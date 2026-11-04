import 'package:pingplace/src/background/multi_place_background_arrival_session.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

/// A place as registered with Android, with the configuration the native
/// service sends along with its geofence events.
final class FakePlace {
  const FakePlace(
    this.id, {
    required this.latitude,
    required this.longitude,
    this.outerRadius = 300,
  });

  final String id;
  final double latitude;
  final double longitude;
  final double outerRadius;

  Map<String, Object?> get config => {
    'placeId': id,
    'targetLatitude': latitude,
    'targetLongitude': longitude,
    'outerRadius': outerRadius,
    'innerRadius': 80.0,
    'rearmRadius': 350.0,
    'cooldownSeconds': 600,
    'approachTimeoutSeconds': 600,
    'maxAcceptedAccuracy': 50.0,
  };

  /// A position [metersNorth] of this place.
  (double, double) north(double metersNorth) =>
      (latitude + metersNorth / 111320, longitude);
}

/// Models PreciseLocationService as far as the Dart session depends on it:
///
/// * A geofence ENTER adds the place to `activePlaceIds` and starts GPS.
/// * A geofence EXIT neither starts GPS nor routes fixes to the place; the
///   session asks with `startVerification:<id>` when it needs to measure the
///   exit. (Build 19 also added the place, so an ARMED place kept receiving,
///   and ignoring, fixes and kept GPS running after every other place had
///   finished, until the watchdog stopped it.)
/// * `startVerification:<id>` adds the place and starts GPS.
/// * `stopPlace:<id>` removes the place; when no place is left, GPS stops and
///   the service stops, destroying the headless engine (this process). While
///   Dart is still handling delivered events, the service stop waits for them
///   (`deferStopsWhileEventsInFlight`); events still queued for a destroyed
///   engine are lost.
/// * Every fix is fanned out to every place in `activePlaceIds`; while GPS is
///   off, or the service is stopped, fixes never reach Dart.
/// * The verification watchdog stops GPS and the service.
///
/// The plain recording fakes used elsewhere deliver every sample regardless,
/// which hid APP-10D: a session can believe it is verifying while the native
/// service has already stopped routing fixes to it.
final class NativeVerificationFake {
  NativeVerificationFake({required DateTime start}) : _now = start;

  final runtime = InMemoryArrivalRuntimeStore();
  final notifications = InMemoryNotificationService();
  final diagnostics = <String>[];
  final commands = <String>[];
  final Set<String> activePlaceIds = <String>{};
  final Map<String, FakePlace> _places = {};
  bool gpsOn = false;
  int droppedFixes = 0;
  int processes = 0;
  int lostEvents = 0;

  /// False models the service as of 20a5f13: a stop that left no place
  /// verifying destroyed the engine at once, with events Dart had not yet
  /// handled (for example a second EXIT from the same geofence callback).
  bool deferStopsWhileEventsInFlight = true;
  int _inFlight = 0;
  bool _stopDeferred = false;
  Future<void> _tail = Future<void>.value();
  DateTime _now;
  MultiPlaceBackgroundArrivalSession? _session;

  bool get serviceRunning => _session != null;

  void register(FakePlace place) => _places[place.id] = place;

  MultiPlaceBackgroundArrivalSession _process() {
    final existing = _session;
    if (existing != null) return existing;
    processes++;
    diagnostics.add('-- NATIVE SERVICE STARTED process=$processes');
    return _session = MultiPlaceBackgroundArrivalSession(
      onDiagnostic: diagnostics.add,
      onCommand: _command,
      runtimeStore: runtime,
      notificationService: notifications,
      clock: () => _now,
    );
  }

  Future<void> _command(String command) async {
    commands.add(command);
    final separator = command.indexOf(':');
    final name = separator < 0 ? command : command.substring(0, separator);
    final placeId = separator < 0 ? null : command.substring(separator + 1);
    switch (name) {
      case 'stopPlace':
        activePlaceIds.remove(placeId);
        if (activePlaceIds.isEmpty) {
          if (deferStopsWhileEventsInFlight && _inFlight > 0) {
            gpsOn = false;
            _stopDeferred = true;
            diagnostics.add(
              '-- NATIVE SERVICE STOP_DEFERRED events=$_inFlight',
            );
          } else {
            _stopService('STOPPING');
          }
        }
      case 'stop':
        activePlaceIds.clear();
        _stopService('STOPPING');
      case 'startVerification':
        if (placeId != null) activePlaceIds.add(placeId);
        gpsOn = true;
    }
  }

  void _stopService(String reason) {
    gpsOn = false;
    _stopDeferred = false;
    diagnostics.add('-- NATIVE SERVICE $reason');
    // The engine is destroyed; its timers die with it. Work already running
    // in the current event may still finish, as on the device.
    _session?.dispose();
    _session = null;
  }

  /// The native verification watchdog fires.
  void watchdog() {
    if (!serviceRunning) return;
    activePlaceIds.clear();
    _stopService('WATCHDOG_STOPPED');
  }

  /// Hands [payload] to the engine of [session]'s process. It is handled in
  /// order, after events delivered earlier, and is lost if that process's
  /// service has stopped by then.
  Future<void> _deliver(
    MultiPlaceBackgroundArrivalSession session,
    Map<String, Object?> payload,
  ) {
    _inFlight++;
    final next = _tail.then((_) async {
      try {
        if (!identical(_session, session)) {
          lostEvents++;
          diagnostics.add(
            '-- EVENT LOST type=${payload['type']} place=${payload['placeId']}',
          );
          return;
        }
        await session.handleEvent(payload);
      } finally {
        _inFlight--;
        if (_stopDeferred && activePlaceIds.isNotEmpty) {
          _stopDeferred = false;
        } else if (_stopDeferred && _inFlight == 0) {
          _stopService('STOPPING_AFTER_EVENTS');
        }
      }
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> enter(String id, DateTime at) {
    _now = at;
    final session = _process();
    activePlaceIds.add(id);
    gpsOn = true;
    return _deliver(session, {
      ..._places[id]!.config,
      'type': 'enter',
      'reminderText': 'Buy milk',
      'timestamp': at.toIso8601String(),
    });
  }

  Future<void> exit(String id, DateTime at) {
    _now = at;
    final session = _process();
    return _deliver(session, {
      ..._places[id]!.config,
      'type': 'exit',
      'timestamp': at.toIso8601String(),
    });
  }

  /// One GPS fix at ([latitude], [longitude]).
  Future<void> fix((double, double) position, DateTime at) async {
    _now = at;
    final session = _session;
    if (session == null || !gpsOn) {
      droppedFixes++;
      return;
    }
    for (final id in activePlaceIds.toList()) {
      await _deliver(session, {
        'type': 'location',
        'placeId': id,
        'latitude': position.$1,
        'longitude': position.$2,
        'accuracy': 5.0,
        'timestamp': at.toIso8601String(),
      });
    }
  }

  /// Fixes every two seconds from [from] for [count] fixes.
  Future<void> fixes(
    (double, double) position,
    DateTime from,
    int count,
  ) async {
    for (var index = 0; index < count; index++) {
      await fix(position, from.add(Duration(seconds: 2 * index)));
    }
  }

  int count(String fragment) =>
      diagnostics.where((line) => line.contains(fragment)).length;
}
