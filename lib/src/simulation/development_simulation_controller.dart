import '../domain/smart_arrival_detection.dart';

typedef SimulationListener = void Function();

final class SimulationController {
  SimulationController({SmartArrivalConfig? config, DateTime? initialTime})
    : config =
          config ??
          const SmartArrivalConfig(
            target: TargetLocation(latitude: 32.000000, longitude: 34.800000),
          ),
      clock = initialTime ?? DateTime.utc(2026, 1, 1),
      engine = SmartArrivalDetectionEngine(
        config ??
            const SmartArrivalConfig(
              target: TargetLocation(latitude: 32.000000, longitude: 34.800000),
            ),
      );

  final SmartArrivalConfig config;
  final SmartArrivalDetectionEngine engine;
  final List<SimulationListener> _listeners = [];
  final List<String> _eventLog = [];

  DateTime clock;
  double? lastDistance;
  double? lastAccuracy;
  bool preciseLocationActive = false;
  bool notificationRequested = false;

  DetectionState get state => engine.state;
  DateTime? get cooldownUntil => engine.cooldownUntil;
  List<String> get eventLog => List.unmodifiable(_eventLog);

  void addListener(SimulationListener listener) => _listeners.add(listener);

  void removeListener(SimulationListener listener) =>
      _listeners.remove(listener);

  void armTest() => _dispatch(const Arm(), 'ARM TEST');

  void simulateOuterEnter() =>
      _dispatch(OuterEnter(at: clock), 'SIMULATE OUTER ENTER');

  void simulateLocation(double meters) {
    final sample = _sampleAtMeters(meters);
    lastDistance = meters;
    lastAccuracy = sample.accuracy;
    _dispatch(LocationReceived(sample), 'SIMULATE LOCATION ${meters.round()}m');
  }

  void simulateExit() => simulateLocation(400);

  void advanceOrExpireCooldown() {
    final expiry = engine.cooldownUntil;
    if (expiry != null && expiry.isAfter(clock)) {
      clock = expiry;
    }
    _dispatch(CooldownElapsed(clock), 'ADVANCE / EXPIRE COOLDOWN');
  }

  void simulateApproachTimeout() {
    clock = clock.add(config.approachTimeout);
    _dispatch(ApproachTimedOut(clock), 'SIMULATE APPROACH TIMEOUT');
  }

  void resetTest() {
    clock = DateTime.utc(2026, 1, 1);
    lastDistance = null;
    lastAccuracy = null;
    notificationRequested = false;
    _dispatch(const ResetTest(), 'RESET TEST');
  }

  void dispose() => _listeners.clear();

  LocationSample _sampleAtMeters(double meters) {
    return LocationSample(
      latitude: config.target.latitude + meters / 111320,
      longitude: config.target.longitude,
      accuracy: 10,
      timestamp: clock,
    );
  }

  void _dispatch(DetectionEvent event, String label) {
    _eventLog.add('${_formatTime(clock)} $label');
    final result = engine.dispatch(event);

    for (final effect in result.effects) {
      if (effect.type == DetectionEffectType.preciseLocationStarted) {
        preciseLocationActive = true;
      } else if (effect.type == DetectionEffectType.preciseLocationStopped) {
        preciseLocationActive = false;
      } else if (effect.type == DetectionEffectType.notificationRequested) {
        notificationRequested = true;
      }
      _eventLog.add('${_formatTime(clock)} ${_describeEffect(effect)}');
    }
    _notifyListeners();
  }

  String _describeEffect(DetectionEffect effect) {
    switch (effect.type) {
      case DetectionEffectType.stateChanged:
        return 'STATE ${effect.from!.name} -> ${effect.to!.name}';
      case DetectionEffectType.locationSample:
        return 'LOCATION distance=${effect.distance!.toStringAsFixed(1)}m '
            'accuracy=${effect.accuracy!.toStringAsFixed(1)}m';
      case DetectionEffectType.locationRejected:
        return 'LOCATION_REJECTED reason=${effect.reason!.name.toUpperCase()}';
      case DetectionEffectType.notificationRequested:
        return 'NOTIFICATION_REQUESTED (simulation only)';
      case DetectionEffectType.preciseLocationStarted:
        return 'PRECISE_LOCATION_ACTIVE';
      case DetectionEffectType.preciseLocationStopped:
        return 'PRECISE_LOCATION_INACTIVE';
      case DetectionEffectType.innerReached:
        return 'INNER_REACHED';
      case DetectionEffectType.exitObservedDuringCooldown:
        return 'EXIT_OBSERVED_DURING_COOLDOWN';
      case DetectionEffectType.approachTimeout:
        return 'APPROACH_TIMEOUT';
    }
  }

  String _formatTime(DateTime value) =>
      value.toIso8601String().substring(11, 19);

  void _notifyListeners() {
    for (final listener in List<SimulationListener>.of(_listeners)) {
      listener();
    }
  }
}
