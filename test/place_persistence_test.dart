import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/persistence/legacy_place_migration.dart';
import 'package:pingplace/src/persistence/place.dart';
import 'package:pingplace/src/persistence/place_persistence.dart';
import 'package:pingplace/src/persistence/place_repositories.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

final class FakeLegacySource implements LegacySingleTargetSource {
  FakeLegacySource(this.value);
  LegacySingleTarget? value;
  int reads = 0;
  Completer<void>? beforeRead;

  @override
  Future<LegacySingleTarget?> read() async {
    reads++;
    await beforeRead?.future;
    return value;
  }
}

final class FakeGeofenceService implements GeofenceService {
  FakeGeofenceService({this.desired, this.monitoring = true});

  GeofenceRegistration? desired;
  bool monitoring;
  int registerCalls = 0;
  int removeCalls = 0;

  @override
  Stream<GeofenceEvent> get events => const Stream.empty();

  @override
  Future<GeofencePermissionStatus> checkPermission() async =>
      GeofencePermissionStatus.backgroundAllowed;

  @override
  Future<GeofencePermissionStatus> requestPermission() async =>
      GeofencePermissionStatus.backgroundAllowed;

  @override
  Future<bool> get registrationStatus async => false;

  @override
  Future<GeofenceRegistration?> get registration async => null;

  @override
  Future<GeofenceRegistration?> get desiredRegistration async => desired;

  @override
  Future<bool> get desiredMonitoring async => monitoring;

  @override
  Future<GeofenceRecoveryStatus> get recoveryStatus async =>
      const GeofenceRecoveryStatus();

  @override
  Future<bool> restoreRegistration() async => false;

  @override
  Future<void> register({
    required double latitude,
    required double longitude,
    required double radius,
    String? reminderText,
  }) async {
    registerCalls++;
  }

  @override
  Future<void> remove() async {
    removeCalls++;
  }

  @override
  void dispose() {}
}

