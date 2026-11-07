import 'dart:async';

import 'package:flutter/material.dart';

import 'src/background/background_arrival.dart';
import 'src/geofence/development_geofence_controller.dart';
import 'src/geofence/geofence_service.dart';
import 'src/home/pingplace_home_screen.dart';
import 'src/persistence/place_persistence.dart';
import 'src/places/place_manager.dart';
import 'src/runtime/arrival_runtime_store.dart';

void main() {
  runApp(const PingPlaceApp());
}

@pragma('vm:entry-point')
Future<void> backgroundMain() => runBackgroundArrival();

final class PingPlaceApp extends StatefulWidget {
  const PingPlaceApp({super.key});

  @override
  State<PingPlaceApp> createState() => _PingPlaceAppState();
}

final class _PingPlaceAppState extends State<PingPlaceApp> {
  final DevelopmentGeofenceController geofenceController =
      DevelopmentGeofenceController();
  final PlacePersistenceCoordinator placePersistence =
      PlacePersistenceCoordinator.production();
  late final PlaceManager placeManager = placePersistence.createManager(
    registrar: GeofencePlaceRegistrar(MethodChannelGeofenceService()),
    runtimeStore: MethodChannelArrivalRuntimeStore(),
  );

  @override
  void initState() {
    super.initState();
    unawaited(geofenceController.initialize());
    unawaited(_initializePlacePersistence());
  }

  Future<void> _initializePlacePersistence() async {
    final initialization = await placePersistence.initialize();
    if (initialization.succeeded) {
      // Registers every enabled place with Android, then loads the list.
      await placeManager.initialize();
    } else {
      // Never register from a document that failed to migrate: an empty or
      // partial set would unregister working geofences. Show the failure.
      await placeManager.refresh();
    }
    geofenceController.setPersistenceInitializationFailure(
      placePersistence.initializationFailure ?? placeManager.lastError,
    );
    placeManager.addListener(_publishDiagnostics);
    await _publishDiagnostics();
  }

  Future<void> _publishDiagnostics() async {
    final lines = <String>[];
    try {
      lines.addAll(await placePersistence.diagnostics());
    } catch (error) {
      lines.add('PLACE_DIAGNOSTICS_FAILED: $error');
    }
    lines.addAll(placeManager.diagnostics.reversed.take(10));
    geofenceController.setPersistenceDiagnostics(lines);
  }

  @override
  void dispose() {
    placeManager.removeListener(_publishDiagnostics);
    placeManager.dispose();
    geofenceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PingPlace',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: PingPlaceHomeScreen(
        controller: geofenceController,
        placeManager: placeManager,
      ),
    );
  }
}
