import 'package:flutter/services.dart';

import '../build_info.dart';

/// Everything the Places pipeline card knows, captured at one moment.
final class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.build,
    required this.exportedAt,
    this.health = const {},
    this.registration = const {},
    this.places = const [],
    this.lastGeofenceCallback,
    this.nativeLog = const [],
    this.pipelineLog = const [],
    this.loadFailures = const [],
  });

  final BuildInfo build;
  final DateTime exportedAt;
  final Map<String, Object?> health;
  final Map<String, Object?> registration;
  final List<String> places;
  final DateTime? lastGeofenceCallback;

  /// Full stored native receiver/registration history, oldest first.
  final List<String> nativeLog;

  /// Full stored background arrival pipeline history, oldest first.
  final List<String> pipelineLog;
  final List<String> loadFailures;
}

/// Coordinates are kept to 3 decimals (about 100 m): enough to tell places
/// apart and to check a registration, not enough to pinpoint a home.
const exportCoordinateDecimals = 3;

final _keyedCoordinate = RegExp(
  r'\b(lat|lon|lng|latitude|longitude)=(-?\d+\.\d+)',
  caseSensitive: false,
);
final _coordinatePair = RegExp(r'(-?\d{1,3}\.\d{4,}),\s*(-?\d{1,3}\.\d{4,})');

/// Rounds coordinates in a log line; distances, accuracies and timestamps
/// are left unchanged.
String redactCoordinates(String line) {
  String round(String value) =>
      double.parse(value).toStringAsFixed(exportCoordinateDecimals);
  return line
      .replaceAllMapped(
        _keyedCoordinate,
        (match) => '${match[1]}=${round(match[2]!)}',
      )
      .replaceAllMapped(
        _coordinatePair,
        (match) => '${round(match[1]!)},${round(match[2]!)}',
      );
}

bool _isVisitSummary(String line) =>
    line.contains('APPROACH_SUMMARY') ||
    line.contains('ENTER_SUPPRESSED') ||
    line.contains('APPROACH_RESTARTED') ||
    line.contains('EXIT_CONFIRMED');

bool _isEngineEvent(String line) =>
    line.contains('BACKGROUND_ENGINE_') ||
    line.contains('FIRST_LOCATION_SAMPLE') ||
    line.contains('PLACE_VERIFICATION_STOPPED') ||
    line.contains('WATCHDOG');

bool _isNotification(String line) => line.contains('NOTIFICATION_');

bool _isError(String line) =>
    line.contains('FAILED') ||
    line.contains('ERROR') ||
    line.contains('BLOCKED') ||
    line.contains('NOT_READY') ||
    line.contains('NOT_ROUTED') ||
    line.contains('CORRUPT') ||
    line.contains('UNKNOWN_PLACE') ||
    line.contains('GEOFENCES_CLEARED');

/// Plain-text report for copying or sharing. Read-only: building it never
/// changes or clears any log.
String buildDiagnosticsReport(DiagnosticsSnapshot snapshot) {
  final native = snapshot.nativeLog.map(redactCoordinates).toList();
  final pipeline = snapshot.pipelineLog.map(redactCoordinates).toList();
  final all = [...native, ...pipeline];
  final out = StringBuffer();

  void section(String title, Iterable<String> lines) {
    final list = lines.toList();
    out
      ..writeln()
      ..writeln('== $title (${list.length}) ==');
    if (list.isEmpty) {
      out.writeln('none');
    } else {
      list.forEach(out.writeln);
    }
  }

  final build = snapshot.build;
  out
    ..writeln('PingPlace diagnostics report')
    ..writeln(
      'App: ${build.version} (Build ${build.buildNumber}) '
      'commit ${build.commit} ${build.buildType}',
    )
    ..writeln('Exported: ${snapshot.exportedAt.toUtc().toIso8601String()}')
    ..writeln(
      'All times UTC. Logs oldest first. Coordinates rounded to '
      '$exportCoordinateDecimals decimals (~100 m).',
    );
  section('System health', [
    for (final entry in snapshot.health.entries)
      '${entry.key}: ${entry.value ?? 'n/a'}',
  ]);
  section('Android registration', [
    if (snapshot.registration.isNotEmpty)
      'confirmed=${snapshot.registration['confirmed'] ?? 'unknown'} '
          'applied=${snapshot.registration['appliedPlaceIds'] ?? '[]'} '
          'desired=${snapshot.registration['desiredPlaceIds'] ?? '[]'}',
    'lastGeofenceCallback='
        '${snapshot.lastGeofenceCallback?.toUtc().toIso8601String() ?? 'none'}',
  ]);
  section('Places', snapshot.places.map(redactCoordinates));
  section('Background engine events', all.where(_isEngineEvent));
  section('Visit summaries', pipeline.where(_isVisitSummary));
  section('Notification results', pipeline.where(_isNotification));
  section('Errors and failures', [
    ...snapshot.loadFailures,
    ...all.where(_isError),
  ]);
  section('Native receiver and registration log (full)', native);
  section('Background arrival pipeline log (full)', pipeline);
  return out.toString();
}

/// Copy and share actions, behind an interface so they can be tested.
abstract interface class DiagnosticsExporter {
  Future<void> copy(String report);
  Future<void> share(String report);
}

final class PlatformDiagnosticsExporter implements DiagnosticsExporter {
  const PlatformDiagnosticsExporter();

  static const channel = MethodChannel('pingplace/share');

  @override
  Future<void> copy(String report) =>
      Clipboard.setData(ClipboardData(text: report));

  @override
  Future<void> share(String report) => channel.invokeMethod<void>('shareText', {
    'text': report,
    'subject': 'PingPlace diagnostics',
  });
}
