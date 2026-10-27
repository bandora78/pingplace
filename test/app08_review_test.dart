import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/geofence/development_geofence_controller.dart';
import 'package:pingplace/src/persistence/legacy_place_migration.dart';
import 'package:pingplace/src/persistence/place.dart';
import 'package:pingplace/src/persistence/place_repositories.dart';
import 'package:pingplace/src/simulation/development_simulation_screen.dart';

final class _Source implements LegacySingleTargetSource {
  _Source(this.value);
  final LegacySingleTarget? value;
  int reads = 0;

  @override
  Future<LegacySingleTarget?> read() async {
    reads++;
    return value;
  }
}

void main() {
  test('migration no-op paths do not write persistent storage', () async {
    final emptyStore = InMemoryPlaceDataStore();
    final emptyMigration = PlaceMigration(
      database: PlaceDatabase(emptyStore),
      source: _Source(null),
    );

    expect(await emptyMigration.migrateIfNeeded(), isFalse);
    expect(emptyStore.writes, 0);

    final existingStore = InMemoryPlaceDataStore();
    final existingDatabase = PlaceDatabase(existingStore);
    await existingDatabase.replace(
      const PlaceData(
        places: [
          Place(
            id: 'existing',
            name: 'Existing',
            latitude: 32,
            longitude: 34.8,
            enabled: true,
          ),
        ],
      ),
    );
    final writesBeforeNoOp = existingStore.writes;
    final existingMigration = PlaceMigration(
      database: existingDatabase,
      source: _Source(
        const LegacySingleTarget(
          latitude: 32,
          longitude: 34.8,
          radius: 300,
          reminderText: 'legacy',
          monitoringEnabled: true,
        ),
      ),
    );

    expect(await existingMigration.migrateIfNeeded(), isFalse);
    expect(existingStore.writes, writesBeforeNoOp);
  });

  testWidgets('migration failures are shown in Developer Mode diagnostics', (
    tester,
  ) async {
    final controller = DevelopmentGeofenceController()
      ..setPersistenceInitializationFailure(
        'Place persistence initialization failed: conflict',
      );

    await tester.pumpWidget(
      MaterialApp(home: DevelopmentSimulationScreen(realGeofence: controller)),
    );

    expect(
      find.textContaining('Persistence initialization failure'),
      findsOneWidget,
    );
    expect(find.textContaining('conflict'), findsOneWidget);
    controller.dispose();
  });
}
