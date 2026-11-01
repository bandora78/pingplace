import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/geofence/development_geofence_controller.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';
import 'package:pingplace/src/simulation/places_pipeline_diagnostics.dart';

import 'development_geofence_controller_test.dart'
    show FakeGeofenceService, FakeLocationService;
import 'support/place_fakes.dart';

DetectionRuntimeSnapshot _stuck(double latitude, double longitude) =>
    DetectionRuntimeSnapshot(
      state: DetectionState.waitingForExit,
      target: TargetLocation(latitude: latitude, longitude: longitude),
      cooldownUntil: DateTime.utc(2026, 10, 28),
      visitId: 'visit-old',
    );

void main() {
  group('stale per-place state at startup', () {
    test('state recorded for an old location is discarded', () async {
      final rig = PlaceTestRig();
      final first = rig.manager();
      await first.initialize();
      await first.add(
        draft(name: 'Home', latitude: 32.0853, longitude: 34.7818),
      );
      await first.add(draft(name: 'Office', latitude: 32.1, longitude: 34.9));
      first.dispose();
      // Build 15 left state for the place's previous coordinates.
      rig.runtime.placeSnapshots['place-1'] = _stuck(32.0001, 34.8001);
      // State at the current location is genuine and must be kept.
      rig.runtime.placeSnapshots['place-2'] = _stuck(32.1, 34.9);

      final restarted = rig.manager();
      await restarted.initialize();

      expect(rig.runtime.placeSnapshots.containsKey('place-1'), isFalse);
      expect(
        rig.runtime.placeSnapshots['place-2']?.state,
        DetectionState.waitingForExit,
      );
      expect(
        restarted.diagnostics.any(
          (line) => line.contains(
            'RUNTIME_RESET_STALE_TARGET place-1 state=WAITINGFOREXIT',
          ),
        ),
        isTrue,
      );
    });

    test('per-place diagnostics show registration and arrival state', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(draft(name: 'Home', latitude: 32.1, longitude: 34.9));
      await manager.add(draft(name: 'Gym', enabled: false));
      rig.runtime.placeSnapshots['place-1'] = _stuck(32.1, 34.9);

      final lines = await manager.placeRuntimeDiagnostics();

      expect(lines, hasLength(2));
      expect(
        lines.first,
        contains(
          'PLACE place-1 "Home" enabled=true registration=REGISTERED radius=300m',
        ),
      );
      expect(lines.first, contains('state=WAITINGFOREXIT'));
      expect(lines.first, contains('visit=visit-old'));
      expect(lines.last, contains('enabled=false registration=DISABLED'));
      expect(lines.last, contains('state=NONE'));
    });
  });

  group('system health channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('pingplace/geofence');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('reads device conditions from the native layer', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'systemHealth');
        return {
          'locationPermission': 'backgroundAllowed',
          'ignoringBatteryOptimizations': false,
          'backgroundRestricted': true,
        };
      });

      final health = await MethodChannelGeofenceService().systemHealth();

      expect(health['locationPermission'], 'backgroundAllowed');
      expect(health['ignoringBatteryOptimizations'], isFalse);
      expect(health['backgroundRestricted'], isTrue);
    });

    test('non-native services report no health data', () async {
      expect(await FakeGeofenceService().systemHealth(), isEmpty);
    });
  });

  test(
    'diagnostics refresh also reloads the background pipeline log',
    () async {
      final notifications = InMemoryNotificationService();
      final controller = DevelopmentGeofenceController(
        service: FakeGeofenceService(),
        locationService: FakeLocationService(),
        notificationService: notifications,
        runtimeStore: InMemoryArrivalRuntimeStore(),
      );
      await controller.initialize();
      expect(controller.backgroundDiagnostics, isEmpty);

      notifications.currentStatus = const NotificationStatus(
        permission: NotificationPermissionStatus.allowed,
        backgroundDiagnostics: ['place-1 BACKGROUND_ENTER_RECEIVED'],
      );
      await controller.refreshDiagnostics();

      expect(controller.backgroundDiagnostics, [
        'place-1 BACKGROUND_ENTER_RECEIVED',
      ]);
      controller.dispose();
    },
  );

  testWidgets(
    'Developer Mode shows the places pipeline, not only legacy state',
    (tester) async {
      final service = FakeGeofenceService()
        ..recovery = GeofenceRecoveryStatus(
          lastBackgroundEvent: DateTime.utc(2026, 11, 1, 5, 42, 20),
          diagnostics: [
            for (var i = 0; i < 12; i++) '2026-11-01T05:${10 + i}:00Z LINE_$i',
          ],
        );
      final notifications = InMemoryNotificationService()
        ..currentStatus = const NotificationStatus(
          permission: NotificationPermissionStatus.allowed,
          backgroundDiagnostics: [
            'place-1 BACKGROUND_EXIT_RESTORING_PERSISTED_STATE',
          ],
        );
      final controller = DevelopmentGeofenceController(
        service: service,
        locationService: FakeLocationService(),
        notificationService: notifications,
        runtimeStore: InMemoryArrivalRuntimeStore(),
      );
      await controller.initialize();
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(draft(name: 'Home'));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlacesPipelineDiagnostics(
                controller: controller,
                placeManager: manager,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Places pipeline (authoritative for places)'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('last-geofence-callback')))
            .data,
        'Last geofence callback: 2026-11-01T05:42:20.000Z',
      );
      final nativeLog = tester
          .widget<SelectableText>(find.byKey(const Key('native-log')))
          .data!;
      // All 12 entries, newest first; Build 16 showed only the newest 6.
      expect(nativeLog.split('\n'), hasLength(12));
      expect(nativeLog.split('\n').first, contains('LINE_11'));
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('pipeline-log')))
            .data,
        contains('BACKGROUND_EXIT_RESTORING_PERSISTED_STATE'),
      );
      expect(find.textContaining('PLACE place-1 "Home"'), findsOneWidget);
      controller.dispose();
    },
  );
}
