import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/places/coordinates.dart';
import 'package:pingplace/src/places/map_location_picker_screen.dart';
import 'package:pingplace/src/places/place_editor_screen.dart';
import 'package:pingplace/src/places/place_manager.dart';
import 'package:pingplace/src/places/places_section.dart';

import 'support/fake_map_surface.dart';
import 'support/place_fakes.dart';

/// APP-11: the map picker only fills the editor. Persistence and Android
/// registration happen through PlaceManager on Save, exactly as before.

final class _Harness {
  _Harness(this.rig, this.manager, this.surface, this.navigator);
  final PlaceTestRig rig;
  final PlaceManager manager;
  final FakeMapSurface surface;
  final GlobalKey<NavigatorState> navigator;

  /// registerPlaces calls made after setup.
  int baseline = 0;
  int get newRegistrations => rig.registrar.calls.length - baseline;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Future<void> Function(PlaceManager manager)? seed,
  PlaceTestRig? rig,
}) async {
  // A phone-sized portrait viewport, so the whole editor form fits.
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final testRig = rig ?? PlaceTestRig();
  final manager = testRig.manager();
  await manager.initialize();
  if (seed != null) await seed(manager);
  final surface = FakeMapSurface();
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: Scaffold(
        body: SingleChildScrollView(
          child: PlacesSection(manager: manager, mapSurface: surface),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(testRig, manager, surface, navigator)
    ..baseline = testRig.registrar.calls.length;
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.enterText(find.byKey(Key(key)), text);
}

String _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

String _shown(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

DetectionRuntimeSnapshot _cooldown(double latitude, double longitude) =>
    DetectionRuntimeSnapshot(
      state: DetectionState.cooldown,
      target: TargetLocation(latitude: latitude, longitude: longitude),
      cooldownUntil: DateTime.utc(2030),
      visitId: 'visit-1',
    );

Future<void> _twoPlaces(PlaceManager manager) async {
  await manager.add(
    draft(name: 'Delek', latitude: 31.732600, longitude: 34.757743),
  );
  await manager.add(
    draft(
      name: 'Sagula',
      latitude: 31.7401,
      longitude: 34.7712,
      radius: 450,
      reminderText: 'Bread',
    ),
  );
}

void main() {
  group('new place', () {
    testWidgets('opens on the default viewport with nothing selected', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      expect(find.text('בחר מיקום במפה'), findsOneWidget);
      await _tapKey(tester, 'place-open-map');

      expect(find.byType(MapLocationPickerScreen), findsOneWidget);
      final view = h.surface.view;
      expect(view.selected, isNull);
      expect(view.original, isNull);
      expect(view.center, point(31.5, 34.9));
      expect(view.zoom, 7);
      expect(view.radii.outer, 300);
      expect(view.radii.inner, 80);
      expect(find.byKey(const Key('map-no-selection')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('map-confirm')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('אזור הגישה (300 מ׳)'), findsOneWidget);
      expect(find.textContaining('סף ההגעה (80 מ׳)'), findsOneWidget);
    });

    testWidgets(
      'map selection fills the editor only; Save adds through PlaceManager',
      (tester) async {
        final h = await _pump(tester);
        await _tapKey(tester, 'add-place');
        await _enter(tester, 'place-name', 'Delek');
        await _tapKey(tester, 'place-open-map');

        h.surface.tap(31.73260012345678, 34.75774398765432);
        await tester.pump();
        h.surface.tap(31.732601, 34.757744); // fine adjustment
        await tester.pump();
        expect(_shown(tester, 'map-selected-latitude'), contains('31.732601'));
        expect(_shown(tester, 'map-selected-longitude'), contains('34.757744'));
        expect(h.newRegistrations, 0);
        expect(h.rig.stored.places, isEmpty);

        await _tapKey(tester, 'map-confirm');
        expect(find.byType(MapLocationPickerScreen), findsNothing);
        expect(_field(tester, 'place-latitude'), '31.732601');
        expect(_field(tester, 'place-longitude'), '34.757744');
        expect(_field(tester, 'place-name'), 'Delek');
        // Confirming the map saved and registered nothing.
        expect(h.rig.stored.places, isEmpty);
        expect(h.newRegistrations, 0);

        await _enter(tester, 'place-reminder', 'Milk');
        await _tapKey(tester, 'place-save');

        final saved = h.rig.stored.places.single;
        expect(saved.latitude, 31.732601);
        expect(saved.longitude, 34.757744);
        expect(saved.outerRadius, 300);
        expect(saved.innerRadius, 80);
        expect(h.newRegistrations, 1);
        expect(h.rig.registrar.applied.single.latitude, 31.732601);

        // Normal restart: the same coordinates are read back.
        final restarted = h.rig.manager();
        await restarted.initialize();
        expect(restarted.places.single.place.latitude, 31.732601);
        expect(restarted.places.single.place.longitude, 34.757744);
      },
    );

    testWidgets('full map precision reaches the stored place', (tester) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      await _tapKey(tester, 'place-open-map');
      h.surface.tap(-33.86881234567891, -151.20931234567891);
      await tester.pump();
      await _tapKey(tester, 'map-confirm');
      await _enter(tester, 'place-name', 'Sydney');
      await _enter(tester, 'place-reminder', 'Ferry');
      await _tapKey(tester, 'place-save');

      final saved = h.rig.stored.places.single;
      expect(saved.latitude, -33.86881234567891);
      expect(saved.longitude, -151.20931234567891);
    });

    testWidgets('without a location, Save keeps the existing validation', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      await _tapKey(tester, 'place-open-map');
      await _tapKey(tester, 'map-cancel');
      await _enter(tester, 'place-name', 'A');
      await _enter(tester, 'place-reminder', 'B');
      await _tapKey(tester, 'place-save');

      expect(find.text('נא להזין קואורדינטות ורדיוס תקינים'), findsOneWidget);
      expect(h.rig.stored.places, isEmpty);
      expect(h.newRegistrations, 0);
    });

    testWidgets('the preview uses the radius typed in the editor', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      await _enter(tester, 'place-radius', '500');
      await _tapKey(tester, 'place-open-map');
      expect(h.surface.view.radii.outer, 500);
      expect(h.surface.view.radii.inner, 80);
      expect(find.textContaining('אזור הגישה (500 מ׳)'), findsOneWidget);
      await _tapKey(tester, 'map-cancel');

      // An invalid radius falls back to the default preview.
      await _enter(tester, 'place-radius', '5');
      await _tapKey(tester, 'place-open-map');
      expect(h.surface.view.radii.outer, 300);
    });

    testWidgets('a valid manual entry centres the map on it', (tester) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      await _enter(tester, 'place-latitude', '32.08');
      await _enter(tester, 'place-longitude', '34.78');
      await _tapKey(tester, 'place-open-map');
      expect(h.surface.view.center, point(32.08, 34.78));
      expect(h.surface.view.zoom, 16);
      expect(h.surface.view.selected, point(32.08, 34.78));
    });
  });

  group('existing place', () {
    testWidgets('opens on the saved location with its configured radius', (
      tester,
    ) async {
      final h = await _pump(tester, seed: _twoPlaces);
      await _tapKey(tester, 'place-edit-place-2');
      await _tapKey(tester, 'place-open-map');

      final view = h.surface.view;
      expect(view.center, point(31.7401, 34.7712));
      expect(view.zoom, 16);
      expect(view.selected, point(31.7401, 34.7712));
      expect(view.original, point(31.7401, 34.7712));
      expect(view.radii.outer, 450);
      expect(view.radii.inner, 80);
      expect(_shown(tester, 'map-selected-latitude'), contains('31.740100'));
      expect(_shown(tester, 'map-selected-longitude'), contains('34.771200'));
    });

    testWidgets(
      'moving the location saves through update and resets only that place',
      (tester) async {
        final h = await _pump(tester, seed: _twoPlaces);
        h.rig.runtime.placeSnapshots['place-1'] = _cooldown(31.7326, 34.7577);
        h.rig.runtime.placeSnapshots['place-2'] = _cooldown(31.7401, 34.7712);
        await _tapKey(tester, 'place-edit-place-2');
        await _tapKey(tester, 'place-open-map');
        h.surface.tap(31.7410, 34.7720);
        await tester.pump();
        // The saved location stays visible for reference.
        expect(h.surface.view.original, point(31.7401, 34.7712));
        await _tapKey(tester, 'map-confirm');
        expect(h.newRegistrations, 0);
        await _tapKey(tester, 'place-save');

        final moved = h.rig.stored.places.firstWhere((p) => p.id == 'place-2');
        expect(moved.latitude, 31.7410);
        expect(moved.longitude, 34.7720);
        expect(moved.name, 'Sagula');
        expect(moved.enabled, isTrue);
        expect(moved.outerRadius, 450);
        expect(
          h.rig.stored.reminders.firstWhere((r) => r.placeId == 'place-2').text,
          'Bread',
        );
        // Existing PlaceManager policy: one full registration set, and only
        // the moved place loses its runtime state.
        expect(h.newRegistrations, 1);
        expect(h.rig.registrar.appliedIds, ['place-1', 'place-2']);
        expect(h.rig.runtime.placeSnapshots.containsKey('place-2'), isFalse);
        expect(
          h.rig.runtime.placeSnapshots['place-1']?.state,
          DetectionState.cooldown,
        );
        final other = h.rig.stored.places.firstWhere((p) => p.id == 'place-1');
        expect(other.latitude, 31.7326);
        expect(other.longitude, 34.757743);
      },
    );

    testWidgets(
      'an unchanged selection keeps the text, identity and runtime state',
      (tester) async {
        final h = await _pump(tester, seed: _twoPlaces);
        h.rig.runtime.placeSnapshots['place-1'] = _cooldown(31.7326, 34.757743);
        await _tapKey(tester, 'place-edit-place-1');
        final latitudeBefore = _field(tester, 'place-latitude');
        final longitudeBefore = _field(tester, 'place-longitude');
        await _tapKey(tester, 'place-open-map');
        await _tapKey(tester, 'map-confirm'); // no tap: same location
        expect(_field(tester, 'place-latitude'), latitudeBefore);
        expect(_field(tester, 'place-longitude'), longitudeBefore);

        await _enter(tester, 'place-name', 'Delek station');
        await _tapKey(tester, 'place-save');

        final place = h.rig.stored.places.firstWhere((p) => p.id == 'place-1');
        expect(place.name, 'Delek station');
        expect(place.latitude, 31.7326);
        expect(place.longitude, 34.757743);
        // A name edit does not change the registration set.
        expect(h.newRegistrations, 0);
        expect(
          h.rig.runtime.placeSnapshots['place-1']?.state,
          DetectionState.cooldown,
        );
      },
    );

    testWidgets('cancel and back leave the editor and storage untouched', (
      tester,
    ) async {
      final h = await _pump(tester, seed: _twoPlaces);
      h.rig.runtime.placeSnapshots['place-1'] = _cooldown(31.7326, 34.757743);
      final before = h.rig.store.writes;
      await _tapKey(tester, 'place-edit-place-1');
      final latitudeBefore = _field(tester, 'place-latitude');

      await _tapKey(tester, 'place-open-map');
      h.surface.tap(32.0, 35.0);
      await tester.pump();
      await _tapKey(tester, 'map-cancel');
      expect(_field(tester, 'place-latitude'), latitudeBefore);

      await _tapKey(tester, 'place-open-map');
      h.surface.tap(32.0, 35.0);
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PlaceEditorScreen), findsOneWidget);
      expect(_field(tester, 'place-latitude'), latitudeBefore);

      expect(h.rig.store.writes, before);
      expect(h.newRegistrations, 0);
      expect(
        h.rig.runtime.placeSnapshots['place-1']?.state,
        DetectionState.cooldown,
      );
    });

    testWidgets(
      'Android rejection after a map change rolls back and keeps the draft',
      (tester) async {
        final h = await _pump(tester, seed: _twoPlaces);
        await _tapKey(tester, 'place-edit-place-1');
        await _tapKey(tester, 'place-open-map');
        h.surface.tap(31.75, 34.80);
        await tester.pump();
        await _tapKey(tester, 'map-confirm');
        h.rig.registrar.failNext = 1;
        await _tapKey(tester, 'place-save');

        expect(find.textContaining('השינוי בוטל'), findsOneWidget);
        // The editor keeps the map selection for another attempt...
        expect(_field(tester, 'place-latitude'), '31.75');
        expect(_field(tester, 'place-longitude'), '34.8');
        // ...while storage and Android hold the previous location.
        final stored = h.rig.stored.places.firstWhere((p) => p.id == 'place-1');
        expect(stored.latitude, 31.7326);
        expect(h.rig.registrar.applied.first.latitude, 31.7326);
        expect(h.newRegistrations, 2); // rejected set + restored set

        await _tapKey(tester, 'place-save');
        expect(find.byType(PlaceEditorScreen), findsNothing);
        expect(
          h.rig.stored.places.firstWhere((p) => p.id == 'place-1').latitude,
          31.75,
        );
      },
    );
  });

  group('failures and lifecycle', () {
    testWidgets('tiles failing shows a fallback; manual entry still works', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      await _enter(tester, 'place-name', 'Offline place');
      await _tapKey(tester, 'place-open-map');
      h.surface.failTiles();
      h.surface.failTiles();
      await tester.pump();
      expect(find.byKey(const Key('map-tiles-failed')), findsOneWidget);
      expect(find.textContaining('ידנית'), findsOneWidget);
      await _tapKey(tester, 'map-cancel');

      expect(_field(tester, 'place-name'), 'Offline place');
      await _enter(tester, 'place-reminder', 'Call');
      await _enter(tester, 'place-latitude', '31.5');
      await _enter(tester, 'place-longitude', '34.9');
      await _tapKey(tester, 'place-save');
      expect(h.rig.stored.places.single.name, 'Offline place');
      expect(h.rig.stored.places.single.latitude, 31.5);
    });

    testWidgets('a double tap on the map button opens one picker', (
      tester,
    ) async {
      await _pump(tester);
      await _tapKey(tester, 'add-place');
      await tester.ensureVisible(find.byKey(const Key('place-open-map')));
      await tester.tap(find.byKey(const Key('place-open-map')));
      await tester.tap(
        find.byKey(const Key('place-open-map')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byType(MapLocationPickerScreen), findsOneWidget);
      await _tapKey(tester, 'map-cancel');
      expect(find.byType(MapLocationPickerScreen), findsNothing);
      // And the button works again afterwards.
      await _tapKey(tester, 'place-open-map');
      expect(find.byType(MapLocationPickerScreen), findsOneWidget);
    });

    testWidgets('reopening starts from the last confirmed selection', (
      tester,
    ) async {
      final h = await _pump(tester, seed: _twoPlaces);
      await _tapKey(tester, 'place-edit-place-1');
      await _tapKey(tester, 'place-open-map');
      h.surface.tap(31.76, 34.79);
      await tester.pump();
      await _tapKey(tester, 'map-confirm');
      await _tapKey(tester, 'place-open-map');
      expect(h.surface.view.selected, point(31.76, 34.79));
      expect(h.surface.view.original, point(31.7326, 34.757743));
    });

    testWidgets('map taps never register; only Save does', (tester) async {
      final h = await _pump(tester, seed: _twoPlaces);
      final writes = h.rig.store.writes;
      await _tapKey(tester, 'place-edit-place-1');
      await _tapKey(tester, 'place-open-map');
      for (var i = 0; i < 5; i++) {
        h.surface.tap(31.7 + i / 1000, 34.7);
        await tester.pump();
      }
      await _tapKey(tester, 'map-confirm');
      expect(h.newRegistrations, 0);
      expect(h.rig.store.writes, writes);
    });

    testWidgets('an editor removed while the map is open ignores the result', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      final editorRoute = ModalRoute.of(
        tester.element(find.byType(PlaceEditorScreen)),
      )!;
      await _tapKey(tester, 'place-open-map');
      h.navigator.currentState!.removeRoute(editorRoute);
      await tester.pumpAndSettle();
      h.surface.tap(31.7, 34.7);
      await tester.pump();
      await _tapKey(tester, 'map-confirm');

      expect(tester.takeException(), isNull);
      expect(find.byType(PlaceEditorScreen), findsNothing);
      expect(h.rig.stored.places, isEmpty);
      expect(h.newRegistrations, 0);
    });

    testWidgets('the map button is disabled while saving', (tester) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      await _enter(tester, 'place-name', 'A');
      await _enter(tester, 'place-reminder', 'B');
      await _enter(tester, 'place-latitude', '31.5');
      await _enter(tester, 'place-longitude', '34.9');
      final gate = h.rig.registrar.holdNext();
      await tester.ensureVisible(find.byKey(const Key('place-save')));
      await tester.tap(find.byKey(const Key('place-save')));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('place-open-map')))
            .onPressed,
        isNull,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(h.rig.stored.places, hasLength(1));
    });
  });

  group('APP-11A editor', () {
    testWidgets('the coordinate paste field and its Apply button are gone', (
      tester,
    ) async {
      await _pump(tester);
      await _tapKey(tester, 'add-place');
      expect(find.byKey(const Key('place-paste-coordinates')), findsNothing);
      expect(find.byKey(const Key('place-apply-pasted')), findsNothing);
      expect(find.text('הדבקת קואורדינטות'), findsNothing);
      expect(find.text('החלה'), findsNothing);
      // The map button and both manual fields remain.
      expect(find.byKey(const Key('place-open-map')), findsOneWidget);
      expect(find.byKey(const Key('place-latitude')), findsOneWidget);
      expect(find.byKey(const Key('place-longitude')), findsOneWidget);
    });
  });

  group('RTL presentation', () {
    double x(TextPainter painter, String text, String part) => painter
        .getOffsetForCaret(TextPosition(offset: text.indexOf(part)), Rect.zero)
        .dx;

    TextPainter laidOut(String text) => TextPainter(
      text: TextSpan(text: text, style: const TextStyle(fontSize: 14)),
      textDirection: TextDirection.rtl,
    )..layout();

    testWidgets('an isolated pair keeps latitude left of longitude in RTL', (
      tester,
    ) async {
      final isolated = 'לדוגמה: ${displayPair(31.5, -34.25)}';
      final painter = laidOut(isolated);
      expect(
        x(painter, isolated, '31.5'),
        lessThan(x(painter, isolated, '-34')),
      );

      // Control: without the isolate the RTL paragraph puts the second
      // number first (on the left), the reversal the isolate prevents.
      const bare = 'לדוגמה: 31.500000, -34.250000';
      final control = laidOut(bare);
      expect(x(control, bare, '31.5'), greaterThan(x(control, bare, '-34')));
      painter.dispose();
      control.dispose();
    });

    testWidgets('the editor puts latitude left of longitude', (tester) async {
      await _pump(tester);
      await _tapKey(tester, 'add-place');
      expect(
        tester.getCenter(find.byKey(const Key('place-latitude'))).dx,
        lessThan(tester.getCenter(find.byKey(const Key('place-longitude'))).dx),
      );
    });

    testWidgets('coordinates render left-to-right with explicit labels', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _tapKey(tester, 'add-place');
      final latitudeField = tester.widget<TextField>(
        find.byKey(const Key('place-latitude')),
      );
      expect(latitudeField.textDirection, TextDirection.ltr);
      expect(latitudeField.decoration!.labelText, 'קו רוחב (Latitude)');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('place-longitude')))
            .decoration!
            .labelText,
        'קו אורך (Longitude)',
      );

      await _tapKey(tester, 'place-open-map');
      h.surface.tap(-31.5, -34.25);
      await tester.pump();
      final shown = tester.widget<Text>(
        find.byKey(const Key('map-selected-latitude')),
      );
      expect(shown.textDirection, TextDirection.ltr);
      expect(shown.data, '\u2066-31.500000\u2069');
      expect(find.text('קו רוחב (Latitude): '), findsOneWidget);
      expect(find.text('קו אורך (Longitude): '), findsOneWidget);
    });
  });
}
