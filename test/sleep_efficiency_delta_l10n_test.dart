// The efficiency row of the sleep comparison put an English "N points" in
// front of the localized lower/higher phrase, so a German reader saw
// "12 points niedriger als üblich". The unit now comes from the locale.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

void main() {
  test('english names percentage points', () {
    final l = lookupAppLocalizations(const Locale('en'));
    expect(sleepEfficiencyDelta(l, 11.6), '12 percentage points');
    expect(sleepEfficiencyDelta(null, 11.6), '12 percentage points');
  });

  for (final code in ['de', 'es', 'ru', 'hi', 'zh']) {
    test('$code verdict has no english unit', () {
      final l = lookupAppLocalizations(Locale(code));
      final s = sleepEfficiencyDelta(l, 11.6);
      expect(s, contains('12'));
      expect(s, isNot(contains('points')));
    });
  }
}
