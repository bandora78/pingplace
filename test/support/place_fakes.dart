import 'dart:async';

import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/persistence/place.dart';
import 'package:pingplace/src/persistence/place_repositories.dart';
import 'package:pingplace/src/places/place_manager.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

/// Records every complete registration set, like the native
/// MultiPlaceGeofenceRegistration, and models Android's applied state.
base class FakePlaceRegistrar implements PlaceRegistrar {
  final List<List<GeofencePlaceRegistration>> calls = [];
  List<GeofencePlaceRegistration> applied = const [];
  bool confirmed = true;

  /// Fail the next N registerPlaces calls with [failure].
  int failNext = 0;
  Object failure = StateError('GEOFENCE_MULTI_RECONCILE_FAILED');
  Object? statusError;

  List<String> get appliedIds => [for (final p in applied) p.placeId];
  List<String> get lastIds => [for (final p in calls.last) p.placeId];

  Completer<void>? _hold;

  /// Holds the next registerPlaces calls until the returned completer
  /// completes, to observe the UI while a save is in progress.
  Completer<void> holdNext() => _hold = Completer<void>();

  @override
  Future<void> registerPlaces(List<GeofencePlaceRegistration> places) async {
    calls.add(List.unmodifiable(places));
    final hold = _hold;
    if (hold != null) {
      await hold.future;
      _hold = null;
    }
    if (failNext > 0) {
      failNext--;
      // Like the native add-then-remove reconcile: a failed add leaves the
      // previous registrations active and clears the confirmation.
      confirmed = false;
      throw failure;
    }
    applied = List.unmodifiable(places);
    confirmed = true;
  }

  /// Android status reads (every PlaceManager reload makes one).
  int statusReads = 0;

  @override
  Future<PlaceRegistrationStatus> status() async {
    statusReads++;
    if (statusError != null) throw statusError!;
    final ids = appliedIds.toSet();
    return PlaceRegistrationStatus(
      confirmed: confirmed,
      appliedPlaceIds: ids,
      desiredPlaceIds: ids,
    );
  }
}

const sampleDraft = PlaceDraft(
  name: 'Home',
  latitude: 32.08,
  longitude: 34.78,
  radius: 300,
  reminderText: 'Take out the trash',
  enabled: true,
);

PlaceDraft draft({
  String name = 'Home',
  double latitude = 32.08,
  double longitude = 34.78,
  double radius = 300,
  String reminderText = 'Take out the trash',
  bool enabled = true,
}) => PlaceDraft(
  name: name,
  latitude: latitude,
  longitude: longitude,
  radius: radius,
  reminderText: reminderText,
  enabled: enabled,
);

final class PlaceTestRig {
  PlaceTestRig({InMemoryPlaceDataStore? store, FakePlaceRegistrar? registrar})
    : store = store ?? InMemoryPlaceDataStore(),
      registrar = registrar ?? FakePlaceRegistrar();

  final InMemoryPlaceDataStore store;
  final FakePlaceRegistrar registrar;
  final InMemoryArrivalRuntimeStore runtime = InMemoryArrivalRuntimeStore();
  int _ids = 0;

  /// A fresh manager over the same storage, as after an app restart.
  PlaceManager manager() => PlaceManager(
    database: PlaceDatabase(store),
    registrar: registrar,
    runtimeStore: runtime,
    idGenerator: () => 'place-${++_ids}',
  );

  PlaceData get stored => store.data ?? const PlaceData();
}
