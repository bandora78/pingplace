import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/geofence/development_geofence_controller.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/home/pingplace_home_screen.dart';
import 'package:pingplace/src/location/location_service.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

final class HomeFakeGeofenceService implements GeofenceService {
  final eventsController = StreamController<GeofenceEvent>.broadcast();
  int eventsReadCount = 0;
  bool registered = false;
  GeofenceRegistration? savedRegistration;
  Object? registerError;

  @override
  Stream<GeofenceEvent> get events {
    eventsReadCount++;
    return eventsController.stream;
  }

  @override
  Future<GeofencePermissionStatus> checkPermission() async =>
      GeofencePermissionStatus.backgroundAllowed;

  @override
  Future<GeofencePermissionStatus> requestPermission() async =>
      GeofencePermissionStatus.backgroundAllowed;

  @override
  Future<bool> get registrationStatus async => registered;

  @override
  Future<GeofenceRegistration?> get desiredRegistration async =>
      savedRegistration;

  @override
  Future<bool> get desiredMonitoring async => registered;


  @override
  Future<GeofenceRegistration?> get registration async => savedRegistration;

  @override
  Future<GeofenceRecoveryStatus> get recoveryStatus async =>
      const GeofenceRecoveryStatus();

  @override
  Future<bool> restoreRegistration() async => registered;

  @override
  Future<void> register({
    required double latitude,
    required double longitude,
    required double radius,
    String? reminderText,
  }) async {
    if (registerError != null) throw registerError!;
    registered = true;
    savedRegistration = GeofenceRegistration(
      latitude: latitude,
      longitude: longitude,
      radius: radius,
    );
  }

  @override
  Future<void> remove() async => registered = false;

  @override
  void dispose() {
    unawaited(eventsController.close());
  }
}

final class HomeFakeLocationService implements LocationService {
  final eventsController = StreamController<LocationServiceEvent>.broadcast();

  @override
  Stream<LocationServiceEvent> get events => eventsController.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() => unawaited(eventsController.close());
}

final class FailingReminderStore implements ArrivalRuntimeStore {
  DetectionRuntimeSnapshot? snapshot = const DetectionRuntimeSnapshot(
    state: DetectionState.disarmed,
    target: TargetLocation(latitude: 32, longitude: 34.8),
  );
  String reminderText = 'תזכורת קיימת';

  @override
  Future<DetectionRuntimeSnapshot?> load() async => snapshot;

  @override
  Future<void> save(DetectionRuntimeSnapshot value) async => snapshot = value;

  @override
  Future<void> clear() async => snapshot = null;

  @override
  Future<String> loadReminderText() async => reminderText;

  @override
  Future<void> saveReminderText(String value) async {
    throw StateError('reminder persistence unavailable');
  }
}

DevelopmentGeofenceController createController({
  HomeFakeGeofenceService? service,
  InMemoryArrivalRuntimeStore? store,
}) {
  return DevelopmentGeofenceController(
    service: service ?? HomeFakeGeofenceService(),
    locationService: HomeFakeLocationService(),
    notificationService: InMemoryNotificationService(),
    runtimeStore: store ?? InMemoryArrivalRuntimeStore(),
  );
}

