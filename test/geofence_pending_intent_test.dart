import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('geofence PendingIntent remains mutable and stable', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/pingplace/GeofencePendingIntent.kt',
    ).readAsStringSync();

    expect(source, contains('const val REQUEST_CODE = 4202'));
    expect(source, contains('PendingIntent.FLAG_UPDATE_CURRENT'));
    expect(source, contains('PendingIntent.FLAG_MUTABLE'));
    expect(source, isNot(contains('PendingIntent.FLAG_IMMUTABLE')));
    expect(source, contains('apiLevel >= Build.VERSION_CODES.S'));
    expect(source, contains('GeofenceBroadcastReceiver::class.java'));
    expect(
      source,
      contains('PendingIntent.getBroadcast(context, REQUEST_CODE'),
    );
  });

  test('registration and removal use the shared PendingIntent helper', () {
    final activitySource = File(
      'android/app/src/main/kotlin/com/example/pingplace/MainActivity.kt',
    ).readAsStringSync();
    final recoverySource = File(
      'android/app/src/main/kotlin/com/example/pingplace/GeofenceRecovery.kt',
    ).readAsStringSync();

    expect(activitySource, contains('GeofenceRecovery.register'));
    expect(activitySource, contains('GeofenceRecovery.remove'));
    expect(
      recoverySource,
      contains('val pendingIntent = GeofencePendingIntent.get(context)'),
    );
    expect(recoverySource, contains('addGeofences(request, pendingIntent)'));
    expect(recoverySource, contains('removeGeofences(pendingIntent)'));
    expect(recoverySource, contains('GeofenceLifecycleCoordinator'));
  });
}

