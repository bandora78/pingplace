import 'dart:async';

import '../domain/smart_arrival_detection.dart';
import '../notification/notification_service.dart';
import '../runtime/arrival_runtime_store.dart';

final class BackgroundArrivalSession {
  BackgroundArrivalSession({
    required this.onDiagnostic,
    required this.onCommand,
    ArrivalRuntimeStore? runtimeStore,
    NotificationService? notificationService,
    this.config,
    DateTime Function()? clock,
  }) : runtimeStore = runtimeStore ?? MethodChannelArrivalRuntimeStore(),
       notificationService =
           notificationService ?? MethodChannelNotificationService(),
       _clock = clock ?? DateTime.now;

  final void Function(String message) onDiagnostic;
  final Future<void> Function(String command) onCommand;
  final ArrivalRuntimeStore runtimeStore;
  final NotificationService notificationService;
  final SmartArrivalConfig? config;
  final DateTime Function() _clock;
  SmartArrivalDetectionEngine? engine;
  Timer? _timeoutTimer;
  Timer? _rearmTimer;
  DateTime? _enteredAt;
  String _reminderText = 'עצור בתחנת דלק יעד';
  bool _preciseVerificationActive = false;
  Future<void> _eventTail = Future<void>.value();

  void dispose() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _rearmTimer?.cancel();
    _rearmTimer = null;
    _preciseVerificationActive = false;
  }

  Future<void> handleEvent(Map<Object?, Object?> payload) {
    final previous = _eventTail;
    final next = previous.then((_) => _handleEvent(payload));
    _eventTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _handleEvent(Map<Object?, Object?> payload) async {
    await _ensureEngine();
    final type = payload['type'] as String?;
    if (type == 'error') {
      final rawError = payload['error'];
      final detail = rawError is String && rawError.trim().isNotEmpty
          ? rawError.trim()
          : 'MISSING_ERROR_DETAIL';
      onDiagnostic('BACKGROUND_EVENT_FAILED: $detail');
      await onCommand('stop');
    } else if (type == 'enter') {
      final latitude = (payload['targetLatitude'] as num?)?.toDouble();
      final longitude = (payload['targetLongitude'] as num?)?.toDouble();
      final timestamp = DateTime.tryParse(
        payload['timestamp'] as String? ?? '',
      );
      if (latitude == null || longitude == null || timestamp == null) {
        onDiagnostic('LOCATION_SERVICE_FAILED: malformed background ENTER');
        await onCommand('stop');
        return;
      }
      if (engine!.state == DetectionState.disarmed) {
        engine = SmartArrivalDetectionEngine(
          (config ??
                  SmartArrivalConfig(
                    target: TargetLocation(
                      latitude: latitude,
                      longitude: longitude,
                    ),
                  ))
              .copyWith(
                target: TargetLocation(
                  latitude: latitude,
                  longitude: longitude,
                ),
              ),
        );
      }
      _enteredAt = timestamp;
      await _process(engine!.dispatch(const Arm()));
      await _process(engine!.dispatch(OuterEnter(at: timestamp)));
    } else if (type == 'exit') {
      if (engine != null) {
        await _process(engine!.dispatch(const OuterExit()));
        if (engine!.state == DetectionState.cooldown ||
            engine!.state == DetectionState.waitingForExit) {
          _startRearmVerification();
          await onCommand('startVerification');
        }
      }
    } else if (type == 'location' && engine != null) {
      if (!_preciseVerificationActive ||
          (engine!.state != DetectionState.approaching &&
              engine!.state != DetectionState.cooldown &&
              engine!.state != DetectionState.waitingForExit)) {
        onDiagnostic('LOCATION_IGNORED precise verifier inactive');
        return;
      }
      final timestamp = DateTime.tryParse(
        payload['timestamp'] as String? ?? '',
      );
      final latitude = (payload['latitude'] as num?)?.toDouble();
      final longitude = (payload['longitude'] as num?)?.toDouble();
      final accuracy = (payload['accuracy'] as num?)?.toDouble();
      if (timestamp == null ||
          latitude == null ||
          longitude == null ||
          accuracy == null) {
        onDiagnostic('LOCATION_SERVICE_FAILED: malformed background sample');
        return;
      }
      await _process(
        engine!.dispatch(
          LocationReceived(
            LocationSample(
              latitude: latitude,
              longitude: longitude,
              accuracy: accuracy,
              timestamp: timestamp,
            ),
          ),
        ),
      );
    } else if (type == 'cooldownElapsed' && engine != null) {
      final timestamp = DateTime.tryParse(
        payload['timestamp'] as String? ?? '',
      );
      if (timestamp != null) {
        await _process(engine!.dispatch(CooldownElapsed(timestamp)));
      }
    } else if (type == 'rearm' && engine != null) {
      final timestamp = DateTime.tryParse(
        payload['timestamp'] as String? ?? '',
      );
      if (timestamp != null) {
        await _process(engine!.dispatch(RearmRadiusCrossed(timestamp)));
      }
    }
  }

  Future<void> _process(DetectionResult result) async {
    // Persist before a stop command can destroy the headless Flutter engine.
    await _saveRuntimeState();
    var stopRequested = false;
    try {
      for (final effect in result.effects) {
        if (effect.type == DetectionEffectType.preciseLocationStopped) {
          // Arrival effects contain this before notificationRequested. Defer
          // the native stop until notification delivery has completed.
          stopRequested = true;
          continue;
        }
        switch (effect.type) {
          case DetectionEffectType.stateChanged:
            onDiagnostic('STATE ${effect.from!.name} -> ${effect.to!.name}');
          case DetectionEffectType.preciseLocationStarted:
            _preciseVerificationActive = true;
            onDiagnostic('PRECISE_LOCATION_STARTED');
            final start = _enteredAt ?? _clock();
            _timeoutTimer?.cancel();
            _timeoutTimer = Timer(engine!.config.approachTimeout, () {
              unawaited(
                _process(
                  engine!.dispatch(
                    ApproachTimedOut(start.add(engine!.config.approachTimeout)),
                  ),
                ),
              );
            });
          case DetectionEffectType.preciseLocationStopped:
            // Handled before the switch so it can be ordered after the
            // notification request.
            break;
          case DetectionEffectType.locationSample:
            onDiagnostic(
              'LOCATION distance=${effect.distance!.toStringAsFixed(1)}m '
              'accuracy=${effect.accuracy!.toStringAsFixed(1)}m',
            );
          case DetectionEffectType.locationRejected:
            onDiagnostic('LOCATION_REJECTED reason=LOW_ACCURACY');
          case DetectionEffectType.innerReached:
            onDiagnostic('INNER_REACHED');
          case DetectionEffectType.notificationRequested:
            onDiagnostic('NOTIFICATION_REQUESTED');
            try {
              await _deliverNotification();
            } catch (error) {
              onDiagnostic('NOTIFICATION_FAILED: $error');
            }
          case DetectionEffectType.exitObservedDuringCooldown:
            onDiagnostic('EXIT_OBSERVED_DURING_COOLDOWN');
          case DetectionEffectType.approachTimeout:
            _timeoutTimer?.cancel();
            _timeoutTimer = null;
            onDiagnostic('APPROACH_TIMEOUT');
        }
      }
    } finally {
      if (stopRequested) {
        _preciseVerificationActive = false;
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        _rearmTimer?.cancel();
        _rearmTimer = null;
        onDiagnostic('PRECISE_LOCATION_STOPPED');
        await _stopService();
      }
    }
    final waitingForExit = result.effects.any(
      (effect) =>
          effect.type == DetectionEffectType.stateChanged &&
          effect.to == DetectionState.waitingForExit,
    );
    if (waitingForExit) await _stopService();
    _scheduleCooldownTimer();
  }

  void _startRearmVerification() {
    if (_preciseVerificationActive) return;
    _preciseVerificationActive = true;
    _rearmTimer?.cancel();
    _rearmTimer = Timer(engine!.config.approachTimeout, () {
      unawaited(_handleRearmTimeout());
    });
    onDiagnostic('PRECISE_LOCATION_STARTED');
  }

  Future<void> _handleRearmTimeout() async {
    if (!_preciseVerificationActive ||
        (engine?.state != DetectionState.cooldown &&
            engine?.state != DetectionState.waitingForExit)) {
      return;
    }
    _preciseVerificationActive = false;
    _rearmTimer = null;
    onDiagnostic('REARM_VERIFICATION_TIMEOUT');
    await _stopService();
  }

  Future<void> _stopService() async {
    try {
      await onCommand('stop');
    } catch (error) {
      onDiagnostic('LOCATION_SERVICE_FAILED while stopping: $error');
    }
  }

  void _scheduleCooldownTimer() {
    final until = engine?.cooldownUntil;
    if (until == null || engine?.state != DetectionState.cooldown) return;
    _timeoutTimer?.cancel();
    final delay = until.difference(_clock());
    _timeoutTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_process(engine!.dispatch(CooldownElapsed(until)))),
    );
  }

  Future<void> _saveRuntimeState() async {
    try {
      await runtimeStore.save(engine!.runtimeSnapshot);
    } catch (error) {
      onDiagnostic('RUNTIME_STATE_SAVE_FAILED: $error');
    }
  }

  Future<void> _ensureEngine() async {
    if (engine != null) return;
    final snapshot = await runtimeStore.load();
    final target =
        snapshot?.target ?? const TargetLocation(latitude: 32, longitude: 34.8);
    engine = SmartArrivalDetectionEngine(
      (config ?? SmartArrivalConfig(target: target)).copyWith(target: target),
      snapshot: snapshot,
    );
    _reminderText = await runtimeStore.loadReminderText();
    onDiagnostic(
      'BACKGROUND_SESSION_RESTORED state=${engine!.state.name.toUpperCase()} '
      'visit=${engine!.visitId ?? 'none'}',
    );
  }

  Future<void> _deliverNotification() async {
    final visitId = engine?.visitId;
    if (visitId == null) {
      onDiagnostic('NOTIFICATION_FAILED: missing visit identity');
      return;
    }
    final result = await notificationService.deliver(
      visitId: visitId,
      reminderText: _reminderText,
    );
    switch (result) {
      case NotificationDeliveryResult.sent:
        onDiagnostic('NOTIFICATION_SENT');
      case NotificationDeliveryResult.duplicate:
        onDiagnostic('NOTIFICATION_SUPPRESSED_DUPLICATE');
      case NotificationDeliveryResult.permissionMissing:
        onDiagnostic('NOTIFICATION_PERMISSION_MISSING');
      case NotificationDeliveryResult.failed:
        onDiagnostic('NOTIFICATION_FAILED');
    }
  }
}

