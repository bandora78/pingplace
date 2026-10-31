import 'dart:async';

import 'package:flutter/material.dart';

import '../build_info.dart';
import '../geofence/development_geofence_controller.dart';
import '../geofence/geofence_service.dart';
import '../places/place_manager.dart';
import '../places/places_section.dart';
import '../simulation/development_simulation_screen.dart';

final class PingPlaceHomeScreen extends StatefulWidget {
  const PingPlaceHomeScreen({
    required this.controller,
    required this.placeManager,
    super.key,
  });

  /// Permission, notification and developer diagnostics.
  final DevelopmentGeofenceController controller;

  /// The user's places (APP-10): the only source of geofence registrations.
  final PlaceManager placeManager;

  @override
  State<PingPlaceHomeScreen> createState() => _PingPlaceHomeScreenState();
}

final class _PingPlaceHomeScreenState extends State<PingPlaceHomeScreen> {
  int _developerTapCount = 0;

  DevelopmentGeofenceController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_refresh);
  }

  @override
  void dispose() {
    controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _checkPermission() async {
    await controller.requestPermission();
    // Registration rejected for missing permission can succeed now.
    if (controller.permission == GeofencePermissionStatus.backgroundAllowed &&
        widget.placeManager.lastError != null) {
      await widget.placeManager.retryRegistration();
    }
  }

  void _openDeveloperMode() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DevelopmentSimulationScreen(realGeofence: controller),
      ),
    );
  }

  void _onVersionTap() {
    _developerTapCount++;
    if (_developerTapCount >= 7) {
      _developerTapCount = 0;
      _openDeveloperMode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final permission = switch (controller.permission) {
      GeofencePermissionStatus.denied => 'נדרשת הרשאת מיקום',
      GeofencePermissionStatus.foregroundOnly => 'נדרשת הרשאת מיקום גם ברקע',
      GeofencePermissionStatus.backgroundAllowed => 'הרשאת מיקום תקינה',
    };

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('PingPlace')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'תזכורות הגעה',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            const Text('שמרו מקומות וקבלו תזכורת כשאתם מגיעים לכל אחד מהם.'),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(permission),
                    if (controller.lastError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        controller.lastError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () => unawaited(_checkPermission()),
                      child: const Text('בדיקת הרשאות'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            PlacesSection(manager: widget.placeManager),
            const SizedBox(height: 20),
            GestureDetector(
              key: const Key('developer-mode-gesture'),
              onLongPress: _openDeveloperMode,
              onTap: _onVersionTap,
              child: Semantics(
                label: 'גרסת האפליקציה. הקשה חוזרת פותחת מצב מפתח',
                child: Column(
                  children: [
                    Text(BuildInfo.current.versionLabel),
                    Text(BuildInfo.current.commitLabel),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
