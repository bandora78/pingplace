import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../build_info.dart';
import 'geofence_service.dart';

String buildGeofenceDiagnosticReport({
  required BuildInfo buildInfo,
  required GeofencePermissionStatus permission,
  required GeofenceDiagnosticsSnapshot snapshot,
}) {
  final lines = <String>[
    buildInfo.versionLabel,
    buildInfo.commitLabel,
    buildInfo.buildTypeLabel,
    'Android: ${snapshot.androidVersion ?? 'Unknown'}',
    'Device: ${snapshot.manufacturer ?? 'Unknown'} ${snapshot.model ?? ''}'
        .trim(),
    'Location permission: ${permission.name}',
    'Location services: ${snapshot.locationServicesEnabled == null
        ? 'Not available'
        : snapshot.locationServicesEnabled!
        ? 'enabled'
        : 'disabled'}',
    'Battery optimization ignored: ${snapshot.batteryOptimizationIgnored ?? 'Not available'}',
    'Desired geofences: ${snapshot.desiredGeofenceCount}',
    'Locally tracked geofences: ${snapshot.trackedGeofenceCount}',
    'Platform confirmation is not inferred from persisted desired state.',
    'Pending removal tombstones: ${snapshot.pendingRemovalTombstoneCount}',
    'Configuration generation: ${snapshot.persistedConfigurationGeneration ?? 'Unknown'}',
    'Last reconciliation: ${snapshot.lastReconciliationAttempt ?? 'Unknown'} (${snapshot.lastReconciliationResult ?? 'Unknown'})',
    'Last boot recovery: ${snapshot.lastBootRecoveryAttempt ?? 'Unknown'} (${snapshot.lastBootRecoveryResult ?? 'Unknown'})',
    'Last registration error: ${snapshot.lastRegistrationError ?? 'None recorded'}',
    'Last removal error: ${snapshot.lastRemovalError ?? 'None recorded'}',
    '',
    'Diagnostic events:',
    ...snapshot.events,
  ];
  return lines.join('\n');
}

final class GeofenceDiagnosticsScreen extends StatefulWidget {
  const GeofenceDiagnosticsScreen({required this.service, super.key});

  final GeofenceService service;

  @override
  State<GeofenceDiagnosticsScreen> createState() =>
      _GeofenceDiagnosticsScreenState();
}

final class _GeofenceDiagnosticsScreenState
    extends State<GeofenceDiagnosticsScreen> {
  GeofenceDiagnosticsSnapshot snapshot = const GeofenceDiagnosticsSnapshot();
  GeofencePermissionStatus permission = GeofencePermissionStatus.denied;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final values = await Future.wait<Object>([
        widget.service.diagnostics,
        widget.service.checkPermission(),
      ]);
      if (!mounted) return;
      setState(() {
        snapshot = values[0] as GeofenceDiagnosticsSnapshot;
        permission = values[1] as GeofencePermissionStatus;
        loading = false;
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = '$exception';
      });
    }
  }

  String _report() => buildGeofenceDiagnosticReport(
    buildInfo: BuildInfo.current,
    permission: permission,
    snapshot: snapshot,
  );

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report()));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Diagnostics copied')));
    }
  }

  Future<void> _share() async {
    try {
      await widget.service.shareDiagnostics(_report());
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Share failed: $exception')));
      }
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear diagnostic history?'),
        content: const Text(
          'This clears only diagnostic events. Saved reminders and geofence state are unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('CLEAR'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.service.clearDiagnostics();
      await _refresh();
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    }
  }

  @override
  Widget build(BuildContext context) {
    final locationServices = snapshot.locationServicesEnabled == null
        ? 'Not available'
        : snapshot.locationServicesEnabled!
        ? 'ENABLED'
        : 'DISABLED';
    final battery = snapshot.batteryOptimizationIgnored == null
        ? 'Not available'
        : snapshot.batteryOptimizationIgnored!
        ? 'IGNORED'
        : 'ACTIVE';
    return Scaffold(
      appBar: AppBar(
        title: const Text('GEOFENCE DIAGNOSTICS'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Developer-only, read-only diagnostics.'),
          const SizedBox(height: 8),
          Text(BuildInfo.current.versionLabel),
          Text(BuildInfo.current.commitLabel),
          Text(BuildInfo.current.buildTypeLabel),
          const Divider(),
          Text('Android: ${snapshot.androidVersion ?? 'Unknown'}'),
          Text(
            'Device: ${snapshot.manufacturer ?? 'Unknown'} ${snapshot.model ?? ''}',
          ),
          Text('Location permission: ${permission.name.toUpperCase()}'),
          Text('Location services: $locationServices'),
          Text('Battery optimization: $battery'),
          const SizedBox(height: 8),
          const Text(
            'PERSISTED DESIRED STATE',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text('Desired geofences: ${snapshot.desiredGeofenceCount}'),
          Text(
            'Configuration generation: ${snapshot.persistedConfigurationGeneration ?? 'Unknown'}',
          ),
          Text(
            'Pending removal tombstones: ${snapshot.pendingRemovalTombstoneCount}',
          ),
          const SizedBox(height: 8),
          const Text(
            'LOCAL / PLATFORM EVIDENCE',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            'Locally tracked registrations: ${snapshot.trackedGeofenceCount}',
          ),
          const Text(
            'Platform confirmation is reported only from successful registration callbacks; local storage alone is not proof.',
          ),
          Text(
            'Last reconciliation: ${snapshot.lastReconciliationAttempt ?? 'Unknown'}',
          ),
          Text(
            'Reconciliation result: ${snapshot.lastReconciliationResult ?? 'Unknown'}',
          ),
          Text(
            'Last boot recovery: ${snapshot.lastBootRecoveryAttempt ?? 'Unknown'}',
          ),
          Text(
            'Boot recovery result: ${snapshot.lastBootRecoveryResult ?? 'Unknown'}',
          ),
          Text(
            'Last registration error: ${snapshot.lastRegistrationError ?? 'None recorded'}',
          ),
          Text(
            'Last removal error: ${snapshot.lastRemovalError ?? 'None recorded'}',
          ),
          if (error != null) Text('Diagnostics error: $error'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('REFRESH'),
              ),
              OutlinedButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy),
                label: const Text('COPY REPORT'),
              ),
              OutlinedButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.share),
                label: const Text('SHARE REPORT'),
              ),
              OutlinedButton.icon(
                onPressed: _clear,
                icon: const Icon(Icons.delete_outline),
                label: const Text('CLEAR EVENT HISTORY'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'EVENT HISTORY (${snapshot.events.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          if (loading) const LinearProgressIndicator(),
          if (snapshot.events.isEmpty && !loading)
            const Text('No persistent diagnostic events.'),
          if (snapshot.events.isNotEmpty)
            SelectableText(snapshot.events.join('\n')),
        ],
      ),
    );
  }
}
