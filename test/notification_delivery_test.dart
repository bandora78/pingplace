import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/background/background_arrival_session.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

const target = TargetLocation(latitude: 32, longitude: 34.8);

LocationSample sample(double meters, DateTime at, {double accuracy = 10}) =>
    LocationSample(
      latitude: target.latitude + meters / 111320,
      longitude: target.longitude,
      accuracy: accuracy,
      timestamp: at,
    );

Map<String, Object?> locationPayload(
  double meters,
  DateTime at, {
  double accuracy = 10,
}) => {
  'type': 'location',
  'latitude': target.latitude + meters / 111320,
  'longitude': target.longitude,
  'accuracy': accuracy,
  'timestamp': at.toIso8601String(),
};

Future<BackgroundArrivalSession> session(
  InMemoryArrivalRuntimeStore runtime,
  InMemoryNotificationService notifications,
  List<String> diagnostics, {
  SmartArrivalConfig? config,
}) async {
  return BackgroundArrivalSession(
    onDiagnostic: diagnostics.add,
    onCommand: (_) async {},
    runtimeStore: runtime,
    notificationService: notifications,
    config: config,
  );
}

Future<void> enterAndSample(
  BackgroundArrivalSession value,
  DateTime at, {
  double meters = 70,
  double accuracy = 10,
}) async {
  await value.handleEvent({
    'type': 'enter',
    'targetLatitude': target.latitude,
    'targetLongitude': target.longitude,
    'timestamp': at.toIso8601String(),
  });
  await value.handleEvent(locationPayload(meters, at, accuracy: accuracy));
}

void main() {
  test('valid arrival sends exactly one notification', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService();
    final diagnostics = <String>[];
    final value = await session(runtime, notifications, diagnostics);
    await enterAndSample(value, DateTime.utc(2026, 1, 1));

    expect(notifications.deliveredVisitIds, hasLength(1));
    expect(diagnostics, contains('NOTIFICATION_SENT'));
    value.dispose();
  });

  test('inaccurate inner sample cannot notify', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService();
    final diagnostics = <String>[];
    final value = await session(runtime, notifications, diagnostics);
    await enterAndSample(value, DateTime.utc(2026, 1, 1), accuracy: 51);

    expect(notifications.deliveredVisitIds, isEmpty);
    expect(diagnostics, contains('LOCATION_REJECTED reason=LOW_ACCURACY'));
    value.dispose();
  });

  test('nearby pass does not notify', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService();
    final diagnostics = <String>[];
    final value = await session(runtime, notifications, diagnostics);
    final at = DateTime.utc(2026, 1, 1);
    await enterAndSample(value, at, meters: 150);
    await value.handleEvent({'type': 'exit'});

    expect(notifications.deliveredVisitIds, isEmpty);
    expect(value.engine?.state, DetectionState.armed);
    value.dispose();
  });

  test('repeated inner samples do not duplicate notification', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService();
    final diagnostics = <String>[];
    final value = await session(runtime, notifications, diagnostics);
    final at = DateTime.utc(2026, 1, 1);
    await enterAndSample(value, at);
    await value.handleEvent(
      locationPayload(60, at.add(const Duration(minutes: 1))),
    );

    expect(notifications.deliveredVisitIds, hasLength(1));
    expect(
      diagnostics.where((entry) => entry == 'NOTIFICATION_SENT'),
      hasLength(1),
    );
    value.dispose();
  });

  test(
    'EXIT and ENTER during cooldown do not duplicate notification',
    () async {
      final runtime = InMemoryArrivalRuntimeStore();
      final notifications = InMemoryNotificationService();
      final diagnostics = <String>[];
      final value = await session(runtime, notifications, diagnostics);
      final at = DateTime.utc(2026, 1, 1);
      await enterAndSample(value, at);
      await value.handleEvent({'type': 'exit'});
      await value.handleEvent({
        'type': 'enter',
        'targetLatitude': target.latitude,
        'targetLongitude': target.longitude,
        'timestamp': at.add(const Duration(minutes: 2)).toIso8601String(),
      });

      expect(notifications.deliveredVisitIds, hasLength(1));
      value.dispose();
    },
  );

  test(
    'restart/headless overlap suppresses the same persisted visit',
    () async {
      final runtime = InMemoryArrivalRuntimeStore();
      final notifications = InMemoryNotificationService();
      final firstDiagnostics = <String>[];
      final first = await session(runtime, notifications, firstDiagnostics);
      final at = DateTime.utc(2026, 1, 1);
      await enterAndSample(first, at);
      first.dispose();

      final secondDiagnostics = <String>[];
      final second = await session(runtime, notifications, secondDiagnostics);
      await enterAndSample(second, at.add(const Duration(minutes: 1)));

      expect(notifications.deliveredVisitIds, hasLength(1));
      expect(secondDiagnostics, isNot(contains('NOTIFICATION_SENT')));
      second.dispose();
    },
  );

  test('a new visit after rearm can notify again', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService();
    final diagnostics = <String>[];
    final config = SmartArrivalConfig(
      target: target,
      cooldownDuration: const Duration(seconds: 1),
    );
    final value = await session(
      runtime,
      notifications,
      diagnostics,
      config: config,
    );
    final at = DateTime.utc(2026, 1, 1);
    await enterAndSample(value, at);
    await value.handleEvent({
      'type': 'cooldownElapsed',
      'timestamp': at.add(const Duration(seconds: 2)).toIso8601String(),
    });
    await value.handleEvent({
      'type': 'rearm',
      'timestamp': at.add(const Duration(seconds: 3)).toIso8601String(),
    });
    await enterAndSample(value, at.add(const Duration(seconds: 4)));

    expect(notifications.deliveredVisitIds, hasLength(2));
    value.dispose();
  });

  test('permission denial and delivery failure are diagnostic', () async {
    final runtime = InMemoryArrivalRuntimeStore();
    final notifications = InMemoryNotificationService()
      ..permission = NotificationPermissionStatus.denied;
    final diagnostics = <String>[];
    final value = await session(runtime, notifications, diagnostics);
    await enterAndSample(value, DateTime.utc(2026, 1, 1));
    expect(diagnostics, contains('NOTIFICATION_PERMISSION_MISSING'));
    value.dispose();

    final failing = InMemoryNotificationService()
      ..deliveryResult = NotificationDeliveryResult.failed;
    final failureDiagnostics = <String>[];
    final failureSession = await session(
      InMemoryArrivalRuntimeStore(),
      failing,
      failureDiagnostics,
    );
    await enterAndSample(failureSession, DateTime.utc(2026, 1, 1));
    expect(failureDiagnostics, contains('NOTIFICATION_FAILED'));
    failureSession.dispose();
  });
}
