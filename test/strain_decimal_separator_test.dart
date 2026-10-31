import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/decimal_text.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The strain trend screen formats through displayFixed; every other place
  // that prints the same strain number has to use the same separator, or a
  // German user sees "12.3" on one screen and "12,3" on the next.
  test('strain cells use the display locale decimal separator', () {
    SharedPreferences.setMockInitialValues({});
    final controller = LocaleController.seed('de')..useForPresentation();
    addTearDown(controller.dispose);
    final de = lookupAppLocalizations(const Locale('de'));

    expect(displayFixed(12.3, 1), '12,3');
    expect(formatCell(de, 'strain', 12.3).$1, displayFixed(12.3, 1));
  });

  // The workout list and the live screen both open the session summary; the
  // summary has to print the strain they printed, not a '.' version of it.
  test('the session summary prints strain like the list that opens it', () {
    SharedPreferences.setMockInitialValues({});
    final controller = LocaleController.seed('de')..useForPresentation();
    addTearDown(controller.dispose);
    final r = ActivityResult(
      allActivities.first,
      start: DateTime(2026, 5, 20, 7, 15),
      duration: const Duration(minutes: 45),
      strain: 12.3,
    );
    final strain = sessionStats(r, null).firstWhere((s) => s.$1 == 'Strain');
    expect(strain.$2, '12,3');
  });

  // Every on-screen strain number. A source scan, because these sit inside
  // widgets that need a full app around them to pump, and the regression is
  // one `toStringAsFixed` slipping back in.
  test('no screen formats a strain value with toStringAsFixed', () {
    const files = [
      'lib/ui2/screens/home_screen.dart',
      'lib/ui2/screens/workout_screen.dart',
      'lib/ui2/activity/day_strain.dart',
      'lib/ui2/activity/live.dart',
      'lib/ui2/activity/summary.dart',
    ];
    final offenders = <String>[];
    for (final f in files) {
      final lines = File(f).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final window = [
          if (i > 0) lines[i - 1],
          lines[i],
        ].join(' ');
        if (lines[i].contains('toStringAsFixed') &&
            RegExp(r'strain|Strain|aim\b').hasMatch(window)) {
          offenders.add('$f:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
