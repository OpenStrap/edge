// A number that parses is not yet a body.
//
// Both profile forms used to accept any finite number: a birth year typed into
// the age box saved as age 1990, and Tanaka put that user's HR ceiling at
// -1185 bpm, so every zone of every day was banded off it. An imperial height
// typed as feet.inches ("5.10") saved as 13 cm.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/hr_max.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/onboarding/profile_setup.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _frame(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: child,
    );

Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1200, 3600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(_frame(child));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('estimatedMaxHr', () {
    test('a stored birth year gets no ceiling, not a negative one', () {
      expect(estimatedMaxHr(1990, 'gen4'), isNull);
      expect(estimatedMaxHr(-5, 'gen4'), isNull);
      expect(estimatedMaxHr(0, 'gen4'), isNull);
    });

    test('a real age is unchanged', () {
      expect(estimatedMaxHr(30, 'gen4'), closeTo(187.0, 1e-9));
      expect(estimatedMaxHr(120, 'gen4'), closeTo(124.0, 1e-9));
    });
  });

  test('plausibility bounds', () {
    expect(plausibleAgeYears(1990), isFalse);
    expect(plausibleAgeYears(0.4), isFalse);
    expect(plausibleAgeYears(34), isTrue);
    expect(plausibleHeightCm(12.95), isFalse);
    expect(plausibleHeightCm(178), isTrue);
    expect(plausibleWeightKg(0), isFalse);
    expect(plausibleWeightKg(72.4), isTrue);
  });

  testWidgets('edit profile refuses a birth year typed as age', (t) async {
    Map<String, dynamic>? saved;
    await _pump(
        t,
        EditProfileView(
          initial: const {'sex': 'm', 'age': 34, 'height_cm': 178.0},
          onSave: (f) async => saved = f,
        ));

    await t.enterText(find.widgetWithText(TextField, '34'), '1990');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved, isNull);
    expect(find.textContaining('out of range'), findsOneWidget);
  });

  testWidgets('edit profile still saves a real profile', (t) async {
    Map<String, dynamic>? saved;
    await _pump(
        t,
        EditProfileView(
          initial: const {'sex': 'm', 'age': 34, 'height_cm': 178.0},
          onSave: (f) async => saved = f,
        ));

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved?['age'], 34);
    expect(saved?['height_cm'], 178.0);
  });

  testWidgets('onboarding refuses feet.inches typed into an inches box',
      (t) async {
    Map<String, dynamic>? saved;
    await _pump(
        t,
        ProfileSetupView(
          initial: const {'sex': 'm', 'age': 34, 'height_cm': 178.0},
          units: UnitsController.seed(UnitSystem.imperial),
          onSave: (f) async => saved = f,
        ));

    // 178 cm pre-fills as 70 total inches.
    await t.enterText(find.widgetWithText(TextField, '70'), '5.10');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();

    expect(saved, isNull);
    expect(find.textContaining('out of range'), findsOneWidget);
  });
  // Imperial pre-fills whole pounds: 20 kg shows "44", which reads back as
  // 19.96 kg, under the floor. An untouched field keeps the stored value.
  testWidgets('an untouched imperial weight on the floor still saves',
      (t) async {
    Map<String, dynamic>? saved;
    await _pump(
        t,
        EditProfileView(
          initial: const {'sex': 'f', 'age': 34, 'weight_kg': 20.0},
          units: UnitsController.seed(UnitSystem.imperial),
          onSave: (f) async => saved = f,
        ));

    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved?['weight_kg'], 20.0);
  });

  testWidgets('onboarding keeps an untouched imperial weight', (t) async {
    Map<String, dynamic>? saved;
    await _pump(
        t,
        ProfileSetupView(
          initial: const {'sex': 'f', 'age': 34, 'weight_kg': 20.0},
          units: UnitsController.seed(UnitSystem.imperial),
          onSave: (f) async => saved = f,
        ));

    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();

    expect(saved?['weight_kg'], 20.0);
  });
}
