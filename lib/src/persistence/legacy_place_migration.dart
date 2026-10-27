import '../geofence/geofence_service.dart';
import '../runtime/arrival_runtime_store.dart';
import 'place.dart';
import 'place_repositories.dart';

final class LegacySingleTarget {
  const LegacySingleTarget({
    required this.latitude,
    required this.longitude,
    required this.radius,
    required this.reminderText,
    required this.monitoringEnabled,
    this.innerRadius,
    this.rearmRadius,
    this.cooldown,
    this.approachTimeout,
    this.maxAcceptedAccuracy,
  });

  final double latitude;
  final double longitude;
  final double radius;
  final String reminderText;
  final bool monitoringEnabled;
  // These are optional because Build 11 did not persist all of them. A source
  // that has them must provide them; migration never overwrites them.
  final double? innerRadius;
  final double? rearmRadius;
  final Duration? cooldown;
  final Duration? approachTimeout;
  final double? maxAcceptedAccuracy;
}

abstract interface class LegacySingleTargetSource {
  Future<LegacySingleTarget?> read();
}

final class LegacySingleTargetReader implements LegacySingleTargetSource {
  const LegacySingleTargetReader({
    required this.runtimeStore,
    required this.geofenceService,
  });

  final ArrivalRuntimeStore runtimeStore;
  final GeofenceService geofenceService;

  @override
  Future<LegacySingleTarget?> read() async {
    final snapshot = await runtimeStore.load();
    final desired = await geofenceService.desiredRegistration;
    final target = snapshot?.target;
    if (target == null && desired == null) return null;

    if (target != null && desired != null &&
        (_different(target.latitude, desired.latitude) ||
            _different(target.longitude, desired.longitude))) {
      throw const FormatException(
        'Legacy runtime and Android desired targets conflict',
      );
    }

    // Android desired registration is the source of truth for the target that
    // the platform intends to monitor. The Dart runtime target is used only
    // when Android has no desired record.
    final latitude = desired?.latitude ?? target!.latitude;
    final longitude = desired?.longitude ?? target!.longitude;
    final radius = desired?.radius ?? _historicalOuterRadius;
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        !radius.isFinite ||
        radius <= 0) {
      throw const FormatException('Legacy target data is invalid');
    }
    return LegacySingleTarget(
      latitude: latitude,
      longitude: longitude,
      radius: radius,
      reminderText: await runtimeStore.loadReminderText(),
      monitoringEnabled: await geofenceService.desiredMonitoring,
    );
  }

  static const _historicalOuterRadius = 300.0;
  static bool _different(double left, double right) =>
      (left - right).abs() > 0.000001;
}

final class PlaceMigration {
  PlaceMigration({required this._database, required this._source});

  static const legacyPlaceId = 'legacy-place-1';
  static const legacyReminderId = 'legacy-reminder-1';
  final PlaceDatabase _database;
  final LegacySingleTargetSource _source;

  Future<bool> migrateIfNeeded() => _database.transact<bool>((existing) async {
    if (existing.places.isNotEmpty) {
      return PlaceDatabaseChange(data: existing, result: false);
    }

    final legacy = await _source.read();
    if (legacy == null) {
      return PlaceDatabaseChange(data: existing, result: false);
    }

    final place = Place(
      id: legacyPlaceId,
      name: 'מקום קיים',
      latitude: legacy.latitude,
      longitude: legacy.longitude,
      enabled: legacy.monitoringEnabled,
      outerRadius: legacy.radius,
      innerRadius: legacy.innerRadius ?? 80,
      rearmRadius:
          legacy.rearmRadius ?? 350,
      cooldown:
          legacy.cooldown ?? const Duration(minutes: 10),
      approachTimeout:
          legacy.approachTimeout ?? const Duration(minutes: 10),
      maxAcceptedAccuracy: legacy.maxAcceptedAccuracy ??
          50,
    );
    final reminder = Reminder(
      id: legacyReminderId,
      placeId: place.id,
      text: legacy.reminderText,
    );
    return PlaceDatabaseChange(
      data: PlaceData(places: [place], reminders: [reminder]),
      result: true,
    );
  });
}