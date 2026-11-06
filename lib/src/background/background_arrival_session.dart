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
  Timer? _exitConfirmationTimer;
  DateTime? _enteredAt;
  _ApproachStats? _approach;
  String? _sampleDetail;
  String _reminderText = 'עצור בתחנת דלק יעד';
  bool _preciseVerificationActive = false;
  bool _exitObservedLogged = false;
  int _ignoredFixes = 0;
  Future<void> _eventTail = Future<void>.value();

  /// Log the first ignored fix of a run, then every [_ignoredFixLogEvery]th
  /// with a count, so fixes routed to a place that does not need them cannot
  /// push visit and notification evidence out of the bounded log.
  static const _ignoredFixLogEvery = 30;

  void dispose() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _rearmTimer?.cancel();
    _rearmTimer = null;
    _exitConfirmationTimer?.cancel();
    _exitConfirmationTimer = null;
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
      final rawText = rawError is String ? rawError.trim() : '';
      final detail = rawText.isNotEmpty && rawText.toLowerCase() != 'null'
          ? rawText
          : 'MISSING_ERROR_DETAIL';
      onDiagnostic('BACKGROUND_EVENT_FAILED: $detail');
      await onCommand('stop');
    } else if (type == 'enter') {
      onDiagnostic('BACKGROUND_ENTER_RECEIVED');
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
      final payloadReminder = payload['reminderText'];
      if (payloadReminder is String && payloadReminder.trim().isNotEmpty) {
        _reminderText = payloadReminder.trim();
      }
      _enteredAt = timestamp;
      // An exit observed during a cooldown that has since expired re-arms the
      // place now, so this ENTER starts a new visit instead of being ignored.
      // APP-10D: the re-arm must not release the place's precise location.
      // Build 19 forwarded the re-arm's stop to the native service, which
      // stopped routing fixes to this place (and stopped GPS when no other
      // place was verifying) just before this ENTER started the approach.
      await _applyElapsedCooldown(releaseVerification: false);
      switch (engine!.state) {
        case DetectionState.approaching:
          // Persisted APPROACHING without a running verifier means the
          // verifying process died (watchdog, OS kill). Build 17 ignored the
          // ENTER in that state, so the place could never notify again.
          onDiagnostic(
            _preciseVerificationActive
                ? 'ENTER_DURING_ACTIVE_APPROACH window restarted '
                      'visit=${engine!.visitId ?? 'none'}'
                : 'APPROACH_RESTARTED_FROM_PERSISTED_STATE '
                      'since=${_iso(engine!.approachStartedAt)} '
                      'visit=${engine!.visitId ?? 'none'}',
          );
          _exitConfirmationTimer?.cancel();
          _exitConfirmationTimer = null;
          _approach = _ApproachStats(timestamp);
          await _process(engine!.dispatch(RestartApproach(timestamp)));
          return;
        case DetectionState.cooldown:
          onDiagnostic(
            'ENTER_SUPPRESSED reason=COOLDOWN '
            'until=${_iso(engine!.cooldownUntil)} '
            'exitObserved=${engine!.exitObservedDuringCooldown} '
            'lastVisit=${engine!.visitId ?? 'none'}',
          );
          if (!_preciseVerificationActive) await _stopService();
          return;
        case DetectionState.waitingForExit:
          onDiagnostic(
            'ENTER_SUPPRESSED reason=WAITING_FOR_EXIT '
            'rearm needs a precise sample >= '
            '${engine!.config.rearmRadius.round()}m after the last arrival '
            'lastVisit=${engine!.visitId ?? 'none'}',
          );
          if (!_preciseVerificationActive) await _stopService();
          return;
        case DetectionState.disarmed:
        case DetectionState.armed:
        case DetectionState.arrived:
          break;
      }
      _approach = _ApproachStats(timestamp);
      await _process(engine!.dispatch(const Arm()));
      await _process(engine!.dispatch(OuterEnter(at: timestamp)));
      if (engine!.state == DetectionState.approaching) {
        onDiagnostic('APPROACH_STARTED visit=${engine!.visitId ?? 'none'}');
      }
    } else if (type == 'exit') {
      onDiagnostic('BACKGROUND_EXIT_RECEIVED');
      if (engine != null) {
        final needsRearm =
            engine!.state == DetectionState.cooldown ||
            engine!.state == DetectionState.waitingForExit;
        // Start verification before applying an already elapsed cooldown, so
        // the transition to waiting-for-exit cannot stop the service that
        // this EXIT needs to measure the re-arm distance.
        if (needsRearm) _startRearmVerification();
        await _applyElapsedCooldown();
        final exitAt =
            DateTime.tryParse(payload['timestamp'] as String? ?? '') ??
            _clock();
        await _process(
          engine!.dispatch(
            OuterExit(at: exitAt, immediate: !_preciseVerificationActive),
          ),
        );
        if (engine!.state == DetectionState.cooldown ||
            engine!.state == DetectionState.waitingForExit) {
          _startRearmVerification();
          await onCommand('startVerification');
        } else if (needsRearm) {
          onDiagnostic(
            'REARMED_ON_EXIT state=${engine!.state.name.toUpperCase()}',
          );
        }
      }
    } else if (type == 'location' && engine != null) {
      if (!_preciseVerificationActive ||
          (engine!.state != DetectionState.approaching &&
              engine!.state != DetectionState.cooldown &&
              engine!.state != DetectionState.waitingForExit)) {
        _ignoredFixes++;
        if (_ignoredFixes == 1 || _ignoredFixes % _ignoredFixLogEvery == 0) {
          onDiagnostic(
            'LOCATION_IGNORED reason=NO_ACTIVE_VERIFICATION '
            'state=${engine!.state.name.toUpperCase()} '
            'count=$_ignoredFixes',
          );
        }
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
      if (engine!.state == DetectionState.approaching) {
        _approach?.record(
          distanceBetween(
            engine!.config.target,
            LocationSample(
              latitude: latitude,
              longitude: longitude,
              accuracy: accuracy,
              timestamp: timestamp,
            ),
          ),
          accuracy,
          timestamp,
          accepted: accuracy <= engine!.config.maxAcceptedAccuracy,
          receivedAt: _clock(),
        );
      }
      // One line per fix: the persisted log is bounded, and a visit's ENTER
      // must not scroll out while samples arrive every two seconds.
      _sampleDetail =
          'at=${_iso(timestamp)} '
          'lat=${latitude.toStringAsFixed(5)} '
          'lon=${longitude.toStringAsFixed(5)} '
          'age=${_clock().difference(timestamp).inSeconds}s';
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

  /// [releaseVerification] false keeps the native service routing fixes to
  /// this place when the result stops precise location, because the event
  /// being handled is about to start a new approach that needs them.
  Future<void> _process(
    DetectionResult result, {
    bool releaseVerification = true,
  }) async {
    // Persist before a stop command can destroy the headless Flutter engine.
    await _saveRuntimeState();
    _summarizeApproach(result);
    var stopRequested = false;
    var rearmVerificationComplete = false;
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
            if (effect.to == DetectionState.armed) _exitObservedLogged = false;
          case DetectionEffectType.preciseLocationStarted:
            _preciseVerificationActive = true;
            _ignoredFixes = 0;
            onDiagnostic('PRECISE_LOCATION_STARTED');
            // APP-10D: a stop sent while handling an earlier event can reach
            // the native service after this place's new ENTER registered it,
            // and remove it again. Re-registering here, before this event is
            // handled, keeps the service (which waits for this event) and
            // the place's fixes for the new approach. Idempotent natively.
            await onCommand('startVerification');
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
            final detail = _sampleDetail;
            _sampleDetail = null;
            onDiagnostic(
              'LOCATION distance=${effect.distance!.toStringAsFixed(1)}m '
              'accuracy=${effect.accuracy!.toStringAsFixed(1)}m'
              '${detail == null ? '' : ' $detail'}',
            );
          case DetectionEffectType.locationRejected:
            onDiagnostic(
              'LOCATION_REJECTED reason=LOW_ACCURACY '
              'accuracy=${effect.accuracy!.toStringAsFixed(1)}m '
              'max=${engine!.config.maxAcceptedAccuracy.round()}m',
            );
          case DetectionEffectType.innerReached:
            onDiagnostic('INNER_REACHED');
          case DetectionEffectType.notificationRequested:
            onDiagnostic(
              'NOTIFICATION_REQUESTED visit=${engine?.visitId ?? 'none'}',
            );
            try {
              await _deliverNotification();
            } catch (error) {
              onDiagnostic('NOTIFICATION_FAILED: $error');
            }
          case DetectionEffectType.exitObservedDuringCooldown:
            // The engine reports this for every fix beyond the re-arm radius.
            // One is enough: the place re-arms when its cooldown ends.
            if (!_exitObservedLogged) {
              _exitObservedLogged = true;
              onDiagnostic(
                'EXIT_OBSERVED_DURING_COOLDOWN '
                'rearmAt=${_iso(engine!.cooldownUntil)}',
              );
            }
            if (_preciseVerificationActive &&
                engine!.state == DetectionState.cooldown) {
              rearmVerificationComplete = true;
            }
          case DetectionEffectType.approachTimeout:
            _timeoutTimer?.cancel();
            _timeoutTimer = null;
            onDiagnostic('APPROACH_TIMEOUT');
          case DetectionEffectType.exitAwaitingConfirmation:
            final window = engine!.config.exitConfirmationWindow;
            onDiagnostic(
              'EXIT_AWAITING_PRECISE_CONFIRMATION '
              'lastDistance=${effect.distance?.toStringAsFixed(1) ?? 'none'} '
              'window=${window.inSeconds}s',
            );
            final reportedAt = effect.timestamp ?? _clock();
            _exitConfirmationTimer?.cancel();
            _exitConfirmationTimer = Timer(window, () {
              _exitConfirmationTimer = null;
              unawaited(
                _process(
                  engine!.dispatch(
                    ExitConfirmationElapsed(reportedAt.add(window)),
                  ),
                ),
              );
            });
          case DetectionEffectType.exitConfirmed:
            _exitConfirmationTimer?.cancel();
            _exitConfirmationTimer = null;
            onDiagnostic(
              'EXIT_CONFIRMED '
              'distance=${effect.distance?.toStringAsFixed(1) ?? 'none'}',
            );
        }
      }
    } finally {
      if (stopRequested) {
        _preciseVerificationActive = false;
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        _rearmTimer?.cancel();
        _rearmTimer = null;
        _exitConfirmationTimer?.cancel();
        _exitConfirmationTimer = null;
        if (releaseVerification) {
          onDiagnostic('PRECISE_LOCATION_STOPPED');
          await _stopService();
        } else {
          onDiagnostic('PRECISE_LOCATION_KEPT reason=NEW_APPROACH');
        }
      } else if (rearmVerificationComplete) {
        // Nothing left to measure for this place until its cooldown ends;
        // stop only this place, never another place's verification.
        _preciseVerificationActive = false;
        _rearmTimer?.cancel();
        _rearmTimer = null;
        onDiagnostic(
          'REARM_VERIFICATION_COMPLETE exitObserved=true '
          'rearmAt=${_iso(engine!.cooldownUntil)}',
        );
        onDiagnostic('PRECISE_LOCATION_STOPPED');
        await _stopService();
      }
    }
    final waitingForExit = result.effects.any(
      (effect) =>
          effect.type == DetectionEffectType.stateChanged &&
          effect.to == DetectionState.waitingForExit,
    );
    // Waiting for exit while still inside: nothing to measure, stop. Keep
    // running while a re-arm verification is measuring the exit distance.
    if (waitingForExit && !_preciseVerificationActive) await _stopService();
    _scheduleCooldownTimer();
  }

  /// One line per approach so a missed arrival can be explained without
  /// reading every sample: how many fixes arrived, how close and how accurate
  /// they were, and why the approach ended.
  void _summarizeApproach(DetectionResult result) {
    final stats = _approach;
    String? outcome;
    for (final effect in result.effects) {
      if (effect.type == DetectionEffectType.innerReached) {
        outcome = 'ARRIVED';
      } else if (effect.type == DetectionEffectType.approachTimeout) {
        outcome = 'TIMEOUT';
      } else if (effect.type == DetectionEffectType.exitConfirmed) {
        outcome ??= 'EXIT_CONFIRMED';
      } else if (effect.type == DetectionEffectType.stateChanged &&
          effect.from == DetectionState.approaching &&
          effect.to == DetectionState.armed) {
        outcome ??= 'EXITED';
      }
    }
    if (outcome == null) return;
    final visit = engine?.visitId ?? 'none';
    if (stats == null) {
      // The approach began in an earlier process (killed by the watchdog or
      // the OS) and ended here: its samples are gone, but its end is not.
      final endedApproach = result.effects.any(
        (effect) =>
            effect.type == DetectionEffectType.stateChanged &&
            effect.from == DetectionState.approaching,
      );
      if (endedApproach) {
        onDiagnostic(
          'APPROACH_SUMMARY outcome=$outcome visit=$visit restored=true '
          'samples=unknown',
        );
      }
      return;
    }
    _approach = null;
    onDiagnostic(stats.summary(outcome, _clock(), visit));
  }

  static String _iso(DateTime? value) =>
      value?.toUtc().toIso8601String() ?? 'none';

  /// A persisted cooldown can expire while no background process is running.
  /// Apply it now instead of waiting for a timer that was never scheduled.
  Future<void> _applyElapsedCooldown({bool releaseVerification = true}) async {
    final until = engine?.cooldownUntil;
    if (engine?.state != DetectionState.cooldown || until == null) return;
    if (_clock().isBefore(until)) return;
    onDiagnostic(
      'COOLDOWN_ELAPSED_WHILE_STOPPED until=${_iso(until)} '
      'exitObserved=${engine!.exitObservedDuringCooldown}',
    );
    await _process(
      engine!.dispatch(CooldownElapsed(until)),
      releaseVerification: releaseVerification,
    );
  }

  void _startRearmVerification() {
    if (_preciseVerificationActive) return;
    _preciseVerificationActive = true;
    _ignoredFixes = 0;
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
    final name = switch (result) {
      NotificationDeliveryResult.sent => 'NOTIFICATION_SENT',
      NotificationDeliveryResult.duplicate =>
        'NOTIFICATION_SUPPRESSED_DUPLICATE',
      NotificationDeliveryResult.permissionMissing =>
        'NOTIFICATION_PERMISSION_MISSING',
      NotificationDeliveryResult.failed => 'NOTIFICATION_FAILED',
    };
    onDiagnostic('$name visit=$visitId');
  }
}

