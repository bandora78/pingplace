import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/build_info.dart';
import 'package:pingplace/src/geofence/development_geofence_controller.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';
import 'package:pingplace/src/simulation/diagnostics_report.dart';
import 'package:pingplace/src/simulation/places_pipeline_diagnostics.dart';

import 'development_geofence_controller_test.dart'
    show FakeGeofenceService, FakeLocationService;
import 'support/place_fakes.dart';

const _build = BuildInfo(
  version: '1.0.0',
  buildNumber: '18',
  commit: 'abc1234',
  buildType: 'release',
);
final _exportedAt = DateTime.utc(2026, 11, 2, 18);

// More history than the card shows (40 native lines), as on the device.
final _native = [
  for (var i = 0; i < 120; i++)
    '2026-11-02T05:${(i % 60).toString().padLeft(2, '0')}:00Z NATIVE_$i',
  '2026-11-02T05:34:42.051908Z GEOFENCE_TRANSITION enter ids=[legacy-place-1] places=[legacy-place-1]',
  '2026-11-02T05:01:58.952023Z MULTI_GEOFENCE_APPLIED source=register count=1 legacy-place-1@31.665,34.781/r300',
  '2026-11-02T05:50:00Z PRECISE_LOCATION_START_BLOCKED place=place-2 error=ForegroundServiceStartNotAllowedException',
];
final _pipeline = [
  '2026-11-02T05:34:43Z BACKGROUND_ENGINE_READY after=900ms queued=2',
  '2026-11-02T05:34:52Z legacy-place-1 LOCATION distance=199.8m accuracy=8.0m at=2026-11-02T05:34:52.000Z lat=31.66512 lon=34.78123 age=0s',
  '2026-11-02T05:35:00Z legacy-place-1 NOTIFICATION_SENT',
  '2026-11-02T05:35:00Z legacy-place-1 APPROACH_SUMMARY outcome=ARRIVED samples=3 accepted=3',
  '2026-11-02T05:40:00Z place-2 ENTER_SUPPRESSED reason=COOLDOWN until=2026-11-02T05:45:00.000Z',
  for (var i = 0; i < 400; i++) '2026-11-02T06:00:00Z place-2 LINE_$i',
];

