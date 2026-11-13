// An imperial profile form pre-fills whole inches and pounds. Saving it
// without touching those fields converted the rounded numbers back to metric,
// so 72.5 kg became 72.57 kg and 178 cm became 177.8 cm on every save — a
// rename moved the stored body.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1200, 3600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
      MaterialApp(theme: buildTheme(Brightness.light), home: child));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('untouched imperial height and weight keep the stored metric',
      (t) async {
    Map<String, dynamic>? saved;
    await _pump(
        t,
        EditProfileView(
          initial: const {
            'name': 'A',
            'sex': 'f',
            'age': 34,
            'height_cm': 178.0,
            'weight_kg': 72.5,
          },
          units: UnitsController.seed(UnitSystem.imperial),
          onSave: (f) async => saved = f,
        ));

    await t.enterText(find.widgetWithText(TextField, 'A'), 'B');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!['name'], 'B');
    expect(saved!['height_cm'], 178.0);
    expect(saved!['weight_kg'], 72.5);
  });

  testWidgets('an edited imperial weight is still converted', (t) async {
    Map<String, dynamic>? saved;
    await _pump(
        t,
        EditProfileView(
          initial: const {'sex': 'f', 'age': 34, 'weight_kg': 72.5},
          units: UnitsController.seed(UnitSystem.imperial),
          onSave: (f) async => saved = f,
        ));

    // 72.5 kg pre-fills as 160 lb.
    await t.enterText(find.widgetWithText(TextField, '160'), '150');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!['weight_kg'] as double, closeTo(150 * 0.45359237, 0.01));
  });
}
