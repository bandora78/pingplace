import 'dart:async';
import 'dart:math';

import '../geofence/geofence_service.dart';
import '../persistence/place.dart';
import '../persistence/place_repositories.dart';
import '../runtime/arrival_runtime_store.dart';

/// Android's registration state for one place, as last read from the
/// platform. Only [registered] means Android confirmed the geofence.
enum PlaceRegistrationState { registered, pending, disabled, unknown }

/// Platform view of the multi-place registration.
final class PlaceRegistrationStatus {
  const PlaceRegistrationStatus({
    required this.confirmed,
    required this.appliedPlaceIds,
    required this.desiredPlaceIds,
  });

  final bool confirmed;
  final Set<String> appliedPlaceIds;
  final Set<String> desiredPlaceIds;
}

/// Registers the complete enabled place set with Android geofencing.
abstract interface class PlaceRegistrar {
  Future<void> registerPlaces(List<GeofencePlaceRegistration> places);
  Future<PlaceRegistrationStatus> status();
}

final class GeofencePlaceRegistrar implements PlaceRegistrar {
  GeofencePlaceRegistrar(this.service);
  final MethodChannelGeofenceService service;

  @override
  Future<void> registerPlaces(List<GeofencePlaceRegistration> places) =>
      service.registerPlaces(places);

  @override
  Future<PlaceRegistrationStatus> status() async {
    final raw = await service.multiRegistrationStatus();
    Set<String> ids(Object? value) =>
        value is List ? value.whereType<String>().toSet() : <String>{};
    return PlaceRegistrationStatus(
      confirmed: raw['confirmed'] == true,
      appliedPlaceIds: ids(raw['appliedPlaceIds']),
      desiredPlaceIds: ids(raw['desiredPlaceIds']),
    );
  }
}

/// User-editable fields of a place. Derived radii are filled in by
/// [PlaceManager] so that the stored place always validates.
final class PlaceDraft {
  const PlaceDraft({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radius,
    required this.reminderText,
    required this.enabled,
  });

  final String name;
  final double latitude;
  final double longitude;
  final double radius;
  final String reminderText;
  final bool enabled;

  /// Returns a user-facing validation error, or null when valid.
  String? validate() {
    if (name.trim().isEmpty) return 'PLACE_NAME_REQUIRED';
    if (reminderText.trim().isEmpty) return 'REMINDER_TEXT_REQUIRED';
    if (!latitude.isFinite || latitude < -90 || latitude > 90) {
      return 'LATITUDE_OUT_OF_RANGE';
    }
    if (!longitude.isFinite || longitude < -180 || longitude > 180) {
      return 'LONGITUDE_OUT_OF_RANGE';
    }
    if (!radius.isFinite || radius < minRadius || radius > maxRadius) {
      return 'RADIUS_OUT_OF_RANGE';
    }
    return null;
  }

  /// Android recommends geofences of at least ~100 m; smaller radii are
  /// unreliable. The upper bound rejects obvious typos.
  static const minRadius = 50.0;
  static const maxRadius = 50000.0;
}

/// A place with its reminder text and registration state, for display.
final class ManagedPlace {
  const ManagedPlace({
    required this.place,
    required this.reminderText,
    required this.registration,
  });

  final Place place;
  final String reminderText;
  final PlaceRegistrationState registration;
}

enum PlaceOperationOutcome {
  /// Persisted and, when needed, registered with Android.
  saved,

  /// Rejected before anything was written.
  invalid,

  /// The place does not exist (for example deleted meanwhile).
  notFound,

  /// The database write failed; nothing changed.
  persistFailed,

  /// Android rejected the new registration set; the previous places and the
  /// previous registration were restored.
  rolledBack,

  /// Android rejected the change and restoring the previous state also
  /// failed. Stored data is the previous data, but the platform state is not
  /// confirmed. A retry is required.
  rollbackFailed,

  /// A retry of the stored registration set was rejected by Android.
  registrationFailed,
}

final class PlaceOperationResult {
  const PlaceOperationResult(this.outcome, [this.detail]);
  final PlaceOperationOutcome outcome;
  final String? detail;
  bool get succeeded => outcome == PlaceOperationOutcome.saved;
}

typedef PlaceManagerListener = void Function();

