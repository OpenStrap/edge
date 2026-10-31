// Height and weight are decimals (a metric weight pre-fills as "72.5"), but a
// plain `TextInputType.number` is iOS's digits-only number pad: clearing the
// field to correct it left no way to type the separator, so 73.4 went in as
// 734 or 73. Age stays a whole number.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/onboarding/profile_setup.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _decimal = TextInputType.numberWithOptions(decimal: true);

Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1200, 3600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: child,
  ));
  await t.pumpAndSettle();
}

TextInputType? _keyboardOf(WidgetTester t, String text) =>
    t.widget<TextField>(find.widgetWithText(TextField, text)).keyboardType;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('edit profile: height and weight offer a decimal key',
      (t) async {
    await _pump(
        t,
        EditProfileView(
          initial: const {
            'sex': 'm',
            'age': 34,
            'height_cm': 178.5,
            'weight_kg': 72.5,
          },
          onSave: (_) async {},
        ));
    expect(_keyboardOf(t, '178.5'), _decimal);
    expect(_keyboardOf(t, '72.5'), _decimal);
    expect(_keyboardOf(t, '34'), TextInputType.number);
  });

  testWidgets('onboarding: height and weight offer a decimal key', (t) async {
    await _pump(
        t,
        ProfileSetupView(
          initial: const {
            'sex': 'f',
            'age': 34,
            'height_cm': 165.5,
            'weight_kg': 61.5,
          },
          onSave: (_) async {},
        ));
    expect(_keyboardOf(t, '165.5'), _decimal);
    expect(_keyboardOf(t, '61.5'), _decimal);
    expect(_keyboardOf(t, '34'), TextInputType.number);
  });
}
