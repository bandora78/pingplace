import 'dart:async';

import '../domain/smart_arrival_detection.dart';
import '../location/location_service.dart';
import '../notification/notification_service.dart';
import '../runtime/arrival_runtime_store.dart';
import 'geofence_service.dart';

typedef GeofenceListener = void Function();

final class DevelopmentGeofenceController {
  DevelopmentGeofenceController({
    GeofenceService? service,
    LocationService? locationService,
    NotificationService? notificationService,
    ArrivalRuntimeStore? runtimeStore,
    SmartArrivalConfig? config,
    DateTime Function()? clock,
  }) : service = service ?? MethodChannelGeofenceService(),
       locationService = locationService ?? MethodChannelLocationService(),
       notificationService =
           notificationService ?? MethodChannelNotificationService(),
       runtimeStore = runtimeStore ?? MethodChannelArrivalRuntimeStore(),
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
  final NotificationService notificationService;
  final ArrivalRuntimeStore runtimeStore;
  SmartArrivalDetectionEngine engine;
  SmartArrivalConfig _config;
  final DateTime Function() _clock;
  final List<GeofenceListener> _listeners = [];
  Future<void> _operationTail = Future<void>.value();
  int _operationGeneration = 0;
  bool _desiredMonitoring = false;
  final List<String> _eventLog = [];
  StreamSubscription<GeofenceEvent>? _geofenceSubscription;
  StreamSubscription<LocationServiceEvent>? _locationSubscription;
  Timer? _approachTimer;
  Timer? _cooldownTimer;
  int _locationGeneration = 0;
  Future<void>? _initialization;

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
  String reminderText = 'עצור בתחנת דלק יעד';
  NotificationPermissionStatus notificationPermission =
      NotificationPermissionStatus.denied;
  NotificationDeliveryResult? lastNotificationResult;
  DateTime? lastNotificationAt;
  String? lastNotificationVisitId;
  String? currentVisitId;
  List<String> backgroundDiagnostics = const [];
  GeofenceRecoveryStatus recoveryStatus = const GeofenceRecoveryStatus();
  bool initialized = false;

  SmartArrivalConfig get config => _config;
  List<String> get eventLog => List.unmodifiable(_eventLog);
  DetectionState get state => engine.state;

  void addListener(GeofenceListener listener) => _listeners.add(listener);

