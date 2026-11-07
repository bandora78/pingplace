import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/geofence/development_geofence_controller.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';
import 'package:pingplace/src/simulation/development_simulation_screen.dart';

import 'development_geofence_controller_test.dart'
    show FakeGeofenceService, FakeLocationService;

// Regression coverage for APP-09A: the diagnostics screen showed
// "Platform registration confirmed: NO / UNKNOWN" after a successful
// registration until the app was restarted.

Future<(FakeGeofenceService, DevelopmentGeofenceController)> _started({
  bool confirmed = false,
}) async {
  final service = FakeGeofenceService()
    ..modelNativeConfirmation = true
    ..recovery = GeofenceRecoveryStatus(registrationConfirmed: confirmed);
  final controller = DevelopmentGeofenceController(
    service: service,
    locationService: FakeLocationService(),
    notificationService: InMemoryNotificationService(),
    runtimeStore: InMemoryArrivalRuntimeStore(),
  );
  await controller.initialize();
  return (service, controller);
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('startup reads platform confirmation as not confirmed', () async {
    final (_, controller) = await _started();

    expect(controller.platformConfirmation, PlatformConfirmation.notConfirmed);
    expect(controller.diagnosticsRefreshedAt, isNotNull);
    controller.dispose();
  });

  test('successful registration refreshes stale platform confirmation '
      'without restarting the app', () async {
    final (service, controller) = await _started();
    final readsBefore = service.recoveryReads;
    var notifications = 0;
    controller.addListener(() => notifications++);

    final succeeded = await controller.register();

    expect(succeeded, isTrue);
    expect(controller.registered, isTrue);
    expect(controller.state, DetectionState.armed);
    expect(service.recoveryReads, greaterThan(readsBefore));
    expect(controller.platformConfirmation, PlatformConfirmation.confirmed);
    expect(controller.recoveryStatus.registrationConfirmed, isTrue);
    expect(notifications, greaterThan(0));
    controller.dispose();
  });

  test('removal refreshes confirmation back to not confirmed', () async {
    final (service, controller) = await _started();
    await controller.register();
    expect(controller.platformConfirmation, PlatformConfirmation.confirmed);

    await controller.remove();

    expect(controller.registered, isFalse);
    expect(controller.state, DetectionState.disarmed);
    expect(controller.platformConfirmation, PlatformConfirmation.notConfirmed);
    expect(service.recovery.registrationConfirmed, isFalse);
    controller.dispose();
  });

  test('failed registration refreshes to the native unconfirmed state '
      'instead of keeping a stale confirmation', () async {
    final (service, controller) = await _started(confirmed: true);
    expect(controller.platformConfirmation, PlatformConfirmation.confirmed);
    service.registerError = StateError('addGeofences failed');

    final succeeded = await controller.register();

    expect(succeeded, isFalse);
    expect(controller.lastError, contains('GEOFENCE_REGISTRATION_FAILED'));
    expect(controller.platformConfirmation, PlatformConfirmation.notConfirmed);
    controller.dispose();
  });

  test('failed removal still refreshes diagnostics', () async {
    final (service, controller) = await _started();
    await controller.register();
    service.removeError = StateError('removeGeofences failed');

    await controller.remove();

    expect(controller.lastError, contains('GEOFENCE_REMOVE_FAILED'));
    // Native removal marks the registration unconfirmed before the platform
    // call; the diagnostics must not keep claiming YES.
    expect(controller.platformConfirmation, PlatformConfirmation.notConfirmed);
    controller.dispose();
  });

  test('native status change after startup reconciliation refreshes '
      'confirmation automatically', () async {
    // Startup reconciliation is still replacing the geofence when Dart reads.
    final (service, controller) = await _started();
    expect(controller.platformConfirmation, PlatformConfirmation.notConfirmed);

    service.recovery = const GeofenceRecoveryStatus(
      registrationConfirmed: true,
    );
    service.statusController.add(null);
    await _settle();

    expect(controller.platformConfirmation, PlatformConfirmation.confirmed);
    controller.dispose();
  });

  test('a failed diagnostics read is UNKNOWN, never confirmed', () async {
    final (service, controller) = await _started(confirmed: true);
    expect(controller.platformConfirmation, PlatformConfirmation.confirmed);

    service.recoveryError = StateError('channel unavailable');
    await controller.refreshDiagnostics();

    expect(controller.platformConfirmation, PlatformConfirmation.unknown);
    expect(
      controller.diagnosticsRefreshFailure,
      contains('DIAGNOSTICS_REFRESH_FAILED reason=manual'),
    );
    expect(controller.eventLog.last, contains('DIAGNOSTICS_REFRESH_FAILED'));
    // A diagnostics read failure is reported separately and does not replace
    // the last lifecycle error.
    expect(controller.lastError, isNull);

    service.recoveryError = null;
    await controller.refreshDiagnostics();
    expect(controller.platformConfirmation, PlatformConfirmation.confirmed);
    expect(controller.diagnosticsRefreshFailure, isNull);
    controller.dispose();
  });

  test('confirmation stays UNKNOWN when the startup read fails', () async {
    final service = FakeGeofenceService()
      ..recovery = const GeofenceRecoveryStatus(registrationConfirmed: true)
      ..recoveryError = StateError('channel unavailable');
    final controller = DevelopmentGeofenceController(
      service: service,
      locationService: FakeLocationService(),
      notificationService: InMemoryNotificationService(),
      runtimeStore: InMemoryArrivalRuntimeStore(),
    );

    await controller.initialize();

    expect(controller.platformConfirmation, PlatformConfirmation.unknown);
    expect(controller.diagnosticsRefreshedAt, isNull);
    expect(controller.initialized, isTrue);
    controller.dispose();
  });

  test('an older diagnostics read cannot overwrite a newer one', () async {
    final (service, controller) = await _started();
    service.holdRecoveryReads = true;

    // Older read captures "not confirmed".
    final older = controller.refreshDiagnostics(reason: 'older');
    await _settle();
    service.recovery = const GeofenceRecoveryStatus(
      registrationConfirmed: true,
    );
    final newer = controller.refreshDiagnostics(reason: 'newer');
    await _settle();
    expect(service.pendingRecoveryReads, hasLength(2));

    // Complete the newer read first, then the stale one.
    service.pendingRecoveryReads[1].complete();
    await newer;
    service.pendingRecoveryReads[0].complete();
    await older;

    expect(controller.platformConfirmation, PlatformConfirmation.confirmed);
    controller.dispose();
  });

  test('a diagnostics read completing after dispose is ignored', () async {
    final (service, controller) = await _started();
    var notifications = 0;
    controller.addListener(() => notifications++);
    service
      ..holdRecoveryReads = true
      ..recovery = const GeofenceRecoveryStatus(registrationConfirmed: true);
    final pending = controller.refreshDiagnostics(reason: 'late');
    await _settle();

    controller.dispose();
    service.pendingRecoveryReads.single.complete();
    await pending;

    expect(notifications, 0);
    expect(controller.platformConfirmation, PlatformConfirmation.notConfirmed);
  });

  group('method channel status callback', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('pingplace/geofence');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    Future<ByteData?> nativeCall(String method) {
      final completer = Completer<ByteData?>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        completer.complete,
      );
      return completer.future;
    }

    test('native registrationStatusChanged reaches statusChanges', () async {
      final service = MethodChannelGeofenceService();
      var changes = 0;
      final subscription = service.statusChanges.listen((_) => changes++);

      await nativeCall('registrationStatusChanged');
      await _settle();

      expect(changes, 1);
      await subscription.cancel();
      service.dispose();
    });

    test(
      'unknown native callbacks are rejected, not treated as changes',
      () async {
        final service = MethodChannelGeofenceService();
        var changes = 0;
        final subscription = service.statusChanges.listen((_) => changes++);

        final reply = await nativeCall('somethingElse');
        await _settle();

        expect(changes, 0);
        expect(reply, isNull); // MissingPluginException => notImplemented.
        await subscription.cancel();
        service.dispose();
      },
    );

    test('dispose removes the handler', () async {
      final service = MethodChannelGeofenceService();
      var changes = 0;
      service.statusChanges.listen((_) => changes++);
      service.dispose();

      final reply = await nativeCall('registrationStatusChanged');
      await _settle();

      expect(changes, 0);
      expect(reply, isNull);
    });

    test(
      'a service that never subscribed does not clear the handler',
      () async {
        final owner = MethodChannelGeofenceService();
        var changes = 0;
        final subscription = owner.statusChanges.listen((_) => changes++);
        // e.g. the place persistence layer creates its own service instance.
        MethodChannelGeofenceService().dispose();

        await nativeCall('registrationStatusChanged');
        await _settle();

        expect(changes, 1);
        await subscription.cancel();
        owner.dispose();
      },
    );
  });

  test('confirmation labels keep the three states distinct', () {
    expect(platformConfirmationLabel(PlatformConfirmation.confirmed), 'YES');
    expect(
      platformConfirmationLabel(PlatformConfirmation.notConfirmed),
      startsWith('NO'),
    );
    expect(
      platformConfirmationLabel(PlatformConfirmation.unknown),
      startsWith('UNKNOWN'),
    );
  });
}