/// Single source of truth for the user's places (APP-10).
///
/// All mutations are serialized. Each one persists the complete new place
/// document and then registers the complete enabled set with Android, so the
/// platform never sees a partial update. A failed registration restores the
/// previous document and the previous registration.
final class PlaceManager {
  PlaceManager({
    required this.database,
    required this.registrar,
    required this.runtimeStore,
    String Function()? idGenerator,
  }) : _idGenerator = idGenerator ?? _defaultId;

  final PlaceDatabase database;
  final PlaceRegistrar registrar;
  final PerPlaceArrivalRuntimeStore runtimeStore;
  final String Function() _idGenerator;
  final List<PlaceManagerListener> _listeners = [];
  final List<String> _log = [];
  Future<void> _tail = Future<void>.value();
  int _pending = 0;
  bool _disposed = false;

  List<ManagedPlace> places = const [];
  bool loaded = false;
  String? lastError;
  String? loadFailure;
  bool registrationStatusKnown = false;

  bool get busy => _pending > 0;
  List<String> get diagnostics => List.unmodifiable(_log);

  void addListener(PlaceManagerListener listener) => _listeners.add(listener);
  void removeListener(PlaceManagerListener listener) =>
      _listeners.remove(listener);

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }

  /// Registers the stored enabled places with Android and loads the list.
  /// Called once at startup after migration.
  Future<void> initialize() => _serialize(() async {
    try {
      final data = await database.read();
      await registrar.registerPlaces(registrationsFor(data));
      _record('PLACES_RECONCILED enabled=${registrationsFor(data).length}');
    } catch (error) {
      lastError = 'PLACE_REGISTRATION_FAILED: ${_describe(error)}';
      _record(lastError!);
    }
    await _reload();
  });

  /// Re-reads stored places and Android's registration status.
  Future<void> refresh() => _serialize(_reload);

  /// Re-registers the stored enabled places, for example after the user
  /// grants background location permission.
  Future<PlaceOperationResult> retryRegistration() => _serialize(() async {
    try {
      final data = await database.read();
      await registrar.registerPlaces(registrationsFor(data));
      lastError = null;
      _record('PLACES_REREGISTERED');
      await _reload();
      return const PlaceOperationResult(PlaceOperationOutcome.saved);
    } catch (error) {
      lastError = 'PLACE_REGISTRATION_FAILED: ${_describe(error)}';
      _record(lastError!);
      await _reload();
      return PlaceOperationResult(
        PlaceOperationOutcome.registrationFailed,
        lastError,
      );
    }
  });

  Future<PlaceOperationResult> add(PlaceDraft draft) {
    final invalid = draft.validate();
    if (invalid != null) return Future.value(_invalid(invalid));
    final id = _idGenerator();
    return _mutate('ADD $id', (data) {
      if (data.places.any((place) => place.id == id)) {
        throw StateError('Generated place id collides: $id');
      }
      final place = _applyDraft(
        Place(
          id: id,
          name: draft.name,
          latitude: 0,
          longitude: 0,
          enabled: false,
        ),
        draft,
      );
      return data.copyWith(
        places: [...data.places, place],
        reminders: [
          ...data.reminders,
          Reminder(id: 'reminder-$id', placeId: id, text: draft.reminderText),
        ],
      );
    });
  }

  Future<PlaceOperationResult> update(String placeId, PlaceDraft draft) {
    final invalid = draft.validate();
    if (invalid != null) return Future.value(_invalid(invalid));
    return _mutate(
      'UPDATE $placeId',
      (data) {
        final current = _find(data, placeId);
        final updated = _applyDraft(current, draft);
        return data.copyWith(
          places: [
            for (final place in data.places)
              place.id == placeId ? updated : place,
          ],
          reminders: _withReminderText(data, placeId, draft.reminderText),
        );
      },
      resetRuntimeWhen: (before, after) =>
          _locationChanged(before, after, placeId),
    );
  }

  Future<PlaceOperationResult> setEnabled(String placeId, bool enabled) =>
      _mutate('${enabled ? 'ENABLE' : 'DISABLE'} $placeId', (data) {
        final current = _find(data, placeId);
        return data.copyWith(
          places: [
            for (final place in data.places)
              place.id == placeId ? current.copyWith(enabled: enabled) : place,
          ],
        );
      });

  Future<PlaceOperationResult> delete(String placeId) =>
      _mutate('DELETE $placeId', (data) {
        _find(data, placeId);
        return data.copyWith(
          places: data.places.where((place) => place.id != placeId).toList(),
          reminders: data.reminders
              .where((reminder) => reminder.placeId != placeId)
              .toList(),
        );
      }, resetRuntimeWhen: (_, _) => {placeId});

  Future<PlaceOperationResult> _mutate(
    String label,
    PlaceData Function(PlaceData data) change, {
    Set<String> Function(PlaceData before, PlaceData after)? resetRuntimeWhen,
  }) => _serialize(() async {
    lastError = null;
    late PlaceData before;
    late PlaceData after;
    try {
      await database.transact<void>((current) async {
        before = current;
        after = change(current);
        after.validate();
        return PlaceDatabaseChange<void>(data: after, result: null);
      });
    } on _PlaceNotFound catch (error) {
      return _finish(
        PlaceOperationOutcome.notFound,
        '$label NOT_FOUND ${error.id}',
      );
    } on FormatException catch (error) {
      return _finish(
        PlaceOperationOutcome.invalid,
        '$label INVALID ${error.message}',
      );
    } catch (error) {
      return _finish(
        PlaceOperationOutcome.persistFailed,
        '$label PERSIST_FAILED ${_describe(error)}',
      );
    }

    final previousRegistrations = registrationsFor(before);
    final nextRegistrations = registrationsFor(after);
    if (!_sameRegistrations(previousRegistrations, nextRegistrations)) {
      try {
        await registrar.registerPlaces(nextRegistrations);
      } catch (error) {
        final failure = _describe(error);
        String? rollbackFailure;
        try {
          await database.replace(before);
          await registrar.registerPlaces(previousRegistrations);
        } catch (rollbackError) {
          rollbackFailure = _describe(rollbackError);
        }
        return rollbackFailure == null
            ? _finish(
                PlaceOperationOutcome.rolledBack,
                '$label REGISTRATION_FAILED $failure; previous places restored',
              )
            : _finish(
                PlaceOperationOutcome.rollbackFailed,
                '$label REGISTRATION_FAILED $failure; '
                'ROLLBACK_FAILED $rollbackFailure',
              );
      }
    }

    // A place whose target moved must not resume a visit or cooldown that
    // belongs to its old location. Name and reminder edits keep the state.
    for (final placeId
        in resetRuntimeWhen?.call(before, after) ?? const <String>{}) {
      try {
        await runtimeStore.clearForPlace(placeId);
        _record('$label RUNTIME_RESET $placeId');
      } catch (error) {
        _record('$label RUNTIME_RESET_FAILED $placeId ${_describe(error)}');
      }
    }
    return _finish(PlaceOperationOutcome.saved, '$label SAVED');
  });

  Future<PlaceOperationResult> _finish(
    PlaceOperationOutcome outcome,
    String message,
  ) async {
    _record(message);
    if (outcome != PlaceOperationOutcome.saved) lastError = message;
    await _reload();
    return PlaceOperationResult(outcome, message);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    _pending++;
    _notify();
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}).catchError((Object _) {});
    return next.whenComplete(() {
      _pending--;
      _notify();
    });
  }

  Future<void> _reload() async {
    try {
      final data = await database.read();
      PlaceRegistrationStatus? status;
      try {
        status = await registrar.status();
        registrationStatusKnown = true;
      } catch (error) {
        registrationStatusKnown = false;
        _record('REGISTRATION_STATUS_FAILED ${_describe(error)}');
      }
      places = [
        for (final place in data.places)
          ManagedPlace(
            place: place,
            reminderText: reminderTextFor(data, place.id),
            registration: _stateFor(place, status),
          ),
      ];
      loadFailure = null;
    } catch (error) {
      loadFailure = 'PLACE_LOAD_FAILED: ${_describe(error)}';
      _record(loadFailure!);
    }
    loaded = true;
    _notify();
  }

  PlaceRegistrationState _stateFor(
    Place place,
    PlaceRegistrationStatus? status,
  ) {
    if (!place.enabled) return PlaceRegistrationState.disabled;
    if (status == null) return PlaceRegistrationState.unknown;
    final registered =
        status.confirmed &&
        status.appliedPlaceIds.contains(place.id) &&
        status.desiredPlaceIds.contains(place.id);
    return registered
        ? PlaceRegistrationState.registered
        : PlaceRegistrationState.pending;
  }

  Place _applyDraft(Place base, PlaceDraft draft) {
    final radius = draft.radius;
    // Keep the existing inner/rearm radii (80/350 for migrated places) while
    // they remain valid for the new outer radius.
    final inner = base.innerRadius > radius ? radius : base.innerRadius;
    final rearm = base.rearmRadius < radius ? radius + 50 : base.rearmRadius;
    return base.copyWith(
      name: draft.name.trim(),
      latitude: draft.latitude,
      longitude: draft.longitude,
      outerRadius: radius,
      innerRadius: inner,
      rearmRadius: rearm,
      enabled: draft.enabled,
    );
  }

  static List<Reminder> _withReminderText(
    PlaceData data,
    String placeId,
    String text,
  ) {
    final existing = data.reminders.where((r) => r.placeId == placeId).toList();
    if (existing.isEmpty) {
      return [
        ...data.reminders,
        Reminder(id: 'reminder-$placeId', placeId: placeId, text: text),
      ];
    }
    // The editor shows one reminder per place: the first is replaced and any
    // additional reminders for the same place are kept unchanged.
    final first = existing.first.id;
    return [
      for (final reminder in data.reminders)
        reminder.id == first ? reminder.copyWith(text: text) : reminder,
    ];
  }

  static Set<String> _locationChanged(
    PlaceData before,
    PlaceData after,
    String placeId,
  ) {
    final old = before.places.where((p) => p.id == placeId).firstOrNull;
    final updated = after.places.where((p) => p.id == placeId).firstOrNull;
    if (old == null || updated == null) return const {};
    final moved =
        old.latitude != updated.latitude ||
        old.longitude != updated.longitude ||
        old.outerRadius != updated.outerRadius ||
        old.innerRadius != updated.innerRadius ||
        old.rearmRadius != updated.rearmRadius;
    return moved ? {placeId} : const {};
  }

  static Place _find(PlaceData data, String placeId) {
    for (final place in data.places) {
      if (place.id == placeId) return place;
    }
    throw _PlaceNotFound(placeId);
  }

  PlaceOperationResult _invalid(String reason) {
    lastError = reason;
    _record('INVALID $reason');
    _notify();
    return PlaceOperationResult(PlaceOperationOutcome.invalid, reason);
  }

  void _record(String message) {
    _log.add('${DateTime.now().toIso8601String()} $message');
    if (_log.length > 50) _log.removeAt(0);
  }

  void _notify() {
    if (_disposed) return;
    for (final listener in List<PlaceManagerListener>.of(_listeners)) {
      listener();
    }
  }

  static String _describe(Object error) {
    final text = '$error'.trim();
    return text.isEmpty ? error.runtimeType.toString() : text;
  }

  static final Random _random = Random.secure();

  static String _defaultId() {
    final suffix = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return 'place-${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }
}