void main() {
  Place place(String id) =>
      Place(id: id, name: id, latitude: 32, longitude: 34.8, enabled: true);

  test('supports multiple places and reminders with CRUD', () async {
    final store = InMemoryPlaceDataStore();
    final database = PlaceDatabase(store);
    final places = PlaceRepository(database);
    final reminders = ReminderRepository(database);

    await places.create(place('one'));
    await places.create(place('two'));
    await reminders.create(
      const Reminder(id: 'r1', placeId: 'one', text: 'אחת'),
    );
    await reminders.create(
      const Reminder(id: 'r2', placeId: 'two', text: 'שתיים'),
    );
    await places.setEnabled('two', false);
    await reminders.update(
      const Reminder(id: 'r2', placeId: 'two', text: 'מעודכן'),
    );

    expect((await places.list()).map((item) => item.id), ['one', 'two']);
    expect((await reminders.list()).map((item) => item.text), [
      'אחת',
      'מעודכן',
    ]);
    expect((await places.get('two'))?.enabled, isFalse);

    await places.delete('one');
    expect(await places.get('one'), isNull);
    expect(await reminders.get('r1'), isNull);
    expect(await reminders.get('r2'), isNotNull);
  });

  test('data survives repository reinitialization', () async {
    final store = InMemoryPlaceDataStore();
    final first = PlaceRepository(PlaceDatabase(store));
    await first.create(place('persisted'));
    final second = PlaceRepository(PlaceDatabase(store));
    expect((await second.get('persisted'))?.latitude, 32);
  });

  test('write failures are surfaced and preserve the previous data', () async {
    final store = InMemoryPlaceDataStore();
    final places = PlaceRepository(PlaceDatabase(store));
    await places.create(place('old'));
    store.failWrites = true;

    expect(
      () => places.create(place('new')),
      throwsA(isA<PlacePersistenceException>()),
    );
    expect((await places.list()).single.id, 'old');
  });

  test('validation rejects malformed documents and dangling references', () {
    expect(
      () => PlaceData.fromJson({
        'schemaVersion': 1,
        'places': [
          {
            'id': 'p',
            'name': 'p',
            'latitude': 91,
            'longitude': 34,
            'enabled': true,
            'outerRadius': 300,
            'innerRadius': 80,
            'rearmRadius': 350,
            'cooldownSeconds': 600,
            'approachTimeoutSeconds': 600,
            'maxAcceptedAccuracy': 50,
          },
        ],
        'reminders': [],
      }),
      throwsFormatException,
    );
    expect(
      () => PlaceData.fromJson({
        'schemaVersion': 1,
        'places': [place('p').toJson(), place('p').toJson()],
        'reminders': [
          const Reminder(id: 'r', placeId: 'missing', text: 'x').toJson(),
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => PlaceData.fromJson({
        'schemaVersion': 1,
        'places': [
          {
            ...place('p').toJson(),
            'cooldownSeconds': 0,
          },
        ],
        'reminders': [],
      }),
      throwsFormatException,
    );
  });

  test('migration preserves complete legacy configuration and is idempotent',
      () async {
    final store = InMemoryPlaceDataStore();
    final database = PlaceDatabase(store);
    final source = FakeLegacySource(
      const LegacySingleTarget(
        latitude: 31.7,
        longitude: 34.9,
        radius: 275,
        reminderText: 'תזכורת',
        monitoringEnabled: true,
        innerRadius: 61,
        rearmRadius: 390,
        cooldown: Duration(minutes: 7),
        approachTimeout: Duration(minutes: 4),
        maxAcceptedAccuracy: 23,
      ),
    );
    final migration = PlaceMigration(database: database, source: source);

    expect(await migration.migrateIfNeeded(), isTrue);
    expect(await migration.migrateIfNeeded(), isFalse);
    expect(source.reads, 1);
    final migrated = (await PlaceRepository(database).list()).single;
    expect(migrated.innerRadius, 61);
    expect(migrated.rearmRadius, 390);
    expect(migrated.cooldown, const Duration(minutes: 7));
    expect(migrated.approachTimeout, const Duration(minutes: 4));
    expect(migrated.maxAcceptedAccuracy, 23);
    expect((await ReminderRepository(database).list()).single.text, 'תזכורת');
  });

  test('conflicting runtime and Android targets fail closed', () async {
    final runtime = InMemoryArrivalRuntimeStore()
      ..snapshot = const DetectionRuntimeSnapshot(
        state: DetectionState.armed,
        target: TargetLocation(latitude: 32, longitude: 34.8),
      );
    final platform = FakeGeofenceService(
      desired: const GeofenceRegistration(
        latitude: 32.1,
        longitude: 34.8,
        radius: 300,
      ),
    );
    final reader = LegacySingleTargetReader(
      runtimeStore: runtime,
      geofenceService: platform,
    );

    expect(() => reader.read(), throwsFormatException);
    expect(platform.registerCalls, 0);
    expect(platform.removeCalls, 0);
  });

  test('disabled desired monitoring is migrated disabled without platform calls',
      () async {
    final platform = FakeGeofenceService(
      desired: const GeofenceRegistration(
        latitude: 32,
        longitude: 34.8,
        radius: 300,
      ),
      monitoring: false,
    );
    final source = LegacySingleTargetReader(
      runtimeStore: InMemoryArrivalRuntimeStore(),
      geofenceService: platform,
    );
    final store = InMemoryPlaceDataStore();
    final migration = PlaceMigration(
      database: PlaceDatabase(store),
      source: source,
    );

    expect(await migration.migrateIfNeeded(), isTrue);
    expect((await PlaceRepository(PlaceDatabase(store)).list()).single.enabled,
        isFalse);
    expect(platform.registerCalls, 0);
    expect(platform.removeCalls, 0);
  });

  test('missing legacy data does not create default coordinates', () async {
    final store = InMemoryPlaceDataStore();
    final migration = PlaceMigration(
      database: PlaceDatabase(store),
      source: FakeLegacySource(null),
    );
    expect(await migration.migrateIfNeeded(), isFalse);
    expect((await PlaceRepository(PlaceDatabase(store)).list()), isEmpty);
  });

  test('migration and repository writes are serialized', () async {
    final store = InMemoryPlaceDataStore();
    final database = PlaceDatabase(store);
    final source = FakeLegacySource(
      const LegacySingleTarget(
        latitude: 32,
        longitude: 34.8,
        radius: 300,
        reminderText: 'קיים',
        monitoringEnabled: true,
      ),
    )..beforeRead = Completer<void>();
    final migration = PlaceMigration(database: database, source: source);
    final migrationFuture = migration.migrateIfNeeded();
    final createFuture = PlaceRepository(database).create(place('new'));
    await Future<void>.delayed(Duration.zero);
    expect(await database.read(), isA<PlaceData>());
    source.beforeRead!.complete();
    expect(await migrationFuture, isTrue);
    await createFuture;

    expect((await PlaceRepository(database).list()).map((item) => item.id),
        containsAll(<String>['legacy-place-1', 'new']));
  });

  test('failed migration write leaves the new store empty', () async {
    final store = InMemoryPlaceDataStore()..failWrites = true;
    final migration = PlaceMigration(
      database: PlaceDatabase(store),
      source: FakeLegacySource(
        const LegacySingleTarget(
          latitude: 32,
          longitude: 34.8,
          radius: 300,
          reminderText: 'קיים',
          monitoringEnabled: false,
        ),
      ),
    );
    expect(
      () => migration.migrateIfNeeded(),
      throwsA(isA<PlacePersistenceException>()),
    );
    expect(await store.load(), isNull);
  });

  test('initialization exposes migration failures', () async {
    final store = InMemoryPlaceDataStore()..failWrites = true;
    final migration = PlaceMigration(
      database: PlaceDatabase(store),
      source: FakeLegacySource(
        const LegacySingleTarget(
          latitude: 32,
          longitude: 34.8,
          radius: 300,
          reminderText: 'קיים',
          monitoringEnabled: true,
        ),
      ),
    );
    final coordinator = PlacePersistenceCoordinator(
      database: PlaceDatabase(store),
      migration: migration,
    );

    expect(await coordinator.initialize(), isFalse);
    expect(coordinator.initializationFailure, contains('PlacePersistenceException'));
  });
}