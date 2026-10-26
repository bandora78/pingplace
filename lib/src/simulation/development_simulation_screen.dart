import 'package:flutter/material.dart';

import '../build_info.dart';
import '../geofence/development_geofence_controller.dart';
import '../geofence/geofence_service.dart';
import 'development_simulation_controller.dart';

final class DevelopmentSimulationScreen extends StatefulWidget {
  const DevelopmentSimulationScreen({required this.realGeofence, super.key});

  final DevelopmentGeofenceController realGeofence;

  @override
  State<DevelopmentSimulationScreen> createState() =>
      _DevelopmentSimulationScreenState();
}

final class _DevelopmentSimulationScreenState
    extends State<DevelopmentSimulationScreen> {
  final SimulationController controller = SimulationController();
  late final DevelopmentGeofenceController realGeofence = widget.realGeofence;
  late final TextEditingController latitudeController;
  late final TextEditingController longitudeController;
  late final TextEditingController reminderController;

  @override
  void initState() {
    super.initState();
    controller.addListener(_refresh);
    realGeofence.addListener(_refresh);
    latitudeController = TextEditingController(
      text: realGeofence.latitude.toString(),
    );
    longitudeController = TextEditingController(
      text: realGeofence.longitude.toString(),
    );
    reminderController = TextEditingController(text: realGeofence.reminderText);
  }

  @override
  void dispose() {
    controller.removeListener(_refresh);
    controller.dispose();
    realGeofence.removeListener(_refresh);
    latitudeController.dispose();
    longitudeController.dispose();
    reminderController.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PingPlace · Simulation Mode')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Development-only diagnostics and controls.'),
          const SizedBox(height: 4),
          Text(BuildInfo.current.versionLabel),
          Text(BuildInfo.current.commitLabel),
          Text(BuildInfo.current.buildTypeLabel),
          const SizedBox(height: 12),
          _RealGeofenceSection(
            controller: realGeofence,
            latitudeController: latitudeController,
            longitudeController: longitudeController,
            reminderController: reminderController,
          ),
          const SizedBox(height: 12),
          Text(
            'SIMULATION MODE',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          const Text(
            'Simulation controls use the same SmartArrivalDetectionEngine and '
            'are independent of the real Android geofence.',
          ),
          const SizedBox(height: 8),
          _StatusCard(controller: controller),
          const SizedBox(height: 12),
          _ControlGrid(controller: controller),
          const SizedBox(height: 12),
          Text('EVENT LOG', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Container(
            constraints: const BoxConstraints(minHeight: 180),
            padding: const EdgeInsets.all(8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: controller.eventLog.isEmpty
                ? const Text('No simulated events yet.')
                : SelectableText(controller.eventLog.reversed.join('\n')),
          ),
        ],
      ),
    );
  }
}

final class _RealGeofenceSection extends StatelessWidget {
  const _RealGeofenceSection({
    required this.controller,
    required this.latitudeController,
    required this.longitudeController,
    required this.reminderController,
  });

  final DevelopmentGeofenceController controller;
  final TextEditingController latitudeController;
  final TextEditingController longitudeController;
  final TextEditingController reminderController;

