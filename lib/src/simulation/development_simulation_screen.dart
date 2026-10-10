import 'package:flutter/material.dart';

import 'development_simulation_controller.dart';

final class DevelopmentSimulationScreen extends StatefulWidget {
  const DevelopmentSimulationScreen({super.key});

  @override
  State<DevelopmentSimulationScreen> createState() =>
      _DevelopmentSimulationScreenState();
}

final class _DevelopmentSimulationScreenState
    extends State<DevelopmentSimulationScreen> {
  final SimulationController controller = SimulationController();

  @override
  void initState() {
    super.initState();
    controller.addListener(_refresh);
  }

  @override
  void dispose() {
    controller.removeListener(_refresh);
    controller.dispose();
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
          const Text(
            'Development-only controls. All actions dispatch events to the '
            'SmartArrivalDetectionEngine.',
          ),
          const SizedBox(height: 12),
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
