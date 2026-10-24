import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';

void main() {
  const target = TargetLocation(latitude: 32.000000, longitude: 34.800000);

  SmartArrivalDetectionEngine createEngine({
    Duration cooldown = const Duration(minutes: 10),
    Duration timeout = const Duration(minutes: 10),
    double maxAccuracy = 50,
  }) {
    return SmartArrivalDetectionEngine(
      SmartArrivalConfig(
        target: target,
        cooldownDuration: cooldown,
        approachTimeout: timeout,
        maxAcceptedAccuracy: maxAccuracy,
      ),
    );
  }

  LocationSample sampleAtMeters(
    double meters, {
    required DateTime at,
    double accuracy = 10,
  }) {
    return LocationSample(
      latitude: target.latitude + meters / 111320,
      longitude: target.longitude,
      accuracy: accuracy,
      timestamp: at,
    );
  }

  test('successful arrival confirms once and enters cooldown', () {
    final engine = createEngine();
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(const OuterEnter());
    final result = engine.dispatch(
      LocationReceived(sampleAtMeters(70, at: at)),
    );

    expect(result.state, DetectionState.cooldown);
    expect(result.contains(DetectionEffectType.innerReached), isTrue);
    expect(result.contains(DetectionEffectType.notificationRequested), isTrue);
    expect(engine.cooldownUntil, at.add(const Duration(minutes: 10)));
  });

  test('nearby pass exits approach without notification', () {
    final engine = createEngine();
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(const OuterEnter());
    final result = engine.dispatch(
      LocationReceived(sampleAtMeters(320, at: at)),
    );

    expect(result.state, DetectionState.armed);
    expect(result.contains(DetectionEffectType.notificationRequested), isFalse);
    expect(result.contains(DetectionEffectType.preciseLocationStopped), isTrue);
  });

  test('GPS jitter does not create a duplicate notification', () {
    final engine = createEngine();
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(const OuterEnter());
    final first = engine.dispatch(LocationReceived(sampleAtMeters(70, at: at)));
    final jitter = engine.dispatch(
      LocationReceived(
        sampleAtMeters(60, at: at.add(const Duration(minutes: 1))),
      ),
    );

    expect(
      first.effects.where(
        (e) => e.type == DetectionEffectType.notificationRequested,
      ),
      hasLength(1),
    );
    expect(jitter.contains(DetectionEffectType.notificationRequested), isFalse);
    expect(engine.state, DetectionState.cooldown);
  });

  test('cooldown waits for exit when it expires inside the target area', () {
    final engine = createEngine();
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(const OuterEnter());
    engine.dispatch(LocationReceived(sampleAtMeters(70, at: at)));
    final result = engine.dispatch(
      CooldownElapsed(at.add(const Duration(minutes: 10))),
    );

    expect(result.state, DetectionState.waitingForExit);
  });

  test(
    'repeated inner samples after cooldown expiry cannot notify before exit',
    () {
      final engine = createEngine();
      final at = DateTime.utc(2026, 10, 10, 12);

      engine.dispatch(const Arm());
      engine.dispatch(OuterEnter(at: at));
      final arrival = engine.dispatch(
        LocationReceived(sampleAtMeters(70, at: at)),
      );
      expect(
        arrival.contains(DetectionEffectType.notificationRequested),
        isTrue,
      );

      final expired = engine.dispatch(
        CooldownElapsed(at.add(const Duration(minutes: 10))),
      );
      expect(expired.state, DetectionState.waitingForExit);

      final distances = [70.0, 60.0, 40.0];
      for (var index = 0; index < distances.length; index++) {
        final result = engine.dispatch(
          LocationReceived(
            sampleAtMeters(
              distances[index],
              at: at.add(Duration(minutes: 11 + index)),
            ),
          ),
        );

        expect(result.contains(DetectionEffectType.locationSample), isTrue);
        expect(result.contains(DetectionEffectType.locationRejected), isFalse);
        expect(result.state, DetectionState.waitingForExit);
        expect(
          result.contains(DetectionEffectType.notificationRequested),
          isFalse,
        );
      }
    },
  );

  test('exit during cooldown allows immediate rearm at cooldown expiry', () {
    final engine = createEngine();
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(const OuterEnter());
    engine.dispatch(LocationReceived(sampleAtMeters(70, at: at)));
    final exit = engine.dispatch(
      LocationReceived(
        sampleAtMeters(360, at: at.add(const Duration(minutes: 2))),
      ),
    );
    final expired = engine.dispatch(
      CooldownElapsed(at.add(const Duration(minutes: 10))),
    );

    expect(
      exit.contains(DetectionEffectType.exitObservedDuringCooldown),
      isTrue,
    );
    expect(expired.state, DetectionState.armed);
    expect(engine.exitObservedDuringCooldown, isFalse);
  });

  test('waiting for exit rearms only after hysteresis radius is crossed', () {
    final engine = createEngine();
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(const OuterEnter());
    engine.dispatch(LocationReceived(sampleAtMeters(70, at: at)));
    engine.dispatch(CooldownElapsed(at.add(const Duration(minutes: 10))));
    engine.dispatch(
      LocationReceived(
        sampleAtMeters(340, at: at.add(const Duration(minutes: 11))),
      ),
    );
    expect(engine.state, DetectionState.waitingForExit);

    final result = engine.dispatch(
      LocationReceived(
        sampleAtMeters(360, at: at.add(const Duration(minutes: 12))),
      ),
    );
    expect(result.state, DetectionState.armed);
  });

  test('poor accuracy is explicitly rejected and cannot confirm arrival', () {
    final engine = createEngine(maxAccuracy: 25);
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(const OuterEnter());
    final result = engine.dispatch(
      LocationReceived(sampleAtMeters(40, at: at, accuracy: 26)),
    );

    expect(result.state, DetectionState.approaching);
    expect(result.contains(DetectionEffectType.locationSample), isTrue);
    expect(result.contains(DetectionEffectType.locationRejected), isTrue);
    expect(result.contains(DetectionEffectType.notificationRequested), isFalse);
  });

  test('approach timeout returns to armed and stops precise location', () {
    final engine = createEngine(timeout: const Duration(minutes: 10));
    final enteredAt = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(OuterEnter(at: enteredAt));
    final result = engine.dispatch(
      ApproachTimedOut(enteredAt.add(const Duration(minutes: 10))),
    );

    expect(result.state, DetectionState.armed);
    expect(result.contains(DetectionEffectType.approachTimeout), isTrue);
    expect(result.contains(DetectionEffectType.preciseLocationStopped), isTrue);
  });

  test('reset clears cooldown and returns the test to armed', () {
    final engine = createEngine();
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(const OuterEnter());
    engine.dispatch(LocationReceived(sampleAtMeters(70, at: at)));
    final result = engine.dispatch(const ResetTest());

    expect(result.state, DetectionState.armed);
    expect(engine.cooldownUntil, isNull);
    expect(engine.exitObservedDuringCooldown, isFalse);
  });

  test('rearm crossing uses its explicit timestamp deterministically', () {
    final engine = createEngine();
    final at = DateTime(2026, 10, 10, 12);

    engine.dispatch(const Arm());
    engine.dispatch(OuterEnter(at: at));
    engine.dispatch(LocationReceived(sampleAtMeters(70, at: at)));
    engine.dispatch(RearmRadiusCrossed(at.add(const Duration(minutes: 2))));

    expect(engine.state, DetectionState.cooldown);
    expect(engine.exitObservedDuringCooldown, isTrue);

    final result = engine.dispatch(
      CooldownElapsed(at.add(const Duration(minutes: 10))),
    );
    expect(result.state, DetectionState.armed);
  });
}
