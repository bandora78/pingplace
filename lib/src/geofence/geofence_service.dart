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

abstract interface class GeofenceService {
  Stream<GeofenceEvent> get events;

  Future<GeofencePermissionStatus> checkPermission();

  Future<GeofencePermissionStatus> requestPermission();

  Future<bool> get registrationStatus;

  Future<GeofenceRegistration?> get registration async => null;

  Future<void> register({
    required double latitude,
    required double longitude,
    required double radius,
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
  Future<void> register({
    required double latitude,
    required double longitude,
    required double radius,
  }) => _methodChannel.invokeMethod<void>('register', {
    'latitude': latitude,
    'longitude': longitude,
    'radius': radius,
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
