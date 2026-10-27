import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/persistence/legacy_place_migration.dart';
import 'package:pingplace/src/persistence/place.dart';
import 'package:pingplace/src/persistence/place_repositories.dart';

final class FakeLegacySource implements LegacySingleTargetSource {
  FakeLegacySource(this.value);
  LegacySingleTarget? value;
  int reads = 0;

  @override
  Future<LegacySingleTarget?> read() async {
    reads++;
    return value;
  }
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

  test('migration preserves the legacy target and is idempotent', () async {
    final store = InMemoryPlaceDataStore();
    final database = PlaceDatabase(store);
    final source = FakeLegacySource(
      const LegacySingleTarget(
        latitude: 31.7,
        longitude: 34.9,
        radius: 275,
        reminderText: 'תזכורת',
        monitoringEnabled: true,
      ),
    );
    final migration = PlaceMigration(database: database, source: source);

    expect(await migration.migrateIfNeeded(), isTrue);
    expect(await migration.migrateIfNeeded(), isFalse);
    expect(source.reads, 1);
    expect((await PlaceRepository(database).list()).single.latitude, 31.7);
    expect((await ReminderRepository(database).list()).single.text, 'תזכורת');
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

  test('migration does not mutate the platform', () async {
    final store = InMemoryPlaceDataStore();
    var sourceReads = 0;
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
    expect(await migration.migrateIfNeeded(), isTrue);
    sourceReads++;
    expect(sourceReads, 1);
  });

  test('partial migration failure leaves the new store empty', () async {
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
}
