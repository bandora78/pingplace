import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/places/place_card.dart';
import 'package:pingplace/src/places/place_manager.dart';
import 'package:pingplace/src/places/places_section.dart';

import 'support/place_fakes.dart';

/// APP-12: place cards. PlaceManager stays the only source of mutations.

final class _Harness {
  _Harness(this.rig, this.manager) : baseline = rig.registrar.calls.length;
  final PlaceTestRig rig;
  final PlaceManager manager;
  final int baseline;
  int get newRegistrations => rig.registrar.calls.length - baseline;
}

const _longName =
    'סניף הדואר המרכזי ברחוב הרצל הארוך מאוד בעיר התחתית ליד תחנת האוטובוס';
const _longReminder =
    'לאסוף את החבילה הרשומה, להביא תעודת זהות, לשלם את החשבון ולקנות בולים '
    'למכתבים של סבתא, ולא לשכוח לשאול על המשלוח הבינלאומי';

Future<_Harness> _pump(
  WidgetTester tester, {
  Future<void> Function(PlaceManager manager)? seed,
  double width = 412,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width * 3, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final rig = PlaceTestRig();
  final manager = rig.manager();
  await manager.initialize();
  if (seed != null) {
    await seed(manager);
  } else {
    await manager.add(draft(name: 'Home', reminderText: 'Keys'));
    await manager.add(
      draft(name: 'Office', latitude: 32.1, reminderText: 'Badge'),
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: Directionality(textDirection: TextDirection.rtl, child: child!),
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: PlacesSection(manager: manager),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(rig, manager);
}

Finder _key(String key) => find.byKey(Key(key));

Switch _switch(WidgetTester tester, String id) =>
    tester.widget<Switch>(_key('place-switch-$id'));

String _status(WidgetTester tester, String id) =>
    tester.widget<Text>(_key('place-status-$id')).data!;

Finder get _editor => find.text('עריכת מקום', skipOffstage: false);

void main() {
  group('content', () {
    testWidgets('one card per place with name, reminder and status only', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byType(PlaceCard), findsNWidgets(2));
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Keys'), findsOneWidget);
      expect(find.text('Office'), findsOneWidget);
      expect(find.text('Badge'), findsOneWidget);
      expect(_status(tester, 'place-1'), 'פעיל · מאושר ע״י Android');
      // Decision 2: coordinates and radius are only in the editor.
      expect(find.textContaining('32.08'), findsNothing);
      expect(find.textContaining('34.78'), findsNothing);
      expect(find.textContaining('רדיוס'), findsNothing);
    });

    testWidgets('the add action is prominent and full width', (tester) async {
      await _pump(tester);
      expect(find.text('הוספת מקום חדש'), findsOneWidget);
      final button = tester.getSize(_key('add-place'));
      expect(button.width, 412 - 32);
      expect(button.height, greaterThanOrEqualTo(48));
    });

    testWidgets(
      'long Hebrew text at 360 dp and 2x text scale does not overflow',
      (tester) async {
        await _pump(
          tester,
          width: 360,
          textScale: 2,
          seed: (manager) async {
            await manager.add(
              draft(name: _longName, reminderText: _longReminder),
            );
            await manager.add(draft(name: 'בית', latitude: 32.1));
          },
        );
        expect(tester.takeException(), isNull);
        final name = tester.widget<Text>(find.text(_longName));
        expect(name.maxLines, 2);
        expect(name.overflow, TextOverflow.ellipsis);
        final reminder = tester.widget<Text>(_key('place-reminder-place-1'));
        expect(reminder.maxLines, 2);
        // Controls keep their size next to the long text.
        expect(
          tester.getSize(_key('place-switch-place-1')).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(_key('place-menu-place-1')).width,
          greaterThanOrEqualTo(48),
        );
      },
    );

    testWidgets('right-to-left: content right, then switch, then menu', (
      tester,
    ) async {
      await _pump(tester);
      final content = tester.getCenter(_key('place-edit-place-1')).dx;
      final toggle = tester.getCenter(_key('place-switch-place-1')).dx;
      final menu = tester.getCenter(_key('place-menu-place-1')).dx;
      expect(content, greaterThan(toggle));
      expect(toggle, greaterThan(menu));
    });
  });

  group('registration states', () {
    Future<void> pumpCard(
      WidgetTester tester,
      PlaceRegistrationState state,
    ) async {
      final rig = PlaceTestRig();
      final manager = rig.manager();
      await manager.initialize();
      await manager.add(draft(name: 'Home'));
      final item = manager.places.single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaceCard(
              item: ManagedPlace(
                place: item.place,
                reminderText: item.reminderText,
                registration: state,
              ),
              interactive: true,
              inFlight: false,
              onOpen: () {},
              onToggle: (_) {},
              onDelete: () {},
            ),
          ),
        ),
      );
    }

    final expected = {
      PlaceRegistrationState.registered: (
        'פעיל · מאושר ע״י Android',
        Icons.check_circle_outline,
      ),
      PlaceRegistrationState.pending: ('ממתין לאישור Android', Icons.schedule),
      PlaceRegistrationState.disabled: (
        'מעקב כבוי',
        Icons.pause_circle_outline,
      ),
      PlaceRegistrationState.unknown: (
        'מצב הרישום לא ידוע',
        Icons.help_outline,
      ),
    };

    for (final MapEntry(key: state, value: (text, icon)) in expected.entries) {
      testWidgets('${state.name} shows matching text and icon', (tester) async {
        await pumpCard(tester, state);
        expect(_status(tester, 'place-1'), text);
        expect(
          tester.widget<Icon>(_key('place-status-icon-place-1')).icon,
          icon,
        );
      });
    }

    test('only registered reads as active', () {
      final theme = ThemeData();
      for (final state in PlaceRegistrationState.values) {
        final text = registrationPresentation(state, theme).text;
        expect(
          text.startsWith('פעיל'),
          state == PlaceRegistrationState.registered,
          reason: state.name,
        );
      }
    });
  });

  group('navigation', () {
    testWidgets('tapping the card content opens the editor', (tester) async {
      await _pump(tester);
      await tester.tap(_key('place-edit-place-1'));
      await tester.pumpAndSettle();
      expect(_editor, findsOneWidget);
      expect(find.widgetWithText(TextField, 'Home'), findsOneWidget);
    });

    testWidgets('a double tap on the card opens one editor', (tester) async {
      await _pump(tester);
      await tester.tap(_key('place-edit-place-1'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(_key('place-edit-place-1'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(_editor, findsOneWidget);
    });

    testWidgets('the switch does not open the editor', (tester) async {
      final h = await _pump(tester);
      await tester.tap(_key('place-switch-place-1'));
      await tester.pumpAndSettle();
      expect(_editor, findsNothing);
      expect(h.newRegistrations, 1);
    });

    testWidgets('the menu does not open the editor; its Edit item does', (
      tester,
    ) async {
      final h = await _pump(tester);
      await tester.tap(_key('place-menu-place-1'));
      await tester.pumpAndSettle();
      expect(_editor, findsNothing);
      expect(_key('place-delete-place-1'), findsOneWidget);
      await tester.tap(_key('place-menu-edit-place-1'));
      await tester.pumpAndSettle();
      expect(_editor, findsOneWidget);
      expect(h.newRegistrations, 0);
    });
  });

  group('enable and disable', () {
    testWidgets('a toggle changes only the selected place', (tester) async {
      final h = await _pump(tester);
      await tester.tap(_key('place-switch-place-2'));
      await tester.pumpAndSettle();
      expect(h.rig.stored.places.map((p) => p.enabled), [true, false]);
      expect(h.rig.registrar.appliedIds, ['place-1']);
      expect(_status(tester, 'place-1'), 'פעיל · מאושר ע״י Android');
      expect(_status(tester, 'place-2'), 'מעקב כבוי');
      expect(_switch(tester, 'place-2').value, isFalse);

      await tester.tap(_key('place-switch-place-2'));
      await tester.pumpAndSettle();
      expect(h.rig.registrar.appliedIds, ['place-1', 'place-2']);
      expect(_status(tester, 'place-2'), 'פעיל · מאושר ע״י Android');
    });

    testWidgets('the switch shows the stored value until the save completes', (
      tester,
    ) async {
      final h = await _pump(tester);
      final hold = h.rig.registrar.holdNext();
      await tester.tap(_key('place-switch-place-1'));
      await tester.pump();
      expect(_switch(tester, 'place-1').value, isTrue);
      expect(_key('place-progress-place-1'), findsOneWidget);

      hold.complete();
      await tester.pumpAndSettle();
      expect(_switch(tester, 'place-1').value, isFalse);
      expect(_key('place-progress-place-1'), findsNothing);
    });

    testWidgets('rapid repeated taps dispatch exactly one operation', (
      tester,
    ) async {
      final h = await _pump(tester);
      final hold = h.rig.registrar.holdNext();
      final writes = h.rig.store.writes;
      await tester.tap(_key('place-switch-place-1'));
      await tester.tap(_key('place-switch-place-1'), warnIfMissed: false);
      await tester.pump();
      await tester.tap(_key('place-switch-place-1'), warnIfMissed: false);
      hold.complete();
      await tester.pumpAndSettle();
      expect(h.newRegistrations, 1);
      expect(h.rig.store.writes, writes + 1);
      expect(h.rig.stored.places.first.enabled, isFalse);
    });

    testWidgets('every card control is disabled while the manager is busy', (
      tester,
    ) async {
      final h = await _pump(tester);
      final hold = h.rig.registrar.holdNext();
      await tester.tap(_key('place-switch-place-1'));
      await tester.pump();
      for (final id in ['place-1', 'place-2']) {
        expect(_switch(tester, id).onChanged, isNull, reason: id);
        expect(
          tester
              .widget<PopupMenuButton<Object?>>(_key('place-menu-$id'))
              .enabled,
          isFalse,
        );
        expect(tester.widget<InkWell>(_key('place-edit-$id')).onTap, isNull);
      }
      hold.complete();
      await tester.pumpAndSettle();
      expect(_switch(tester, 'place-2').onChanged, isNotNull);
    });

    testWidgets('an Android rejection rolls back and reports it', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.rig.registrar.failNext = 1;
      await tester.tap(_key('place-switch-place-1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('השינוי בוטל'), findsOneWidget);
      expect(_switch(tester, 'place-1').value, isTrue);
      expect(h.rig.stored.places.first.enabled, isTrue);
      expect(_key('places-error'), findsOneWidget);
      expect(_key('retry-registration'), findsOneWidget);
      expect(_key('place-progress-place-1'), findsNothing);
    });

    testWidgets('a failed rollback asks for a retry, which can also fail', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.rig.registrar.failNext = 2;
      await tester.tap(_key('place-switch-place-1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('השחזור לא אושר'), findsOneWidget);

      // Let the first message leave; snackbars are shown one at a time.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      h.rig.registrar.failNext = 1;
      await tester.tap(_key('retry-registration'));
      await tester.pumpAndSettle();
      expect(
        find.text('רישום המקומות ב-Android נכשל. בדקו הרשאות ונסו שוב.'),
        findsOneWidget,
      );

      await tester.tap(_key('retry-registration'));
      await tester.pumpAndSettle();
      expect(_key('places-error'), findsNothing);
      expect(h.rig.registrar.appliedIds, ['place-1', 'place-2']);
    });
  });

  group('delete', () {
    Future<void> openDelete(WidgetTester tester, String id) async {
      await tester.tap(_key('place-menu-$id'));
      await tester.pumpAndSettle();
      await tester.tap(_key('place-delete-$id'));
      await tester.pumpAndSettle();
    }

    testWidgets('cancel keeps the place and registers nothing', (tester) async {
      final h = await _pump(tester);
      await openDelete(tester, 'place-1');
      expect(find.text('מחיקת מקום'), findsOneWidget);
      await tester.tap(_key('cancel-delete'));
      await tester.pumpAndSettle();
      expect(h.rig.stored.places, hasLength(2));
      expect(h.newRegistrations, 0);
    });

    testWidgets('confirm deletes exactly that place', (tester) async {
      final h = await _pump(tester);
      await openDelete(tester, 'place-1');
      await tester.tap(_key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(h.rig.stored.places.map((p) => p.id), ['place-2']);
      expect(h.rig.registrar.appliedIds, ['place-2']);
      expect(h.newRegistrations, 1);
      expect(find.byType(PlaceCard), findsOneWidget);
    });

    testWidgets('a failed delete keeps the place and reports it', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.rig.store.failWrites = true;
      await openDelete(tester, 'place-1');
      await tester.tap(_key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(find.text('השמירה נכשלה. לא בוצע שינוי.'), findsOneWidget);
      expect(find.byType(PlaceCard), findsNWidgets(2));
      expect(h.newRegistrations, 0);
    });

    testWidgets('a confirmation after another operation started is refused', (
      tester,
    ) async {
      final h = await _pump(tester);
      await openDelete(tester, 'place-1');
      // Another operation starts while the dialog is open.
      final hold = h.rig.registrar.holdNext();
      final other = h.manager.setEnabled('place-2', false);
      await tester.tap(_key('confirm-delete'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('פעולה אחרת מתבצעת'), findsOneWidget);
      hold.complete();
      await other;
      await tester.pumpAndSettle();
      expect(h.rig.stored.places.map((p) => p.id), ['place-1', 'place-2']);
      expect(h.newRegistrations, 1);
    });
  });

  group('accessibility', () {
    testWidgets('the switch is labelled with the place name', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester);
      expect(find.bySemanticsLabel(RegExp('מעקב עבור Home')), findsOneWidget);
      expect(find.byTooltip('פעולות נוספות עבור Office'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('tap targets meet the Android guideline', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      semantics.dispose();
    });
  });

  group('loading and empty', () {
    testWidgets('a spinner until loaded, add disabled meanwhile', (
      tester,
    ) async {
      final manager = PlaceTestRig().manager();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PlacesSection(manager: manager)),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<FilledButton>(_key('add-place')).onPressed, isNull);
      unawaited(manager.initialize());
      await tester.pumpAndSettle();
      expect(_key('places-empty'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('add-place')).onPressed,
        isNotNull,
      );
    });
  });
}