void main() {
  testWidgets('production home hides developer controls', (tester) async {
    final controller = createController();
    await tester.pumpWidget(
      MaterialApp(home: PingPlaceHomeScreen(controller: controller)),
    );

    expect(find.text('היעד הפעיל'), findsOneWidget);
    expect(find.textContaining('SIMULATE OUTER ENTER'), findsNothing);
    expect(find.text('EVENT LOG'), findsNothing);

    controller.dispose();
  });

  testWidgets('deliberate version gesture opens Developer Mode', (
    tester,
  ) async {
    final controller = createController();
    await tester.pumpWidget(
      MaterialApp(home: PingPlaceHomeScreen(controller: controller)),
    );

    final version = find.byKey(const Key('developer-mode-gesture'));
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump();
    await tester.longPress(version);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('PingPlace · Simulation Mode'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('real controller survives production screen navigation', (
    tester,
  ) async {
    final service = HomeFakeGeofenceService();
    final controller = createController(service: service);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(home: PingPlaceHomeScreen(controller: controller)),
    );
    await tester.pump();
    expect(service.eventsReadCount, 1);

    final version = find.byKey(const Key('developer-mode-gesture'));
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump();
    await tester.longPress(version);
    await tester.pump(const Duration(milliseconds: 500));
    expect(service.eventsReadCount, 1);

    controller.dispose();
  });

  test('invalid target input does not mutate or persist the active target', () async {
    final service = HomeFakeGeofenceService();
    final store = InMemoryArrivalRuntimeStore();
    final controller = createController(service: service, store: store);
    await controller.initialize();

    final result = await controller.registerTarget(
      targetLatitude: 91,
      targetLongitude: 34.8,
      targetRadius: 300,
      targetReminderText: 'חדש',
    );

    expect(result, isFalse);
    expect(controller.latitude, 32);
    expect(controller.longitude, 34.8);
    expect(controller.reminderText, store.reminderText);
    expect(service.registered, isFalse);
    controller.dispose();
  });

  test('failed platform registration preserves the previously saved target', () async {
    final service = HomeFakeGeofenceService()
      ..registerError = StateError('platform unavailable');
    final store = InMemoryArrivalRuntimeStore()..reminderText = 'תזכורת קיימת';
    final controller = createController(service: service, store: store);
    await controller.initialize();
    controller
      ..latitude = 31.664913
      ..longitude = 34.8
      ..radius = 300;
    await controller.registerTarget(
      targetLatitude: 31.7,
      targetLongitude: 34.9,
      targetRadius: 250,
      targetReminderText: 'תזכורת חדשה',
    );

    expect(controller.latitude, 31.664913);
    expect(controller.longitude, 34.8);
    expect(controller.radius, 300);
    expect(controller.reminderText, 'תזכורת קיימת');
    expect(store.reminderText, 'תזכורת קיימת');
    expect(controller.registered, isFalse);
    expect(controller.lastError, contains('GEOFENCE_REGISTRATION_FAILED'));
    controller.dispose();
  });

  test(
    'failed reminder persistence rolls back the new registration and snapshot',
    () async {
      final service = HomeFakeGeofenceService();
      final store = FailingReminderStore();
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: HomeFakeLocationService(),
        notificationService: InMemoryNotificationService(),
        runtimeStore: store,
      );
      await controller.initialize();

      final result = await controller.registerTarget(
        targetLatitude: 31.7,
        targetLongitude: 34.9,
        targetRadius: 250,
        targetReminderText: 'תזכורת חדשה',
      );

      expect(result, isFalse);
      expect(service.registered, isFalse);
      expect(controller.latitude, 32);
      expect(controller.longitude, 34.8);
      expect(controller.reminderText, 'תזכורת קיימת');
      expect(
        store.snapshot?.target,
        const TargetLocation(latitude: 32, longitude: 34.8),
      );
      expect(controller.lastError, contains('REGISTRATION_ROLLBACK_FAILED'));
      controller.dispose();
    },
  );

  test('initialization is idempotent and preserves the saved target', () async {
    final service = HomeFakeGeofenceService();
    final store = InMemoryArrivalRuntimeStore()
      ..snapshot = const DetectionRuntimeSnapshot(
        state: DetectionState.armed,
        target: TargetLocation(latitude: 31.664913, longitude: 34.8),
      );
    final controller = createController(service: service, store: store);

    await Future.wait([controller.initialize(), controller.initialize()]);

    expect(service.eventsReadCount, 1);
    expect(controller.latitude, 31.664913);
    expect(controller.longitude, 34.8);
    expect(controller.state, DetectionState.armed);

    controller.dispose();
  });
}
