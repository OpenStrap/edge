import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/wellness_screen.dart';

void main() {
  test('stress level tokens map to the locale, not the analytics English', () {
    final de = lookupAppLocalizations(const Locale('de'));
    expect(stressLevelLabel(de, 'elevated'), de.wellnessStressLevelElevated);
    expect(stressLevelLabel(de, 'elevated'), isNot('elevated'));
    expect(stressLevelLabel(de, 'low'), de.wellnessStressLevelLow);
    expect(stressLevelLabel(de, 'normal'), de.wellnessStressLevelNormal);
    expect(stressLevelLabel(de, 'high'), de.wellnessStressLevelHigh);
  });

  test('unknown token and missing localizations fall back to the raw token',
      () {
    final de = lookupAppLocalizations(const Locale('de'));
    expect(stressLevelLabel(de, 'weird'), 'weird');
    expect(stressLevelLabel(null, 'high'), 'high');
  });
}
