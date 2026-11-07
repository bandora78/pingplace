import '../geofence/geofence_service.dart';
import '../runtime/arrival_runtime_store.dart';
import 'place.dart';
import 'place_repositories.dart';

final class LegacySingleTarget {
  const LegacySingleTarget({
    required this.latitude,
    required this.longitude,
    required this.radius,
    required this.reminderText,
    required this.monitoringEnabled,
    this.innerRadius,
    this.rearmRadius,
    this.cooldown,
    this.approachTimeout,
    this.maxAcceptedAccuracy,
  });

  final double latitude;
  final double longitude;
  final double radius;
  final String reminderText;
  final bool monitoringEnabled;
  // These are optional because Build 11 did not persist all of them. A source
  // that has them must provide them; migration never overwrites them.
  final double? innerRadius;
  final double? rearmRadius;
  final Duration? cooldown;
  final Duration? approachTimeout;
  final double? maxAcceptedAccuracy;
}

abstract interface class LegacySingleTargetSource {
  Future<LegacySingleTarget?> read();
}

final class LegacySingleTargetReader implements LegacySingleTargetSource {
  const LegacySingleTargetReader({
    required this.runtimeStore,
    required this.geofenceService,
  });

  final ArrivalRuntimeStore runtimeStore;
  final GeofenceService geofenceService;

  @override
  Future<LegacySingleTarget?> read() async {
    final snapshot = await runtimeStore.load();
    final desired = await geofenceService.desiredRegistration;
    final target = snapshot?.target;
    if (target == null && desired == null) return null;

    if (target != null &&
        desired != null &&
        (_different(target.latitude, desired.latitude) ||
            _different(target.longitude, desired.longitude))) {
      throw const FormatException(
        'Legacy runtime and Android desired targets conflict',
      );
    }

    // Android desired registration is the source of truth for the target that
    // the platform intends to monitor. The Dart runtime target is used only
    // when Android has no desired record.
    final latitude = desired?.latitude ?? target!.latitude;
    final longitude = desired?.longitude ?? target!.longitude;
    final radius = desired?.radius ?? _historicalOuterRadius;
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        !radius.isFinite ||
        radius <= 0) {
      throw const FormatException('Legacy target data is invalid');
    }
    return LegacySingleTarget(
      latitude: latitude,
      longitude: longitude,
      radius: radius,
      reminderText: await runtimeStore.loadReminderText(),
      monitoringEnabled: await geofenceService.desiredMonitoring,
    );
  }

  static const _historicalOuterRadius = 300.0;
  static bool _different(double left, double right) =>
      (left - right).abs() > 0.000001;
}

final class PlaceMigration {
  PlaceMigration({required this._database, required this._source});

  static const legacyPlaceId = 'legacy-place-1';
  static const legacyReminderId = 'legacy-reminder-1';
  final PlaceDatabase _database;
  final LegacySingleTargetSource _source;

  Future<bool> migrateIfNeeded() => _database.transact<bool>((existing) async {
    if (existing.places.isNotEmpty) {
      return PlaceDatabaseChange(data: existing, result: false, persist: false);
    }

    final legacy = await _source.read();
    if (legacy == null) {
      return PlaceDatabaseChange(data: existing, result: false, persist: false);
    }

    final place = Place(
      id: legacyPlaceId,
      name: 'מקום קיים',
      latitude: legacy.latitude,
      longitude: legacy.longitude,
      enabled: legacy.monitoringEnabled,
      outerRadius: legacy.radius,
      innerRadius: legacy.innerRadius ?? 80,
      rearmRadius: legacy.rearmRadius ?? 350,
      cooldown: legacy.cooldown ?? const Duration(minutes: 10),
      approachTimeout: legacy.approachTimeout ?? const Duration(minutes: 10),
      maxAcceptedAccuracy: legacy.maxAcceptedAccuracy ?? 50,
    );
    final reminder = Reminder(
      id: legacyReminderId,
      placeId: place.id,
      text: legacy.reminderText,
    );
    return PlaceDatabaseChange(
      data: PlaceData(places: [place], reminders: [reminder]),
      result: true,
    );
  });
}

/// Outcome of the one-time APP-10 legacy sync.
final class LegacyPlaceSyncResult {
  const LegacyPlaceSyncResult({required this.changed, required this.detail});
  final bool changed;
  final String detail;
}

