import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/background/background_arrival_session.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

void main() {
  test(
    'cold background ENTER starts the same pure engine verification path',
    () async {
      final diagnostics = <String>[];
      final commands = <String>[];
      final runtime = InMemoryArrivalRuntimeStore();
      final session = BackgroundArrivalSession(
        onDiagnostic: diagnostics.add,
        onCommand: (command) async => commands.add(command),
        runtimeStore: runtime,
        notificationService: InMemoryNotificationService(),
      );
      final enteredAt = DateTime.utc(2026, 10, 10, 12);

      await session.handleEvent({
        'type': 'enter',
        'targetLatitude': 32.0,
        'targetLongitude': 34.8,
        'timestamp': enteredAt.toIso8601String(),
      });

      expect(diagnostics, contains(contains('BACKGROUND_SESSION_RESTORED')));

      expect(session.engine?.state, DetectionState.approaching);
      expect(diagnostics, contains('PRECISE_LOCATION_STARTED'));
      expect(commands, isEmpty);

      await session.handleEvent({
        'type': 'location',
        'latitude': 32.00063,
        'longitude': 34.8,
        'accuracy': 10.0,
        'timestamp': enteredAt
            .add(const Duration(minutes: 1))
            .toIso8601String(),
      });

      expect(session.engine?.state, DetectionState.cooldown);
      expect(diagnostics, contains('INNER_REACHED'));
      expect(commands, contains('stop'));
      session.dispose();
    },
  );

  test(
    'cold background EXIT returns the shared engine to armed and stops service',
    () async {
      final commands = <String>[];
      final runtime = InMemoryArrivalRuntimeStore();
      final session = BackgroundArrivalSession(
        onDiagnostic: (_) {},
        onCommand: (command) async => commands.add(command),
        runtimeStore: runtime,
        notificationService: InMemoryNotificationService(),
      );
      final enteredAt = DateTime.utc(2026, 10, 10, 12);
      await session.handleEvent({
        'type': 'enter',
        'targetLatitude': 32.0,
        'targetLongitude': 34.8,
        'timestamp': enteredAt.toIso8601String(),
      });
      await session.handleEvent({'type': 'exit'});

      expect(session.engine?.state, DetectionState.armed);
      expect(commands, contains('stop'));
      session.dispose();
    },
  );
}
