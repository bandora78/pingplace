import 'dart:async';

import '../domain/smart_arrival_detection.dart';
import 'geofence_service.dart';

typedef GeofenceListener = void Function();

final class DevelopmentGeofenceController {
  DevelopmentGeofenceController({GeofenceService? service})
    : service = service ?? MethodChannelGeofenceService(),
      engine = SmartArrivalDetectionEngine(
        const SmartArrivalConfig(
          target: TargetLocation(latitude: 32, longitude: 34.8),
        ),
      );

  final GeofenceService service;
  SmartArrivalDetectionEngine engine;
  final List<GeofenceListener> _listeners = [];
  final List<String> _eventLog = [];
  StreamSubscription<GeofenceEvent>? _subscription;

  double latitude = 32;
  double longitude = 34.8;
  double radius = 300;
  GeofencePermissionStatus permission = GeofencePermissionStatus.denied;
  bool registered = false;
  GeofenceEvent? lastEvent;
  String? lastError;

  List<String> get eventLog => List.unmodifiable(_eventLog);
  DetectionState get state => engine.state;

  void addListener(GeofenceListener listener) => _listeners.add(listener);

  void removeListener(GeofenceListener listener) => _listeners.remove(listener);

  Future<void> initialize() async {
    _subscription = service.events.listen(
      _handleEvent,
      onError: (Object error) {
        _fail('BACKGROUND_EVENT_FAILED: $error');
      },
    );
    await refreshPermission();
    try {
      registered = await service.registrationStatus;
      _notifyListeners();
    } catch (error) {
      _fail('REGISTRATION_STATUS_FAILED: $error');
    }
  }

  Future<void> refreshPermission() async {
    try {
      permission = await service.checkPermission();
      _notifyListeners();
    } catch (error) {
      _fail('PERMISSION_CHECK_FAILED: $error');
    }
  }

  Future<void> requestPermission() async {
    try {
      permission = await service.requestPermission();
      _log('PERMISSION_STATUS ${permission.name}');
      if (permission != GeofencePermissionStatus.backgroundAllowed) {
        _log('PERMISSION_MISSING ${permission.name}');
      }
      _notifyListeners();
    } catch (error) {
      _fail('PERMISSION_REQUEST_FAILED: $error');
    }
  }

  Future<void> register() async {
    lastError = null;
    _log('GEOFENCE_REGISTER_REQUESTED');
    if (permission != GeofencePermissionStatus.backgroundAllowed) {
      _log('PERMISSION_MISSING ${permission.name}');
      lastError = 'Background location permission is required.';
      _notifyListeners();
      return;
    }
    try {
      await service.register(
        latitude: latitude,
        longitude: longitude,
        radius: radius,
      );
      registered = true;
      _log('GEOFENCE_REGISTERED radius=${radius.toStringAsFixed(0)}m');
      final armResult = engine.dispatch(const Arm());
      for (final effect in armResult.effects) {
        if (effect.type == DetectionEffectType.stateChanged) {
          _log('STATE ${effect.from!.name} -> ${effect.to!.name}');
        }
      }
    } catch (error) {
      _fail('GEOFENCE_REGISTRATION_FAILED: $error');
    }
  }

  Future<void> remove() async {
    lastError = null;
    try {
      await service.remove();
      registered = false;
      _log('GEOFENCE_REMOVED');
    } catch (error) {
      _fail('GEOFENCE_REMOVE_FAILED: $error');
    }
  }

  void dispose() {
    _subscription?.cancel();
    service.dispose();
    _listeners.clear();
  }

  void _handleEvent(GeofenceEvent event) {
    lastEvent = event;
    _log('BACKGROUND_EVENT_RECEIVED ${event.type.name.toUpperCase()}');
    final eventType = event.type;
    if (event.error != null) {
      _fail('GEOFENCE_EVENT_FAILED: ${event.error}');
      return;
    }
    final result = engine.dispatch(
      eventType == GeofenceEventType.enter
          ? OuterEnter(at: event.at)
          : const OuterExit(),
    );
    _log(
      eventType == GeofenceEventType.enter
          ? 'OUTER_ENTER_RECEIVED'
          : 'OUTER_EXIT_RECEIVED',
    );
    for (final effect in result.effects) {
      if (effect.type == DetectionEffectType.stateChanged) {
        _log('STATE ${effect.from!.name} -> ${effect.to!.name}');
      }
    }
    _notifyListeners();
  }

  void _fail(String message) {
    lastError = message;
    _log(message);
    _notifyListeners();
  }

  void _log(String message) {
    _eventLog.add('${DateTime.now().toIso8601String()} $message');
  }

  void _notifyListeners() {
    for (final listener in List<GeofenceListener>.of(_listeners)) {
      listener();
    }
  }
}
