import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';

import 'support/native_verification_fake.dart';

// APP-10D: replays the Build 19 Xiaomi 15 trip of 2026-11-04 from the exported
// report (geofence callbacks to the second; coordinates rounded to 3
// decimals, as exported). The Build 19 report, by elimination:
//
// * 05:28:44 ENTER legacy-place-1, which had been left in COOLDOWN with an
//   observed exit since the evening before. Re-arming inside the ENTER sent
//   stopPlace, GPS stopped, and the approach got no fixes. The approach's own
//   save was lost with the service, leaving legacy-place-1 ARMED with no
//   visit, as exported.
// * 05:29:29 EXIT legacy-place-1 registered it for fixes although it was
//   ARMED; it then ignored every fix (196 LOCATION_IGNORED state=ARMED) and
//   kept GPS on until the watchdog at 05:40:44, 11 minutes after the
//   05:29:44 ENTER.
// * Place 2 arrived (cooldown ended 05:39:58), and after its EXIT logged
//   EXIT_OBSERVED_DURING_COOLDOWN and LOCATION for every fix.
// * Those three repeated lines filled 495 of the 500 retained entries.

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
const _anita = FakePlace(
  'place-1793704230882548-8661ce2e',
  latitude: 31.669,
  longitude: 34.776,
);

DateTime _at(String time) => DateTime.parse('2026-11-04T${time}Z');

void main() {
  test('the 2026-11-04 trip notifies at both places and stops GPS', () async {
    final native = NativeVerificationFake(start: _at('05:28:00'))
      ..register(_legacy)
      ..register(_junction)
      ..register(_anita);
    // Left within the cooldown of the evening visit; the process then died.
    native.runtime.placeSnapshots[_legacy.id] = DetectionRuntimeSnapshot(
      state: DetectionState.cooldown,
      target: const TargetLocation(latitude: 31.665, longitude: 34.781),
      cooldownUntil: DateTime.parse('2026-11-03T21:57:40Z'),
      exitObservedDuringCooldown: true,
      visitId: 'visit-1793741246000000',
    );

    await native.enter(_legacy.id, _at('05:28:44'));
    await native.fixes(_legacy.north(250), _at('05:28:48'), 3);
    await native.fixes(_legacy.north(40), _at('05:28:56'), 3);
    await native.exit(_legacy.id, _at('05:29:29'));
    await native.fixes(_legacy.north(600), _at('05:29:30'), 2);

    await native.enter(_anita.id, _at('05:29:34'));
    await native.enter(_junction.id, _at('05:29:44'));
    await native.fixes(_junction.north(250), _at('05:29:46'), 3);
    await native.exit(_anita.id, _at('05:29:54'));
    await native.fixes(_junction.north(40), _at('05:29:58'), 3);
    await native.exit(_junction.id, _at('05:30:54'));
    // Driving away: about 5 km from the junction by 05:37.
    await native.fixes(_junction.north(5000), _at('05:30:56'), 90);

    // Build 19 notified at the junction but not at legacy-place-1.
    expect(native.notifications.deliveredVisitIds, [
      startsWith('${_legacy.id}:visit-'),
      startsWith('${_junction.id}:visit-'),
    ]);
    expect(native.count('APPROACH_SUMMARY outcome=ARRIVED'), 2);

    // No fix routed to a place that does not need it, GPS off, no watchdog.
    expect(native.count('LOCATION_IGNORED'), lessThanOrEqualTo(2));
    expect(native.count('EXIT_OBSERVED_DURING_COOLDOWN'), 2);
    expect(native.count('REARM_VERIFICATION_COMPLETE'), 2);
    expect(native.serviceRunning, isFalse);
    expect(native.gpsOn, isFalse);

    // Places end as the export would show them under Build 20.
    final legacy = native.runtime.placeSnapshots[_legacy.id]!;
    final junction = native.runtime.placeSnapshots[_junction.id]!;
    final anita = native.runtime.placeSnapshots[_anita.id]!;
    expect(legacy.state, DetectionState.cooldown);
    expect(legacy.exitObservedDuringCooldown, isTrue);
    expect(junction.state, DetectionState.cooldown);
    expect(junction.exitObservedDuringCooldown, isTrue);
    expect(junction.cooldownUntil, _at('05:39:58'));
    // Anita: a 20-second pass, never within 80 m, ends without a notification.
    expect(anita.state, DetectionState.armed);
    expect(anita.visitId, 'visit-${_at('05:29:34').microsecondsSinceEpoch}');

    // The whole trip fits easily in the 500-entry log.
    expect(native.diagnostics.length, lessThan(150));
  });
}
