import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';

const _target = TargetLocation(latitude: 32, longitude: 34.8);
final _t0 = DateTime.utc(2026, 11, 2, 6);

LocationSample _at(double metersNorth, DateTime at, {double accuracy = 8}) =>
    LocationSample(
      latitude: 32 + metersNorth / 111320,
      longitude: 34.8,
      accuracy: accuracy,
      timestamp: at,
    );

SmartArrivalDetectionEngine _approaching(Duration window) {
  final engine = SmartArrivalDetectionEngine(
    SmartArrivalConfig(target: _target, exitConfirmationWindow: window),
  );
  engine.dispatch(const Arm());
  engine.dispatch(OuterEnter(at: _t0));
  expect(engine.state, DetectionState.approaching);
  return engine;
}

void main() {
  group('without a confirmation window (legacy and simulation)', () {
    test('a fix beyond the outer radius still ends the approach', () {
      final engine = _approaching(Duration.zero);
      engine.dispatch(LocationReceived(_at(330, _t0)));
      expect(engine.state, DetectionState.armed);
    });

    test('an outer EXIT still ends the approach immediately', () {
      final engine = _approaching(Duration.zero);
      final result = engine.dispatch(OuterExit(at: _t0));
      expect(engine.state, DetectionState.armed);
      expect(result.contains(DetectionEffectType.exitConfirmed), isFalse);
    });
  });

  group('with a confirmation window', () {
    const window = Duration(seconds: 60);

    test('a fix beyond the outer radius alone keeps verifying', () {
      final engine = _approaching(window);
      final result = engine.dispatch(LocationReceived(_at(330, _t0)));
      expect(engine.state, DetectionState.approaching);
      expect(
        result.contains(DetectionEffectType.preciseLocationStopped),
        false,
      );
    });

    test('EXIT waits; a later inner fix still arrives', () {
      final engine = _approaching(window);
      final exit = engine.dispatch(OuterExit(at: _t0.add(_s(30))));
      expect(exit.contains(DetectionEffectType.exitAwaitingConfirmation), true);
      expect(engine.exitReportedAt, _t0.add(_s(30)));

      final arrival = engine.dispatch(
        LocationReceived(_at(50, _t0.add(_s(33)))),
      );
      expect(arrival.contains(DetectionEffectType.notificationRequested), true);
      expect(engine.state, DetectionState.cooldown);
      expect(engine.exitReportedAt, isNull);
    });

    test('EXIT is confirmed by a fix beyond the outer radius', () {
      final engine = _approaching(window);
      engine.dispatch(OuterExit(at: _t0));
      final result = engine.dispatch(
        LocationReceived(_at(320, _t0.add(_s(4)))),
      );
      expect(result.contains(DetectionEffectType.exitConfirmed), true);
      expect(engine.state, DetectionState.armed);
    });

    test('EXIT after a fix already beyond the outer radius ends at once', () {
      final engine = _approaching(window);
      engine.dispatch(LocationReceived(_at(320, _t0)));
      engine.dispatch(OuterExit(at: _t0.add(_s(2))));
      expect(engine.state, DetectionState.armed);
    });

    test('an inside fix after EXIT does not confirm it', () {
      final engine = _approaching(window);
      engine.dispatch(OuterExit(at: _t0));
      engine.dispatch(LocationReceived(_at(150, _t0.add(_s(5)))));
      expect(engine.state, DetectionState.approaching);
    });

    test('the window elapsing without evidence ends the approach', () {
      final engine = _approaching(window);
      engine.dispatch(OuterExit(at: _t0));
      engine.dispatch(ExitConfirmationElapsed(_t0.add(_s(59))));
      expect(engine.state, DetectionState.approaching);
      final result = engine.dispatch(ExitConfirmationElapsed(_t0.add(_s(60))));
      expect(result.contains(DetectionEffectType.exitConfirmed), true);
      expect(engine.state, DetectionState.armed);
    });

    test('an immediate EXIT ends the approach when nothing can verify', () {
      final engine = _approaching(window);
      engine.dispatch(OuterExit(at: _t0, immediate: true));
      expect(engine.state, DetectionState.armed);
    });

    test('the approach timeout still applies', () {
      final engine = _approaching(window);
      engine.dispatch(ApproachTimedOut(_t0.add(const Duration(minutes: 10))));
      expect(engine.state, DetectionState.armed);
    });
  });

  group('restart approach', () {
    test('restarts verification and the timeout from the new ENTER', () {
      final engine = SmartArrivalDetectionEngine(
        const SmartArrivalConfig(target: _target),
        snapshot: DetectionRuntimeSnapshot(
          state: DetectionState.approaching,
          target: _target,
          approachStartedAt: _t0.subtract(const Duration(hours: 5)),
          visitId: 'visit-1',
        ),
      );
      final result = engine.dispatch(RestartApproach(_t0));
      expect(result.contains(DetectionEffectType.preciseLocationStarted), true);
      expect(engine.approachStartedAt, _t0);
      expect(engine.visitId, 'visit-1');
      engine.dispatch(ApproachTimedOut(_t0.add(const Duration(minutes: 9))));
      expect(engine.state, DetectionState.approaching);
    });

    test('has no effect outside an approach', () {
      for (final state in [
        DetectionState.armed,
        DetectionState.cooldown,
        DetectionState.waitingForExit,
      ]) {
        final engine = SmartArrivalDetectionEngine(
          const SmartArrivalConfig(target: _target),
          snapshot: DetectionRuntimeSnapshot(state: state, target: _target),
        );
        expect(engine.dispatch(RestartApproach(_t0)).effects, isEmpty);
        expect(engine.state, state);
      }
    });
  });
}

Duration _s(int seconds) => Duration(seconds: seconds);