/// One-time reconciliation of the migrated place with Build 12-15 edits.
///
/// Builds 12-15 migrated the single legacy target into the place list once
/// (`legacy-place-1`), but their home screen kept editing only the legacy
/// target. The legacy target is therefore the user's most recent choice for
/// that place. Before the place list becomes the only editable source, copy
/// the legacy coordinates, radius, monitoring choice and reminder text onto
/// `legacy-place-1`.
///
/// Runs at most once: completion is recorded in the place document, so later
/// edits made in the place list are never overwritten. Nothing is deleted. If
/// the legacy data cannot be read or is invalid, the stored place is kept
/// unchanged and the reason is reported.
final class LegacyPlaceSync {
  LegacyPlaceSync({required this._database, required this._source});

  final PlaceDatabase _database;
  final LegacySingleTargetSource _source;

  Future<LegacyPlaceSyncResult>
  syncIfNeeded() => _database.transact<LegacyPlaceSyncResult>((data) async {
    if (data.legacySyncCompleted) {
      return PlaceDatabaseChange(
        data: data,
        result: const LegacyPlaceSyncResult(
          changed: false,
          detail: 'ALREADY_COMPLETED',
        ),
        persist: false,
      );
    }
    PlaceDatabaseChange<LegacyPlaceSyncResult> complete(
      PlaceData updated,
      bool changed,
      String detail,
    ) => PlaceDatabaseChange(
      data: updated.copyWith(legacySyncCompleted: true),
      result: LegacyPlaceSyncResult(changed: changed, detail: detail),
    );

    final index = data.places.indexWhere(
      (place) => place.id == PlaceMigration.legacyPlaceId,
    );
    if (index < 0) return complete(data, false, 'NO_MIGRATED_PLACE');

    LegacySingleTarget? legacy;
    try {
      legacy = await _source.read();
    } catch (error) {
      return complete(data, false, 'LEGACY_UNREADABLE_KEPT_PLACE: $error');
    }
    if (legacy == null) return complete(data, false, 'NO_LEGACY_TARGET');

    final current = data.places[index];
    final radius = legacy.radius;
    final candidate = current.copyWith(
      latitude: legacy.latitude,
      longitude: legacy.longitude,
      outerRadius: radius,
      innerRadius: current.innerRadius > radius ? radius : current.innerRadius,
      rearmRadius: current.rearmRadius < radius
          ? radius + 50
          : current.rearmRadius,
      enabled: legacy.monitoringEnabled,
    );
    try {
      candidate.validate();
    } on FormatException catch (error) {
      return complete(
        data,
        false,
        'LEGACY_INVALID_KEPT_PLACE: ${error.message}',
      );
    }

    final text = legacy.reminderText.trim();
    var reminders = data.reminders;
    var reminderChanged = false;
    if (text.isNotEmpty) {
      final existing = reminders.indexWhere(
        (reminder) => reminder.id == PlaceMigration.legacyReminderId,
      );
      if (existing >= 0) {
        if (reminders[existing].text != legacy.reminderText) {
          reminders = [
            for (final reminder in reminders)
              reminder.id == PlaceMigration.legacyReminderId
                  ? reminder.copyWith(text: legacy.reminderText)
                  : reminder,
          ];
          reminderChanged = true;
        }
      } else if (!reminders.any((r) => r.placeId == current.id)) {
        reminders = [
          ...reminders,
          Reminder(
            id: PlaceMigration.legacyReminderId,
            placeId: current.id,
            text: legacy.reminderText,
          ),
        ];
        reminderChanged = true;
      }
    }

    final placeChanged =
        candidate.latitude != current.latitude ||
        candidate.longitude != current.longitude ||
        candidate.outerRadius != current.outerRadius ||
        candidate.innerRadius != current.innerRadius ||
        candidate.rearmRadius != current.rearmRadius ||
        candidate.enabled != current.enabled;
    if (!placeChanged && !reminderChanged) {
      return complete(data, false, 'ALREADY_IN_SYNC');
    }
    return complete(
      data.copyWith(
        places: [
          for (final place in data.places)
            place.id == current.id ? candidate : place,
        ],
        reminders: reminders,
      ),
      true,
      'ADOPTED_LEGACY_EDITS '
      'from=(${current.latitude},${current.longitude},${current.outerRadius},enabled=${current.enabled}) '
      'to=(${candidate.latitude},${candidate.longitude},${candidate.outerRadius},enabled=${candidate.enabled}) '
      'reminderChanged=$reminderChanged',
    );
  });
}
