import 'package:flutter/foundation.dart';

import '../geofence/geofence_service.dart';
import '../places/place_manager.dart';
import '../runtime/arrival_runtime_store.dart';
import 'legacy_place_migration.dart';
import 'place_repositories.dart';

final class PlaceInitializationResult {
  const PlaceInitializationResult({
    required this.succeeded,
    required this.migrationChanged,
    this.legacySync,
  });

  final bool succeeded;
  final bool migrationChanged;
  final LegacyPlaceSyncResult? legacySync;
}

final class PlacePersistenceCoordinator {
  PlacePersistenceCoordinator({
    required this.database,
    required this.migration,
    this.legacySync,
    GeofenceService? geofenceService,
  }) : geofenceService = geofenceService ?? MethodChannelGeofenceService();

  factory PlacePersistenceCoordinator.production() {
    final database = PlaceDatabase(MethodChannelPlaceDataStore());
    final legacy = LegacySingleTargetReader(
      runtimeStore: MethodChannelArrivalRuntimeStore(),
      geofenceService: MethodChannelGeofenceService(),
    );
    return PlacePersistenceCoordinator(
      database: database,
      migration: PlaceMigration(database: database, source: legacy),
      legacySync: LegacyPlaceSync(database: database, source: legacy),
      geofenceService: MethodChannelGeofenceService(),
    );
  }

  final PlaceDatabase database;
  final PlaceMigration migration;
  final LegacyPlaceSync? legacySync;
  final GeofenceService geofenceService;
  String? initializationFailure;
  String? lastLegacySync;

  /// The APP-10 place manager over this coordinator's database.
  PlaceManager createManager({
    required PlaceRegistrar registrar,
    required PerPlaceArrivalRuntimeStore runtimeStore,
  }) => PlaceManager(
    database: database,
    registrar: registrar,
    runtimeStore: runtimeStore,
  );

  PlaceRepository get places => PlaceRepository(database);
  ReminderRepository get reminders => ReminderRepository(database);

  Future<List<String>> diagnostics() async {
    final data = await database.read();
    return [
      'MIGRATION_STATUS: completed',
      'LEGACY_SYNC: ${lastLegacySync ?? (data.legacySyncCompleted ? 'completed' : 'pending')}',
      'PERSISTED_PLACES: ${data.places.length}',
      'PERSISTED_REMINDERS: ${data.reminders.length}',
      ...((await geofenceService.multiRegistrationStatus()).entries.map(
        (entry) => 'REGISTRATION_${entry.key.toUpperCase()}: ${entry.value}',
      )),
      ...data.places.map(
        (place) =>
            'PLACE ${place.id} name=${place.name} enabled=${place.enabled} desiredRegistration=${place.enabled}',
      ),
    ];
  }

  Future<void> reconcileEnabledPlaces() async {
    await geofenceService.registerPlaces(
      registrationsFor(await database.read()),
    );
  }

  Future<PlaceInitializationResult> initialize() async {
    try {
      final migrated = await migration.migrateIfNeeded();
      final sync = await legacySync?.syncIfNeeded();
      if (sync != null) lastLegacySync = sync.detail;
      initializationFailure = null;
      return PlaceInitializationResult(
        succeeded: true,
        migrationChanged: migrated,
        legacySync: sync,
      );
    } catch (error) {
      initializationFailure =
          'Place persistence initialization failed: ${error.runtimeType}: $error';
      debugPrint(initializationFailure);
      return const PlaceInitializationResult(
        succeeded: false,
        migrationChanged: false,
      );
    }
  }
}
