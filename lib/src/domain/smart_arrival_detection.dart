import 'dart:math' as math;

enum DetectionState {
  disarmed,
  armed,
  approaching,
  arrived,
  cooldown,
  waitingForExit,
}

enum DetectionEffectType {
  stateChanged,
  preciseLocationStarted,
  preciseLocationStopped,
  locationSample,
  locationRejected,
  innerReached,
  notificationRequested,
  exitObservedDuringCooldown,
  approachTimeout,
}

enum LocationRejectionReason { lowAccuracy }

final class TargetLocation {
  const TargetLocation({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

final class LocationSample {
  const LocationSample({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime timestamp;
}

final class SmartArrivalConfig {
  const SmartArrivalConfig({
    required this.target,
    this.outerRadius = 300,
    this.innerRadius = 80,
    this.rearmRadius = 350,
    this.cooldownDuration = const Duration(minutes: 10),
    this.approachTimeout = const Duration(minutes: 10),
    this.maxAcceptedAccuracy = 50,
  }) : assert(outerRadius > 0),
       assert(innerRadius > 0),
       assert(rearmRadius >= outerRadius),
       assert(innerRadius <= outerRadius),
       assert(maxAcceptedAccuracy > 0);

  final TargetLocation target;
  final double outerRadius;
  final double innerRadius;
  final double rearmRadius;
  final Duration cooldownDuration;
  final Duration approachTimeout;
  final double maxAcceptedAccuracy;
}

sealed class DetectionEvent {
  const DetectionEvent();
}

final class Arm extends DetectionEvent {
  const Arm();
}

final class Disarm extends DetectionEvent {
  const Disarm();
}

final class OuterEnter extends DetectionEvent {
  const OuterEnter({this.at});

  final DateTime? at;
}

final class OuterExit extends DetectionEvent {
  const OuterExit();
}

final class LocationReceived extends DetectionEvent {
  const LocationReceived(this.sample);

  final LocationSample sample;
}

final class CooldownElapsed extends DetectionEvent {
  const CooldownElapsed(this.at);

  final DateTime at;
}

final class RearmRadiusCrossed extends DetectionEvent {
  const RearmRadiusCrossed(this.at);

  final DateTime at;
}

final class ApproachTimedOut extends DetectionEvent {
  const ApproachTimedOut(this.at);

  final DateTime at;
}

final class ResetTest extends DetectionEvent {
  const ResetTest();
}

final class DetectionEffect {
  const DetectionEffect(
    this.type, {
    this.from,
    this.to,
    this.distance,
    this.accuracy,
    this.timestamp,
    this.reason,
  });

  final DetectionEffectType type;
  final DetectionState? from;
  final DetectionState? to;
  final double? distance;
  final double? accuracy;
  final DateTime? timestamp;
  final LocationRejectionReason? reason;
}

final class DetectionResult {
  const DetectionResult({required this.state, required this.effects});

  final DetectionState state;
  final List<DetectionEffect> effects;

  bool contains(DetectionEffectType type) =>
      effects.any((effect) => effect.type == type);
}

final class SmartArrivalDetectionEngine {
  SmartArrivalDetectionEngine(this.config) : _state = DetectionState.disarmed;

  final SmartArrivalConfig config;
  DetectionState _state;
  DateTime? _approachStartedAt;
  DateTime? _cooldownUntil;
  bool _exitObservedDuringCooldown = false;

  DetectionState get state => _state;
  DateTime? get cooldownUntil => _cooldownUntil;
  bool get exitObservedDuringCooldown => _exitObservedDuringCooldown;

  DetectionResult dispatch(DetectionEvent event) {
    final effects = <DetectionEffect>[];

    switch (event) {
      case Arm():
        if (_state == DetectionState.disarmed) {
          _setState(DetectionState.armed, effects);
        }
      case Disarm():
        if (_state != DetectionState.disarmed) {
          if (_state == DetectionState.approaching) {
            effects.add(
              const DetectionEffect(DetectionEffectType.preciseLocationStopped),
            );
          }
          _setState(DetectionState.disarmed, effects);
        }
      case OuterEnter(:final at):
        if (_state == DetectionState.armed) {
          _approachStartedAt = at;
          _setState(DetectionState.approaching, effects);
          effects.add(
            const DetectionEffect(DetectionEffectType.preciseLocationStarted),
          );
        }
      case OuterExit():
        if (_state == DetectionState.approaching) {
          _returnToArmed(effects, includeTimeout: false);
        }
      case LocationReceived(:final sample):
        _handleLocation(sample, effects);
      case CooldownElapsed(:final at):
        _handleCooldownElapsed(at, effects);
      case RearmRadiusCrossed(:final at):
        _handleRearmCrossed(at, effects);
      case ApproachTimedOut(:final at):
        if (_state == DetectionState.approaching &&
            _approachStartedAt != null &&
            !at.isBefore(_approachStartedAt!.add(config.approachTimeout))) {
          _returnToArmed(effects, includeTimeout: true);
        }
      case ResetTest():
        if (_state == DetectionState.approaching) {
          effects.add(
            const DetectionEffect(DetectionEffectType.preciseLocationStopped),
          );
        }
        _cooldownUntil = null;
        _approachStartedAt = null;
        _exitObservedDuringCooldown = false;
        _setState(DetectionState.armed, effects);
    }

    return DetectionResult(state: _state, effects: List.unmodifiable(effects));
  }

  void _handleLocation(LocationSample sample, List<DetectionEffect> effects) {
    final distance = distanceBetween(config.target, sample);

    if (_state == DetectionState.approaching) {
      _approachStartedAt ??= sample.timestamp;
      effects.add(
        DetectionEffect(
          DetectionEffectType.locationSample,
          distance: distance,
          accuracy: sample.accuracy,
          timestamp: sample.timestamp,
        ),
      );

      if (sample.accuracy > config.maxAcceptedAccuracy) {
        effects.add(
          DetectionEffect(
            DetectionEffectType.locationRejected,
            distance: distance,
            accuracy: sample.accuracy,
            timestamp: sample.timestamp,
            reason: LocationRejectionReason.lowAccuracy,
          ),
        );
        return;
      }

      if (distance <= config.innerRadius) {
        _setState(DetectionState.arrived, effects);
        effects.add(const DetectionEffect(DetectionEffectType.innerReached));
        effects.add(
          const DetectionEffect(DetectionEffectType.preciseLocationStopped),
        );
        effects.add(
          const DetectionEffect(DetectionEffectType.notificationRequested),
        );
        _cooldownUntil = sample.timestamp.add(config.cooldownDuration);
        _setState(DetectionState.cooldown, effects);
      } else if (distance > config.outerRadius) {
        _returnToArmed(effects, includeTimeout: false);
      }
    } else if (_state == DetectionState.cooldown &&
        distance >= config.rearmRadius) {
      _exitObservedDuringCooldown = true;
      effects.add(
        const DetectionEffect(DetectionEffectType.exitObservedDuringCooldown),
      );
    } else if (_state == DetectionState.waitingForExit &&
        distance >= config.rearmRadius) {
      _rearm(effects);
    }
  }

  void _handleCooldownElapsed(DateTime at, List<DetectionEffect> effects) {
    if (_state != DetectionState.cooldown || _cooldownUntil == null) return;
    if (at.isBefore(_cooldownUntil!)) return;

    if (_exitObservedDuringCooldown) {
      _rearm(effects);
    } else {
      _setState(DetectionState.waitingForExit, effects);
    }
  }

  void _handleRearmCrossed(DateTime at, List<DetectionEffect> effects) {
    if (_state == DetectionState.cooldown) {
      _exitObservedDuringCooldown = true;
    }
    if (_state == DetectionState.waitingForExit ||
        (_state == DetectionState.cooldown && _cooldownExpiredAt(at))) {
      _rearm(effects);
    }
  }

  bool _cooldownExpiredAt(DateTime at) =>
      _cooldownUntil != null && !at.isBefore(_cooldownUntil!);

  void _returnToArmed(
    List<DetectionEffect> effects, {
    required bool includeTimeout,
  }) {
    effects.add(
      const DetectionEffect(DetectionEffectType.preciseLocationStopped),
    );
    if (includeTimeout) {
      effects.add(const DetectionEffect(DetectionEffectType.approachTimeout));
    }
    _approachStartedAt = null;
    _setState(DetectionState.armed, effects);
  }

  void _rearm(List<DetectionEffect> effects) {
    _cooldownUntil = null;
    _exitObservedDuringCooldown = false;
    _setState(DetectionState.armed, effects);
  }

  void _setState(DetectionState next, List<DetectionEffect> effects) {
    if (_state == next) return;
    final previous = _state;
    _state = next;
    effects.add(
      DetectionEffect(
        DetectionEffectType.stateChanged,
        from: previous,
        to: next,
      ),
    );
  }
}

double distanceBetween(TargetLocation target, LocationSample sample) {
  const earthRadiusMeters = 6371000.0;
  final latitude1 = target.latitude * math.pi / 180;
  final latitude2 = sample.latitude * math.pi / 180;
  final deltaLatitude = (sample.latitude - target.latitude) * math.pi / 180;
  final deltaLongitude = (sample.longitude - target.longitude) * math.pi / 180;
  final a =
      math.pow(math.sin(deltaLatitude / 2), 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.pow(math.sin(deltaLongitude / 2), 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}
