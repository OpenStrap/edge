// The step calibration screen shipped without German: all 41 of its strings
// fell back to English on an otherwise German app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  final de = lookupAppLocalizations(const Locale('de'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('german has every string the english file has', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final german = arb('de');
    final missing = [
      for (final k in arb('en').keys)
        if (!k.startsWith('@') && !german.containsKey(k)) k,
    ];
    // The WHOOP firmware warning is added by its own change.
    missing.removeWhere((k) => k.startsWith('whoopFirmwareWarning'));
    expect(missing, isEmpty);
  });

  test('the calibration screen reads in german', () {
    expect(de.stepCalTitle, 'Schrittkalibrierung');
    expect(de.stepCalTitle, isNot(en.stepCalTitle));
    expect(de.stepCalCancel, 'Abbrechen');
  });

  test('counts agree with their noun', () {
    expect(de.stepCalBandSeen(1), 'Schritt, den das Band erkannt hat');
    expect(de.stepCalBandSeen(5), 'Schritte, die das Band erkannt hat');
    final one = de.stepCalDoneGait(1, 2, 10);
    expect(one, contains('1 Schritt gezählt'));
    expect(one, contains('2 Schritte erkannt'));
    expect(one, contains('10 %'));
  });
}
