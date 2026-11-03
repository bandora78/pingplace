import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/background/multi_place_background_arrival_session.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

// APP-10C regression: Build 18 field test, 2026-11-03. After leaving and
// returning more than 10 minutes later, legacy-place-1 logged
// APPROACH_SUMMARY outcome=ARRIVED, NOTIFICATION_REQUESTED and then
// NOTIFICATION_SUPPRESSED_DUPLICATE, and its state showed `visit=null`.
//
// The native runtime bridge stores a cleared visit ID as JSON null. On Android
// (libcore org.json), `JSONObject.optString` returns the literal string "null"
// for a JSON null, so the next background process restored visitId "null".
// The engine kept that ID for the next visit (`_visitId ??= ...`), and every
// visit that started from a restored, re-armed state was delivered as
// "<place>:null". The first one was sent and every later one was suppressed
// as a duplicate.

const _runtimeChannel = MethodChannel('pingplace/runtime');
const _lat = 32.0;
const _lon = 34.8;
final _t0 = DateTime.utc(2026, 11, 3, 13);

/// Emulates PlatformRuntimeBridge on the device: the state is stored as JSON
/// with nulls kept as JSON null, and string fields are read back with
/// Android's `optString`, which turns a JSON null into "null". It also returns
/// a value already corrupted by an earlier save, as stored on the field-test
/// phone.
final class _AndroidRuntimeBridge {
  final Map<String, Map<String, Object?>> stored = {};

  static const _optStringFields = [
    'approachStartedAt',
    'cooldownUntil',
    'visitId',
  ];

  Future<Object?> handle(MethodCall call) async {
    final arguments = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    final key = arguments['placeId'] as String? ?? '__legacy__';
    switch (call.method) {
      case 'save':
        stored[key] = Map.of(arguments)..remove('placeId');
        return null;
      case 'load':
        final value = stored[key];
        if (value == null) return null;
        return {
          ...value,
          for (final field in _optStringFields) field: value[field] ?? 'null',
        };
      case 'clear':
        stored.remove(key);
        return null;
      case 'loadReminderText':
        return 'Buy milk';
    }
    return null;
  }
}

Map<String, Object?> _config(String placeId, double lat) => {
  'placeId': placeId,
  'targetLatitude': lat,
  'targetLongitude': _lon,
  'outerRadius': 300.0,
  'innerRadius': 80.0,
  'rearmRadius': 350.0,
  'cooldownSeconds': 600,
  'approachTimeoutSeconds': 600,
  'maxAcceptedAccuracy': 50.0,
};

Map<String, Object?> _enter(String placeId, double lat, DateTime at) => {
  ..._config(placeId, lat),
  'type': 'enter',
  'reminderText': 'Buy milk',
  'timestamp': at.toIso8601String(),
};

Map<String, Object?> _exit(String placeId, double lat, DateTime at) => {
  ..._config(placeId, lat),
  'type': 'exit',
  'timestamp': at.toIso8601String(),
};

Map<String, Object?> _sample(
  String placeId,
  double lat,
  double metersNorth,
  DateTime at,
) => {
  'type': 'location',
  'placeId': placeId,
  'latitude': lat + metersNorth / 111320,
  'longitude': _lon,
  'accuracy': 3.8,
  'timestamp': at.toIso8601String(),
};

/// One headless background process: a new session over the same native
/// storage, as after the service stops or the device reboots.
final class _Process {
  _Process(this.notifications, DateTime now)
    : session = MultiPlaceBackgroundArrivalSession(
        onDiagnostic: diagnostics.add,
        onCommand: (_) async {},
        runtimeStore: MethodChannelArrivalRuntimeStore(),
        notificationService: notifications,
        clock: () => now,
      );

  static final List<String> diagnostics = [];
  final InMemoryNotificationService notifications;
  final MultiPlaceBackgroundArrivalSession session;

  Future<void> send(Map<String, Object?> event) => session.handleEvent(event);
  void kill() => session.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _AndroidRuntimeBridge bridge;

  setUp(() {
    bridge = _AndroidRuntimeBridge();
    _Process.diagnostics.clear();
    messenger.setMockMethodCallHandler(_runtimeChannel, bridge.handle);
  });
  tearDown(() => messenger.setMockMethodCallHandler(_runtimeChannel, null));

  /// Arrive in one process, leave and re-arm in another (Android EXIT, then a
  /// precise fix beyond the re-arm radius after the cooldown has expired).
  Future<void> visitAndLeave(
    InMemoryNotificationService notifications,
    String placeId,
    double lat,
    DateTime at,
  ) async {
    final arriving = _Process(notifications, at);
    await arriving.send(_enter(placeId, lat, at));
    await arriving.send(
      _sample(placeId, lat, 200, at.add(const Duration(seconds: 4))),
    );
    await arriving.send(
      _sample(placeId, lat, 75.8, at.add(const Duration(seconds: 21))),
    );
    arriving.kill();

    final leaveAt = at.add(const Duration(minutes: 12));
    final leaving = _Process(notifications, leaveAt);
    await leaving.send(_exit(placeId, lat, leaveAt));
    await leaving.send(
      _sample(placeId, lat, 600, leaveAt.add(const Duration(seconds: 30))),
    );
    leaving.kill();
  }

