import 'package:flutter/foundation.dart';

import '../geofence/geofence_service.dart';
import '../runtime/arrival_runtime_store.dart';
import 'legacy_place_migration.dart';
import 'place_repositories.dart';

final class PlacePersistenceCoordinator {
  PlacePersistenceCoordinator({
    required this.database,
    required this.migration,
  });

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
    );
  }

  final PlaceDatabase database;
  final PlaceMigration migration;

  PlaceRepository get places => PlaceRepository(database);
  ReminderRepository get reminders => ReminderRepository(database);

  Future<bool> initialize() async {
    try {
      return await migration.migrateIfNeeded();
    } catch (error) {
      debugPrint(
        'Place persistence initialization failed: ${error.runtimeType}',
      );
      return false;
    }
  }
}
