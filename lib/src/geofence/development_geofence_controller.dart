import 'dart:async';

import '../domain/smart_arrival_detection.dart';
import '../location/location_service.dart';
import 'geofence_service.dart';

typedef GeofenceListener = void Function();

final class DevelopmentGeofenceController {
  DevelopmentGeofenceController({
    GeofenceService? service,
    LocationService? locationService,
    SmartArrivalConfig? config,
    DateTime Function()? clock,
  }) : service = service ?? MethodChannelGeofenceService(),
       locationService = locationService ?? MethodChannelLocationService(),
       _config =
           config ??
           const SmartArrivalConfig(
             target: TargetLocation(latitude: 32, longitude: 34.8),
           ),
       _clock = clock ?? DateTime.now,
       engine = SmartArrivalDetectionEngine(
         config ??
             const SmartArrivalConfig(
               target: TargetLocation(latitude: 32, longitude: 34.8),
             ),
       );

  final GeofenceService service;
  final LocationService locationService;
  SmartArrivalDetectionEngine engine;
  SmartArrivalConfig _config;
  final DateTime Function() _clock;
  final List<GeofenceListener> _listeners = [];
  final List<String> _eventLog = [];
  StreamSubscription<GeofenceEvent>? _geofenceSubscription;
  StreamSubscription<LocationServiceEvent>? _locationSubscription;
  Timer? _approachTimer;
  int _locationGeneration = 0;

  double latitude = 32;
  double longitude = 34.8;
  double radius = 300;
  GeofencePermissionStatus permission = GeofencePermissionStatus.denied;
  bool registered = false;
  bool preciseLocationActive = false;
  bool arrivalConfirmed = false;
  GeofenceEvent? lastEvent;
  String? lastError;
  double? latestLatitude;
  double? latestLongitude;
  double? latestDistance;
  double? latestAccuracy;
  DateTime? latestLocationTimestamp;
  DateTime? approachDeadline;
  DateTime? lastArrivalAt;

  SmartArrivalConfig get config => _config;
  List<String> get eventLog => List.unmodifiable(_eventLog);
  DetectionState get state => engine.state;

  void addListener(GeofenceListener listener) => _listeners.add(listener);

  void removeListener(GeofenceListener listener) => _listeners.remove(listener);

  Future<void> initialize() async {
    _geofenceSubscription = service.events.listen(
      _handleGeofenceEvent,
      onError: (Object error) => _fail('BACKGROUND_EVENT_FAILED: $error'),
    );
    _locationSubscription = locationService.events.listen(
      _handleLocationEvent,
      onError: (Object error) => _handleLocationFailure('$error'),
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
    if (!_syncTarget()) return;
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
      _dispatch(const Arm());
    } catch (error) {
      _fail('GEOFENCE_REGISTRATION_FAILED: $error');
    }
  }

  Future<void> remove() async {
    lastError = null;
    await _stopPreciseLocation();
    try {
      await service.remove();
      registered = false;
      _log('GEOFENCE_REMOVED');
      _notifyListeners();
    } catch (error) {
      _fail('GEOFENCE_REMOVE_FAILED: $error');
    }
  }

  void resetTest() {
    arrivalConfirmed = false;
    latestLatitude = null;
    latestLongitude = null;
    latestDistance = null;
    latestAccuracy = null;
    latestLocationTimestamp = null;
    approachDeadline = null;
    _dispatch(const ResetTest());
  }

  void dispose() {
    _geofenceSubscription?.cancel();
    _locationSubscription?.cancel();
    _approachTimer?.cancel();
    _locationGeneration++;
    unawaited(locationService.stop());
    locationService.dispose();
    service.dispose();
    _listeners.clear();
  }

  void _handleGeofenceEvent(GeofenceEvent event) {
    lastEvent = event;
    _log('BACKGROUND_EVENT_RECEIVED ${event.type.name.toUpperCase()}');
    final eventType = event.type;
    if (eventType == GeofenceEventType.error || event.error != null) {
      _fail(
        'GEOFENCE_EVENT_FAILED: ${event.error ?? 'Unknown geofence event'}',
      );
      return;
    }
    _log(
      eventType == GeofenceEventType.enter
          ? 'OUTER_ENTER_RECEIVED'
          : 'OUTER_EXIT_RECEIVED',
    );
    _dispatch(
      eventType == GeofenceEventType.enter
          ? OuterEnter(at: event.at)
          : const OuterExit(),
    );
  }

