import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The journal's "Talk it through with AI" link was a bare English literal,
/// so it stayed English above otherwise translated fields, and the sheet it
/// opens fell back to the English template title in most locales.
void main() {
  const locales = ['de', 'es', 'fr', 'hi', 'ru', 'zh'];
  const keys = [
    'journalComposeTalkItThroughWithAi',
    'supplementTalkItThrough88a9d2',
  ];

  Map<String, dynamic> arb(String locale) =>
      jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
          as Map<String, dynamic>;

  test('english template defines the keys', () {
    final en = arb('en');
    for (final k in keys) {
      expect(en[k], isA<String>(), reason: k);
    }
  });

  for (final locale in locales) {
    test('$locale translates the journal AI entry and sheet title', () {
      final en = arb('en');
      final l = arb(locale);
      for (final k in keys) {
        expect(l[k], isA<String>(), reason: '$locale $k');
        expect(l[k], isNot(en[k]), reason: '$locale $k');
      }
    });
  }

  test('the compose screen reads the link label from localizations', () {
    final src =
        File('lib/ui2/screens/journal_compose.dart').readAsStringSync();
    expect(src, contains('l?.journalComposeTalkItThroughWithAi'));
  });
}
