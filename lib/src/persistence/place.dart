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
    this.maxAcceptedAccuracy = 50,
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

  void validate() {
    if (id.trim().isEmpty || name.trim().isEmpty) {
      throw const FormatException('Place id and name must not be blank');
    }
    if (!latitude.isFinite || latitude < -90 || latitude > 90) {
      throw const FormatException('Place latitude is out of bounds');
    }
    if (!longitude.isFinite || longitude < -180 || longitude > 180) {
      throw const FormatException('Place longitude is out of bounds');
    }
    if (!outerRadius.isFinite || outerRadius <= 0 ||
        !innerRadius.isFinite || innerRadius <= 0 ||
        !rearmRadius.isFinite || rearmRadius < outerRadius ||
        innerRadius > outerRadius) {
      throw const FormatException('Place geofence radii are invalid');
    }
    if (cooldown.inSeconds <= 0 || approachTimeout.inSeconds <= 0 ||
        !maxAcceptedAccuracy.isFinite || maxAcceptedAccuracy <= 0) {
      throw const FormatException('Place timing or accuracy is invalid');
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return {
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
  }

  static Place fromJson(Map<Object?, Object?> json) {
    final place = Place(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      latitude: _requiredNumber(json, 'latitude'),
      longitude: _requiredNumber(json, 'longitude'),
      enabled: _requiredBool(json, 'enabled'),
      outerRadius: _requiredNumber(json, 'outerRadius'),
      innerRadius: _requiredNumber(json, 'innerRadius'),
      rearmRadius: _requiredNumber(json, 'rearmRadius'),
      cooldown: Duration(
        seconds: _requiredPositiveInt(json, 'cooldownSeconds'),
      ),
      approachTimeout: Duration(
        seconds: _requiredPositiveInt(json, 'approachTimeoutSeconds'),
      ),
      maxAcceptedAccuracy: _requiredNumber(json, 'maxAcceptedAccuracy'),
    );
    place.validate();
    return place;
  }
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

  void validate() {
    if (id.trim().isEmpty || placeId.trim().isEmpty) {
      throw const FormatException('Reminder ids must not be blank');
    }
    if (text.trim().isEmpty) {
      throw const FormatException('Reminder text must not be blank');
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return {'id': id, 'placeId': placeId, 'text': text};
  }

  static Reminder fromJson(Map<Object?, Object?> json) {
    final reminder = Reminder(
      id: _requiredString(json, 'id'),
      placeId: _requiredString(json, 'placeId'),
      text: _requiredString(json, 'text'),
    );
    reminder.validate();
    return reminder;
  }
}

String _requiredString(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw FormatException('Invalid persistence field: $key');
}

bool _requiredBool(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('Invalid persistence field: $key');
}

double _requiredNumber(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is num && value.isFinite) return value.toDouble();
  throw FormatException('Invalid persistence field: $key');
}

int _requiredPositiveInt(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite || value.toInt() != value ||
      value <= 0) {
    throw FormatException('Invalid persistence field: $key');
  }
  return value.toInt();
}

final class PlaceData {
  const PlaceData({this.places = const [], this.reminders = const []});

  final List<Place> places;
  final List<Reminder> reminders;

  void validate() {
    final placeIds = <String>{};
    for (final place in places) {
      place.validate();
      if (!placeIds.add(place.id)) {
        throw FormatException('Duplicate place id: ${place.id}');
      }
    }
    final reminderIds = <String>{};
    for (final reminder in reminders) {
      reminder.validate();
      if (!reminderIds.add(reminder.id)) {
        throw FormatException('Duplicate reminder id: ${reminder.id}');
      }
      if (!placeIds.contains(reminder.placeId)) {
        throw FormatException(
          'Reminder references missing place: ${reminder.placeId}',
        );
      }
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return {
      'schemaVersion': 1,
      'places': places.map((place) => place.toJson()).toList(),
      'reminders': reminders.map((reminder) => reminder.toJson()).toList(),
    };
  }

  static PlaceData fromJson(Map<Object?, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported place persistence schema');
    }
    final rawPlaces = json['places'];
    final rawReminders = json['reminders'];
    if (rawPlaces is! List || rawReminders is! List) {
      throw const FormatException('Invalid place persistence collections');
    }
    try {
      final data = PlaceData(
        places: rawPlaces
            .map(
              (value) => Place.fromJson(
                Map<Object?, Object?>.from(value as Map),
              ),
            )
            .toList(growable: false),
        reminders: rawReminders
            .map(
              (value) => Reminder.fromJson(
                Map<Object?, Object?>.from(value as Map),
              ),
            )
            .toList(growable: false),
      );
      data.validate();
      return data;
    } on TypeError {
      throw const FormatException('Malformed place persistence document');
    }
  }
}