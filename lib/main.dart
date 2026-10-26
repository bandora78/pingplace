import 'dart:async';

import 'package:flutter/material.dart';

import 'src/background/background_arrival.dart';
import 'src/geofence/development_geofence_controller.dart';
import 'src/home/pingplace_home_screen.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(geofenceController.initialize());
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
