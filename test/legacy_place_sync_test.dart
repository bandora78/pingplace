import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/persistence/legacy_place_migration.dart';
import 'package:pingplace/src/persistence/place.dart';
import 'package:pingplace/src/persistence/place_persistence.dart';
import 'package:pingplace/src/persistence/place_repositories.dart';
import 'package:pingplace/src/places/place_manager.dart';

import 'support/place_fakes.dart';

final class _LegacySource implements LegacySingleTargetSource {
  _LegacySource(this.value);
  LegacySingleTarget? value;
  Object? error;
  int reads = 0;

  @override
  Future<LegacySingleTarget?> read() async {
    reads++;
    if (error != null) throw error!;
    return value;
  }
}

LegacySingleTarget _legacy({
  double latitude = 32.0853,
  double longitude = 34.7818,
  double radius = 300,
  String reminderText = 'עצור בתחנת דלק יעד',
  bool enabled = true,
}) => LegacySingleTarget(
  latitude: latitude,
  longitude: longitude,
  radius: radius,
  reminderText: reminderText,
  monitoringEnabled: enabled,
);

/// Place document as Builds 12-15 left it: the target migrated once, never
/// updated afterwards by the home screen.
PlaceData _build15Document({bool enabled = true}) => PlaceData(
  places: [
    Place(
      id: PlaceMigration.legacyPlaceId,
      name: 'מקום קיים',
      latitude: 32.0001,
      longitude: 34.8001,
      enabled: enabled,
    ),
  ],
  reminders: const [
    Reminder(
      id: PlaceMigration.legacyReminderId,
      placeId: PlaceMigration.legacyPlaceId,
      text: 'old reminder',
    ),
  ],
);

