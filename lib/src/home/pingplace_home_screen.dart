import 'package:flutter/material.dart';

import '../build_info.dart';
import '../geofence/development_geofence_controller.dart';
import '../geofence/geofence_service.dart';
import '../simulation/development_simulation_screen.dart';

final class PingPlaceHomeScreen extends StatefulWidget {
  const PingPlaceHomeScreen({required this.controller, super.key});

  final DevelopmentGeofenceController controller;

  @override
  State<PingPlaceHomeScreen> createState() => _PingPlaceHomeScreenState();
}

final class _PingPlaceHomeScreenState extends State<PingPlaceHomeScreen> {
  late final TextEditingController latitudeController;
  late final TextEditingController longitudeController;
  late final TextEditingController radiusController;
  late final TextEditingController reminderController;
  late final FocusNode latitudeFocus;
  late final FocusNode longitudeFocus;
  late final FocusNode radiusFocus;
  late final FocusNode reminderFocus;
  int _developerTapCount = 0;

  DevelopmentGeofenceController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    latitudeController = TextEditingController();
    longitudeController = TextEditingController();
    radiusController = TextEditingController();
    reminderController = TextEditingController();
    latitudeFocus = FocusNode();
    longitudeFocus = FocusNode();
    radiusFocus = FocusNode();
    reminderFocus = FocusNode();
    controller.addListener(_refresh);
    _syncFields();
  }

  @override
  void dispose() {
    controller.removeListener(_refresh);
    latitudeController.dispose();
    longitudeController.dispose();
    radiusController.dispose();
    reminderController.dispose();
    latitudeFocus.dispose();
    longitudeFocus.dispose();
    radiusFocus.dispose();
    reminderFocus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    _syncFields();
    setState(() {});
  }

  void _syncFields() {
    if (!latitudeFocus.hasFocus) {
      latitudeController.text = controller.latitude.toString();
    }
    if (!longitudeFocus.hasFocus) {
      longitudeController.text = controller.longitude.toString();
    }
    if (!radiusFocus.hasFocus) {
      radiusController.text = controller.radius.toString();
    }
    if (!reminderFocus.hasFocus) {
      reminderController.text = controller.reminderText;
    }
  }

  Future<void> _saveAndRegister() async {
    final latitude = double.tryParse(latitudeController.text.trim());
    final longitude = double.tryParse(longitudeController.text.trim());
    final radius = double.tryParse(radiusController.text.trim());
    if (latitude == null || longitude == null || radius == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('נא להזין קואורדינטות ורדיוס תקינים')),
      );
      return;
    }

    final succeeded = await controller.registerTarget(
      targetLatitude: latitude,
      targetLongitude: longitude,
      targetRadius: radius,
      targetReminderText: reminderController.text,
    );
    if (!mounted || succeeded) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          controller.lastError ?? 'שמירת היעד והפעלת המעקב נכשלו',
        ),
      ),
    );
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
    final status = controller.registered ? 'המעקב פעיל' : 'המעקב כבוי';

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('PingPlace')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'תזכורת הגעה',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            const Text('הגדירו יעד אחד וקבלו תזכורת כשאתם מגיעים אליו.'),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('סטטוס: $status'),
                    const SizedBox(height: 4),
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
                    if (controller.recoveryStatus.lastRecoveryFailure != null)
                      Text(
                        controller.recoveryStatus.lastRecoveryFailure!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: controller.requestPermission,
                      child: const Text('בדיקת הרשאות'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'היעד הפעיל',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: reminderController,
                      focusNode: reminderFocus,
                      decoration: const InputDecoration(
                        labelText: 'תזכורת',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: latitudeController,
                            focusNode: latitudeFocus,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'קו רוחב',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: longitudeController,
                            focusNode: longitudeFocus,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'קו אורך',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: radiusController,
                      focusNode: radiusFocus,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'רדיוס התראה במטרים',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: controller.initialized
                          ? _saveAndRegister
                          : null,
                      child: const Text('שמירה והפעלת מעקב'),
                    ),
                    OutlinedButton(
                      onPressed: controller.remove,
                      child: const Text('כיבוי מעקב'),
                    ),
                    OutlinedButton(
                      onPressed: controller.restoreGeofence,
                      child: const Text('שחזור מעקב'),
                    ),
                  ],
                ),
              ),
            ),
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
