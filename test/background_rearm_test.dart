import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/background/multi_place_background_arrival_session.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

// APP-10A regression: the background service stops right after an arrival
// notification, so a place's EXIT always arrives in a new background process.
// Build 16 dropped that EXIT ("BACKGROUND_EVENT_IGNORED unknown place id"),
// leaving the place in cooldown/waiting-for-exit forever: each place notified
// at most once.

const _id = 'place-1';
const _lat = 32.0;
const _lon = 34.8;
final _t0 = DateTime.utc(2026, 11, 1, 6);

Map<String, Object?> _config() => {
  'placeId': _id,
  'targetLatitude': _lat,
  'targetLongitude': _lon,
  'innerRadius': 80.0,
  'rearmRadius': 350.0,
  'cooldownSeconds': 600,
  'approachTimeoutSeconds': 600,
  'maxAcceptedAccuracy': 50.0,
};

Map<String, Object?> _enter(DateTime at) => {
  ..._config(),
  'type': 'enter',
  'reminderText': 'Buy milk',
  'timestamp': at.toIso8601String(),
};

Map<String, Object?> _exit(DateTime at) => {
  ..._config(),
  'type': 'exit',
  'timestamp': at.toIso8601String(),
};

/// [metersNorth] from the place, with good accuracy.
Map<String, Object?> _sample(double metersNorth, DateTime at) => {
  'type': 'location',
  'placeId': _id,
  'latitude': _lat + metersNorth / 111320,
  'longitude': _lon,
  'accuracy': 10.0,
  'timestamp': at.toIso8601String(),
};

final class _Process {
  _Process(this.runtime, this.notifications, DateTime now)
    : session = MultiPlaceBackgroundArrivalSession(
        onDiagnostic: _diagnostics.add,
        onCommand: (command) async => _commands.add(command),
        runtimeStore: runtime,
        notificationService: notifications,
        clock: () => now,
      );

  static final List<String> _diagnostics = [];
  static final List<String> _commands = [];
  final InMemoryArrivalRuntimeStore runtime;
  final InMemoryNotificationService notifications;
  final MultiPlaceBackgroundArrivalSession session;

  List<String> get commands => _commands;
  List<String> get diagnostics => _diagnostics;

  Future<void> send(Map<String, Object?> event) => session.handleEvent(event);

  /// Like the native service stopping and destroying the headless engine.
  void kill() => session.dispose();

  static void reset() {
    _diagnostics.clear();
    _commands.clear();
  }
}

Future<void> _firstVisit(
  InMemoryArrivalRuntimeStore runtime,
  InMemoryNotificationService notifications,
) async {
  final process = _Process(runtime, notifications, _t0);
  await process.send(_enter(_t0));
  await process.send(_sample(60, _t0.add(const Duration(minutes: 1))));
  expect(notifications.deliveredVisitIds, hasLength(1));
  expect(runtime.placeSnapshots[_id]?.state, DetectionState.cooldown);
  // The session stops the service after notifying.
  expect(process.commands, contains('stop'));
  process.kill();
}

