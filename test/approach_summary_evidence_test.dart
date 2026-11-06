import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';

import 'support/native_verification_fake.dart';

// APP-10F: an APPROACH_SUMMARY must explain its own evidence, because the
// per-fix lines of a visit may already be evicted when a report is exported.
// On 2026-11-06 the Xiaomi 15 arrived at Delek on one fix (39.8 m, accuracy
// 42.1 m) delivered 8 ms after GPS was requested; its age was lost with the
// evicted LOCATION line.

const _delek = FakePlace('legacy-place-1', latitude: 31.665, longitude: 34.781);
const _sagula = FakePlace(
  'place-1793511714921683-2ec1bef0',
  latitude: 31.667,
  longitude: 34.772,
);

DateTime _at(String time) => DateTime.parse('2026-11-06T${time}Z');

String _summary(NativeVerificationFake native, String placeId) => native
    .diagnostics
    .singleWhere((l) => l.contains(placeId) && l.contains('APPROACH_SUMMARY'));

void main() {
  test(
    'a single cached fix: its age, accuracy and pre-ENTER time are stated',
    () async {
      final native = NativeVerificationFake(start: _at('06:00:00'))
        ..register(_delek);
      await native.enter(_delek.id, _at('06:01:03.224'));
      // Taken 1.2 s before the ENTER, delivered with the GPS request.
      await native.fix(
        _delek.north(39.8),
        _at('06:01:03.232'),
        takenAt: _at('06:01:02.032'),
        accuracy: 42.1,
      );

      final summary = _summary(native, _delek.id);
      expect(summary, contains('outcome=ARRIVED'));
      expect(summary, contains('samples=1'));
      expect(summary, contains('firstFixAge=1.2s'));
      expect(summary, contains('firstFixAccuracy=42.1m'));
      expect(summary, contains('firstFixFromEnter=-1.2s'));
      // One fix: it is also the deciding one.
      expect(summary, contains('lastFixAge=1.2s'));
      expect(summary, contains('lastFixAccuracy=42.1m'));
      expect(summary, contains('lastFixFromEnter=-1.2s'));
      // Behaviour unchanged: the arrival policy is not part of APP-10F.
      expect(native.notifications.deliveredVisitIds, hasLength(1));
    },
  );

  test('a multi-fix approach reports its first and its deciding fix', () async {
    final native = NativeVerificationFake(start: _at('06:00:00'))
      ..register(_sagula);
    await native.enter(_sagula.id, _at('06:01:34.689'));
    await native.fix(_sagula.north(250), _at('06:01:35'), accuracy: 6.6);
    await native.fixes(_sagula.north(150), _at('06:01:37'), 2);
    // Delivered 0.5 s after it was taken.
    await native.fix(
      _sagula.north(74.9),
      _at('06:01:42.5'),
      takenAt: _at('06:01:42'),
      accuracy: 1.5,
    );

    final summary = _summary(native, _sagula.id);
    expect(summary, contains('samples=4'));
    expect(summary, contains('firstFixAge=0.0s'));
    expect(summary, contains('firstFixAccuracy=6.6m'));
    expect(summary, contains('firstFixFromEnter=0.3s'));
    expect(summary, contains('lastFixAge=0.5s'));
    expect(summary, contains('lastFixAccuracy=1.5m'));
    expect(summary, contains('lastFixFromEnter=7.3s'));
  });

  test(
    'each place keeps its own evidence when two approaches overlap',
    () async {
      final native = NativeVerificationFake(start: _at('06:00:00'))
        ..register(_delek)
        ..register(_sagula);
      await native.enter(_delek.id, _at('06:01:00'));
      await native.enter(_sagula.id, _at('06:01:01'));
      // Every fix is routed to both places.
      await native.fix(_delek.north(40), _at('06:01:02'), accuracy: 9.0);
      await native.fix(_sagula.north(40), _at('06:01:04'), accuracy: 3.0);

      final delek = _summary(native, _delek.id);
      final sagula = _summary(native, _sagula.id);
      expect(delek, contains('firstFixFromEnter=2.0s'));
      expect(delek, contains('lastFixAccuracy=9.0m'));
      expect(sagula, contains('firstFixFromEnter=1.0s'));
      expect(sagula, contains('firstFixAccuracy=9.0m'));
      expect(sagula, contains('lastFixFromEnter=3.0s'));
      expect(sagula, contains('lastFixAccuracy=3.0m'));
    },
  );

  test(
    'an exit-confirmed pass reports the fix that confirmed the exit',
    () async {
      final native = NativeVerificationFake(start: _at('06:00:00'))
        ..register(_sagula);
      await native.enter(_sagula.id, _at('06:01:34'));
      await native.fix(_sagula.north(200), _at('06:01:36'), accuracy: 4.0);
      await native.exit(_sagula.id, _at('06:02:39'));
      await native.fix(_sagula.north(420), _at('06:02:40'), accuracy: 2.0);

      final summary = _summary(native, _sagula.id);
      expect(summary, contains('outcome=EXIT_CONFIRMED'));
      expect(summary, contains('firstFixFromEnter=2.0s'));
      expect(summary, contains('lastFixAccuracy=2.0m'));
      expect(summary, contains('lastFixFromEnter=66.0s'));
      expect(native.notifications.deliveredVisitIds, isEmpty);
      expect(
        native.runtime.placeSnapshots[_sagula.id]!.state,
        DetectionState.armed,
      );
    },
  );
}