final class _PlaceNotFound implements Exception {
  const _PlaceNotFound(this.id);
  final String id;
}

/// Reminder text shown and registered for a place: all of its reminders in
/// saved order.
String reminderTextFor(PlaceData data, String placeId) => data.reminders
    .where((reminder) => reminder.placeId == placeId)
    .map((reminder) => reminder.text.trim())
    .where((text) => text.isNotEmpty)
    .join(' • ');

/// The Android registration set for a place document: every enabled place.
List<GeofencePlaceRegistration> registrationsFor(PlaceData data) => [
  for (final place in data.places.where((place) => place.enabled))
    GeofencePlaceRegistration(
      placeId: place.id,
      latitude: place.latitude,
      longitude: place.longitude,
      radius: place.outerRadius,
      innerRadius: place.innerRadius,
      rearmRadius: place.rearmRadius,
      cooldownSeconds: place.cooldown.inSeconds,
      approachTimeoutSeconds: place.approachTimeout.inSeconds,
      maxAcceptedAccuracy: place.maxAcceptedAccuracy,
      reminderText: reminderTextFor(data, place.id),
    ),
];

bool _sameRegistrations(
  List<GeofencePlaceRegistration> left,
  List<GeofencePlaceRegistration> right,
) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    final a = left[i];
    final b = right[i];
    if (a.placeId != b.placeId ||
        a.latitude != b.latitude ||
        a.longitude != b.longitude ||
        a.radius != b.radius ||
        a.innerRadius != b.innerRadius ||
        a.rearmRadius != b.rearmRadius ||
        a.cooldownSeconds != b.cooldownSeconds ||
        a.approachTimeoutSeconds != b.approachTimeoutSeconds ||
        a.maxAcceptedAccuracy != b.maxAcceptedAccuracy ||
        a.reminderText != b.reminderText) {
      return false;
    }
  }
  return true;
}
