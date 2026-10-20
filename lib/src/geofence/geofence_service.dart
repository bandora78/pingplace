import 'package:flutter/services.dart';

enum GeofencePermissionStatus { denied, foregroundOnly, backgroundAllowed }

enum GeofenceEventType { enter, exit, error }

final class GeofenceEvent {
  const GeofenceEvent({required this.type, required this.at, this.error});

  final GeofenceEventType type;
  final DateTime at;
  final String? error;
}

final class GeofenceRegistration {
  const GeofenceRegistration({
    required this.latitude,
    required this.longitude,
    required this.radius,
  });

  final double latitude;
  final double longitude;
  final double radius;
}

final class GeofenceRecoveryStatus {
  const GeofenceRecoveryStatus({
    this.registrationConfirmed = false,
    this.registrationState,
    this.desiredMonitoring = false,
    this.recoveryGeneration = 0,
    this.schemaVersion,
    this.reminderText,
    this.lastRecoveryAttempt,
    this.lastRecoverySuccess,
    this.lastRecoveryFailure,
    this.lastBackgroundEvent,
    this.lastBackgroundFailure,
    this.diagnostics = const [],
  });

  final bool registrationConfirmed;
  final String? registrationState;
  final bool desiredMonitoring;
  final int recoveryGeneration;
  final int? schemaVersion;
  final String? reminderText;
  final DateTime? lastRecoveryAttempt;
  final DateTime? lastRecoverySuccess;
  final String? lastRecoveryFailure;
  final DateTime? lastBackgroundEvent;
  final String? lastBackgroundFailure;
  final List<String> diagnostics;
}

final class GeofenceDiagnosticsSnapshot {
  const GeofenceDiagnosticsSnapshot({
    this.androidVersion,
    this.manufacturer,
    this.model,
    this.locationServicesEnabled,
    this.batteryOptimizationIgnored,
    this.desiredGeofenceCount = 0,
    this.trackedGeofenceCount = 0,
    this.pendingRemovalTombstoneCount = 0,
    this.persistedConfigurationGeneration,
    this.lastReconciliationAttempt,
    this.lastReconciliationResult,
    this.lastBootRecoveryAttempt,
    this.lastBootRecoveryResult,
    this.lastRegistrationError,
    this.lastRemovalError,
    this.events = const [],
  });

  final String? androidVersion;
  final String? manufacturer;
  final String? model;
  final bool? locationServicesEnabled;
  final bool? batteryOptimizationIgnored;
  final int desiredGeofenceCount;
  final int trackedGeofenceCount;
  final int pendingRemovalTombstoneCount;
  final int? persistedConfigurationGeneration;
  final DateTime? lastReconciliationAttempt;
  final String? lastReconciliationResult;
  final DateTime? lastBootRecoveryAttempt;
  final String? lastBootRecoveryResult;
  final String? lastRegistrationError;
  final String? lastRemovalError;
  final List<String> events;
}

abstract interface class GeofenceService {
  Stream<GeofenceEvent> get events;

  Future<GeofencePermissionStatus> checkPermission();

  Future<GeofencePermissionStatus> requestPermission();

  Future<bool> get registrationStatus;

  Future<GeofenceRegistration?> get registration async => null;

  Future<GeofenceRecoveryStatus> get recoveryStatus async =>
      const GeofenceRecoveryStatus();

  Future<GeofenceDiagnosticsSnapshot> get diagnostics async =>
      const GeofenceDiagnosticsSnapshot();

  Future<void> clearDiagnostics() async {}

  Future<void> shareDiagnostics(String report) async {}

  Future<bool> restoreRegistration() async => false;

  Future<void> register({
    required double latitude,
    required double longitude,
    required double radius,
    String? reminderText,
  });

  Future<void> remove();

  void dispose();
}

final class MethodChannelGeofenceService implements GeofenceService {
  MethodChannelGeofenceService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel = methodChannel ?? const MethodChannel(_methodName),
       _eventChannel = eventChannel ?? const EventChannel(_eventName);

  static const _methodName = 'pingplace/geofence';
  static const _eventName = 'pingplace/geofence/events';

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<GeofenceEvent>? _events;

  @override
  Stream<GeofenceEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .map((event) => _parseEvent(event as Map<dynamic, dynamic>));

  @override
  Future<GeofencePermissionStatus> checkPermission() async {
    final value = await _methodChannel.invokeMethod<String>('checkPermission');
    return _parsePermission(value);
  }

  @override
  Future<GeofencePermissionStatus> requestPermission() async {
    final value = await _methodChannel.invokeMethod<String>(
      'requestPermission',
    );
    return _parsePermission(value);
  }

  @override
  Future<bool> get registrationStatus async =>
      await _methodChannel.invokeMethod<bool>('registrationStatus') ?? false;

