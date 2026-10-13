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
    final source = File(
      'android/app/src/main/kotlin/com/example/pingplace/MainActivity.kt',
    ).readAsStringSync();

    expect(
      source,
      contains('val pendingIntent = GeofencePendingIntent.get(this)'),
    );
    expect(source, contains('addGeofences(request, pendingIntent)'));
    expect(source, contains('removeGeofences(pendingIntent)'));
    expect(
      source,
      contains('removeGeofences(GeofencePendingIntent.get(this))'),
    );
  });

  test(
    'APP-01A persists a versioned registration record and reconciles state',
    () {
      final recovery = File(
        'android/app/src/main/kotlin/com/example/pingplace/GeofenceRecovery.kt',
      ).readAsStringSync();
      final record = File(
        'android/app/src/main/kotlin/com/example/pingplace/RegistrationRecordStore.kt',
      ).readAsStringSync();
      final activity = File(
        'android/app/src/main/kotlin/com/example/pingplace/MainActivity.kt',
      ).readAsStringSync();

      expect(record, contains('const val SCHEMA_VERSION = 1'));
      for (final state in [
        'CONFIGURED',
        'REGISTRATION_PENDING',
        'REGISTRATION_CONFIRMED',
        'RECOVERY_REQUIRED',
        'RECOVERY_BLOCKED',
      ]) {
        expect(record, contains(state));
      }
      expect(record, contains('put("desiredMonitoring"'));
      expect(record, contains('put("recoveryGeneration"'));
      expect(record, contains('.commit()'));
      expect(
        recovery,
        contains('RegistrationRecordStore.State.REGISTRATION_PENDING'),
      );
      expect(
        recovery,
        contains('RegistrationRecordStore.State.REGISTRATION_CONFIRMED'),
      );
      expect(
        activity,
        contains('GeofenceRecovery.restore(this, "ui_startup")'),
      );
      expect(activity, isNot(contains('GEOFENCE_RECOVERY_SKIPPED_CONFIRMED')));
    },
  );

  test('APP-01A fails closed for persistence and stale callbacks', () {
    final store = File(
      'android/app/src/main/kotlin/com/example/pingplace/RegistrationRecordStore.kt',
    ).readAsStringSync();
    final recovery = File(
      'android/app/src/main/kotlin/com/example/pingplace/GeofenceRecovery.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/example/pingplace/MainActivity.kt',
    ).readAsStringSync();

    expect(store, contains('check('));
    expect(store, contains('ReadFailure.CORRUPT'));
    expect(store, contains('ReadFailure.UNSUPPORTED_SCHEMA'));
    expect(recovery, contains('STALE_CALLBACK_IGNORED'));
    expect(recovery, contains('sameDesired(current, pending)'));
    expect(recovery, contains('!current.desiredMonitoring'));
    expect(recovery, contains('REGISTRATION_RECORD_\${stored.failure.name}'));
    expect(
      activity,
      contains('RegistrationRecordStore.State.RECOVERY_BLOCKED'),
    );
    expect(activity, contains('RegistrationRecordStore.configure'));
    expect(activity, contains('GeofenceRecovery.remove(this)'));
    expect(
      recovery.indexOf('RegistrationRecordStore.desiredDisabled(context)'),
      lessThan(
        recovery.lastIndexOf(
          'removeGeofences(GeofencePendingIntent.get(context))',
        ),
      ),
    );
    expect(
      recovery.indexOf('RegistrationRecordStore.persist(context, pending)'),
      lessThan(recovery.indexOf('client.removeGeofences(pendingIntent)')),
    );
  });
}
