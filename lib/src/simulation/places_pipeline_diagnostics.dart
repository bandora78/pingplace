import 'dart:async';

import 'package:flutter/material.dart';

import '../geofence/development_geofence_controller.dart';
import '../geofence/geofence_service.dart';
import '../places/place_manager.dart';

/// Developer Mode view of the multi-place pipeline: what Android was asked to
/// monitor, what it delivered, and what each place's arrival session did.
/// This, not the legacy single-target engine, is authoritative for places.
final class PlacesPipelineDiagnostics extends StatefulWidget {
  const PlacesPipelineDiagnostics({
    required this.controller,
    this.placeManager,
    this.logLimit = 40,
    super.key,
  });

  final DevelopmentGeofenceController controller;
  final PlaceManager? placeManager;
  final int logLimit;

  @override
  State<PlacesPipelineDiagnostics> createState() =>
      _PlacesPipelineDiagnosticsState();
}

final class _PlacesPipelineDiagnosticsState
    extends State<PlacesPipelineDiagnostics> {
  Map<String, Object?> health = const {};
  Map<String, Object?> registration = const {};
  List<String> places = const [];
  String? loadFailure;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool refreshNative = false}) async {
    setState(() => loading = true);
    final failures = <String>[];
    if (refreshNative) {
      await widget.controller.refreshDiagnostics(reason: 'places_pipeline');
    }
    Map<String, Object?> nextHealth = const {};
    Map<String, Object?> nextRegistration = const {};
    var nextPlaces = const <String>[];
    try {
      nextHealth = await widget.controller.service.systemHealth();
    } catch (error) {
      failures.add('SYSTEM_HEALTH_FAILED: $error');
    }
    try {
      nextRegistration = await widget.controller.service
          .multiRegistrationStatus();
    } catch (error) {
      failures.add('REGISTRATION_STATUS_FAILED: $error');
    }
    final manager = widget.placeManager;
    if (manager != null) {
      try {
        await manager.refresh();
        nextPlaces = await manager.placeRuntimeDiagnostics();
      } catch (error) {
        failures.add('PLACE_RUNTIME_FAILED: $error');
      }
    }
    if (!mounted) return;
    setState(() {
      health = nextHealth;
      registration = nextRegistration;
      places = nextPlaces;
      loadFailure = failures.isEmpty ? null : failures.join('\n');
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final nativeLog = controller.recoveryStatus.diagnostics.reversed
        .take(widget.logLimit)
        .toList();
    final pipelineLog = controller.backgroundDiagnostics.reversed
        .take(widget.logLimit)
        .toList();
    return Card(
      key: const Key('places-pipeline-diagnostics'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Places pipeline (authoritative for places)',
              style: theme.textTheme.titleMedium,
            ),
            const Text('All times are UTC. Newest first.'),
            const SizedBox(height: 8),
            Text('System health', style: theme.textTheme.titleSmall),
            if (health.isEmpty)
              const Text('unavailable')
            else
              for (final entry in health.entries)
                Text('${entry.key}: ${entry.value ?? 'n/a'}'),
            const SizedBox(height: 8),
            Text('Android registration', style: theme.textTheme.titleSmall),
            Text(
              'confirmed=${registration['confirmed'] ?? 'unknown'} '
              'applied=${registration['appliedPlaceIds'] ?? '[]'} '
              'desired=${registration['desiredPlaceIds'] ?? '[]'}',
            ),
            const SizedBox(height: 8),
            Text('Places', style: theme.textTheme.titleSmall),
            if (places.isEmpty)
              const Text('none')
            else
              SelectableText(places.join('\n')),
            const SizedBox(height: 8),
            Text(
              'Native receiver and registration log',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              'Last geofence callback: '
              '${controller.recoveryStatus.lastBackgroundEvent?.toUtc().toIso8601String() ?? 'none'}',
              key: const Key('last-geofence-callback'),
            ),
            SelectableText(
              nativeLog.isEmpty ? 'empty' : nativeLog.join('\n'),
              key: const Key('native-log'),
            ),
            const SizedBox(height: 8),
            Text(
              'Background arrival pipeline log',
              style: theme.textTheme.titleSmall,
            ),
            SelectableText(
              pipelineLog.isEmpty ? 'empty' : pipelineLog.join('\n'),
              key: const Key('pipeline-log'),
            ),
            if (loadFailure != null)
              Text(
                loadFailure!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const Key('refresh-places-pipeline'),
                onPressed: loading
                    ? null
                    : () => unawaited(_load(refreshNative: true)),
                child: Text(loading ? 'Refreshing…' : 'Refresh'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
