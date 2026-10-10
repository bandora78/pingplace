import 'package:flutter/services.dart';

import '../domain/smart_arrival_detection.dart';

final class LocationServiceEvent {
  const LocationServiceEvent._({this.sample, this.error});

  const LocationServiceEvent.sample(LocationSample sample)
    : this._(sample: sample);

  const LocationServiceEvent.failure(String error) : this._(error: error);

  final LocationSample? sample;
  final String? error;

  bool get isFailure => error != null;
}

abstract interface class LocationService {
  Stream<LocationServiceEvent> get events;

  Future<void> start();

  Future<void> stop();

  void dispose();
}

final class MethodChannelLocationService implements LocationService {
  MethodChannelLocationService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel(_methodChannelName),
       _eventChannel = eventChannel ?? const EventChannel(_eventChannelName);

  static const _methodChannelName = 'pingplace/location';
  static const _eventChannelName = 'pingplace/location/events';

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<LocationServiceEvent>? _events;

  @override
  Stream<LocationServiceEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .map((event) => _parseEvent(event as Map<dynamic, dynamic>));

  @override
  Future<void> start() => _methodChannel.invokeMethod<void>('start');

  @override
  Future<void> stop() => _methodChannel.invokeMethod<void>('stop');

  @override
  void dispose() {}

  static LocationServiceEvent _parseEvent(Map<dynamic, dynamic> value) {
    final type = value['type'] as String?;
    if (type == 'error') {
      return LocationServiceEvent.failure(
        value['error'] as String? ?? 'Unknown location service failure',
      );
    }

    final latitude = (value['latitude'] as num?)?.toDouble();
    final longitude = (value['longitude'] as num?)?.toDouble();
    final accuracy = (value['accuracy'] as num?)?.toDouble();
    final timestamp = DateTime.tryParse(value['timestamp'] as String? ?? '');
    if (latitude == null ||
        longitude == null ||
        accuracy == null ||
        timestamp == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        !accuracy.isFinite ||
        accuracy < 0) {
      return const LocationServiceEvent.failure(
        'Malformed location sample from platform',
      );
    }
    return LocationServiceEvent.sample(
      LocationSample(
        latitude: latitude,
        longitude: longitude,
        accuracy: accuracy,
        timestamp: timestamp,
      ),
    );
  }
}
