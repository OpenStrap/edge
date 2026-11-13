import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// gen-l10n fills a key a locale lacks from the English template without a
/// warning, so a missing key shows up as English text inside an otherwise
/// translated screen. These are the Settings group headers, the whole
/// Report-an-issue screen and the onboarding strings that were English in
/// every locale except Russian.
void main() {
  const locales = ['de', 'es', 'fr', 'hi', 'ru', 'zh'];

  Map<String, dynamic> arb(String locale) =>
      jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
          as Map<String, dynamic>;

  bool covered(String k) =>
      k.startsWith('report') ||
      k.startsWith('settingsGroup') ||
      k.startsWith('settingsReportIssue') ||
      k.startsWith('settingsZoneAlert') ||
      k.startsWith('settingsAlarm') ||
      k == 'settingsCycleTrackingRowSubHealth' ||
      k == 'profileSetupCycleSub' ||
      k == 'supplementUnreadableField' ||
      k == 'supplementUnreadableFields' ||
      k == 'presentationHeightCm' ||
      k == 'presentationHeightIn' ||
      k == 'presentationWeightLb';

  Set<String> placeholders(String s) =>
      RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m[1]!).toSet();

  final en = arb('en');
  final keys = en.keys.where((k) => !k.startsWith('@') && covered(k)).toList();

  test('the key set under test is not empty', () {
    expect(keys, contains('reportNavTitle'));
    expect(keys, contains('settingsGroupApp'));
  });

  for (final locale in locales) {
    test('$locale translates settings, report and onboarding strings', () {
      final l = arb(locale);
      final missing = keys.where((k) => !l.containsKey(k)).toList();
      expect(missing, isEmpty);
      for (final k in keys) {
        expect(
          placeholders(l[k] as String),
          placeholders(en[k] as String),
          reason: '$locale $k',
        );
      }
    });
  }
}
