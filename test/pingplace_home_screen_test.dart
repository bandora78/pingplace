import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/build_info.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/geofence/development_geofence_controller.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/home/pingplace_home_screen.dart';
import 'package:pingplace/src/location/location_service.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/places/place_manager.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

import 'support/place_fakes.dart';

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

  GeofencePermissionStatus checkResult =
      GeofencePermissionStatus.backgroundAllowed;
  GeofencePermissionStatus requestResult =
      GeofencePermissionStatus.backgroundAllowed;
  Object? checkError;

  /// Holds checkPermission until completed, to observe a running refresh.
  Completer<void>? checkHold;
  int checkCount = 0;
  int requestCount = 0;

  @override
  Future<GeofencePermissionStatus> checkPermission() async {
    checkCount++;
    final hold = checkHold;
    if (hold != null) await hold.future;
    if (checkError != null) throw checkError!;
    return checkResult;
  }

  @override
  Future<GeofencePermissionStatus> requestPermission() async {
    requestCount++;
    checkResult = requestResult;
    return requestResult;
  }

  @override
  Future<bool> get registrationStatus async => registered;

  @override
  Future<GeofenceRegistration?> get desiredRegistration async =>
      savedRegistration;

  @override
  Future<bool> get desiredMonitoring async => registered;

  @override
  Future<DesiredMonitoringState> get desiredMonitoringState async => registered
      ? DesiredMonitoringState.enabled
      : savedRegistration != null
      ? DesiredMonitoringState.disabled
      : DesiredMonitoringState.unknown;

  @override
  Future<GeofenceRegistration?> get registration async => savedRegistration;

  @override
  Future<GeofenceRecoveryStatus> get recoveryStatus async =>
      const GeofenceRecoveryStatus();

  @override
  Future<bool> restoreRegistration() async => registered;

  @override
  Stream<void> get statusChanges => const Stream<void>.empty();

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
      MaterialApp(
        home: PingPlaceHomeScreen(
          controller: controller,
          placeManager: PlaceTestRig().manager(),
        ),
      ),
    );

    expect(find.text('המקומות שלי'), findsOneWidget);
    expect(find.text('היעד הפעיל'), findsNothing);
    expect(find.textContaining('SIMULATE OUTER ENTER'), findsNothing);
    expect(find.text('EVENT LOG'), findsNothing);

    controller.dispose();
  });

  testWidgets('deliberate version gesture opens Developer Mode', (
    tester,
  ) async {
    final controller = createController();
    await tester.pumpWidget(
      MaterialApp(
        home: PingPlaceHomeScreen(
          controller: controller,
          placeManager: PlaceTestRig().manager(),
        ),
      ),
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
      MaterialApp(
        home: PingPlaceHomeScreen(
          controller: controller,
          placeManager: PlaceTestRig().manager(),
        ),
      ),
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

  test(
    'invalid target input does not mutate or persist the active target',
    () async {
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
    },
  );

  test(
    'failed platform registration preserves the previously saved target',
    () async {
      final service = HomeFakeGeofenceService()
        ..registerError = StateError('platform unavailable');
      final store = InMemoryArrivalRuntimeStore()
        ..reminderText = 'תזכורת קיימת';
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
    },
  );

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

  group('APP-12 home status', () {
    Future<_Home> pumpHome(
      WidgetTester tester, {
      bool initializeController = true,
      bool initializeManager = true,
      HomeFakeGeofenceService? service,
      _Notifications? notifications,
      PlaceTestRig? rig,
      Future<void> Function(PlaceManager manager)? seed,
    }) async {
      final h = _Home(
        service ?? HomeFakeGeofenceService(),
        notifications ?? _Notifications(),
        rig ?? PlaceTestRig(),
      );
      if (initializeManager) {
        await h.manager.initialize();
        if (seed != null) await seed(h.manager);
      }
      if (initializeController) await h.controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: PingPlaceHomeScreen(
            controller: h.controller,
            placeManager: h.manager,
          ),
        ),
      );
      await tester.pump();
      addTearDown(h.controller.dispose);
      return h;
    }

    Future<void> twoPlaces(PlaceManager manager) async {
      await manager.add(draft(name: 'Home'));
      await manager.add(draft(name: 'Office', latitude: 32.1));
    }

    String title(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('home-status-title'))).data!;

    Future<void> resume(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }

    testWidgets('no permission warning before initialization completes', (
      tester,
    ) async {
      await pumpHome(tester, initializeController: false);
      expect(title(tester), 'בודק מצב המעקב…');
      expect(find.textContaining('נדרשת הרשאת'), findsNothing);
      expect(find.byKey(const Key('home-status-action')), findsNothing);
    });

    testWidgets('active only with every enabled place confirmed', (
      tester,
    ) async {
      final h = await pumpHome(tester, seed: twoPlaces);
      expect(title(tester), 'המעקב פעיל');
      expect(find.text('2 מקומות במעקב'), findsOneWidget);

      // Android has not confirmed the set: never shown as active.
      h.rig.registrar.confirmed = false;
      await h.manager.refresh();
      await tester.pump();
      expect(title(tester), 'ממתין להפעלת המעקב');
      expect(find.text('0 מתוך 2 מקומות פעילים'), findsOneWidget);
    });

    testWidgets('empty and all-disabled are never active', (tester) async {
      final h = await pumpHome(tester);
      expect(title(tester), 'עדיין אין מקומות במעקב');
      await h.manager.add(draft(name: 'Home', enabled: false));
      await tester.pump();
      expect(title(tester), 'כל המקומות כבויים');
    });

    testWidgets('missing notification permission offers both recoveries', (
      tester,
    ) async {
      final notifications = _Notifications()
        ..permission = NotificationPermissionStatus.denied;
      final h = await pumpHome(
        tester,
        notifications: notifications,
        seed: twoPlaces,
      );
      expect(title(tester), 'נדרשת הרשאת התראות');
      expect(find.text('הפעלת התראות'), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-status-settings')));
      await tester.pump();
      expect(notifications.settingsOpened, 1);

      notifications.grantOnRequest = true;
      await tester.tap(find.byKey(const Key('home-status-action')));
      await tester.pump();
      await tester.pump();
      expect(notifications.requests, 1);
      expect(title(tester), 'המעקב פעיל');
      expect(h.rig.registrar.calls, hasLength(3)); // startup + two adds only
    });

    testWidgets('missing background location uses the existing flow', (
      tester,
    ) async {
      final service = HomeFakeGeofenceService()
        ..checkResult = GeofencePermissionStatus.foregroundOnly;
      final rig = PlaceTestRig()..registrar.failNext = 1;
      final h = await pumpHome(tester, service: service, rig: rig);
      expect(h.manager.lastError, isNotNull);
      expect(title(tester), 'נדרשת הרשאת מיקום גם ברקע');

      final calls = rig.registrar.calls.length;
      await tester.tap(find.byKey(const Key('home-status-action')));
      await tester.pumpAndSettle();
      expect(service.requestCount, 1);
      // Background access granted: the rejected registration is retried once.
      expect(rig.registrar.calls.length, calls + 1);
      expect(h.manager.lastError, isNull);
      expect(title(tester), 'עדיין אין מקומות במעקב');
    });

    testWidgets('missing location permission', (tester) async {
      final service = HomeFakeGeofenceService()
        ..checkResult = GeofencePermissionStatus.denied;
      await pumpHome(tester, service: service, seed: twoPlaces);
      expect(title(tester), 'נדרשת הרשאת מיקום');
      expect(find.text('מתן הרשאת מיקום'), findsOneWidget);
    });

    testWidgets('controller and setup failures stay visible', (tester) async {
      final notifications = _Notifications()
        ..statusError = StateError('channel down');
      final h = await pumpHome(tester, notifications: notifications);
      expect(find.byKey(const Key('home-controller-error')), findsOneWidget);
      expect(find.textContaining('NOTIFICATION_STATUS_FAILED'), findsOneWidget);

      h.controller.setPersistenceInitializationFailure(
        'Place persistence initialization failed: FormatException',
      );
      await tester.pump();
      expect(title(tester), 'טעינת המקומות השמורים נכשלה');
    });

    testWidgets('an operation failure is shown above the places', (
      tester,
    ) async {
      final h = await pumpHome(tester, seed: twoPlaces);
      h.rig.registrar.failNext = 1;
      await tester.tap(find.byKey(const Key('place-switch-place-1')));
      await tester.pumpAndSettle();
      expect(title(tester), 'פעולה על המקומות לא הושלמה');
      expect(find.byKey(const Key('retry-registration')), findsOneWidget);
    });

    testWidgets('resume re-reads permissions and status without registering', (
      tester,
    ) async {
      final service = HomeFakeGeofenceService();
      final h = await pumpHome(tester, service: service, seed: twoPlaces);
      expect(title(tester), 'המעקב פעיל');
      final calls = h.rig.registrar.calls.length;
      final writes = h.rig.store.writes;
      final reads = h.rig.registrar.statusReads;
      final checks = service.checkCount;
      final notificationReads = h.notifications.statusReads;

      service.checkResult = GeofencePermissionStatus.foregroundOnly;
      await resume(tester);
      await tester.pumpAndSettle();
      expect(service.checkCount, checks + 1);
      expect(h.notifications.statusReads, notificationReads + 1);
      expect(h.rig.registrar.statusReads, reads + 1);
      expect(h.rig.registrar.calls.length, calls);
      expect(h.rig.store.writes, writes);
      expect(service.requestCount, 0);
      expect(h.notifications.requests, 0);
      expect(title(tester), 'נדרשת הרשאת מיקום גם ברקע');

      service.checkResult = GeofencePermissionStatus.backgroundAllowed;
      await resume(tester);
      await tester.pumpAndSettle();
      expect(title(tester), 'המעקב פעיל');
      expect(h.rig.registrar.calls.length, calls);
    });

    testWidgets('duplicate resume events run one refresh', (tester) async {
      final service = HomeFakeGeofenceService();
      final h = await pumpHome(tester, service: service, seed: twoPlaces);
      final checks = service.checkCount;
      final reads = h.rig.registrar.statusReads;
      final hold = service.checkHold = Completer<void>();
      await resume(tester);
      await resume(tester);
      await resume(tester);
      hold.complete();
      service.checkHold = null;
      await tester.pumpAndSettle();
      expect(service.checkCount, checks + 1);
      expect(h.rig.registrar.statusReads, reads + 1);
    });

    testWidgets('a failed refresh is never shown as monitoring', (
      tester,
    ) async {
      final service = HomeFakeGeofenceService();
      final h = await pumpHome(tester, service: service, seed: twoPlaces);
      expect(title(tester), 'המעקב פעיל');

      service.checkError = StateError('binder died');
      await resume(tester);
      await tester.pumpAndSettle();
      expect(title(tester), 'לא ניתן לאמת את מצב המעקב');
      expect(find.textContaining('PERMISSION_CHECK_FAILED'), findsOneWidget);

      service.checkError = null;
      h.rig.registrar.statusError = StateError('status unavailable');
      await resume(tester);
      await tester.pumpAndSettle();
      expect(title(tester), 'לא ניתן לאמת את מצב המעקב');
      expect(
        tester.widget<Text>(find.byKey(const Key('place-status-place-1'))).data,
        'מצב הרישום לא ידוע',
      );
    });

    testWidgets('no refresh while a PlaceManager operation runs', (
      tester,
    ) async {
      final h = await pumpHome(tester, seed: twoPlaces);
      final reads = h.rig.registrar.statusReads;
      final hold = h.rig.registrar.holdNext();
      final operation = h.manager.setEnabled('place-1', false);
      await tester.pump();
      await resume(tester);
      await tester.pumpAndSettle();
      expect(h.rig.registrar.statusReads, reads);
      hold.complete();
      await operation;
      await tester.pumpAndSettle();
      // Only the operation's own reload read the status.
      expect(h.rig.registrar.statusReads, reads + 1);
    });

    testWidgets('disposal during a running refresh is safe', (tester) async {
      final service = HomeFakeGeofenceService();
      final h = await pumpHome(tester, service: service, seed: twoPlaces);
      final reads = h.rig.registrar.statusReads;
      final calls = h.rig.registrar.calls.length;
      final hold = service.checkHold = Completer<void>();
      await resume(tester);
      await tester.pumpWidget(const SizedBox());
      hold.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(h.rig.registrar.statusReads, reads);
      expect(h.rig.registrar.calls.length, calls);
    });

    testWidgets('seven taps on the version open Developer Mode', (
      tester,
    ) async {
      await pumpHome(tester);
      final version = find.byKey(const Key('developer-mode-gesture'));
      await tester.drag(find.byType(ListView), const Offset(0, -1000));
      await tester.pump();
      expect(find.text(BuildInfo.current.versionLabel), findsOneWidget);
      expect(find.text(BuildInfo.current.commitLabel), findsOneWidget);
      for (var i = 0; i < 7; i++) {
        await tester.tap(version);
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('PingPlace · Simulation Mode'), findsOneWidget);
    });
  });
}

final class _Notifications implements NotificationService {
  NotificationPermissionStatus permission =
      NotificationPermissionStatus.allowed;
  Object? statusError;
  bool grantOnRequest = false;
  int requests = 0;
  int settingsOpened = 0;
  int statusReads = 0;

  @override
  Future<NotificationStatus> status() async {
    statusReads++;
    if (statusError != null) throw statusError!;
    return NotificationStatus(permission: permission);
  }

  @override
  Future<void> requestPermission() async {
    requests++;
    if (grantOnRequest) permission = NotificationPermissionStatus.allowed;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<void> resetTest() async {}

  @override
  Future<NotificationDeliveryResult> deliver({
    required String visitId,
    required String reminderText,
  }) async => NotificationDeliveryResult.sent;
}

final class _Home {
  _Home(this.service, this.notifications, this.rig)
    : manager = rig.manager(),
      controller = DevelopmentGeofenceController(
        service: service,
        locationService: HomeFakeLocationService(),
        notificationService: notifications,
        runtimeStore: InMemoryArrivalRuntimeStore(),
      );

  final HomeFakeGeofenceService service;
  final _Notifications notifications;
  final PlaceTestRig rig;
  final PlaceManager manager;
  final DevelopmentGeofenceController controller;
}
