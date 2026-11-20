// Plural strings print the number, not a literal '#'.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  test('plural counts are substituted in every language', () {
    for (final code in ['en', 'de', 'es', 'fr', 'hi', 'ru', 'th', 'zh']) {
      final l = lookupAppLocalizations(Locale(code));
      for (final s in [
        l.investigateDroppedIrregular(3),
        l.investigateDroppedThin(3),
        l.calmBreathingMinutesSemantic(5),
      ]) {
        expect(s, isNot(contains('#')), reason: '$code: $s');
        expect(s, matches(RegExp('[35]')), reason: '$code: $s');
      }
    }
  });

  test('english not-taken dose state reads as prose', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.supplementNotTaken3d2bc8, 'not taken');
  });
}
