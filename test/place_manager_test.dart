import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/persistence/place.dart';
import 'package:pingplace/src/persistence/place_repositories.dart';
import 'package:pingplace/src/places/place_manager.dart';

import 'support/place_fakes.dart';

DetectionRuntimeSnapshot _cooldownSnapshot(double latitude, double longitude) =>
    DetectionRuntimeSnapshot(
      state: DetectionState.cooldown,
      target: TargetLocation(latitude: latitude, longitude: longitude),
      cooldownUntil: DateTime.utc(2030),
      visitId: 'visit-1',
    );

void main() {
  group('creation and persistence', () {
    test('adds multiple places without replacing existing ones', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();

      expect((await manager.add(draft(name: 'Home'))).succeeded, isTrue);
      expect(
        (await manager.add(
          draft(name: 'Office', latitude: 32.1, longitude: 34.9),
        )).succeeded,
        isTrue,
      );
      expect(
        (await manager.add(draft(name: 'Gym', latitude: 31.9, longitude: 34.7)))
            .succeeded,
        isTrue,
      );

      expect(manager.places.map((p) => p.place.name), [
        'Home',
        'Office',
        'Gym',
      ]);
      expect(rig.stored.places, hasLength(3));
      expect(rig.stored.reminders, hasLength(3));
      // Each place has its own reminder.
      expect(rig.stored.reminders.map((r) => r.placeId).toSet(), {
        'place-1',
        'place-2',
        'place-3',
      });
    });

    test('places, reminders and radii survive an app restart', () async {
      final rig = PlaceTestRig();
      final first = rig.manager();
      await first.initialize();
      await first.add(
        draft(name: 'Home', radius: 450, reminderText: 'Water plants'),
      );
      await first.add(draft(name: 'Office', enabled: false));
      first.dispose();

      final restarted = rig.manager();
      await restarted.initialize();

      expect(restarted.places, hasLength(2));
      final home = restarted.places.first;
      expect(home.place.name, 'Home');
      expect(home.place.outerRadius, 450);
      expect(home.place.rearmRadius, greaterThanOrEqualTo(450));
      expect(home.reminderText, 'Water plants');
      expect(restarted.places.last.place.enabled, isFalse);
    });

    test('invalid drafts are rejected before anything is written', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      final writesBefore = rig.store.writes;
      final callsBefore = rig.registrar.calls.length;

      for (final (bad, code) in [
        (draft(name: '  '), 'PLACE_NAME_REQUIRED'),
        (draft(reminderText: ''), 'REMINDER_TEXT_REQUIRED'),
        (draft(latitude: 91), 'LATITUDE_OUT_OF_RANGE'),
        (draft(longitude: -181), 'LONGITUDE_OUT_OF_RANGE'),
        (draft(radius: 10), 'RADIUS_OUT_OF_RANGE'),
        (draft(radius: double.nan), 'RADIUS_OUT_OF_RANGE'),
      ]) {
        final result = await manager.add(bad);
        expect(result.outcome, PlaceOperationOutcome.invalid);
        expect(result.detail, code);
      }
      expect(rig.store.writes, writesBefore);
      expect(rig.registrar.calls.length, callsBefore);
      expect(rig.stored.places, isEmpty);
    });
  });

  group('editing', () {
    test('editing one place leaves every other place unchanged', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(draft(name: 'Home'));
      await manager.add(
        draft(
          name: 'Office',
          latitude: 32.1,
          longitude: 34.9,
          reminderText: 'Badge',
        ),
      );
      final officeBefore = rig.stored.places.last;
      final officeReminderBefore = rig.stored.reminders.last;

      final result = await manager.update(
        'place-1',
        draft(
          name: 'Home 2',
          latitude: 32.2,
          longitude: 34.8,
          radius: 500,
          reminderText: 'Keys',
        ),
      );

      expect(result.succeeded, isTrue);
      final home = rig.stored.places.first;
      expect(home.name, 'Home 2');
      expect(
        (home.latitude, home.longitude, home.outerRadius),
        (32.2, 34.8, 500.0),
      );
      expect(rig.stored.reminders.first.text, 'Keys');
      final officeAfter = rig.stored.places.last;
      expect(officeAfter.toJson(), officeBefore.toJson());
      expect(rig.stored.reminders.last.toJson(), officeReminderBefore.toJson());
    });

    test('editing a location resets only that place runtime state', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(draft(name: 'Home'));
      await manager.add(draft(name: 'Office', latitude: 32.1, longitude: 34.9));
      rig.runtime.placeSnapshots['place-1'] = _cooldownSnapshot(32.08, 34.78);
      rig.runtime.placeSnapshots['place-2'] = _cooldownSnapshot(32.1, 34.9);

      await manager.update('place-1', draft(name: 'Home', latitude: 32.3));

      expect(rig.runtime.placeSnapshots.containsKey('place-1'), isFalse);
      expect(
        rig.runtime.placeSnapshots['place-2']?.state,
        DetectionState.cooldown,
      );
    });

    test('renaming or changing reminder text keeps the cooldown', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(draft(name: 'Home'));
      rig.runtime.placeSnapshots['place-1'] = _cooldownSnapshot(32.08, 34.78);

      await manager.update(
        'place-1',
        draft(name: 'House', reminderText: 'New text'),
      );

      expect(
        rig.runtime.placeSnapshots['place-1']?.state,
        DetectionState.cooldown,
      );
      // The new reminder text still reaches Android.
      expect(rig.registrar.calls.last.single.reminderText, 'New text');
    });

    test(
      'editing a missing place reports notFound and writes nothing',
      () async {
        final rig = PlaceTestRig();
        final manager = rig.manager();
        await manager.initialize();
        final writes = rig.store.writes;

        final result = await manager.update('nope', sampleDraft);

        expect(result.outcome, PlaceOperationOutcome.notFound);
        expect(rig.store.writes, writes);
      },
    );
  });

  group('independent enable and disable', () {
    test(
      'only enabled places are registered, each toggled independently',
      () async {
        final rig = PlaceTestRig();
        final manager = rig.manager();
        await manager.initialize();
        await manager.add(draft(name: 'A'));
        await manager.add(draft(name: 'B', latitude: 32.1));
        await manager.add(draft(name: 'C', latitude: 32.2));
        expect(rig.registrar.appliedIds, ['place-1', 'place-2', 'place-3']);

        await manager.setEnabled('place-2', false);
        expect(rig.registrar.appliedIds, ['place-1', 'place-3']);
        expect(rig.stored.places.map((p) => p.enabled), [true, false, true]);
        expect(manager.places.map((p) => p.registration), [
          PlaceRegistrationState.registered,
          PlaceRegistrationState.disabled,
          PlaceRegistrationState.registered,
        ]);

        await manager.setEnabled('place-1', false);
        expect(rig.registrar.appliedIds, ['place-3']);

        await manager.setEnabled('place-2', true);
        expect(rig.registrar.appliedIds, ['place-2', 'place-3']);
        expect(rig.stored.places.map((p) => p.enabled), [false, true, true]);
      },
    );

    test('adding or editing a disabled place does not call Android', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      final calls = rig.registrar.calls.length;

      await manager.add(draft(name: 'Later', enabled: false));
      await manager.update('place-1', draft(name: 'Later 2', enabled: false));

      expect(rig.registrar.calls.length, calls);
      expect(
        manager.places.single.registration,
        PlaceRegistrationState.disabled,
      );
    });
  });

  group('deletion', () {
    test(
      'deleting removes the place, its reminders, its geofence and its state',
      () async {
        final rig = PlaceTestRig();
        final manager = rig.manager();
        await manager.initialize();
        await manager.add(draft(name: 'Home'));
        await manager.add(draft(name: 'Office', latitude: 32.1));
        rig.runtime.placeSnapshots['place-1'] = _cooldownSnapshot(32.08, 34.78);
        rig.runtime.placeSnapshots['place-2'] = _cooldownSnapshot(32.1, 34.78);

        final result = await manager.delete('place-1');

        expect(result.succeeded, isTrue);
        expect(rig.stored.places.map((p) => p.id), ['place-2']);
        expect(rig.stored.reminders.map((r) => r.placeId), ['place-2']);
        expect(rig.registrar.appliedIds, ['place-2']);
        expect(rig.runtime.placeSnapshots.keys, ['place-2']);
      },
    );

    test('deleting the last place unregisters everything', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(sampleDraft);

      await manager.delete('place-1');

      expect(rig.registrar.calls.last, isEmpty);
      expect(manager.places, isEmpty);
    });
  });

  group('simultaneous registration and recovery', () {
    test(
      'every enabled place is registered together with its own settings',
      () async {
        final rig = PlaceTestRig();
        final manager = rig.manager();
        await manager.initialize();
        await manager.add(
          draft(name: 'A', latitude: 32.0, radius: 200, reminderText: 'a'),
        );
        await manager.add(
          draft(name: 'B', latitude: 32.5, radius: 800, reminderText: 'b'),
        );

        final set = rig.registrar.calls.last;
        expect(set.map((p) => p.placeId), ['place-1', 'place-2']);
        expect(set.map((p) => p.latitude), [32.0, 32.5]);
        expect(set.map((p) => p.radius), [200.0, 800.0]);
        expect(set.map((p) => p.reminderText), ['a', 'b']);
        expect(set.map((p) => p.cooldownSeconds), [600, 600]);
      },
    );

    test('startup re-registers the stored set, as after a reboot', () async {
      final rig = PlaceTestRig();
      final first = rig.manager();
      await first.initialize();
      await first.add(draft(name: 'A'));
      await first.add(draft(name: 'B', latitude: 32.5));
      await first.setEnabled('place-1', false);
      first.dispose();
      // Android drops geofences on reboot.
      rig.registrar.applied = const [];

      final restarted = rig.manager();
      await restarted.initialize();

      expect(rig.registrar.lastIds, ['place-2']);
      expect(restarted.places.map((p) => p.registration), [
        PlaceRegistrationState.disabled,
        PlaceRegistrationState.registered,
      ]);
    });

    test('failed startup registration is visible and retry succeeds', () async {
      final rig = PlaceTestRig();
      final first = rig.manager();
      await first.initialize();
      await first.add(sampleDraft);
      first.dispose();
      rig.registrar
        ..failNext = 1
        ..failure = StateError('PERMISSION_MISSING');

      final restarted = rig.manager();
      await restarted.initialize();
      expect(restarted.lastError, contains('PERMISSION_MISSING'));
      expect(
        restarted.places.single.registration,
        PlaceRegistrationState.pending,
      );
      // Stored places are never removed because registration failed.
      expect(rig.stored.places, hasLength(1));

      final retry = await restarted.retryRegistration();
      expect(retry.succeeded, isTrue);
      expect(restarted.lastError, isNull);
      expect(
        restarted.places.single.registration,
        PlaceRegistrationState.registered,
      );
    });

    test(
      'unreadable registration status is UNKNOWN, never registered',
      () async {
        final rig = PlaceTestRig();
        final manager = rig.manager();
        await manager.initialize();
        rig.registrar.statusError = StateError('channel down');

        await manager.add(sampleDraft);

        expect(manager.registrationStatusKnown, isFalse);
        expect(
          manager.places.single.registration,
          PlaceRegistrationState.unknown,
        );
      },
    );

    test(
      'unconfirmed Android registration is pending, never registered',
      () async {
        final rig = PlaceTestRig();
        final manager = rig.manager();
        await manager.initialize();
        await manager.add(sampleDraft);
        rig.registrar.confirmed = false;

        await manager.refresh();

        expect(
          manager.places.single.registration,
          PlaceRegistrationState.pending,
        );
      },
    );
  });

  group('failure and rollback', () {
    test(
      'Android rejection restores the previous places and registration',
      () async {
        final rig = PlaceTestRig();
        final manager = rig.manager();
        await manager.initialize();
        await manager.add(draft(name: 'Home'));
        final before = rig.stored.toJson();
        rig.registrar.failNext = 1;

        final result = await manager.add(draft(name: 'Office', latitude: 32.1));

        expect(result.outcome, PlaceOperationOutcome.rolledBack);
        expect(rig.stored.toJson(), before);
        expect(rig.registrar.appliedIds, ['place-1']);
        expect(manager.places.map((p) => p.place.name), ['Home']);
        expect(manager.lastError, contains('REGISTRATION_FAILED'));
      },
    );

    test('rejected disable keeps the place enabled and registered', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(draft(name: 'A'));
      await manager.add(draft(name: 'B', latitude: 32.1));
      rig.registrar.failNext = 1;

      final result = await manager.setEnabled('place-1', false);

      expect(result.outcome, PlaceOperationOutcome.rolledBack);
      expect(rig.stored.places.first.enabled, isTrue);
      expect(rig.registrar.appliedIds, ['place-1', 'place-2']);
    });

    test(
      'rejected edit keeps the old location and the old runtime state',
      () async {
        final rig = PlaceTestRig();
        final manager = rig.manager();
        await manager.initialize();
        await manager.add(sampleDraft);
        rig.runtime.placeSnapshots['place-1'] = _cooldownSnapshot(32.08, 34.78);
        rig.registrar.failNext = 1;

        final result = await manager.update('place-1', draft(latitude: 33));

        expect(result.outcome, PlaceOperationOutcome.rolledBack);
        expect(rig.stored.places.single.latitude, 32.08);
        expect(
          rig.runtime.placeSnapshots['place-1']?.state,
          DetectionState.cooldown,
        );
      },
    );

    test('failed rollback is reported as such, not as success', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(sampleDraft);
      rig.registrar.failNext = 2;

      final result = await manager.add(draft(name: 'Office', latitude: 32.1));

      expect(result.outcome, PlaceOperationOutcome.rollbackFailed);
      expect(result.detail, contains('ROLLBACK_FAILED'));
      // The stored document is still restored to the previous places.
      expect(rig.stored.places.map((p) => p.id), ['place-1']);
      expect(
        manager.places.single.registration,
        PlaceRegistrationState.pending,
      );
    });

    test('a storage failure changes nothing and never calls Android', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(sampleDraft);
      final calls = rig.registrar.calls.length;
      rig.store.failWrites = true;

      final result = await manager.add(draft(name: 'Office', latitude: 32.1));

      expect(result.outcome, PlaceOperationOutcome.persistFailed);
      expect(rig.registrar.calls.length, calls);
      expect(rig.stored.places, hasLength(1));
    });

    test('concurrent operations are serialized in order', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();

      final results = await Future.wait([
        manager.add(draft(name: 'A')),
        manager.add(draft(name: 'B', latitude: 32.1)),
        manager.setEnabled('place-1', false),
        manager.delete('place-2'),
      ]);

      expect(
        results.map((r) => r.outcome),
        everyElement(PlaceOperationOutcome.saved),
      );
      expect(rig.stored.places.map((p) => (p.id, p.enabled)), [
        ('place-1', false),
      ]);
      expect(rig.registrar.calls.last, isEmpty);
      expect(manager.busy, isFalse);
    });

    test('listeners are notified and disposal stops notifications', () async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      var notifications = 0;
      manager.addListener(() => notifications++);
      await manager.initialize();
      expect(notifications, greaterThan(0));

      manager.dispose();
      final before = notifications;
      await manager.add(sampleDraft);
      expect(notifications, before);
    });
  });

  test('stored documents keep the legacy sync marker through edits', () async {
    final rig = PlaceTestRig(
      store: InMemoryPlaceDataStore()
        ..data = const PlaceData(legacySyncCompleted: true),
    );
    final manager = rig.manager();
    await manager.initialize();

    await manager.add(sampleDraft);
    await manager.update('place-1', draft(name: 'Renamed'));
    await manager.delete('place-1');

    expect(rig.stored.legacySyncCompleted, isTrue);
  });

  test('registration payload is derived only from enabled places', () {
    const data = PlaceData(
      places: [
        Place(id: 'a', name: 'A', latitude: 1, longitude: 1, enabled: true),
        Place(id: 'b', name: 'B', latitude: 2, longitude: 2, enabled: false),
      ],
      reminders: [
        Reminder(id: 'r1', placeId: 'a', text: 'one'),
        Reminder(id: 'r2', placeId: 'a', text: 'two'),
        Reminder(id: 'r3', placeId: 'b', text: 'hidden'),
      ],
    );
    final set = registrationsFor(data);
    expect(set.map((p) => p.placeId), ['a']);
    expect(set.single.reminderText, 'one • two');
  });

  test(
    'a slow registration blocks the next operation until it completes',
    () async {
      final rig = PlaceTestRig(registrar: _GatedRegistrar());
      final registrar = rig.registrar as _GatedRegistrar;
      final manager = rig.manager();
      await manager.initialize();

      final gate = registrar.gate = Completer<void>();
      final first = manager.add(draft(name: 'A'));
      final second = manager.add(draft(name: 'B', latitude: 32.1));
      await Future<void>.delayed(Duration.zero);
      expect(manager.busy, isTrue);
      expect(rig.stored.places.map((p) => p.id), ['place-1']);

      gate.complete();
      await Future.wait([first, second]);
      expect(rig.stored.places.map((p) => p.id), ['place-1', 'place-2']);
      expect(registrar.lastIds, ['place-1', 'place-2']);
    },
  );
}

final class _GatedRegistrar extends FakePlaceRegistrar {
  Completer<void>? gate;

  @override
  Future<void> registerPlaces(places) async {
    final pending = gate;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
    await super.registerPlaces(places);
  }
}
