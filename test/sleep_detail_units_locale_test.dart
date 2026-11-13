import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Metric detail prints these readings with displayFixed and a translated
  // unit; the sleep screen has to print the same night the same way.
  test('sleep readings use the display locale unit and separator', () {
    SharedPreferences.setMockInitialValues({});
    final controller = LocaleController.seed('ru')..useForPresentation();
    addTearDown(controller.dispose);
    final ru = lookupAppLocalizations(const Locale('ru'));

    expect(sleepReadingText(ru, 14.2, 1, 'br/min'),
        '14,2 ${ru.supplementBrMin0041f9}');
    expect(sleepReadingText(ru, 52, 0, 'bpm'), '52 ${ru.activityLiveBpmUnit}');
    expect(sleepReadingText(ru, 48, 0, 'ms'), '48 ${ru.cycleUnitMs}');
  });

  test('english readings are unchanged', () {
    SharedPreferences.setMockInitialValues({});
    final controller = LocaleController.seed('en')..useForPresentation();
    addTearDown(controller.dispose);
    final en = lookupAppLocalizations(const Locale('en'));

    expect(sleepReadingText(en, 14.2, 1, 'br/min'), '14.2 br/min');
    expect(sleepReadingText(en, 52, 0, 'bpm'), '52 bpm');
  });

  // The readings sit inside a screen that needs a full app to pump; the
  // regression is a raw literal slipping back in.
  test('the sleep screen formats no reading with toStringAsFixed', () {
    final src = File('lib/ui2/screens/sleep_detail.dart').readAsStringSync();
    expect(src.contains('toStringAsFixed'), isFalse);
    expect(RegExp(r"\} (bpm|ms|br/min)'").hasMatch(src), isFalse);
  });
}
