import 'package:flutter/services.dart';

import '../domain/smart_arrival_detection.dart';

abstract interface class ArrivalRuntimeStore {
  Future<DetectionRuntimeSnapshot?> load();

  Future<void> save(DetectionRuntimeSnapshot snapshot);

  Future<void> clear();

  Future<String> loadReminderText();

  Future<void> saveReminderText(String value);
}

abstract interface class PerPlaceArrivalRuntimeStore {
  Future<DetectionRuntimeSnapshot?> loadForPlace(String placeId);
  Future<void> saveForPlace(String placeId, DetectionRuntimeSnapshot snapshot);
  Future<void> clearForPlace(String placeId);
  Future<String> loadReminderTextForPlace(String placeId);
}

final class MethodChannelArrivalRuntimeStore implements ArrivalRuntimeStore, PerPlaceArrivalRuntimeStore {
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

  @override
  Future<DetectionRuntimeSnapshot?> loadForPlace(String placeId) async {
    final value = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'load',
      {'placeId': placeId},
    );
    if (value == null) return null;
    return _parseSnapshot(value);
  }

  @override
  Future<void> saveForPlace(
    String placeId,
    DetectionRuntimeSnapshot snapshot,
  ) => _channel.invokeMethod<void>('save', {
    ..._encodeSnapshot(snapshot),
    'placeId': placeId,
  });

  @override
  Future<void> clearForPlace(String placeId) =>
      _channel.invokeMethod<void>('clear', {'placeId': placeId});

  @override
  Future<String> loadReminderTextForPlace(String placeId) async =>
      await _channel.invokeMethod<String>('loadReminderText', {'placeId': placeId}) ??
      'עצור בתחנת דלק יעד';

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

final class InMemoryArrivalRuntimeStore implements ArrivalRuntimeStore, PerPlaceArrivalRuntimeStore {
  DetectionRuntimeSnapshot? snapshot;
  final Map<String, DetectionRuntimeSnapshot> placeSnapshots = {};
  final Map<String, String> placeReminderTexts = {};
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

  @override
  Future<DetectionRuntimeSnapshot?> loadForPlace(String placeId) async =>
      placeSnapshots[placeId];

  @override
  Future<void> saveForPlace(
    String placeId,
    DetectionRuntimeSnapshot value,
  ) async => placeSnapshots[placeId] = value;

  @override
  Future<void> clearForPlace(String placeId) async =>
      placeSnapshots.remove(placeId);

  @override
  Future<String> loadReminderTextForPlace(String placeId) async =>
      placeReminderTexts[placeId] ?? reminderText;
}