void main() {
  setUp(_Process.reset);

  test(
    'the next visit notifies again after an EXIT in a new process',
    () async {
      final runtime = InMemoryArrivalRuntimeStore();
      final notifications = InMemoryNotificationService();
      await _firstVisit(runtime, notifications);

      // 20 minutes later the user leaves; Android starts a new background process.
      final leaveAt = _t0.add(const Duration(minutes: 20));
      final leaving = _Process(runtime, notifications, leaveAt)
        ..commands.clear();
      await leaving.send(_exit(leaveAt));
      expect(leaving.commands, contains('startVerification'));
      expect(
        leaving.diagnostics,
        isNot(contains(contains('BACKGROUND_EVENT_IGNORED'))),
      );
      await leaving.send(_sample(600, leaveAt.add(const Duration(minutes: 1))));
      expect(runtime.placeSnapshots[_id]?.state, DetectionState.armed);
      leaving.kill();

      // The next day: a new visit in yet another process.
      final nextVisit = _t0.add(const Duration(days: 1));
      final returning = _Process(runtime, notifications, nextVisit);
      await returning.send(_enter(nextVisit));
      await returning.send(
        _sample(60, nextVisit.add(const Duration(minutes: 1))),
      );

      expect(notifications.deliveredVisitIds, hasLength(2));
      expect(notifications.deliveredVisitIds.toSet(), hasLength(2));
      returning.kill();
    },
  );

  test(
    'EXIT during the cooldown is remembered and the later visit notifies',
    () async {
      final runtime = InMemoryArrivalRuntimeStore();
      final notifications = InMemoryNotificationService();
      await _firstVisit(runtime, notifications);

      // Leaves after 3 minutes, still inside the 10-minute cooldown.
      final leaveAt = _t0.add(const Duration(minutes: 3));
      final leaving = _Process(runtime, notifications, leaveAt);
      await leaving.send(_exit(leaveAt));
      await leaving.send(
        _sample(600, leaveAt.add(const Duration(seconds: 30))),
      );
      expect(runtime.placeSnapshots[_id]?.state, DetectionState.cooldown);
      expect(runtime.placeSnapshots[_id]?.exitObservedDuringCooldown, isTrue);
      leaving.kill();

      // Returns after the cooldown expired while no process was running.
      final back = _t0.add(const Duration(minutes: 45));
      final returning = _Process(runtime, notifications, back);
      await returning.send(_enter(back));
      await returning.send(_sample(60, back.add(const Duration(minutes: 1))));

      expect(notifications.deliveredVisitIds, hasLength(2));
      returning.kill();
    },
  );

  test(
    'a re-registration ENTER while still inside does not notify twice',
    () async {
      final runtime = InMemoryArrivalRuntimeStore();
      final notifications = InMemoryNotificationService();
      await _firstVisit(runtime, notifications);

      // App restart or reboot re-registers geofences; Android sends an initial
      // ENTER although the user never left. Cooldown has expired.
      final later = _t0.add(const Duration(minutes: 40));
      final restarted = _Process(runtime, notifications, later);
      await restarted.send(_enter(later));
      await restarted.send(_sample(40, later.add(const Duration(minutes: 1))));

      expect(notifications.deliveredVisitIds, hasLength(1));
      expect(runtime.placeSnapshots[_id]?.state, DetectionState.waitingForExit);
      restarted.kill();
    },
  );

  test('EXIT verification survives the cooldown expiring meanwhile', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService();
    await _firstVisit(runtime, notifications);

    // EXIT arrives after the cooldown expired; the transition to
    // waiting-for-exit must not stop the service before the exit is measured.
    final leaveAt = _t0.add(const Duration(minutes: 15));
    final leaving = _Process(runtime, notifications, leaveAt)..commands.clear();
    await leaving.send(_exit(leaveAt));
    expect(leaving.commands, isNot(contains('stop')));
    expect(leaving.commands, contains('startVerification'));
    await leaving.send(_sample(600, leaveAt.add(const Duration(minutes: 1))));
    expect(runtime.placeSnapshots[_id]?.state, DetectionState.armed);
    expect(leaving.commands.last, 'stop');
    leaving.kill();
  });

  test('EXIT for a place without stored state is harmless', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService();
    final process = _Process(runtime, notifications, _t0);

    await process.send(_exit(_t0));

    expect(process.commands, isNot(contains('startVerification')));
    expect(notifications.deliveredVisitIds, isEmpty);
    process.kill();
  });

  test(
    'location samples for a place without a session are still ignored',
    () async {
      final runtime = InMemoryArrivalRuntimeStore();
      final process = _Process(runtime, InMemoryNotificationService(), _t0);

      await process.send(_sample(10, _t0));

      expect(
        process.diagnostics.last,
        contains('BACKGROUND_EVENT_IGNORED $_id type=location'),
      );
      expect(runtime.placeSnapshots, isEmpty);
      process.kill();
    },
  );
}
