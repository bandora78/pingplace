import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';

import 'support/native_verification_fake.dart';

// APP-10D regression: Build 19 field test, 2026-11-04. Three visits to
// legacy-place-1 produced only two notifications, and the retained log held
// no visit summary or notification result for the missed visit.
//
// Root cause: when a place left during its cooldown (exit observed) and came
// back after the cooldown had expired while no process was running, the ENTER
// first applied the elapsed cooldown. Re-arming emitted "precise location
// stopped", which the session forwarded to the native service as
// stopPlace:<id>. The native service removed the place from the places it
// routes fixes to and, with no other place verifying, stopped GPS and the
// service. The same ENTER then started the approach, but no fix ever reached
// it: no ARRIVED, no summary, no notification. The recording fakes used by
// the earlier tests delivered every sample regardless, so they never saw it.

const _home = FakePlace('legacy-place-1', latitude: 32.0, longitude: 34.8);
const _shop = FakePlace('place-2', latitude: 32.05, longitude: 34.8);
final _t0 = DateTime.utc(2026, 11, 4, 4);

Duration _min(int minutes) => Duration(minutes: minutes);
Duration _s(int seconds) => Duration(seconds: seconds);

NativeVerificationFake _native() => NativeVerificationFake(start: _t0)
  ..register(_home)
  ..register(_shop);

/// Drive in from 250 m and stop 40 m from [place].
Future<void> _arrive(
  NativeVerificationFake native,
  FakePlace place,
  DateTime at,
) async {
  await native.enter(place.id, at);
  await native.fixes(place.north(250), at.add(_s(4)), 3);
  await native.fixes(place.north(40), at.add(_s(12)), 3);
}

/// Android EXIT after [after], then fixes 600 m away until the watchdog.
Future<void> _leave(
  NativeVerificationFake native,
  FakePlace place,
  DateTime at,
) async {
  await native.exit(place.id, at);
  await native.fixes(place.north(600), at.add(_s(2)), 60);
  native.watchdog();
}