  void removeListener(GeofenceListener listener) => _listeners.remove(listener);

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    initialized = false;
    await _restoreRuntime();
    try {
      reminderText = await runtimeStore.loadReminderText();
      final notificationStatus = await notificationService.status();
      notificationPermission = notificationStatus.permission;
      lastNotificationResult = notificationStatus.lastResult;
      lastNotificationAt = notificationStatus.lastTimestamp;
      lastNotificationVisitId = notificationStatus.lastVisitId;
      backgroundDiagnostics = notificationStatus.backgroundDiagnostics;
    } catch (error) {
      _fail('NOTIFICATION_STATUS_FAILED: $error');
    }
    _geofenceSubscription = service.events.listen(
      _handleGeofenceEvent,
      onError: (Object error) => _fail('BACKGROUND_EVENT_FAILED: $error'),
    );
    _locationSubscription = locationService.events.listen(
      (event) => unawaited(_handleLocationEvent(event)),
      onError: (Object error) => _handleLocationFailure('$error'),
    );
    await refreshPermission();
    try {
      registered = await service.registrationStatus;
      _desiredMonitoring = registered;
      recoveryStatus = await service.recoveryStatus;
      final savedRegistration = await service.registration;
      if (savedRegistration != null) {
        latitude = savedRegistration.latitude;
        longitude = savedRegistration.longitude;
        radius = savedRegistration.radius;
      }
      _notifyListeners();
    } catch (error) {
      _fail('REGISTRATION_STATUS_FAILED: $error');
    }
    initialized = true;
    _notifyListeners();
  }

  Future<void> refreshPermission() async {
    try {
      permission = await service.checkPermission();
      _notifyListeners();
    } catch (error) {
      _fail('PERMISSION_CHECK_FAILED: $error');
    }
  }

  Future<void> restoreGeofence() {
    _desiredMonitoring = true;
    return _enqueueOperation(() async {
      lastError = null;
      if (!_desiredMonitoring && registered) {
        _fail('GEOFENCE_RECOVERY_BLOCKED desiredMonitoring=false');
        return;
      }
      await _restoreGeofence();
    });
  }

  Future<void> _restoreGeofence() async {
    lastError = null;
    if (permission != GeofencePermissionStatus.backgroundAllowed) {
      _fail(
        'GEOFENCE_RECOVERY_FAILED: background location permission is required.',
      );
      return;
    }
    try {
      registered = await service.restoreRegistration();
      recoveryStatus = await service.recoveryStatus;
      _log(registered ? 'GEOFENCE_RESTORED' : 'BOOT_RECOVERY_FAILED');
      _notifyListeners();
    } catch (error) {
      _fail('BOOT_RECOVERY_FAILED: $error');
      try {
        recoveryStatus = await service.recoveryStatus;
      } catch (_) {}
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

  Future<void> requestNotificationPermission() async {
    try {
      await notificationService.requestPermission();
      final status = await notificationService.status();
      notificationPermission = status.permission;
      _notifyListeners();
    } catch (error) {
      _fail('NOTIFICATION_PERMISSION_FAILED: $error');
    }
  }

  Future<void> openNotificationSettings() => notificationService.openSettings();

  Future<void> setReminderText(String value) async {
    reminderText = value;
    try {
      await runtimeStore.saveReminderText(value);
    } catch (error) {
      _fail('REMINDER_SAVE_FAILED: $error');
    }
    _notifyListeners();
  }

  Future<void> register() {
    _desiredMonitoring = true;
    return _enqueueOperation(() async {
      lastError = null;
      if (!initialized) {
        _fail(
          'INITIALIZATION_INCOMPLETE: wait for PingPlace to finish loading.',
        );
        return;
      }
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
          reminderText: reminderText,
        );
        if (!_desiredMonitoring) {
          _log('GEOFENCE_REGISTER_CALLBACK_STALE');
          return;
        }
        registered = true;
        _log('GEOFENCE_REGISTERED radius=${radius.toStringAsFixed(0)}m');
        await _dispatch(const Arm());
      } catch (error) {
        if (_desiredMonitoring) {
          _fail('GEOFENCE_REGISTRATION_FAILED: ${error.runtimeType}');
        }
      }
    });
  }

  Future<void> remove() {
    _desiredMonitoring = false;
    return _enqueueOperation(() async {
      lastError = null;
      await _stopPreciseLocation();
      try {
        await service.remove();
        if (_desiredMonitoring) {
          _log('GEOFENCE_REMOVE_CALLBACK_STALE');
          return;
        }
        registered = false;
        _log('GEOFENCE_REMOVED');
        _notifyListeners();
      } catch (error) {
        if (!_desiredMonitoring) {
          _fail('GEOFENCE_REMOVE_FAILED: ${error.runtimeType}');
        }
      }
    });
  }

  Future<void> _enqueueOperation(Future<void> Function() operation) {
    final generation = ++_operationGeneration;
    final next = _operationTail.then((_) async {
      if (generation != _operationGeneration && !_desiredMonitoring) return;
      await operation();
    });
    _operationTail = next.catchError((Object _) {});
    return next;
  }

  void resetTest() {
    arrivalConfirmed = false;
    latestLatitude = null;
    latestLongitude = null;
    latestDistance = null;
    latestAccuracy = null;
    latestLocationTimestamp = null;
    approachDeadline = null;
    currentVisitId = null;
    lastNotificationResult = null;
    lastNotificationAt = null;
    unawaited(notificationService.resetTest());
    unawaited(_dispatch(const ResetTest()));
  }

  void dispose() {
    _geofenceSubscription?.cancel();
    _locationSubscription?.cancel();
    _approachTimer?.cancel();
    _cooldownTimer?.cancel();
    _locationGeneration++;
    _operationGeneration++;
    _desiredMonitoring = false;
    unawaited(locationService.stop());
    locationService.dispose();
    service.dispose();
    _listeners.clear();
  }

  Future<void> _handleGeofenceEvent(GeofenceEvent event) async {
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
    await _dispatch(
      eventType == GeofenceEventType.enter
          ? OuterEnter(at: event.at)
          : const OuterExit(),
    );
    if (eventType == GeofenceEventType.exit &&
        (engine.state == DetectionState.cooldown ||
            engine.state == DetectionState.waitingForExit) &&
        !preciseLocationActive) {
      _startPreciseLocation();
    }
  }

  Future<void> _handleLocationEvent(LocationServiceEvent event) async {
    if (event.isFailure) {
      _handleLocationFailure(event.error!);
      return;
    }
    final sample = event.sample!;
    if (!preciseLocationActive ||
        (engine.state != DetectionState.approaching &&
            engine.state != DetectionState.cooldown &&
            engine.state != DetectionState.waitingForExit)) {
      _log('LOCATION_IGNORED precise verifier inactive');
      return;
    }
    latestLatitude = sample.latitude;
    latestLongitude = sample.longitude;
    latestAccuracy = sample.accuracy;
    latestLocationTimestamp = sample.timestamp;
    final result = await _dispatch(LocationReceived(sample));
    final locationEffect = result.effects.firstWhere(
      (effect) => effect.type == DetectionEffectType.locationSample,
      orElse: () => const DetectionEffect(DetectionEffectType.locationSample),
    );
    latestDistance = locationEffect.distance;
    _notifyListeners();
  }

  Future<void> _handleLocationFailure(String message) async {
    _fail('LOCATION_SERVICE_FAILED: $message');
    if (engine.state == DetectionState.approaching) {
      await _dispatch(const Disarm());
    }
  }

  Future<DetectionResult> _dispatch(DetectionEvent event) async {
    if (event is OuterEnter && engine.state == DetectionState.armed) {
      currentVisitId = engine.visitId;
    }
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
            currentVisitId = engine.visitId;
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
          _log('NOTIFICATION_REQUESTED');
          await _deliverNotification();
        case DetectionEffectType.exitObservedDuringCooldown:
          _log('EXIT_OBSERVED_DURING_COOLDOWN');
        case DetectionEffectType.approachTimeout:
          _log('APPROACH_TIMEOUT');
      }
    }
    currentVisitId = engine.visitId;
    _scheduleCooldownTimer();
    try {
      await runtimeStore.save(engine.runtimeSnapshot);
    } catch (error) {
      final message = 'RUNTIME_STATE_SAVE_FAILED: $error';
      if (lastError == null) {
        _fail(message);
      } else {
        _log(message);
      }
    }
    _notifyListeners();
    return result;
  }

  void _scheduleCooldownTimer() {
    final until = engine.cooldownUntil;
    if (until == null || engine.state != DetectionState.cooldown) {
      _cooldownTimer?.cancel();
      _cooldownTimer = null;
      return;
    }
    _cooldownTimer?.cancel();
    final delay = until.difference(_clock());
    _cooldownTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_dispatch(CooldownElapsed(until))),
    );
  }

  Future<void> _deliverNotification() async {
    final visitId = engine.visitId;
    if (visitId == null) {
      _fail('NOTIFICATION_FAILED: missing visit identity');
      return;
    }
    try {
      final result = await notificationService.deliver(
        visitId: visitId,
        reminderText: reminderText,
      );
      lastNotificationResult = result;
      lastNotificationAt = _clock();
      lastNotificationVisitId = visitId;
      switch (result) {
        case NotificationDeliveryResult.sent:
          _log('NOTIFICATION_SENT');
        case NotificationDeliveryResult.duplicate:
          _log('NOTIFICATION_SUPPRESSED_DUPLICATE');
        case NotificationDeliveryResult.permissionMissing:
          _log('NOTIFICATION_PERMISSION_MISSING');
        case NotificationDeliveryResult.failed:
          _fail('NOTIFICATION_FAILED');
      }
    } catch (error) {
      _fail('NOTIFICATION_FAILED: $error');
    }
  }

  Future<void> _restoreRuntime() async {
    try {
      final snapshot = await runtimeStore.load();
      if (snapshot == null) return;
      final target = snapshot.target;
      if (target != null) {
        _config = _config.copyWith(target: target);
        latitude = target.latitude;
        longitude = target.longitude;
      }
      engine = SmartArrivalDetectionEngine(_config, snapshot: snapshot);
      currentVisitId = snapshot.visitId;
      if (engine.state == DetectionState.approaching) {
        _startPreciseLocation();
      }
      _log('RUNTIME_STATE_RESTORED ${engine.state.name.toUpperCase()}');
      _notifyListeners();
    } catch (error) {
      _fail('RUNTIME_STATE_LOAD_FAILED: $error');
    }
  }

  void _startPreciseLocation() {
    if (preciseLocationActive) return;
    preciseLocationActive = true;
    final enteredAt = latestLocationTimestamp ?? _clock();
    final approachStartedAt = engine.approachStartedAt ?? enteredAt;
    approachDeadline = approachStartedAt.add(_config.approachTimeout);
    _approachTimer?.cancel();
    final remaining = approachDeadline!.difference(_clock());
    _approachTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        if (engine.state == DetectionState.approaching) {
          _dispatch(ApproachTimedOut(approachDeadline ?? _clock()));
        }
      },
    );
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
    if (!latitude.isFinite || latitude < -90 || latitude > 90) {
      _fail('INVALID_COORDINATES: latitude must be between -90 and 90.');
      return false;
    }
    if (!longitude.isFinite || longitude < -180 || longitude > 180) {
      _fail('INVALID_COORDINATES: longitude must be between -180 and 180.');
      return false;
    }
    if (!radius.isFinite || radius <= 0) {
      _fail('INVALID_COORDINATES: radius must be greater than zero.');
      return false;
    }
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
