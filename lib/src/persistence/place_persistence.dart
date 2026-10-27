import 'package:flutter/foundation.dart';

import '../geofence/geofence_service.dart';
import '../runtime/arrival_runtime_store.dart';
import 'legacy_place_migration.dart';
import 'place_repositories.dart';

final class PlacePersistenceCoordinator {
  PlacePersistenceCoordinator({
    required this.database,
    required this.migration,
    GeofenceService? geofenceService,
  }) : geofenceService = geofenceService ?? MethodChannelGeofenceService();

  factory PlacePersistenceCoordinator.production() {
    final database = PlaceDatabase(MethodChannelPlaceDataStore());
    return PlacePersistenceCoordinator(
      database: database,
      migration: PlaceMigration(
        database: database,
        source: LegacySingleTargetReader(
          runtimeStore: MethodChannelArrivalRuntimeStore(),
          geofenceService: MethodChannelGeofenceService(),
        ),
      ),
      geofenceService: MethodChannelGeofenceService(),
    );
  }

  final PlaceDatabase database;
  final PlaceMigration migration;
  final GeofenceService geofenceService;
  String? initializationFailure;

  PlaceRepository get places => PlaceRepository(database);
  ReminderRepository get reminders => ReminderRepository(database);

  Future<void> reconcileEnabledPlaces() async {
    final places = await this.places.list();
    await geofenceService.registerPlaces(
      places.where((place) => place.enabled).map(
        (place) => GeofencePlaceRegistration(
          placeId: place.id,
          latitude: place.latitude,
          longitude: place.longitude,
          radius: place.outerRadius,
        ),
      ),
    );
  }

  Future<bool> initialize() async {
    try {
      final migrated = await migration.migrateIfNeeded();
      initializationFailure = null;
      return migrated;
    } catch (error) {
      initializationFailure =
          'Place persistence initialization failed: ${error.runtimeType}: $error';
      debugPrint(initializationFailure);
      return false;
    }
  }
}