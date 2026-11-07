import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/background/multi_place_background_arrival_session.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

// APP-10B regression: on the Xiaomi 15, Android delivered ENTER and EXIT for
// both places 40-55 seconds apart and no notification followed. These cases
// replay short visits through the production background router.

const _home = 'legacy-place-1';
const _shop = 'place-1793511714921683-2ec1bef0';
const _lat = 32.0;
const _lon = 34.8;
final _t0 = DateTime.utc(2026, 11, 2, 5, 34, 42);

Map<String, Object?> _config(String id, {double radius = 300}) => {
  'placeId': id,
  'targetLatitude': _lat,
  'targetLongitude': id == _shop ? _lon + 0.05 : _lon,
  'outerRadius': radius,
  'innerRadius': 80.0,
  'rearmRadius': radius + 50 < 350 ? 350.0 : radius + 50,
  'cooldownSeconds': 600,
  'approachTimeoutSeconds': 600,
  'maxAcceptedAccuracy': 50.0,
};

Map<String, Object?> _enter(String id, DateTime at, {double radius = 300}) => {
  ..._config(id, radius: radius),
  'type': 'enter',
  'reminderText': 'Buy milk',
  'timestamp': at.toIso8601String(),
};

Map<String, Object?> _exit(String id, DateTime at, {double radius = 300}) => {
  ..._config(id, radius: radius),
  'type': 'exit',
  'timestamp': at.toIso8601String(),
};

/// A fix [metersNorth] of place [id].
Map<String, Object?> _sample(
  String id,
  double metersNorth,
  DateTime at, {
  double accuracy = 8,
}) => {
  'type': 'location',
  'placeId': id,
  'latitude': _lat + metersNorth / 111320,
  'longitude': id == _shop ? _lon + 0.05 : _lon,
  'accuracy': accuracy,
  'timestamp': at.toIso8601String(),
};

final class _Rig {
  _Rig({DateTime? now}) : _now = now ?? _t0 {
    session = MultiPlaceBackgroundArrivalSession(
      onDiagnostic: diagnostics.add,
      onCommand: (command) async => commands.add(command),
      runtimeStore: runtime,
      notificationService: notifications,
      clock: () => _now,
    );
  }

  final runtime = InMemoryArrivalRuntimeStore();
  final notifications = InMemoryNotificationService();
  final diagnostics = <String>[];
  final commands = <String>[];
  late MultiPlaceBackgroundArrivalSession session;
  DateTime _now;

  Future<void> send(Map<String, Object?> event) {
    final at = DateTime.tryParse(event['timestamp'] as String? ?? '');
    if (at != null) _now = at;
    return session.handleEvent(event);
  }

  /// The native service stops; the next event starts a new process.
  void restartProcess() {
    session.dispose();
    session = MultiPlaceBackgroundArrivalSession(
      onDiagnostic: diagnostics.add,
      onCommand: (command) async => commands.add(command),
      runtimeStore: runtime,
      notificationService: notifications,
      clock: () => _now,
    );
  }

  DetectionState? state(String id) => runtime.placeSnapshots[id]?.state;

  bool logged(String fragment) =>
      diagnostics.any((line) => line.contains(fragment));

  String line(String fragment) =>
      diagnostics.lastWhere((line) => line.contains(fragment));
}

Duration _s(int seconds) => Duration(seconds: seconds);

