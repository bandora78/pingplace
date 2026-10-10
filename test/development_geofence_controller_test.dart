import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/geofence/development_geofence_controller.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';

final class FakeGeofenceService implements GeofenceService {
  final StreamController<GeofenceEvent> eventsController =
      StreamController<GeofenceEvent>.broadcast();
  GeofencePermissionStatus status = GeofencePermissionStatus.backgroundAllowed;
  bool registered = false;

  @override
  Stream<GeofenceEvent> get events => eventsController.stream;

  @override
  Future<GeofencePermissionStatus> checkPermission() async => status;

  @override
  Future<GeofencePermissionStatus> requestPermission() async => status;

  @override
  Future<bool> get registrationStatus async => registered;

  @override
  Future<void> register({
    required double latitude,
    required double longitude,
    required double radius,
  }) async {
    registered = true;
  }

  @override
  Future<void> remove() async {
    registered = false;
  }

  @override
  void dispose() {
    eventsController.close();
  }
}

void main() {
  test(
    'real ENTER translates to the existing engine OuterEnter path',
    () async {
      final service = FakeGeofenceService();
      final controller = DevelopmentGeofenceController(service: service);
      await controller.initialize();
      await controller.register();

      service.eventsController.add(
        GeofenceEvent(
          type: GeofenceEventType.enter,
          at: DateTime.utc(2026, 10, 10, 12),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.registered, isTrue);
      expect(controller.state, DetectionState.approaching);
      expect(
        controller.eventLog.any(
          (entry) => entry.contains('OUTER_ENTER_RECEIVED'),
        ),
        isTrue,
      );
      controller.dispose();
    },
  );

  test('permission missing is visible and blocks registration', () async {
    final service = FakeGeofenceService()
      ..status = GeofencePermissionStatus.foregroundOnly;
    final controller = DevelopmentGeofenceController(service: service);
    await controller.initialize();
    await controller.register();

    expect(controller.registered, isFalse);
    expect(controller.lastError, contains('Background location'));
    expect(
      controller.eventLog.any((entry) => entry.contains('PERMISSION_MISSING')),
      isTrue,
    );
    controller.dispose();
  });

  test('real EXIT translates to OuterExit and returns to armed', () async {
    final service = FakeGeofenceService();
    final controller = DevelopmentGeofenceController(service: service);
    await controller.initialize();
    await controller.register();
    service.eventsController.add(
      GeofenceEvent(
        type: GeofenceEventType.enter,
        at: DateTime.utc(2026, 1, 1),
      ),
    );
    service.eventsController.add(
      GeofenceEvent(
        type: GeofenceEventType.exit,
        at: DateTime.utc(2026, 1, 1, 0, 1),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, DetectionState.armed);
    expect(
      controller.eventLog.any((entry) => entry.contains('OUTER_EXIT_RECEIVED')),
      isTrue,
    );
    controller.dispose();
  });

  test(
    'platform error is visible and cannot move armed engine to approaching',
    () async {
      final service = FakeGeofenceService();
      final controller = DevelopmentGeofenceController(service: service);
      await controller.initialize();
      await controller.register();

      service.eventsController.add(
        GeofenceEvent(
          type: GeofenceEventType.error,
          at: DateTime.utc(2026, 1, 1),
          error: 'Unsupported geofence transition 99',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, DetectionState.armed);
      expect(controller.lastError, contains('Unsupported geofence transition'));
      expect(
        controller.eventLog.any(
          (entry) => entry.contains('GEOFENCE_EVENT_FAILED'),
        ),
        isTrue,
      );
      controller.dispose();
    },
  );

  test(
    'unknown platform event is treated as an error, never as ENTER',
    () async {
      final service = FakeGeofenceService();
      final controller = DevelopmentGeofenceController(service: service);
      await controller.initialize();
      await controller.register();

      service.eventsController.add(
        GeofenceEvent(
          type: GeofenceEventType.error,
          at: DateTime.utc(2026, 1, 1),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, DetectionState.armed);
      expect(controller.lastError, contains('Unknown geofence event'));
      controller.dispose();
    },
  );
}