void main() {
  group('report', () {
    String report() => buildDiagnosticsReport(
      DiagnosticsSnapshot(
        build: _build,
        exportedAt: _exportedAt,
        health: const {
          'locationPermission': 'backgroundAllowed',
          'backgroundRestricted': false,
          'device': 'Xiaomi 24129PN74G SDK 35',
        },
        registration: const {
          'confirmed': true,
          'appliedPlaceIds': ['legacy-place-1', 'place-2'],
        },
        places: const [
          'PLACE legacy-place-1 "Home" enabled=true registration=REGISTERED radius=300m state=ARMED',
        ],
        lastGeofenceCallback: DateTime.utc(2026, 11, 2, 5, 34, 42),
        nativeLog: _native,
        pipelineLog: _pipeline,
      ),
    );

    test('contains every section and the full stored history', () {
      final text = report();
      for (final heading in [
        '== System health (3) ==',
        '== Android registration (2) ==',
        '== Places (1) ==',
        '== Background engine events',
        '== Visit summaries',
        '== Notification results (1) ==',
        '== Errors and failures',
        '== Native receiver and registration log (full) (123) ==',
        '== Background arrival pipeline log (full) (405) ==',
      ]) {
        expect(text, contains(heading));
      }
      expect(text, contains('App: 1.0.0 (Build 18) commit abc1234 release'));
      expect(text, contains('Exported: 2026-11-02T18:00:00.000Z'));
      // Lines far beyond what the card shows.
      expect(text, contains('NATIVE_0'));
      expect(text, contains('place-2 LINE_399'));
      expect(text, contains('reason=COOLDOWN'));
      expect(text, contains('APPROACH_SUMMARY outcome=ARRIVED'));
      expect(text, contains('BACKGROUND_ENGINE_READY after=900ms'));
      expect(text, contains('NOTIFICATION_SENT'));
      expect(text, contains('PRECISE_LOCATION_START_BLOCKED place=place-2'));
      expect(text, contains('backgroundRestricted: false'));
    });

    test('rounds precise coordinates and keeps other numbers', () {
      final text = report();
      expect(text, isNot(contains('31.66512')));
      expect(text, isNot(contains('34.78123')));
      expect(text, contains('lat=31.665 lon=34.781'));
      expect(text, contains('distance=199.8m accuracy=8.0m'));
      expect(text, contains('at=2026-11-02T05:34:52.000Z'));
      expect(text, contains('legacy-place-1@31.665,34.781/r300'));
      expect(
        redactCoordinates('target 32.085312, 34.781876 at 05:34:42.052662Z'),
        'target 32.085,34.782 at 05:34:42.052662Z',
      );
    });

    test('building the report does not modify the logs', () {
      final native = List.of(_native);
      final pipeline = List.of(_pipeline);
      buildDiagnosticsReport(
        DiagnosticsSnapshot(
          build: _build,
          exportedAt: _exportedAt,
          nativeLog: native,
          pipelineLog: pipeline,
        ),
      );
      expect(native, _native);
      expect(pipeline, _pipeline);
    });
  });

  group('card export actions', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> shareCalls;
    late String? clipboard;

    setUp(() {
      shareCalls = [];
      clipboard = null;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(PlatformDiagnosticsExporter.channel, (
        call,
      ) async {
        shareCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(
        PlatformDiagnosticsExporter.channel,
        null,
      );
    });

    Future<DevelopmentGeofenceController> pumpCard(WidgetTester tester) async {
      final service = FakeGeofenceService()
        ..recovery = GeofenceRecoveryStatus(diagnostics: List.of(_native));
      final notifications = InMemoryNotificationService()
        ..currentStatus = NotificationStatus(
          permission: NotificationPermissionStatus.allowed,
          backgroundDiagnostics: List.of(_pipeline),
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
                buildInfo: _build,
                clock: () => _exportedAt,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets(
      'Copy full diagnostics puts the whole report on the clipboard',
      (tester) async {
        final controller = await pumpCard(tester);

        await tester.tap(find.byKey(const Key('copy-diagnostics')));
        await tester.pumpAndSettle();

        expect(clipboard, isNotNull);
        expect(clipboard, contains('PingPlace diagnostics report'));
        expect(clipboard, contains('NATIVE_0'));
        expect(clipboard, contains('place-2 LINE_399'));
        expect(clipboard, contains('PLACE place-1 "Home"'));
        expect(clipboard, isNot(contains('31.66512')));
        expect(
          tester.widget<Text>(find.byKey(const Key('export-status'))).data,
          startsWith('Copied full diagnostics'),
        );
        expect(shareCalls, isEmpty);
        // Exporting never clears or changes the logs.
        expect(controller.recoveryStatus.diagnostics, _native);
        expect(controller.backgroundDiagnostics, _pipeline);
        controller.dispose();
      },
    );

    testWidgets('Share diagnostics opens the native share sheet', (
      tester,
    ) async {
      final controller = await pumpCard(tester);

      await tester.tap(find.byKey(const Key('share-diagnostics')));
      await tester.pumpAndSettle();

      expect(shareCalls, hasLength(1));
      expect(shareCalls.single.method, 'shareText');
      final arguments = shareCalls.single.arguments as Map;
      expect(arguments['subject'], 'PingPlace diagnostics');
      final text = arguments['text'] as String;
      expect(
        text,
        contains('== Background arrival pipeline log (full) (405) =='),
      );
      expect(text, contains('lat=31.665 lon=34.781'));
      expect(clipboard, isNull);
      expect(
        tester.widget<Text>(find.byKey(const Key('export-status'))).data,
        startsWith('Share sheet opened'),
      );
      expect(controller.backgroundDiagnostics, _pipeline);
      controller.dispose();
    });

    testWidgets('a share failure is shown, not hidden', (tester) async {
      messenger.setMockMethodCallHandler(PlatformDiagnosticsExporter.channel, (
        call,
      ) async {
        throw PlatformException(code: 'SHARE_FAILED', message: 'no activity');
      });
      final controller = await pumpCard(tester);

      await tester.tap(find.byKey(const Key('share-diagnostics')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('export-status'))).data,
        allOf(startsWith('Share failed'), contains('SHARE_FAILED')),
      );
      controller.dispose();
    });
  });
}
