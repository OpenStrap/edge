import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/presentation_text.dart';

void main() {
  test('measures caption keeps the total in every locale', () {
    final want = {
      'en': 'of 12 measures',
      'hi': '12 में से माप',
      'de': 'von 12 Messwerten',
      'fr': 'mesures sur 12',
    };
    for (final e in want.entries) {
      final l = lookupAppLocalizations(Locale(e.key));
      expect(consistencyOf(l, 12, 'measures'), e.value, reason: e.key);
    }
  });
}
