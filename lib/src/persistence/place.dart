import '../domain/smart_arrival_detection.dart';

final class Place {
  const Place({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.enabled,
    this.outerRadius = 300,
    this.innerRadius = 80,
    this.rearmRadius = 350,
    this.cooldown = const Duration(minutes: 10),
    this.approachTimeout = const Duration(minutes: 10),
    this.maxAcceptedAccuracy = 80,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final bool enabled;
  final double outerRadius;
  final double innerRadius;
  final double rearmRadius;
  final Duration cooldown;
  final Duration approachTimeout;
  final double maxAcceptedAccuracy;

  TargetLocation get target =>
      TargetLocation(latitude: latitude, longitude: longitude);

  Place copyWith({
    String? name,
    double? latitude,
    double? longitude,
    bool? enabled,
    double? outerRadius,
    double? innerRadius,
    double? rearmRadius,
    Duration? cooldown,
    Duration? approachTimeout,
    double? maxAcceptedAccuracy,
  }) => Place(
    id: id,
    name: name ?? this.name,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    enabled: enabled ?? this.enabled,
    outerRadius: outerRadius ?? this.outerRadius,
    innerRadius: innerRadius ?? this.innerRadius,
    rearmRadius: rearmRadius ?? this.rearmRadius,
    cooldown: cooldown ?? this.cooldown,
    approachTimeout: approachTimeout ?? this.approachTimeout,
    maxAcceptedAccuracy: maxAcceptedAccuracy ?? this.maxAcceptedAccuracy,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'enabled': enabled,
    'outerRadius': outerRadius,
    'innerRadius': innerRadius,
    'rearmRadius': rearmRadius,
    'cooldownSeconds': cooldown.inSeconds,
    'approachTimeoutSeconds': approachTimeout.inSeconds,
    'maxAcceptedAccuracy': maxAcceptedAccuracy,
  };

  static Place fromJson(Map<Object?, Object?> json) => Place(
    id: _requiredString(json, 'id'),
    name: _requiredString(json, 'name'),
    latitude: _requiredNumber(json, 'latitude'),
    longitude: _requiredNumber(json, 'longitude'),
    enabled: json['enabled'] == true,
    outerRadius: _numberOr(json, 'outerRadius', 300),
    innerRadius: _numberOr(json, 'innerRadius', 80),
    rearmRadius: _numberOr(json, 'rearmRadius', 350),
    cooldown: Duration(seconds: _intOr(json, 'cooldownSeconds', 600)),
    approachTimeout: Duration(
      seconds: _intOr(json, 'approachTimeoutSeconds', 600),
    ),
    maxAcceptedAccuracy: _numberOr(json, 'maxAcceptedAccuracy', 80),
  );
}

final class Reminder {
  const Reminder({required this.id, required this.placeId, required this.text});

  final String id;
  final String placeId;
  final String text;

  Reminder copyWith({String? placeId, String? text}) => Reminder(
    id: id,
    placeId: placeId ?? this.placeId,
    text: text ?? this.text,
  );

  Map<String, Object?> toJson() => {'id': id, 'placeId': placeId, 'text': text};

  static Reminder fromJson(Map<Object?, Object?> json) => Reminder(
    id: _requiredString(json, 'id'),
    placeId: _requiredString(json, 'placeId'),
    text: _requiredString(json, 'text'),
  );
}

String _requiredString(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw FormatException('Invalid persistence field: $key');
}

double _requiredNumber(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is num && value.isFinite) return value.toDouble();
  throw FormatException('Invalid persistence field: $key');
}

double _numberOr(Map<Object?, Object?> json, String key, double fallback) {
  final value = json[key];
  return value is num && value.isFinite ? value.toDouble() : fallback;
}

int _intOr(Map<Object?, Object?> json, String key, int fallback) {
  final value = json[key];
  return value is num && value.isFinite ? value.toInt() : fallback;
}

final class PlaceData {
  const PlaceData({this.places = const [], this.reminders = const []});

  final List<Place> places;
  final List<Reminder> reminders;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'places': places.map((place) => place.toJson()).toList(),
    'reminders': reminders.map((reminder) => reminder.toJson()).toList(),
  };

  static PlaceData fromJson(Map<Object?, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw FormatException('Unsupported place persistence schema');
    }
    final rawPlaces = json['places'];
    final rawReminders = json['reminders'];
    if (rawPlaces is! List || rawReminders is! List) {
      throw FormatException('Invalid place persistence collections');
    }
    return PlaceData(
      places: rawPlaces
          .map(
            (value) => Place.fromJson(Map<Object?, Object?>.from(value as Map)),
          )
          .toList(growable: false),
      reminders: rawReminders
          .map(
            (value) =>
                Reminder.fromJson(Map<Object?, Object?>.from(value as Map)),
          )
          .toList(growable: false),
    );
  }
}
