import 'package:flutter/foundation.dart';

import '../geofence/geofence_service.dart';
import '../runtime/arrival_runtime_store.dart';
import 'legacy_place_migration.dart';
import 'place_repositories.dart';

final class PlaceInitializationResult {
  const PlaceInitializationResult({
    required this.succeeded,
    required this.migrationChanged,
  });

  final bool succeeded;
  final bool migrationChanged;
}

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

  Future<List<String>> diagnostics() async {
    final data = await database.read();
    return [
      'MIGRATION_STATUS: completed',
      'PERSISTED_PLACES: ${data.places.length}',
      'PERSISTED_REMINDERS: ${data.reminders.length}',
      ...((await geofenceService.multiRegistrationStatus()).entries.map(
        (entry) => 'REGISTRATION_${entry.key.toUpperCase()}: ${entry.value}',
      )),
      ...data.places.map((place) =>
          'PLACE ${place.id} name=${place.name} enabled=${place.enabled} desiredRegistration=${place.enabled}'),
    ];
  }

  Future<void> reconcileEnabledPlaces() async {
    final places = await this.places.list();
    final reminders = await this.reminders.list();
    await geofenceService.registerPlaces(
      places.where((place) => place.enabled).map(
        (place) => GeofencePlaceRegistration(
          placeId: place.id,
          latitude: place.latitude,
          longitude: place.longitude,
          radius: place.outerRadius,
          innerRadius: place.innerRadius,
          rearmRadius: place.rearmRadius,
          cooldownSeconds: place.cooldown.inSeconds,
          approachTimeoutSeconds: place.approachTimeout.inSeconds,
          maxAcceptedAccuracy: place.maxAcceptedAccuracy,
          reminderText: reminders
              .where((reminder) => reminder.placeId == place.id)
              .map((reminder) => reminder.text.trim())
              .where((text) => text.isNotEmpty)
              .join(' • '),
        ),
      ),
    );
  }

  Future<PlaceInitializationResult> initialize() async {
    try {
      final migrated = await migration.migrateIfNeeded();
      initializationFailure = null;
      return PlaceInitializationResult(
        succeeded: true,
        migrationChanged: migrated,
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