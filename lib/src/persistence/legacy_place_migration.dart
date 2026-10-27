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
  });

  final double latitude;
  final double longitude;
  final double radius;
  final String reminderText;
  final bool monitoringEnabled;
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
    final latitude = target?.latitude ?? desired!.latitude;
    final longitude = target?.longitude ?? desired!.longitude;
    final radius = desired?.radius ?? 300;
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
}

final class PlaceMigration {
  PlaceMigration({required this._database, required this._source});

  static const legacyPlaceId = 'legacy-place-1';
  final PlaceDatabase _database;
  final LegacySingleTargetSource _source;

  Future<bool> migrateIfNeeded() async {
    final existing = await _database.read();
    if (existing.places.isNotEmpty) return false;
    final legacy = await _source.read();
    if (legacy == null) return false;
    final place = Place(
      id: legacyPlaceId,
      name: 'מקום קיים',
      latitude: legacy.latitude,
      longitude: legacy.longitude,
      enabled: legacy.monitoringEnabled,
      outerRadius: legacy.radius,
    );
    final reminder = Reminder(
      id: 'legacy-reminder-1',
      placeId: place.id,
      text: legacy.reminderText,
    );
    await _database.replace(PlaceData(places: [place], reminders: [reminder]));
    return true;
  }
}
