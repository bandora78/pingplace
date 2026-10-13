import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/geofence/development_geofence_controller.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/location/location_service.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

final class FakeGeofenceService implements GeofenceService {
  final StreamController<GeofenceEvent> eventsController =
      StreamController<GeofenceEvent>.broadcast();
  GeofencePermissionStatus status = GeofencePermissionStatus.backgroundAllowed;
  bool registered = false;
  GeofenceRegistration? savedRegistration;
  GeofenceRecoveryStatus recovery = const GeofenceRecoveryStatus();
  int restoreCount = 0;
  int activeRestoreCount = 0;
  int maxActiveRestoreCount = 0;
  Duration restoreDelay = Duration.zero;

  @override
  Stream<GeofenceEvent> get events => eventsController.stream;

  @override
  Future<GeofencePermissionStatus> checkPermission() async => status;

  @override
  Future<GeofencePermissionStatus> requestPermission() async => status;

  @override
  Future<bool> get registrationStatus async => registered;

  @override
  Future<GeofenceRegistration?> get registration async => savedRegistration;

  @override
  Future<GeofenceRecoveryStatus> get recoveryStatus async => recovery;

  @override
  Future<GeofenceDiagnosticsSnapshot> get diagnostics async =>
      const GeofenceDiagnosticsSnapshot();

  @override
  Future<void> clearDiagnostics() async {}

  @override
  Future<void> shareDiagnostics(String report) async {}

  @override
  Future<bool> restoreRegistration() async {
    restoreCount++;
    activeRestoreCount++;
    if (activeRestoreCount > maxActiveRestoreCount) {
      maxActiveRestoreCount = activeRestoreCount;
    }
    await Future<void>.delayed(restoreDelay);
    registered = recovery.registrationConfirmed;
    activeRestoreCount--;
    return registered;
  }

  @override
  Future<void> register({
    required double latitude,
    required double longitude,
    required double radius,
    String? reminderText,
  }) async {
    registered = true;
    savedRegistration = GeofenceRegistration(
      latitude: latitude,
      longitude: longitude,
      radius: radius,
    );
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

final class FakeLocationService implements LocationService {
  final StreamController<LocationServiceEvent> eventsController =
      StreamController<LocationServiceEvent>.broadcast();
  int startCount = 0;
  int stopCount = 0;
  Object? startError;

  @override
  Stream<LocationServiceEvent> get events => eventsController.stream;

  @override
  Future<void> start() async {
    startCount++;
    if (startError != null) throw startError!;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  void dispose() {
    eventsController.close();
  }
}

GeofenceEvent enterEvent([DateTime? at]) =>
    GeofenceEvent(type: GeofenceEventType.enter, at: at ?? DateTime.now());

LocationServiceEvent locationEvent(
  double meters, {
  double accuracy = 10,
  DateTime? at,
}) {
  const target = TargetLocation(latitude: 32, longitude: 34.8);
  return LocationServiceEvent.sample(
    LocationSample(
      latitude: target.latitude + meters / 111320,
      longitude: target.longitude,
      accuracy: accuracy,
      timestamp: at ?? DateTime.now(),
    ),
  );
}

void main() {
  test(
    'manual recovery is visible and does not alter detection state',
    () async {
      final service = FakeGeofenceService()
        ..recovery = const GeofenceRecoveryStatus(registrationConfirmed: true);
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: FakeLocationService(),
      );
      await controller.initialize();
      await controller.restoreGeofence();

      expect(service.restoreCount, 1);
      expect(controller.registered, isTrue);
      expect(controller.state, DetectionState.disarmed);
      expect(controller.eventLog, contains(contains('GEOFENCE_RESTORED')));
      controller.dispose();
    },
  );

  test('recovery failure is surfaced without creating an arrival', () async {
    final service = FakeGeofenceService()
      ..recovery = const GeofenceRecoveryStatus(
        registrationConfirmed: false,
        lastRecoveryFailure: 'Location services are disabled',
      );
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: FakeLocationService(),
    );
    await controller.initialize();
    await controller.restoreGeofence();

    expect(controller.registered, isFalse);
    expect(controller.state, DetectionState.disarmed);
    expect(controller.eventLog, contains(contains('BOOT_RECOVERY_FAILED')));
    controller.dispose();
  });

  test('recovery requires background location permission', () async {
    final service = FakeGeofenceService()
      ..status = GeofencePermissionStatus.foregroundOnly;
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: FakeLocationService(),
    );
    await controller.initialize();
    await controller.restoreGeofence();

    expect(service.restoreCount, 0);
    expect(controller.lastError, contains('background location permission'));
    expect(controller.state, DetectionState.disarmed);
    controller.dispose();
  });

