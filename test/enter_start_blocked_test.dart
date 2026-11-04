import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';

import 'support/native_verification_fake.dart';

// APP-10E: Build 20, Xiaomi 15, 2026-11-04. The third ENTER at legacy-place-1
// (19:39:41) reached startForegroundService only at 19:40:20, after its
// background-start exemption had expired; Android threw
// ForegroundServiceStartNotAllowedException. Nothing reached the arrival
// engine. The EXIT at 19:40:26 then re-armed the place.
//
// Recovery re-adds that place's geofence with INITIAL_TRIGGER_ENTER; a device
// still inside receives a fresh, platform-issued ENTER. These tests pin what
// the Dart side does with that sequence.

const _legacy = FakePlace(
  'legacy-place-1',
  latitude: 31.665,
  longitude: 34.781,
);
const _junction = FakePlace(
  'place-1793511714921683-2ec1bef0',
  latitude: 31.667,
  longitude: 34.772,
);

DateTime _at(String time) => DateTime.parse('2026-11-04T${time}Z');

/// legacy-place-1 as exported before the failed pass: COOLDOWN from the
/// 19:12:05 notification, exit observed, cooldown over since 19:22:04.
DetectionRuntimeSnapshot _afterSecondVisit() => DetectionRuntimeSnapshot(
  state: DetectionState.cooldown,
  target: const TargetLocation(latitude: 31.665, longitude: 34.781),
  cooldownUntil: DateTime.parse('2026-11-04T19:22:04.966Z'),
  exitObservedDuringCooldown: true,
  visitId: 'visit-1793819512359337',
);

NativeVerificationFake _native() {
  final native = NativeVerificationFake(start: _at('19:39:00'))
    ..register(_legacy)
    ..register(_junction);
  native.runtime.placeSnapshots[_legacy.id] = _afterSecondVisit();
  return native;
}

