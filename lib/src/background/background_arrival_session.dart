import 'dart:async';

import '../domain/smart_arrival_detection.dart';

final class BackgroundArrivalSession {
  BackgroundArrivalSession({
    required this.onDiagnostic,
    required this.onCommand,
  });

  final void Function(String message) onDiagnostic;
  final Future<void> Function(String command) onCommand;
  SmartArrivalDetectionEngine? engine;
  Timer? _timeoutTimer;
  DateTime? _enteredAt;

  void dispose() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  Future<void> handleEvent(Map<Object?, Object?> payload) async {
    final type = payload['type'] as String?;
    if (type == 'error') {
      onDiagnostic(
        'BACKGROUND_EVENT_FAILED: ${payload['error'] ?? 'Unknown background event'}',
      );
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
      engine = SmartArrivalDetectionEngine(
        SmartArrivalConfig(
          target: TargetLocation(latitude: latitude, longitude: longitude),
        ),
      );
      _enteredAt = timestamp;
      _process(engine!.dispatch(const Arm()));
      _process(engine!.dispatch(OuterEnter(at: timestamp)));
    } else if (type == 'exit') {
      if (engine != null) _process(engine!.dispatch(const OuterExit()));
    } else if (type == 'location' && engine != null) {
      if (engine!.state != DetectionState.approaching) return;
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
      _process(
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
    }
  }

  void _process(DetectionResult result) {
    for (final effect in result.effects) {
      switch (effect.type) {
        case DetectionEffectType.stateChanged:
          onDiagnostic('STATE ${effect.from!.name} -> ${effect.to!.name}');
        case DetectionEffectType.preciseLocationStarted:
          onDiagnostic('PRECISE_LOCATION_STARTED');
          final start = _enteredAt ?? DateTime.now();
          _timeoutTimer?.cancel();
          _timeoutTimer = Timer(engine!.config.approachTimeout, () {
            _process(
              engine!.dispatch(
                ApproachTimedOut(start.add(engine!.config.approachTimeout)),
              ),
            );
          });
        case DetectionEffectType.preciseLocationStopped:
          _timeoutTimer?.cancel();
          _timeoutTimer = null;
          onDiagnostic('PRECISE_LOCATION_STOPPED');
          unawaited(onCommand('stop'));
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
          onDiagnostic('NOTIFICATION_REQUESTED (diagnostic only)');
        case DetectionEffectType.exitObservedDuringCooldown:
          onDiagnostic('EXIT_OBSERVED_DURING_COOLDOWN');
        case DetectionEffectType.approachTimeout:
          _timeoutTimer?.cancel();
          _timeoutTimer = null;
          onDiagnostic('APPROACH_TIMEOUT');
      }
    }
  }
}