  test('repeated recovery actions are serialized', () async {
    final service = FakeGeofenceService()
      ..recovery = const GeofenceRecoveryStatus(registrationConfirmed: true)
      ..restoreDelay = const Duration(milliseconds: 10);
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: FakeLocationService(),
    );
    await controller.initialize();

    await Future.wait([
      controller.restoreGeofence(),
      controller.restoreGeofence(),
    ]);

    expect(service.restoreCount, 2);
    expect(service.maxActiveRestoreCount, 1);
    controller.dispose();
  });

  test('first initialization keeps default coordinates in sync', () async {
    final controller = DevelopmentGeofenceController(
      service: FakeGeofenceService(),
      locationService: FakeLocationService(),
    );

    await controller.initialize();

    expect(controller.initialized, isTrue);
    expect(controller.latitude, 32);
    expect(controller.longitude, 34.8);
    controller.dispose();
  });

  test('restored registration coordinates are exposed consistently', () async {
    final service = FakeGeofenceService()
      ..registered = true
      ..savedRegistration = const GeofenceRegistration(
        latitude: 31.664913,
        longitude: 34.8,
        radius: 300,
      );
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: FakeLocationService(),
    );

    await controller.initialize();

    expect(controller.latitude, 31.664913);
    expect(controller.longitude, 34.8);
    expect(controller.radius, 300);
    controller.dispose();
  });

  test(
    'invalid coordinates are rejected before geofence registration',
    () async {
      final service = FakeGeofenceService();
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: FakeLocationService(),
      );
      await controller.initialize();

      controller.latitude = 310000000;
      await controller.register();

      expect(service.registered, isFalse);
      expect(controller.lastError, contains('latitude must be between'));
      controller.dispose();
    },
  );

  test(
    'real ENTER translates to the existing engine OuterEnter path',
    () async {
      final service = FakeGeofenceService();
      final location = FakeLocationService();
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: location,
      );
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
      expect(location.startCount, 1);
      expect(controller.preciseLocationActive, isTrue);
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
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: FakeLocationService(),
    );
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
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: FakeLocationService(),
    );
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
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: FakeLocationService(),
      );
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
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: FakeLocationService(),
      );
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

  test(
    'valid sample outside inner radius remains approaching and active',
    () async {
      final service = FakeGeofenceService();
      final location = FakeLocationService();
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: location,
      );
      await controller.initialize();
      await controller.register();
      service.eventsController.add(enterEvent());
      await Future<void>.delayed(Duration.zero);
      location.eventsController.add(locationEvent(150));
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, DetectionState.approaching);
      expect(controller.preciseLocationActive, isTrue);
      expect(controller.latestDistance, greaterThan(80));
      expect(location.stopCount, 0);
      controller.dispose();
    },
  );

  test(
    'valid inner sample confirms arrival and stops precise location',
    () async {
      final service = FakeGeofenceService();
      final location = FakeLocationService();
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: location,
      );
      await controller.initialize();
      await controller.register();
      service.eventsController.add(enterEvent());
      await Future<void>.delayed(Duration.zero);
      location.eventsController.add(locationEvent(70));
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, DetectionState.cooldown);
      expect(controller.arrivalConfirmed, isTrue);
      expect(
        controller.eventLog.any((entry) => entry.contains('INNER_REACHED')),
        isTrue,
      );
      expect(controller.preciseLocationActive, isFalse);
      expect(location.stopCount, greaterThanOrEqualTo(1));
      controller.dispose();
    },
  );

  test('foreground arrival delivers exactly one notification', () async {
    final service = FakeGeofenceService();
    final location = FakeLocationService();
    final notifications = InMemoryNotificationService();
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: location,
      notificationService: notifications,
      runtimeStore: InMemoryArrivalRuntimeStore(),
    );
    await controller.initialize();
    await controller.register();
    service.eventsController.add(enterEvent(DateTime.utc(2026, 1, 1)));
    await Future<void>.delayed(Duration.zero);
    location.eventsController.add(
      locationEvent(70, at: DateTime.utc(2026, 1, 1, 0, 1)),
    );
    await Future<void>.delayed(Duration.zero);

    expect(notifications.deliveredVisitIds, hasLength(1));
    expect(
      controller.eventLog.any((entry) => entry.contains('NOTIFICATION_SENT')),
      isTrue,
    );
    controller.dispose();
  });

  test(
    'poor accuracy inside inner radius is rejected and remains active',
    () async {
      final service = FakeGeofenceService();
      final location = FakeLocationService();
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: location,
        config: const SmartArrivalConfig(
          target: TargetLocation(latitude: 32, longitude: 34.8),
          maxAcceptedAccuracy: 25,
        ),
      );
      await controller.initialize();
      await controller.register();
      service.eventsController.add(enterEvent());
      await Future<void>.delayed(Duration.zero);
      location.eventsController.add(locationEvent(40, accuracy: 26));
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, DetectionState.approaching);
      expect(controller.arrivalConfirmed, isFalse);
      expect(controller.preciseLocationActive, isTrue);
      expect(
        controller.eventLog.any((entry) => entry.contains('LOW_ACCURACY')),
        isTrue,
      );
      controller.dispose();
    },
  );

  test('outer EXIT while approaching stops precise location', () async {
    final service = FakeGeofenceService();
    final location = FakeLocationService();
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: location,
    );
    await controller.initialize();
    await controller.register();
    service.eventsController.add(enterEvent());
    await Future<void>.delayed(Duration.zero);
    service.eventsController.add(
      GeofenceEvent(type: GeofenceEventType.exit, at: DateTime.now()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, DetectionState.armed);
    expect(controller.preciseLocationActive, isFalse);
    expect(location.stopCount, greaterThanOrEqualTo(1));
    controller.dispose();
  });

  test(
    'approach timeout returns to armed and stops precise location',
    () async {
      final service = FakeGeofenceService();
      final location = FakeLocationService();
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: location,
        config: const SmartArrivalConfig(
          target: TargetLocation(latitude: 32, longitude: 34.8),
          approachTimeout: Duration(milliseconds: 20),
        ),
      );
      await controller.initialize();
      await controller.register();
      service.eventsController.add(enterEvent());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controller.state, DetectionState.armed);
      expect(controller.preciseLocationActive, isFalse);
      expect(
        controller.eventLog.any((entry) => entry.contains('APPROACH_TIMEOUT')),
        isTrue,
      );
      controller.dispose();
    },
  );

  test(
    'location service failure is visible and cannot confirm arrival',
    () async {
      final service = FakeGeofenceService();
      final location = FakeLocationService();
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: location,
      );
      await controller.initialize();
      await controller.register();
      service.eventsController.add(enterEvent());
      await Future<void>.delayed(Duration.zero);
      location.eventsController.add(
        const LocationServiceEvent.failure('location provider unavailable'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.arrivalConfirmed, isFalse);
      expect(controller.state, DetectionState.disarmed);
      expect(controller.lastError, contains('location provider unavailable'));
      controller.dispose();
    },
  );

  test('late location sample after stop is ignored', () async {
    final service = FakeGeofenceService();
    final location = FakeLocationService();
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: location,
    );
    await controller.initialize();
    await controller.register();
    service.eventsController.add(enterEvent());
    await Future<void>.delayed(Duration.zero);
    location.eventsController.add(locationEvent(70));
    await Future<void>.delayed(Duration.zero);
    final arrivalCount = controller.eventLog
        .where((entry) => entry.contains('INNER_REACHED'))
        .length;
    location.eventsController.add(locationEvent(40));
    await Future<void>.delayed(Duration.zero);

    expect(controller.arrivalConfirmed, isTrue);
    expect(
      controller.eventLog.where((entry) => entry.contains('INNER_REACHED')),
      hasLength(arrivalCount),
    );
    controller.dispose();
  });
}
