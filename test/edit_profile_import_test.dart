// The read button on Edit profile.
//
// Three things have to hold, and none of them are visible from the importer's
// own unit tests: the form has to SHOW what came back (a refresh that leaves
// the old weight on screen has not refreshed anything a user can see), the
// word on the button has to flip once something has arrived, and a form with
// no importer wired must not grow a control at all — that is the case the
// golden sweep pumps, and a real health-store prompt from a screenshot run is
// not something to discover on CI.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _frame(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: child,
    );

const _initial = {
  'name': 'Sahil',
  'sex': 'm',
  'age': 34,
  'height_cm': 178.0,
  'weight_kg': 72.4,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Tall enough that the whole form is laid out at once. The default 800 pt
  /// viewport leaves the button below the fold, where a `ListView` has not
  /// built it yet — and a widget that does not exist cannot be tapped, which
  /// reads as a broken button rather than as a short window.
  Future<void> pump(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(1200, 3600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(_frame(child));
    await t.pumpAndSettle();
  }

  testWidgets('no importer, no button', (t) async {
    await t.pumpWidget(_frame(EditProfileView(
      initial: _initial,
      onSave: (_) async {},
    )));
    expect(find.textContaining('from Apple Health'), findsNothing);
    expect(find.textContaining('from Health Connect'), findsNothing);
  });

  testWidgets('the first read says Import, and fills the fields', (t) async {
    await pump(
        t,
        EditProfileView(
          initial: _initial,
          onSave: (_) async {},
          onImport: () async => (
            'Updated weight from the store.',
            false,
            {..._initial, 'weight_kg': 70.1, 'age': 35},
          ),
        ));

    expect(find.textContaining('Import from '), findsOneWidget);
    expect(find.widgetWithText(TextField, '72.4'), findsOneWidget);

    await t.tap(find.textContaining('Import from '));
    await t.pumpAndSettle();

    // What arrived is on screen, in the field it belongs to — not just in a
    // confirmation line claiming it.
    expect(find.widgetWithText(TextField, '70.1'), findsOneWidget);
    expect(find.widgetWithText(TextField, '35'), findsOneWidget);
    expect(find.text('Updated weight from the store.'), findsOneWidget);
    // Same control, second verb.
    expect(find.textContaining('Refresh from '), findsOneWidget);
  });

  testWidgets('a refusal keeps the first verb and changes nothing', (t) async {
    await pump(
        t,
        EditProfileView(
          initial: _initial,
          onSave: (_) async {},
          onImport: () async => ('The store granted nothing.', true, null),
        ));
    await t.tap(find.textContaining('Import from '));
    await t.pumpAndSettle();

    expect(find.text('The store granted nothing.'), findsOneWidget);
    expect(find.widgetWithText(TextField, '72.4'), findsOneWidget);
    // Nothing was read, so nothing is there to refresh.
    expect(find.textContaining('Import from '), findsOneWidget);
    expect(find.textContaining('Refresh from '), findsNothing);
  });

  testWidgets('an import that changes nothing keeps what was typed',
      (t) async {
    await pump(
        t,
        EditProfileView(
          initial: _initial,
          onSave: (_) async {},
          onImport: () async =>
              ('Nothing changed.', false, const <String, dynamic>{}),
        ));
    await t.enterText(find.widgetWithText(TextField, '72.4'), '80');
    await t.enterText(find.widgetWithText(TextField, '34'), '40');
    await t.tap(find.textContaining('Import from '));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, '80'), findsOneWidget);
    expect(find.widgetWithText(TextField, '40'), findsOneWidget);
  });

  testWidgets('an import rewrites only the fields it changed', (t) async {
    await pump(
        t,
        EditProfileView(
          initial: _initial,
          onSave: (_) async {},
          onImport: () async => ('Updated height.', false, {'height_cm': 180.0}),
        ));
    await t.enterText(find.widgetWithText(TextField, '72.4'), '80');
    await t.tap(find.textContaining('Import from '));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, '80'), findsOneWidget);
    expect(find.widgetWithText(TextField, '180'), findsOneWidget);
  });

  testWidgets('a refused save says so, and a double tap saves once',
      (t) async {
    var calls = 0;
    await pump(
        t,
        EditProfileView(
          initial: _initial,
          onSave: (_) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 50));
            throw StateError('profile not saved');
          },
        ));
    await t.tap(find.text('Save'));
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('profile not saved'), findsOneWidget);
  });
}
