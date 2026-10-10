import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/simulation/development_simulation_controller.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';

void main() {
  SimulationController createController() {
    return SimulationController(
      config: const SmartArrivalConfig(
        target: TargetLocation(latitude: 32, longitude: 34.8),
      ),
      initialTime: DateTime.utc(2026, 1, 1, 12),
    );
  }

  test('simulation controls drive the existing engine to arrival', () {
    final controller = createController();

    controller.armTest();
    controller.simulateOuterEnter();
    controller.simulateLocation(70);

    expect(controller.state, DetectionState.cooldown);
    expect(controller.lastDistance, 70);
    expect(controller.lastAccuracy, 10);
    expect(controller.preciseLocationActive, isFalse);
    expect(controller.notificationRequested, isTrue);
    expect(
      controller.eventLog.any(
        (entry) => entry.contains('NOTIFICATION_REQUESTED (simulation only)'),
      ),
      isTrue,
    );
  });

  test('simulation can exercise exit during cooldown and rearm', () {
    final controller = createController();

    controller.armTest();
    controller.simulateOuterEnter();
    controller.simulateLocation(70);
    controller.simulateExit();
    controller.advanceOrExpireCooldown();

    expect(controller.state, DetectionState.armed);
    expect(
      controller.eventLog.any(
        (entry) => entry.contains('EXIT_OBSERVED_DURING_COOLDOWN'),
      ),
      isTrue,
    );
  });

  test('simulation clock advances explicitly for approach timeout', () {
    final controller = createController();
    final start = controller.clock;

    controller.armTest();
    controller.simulateOuterEnter();
    controller.simulateApproachTimeout();

    expect(controller.state, DetectionState.armed);
    expect(controller.clock, start.add(const Duration(minutes: 10)));
    expect(
      controller.eventLog.any((entry) => entry.contains('APPROACH_TIMEOUT')),
      isTrue,
    );
  });

  test('reset clears simulation notification and runtime display values', () {
    final controller = createController();

    controller.armTest();
    controller.simulateOuterEnter();
    controller.simulateLocation(70);
    controller.resetTest();

    expect(controller.state, DetectionState.armed);
    expect(controller.notificationRequested, isFalse);
    expect(controller.lastDistance, isNull);
    expect(controller.lastAccuracy, isNull);
    expect(controller.clock, DateTime.utc(2026, 1, 1));
  });
}