final class _ApproachStats {
  _ApproachStats(this.enteredAt);

  final DateTime enteredAt;
  DateTime? firstSampleAt;
  int samples = 0;
  int accepted = 0;
  double? closest;
  double? closestAccuracy;
  double? bestAccuracy;
  _Fix? firstFix;
  _Fix? lastFix;

  void record(
    double distance,
    double accuracy,
    DateTime at, {
    required bool accepted,
    required DateTime receivedAt,
  }) {
    samples++;
    firstSampleAt ??= at;
    final fix = _Fix(at: at, accuracy: accuracy, receivedAt: receivedAt);
    firstFix ??= fix;
    lastFix = fix;
    if (bestAccuracy == null || accuracy < bestAccuracy!) {
      bestAccuracy = accuracy;
    }
    if (!accepted) return;
    this.accepted++;
    if (closest == null || distance < closest!) {
      closest = distance;
      closestAccuracy = accuracy;
    }
  }

  String summary(String outcome, DateTime now, String visit) {
    final firstFixAfter = firstSampleAt == null
        ? 'none'
        : '${firstSampleAt!.difference(enteredAt).inSeconds}s';
    return 'APPROACH_SUMMARY outcome=$outcome visit=$visit '
        'samples=$samples accepted=$accepted '
        'rejectedLowAccuracy=${samples - accepted} '
        'closest=${closest == null ? 'none' : '${closest!.toStringAsFixed(1)}m'}'
        '${closestAccuracy == null ? '' : '@${closestAccuracy!.toStringAsFixed(1)}m'} '
        'bestAccuracy=${bestAccuracy == null ? 'none' : '${bestAccuracy!.toStringAsFixed(1)}m'} '
        'firstFixAfterEnter=$firstFixAfter '
        'duration=${now.difference(enteredAt).inSeconds}s '
        // APP-10F: the first and the last (deciding) fix of the approach:
        // how old each was when it arrived, how accurate, and when it was
        // taken relative to the ENTER (negative: before the ENTER).
        // Diagnostic measurements only: no arrival, rejection or cooldown
        // decision reads them. They compare the provider's fix time with
        // this phone's wall clock (see _Fix).
        '${_describe('firstFix', firstFix)} '
        '${_describe('lastFix', lastFix)}';
  }

  String _describe(String name, _Fix? fix) {
    if (fix == null) {
      return '${name}Age=none ${name}Accuracy=none ${name}FromEnter=none';
    }
    return '${name}Age=${_seconds(fix.receivedAt.difference(fix.at))} '
        '${name}Accuracy=${fix.accuracy.toStringAsFixed(1)}m '
        '${name}FromEnter=${_seconds(fix.at.difference(enteredAt))}';
  }

  static String _seconds(Duration value) =>
      '${(value.inMilliseconds / 1000).toStringAsFixed(1)}s';
}

/// One fix as the approach saw it: when it was taken, its accuracy, and
/// when it reached the session. Diagnostics only (APP-10F).
///
/// Wall-clock limits: [at] is the provider's fix time (UTC) and
/// [receivedAt] is this phone's wall clock when Dart handled the fix, and
/// the ENTER time is the receiver's wall clock. An offset between the phone
/// clock and the provider's time, or a clock change during the approach,
/// shifts every Age and FromEnter value; Age also includes time the fix
/// waited in the native queue (for example while the engine started).
final class _Fix {
  const _Fix({
    required this.at,
    required this.accuracy,
    required this.receivedAt,
  });

  final DateTime at;
  final double accuracy;
  final DateTime receivedAt;
}
