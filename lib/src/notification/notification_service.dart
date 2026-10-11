import 'package:flutter/services.dart';

enum NotificationPermissionStatus { allowed, denied, unavailable }

enum NotificationDeliveryResult { sent, duplicate, permissionMissing, failed }

final class NotificationStatus {
  const NotificationStatus({
    required this.permission,
    this.lastResult,
    this.lastTimestamp,
    this.lastVisitId,
    this.backgroundDiagnostics = const [],
  });

  final NotificationPermissionStatus permission;
  final NotificationDeliveryResult? lastResult;
  final DateTime? lastTimestamp;
  final String? lastVisitId;
  final List<String> backgroundDiagnostics;
}

abstract interface class NotificationService {
  Future<NotificationStatus> status();

  Future<void> requestPermission();

  Future<void> openSettings();

  Future<void> resetTest();

  Future<NotificationDeliveryResult> deliver({
    required String visitId,
    required String reminderText,
  });
}

final class MethodChannelNotificationService implements NotificationService {
  MethodChannelNotificationService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'pingplace/notifications';
  final MethodChannel _channel;

  @override
  Future<NotificationStatus> status() async {
    final value = await _channel.invokeMethod<Map<dynamic, dynamic>>('status');
    return _parseStatus(value ?? const {});
  }

  @override
  Future<void> requestPermission() =>
      _channel.invokeMethod<void>('requestPermission');

  @override
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');

  @override
  Future<void> resetTest() => _channel.invokeMethod<void>('resetTest');

  @override
  Future<NotificationDeliveryResult> deliver({
    required String visitId,
    required String reminderText,
  }) async {
    try {
      final value = await _channel.invokeMethod<String>('deliver', {
        'visitId': visitId,
        'reminderText': reminderText,
      });
      return _parseResult(value);
    } on PlatformException {
      return NotificationDeliveryResult.failed;
    }
  }

  static NotificationStatus _parseStatus(Map<dynamic, dynamic> value) {
    return NotificationStatus(
      permission: switch (value['permission']) {
        'allowed' => NotificationPermissionStatus.allowed,
        'unavailable' => NotificationPermissionStatus.unavailable,
        _ => NotificationPermissionStatus.denied,
      },
      lastResult: _parseResultOrNull(value['lastResult'] as String?),
      lastTimestamp: DateTime.tryParse(value['lastTimestamp'] as String? ?? ''),
      lastVisitId: value['lastVisitId'] as String?,
      backgroundDiagnostics:
          (value['backgroundDiagnostics'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(growable: false),
    );
  }

  static NotificationDeliveryResult _parseResult(String? value) =>
      _parseResultOrNull(value) ?? NotificationDeliveryResult.failed;

  static NotificationDeliveryResult? _parseResultOrNull(String? value) =>
      switch (value) {
        'sent' => NotificationDeliveryResult.sent,
        'duplicate' => NotificationDeliveryResult.duplicate,
        'permissionMissing' => NotificationDeliveryResult.permissionMissing,
        'failed' => NotificationDeliveryResult.failed,
        _ => null,
      };
}

final class InMemoryNotificationService implements NotificationService {
  NotificationPermissionStatus permission =
      NotificationPermissionStatus.allowed;
  final List<String> deliveredVisitIds = [];
  NotificationDeliveryResult deliveryResult = NotificationDeliveryResult.sent;
  NotificationStatus currentStatus = const NotificationStatus(
    permission: NotificationPermissionStatus.allowed,
  );

  @override
  Future<NotificationStatus> status() async => currentStatus;

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> resetTest() async => deliveredVisitIds.clear();

  @override
  Future<NotificationDeliveryResult> deliver({
    required String visitId,
    required String reminderText,
  }) async {
    if (permission != NotificationPermissionStatus.allowed) {
      return NotificationDeliveryResult.permissionMissing;
    }
    if (deliveredVisitIds.contains(visitId)) {
      return NotificationDeliveryResult.duplicate;
    }
    if (deliveryResult == NotificationDeliveryResult.sent) {
      deliveredVisitIds.add(visitId);
    }
    return deliveryResult;
  }
}