  @override
  Widget build(BuildContext context) {
    final permission = switch (controller.permission) {
      GeofencePermissionStatus.denied => 'DENIED',
      GeofencePermissionStatus.foregroundOnly => 'FOREGROUND ONLY',
      GeofencePermissionStatus.backgroundAllowed =>
        'BACKGROUND / ALWAYS ALLOWED',
    };
    final event = controller.lastEvent;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'REAL GEOFENCE TEST',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              'Android OS outer wake-up starts temporary precise verification '
              'only while APPROACHING.',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: latitudeController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Latitude'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: longitudeController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Longitude'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Outer radius: ${controller.radius.round()} m'),
            Text('Inner radius: ${controller.config.innerRadius.round()} m'),
            Text(
              'Max accepted accuracy: '
              '${controller.config.maxAcceptedAccuracy.toStringAsFixed(0)} m',
            ),
            Text(
              'Registration: ${controller.registered ? 'REGISTERED' : 'NOT REGISTERED'}',
            ),
            Text('Permission: $permission'),
            Text(
              'Platform registration confirmed: '
              '${controller.recoveryStatus.registrationConfirmed ? 'YES' : 'NO / UNKNOWN'}',
            ),
            Text(
              'Last recovery: '
              'attempt=${controller.recoveryStatus.lastRecoveryAttempt?.toIso8601String() ?? 'none'} '
              'success=${controller.recoveryStatus.lastRecoverySuccess?.toIso8601String() ?? 'none'}',
            ),
            if (controller.recoveryStatus.lastRecoveryFailure != null)
              Text(
                'Recovery failure: ${controller.recoveryStatus.lastRecoveryFailure}',
              ),
            Text(
              'Last background event: '
              '${controller.recoveryStatus.lastBackgroundEvent?.toIso8601String() ?? 'none'}',
            ),
            if (controller.recoveryStatus.lastBackgroundFailure != null)
              Text(
                'Background failure: ${controller.recoveryStatus.lastBackgroundFailure}',
              ),
            if (controller.recoveryStatus.diagnostics.isNotEmpty)
              SelectableText(
                controller.recoveryStatus.diagnostics.reversed
                    .take(6)
                    .join('\n'),
              ),
            Text(
              'Notification readiness: '
              '${controller.notificationPermission.name.toUpperCase()}',
            ),
            Text(
              'Last notification: '
              '${controller.lastNotificationResult?.name ?? 'none'} '
              '${controller.lastNotificationAt?.toIso8601String() ?? ''}',
            ),
            if (controller.currentVisitId != null)
              Text('Current visit: ${controller.currentVisitId}'),
            Text('Engine state: ${controller.state.name.toUpperCase()}'),
            Text(
              'Precise location: '
              '${controller.preciseLocationActive ? 'ACTIVE' : 'INACTIVE'}',
            ),
            if (controller.latestLatitude != null)
              Text(
                'Latest location: ${controller.latestLatitude!.toStringAsFixed(6)}, '
                '${controller.latestLongitude!.toStringAsFixed(6)}',
              ),
            Text(
              'Latest distance: '
              '${controller.latestDistance?.toStringAsFixed(1) ?? '—'} m',
            ),
            Text(
              'Latest accuracy: '
              '${controller.latestAccuracy?.toStringAsFixed(1) ?? '—'} m',
            ),
            Text(
              'Latest timestamp: '
              '${controller.latestLocationTimestamp?.toIso8601String() ?? '—'}',
            ),
            Text(
              'Approach timeout: '
              '${controller.approachDeadline?.toIso8601String() ?? 'inactive'}',
            ),
            TextField(
              controller: reminderController,
              decoration: const InputDecoration(labelText: 'Reminder text'),
              onChanged: (value) => controller.setReminderText(value),
            ),
            if (controller.arrivalConfirmed)
              const Text('ARRIVED CONFIRMED; precise location stopped.'),
            if (event != null)
              Text(
                'Last real event: ${event.type.name.toUpperCase()} at ${event.at.toIso8601String()}',
              ),
            if (controller.lastError != null)
              Text(
                'ERROR: ${controller.lastError}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: controller.requestPermission,
                  child: const Text('REQUEST / CHECK PERMISSION'),
                ),
                OutlinedButton(
                  onPressed: controller.restoreGeofence,
                  child: const Text('CHECK / RESTORE GEOFENCE'),
                ),
                FilledButton(
                  onPressed: controller.requestNotificationPermission,
                  child: const Text('ALLOW NOTIFICATIONS'),
                ),
                OutlinedButton(
                  onPressed: controller.openNotificationSettings,
                  child: const Text('NOTIFICATION SETTINGS'),
                ),
                FilledButton(
                  onPressed: controller.initialized
                      ? () {
                          final latitude = double.tryParse(
                            latitudeController.text,
                          );
                          final longitude = double.tryParse(
                            longitudeController.text,
                          );
                          if (latitude == null || longitude == null) return;
                          controller.latitude = latitude;
                          controller.longitude = longitude;
                          controller.register();
                        }
                      : null,
                  child: const Text('REGISTER OUTER GEOFENCE'),
                ),
                OutlinedButton(
                  onPressed: controller.remove,
                  child: const Text('REMOVE GEOFENCE'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (controller.eventLog.isNotEmpty)
              SelectableText(controller.eventLog.reversed.take(8).join('\n')),
          ],
        ),
      ),
    );
  }
}

final class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final SimulationController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state.name.toUpperCase();
    final notification = controller.notificationRequested
        ? 'NOTIFICATION REQUESTED (simulation only)'
        : 'No notification requested';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'STATE: $state',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('Simulated time: ${controller.clock.toIso8601String()}'),
            Text(
              'Distance: ${controller.lastDistance?.toStringAsFixed(1) ?? '—'} m  '
              'Accuracy: ${controller.lastAccuracy?.toStringAsFixed(1) ?? '—'} m',
            ),
            Text(
              'Precise location: ${controller.preciseLocationActive ? 'ACTIVE' : 'INACTIVE'}',
            ),
            Text(notification),
            Text(
              'Radii: outer ${controller.config.outerRadius.round()} m · '
              'inner ${controller.config.innerRadius.round()} m · '
              'rearm ${controller.config.rearmRadius.round()} m',
            ),
          ],
        ),
      ),
    );
  }
}

final class _ControlGrid extends StatelessWidget {
  const _ControlGrid({required this.controller});

  final SimulationController controller;

  @override
  Widget build(BuildContext context) {
    final buttons = [
      ('ARM TEST', controller.armTest),
      ('SIMULATE OUTER ENTER', controller.simulateOuterEnter),
      ('SIMULATE LOCATION 250m', () => controller.simulateLocation(250)),
      ('SIMULATE LOCATION 150m', () => controller.simulateLocation(150)),
      ('SIMULATE LOCATION 90m', () => controller.simulateLocation(90)),
      ('SIMULATE LOCATION 70m', () => controller.simulateLocation(70)),
      ('SIMULATE EXIT 400m', controller.simulateExit),
      ('ADVANCE / EXPIRE COOLDOWN', controller.advanceOrExpireCooldown),
      ('SIMULATE APPROACH TIMEOUT', controller.simulateApproachTimeout),
      ('RESET TEST', controller.resetTest),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final button in buttons)
          FilledButton(onPressed: button.$2, child: Text(button.$1)),
      ],
    );
  }
}