  test('every re-armed visit restored from storage notifies again', () async {
    final notifications = InMemoryNotificationService();
    const place = 'legacy-place-1';

    // Three visits, each separated by a confirmed exit beyond 350 m and an
    // expired 10-minute cooldown, each starting in a new process.
    for (var visit = 0; visit < 3; visit++) {
      await visitAndLeave(
        notifications,
        place,
        _lat,
        _t0.add(Duration(hours: visit)),
      );
      expect(
        bridge.stored[place]?['state'],
        DetectionState.armed.name,
        reason: 'visit $visit must end re-armed',
      );
    }

    expect(
      _Process.diagnostics.where((l) => l.contains('APPROACH_SUMMARY')),
      everyElement(contains('outcome=ARRIVED')),
    );
    expect(
      _Process.diagnostics.where((l) => l.contains('NOTIFICATION_SUPPRESSED')),
      isEmpty,
    );
    expect(notifications.deliveredVisitIds, hasLength(3));
    expect(notifications.deliveredVisitIds.toSet(), hasLength(3));
    expect(
      notifications.deliveredVisitIds,
      everyElement(allOf(startsWith('$place:visit-'), isNot(endsWith('null')))),
    );
  });

  test(
    'a visit ID already stored as "null" on the device is not reused',
    () async {
      // State persisted by Build 18 on the field-test phone after a re-arm.
      bridge.stored['legacy-place-1'] = {
        'state': 'armed',
        'targetLatitude': _lat,
        'targetLongitude': _lon,
        'approachStartedAt': 'null',
        'cooldownUntil': 'null',
        'exitObservedDuringCooldown': false,
        'visitId': 'null',
      };
      final notifications = InMemoryNotificationService()
        // The earlier "null" visit was already delivered.
        ..deliveredVisitIds.add('legacy-place-1:null');

      final process = _Process(notifications, _t0);
      await process.send(_enter('legacy-place-1', _lat, _t0));
      await process.send(
        _sample(
          'legacy-place-1',
          _lat,
          63.4,
          _t0.add(const Duration(seconds: 9)),
        ),
      );

      expect(_Process.diagnostics, contains(contains('NOTIFICATION_SENT')));
      expect(
        notifications.deliveredVisitIds.last,
        startsWith('legacy-place-1:visit-'),
      );
      expect(bridge.stored['legacy-place-1']?['visitId'], startsWith('visit-'));
    },
  );

  test('cooldown and per-place duplicate prevention are unchanged', () async {
    final notifications = InMemoryNotificationService();
    const a = 'legacy-place-1';
    const b = 'place-2';
    const latB = _lat + 0.05;

    final first = _Process(notifications, _t0);
    await first.send(_enter(a, _lat, _t0));
    await first.send(_sample(a, _lat, 60, _t0.add(const Duration(seconds: 9))));
    await first.send(_enter(b, latB, _t0.add(const Duration(minutes: 1))));
    await first.send(
      _sample(b, latB, 60, _t0.add(const Duration(minutes: 1, seconds: 9))),
    );
    first.kill();
    expect(notifications.deliveredVisitIds, hasLength(2));

    // Back at place A within its cooldown, in a new process: no notification.
    final revisitAt = _t0.add(const Duration(minutes: 5));
    final revisit = _Process(notifications, revisitAt);
    await revisit.send(_enter(a, _lat, revisitAt));
    await revisit.send(
      _sample(a, _lat, 20, revisitAt.add(const Duration(seconds: 5))),
    );
    expect(notifications.deliveredVisitIds, hasLength(2));
    expect(
      _Process.diagnostics,
      contains(
        allOf(startsWith(a), contains('ENTER_SUPPRESSED reason=COOLDOWN')),
      ),
    );

    // After the cooldown, without a confirmed exit beyond 350 m: still no
    // notification (waiting for exit).
    final lateAt = _t0.add(const Duration(minutes: 15));
    final late = _Process(notifications, lateAt);
    await late.send(_enter(a, _lat, lateAt));
    await late.send(
      _sample(a, _lat, 20, lateAt.add(const Duration(seconds: 5))),
    );
    expect(notifications.deliveredVisitIds, hasLength(2));
    expect(
      _Process.diagnostics,
      contains(
        allOf(
          startsWith(a),
          contains('ENTER_SUPPRESSED reason=WAITING_FOR_EXIT'),
        ),
      ),
    );
  });

  test('entering from ARMED always starts a new visit ID', () {
    final enteredAt = _t0.add(const Duration(hours: 2));
    final engine = SmartArrivalDetectionEngine(
      SmartArrivalConfig(
        target: const TargetLocation(latitude: _lat, longitude: _lon),
      ),
      snapshot: const DetectionRuntimeSnapshot(
        state: DetectionState.armed,
        visitId: 'visit-already-notified',
      ),
    );
    engine.dispatch(OuterEnter(at: enteredAt));
    expect(engine.state, DetectionState.approaching);
    expect(engine.visitId, 'visit-${enteredAt.microsecondsSinceEpoch}');

    // A restarted approach is the same visit and keeps its ID.
    engine.dispatch(RestartApproach(enteredAt.add(const Duration(minutes: 1))));
    expect(engine.visitId, 'visit-${enteredAt.microsecondsSinceEpoch}');
  });

  test('notification lines name the visit they were delivered for', () async {
    final notifications = InMemoryNotificationService();
    final process = _Process(notifications, _t0);
    await process.send(_enter('place-2', _lat, _t0));
    await process.send(
      _sample('place-2', _lat, 60, _t0.add(const Duration(seconds: 9))),
    );
    final visit = notifications.deliveredVisitIds.single.substring(
      'place-2:'.length,
    );
    expect(
      _Process.diagnostics,
      contains('place-2 NOTIFICATION_REQUESTED visit=$visit'),
    );
    expect(
      _Process.diagnostics,
      contains('place-2 NOTIFICATION_SENT visit=$visit'),
    );
  });
}
