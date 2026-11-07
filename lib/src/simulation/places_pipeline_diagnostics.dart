import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../build_info.dart';
import '../geofence/development_geofence_controller.dart';
import '../geofence/geofence_service.dart';
import '../places/place_manager.dart';
import 'diagnostics_report.dart';

/// Developer Mode view of the multi-place pipeline: what Android was asked to
/// monitor, what it delivered, and what each place's arrival session did.
/// This, not the legacy single-target engine, is authoritative for places.
final class PlacesPipelineDiagnostics extends StatefulWidget {
  const PlacesPipelineDiagnostics({
    required this.controller,
    this.placeManager,
    this.logLimit = 40,
    this.pipelineLogLimit = 500,
    this.exporter = const PlatformDiagnosticsExporter(),
    this.buildInfo = BuildInfo.current,
    this.clock = DateTime.now,
    super.key,
  });

  final DevelopmentGeofenceController controller;
  final PlaceManager? placeManager;
  final int logLimit;

  /// The whole stored pipeline log: one visit can produce hundreds of lines,
  /// and its ENTER must stay visible next to its APPROACH_SUMMARY.
  final int pipelineLogLimit;
  final DiagnosticsExporter exporter;
  final BuildInfo buildInfo;
  final DateTime Function() clock;

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
  DateTime? _loadedAt;
  String? exportStatus;
  bool exporting = false;

  @override
  void initState() {
    super.initState();
    // Reload native logs on open: otherwise the pipeline log is only as fresh
    // as the app start, which hid the Build 17 visits.
    unawaited(_load(refreshNative: true));
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
      _loadedAt = DateTime.now();
    });
  }

  /// Reloads everything, then builds the report from the full stored
  /// history, not from the lines visible on screen. Logs are only read.
  Future<String> _report() async {
    await _load(refreshNative: true);
    final controller = widget.controller;
    return buildDiagnosticsReport(
      DiagnosticsSnapshot(
        build: widget.buildInfo,
        exportedAt: widget.clock(),
        health: health,
        registration: registration,
        places: places,
        lastGeofenceCallback: controller.recoveryStatus.lastBackgroundEvent,
        nativeLog: List.of(controller.recoveryStatus.diagnostics),
        pipelineLog: List.of(controller.backgroundDiagnostics),
        loadFailures: [?loadFailure],
      ),
    );
  }

  Future<void> _export({required bool share}) async {
    setState(() {
      exporting = true;
      exportStatus = null;
    });
    String status;
    try {
      final report = await _report();
      final lines = const LineSplitter().convert(report).length;
      if (share) {
        await widget.exporter.share(report);
        status = 'Share sheet opened ($lines lines).';
      } else {
        await widget.exporter.copy(report);
        status = 'Copied full diagnostics ($lines lines).';
      }
    } catch (error) {
      status = share ? 'Share failed: $error' : 'Copy failed: $error';
    }
    if (!mounted) return;
    setState(() {
      exporting = false;
      exportStatus = status;
    });
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(status)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final nativeLog = controller.recoveryStatus.diagnostics.reversed
        .take(widget.logLimit)
        .toList();
    final pipelineLog = controller.backgroundDiagnostics.reversed
        .take(widget.pipelineLogLimit)
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
            Text(
              'All times are UTC. Newest first. '
              'Loaded ${_loadedAt?.toUtc().toIso8601String() ?? 'never'}.',
              key: const Key('pipeline-loaded-at'),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('copy-diagnostics'),
                  onPressed: exporting
                      ? null
                      : () => unawaited(_export(share: false)),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy full diagnostics'),
                ),
                OutlinedButton.icon(
                  key: const Key('share-diagnostics'),
                  onPressed: exporting
                      ? null
                      : () => unawaited(_export(share: true)),
                  icon: const Icon(Icons.share),
                  label: const Text('Share diagnostics'),
                ),
              ],
            ),
            if (exportStatus != null)
              Text(exportStatus!, key: const Key('export-status')),
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