void main() {
  test('the 2026-11-04 blocked pass: no verification, no false arrival, '
      're-armed by the EXIT, and the next visit notifies', () async {
    final native = _native();

    native.enterBlocked(_legacy.id, _at('19:40:20'));
    expect(native.serviceRunning, isFalse);
    expect(native.gpsOn, isFalse);

    await native.exit(_legacy.id, _at('19:40:26'));
    await native.fixes(_legacy.north(600), _at('19:40:27'), 2);

    expect(native.notifications.deliveredVisitIds, isEmpty);
    expect(native.count('outcome=START_BLOCKED visit=none'), 1);
    expect(native.count('outcome=ARRIVED'), 0);
    expect(native.count('REARMED_ON_EXIT'), 1);
    final legacy = native.runtime.placeSnapshots[_legacy.id]!;
    expect(legacy.state, DetectionState.armed);
    // As exported (state=ARMED, no visit): the re-arm closed the 19:11:52
    // visit and the blocked ENTER never created one.
    expect(legacy.visitId, isNull);
    expect(native.serviceRunning, isFalse);
    expect(native.gpsOn, isFalse);

    // The next pass starts normally and notifies once, with a new visit.
    await native.enter(_legacy.id, _at('19:55:00'));
    await native.fixes(_legacy.north(250), _at('19:55:02'), 3);
    await native.fixes(_legacy.north(40), _at('19:55:08'), 3);
    expect(native.notifications.deliveredVisitIds, [
      '${_legacy.id}:visit-${_at('19:55:00').microsecondsSinceEpoch}',
    ]);
    expect(native.gpsOn, isFalse);
  });

  test(
    'a recovered ENTER while still inside verifies the arrival once',
    () async {
      final native = _native();

      native.enterBlocked(_legacy.id, _at('19:39:41'), sinceReceiveMs: 12000);
      // Re-added with INITIAL_TRIGGER_ENTER: Google Play services sends a new
      // ENTER, with its own exemption, while the device is still inside.
      await native.enter(_legacy.id, _at('19:39:45'));
      await native.fixes(_legacy.north(150), _at('19:39:46'), 3);
      await native.fixes(_legacy.north(40), _at('19:39:52'), 3);

      expect(native.notifications.deliveredVisitIds, [
        '${_legacy.id}:visit-${_at('19:39:45').microsecondsSinceEpoch}',
      ]);
      expect(native.count('APPROACH_STARTED'), 1);
      expect(native.count('outcome=ARRIVED'), 1);
      expect(native.count('outcome=START_BLOCKED'), 1);
      expect(native.gpsOn, isFalse);
      expect(native.serviceRunning, isFalse);
    },
  );

  test(
    'a recovered ENTER during a cooldown is suppressed, no duplicate',
    () async {
      final native = _native();
      // Arrive and notify.
      await native.enter(_legacy.id, _at('19:45:00'));
      await native.fixes(_legacy.north(40), _at('19:45:02'), 3);
      expect(native.notifications.deliveredVisitIds, hasLength(1));

      // A later ENTER of the same visit is blocked and recovered within the
      // 10-minute cooldown.
      native.enterBlocked(_legacy.id, _at('19:47:00'));
      await native.enter(_legacy.id, _at('19:47:02'));
      await native.fixes(_legacy.north(40), _at('19:47:04'), 3);

      expect(native.notifications.deliveredVisitIds, hasLength(1));
      expect(native.count('ENTER_SUPPRESSED'), 1);
      expect(native.gpsOn, isFalse);
    },
  );

  test(
    'a blocked start and its recovery do not disturb another place',
    () async {
      final native = _native();
      await native.enter(_junction.id, _at('19:39:21'));
      await native.fixes(_junction.north(250), _at('19:39:22'), 2);

      // Android refuses legacy-place-1's start; junction keeps verifying.
      native.enterBlocked(_legacy.id, _at('19:39:30'), sinceReceiveMs: 9000);
      expect(native.activePlaceIds, {_junction.id});
      expect(native.gpsOn, isTrue);

      // The recovered ENTER joins the running service.
      await native.enter(_legacy.id, _at('19:39:32'));
      await native.fixes(_junction.north(40), _at('19:39:34'), 3);
      await native.fixes(_legacy.north(40), _at('19:39:40'), 3);

      expect(native.notifications.deliveredVisitIds, [
        startsWith('${_junction.id}:visit-'),
        startsWith('${_legacy.id}:visit-'),
      ]);
      expect(
        native.commands.where((c) => c.endsWith(':${_junction.id}')).toList(),
        ['startVerification:${_junction.id}', 'stopPlace:${_junction.id}'],
      );
      expect(native.gpsOn, isFalse);
      expect(native.serviceRunning, isFalse);
    },
  );

  test(
    'a late-delivered ENTER keeps its transition time and verifies once',
    () async {
      final native = _native();
      // Delivered 39 s after the transition it reports.
      await native.enter(
        _legacy.id,
        _at('19:40:20'),
        transitionAt: _at('19:39:41'),
      );
      await native.fixes(_legacy.north(40), _at('19:40:21'), 3);

      expect(native.notifications.deliveredVisitIds, [
        '${_legacy.id}:visit-${_at('19:39:41').microsecondsSinceEpoch}',
      ]);
      expect(native.gpsOn, isFalse);
    },
  );

  test('a recovered ENTER after the device left ends without a notification '
      'and releases GPS', () async {
    final native = _native();
    native.enterBlocked(_legacy.id, _at('19:40:20'));
    // Worst case: the initial-trigger ENTER is delivered just as the device
    // leaves, and the EXIT follows.
    await native.enter(_legacy.id, _at('19:40:22'));
    await native.fixes(_legacy.north(320), _at('19:40:23'), 2);
    await native.exit(_legacy.id, _at('19:40:26'));
    await native.fixes(_legacy.north(600), _at('19:40:27'), 2);

    expect(native.notifications.deliveredVisitIds, isEmpty);
    expect(native.count('outcome=ARRIVED'), 0);
    expect(
      native.runtime.placeSnapshots[_legacy.id]!.state,
      DetectionState.armed,
    );
    expect(native.gpsOn, isFalse);
    expect(native.serviceRunning, isFalse);
  });

  // Overlapping geofences: one Android callback can report ENTER for both
  // places. Build 21 starts them with one service start.
  test(
    'one callback with two ENTERs verifies both places independently',
    () async {
      final native = _native();
      await native.enter(_legacy.id, _at('19:50:00'));
      await native.enter(_junction.id, _at('19:50:00'));
      await native.fixes(_legacy.north(40), _at('19:50:02'), 3);
      await native.fixes(_junction.north(40), _at('19:50:10'), 3);

      expect(native.notifications.deliveredVisitIds, [
        startsWith('${_legacy.id}:visit-'),
        startsWith('${_junction.id}:visit-'),
      ]);
      expect(native.gpsOn, isFalse);
      expect(native.serviceRunning, isFalse);
    },
  );

  test('one refused start for a two-place callback: both are logged, both '
      'recover, each notifies once', () async {
    final native = _native();
    native
      ..enterBlocked(_legacy.id, _at('19:50:00'), sinceReceiveMs: 15000)
      ..enterBlocked(_junction.id, _at('19:50:00'), sinceReceiveMs: 15000);
    expect(native.count('outcome=START_BLOCKED'), 2);
    expect(native.serviceRunning, isFalse);

    // Each place's geofence is re-added on its own; both ENTERs return.
    await native.enter(_legacy.id, _at('19:50:03'));
    await native.enter(_junction.id, _at('19:50:03'));
    await native.fixes(_legacy.north(40), _at('19:50:05'), 3);
    await native.fixes(_junction.north(40), _at('19:50:12'), 3);
    // A duplicate initial-trigger ENTER for the same visit changes nothing.
    await native.enter(_legacy.id, _at('19:50:20'));
    await native.fixes(_legacy.north(40), _at('19:50:21'), 3);

    expect(native.notifications.deliveredVisitIds, hasLength(2));
    expect(native.count('outcome=ARRIVED'), 2);
    expect(native.gpsOn, isFalse);
    expect(native.serviceRunning, isFalse);
  });
}