void main() {
  test(
    'adopts the newer Build 15 legacy edits onto the migrated place',
    () async {
      final store = InMemoryPlaceDataStore()..data = _build15Document();
      final source = _LegacySource(
        _legacy(
          latitude: 32.0853,
          longitude: 34.7818,
          radius: 450,
          reminderText: 'Buy milk',
        ),
      );

      final result = await LegacyPlaceSync(
        database: PlaceDatabase(store),
        source: source,
      ).syncIfNeeded();

      expect(result.changed, isTrue);
      expect(result.detail, startsWith('ADOPTED_LEGACY_EDITS'));
      final place = store.data!.places.single;
      expect(place.id, PlaceMigration.legacyPlaceId);
      expect(place.name, 'מקום קיים');
      expect(
        (place.latitude, place.longitude, place.outerRadius),
        (32.0853, 34.7818, 450.0),
      );
      expect(place.rearmRadius, greaterThanOrEqualTo(450));
      expect(store.data!.reminders.single.text, 'Buy milk');
      expect(store.data!.legacySyncCompleted, isTrue);
    },
  );

  test('a disabled legacy target disables the migrated place', () async {
    final store = InMemoryPlaceDataStore()..data = _build15Document();
    await LegacyPlaceSync(
      database: PlaceDatabase(store),
      source: _LegacySource(_legacy(enabled: false)),
    ).syncIfNeeded();

    expect(store.data!.places.single.enabled, isFalse);
  });

  test(
    'identical data is left as is and only the marker is recorded',
    () async {
      final original = _build15Document();
      final store = InMemoryPlaceDataStore()..data = original;
      final result = await LegacyPlaceSync(
        database: PlaceDatabase(store),
        source: _LegacySource(
          _legacy(
            latitude: 32.0001,
            longitude: 34.8001,
            reminderText: 'old reminder',
          ),
        ),
      ).syncIfNeeded();

      expect(result.changed, isFalse);
      expect(result.detail, 'ALREADY_IN_SYNC');
      expect(
        store.data!.places.single.toJson(),
        original.places.single.toJson(),
      );
      expect(store.data!.legacySyncCompleted, isTrue);
    },
  );

  test('unreadable legacy data keeps the stored place unchanged', () async {
    final original = _build15Document();
    final store = InMemoryPlaceDataStore()..data = original;
    final source = _LegacySource(null)
      ..error = const FormatException(
        'Legacy runtime and Android desired targets conflict',
      );

    final result = await LegacyPlaceSync(
      database: PlaceDatabase(store),
      source: source,
    ).syncIfNeeded();

    expect(result.changed, isFalse);
    expect(result.detail, startsWith('LEGACY_UNREADABLE_KEPT_PLACE'));
    expect(store.data!.places.single.toJson(), original.places.single.toJson());
    expect(store.data!.reminders.single.text, 'old reminder');
  });

  test('invalid legacy values keep the stored place unchanged', () async {
    final original = _build15Document();
    final store = InMemoryPlaceDataStore()..data = original;
    final result = await LegacyPlaceSync(
      database: PlaceDatabase(store),
      source: _LegacySource(_legacy(radius: -5)),
    ).syncIfNeeded();

    expect(result.detail, startsWith('LEGACY_INVALID_KEPT_PLACE'));
    expect(store.data!.places.single.toJson(), original.places.single.toJson());
  });

  test('a blank legacy reminder never erases the stored reminder', () async {
    final store = InMemoryPlaceDataStore()..data = _build15Document();
    await LegacyPlaceSync(
      database: PlaceDatabase(store),
      source: _LegacySource(_legacy(reminderText: '   ')),
    ).syncIfNeeded();

    expect(store.data!.reminders.single.text, 'old reminder');
  });

  test(
    'runs once: later edits in the place list are never overwritten',
    () async {
      final store = InMemoryPlaceDataStore()..data = _build15Document();
      final source = _LegacySource(_legacy(latitude: 32.0853));
      final sync = LegacyPlaceSync(
        database: PlaceDatabase(store),
        source: source,
      );
      await sync.syncIfNeeded();

      // The user then edits the place in the APP-10 list.
      final rig = PlaceTestRig(store: store);
      final manager = rig.manager();
      await manager.initialize();
      await manager.update(
        PlaceMigration.legacyPlaceId,
        draft(
          name: 'Home',
          latitude: 31.5,
          longitude: 35.0,
          reminderText: 'new',
        ),
      );

      final again = await sync.syncIfNeeded();
      expect(again.detail, 'ALREADY_COMPLETED');
      expect(source.reads, 1);
      expect(store.data!.places.single.latitude, 31.5);
      expect(store.data!.reminders.single.text, 'new');
    },
  );

  test('places added later are never touched by the sync', () async {
    final document = _build15Document();
    final store = InMemoryPlaceDataStore()
      ..data = document.copyWith(
        places: [
          ...document.places,
          const Place(
            id: 'place-x',
            name: 'Office',
            latitude: 31,
            longitude: 35,
            enabled: true,
          ),
        ],
      );
    await LegacyPlaceSync(
      database: PlaceDatabase(store),
      source: _LegacySource(_legacy(latitude: 32.5)),
    ).syncIfNeeded();

    expect(store.data!.places.map((p) => p.id), [
      PlaceMigration.legacyPlaceId,
      'place-x',
    ]);
    expect(store.data!.places.last.latitude, 31);
  });

  test(
    'a fresh install without a migrated place only records the marker',
    () async {
      final store = InMemoryPlaceDataStore();
      final source = _LegacySource(_legacy());
      final result = await LegacyPlaceSync(
        database: PlaceDatabase(store),
        source: source,
      ).syncIfNeeded();

      expect(result.detail, 'NO_MIGRATED_PLACE');
      expect(source.reads, 0);
      expect(store.data!.places, isEmpty);
      expect(store.data!.legacySyncCompleted, isTrue);
    },
  );

  test(
    'marker survives JSON round trip and is optional for older documents',
    () {
      final json = _build15Document()
          .copyWith(legacySyncCompleted: true)
          .toJson();
      expect(json['schemaVersion'], 1);
      expect(PlaceData.fromJson(json).legacySyncCompleted, isTrue);

      final older = _build15Document().toJson();
      expect(older.containsKey('legacySyncCompleted'), isFalse);
      expect(PlaceData.fromJson(older).legacySyncCompleted, isFalse);

      expect(
        () => PlaceData.fromJson({...older, 'legacySyncCompleted': 'yes'}),
        throwsFormatException,
      );
    },
  );

  test(
    'Build 15 upgrade path: migrate, sync, then register the adopted place',
    () async {
      // Build 15 device: place document from the original migration, and newer
      // legacy edits made later on the old home screen.
      final store = InMemoryPlaceDataStore()..data = _build15Document();
      final database = PlaceDatabase(store);
      final source = _LegacySource(
        _legacy(
          latitude: 32.0853,
          longitude: 34.7818,
          reminderText: 'Buy milk',
        ),
      );
      final coordinator = PlacePersistenceCoordinator(
        database: database,
        migration: PlaceMigration(database: database, source: source),
        legacySync: LegacyPlaceSync(database: database, source: source),
        geofenceService: null,
      );
      final rig = PlaceTestRig(store: store);

      final init = await coordinator.initialize();
      expect(init.succeeded, isTrue);
      expect(init.migrationChanged, isFalse);
      expect(init.legacySync?.changed, isTrue);

      final manager = PlaceManager(
        database: database,
        registrar: rig.registrar,
        runtimeStore: rig.runtime,
      );
      await manager.initialize();

      final registered = rig.registrar.calls.last.single;
      expect(registered.placeId, PlaceMigration.legacyPlaceId);
      expect((registered.latitude, registered.longitude), (32.0853, 34.7818));
      expect(registered.reminderText, 'Buy milk');
      expect(
        manager.places.single.registration,
        PlaceRegistrationState.registered,
      );
    },
  );
}
