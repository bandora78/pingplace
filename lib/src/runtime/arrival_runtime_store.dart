import 'package:flutter/services.dart';

import '../domain/smart_arrival_detection.dart';

abstract interface class ArrivalRuntimeStore {
  Future<DetectionRuntimeSnapshot?> load();

  Future<void> save(DetectionRuntimeSnapshot snapshot);

  Future<void> clear();

  Future<String> loadReminderText();

  Future<void> saveReminderText(String value);
}

final class MethodChannelArrivalRuntimeStore implements ArrivalRuntimeStore {
  MethodChannelArrivalRuntimeStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'pingplace/runtime';
  final MethodChannel _channel;

  @override
  Future<DetectionRuntimeSnapshot?> load() async {
    final value = await _channel.invokeMethod<Map<dynamic, dynamic>>('load');
    if (value == null) return null;
    return _parseSnapshot(value);
  }

  @override
  Future<void> save(DetectionRuntimeSnapshot snapshot) =>
      _channel.invokeMethod<void>('save', _encodeSnapshot(snapshot));

  @override
  Future<void> clear() => _channel.invokeMethod<void>('clear');

  @override
  Future<String> loadReminderText() async =>
      await _channel.invokeMethod<String>('loadReminderText') ??
      'עצור בתחנת דלק יעד';

  @override
  Future<void> saveReminderText(String value) =>
      _channel.invokeMethod<void>('saveReminderText', value);

  static Map<String, Object?> _encodeSnapshot(
    DetectionRuntimeSnapshot snapshot,
  ) => {
    'state': snapshot.state.name,
    'targetLatitude': snapshot.target?.latitude,
    'targetLongitude': snapshot.target?.longitude,
    'approachStartedAt': snapshot.approachStartedAt?.toIso8601String(),
    'cooldownUntil': snapshot.cooldownUntil?.toIso8601String(),
    'exitObservedDuringCooldown': snapshot.exitObservedDuringCooldown,
    'visitId': snapshot.visitId,
  };

  static DetectionRuntimeSnapshot _parseSnapshot(Map<dynamic, dynamic> value) {
    final state = DetectionState.values.firstWhere(
      (candidate) => candidate.name == value['state'],
      orElse: () => DetectionState.disarmed,
    );
    return DetectionRuntimeSnapshot(
      state: state,
      target:
          (value['targetLatitude'] as num?) != null &&
              (value['targetLongitude'] as num?) != null
          ? TargetLocation(
              latitude: (value['targetLatitude'] as num).toDouble(),
              longitude: (value['targetLongitude'] as num).toDouble(),
            )
          : null,
      approachStartedAt: DateTime.tryParse(
        value['approachStartedAt'] as String? ?? '',
      ),
      cooldownUntil: DateTime.tryParse(value['cooldownUntil'] as String? ?? ''),
      exitObservedDuringCooldown:
          value['exitObservedDuringCooldown'] as bool? ?? false,
      visitId: value['visitId'] as String?,
    );
  }
}

final class InMemoryArrivalRuntimeStore implements ArrivalRuntimeStore {
  DetectionRuntimeSnapshot? snapshot;
  String reminderText = 'עצור בתחנת דלק יעד';

  @override
  Future<DetectionRuntimeSnapshot?> load() async => snapshot;

  @override
  Future<void> save(DetectionRuntimeSnapshot value) async => snapshot = value;

  @override
  Future<void> clear() async => snapshot = null;

  @override
  Future<String> loadReminderText() async => reminderText;

  @override
  Future<void> saveReminderText(String value) async => reminderText = value;
}
