// A translated catalogue that holds the English text word for word shows
// English on an otherwise translated screen, and the coverage tests can't see
// it because the key is present. Spanish and French said "3 SETS" on the live
// strength screen, and Thai titled the ECG screen "Heart Screener".
//
// Only phrases are checked (longer than 12 characters, with a space): short
// labels such as "REM", "kg" or "OK" are legitimately the same in many
// languages. A phrase that really is the same in a language goes in
// [_sameOnPurpose] with its locale.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// (locale, key) pairs whose value is identical to English on purpose:
/// placeholder-only patterns, brand names, units and abbreviations, or words
/// that are spelled the same in that language.
final _sameOnPurpose = <String>{
  for (final code in ['de', 'es', 'fr', 'hi', 'ru', 'th', 'zh'])
    '$code:logFoodPillOpenFoodFacts', // a product name
  // Placeholder-only patterns: no words of their own.
  for (final code in ['de', 'es', 'fr', 'hi', 'ru'])
    '$code:metricDetailSlotWithValue',
  for (final code in ['de', 'es', 'fr', 'hi', 'ru']) '$code:sleepDetailScrubAt',
  for (final code in ['de', 'es', 'fr', 'hi', 'th', 'zh'])
    '$code:exerciseCatalogueName',
  'th:activityCatalogueName',
  for (final code in ['de', 'es', 'hi', 'ru', 'th']) '$code:slotColumnReason',
  for (final code in ['de', 'es', 'hi', 'ru', 'th'])
    '$code:slotCapabilityStatus',
  'es:flashFileInfo',
  // Units and abbreviations.
  for (final code in ['de', 'fr', 'hi', 'th']) '$code:zoneRowsRange',
  for (final code in ['es', 'fr']) '$code:zoneRowsMinutes',
  for (final code in ['es', 'fr']) '$code:activityLengthMinutes',
  for (final code in ['es', 'fr']) '$code:activityPickerKcalPer30',
  for (final code in ['es', 'fr']) '$code:investigateSd1Sd224h',
  'de:supplementVitaminD25OHacb2ca',
  'fr:supplementVO2maxEst25e886',
  // Spelled the same in French.
  'fr:investigateStressScore',
  'fr:calmBreathingMinutesSemantic',
  'fr:sleepDetailSolRange',
};

Map<String, dynamic> _arb(String code) =>
    jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('no translated catalogue copies an English phrase by accident', () {
    final en = _arb('en');
    // Every catalogue on disk, so a new locale is checked without editing
    // this test.
    final codes = [
      for (final f in Directory('lib/l10n').listSync())
        if (RegExp(r'app_(\w+)\.arb$').firstMatch(f.path) case final m?)
          if (m[1] != 'en') m[1]!,
    ]..sort();
    expect(codes, containsAll(['de', 'es', 'fr', 'hi', 'ru', 'th', 'zh']));
    final copies = <String>[];
    for (final code in codes) {
      final arb = _arb(code);
      for (final key in en.keys) {
        if (key.startsWith('@')) continue;
        final english = en[key];
        if (english is! String || english.length <= 12) continue;
        if (!english.contains(' ')) continue;
        if (arb[key] != english) continue;
        if (_sameOnPurpose.contains('$code:$key')) continue;
        copies.add('$code:$key = $english');
      }
    }
    expect(copies, isEmpty);
  });
}
