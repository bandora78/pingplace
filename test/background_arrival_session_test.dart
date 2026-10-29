import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/background/background_arrival_session.dart';
import 'package:pingplace/src/background/multi_place_background_arrival_session.dart';
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
  test('ENTER without an accurate inner sample does not notify', () async {
    final diagnostics = <String>[];
    final notifications = InMemoryNotificationService();
    final session = BackgroundArrivalSession(
      onDiagnostic: diagnostics.add,
      onCommand: (_) async {},
      runtimeStore: InMemoryArrivalRuntimeStore(),
      notificationService: notifications,
    );

    await session.handleEvent({
      'type': 'enter',
      'targetLatitude': 32.0,
      'targetLongitude': 34.8,
      'timestamp': DateTime.utc(2026, 10, 27, 13).toIso8601String(),
    });
    await session.handleEvent({'type': 'exit'});

    expect(notifications.deliveredVisitIds, isEmpty);
    expect(diagnostics, contains('BACKGROUND_ENTER_RECEIVED'));
    expect(diagnostics, contains('PRECISE_LOCATION_STARTED'));
    expect(diagnostics, contains('BACKGROUND_EXIT_RECEIVED'));
    session.dispose();
  });

  test('literal null background failure detail is diagnosed without null', () async {
    final diagnostics = <String>[];
    final session = BackgroundArrivalSession(
      onDiagnostic: diagnostics.add,
      onCommand: (_) async {},
      runtimeStore: InMemoryArrivalRuntimeStore(),
      notificationService: InMemoryNotificationService(),
    );

    await session.handleEvent({'type': 'error', 'error': 'null'});

    expect(
      diagnostics,
      contains('BACKGROUND_EVENT_FAILED: MISSING_ERROR_DETAIL'),
    );
    expect(diagnostics, isNot(contains('null')));
    session.dispose();
  });
  test('valid background failure detail is preserved', () async {
    final diagnostics = <String>[];
    final session = BackgroundArrivalSession(
      onDiagnostic: diagnostics.add,
      onCommand: (_) async {},
      runtimeStore: InMemoryArrivalRuntimeStore(),
      notificationService: InMemoryNotificationService(),
    );

    await session.handleEvent({
      'type': 'error',
      'error': 'GEOFENCE_EVENT_FAILED: registration lost',
    });

    expect(
      diagnostics,
      contains(
        'BACKGROUND_EVENT_FAILED: GEOFENCE_EVENT_FAILED: registration lost',
      ),
    );
    expect(diagnostics, isNot(contains('MISSING_ERROR_DETAIL')));
    session.dispose();
  });
  test('headless multi-place routing persists independent state and notifications', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService();
    final session = MultiPlaceBackgroundArrivalSession(
      onDiagnostic: (_) {},
      onCommand: (_) async {},
      runtimeStore: runtime,
      notificationService: notifications,
    );
    final at = DateTime.utc(2026, 10, 10, 12);

    for (final place in [
      ('home', 32.0, 34.8, 'Home reminder'),
      ('work', 32.01, 34.8, 'Work reminder'),
    ]) {
      await session.handleEvent({
        'type': 'enter',
        'placeId': place.$1,
        'targetLatitude': place.$2,
        'targetLongitude': place.$3,
        'reminderText': place.$4,
        'timestamp': at.toIso8601String(),
      });
      await session.handleEvent({
        'type': 'location',
        'placeId': place.$1,
        'latitude': place.$2 + 0.00063,
        'longitude': place.$3,
        'accuracy': 10.0,
        'timestamp': at.add(const Duration(minutes: 1)).toIso8601String(),
      });
    }

    expect(runtime.placeSnapshots.keys, containsAll(<String>['home', 'work']));
    expect(runtime.placeSnapshots['home']?.state, DetectionState.cooldown);
    expect(runtime.placeSnapshots['work']?.state, DetectionState.cooldown);
    expect(notifications.deliveredVisitIds, hasLength(2));
    expect(notifications.deliveredVisitIds.toSet(), hasLength(2));
    session.dispose();
  });

}

