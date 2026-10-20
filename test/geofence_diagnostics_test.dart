import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pingplace/src/build_info.dart';
import 'package:pingplace/src/geofence/geofence_diagnostics_screen.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'maps persisted diagnostics without inventing platform confirmation',
    () async {
      final channel = MethodChannel('test/geofence-diagnostics');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'diagnosticSnapshot') {
              return <String, Object?>{
                'androidVersion': '14 (API 34)',
                'manufacturer': 'Xiaomi',
                'model': 'Xiaomi 15',
                'locationServicesEnabled': true,
                'batteryOptimizationIgnored': false,
                'desiredGeofenceCount': 1,
                'trackedGeofenceCount': 0,
                'pendingRemovalTombstoneCount': 0,
                'persistedConfigurationGeneration': 7,
                'lastReconciliationAttempt': '2026-10-14T10:00:00Z',
                'lastReconciliationResult': 'failed: permission',
                'events': <String>[
                  '2026-10-14T10:00:00Z ADD_REQUEST generation=7 result=failed',
                ],
              };
            }
            if (call.method == 'checkPermission') return 'foregroundOnly';
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final service = MethodChannelGeofenceService(methodChannel: channel);
      final snapshot = await service.diagnostics;
      final permission = await service.checkPermission();
      final report = buildGeofenceDiagnosticReport(
        buildInfo: BuildInfo.current,
        permission: permission,
        snapshot: snapshot,
      );

      expect(snapshot.desiredGeofenceCount, 1);
      expect(snapshot.trackedGeofenceCount, 0);
      expect(permission, GeofencePermissionStatus.foregroundOnly);
      expect(report, contains('Locally tracked geofences: 0'));
      expect(report, contains('Platform confirmation'));
      expect(report, isNot(contains('31.664913')));
      expect(report, contains('ADD_REQUEST generation=7 result=failed'));
      expect(
        calls,
        containsAll(<String>['diagnosticSnapshot', 'checkPermission']),
      );
    },
  );

  test('diagnostic controls call only diagnostic methods', () async {
    final channel = MethodChannel('test/geofence-diagnostics-controls');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == 'diagnosticSnapshot'
              ? <String, Object?>{'events': <String>[]}
              : null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final service = MethodChannelGeofenceService(methodChannel: channel);
    await service.clearDiagnostics();
    await service.shareDiagnostics('safe report');

    expect(calls, <String>['clearDiagnostics', 'shareDiagnostics']);
    expect(calls, isNot(contains('register')));
    expect(calls, isNot(contains('remove')));
  });

  test('report renders unavailable values explicitly', () {
    final report = buildGeofenceDiagnosticReport(
      buildInfo: BuildInfo.current,
      permission: GeofencePermissionStatus.denied,
      snapshot: const GeofenceDiagnosticsSnapshot(),
    );

    expect(report, contains('Unknown'));
    expect(report, contains('Not available'));
    expect(report, contains('None recorded'));
  });
}