  @override
  Future<GeofenceRegistration?> get registration async {
    final value = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'registrationDetails',
    );
    if (value == null) return null;
    final latitude = (value['latitude'] as num?)?.toDouble();
    final longitude = (value['longitude'] as num?)?.toDouble();
    final radius = (value['radius'] as num?)?.toDouble();
    if (latitude == null || longitude == null || radius == null) return null;
    return GeofenceRegistration(
      latitude: latitude,
      longitude: longitude,
      radius: radius,
    );
  }

  @override
  Future<GeofenceRecoveryStatus> get recoveryStatus async {
    final value = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'recoveryStatus',
    );
    final map = value ?? const {};
    DateTime? parseDate(Object? raw) =>
        raw is String ? DateTime.tryParse(raw) : null;
    return GeofenceRecoveryStatus(
      registrationConfirmed: map['registrationConfirmed'] == true,
      registrationState: map['registrationState'] as String?,
      desiredMonitoring: map['desiredMonitoring'] == true,
      recoveryGeneration: (map['recoveryGeneration'] as num?)?.toInt() ?? 0,
      schemaVersion: (map['schemaVersion'] as num?)?.toInt(),
      reminderText: map['reminderText'] as String?,
      lastRecoveryAttempt: parseDate(map['lastRecoveryAttempt']),
      lastRecoverySuccess: parseDate(map['lastRecoverySuccess']),
      lastRecoveryFailure: map['lastRecoveryFailure'] as String?,
      lastBackgroundEvent: parseDate(map['lastBackgroundEvent']),
      lastBackgroundFailure: map['lastBackgroundFailure'] as String?,
      diagnostics: (map['diagnostics'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }

  @override
  Future<GeofenceDiagnosticsSnapshot> get diagnostics async {
    final value = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'diagnosticSnapshot',
    );
    final map = value ?? const {};
    DateTime? parseDate(Object? raw) =>
        raw is String ? DateTime.tryParse(raw) : null;
    return GeofenceDiagnosticsSnapshot(
      androidVersion: map['androidVersion'] as String?,
      manufacturer: map['manufacturer'] as String?,
      model: map['model'] as String?,
      locationServicesEnabled: map['locationServicesEnabled'] as bool?,
      batteryOptimizationIgnored: map['batteryOptimizationIgnored'] as bool?,
      desiredGeofenceCount: (map['desiredGeofenceCount'] as num?)?.toInt() ?? 0,
      trackedGeofenceCount: (map['trackedGeofenceCount'] as num?)?.toInt() ?? 0,
      pendingRemovalTombstoneCount:
          (map['pendingRemovalTombstoneCount'] as num?)?.toInt() ?? 0,
      persistedConfigurationGeneration:
          (map['persistedConfigurationGeneration'] as num?)?.toInt(),
      lastReconciliationAttempt: parseDate(map['lastReconciliationAttempt']),
      lastReconciliationResult: map['lastReconciliationResult'] as String?,
      lastBootRecoveryAttempt: parseDate(map['lastBootRecoveryAttempt']),
      lastBootRecoveryResult: map['lastBootRecoveryResult'] as String?,
      lastRegistrationError: map['lastRegistrationError'] as String?,
      lastRemovalError: map['lastRemovalError'] as String?,
      events: (map['events'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }

  @override
  Future<void> clearDiagnostics() =>
      _methodChannel.invokeMethod<void>('clearDiagnostics');

  @override
  Future<void> shareDiagnostics(String report) =>
      _methodChannel.invokeMethod<void>('shareDiagnostics', report);

  @override
  Future<bool> restoreRegistration() async =>
      await _methodChannel.invokeMethod<bool>('restoreGeofence') ?? false;

  @override
  Future<void> register({
    required double latitude,
    required double longitude,
    required double radius,
    String? reminderText,
  }) => _methodChannel.invokeMethod<void>('register', {
    'latitude': latitude,
    'longitude': longitude,
    'radius': radius,
    'reminderText': reminderText,
  });

  @override
  Future<void> remove() => _methodChannel.invokeMethod<void>('remove');

  @override
  void dispose() {}

  static GeofencePermissionStatus _parsePermission(String? value) {
    return switch (value) {
      'backgroundAllowed' => GeofencePermissionStatus.backgroundAllowed,
      'foregroundOnly' => GeofencePermissionStatus.foregroundOnly,
      _ => GeofencePermissionStatus.denied,
    };
  }

  static GeofenceEvent _parseEvent(Map<dynamic, dynamic> value) {
    final type = value['type'] as String?;
    final timestamp = DateTime.tryParse(value['timestamp'] as String? ?? '');
    final error = value['error'] as String?;
    final eventType = switch (type) {
      'enter' => GeofenceEventType.enter,
      'exit' => GeofenceEventType.exit,
      _ => GeofenceEventType.error,
    };
    return GeofenceEvent(
      type: eventType,
      at: timestamp ?? DateTime.now(),
      error:
          error ??
          (eventType == GeofenceEventType.error
              ? 'Unknown geofence event type: $type'
              : null),
    );
  }
}
