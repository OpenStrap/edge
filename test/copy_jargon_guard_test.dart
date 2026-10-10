// One name per score, plain words everywhere else. The 0-100 morning score
// is "Recovery", and method names, raw-signal acronyms and statistics words
// live only on the method sheet, Nerd stats and vendor descriptions. This
// fails when a copy edit brings one of them back into user-facing text.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Method sheet (supplement*), Nerd stats (investigate*) and strings mapped
// from the protocol/analytics packages (presentation*) keep technical names.
const _allowedPrefixes = ['investigate', 'supplement', 'presentation'];
// Names another vendor's score; that vendor calls it Readiness.
const _allowedKeys = {'wearableScoreReadiness'};

final _jargon = RegExp(
  r'\b(Readiness|readiness|RMSSD|SDNN|TRIMP|baselines?|Baselines?|'
  r'z-scores?|percentiles?|Baevsky|Lipponen|Tarvainen|Keytel|Mifflin|'
  r'derived?|MET)\b',
);

Map<String, String> _messages(String path) {
  final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in raw.entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };
}

bool _allowed(String key) =>
    _allowedKeys.contains(key) ||
    _allowedPrefixes.any((p) => key.startsWith(p));

void main() {
  test('en user-facing copy has no jargon outside the allowlist', () {
    final hits = <String>[
      for (final e in _messages('lib/l10n/app_en.arb').entries)
        if (!_allowed(e.key) && _jargon.hasMatch(e.value))
          '${e.key}: ${_jargon.firstMatch(e.value)!.group(0)}',
    ];
    expect(hits, isEmpty);
  });

  test('ru user-facing copy has no Latin jargon outside the allowlist', () {
    final latin = RegExp(r'\b(RMSSD|SDNN|TRIMP|Baevsky|Keytel|Mifflin|MET)\b');
    final hits = <String>[
      for (final e in _messages('lib/l10n/app_ru.arb').entries)
        if (!_allowed(e.key) && latin.hasMatch(e.value))
          '${e.key}: ${latin.firstMatch(e.value)!.group(0)}',
    ];
    expect(hits, isEmpty);
  });

  test('the guard catches what it is for', () {
    for (final s in [
      'Your Readiness is 70',
      'above your baseline',
      'RMSSD fell',
      'TRIMP today',
      '6.0 MET',
      'every derived day',
    ]) {
      expect(_jargon.hasMatch(s), isTrue, reason: s);
    }
    expect(_jargon.hasMatch('Recovery, Strain, your usual'), isFalse);
  });
}
