import 'dart:async';

import 'package:flutter/material.dart';

import 'src/background/background_arrival.dart';
import 'src/geofence/development_geofence_controller.dart';
import 'src/home/pingplace_home_screen.dart';
import 'src/persistence/place_persistence.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(geofenceController.initialize());
    unawaited(_initializePlacePersistence());
  }

  Future<void> _initializePlacePersistence() async {
    final initialization = await placePersistence.initialize();
    if (initialization.succeeded) {
      try {
        await placePersistence.reconcileEnabledPlaces();
      } catch (error) {
        placePersistence.initializationFailure =
            'Place registration reconciliation failed: $error';
      }
    }
    geofenceController.setPersistenceInitializationFailure(
      placePersistence.initializationFailure,
    );
    if (initialization.succeeded) {
      try {
        geofenceController.setPersistenceDiagnostics(
          await placePersistence.diagnostics(),
        );
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    geofenceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PingPlace',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: PingPlaceHomeScreen(controller: geofenceController),
    );
  }
}