  void _handleLocationEvent(LocationServiceEvent event) {
    if (event.isFailure) {
      _handleLocationFailure(event.error!);
      return;
    }
    final sample = event.sample!;
    if (!preciseLocationActive || engine.state != DetectionState.approaching) {
      _log('LOCATION_IGNORED precise verifier inactive');
      return;
    }
    latestLatitude = sample.latitude;
    latestLongitude = sample.longitude;
    latestAccuracy = sample.accuracy;
    latestLocationTimestamp = sample.timestamp;
    final result = _dispatch(LocationReceived(sample));
    final locationEffect = result.effects.firstWhere(
      (effect) => effect.type == DetectionEffectType.locationSample,
      orElse: () => const DetectionEffect(DetectionEffectType.locationSample),
    );
    latestDistance = locationEffect.distance;
    _notifyListeners();
  }

  void _handleLocationFailure(String message) {
    _fail('LOCATION_SERVICE_FAILED: $message');
    if (engine.state == DetectionState.approaching) {
      _dispatch(const Disarm());
    }
  }

  DetectionResult _dispatch(DetectionEvent event) {
    final result = engine.dispatch(event);
    for (final effect in result.effects) {
      switch (effect.type) {
        case DetectionEffectType.preciseLocationStarted:
          _startPreciseLocation();
        case DetectionEffectType.preciseLocationStopped:
          unawaited(_stopPreciseLocation());
        case DetectionEffectType.stateChanged:
          _log('STATE ${effect.from!.name} -> ${effect.to!.name}');
          if (effect.to == DetectionState.arrived) {
            arrivalConfirmed = true;
            lastArrivalAt = latestLocationTimestamp ?? _clock();
          }
        case DetectionEffectType.locationSample:
          if (effect.distance != null && effect.accuracy != null) {
            _log(
              'LOCATION distance=${effect.distance!.toStringAsFixed(1)}m '
              'accuracy=${effect.accuracy!.toStringAsFixed(1)}m',
            );
          }
        case DetectionEffectType.locationRejected:
          _log(
            'LOCATION_REJECTED reason=${effect.reason == LocationRejectionReason.lowAccuracy ? 'LOW_ACCURACY' : effect.reason!.name.toUpperCase()}',
          );
        case DetectionEffectType.innerReached:
          _log('INNER_REACHED');
        case DetectionEffectType.notificationRequested:
          _log('NOTIFICATION_REQUESTED (diagnostic only)');
        case DetectionEffectType.exitObservedDuringCooldown:
          _log('EXIT_OBSERVED_DURING_COOLDOWN');
        case DetectionEffectType.approachTimeout:
          _log('APPROACH_TIMEOUT');
      }
    }
    _notifyListeners();
    return result;
  }

  void _startPreciseLocation() {
    if (preciseLocationActive) return;
    preciseLocationActive = true;
    final enteredAt = latestLocationTimestamp ?? _clock();
    approachDeadline = enteredAt.add(_config.approachTimeout);
    _approachTimer?.cancel();
    _approachTimer = Timer(_config.approachTimeout, () {
      if (engine.state == DetectionState.approaching) {
        _dispatch(ApproachTimedOut(approachDeadline ?? _clock()));
      }
    });
    _log('PRECISE_LOCATION_STARTED');
    _notifyListeners();
    final generation = ++_locationGeneration;
    unawaited(
      locationService
          .start()
          .then((_) {
            if (!preciseLocationActive || generation != _locationGeneration) {
              unawaited(locationService.stop());
            }
          })
          .catchError((Object error) {
            if (generation == _locationGeneration) {
              _handleLocationFailure('$error');
            }
          }),
    );
  }

  Future<void> _stopPreciseLocation() async {
    final wasActive = preciseLocationActive;
    preciseLocationActive = false;
    approachDeadline = null;
    _approachTimer?.cancel();
    _approachTimer = null;
    _locationGeneration++;
    if (wasActive) {
      _log('PRECISE_LOCATION_STOPPED');
      _notifyListeners();
    }
    try {
      await locationService.stop();
    } catch (error) {
      _fail('LOCATION_SERVICE_FAILED while stopping: $error');
    }
  }

  bool _syncTarget() {
    final target = TargetLocation(latitude: latitude, longitude: longitude);
    if (target.latitude == _config.target.latitude &&
        target.longitude == _config.target.longitude) {
      return true;
    }
    if (engine.state != DetectionState.disarmed) {
      _fail('TARGET_UPDATE_REQUIRES_DISARMED_STATE');
      return false;
    }
    _config = _config.copyWith(target: target);
    engine = SmartArrivalDetectionEngine(_config);
    return true;
  }

  void _fail(String message) {
    lastError = message;
    _log(message);
    _notifyListeners();
  }

  void _log(String message) {
    _eventLog.add('${_clock().toIso8601String()} $message');
  }

  void _notifyListeners() {
    for (final listener in List<GeofenceListener>.of(_listeners)) {
      listener();
    }
  }
}
