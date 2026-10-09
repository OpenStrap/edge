// The two nightly-RMSSD labels Investigate shows are translated in every
// shipped language, not left in English.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  test('every language has its own nightly RMSSD labels', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final code in ['de', 'es', 'fr', 'hi', 'zh']) {
      final l = lookupAppLocalizations(Locale(code));
      expect(l.investigateRmssdNightly, isNot(en.investigateRmssdNightly),
          reason: code);
      expect(l.investigateRmssdStored, isNot(en.investigateRmssdStored),
          reason: code);
      expect(l.investigateRmssdNightly, startsWith('RMSSD'), reason: code);
      expect(l.investigateRmssdStored, startsWith('RMSSD'), reason: code);
    }
  });
}