void main() {
  test('a first fix just outside the outer radius no longer aborts '
      'the approach', () async {
    // Android's coarse geofence ENTER fired while the device was still
    // 330 m away. Build 17 treated that precise sample as an exit, stopped
    // verifying and never notified on the drive past the place.
    final rig = _Rig();
    await rig.send(_enter(_home, _t0));
    await rig.send(_sample(_home, 330, _t0.add(_s(8))));
    expect(rig.state(_home), DetectionState.approaching);
    expect(rig.commands, isNot(contains('stopPlace:$_home')));

    await rig.send(_sample(_home, 150, _t0.add(_s(18))));
    await rig.send(_sample(_home, 45, _t0.add(_s(26))));
    await rig.send(_exit(_home, _t0.add(_s(40))));

    expect(rig.notifications.deliveredVisitIds, hasLength(1));
    expect(rig.state(_home), DetectionState.cooldown);
    expect(
      rig.line('APPROACH_SUMMARY'),
      allOf(
        contains('outcome=ARRIVED'),
        contains('samples=3 accepted=3'),
        contains('closest=44.9m'),
        contains('firstFixAfterEnter=8s'),
      ),
    );
  });

  test('a place is verified against its own outer radius', () async {
    // A 600 m place: Build 17 used the default 300 m, so the first fix at
    // 450 m ended the approach.
    final rig = _Rig();
    await rig.send(_enter(_shop, _t0, radius: 600));
    await rig.send(_sample(_shop, 450, _t0.add(_s(5))));
    expect(rig.state(_shop), DetectionState.approaching);
    await rig.send(_sample(_shop, 60, _t0.add(_s(30))));

    expect(rig.notifications.deliveredVisitIds, hasLength(1));
  });

  test('an EXIT reported before the inner fix waits for precise '
      'confirmation', () async {
    final rig = _Rig();
    await rig.send(_enter(_home, _t0));
    await rig.send(_sample(_home, 200, _t0.add(_s(10))));
    await rig.send(_exit(_home, _t0.add(_s(20))));

    expect(rig.state(_home), DetectionState.approaching);
    expect(rig.logged('EXIT_AWAITING_PRECISE_CONFIRMATION'), isTrue);

    await rig.send(_sample(_home, 70, _t0.add(_s(24))));
    expect(rig.notifications.deliveredVisitIds, hasLength(1));
  });

  test('a confirmed EXIT ends the approach without a notification', () async {
    final rig = _Rig();
    await rig.send(_enter(_home, _t0));
    await rig.send(_sample(_home, 200, _t0.add(_s(10))));
    await rig.send(_exit(_home, _t0.add(_s(40))));
    await rig.send(_sample(_home, 340, _t0.add(_s(44))));

    expect(rig.notifications.deliveredVisitIds, isEmpty);
    expect(rig.state(_home), DetectionState.armed);
    expect(rig.commands.last, 'stopPlace:$_home');
    expect(
      rig.line('APPROACH_SUMMARY'),
      allOf(contains('outcome=EXIT_CONFIRMED'), contains('closest=199.8m')),
    );
  });

  test('inaccurate fixes are reported, never treated as arrival', () async {
    final rig = _Rig();
    await rig.send(_enter(_home, _t0));
    await rig.send(_sample(_home, 20, _t0.add(_s(5)), accuracy: 120));
    await rig.send(_exit(_home, _t0.add(_s(40))));
    await rig.send(_sample(_home, 400, _t0.add(_s(45))));

    expect(rig.notifications.deliveredVisitIds, isEmpty);
    expect(
      rig.diagnostics,
      contains(
        '$_home LOCATION_REJECTED reason=LOW_ACCURACY '
        'accuracy=120.0m max=50m',
      ),
    );
    expect(
      rig.line('APPROACH_SUMMARY'),
      allOf(
        contains('samples=2 accepted=1'),
        contains('rejectedLowAccuracy=1'),
      ),
    );
  });

  test('every sample is logged once, with its coordinates and age', () async {
    final rig = _Rig();
    await rig.send(_enter(_home, _t0));
    await rig.send(_sample(_home, 200, _t0.add(_s(10))));

    final lines = rig.diagnostics.where((line) => line.contains('LOCATION '));
    expect(lines, [
      '$_home LOCATION distance=199.8m accuracy=8.0m '
          'at=2026-11-02T05:34:52.000Z lat=32.00180 lon=34.80000 age=0s',
    ]);
  });

  test(
    'a persisted APPROACHING state no longer blocks the next visit',
    () async {
      // The verifying process died mid-approach (watchdog or OS kill), leaving
      // APPROACHING persisted. Build 17 ignored every later ENTER.
      final rig = _Rig();
      rig.runtime.placeSnapshots[_home] = DetectionRuntimeSnapshot(
        state: DetectionState.approaching,
        target: const TargetLocation(latitude: _lat, longitude: _lon),
        approachStartedAt: _t0.subtract(const Duration(days: 1)),
      );

      await rig.send(_enter(_home, _t0));
      expect(rig.logged('APPROACH_RESTARTED_FROM_PERSISTED_STATE'), isTrue);
      await rig.send(_sample(_home, 40, _t0.add(_s(15))));

      expect(rig.notifications.deliveredVisitIds, hasLength(1));
    },
  );

  test('an ENTER during the cooldown is suppressed with its reason and '
      'releases precise location', () async {
    final rig = _Rig();
    await rig.send(_enter(_home, _t0));
    await rig.send(_sample(_home, 40, _t0.add(_s(10))));
    rig.restartProcess();
    rig.commands.clear();

    await rig.send(_enter(_home, _t0.add(const Duration(minutes: 3))));

    expect(rig.notifications.deliveredVisitIds, hasLength(1));
    expect(
      rig.line('ENTER_SUPPRESSED'),
      contains('reason=COOLDOWN until=2026-11-02T05:44:52.000Z'),
    );
    expect(rig.commands, ['stopPlace:$_home']);
  });

  test(
    'an ENTER while waiting for exit is suppressed with its reason',
    () async {
      final rig = _Rig();
      rig.runtime.placeSnapshots[_home] = DetectionRuntimeSnapshot(
        state: DetectionState.waitingForExit,
        target: const TargetLocation(latitude: _lat, longitude: _lon),
        visitId: 'visit-old',
      );

      await rig.send(_enter(_home, _t0));
      await rig.send(_sample(_home, 30, _t0.add(_s(10))));

      expect(rig.notifications.deliveredVisitIds, isEmpty);
      expect(
        rig.line('ENTER_SUPPRESSED'),
        contains(
          'reason=WAITING_FOR_EXIT rearm needs a precise sample >= 350m',
        ),
      );
      expect(
        rig.logged('LOCATION_IGNORED reason=NO_ACTIVE_VERIFICATION'),
        isTrue,
      );
      expect(rig.commands, contains('stopPlace:$_home'));
    },
  );

  test('one place arriving does not stop another place verifying', () async {
    final rig = _Rig();
    await rig.send(_enter(_home, _t0));
    await rig.send(_enter(_shop, _t0.add(_s(2))));
    await rig.send(_sample(_home, 30, _t0.add(_s(10))));

    // Each approach re-registers itself when it starts (APP-10D).
    List<String> stops() =>
        rig.commands.where((c) => c.startsWith('stop')).toList();
    expect(stops(), ['stopPlace:$_home']);
    expect(rig.state(_shop), DetectionState.approaching);
    await rig.send(_sample(_shop, 50, _t0.add(_s(20))));

    expect(rig.notifications.deliveredVisitIds, hasLength(2));
    expect(stops(), ['stopPlace:$_home', 'stopPlace:$_shop']);
  });

  test(
    'the cooldown still prevents a duplicate after a quick return',
    () async {
      final rig = _Rig();
      await rig.send(_enter(_home, _t0));
      await rig.send(_sample(_home, 40, _t0.add(_s(10))));
      rig.restartProcess();
      await rig.send(_exit(_home, _t0.add(_s(60))));
      await rig.send(_sample(_home, 500, _t0.add(_s(70))));
      rig.restartProcess();
      await rig.send(_enter(_home, _t0.add(const Duration(minutes: 4))));
      await rig.send(_sample(_home, 20, _t0.add(const Duration(minutes: 5))));

      expect(rig.notifications.deliveredVisitIds, hasLength(1));
      expect(rig.state(_home), DetectionState.cooldown);
    },
  );
}
