import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/places/place_manager.dart';
import 'package:pingplace/src/places/places_section.dart';

import 'support/place_fakes.dart';

Future<PlaceManager> _pump(WidgetTester tester, PlaceTestRig rig) async {
  final manager = rig.manager();
  await manager.initialize();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: PlacesSection(manager: manager)),
      ),
    ),
  );
  await tester.pump();
  return manager;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

Future<void> _fillEditor(
  WidgetTester tester, {
  String? name,
  String? reminder,
  String? latitude,
  String? longitude,
  String? radius,
}) async {
  if (name != null) {
    await tester.enterText(find.byKey(const Key('place-name')), name);
  }
  if (reminder != null) {
    await tester.enterText(find.byKey(const Key('place-reminder')), reminder);
  }
  if (latitude != null) {
    await tester.enterText(find.byKey(const Key('place-latitude')), latitude);
  }
  if (longitude != null) {
    await tester.enterText(find.byKey(const Key('place-longitude')), longitude);
  }
  if (radius != null) {
    await tester.enterText(find.byKey(const Key('place-radius')), radius);
  }
}

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('place-save')));
  await tester.tap(find.byKey(const Key('place-save')));
  await _settle(tester);
}

void main() {
  testWidgets('shows an empty state and adds places one after another', (
    tester,
  ) async {
    final rig = PlaceTestRig();
    await _pump(tester, rig);
    expect(find.textContaining('עדיין אין מקומות'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-place')));
    await tester.pumpAndSettle();
    await _fillEditor(
      tester,
      name: 'Home',
      reminder: 'Keys',
      latitude: '32.08',
      longitude: '34.78',
    );
    await _save(tester);

    await tester.tap(find.byKey(const Key('add-place')));
    await tester.pumpAndSettle();
    await _fillEditor(
      tester,
      name: 'Office',
      reminder: 'Badge',
      latitude: '32.1',
      longitude: '34.9',
      radius: '500',
    );
    await _save(tester);

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Office'), findsOneWidget);
    expect(rig.stored.places.map((p) => p.name), ['Home', 'Office']);
    expect(rig.stored.places.last.outerRadius, 500);
    expect(rig.registrar.appliedIds, ['place-1', 'place-2']);
    expect(find.text('פעיל · מאושר ע״י Android'), findsNWidgets(2));
  });

  testWidgets(
    'editor validation errors keep the editor open and save nothing',
    (tester) async {
      final rig = PlaceTestRig();
      await _pump(tester, rig);
      await tester.tap(find.byKey(const Key('add-place')));
      await tester.pumpAndSettle();

      await _fillEditor(
        tester,
        name: '',
        reminder: 'x',
        latitude: '32',
        longitude: '34',
      );
      await _save(tester);
      expect(find.text('נא להזין שם למקום'), findsOneWidget);

      await _fillEditor(tester, name: 'A', latitude: 'abc');
      await _save(tester);
      expect(find.text('נא להזין קואורדינטות ורדיוס תקינים'), findsOneWidget);

      await _fillEditor(tester, latitude: '32', radius: '5');
      await _save(tester);
      expect(find.byKey(const Key('place-error')), findsOneWidget);
      expect(rig.stored.places, isEmpty);
    },
  );

  testWidgets('edits one place in place', (tester) async {
    final rig = PlaceTestRig();
    final manager = rig.manager();
    await manager.initialize();
    await manager.add(draft(name: 'Home'));
    await manager.add(draft(name: 'Office', latitude: 32.1));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PlacesSection(manager: manager)),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('place-edit-place-2')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Office'), findsOneWidget);
    await _fillEditor(tester, name: 'Office HQ', reminder: 'Lunch');
    await _save(tester);

    expect(find.text('Office HQ'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(rig.stored.places.first.name, 'Home');
    expect(rig.stored.reminders.last.text, 'Lunch');
  });

  testWidgets('switch toggles monitoring for one place only', (tester) async {
    final rig = PlaceTestRig();
    final manager = rig.manager();
    await manager.initialize();
    await manager.add(draft(name: 'Home'));
    await manager.add(draft(name: 'Office', latitude: 32.1));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PlacesSection(manager: manager)),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('place-switch-place-1')));
    await _settle(tester);

    expect(rig.stored.places.map((p) => p.enabled), [false, true]);
    expect(rig.registrar.appliedIds, ['place-2']);
    expect(
      tester.widget<Text>(find.byKey(const Key('place-status-place-1'))).data,
      'מעקב כבוי',
    );
  });

  testWidgets('delete asks for confirmation; cancel keeps the place', (
    tester,
  ) async {
    final rig = PlaceTestRig();
    final manager = rig.manager();
    await manager.initialize();
    await manager.add(draft(name: 'Home'));
    await manager.add(draft(name: 'Office', latitude: 32.1));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PlacesSection(manager: manager)),
        ),
      ),
    );
    await tester.pump();

    // APP-12: Delete is in the card's overflow menu.
    await tester.tap(find.byKey(const Key('place-menu-place-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place-delete-place-1')));
    await tester.pumpAndSettle();
    expect(find.text('מחיקת מקום'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel-delete')));
    await _settle(tester);
    expect(rig.stored.places, hasLength(2));

    // APP-12: Delete is in the card's overflow menu.
    await tester.tap(find.byKey(const Key('place-menu-place-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place-delete-place-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await _settle(tester);

    expect(rig.stored.places.map((p) => p.id), ['place-2']);
    expect(rig.registrar.appliedIds, ['place-2']);
    expect(find.text('Home'), findsNothing);
    expect(find.text('Office'), findsOneWidget);
  });

  testWidgets(
    'Android rejection keeps the editor open with a rollback message',
    (tester) async {
      final rig = PlaceTestRig();
      await _pump(tester, rig);
      rig.registrar.failNext = 1;

      await tester.tap(find.byKey(const Key('add-place')));
      await tester.pumpAndSettle();
      await _fillEditor(
        tester,
        name: 'Home',
        reminder: 'Keys',
        latitude: '32',
        longitude: '34',
      );
      await _save(tester);

      expect(find.textContaining('השינוי בוטל'), findsOneWidget);
      expect(find.byKey(const Key('place-save')), findsOneWidget);
      expect(rig.stored.places, isEmpty);
    },
  );
}