void main() {
  test('a visit after leaving during the cooldown notifies (the missed third '
      'visit)', () async {
    final native = _native();

    // Visit 1, leaving after the cooldown expired.
    await _arrive(native, _home, _t0);
    await _leave(native, _home, _t0.add(_min(12)));
    expect(
      native.runtime.placeSnapshots[_home.id]?.state,
      DetectionState.armed,
    );

    // Visit 2, leaving within the 10-minute cooldown.
    final second = _t0.add(_min(40));
    await _arrive(native, _home, second);
    await _leave(native, _home, second.add(_min(3)));
    final afterSecond = native.runtime.placeSnapshots[_home.id];
    expect(afterSecond?.state, DetectionState.cooldown);
    expect(afterSecond?.exitObservedDuringCooldown, isTrue);

    // Visit 3, after the cooldown expired with no process running.
    final third = _t0.add(_min(80));
    await native.enter(_home.id, third);
    native.droppedFixes = 0;
    await native.fixes(_home.north(250), third.add(_s(4)), 3);
    await native.fix(_home.north(40), third.add(_s(12)));

    expect(native.droppedFixes, 0, reason: 'no fix of visit 3 was lost');
    expect(native.notifications.deliveredVisitIds, hasLength(3));
    expect(native.notifications.deliveredVisitIds.toSet(), hasLength(3));
    expect(native.count('APPROACH_SUMMARY outcome=ARRIVED'), 3);
    expect(native.count('NOTIFICATION_SENT visit=visit-'), 3);
    expect(native.count('NOTIFICATION_SUPPRESSED'), 0);
  });

  test('re-arming on ENTER keeps the place routed for fixes', () async {
    final native = _native();
    native.runtime.placeSnapshots[_home.id] = DetectionRuntimeSnapshot(
      state: DetectionState.cooldown,
      target: const TargetLocation(latitude: 32.0, longitude: 34.8),
      cooldownUntil: _t0.subtract(_min(5)),
      exitObservedDuringCooldown: true,
      visitId: 'visit-earlier',
    );

    await native.enter(_home.id, _t0);

    expect(native.serviceRunning, isTrue);
    expect(native.gpsOn, isTrue);
    expect(native.activePlaceIds, contains(_home.id));
    expect(native.commands, isNot(contains('stopPlace:${_home.id}')));
    expect(native.count('COOLDOWN_ELAPSED_WHILE_STOPPED'), 1);
    expect(native.count('APPROACH_STARTED visit=visit-'), 1);
    expect(
      native.runtime.placeSnapshots[_home.id]?.state,
      DetectionState.approaching,
    );
  });

  test('the re-arm on ENTER does not cut a place off while another place '
      'keeps the service running', () async {
    final native = _native();
    native.runtime.placeSnapshots[_home.id] = DetectionRuntimeSnapshot(
      state: DetectionState.cooldown,
      target: const TargetLocation(latitude: 32.0, longitude: 34.8),
      cooldownUntil: _t0.subtract(_min(5)),
      exitObservedDuringCooldown: true,
      visitId: 'visit-earlier',
    );
    await native.enter(_shop.id, _t0);
    await native.fixes(_shop.north(250), _t0.add(_s(2)), 2);

    await native.enter(_home.id, _t0.add(_s(10)));
    await native.fixes(_home.north(40), _t0.add(_s(14)), 3);

    expect(
      native.notifications.deliveredVisitIds,
      contains(startsWith('${_home.id}:visit-')),
    );
    expect(
      native.runtime.placeSnapshots[_shop.id]?.state,
      DetectionState.approaching,
    );
  });

  test('an observed exit during the cooldown ends that place\'s GPS once, '
      'without stopping another place\'s approach', () async {
    final native = _native();
    await _arrive(native, _home, _t0);
    expect(native.serviceRunning, isFalse);

    // Shop is being approached when home's EXIT arrives in the same process.
    final leaveAt = _t0.add(_min(3));
    await native.enter(_shop.id, leaveAt);
    await native.exit(_home.id, leaveAt.add(_s(1)));
    expect(native.activePlaceIds, containsAll([_home.id, _shop.id]));

    // 600 m from home, 5 km from shop: home's exit is observed at once.
    final mark = native.diagnostics.length;
    await native.fixes(_home.north(600), leaveAt.add(_s(2)), 30);

    expect(native.count('${_home.id} EXIT_OBSERVED_DURING_COOLDOWN'), 1);
    expect(native.commands, contains('stopPlace:${_home.id}'));
    expect(native.activePlaceIds, [_shop.id]);
    expect(native.gpsOn, isTrue, reason: 'shop is still approaching');
    expect(
      native.diagnostics
          .skip(mark)
          .where((l) => l.contains('${_home.id} LOCATION distance=')),
      hasLength(1),
    );
    final home = native.runtime.placeSnapshots[_home.id];
    expect(home?.state, DetectionState.cooldown);
    expect(home?.exitObservedDuringCooldown, isTrue);

    // Shop still arrives and notifies.
    await native.fixes(_shop.north(30), leaveAt.add(_s(70)), 2);
    expect(
      native.notifications.deliveredVisitIds,
      contains(startsWith('${_shop.id}:visit-')),
    );
    expect(native.serviceRunning, isFalse);
  });

  test('ignored fixes are aggregated instead of logged one by one', () async {
    final native = _native();
    native.runtime.placeSnapshots[_home.id] = const DetectionRuntimeSnapshot(
      state: DetectionState.armed,
      target: TargetLocation(latitude: 32.0, longitude: 34.8),
    );
    await native.enter(_shop.id, _t0);
    // Home is routed fixes it does not need (as after a Build 19 EXIT).
    await native.exit(_home.id, _t0.add(_s(1)));
    native.activePlaceIds.add(_home.id);

    await native.fixes(_shop.north(250), _t0.add(_s(2)), 100);

    final ignored = native.diagnostics
        .where((l) => l.contains('${_home.id} LOCATION_IGNORED'))
        .toList();
    expect(ignored, isNotEmpty);
    expect(ignored.length, lessThanOrEqualTo(5));
    expect(ignored.first, contains('reason=NO_ACTIVE_VERIFICATION'));
    expect(ignored.last, contains('count='));
  });

  test('cooldown suppression and waiting-for-exit are unchanged', () async {
    final native = _native();
    await _arrive(native, _home, _t0);

    // Back within the cooldown without having left: suppressed.
    await _arrive(native, _home, _t0.add(_min(5)));
    expect(native.count('ENTER_SUPPRESSED reason=COOLDOWN'), 1);

    // After the cooldown without a confirmed exit: still suppressed.
    await _arrive(native, _home, _t0.add(_min(20)));
    expect(native.count('ENTER_SUPPRESSED reason=WAITING_FOR_EXIT'), 1);

    expect(native.notifications.deliveredVisitIds, hasLength(1));
    expect(native.serviceRunning, isFalse);
  });

  test('an approach ended in a later process still gets a summary', () async {
    final native = _native();
    await native.enter(_home.id, _t0);
    await native.fixes(_home.north(250), _t0.add(_s(2)), 2);
    native.watchdog();

    // Android EXIT in a new process: the approach ends without its samples.
    await native.exit(_home.id, _t0.add(_min(4)));

    final summary = native.diagnostics.lastWhere(
      (l) => l.contains('APPROACH_SUMMARY'),
    );
    expect(summary, contains('outcome=EXIT_CONFIRMED'));
    expect(summary, contains('visit=visit-'));
    expect(summary, contains('restored=true'));
    expect(
      native.runtime.placeSnapshots[_home.id]?.state,
      DetectionState.armed,
    );
  });

  group('EXITs from one geofence callback', () {
    // 2026-11-03T21:33:22Z: one callback reported EXIT for all three places.
    // Home's cooldown had expired with an exit observed, so its EXIT re-arms
    // it at once and stops its verification. The shop's EXIT, queued right
    // behind it, still needs GPS to measure its exit.
    Future<NativeVerificationFake> clusteredExits({required bool defer}) async {
      final native = _native()..deferStopsWhileEventsInFlight = defer;
      native.runtime.placeSnapshots[_home.id] = DetectionRuntimeSnapshot(
        state: DetectionState.cooldown,
        target: const TargetLocation(latitude: 32.0, longitude: 34.8),
        cooldownUntil: _t0.subtract(_min(5)),
        exitObservedDuringCooldown: true,
        visitId: 'visit-home',
      );
      native.runtime.placeSnapshots[_shop.id] = DetectionRuntimeSnapshot(
        state: DetectionState.cooldown,
        target: const TargetLocation(latitude: 32.05, longitude: 34.8),
        cooldownUntil: _t0.add(_min(5)),
        visitId: 'visit-shop',
      );
      await Future.wait([
        native.exit(_home.id, _t0),
        native.exit(_shop.id, _t0),
      ]);
      await native.fixes(_shop.north(600), _t0.add(_s(2)), 3);
      return native;
    }

    test(
      'a stop for one place never drops the queued EXIT of another place',
      () async {
        final native = await clusteredExits(defer: true);

        expect(native.lostEvents, 0);
        expect(native.count('${_home.id} REARMED_ON_EXIT'), 1);
        expect(native.count('${_shop.id} BACKGROUND_EXIT_RECEIVED'), 1);
        expect(native.count('${_shop.id} EXIT_OBSERVED_DURING_COOLDOWN'), 1);
        expect(
          native.runtime.placeSnapshots[_shop.id]?.exitObservedDuringCooldown,
          isTrue,
        );
        expect(
          native.runtime.placeSnapshots[_home.id]?.state,
          DetectionState.armed,
        );
        // Both done: GPS and the service stop.
        expect(native.serviceRunning, isFalse);
        expect(native.gpsOn, isFalse);
      },
    );

    test('reproduction: stopping at once loses the queued EXIT', () async {
      final native = await clusteredExits(defer: false);

      expect(native.lostEvents, 1);
      expect(native.count('${_shop.id} BACKGROUND_EXIT_RECEIVED'), 0);
      expect(
        native.runtime.placeSnapshots[_shop.id]?.exitObservedDuringCooldown,
        isFalse,
      );
    });
  });
}
