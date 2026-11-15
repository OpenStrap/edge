// A metric's title and method text are written in English on its MetricSpec
// and translated on screen through `localizedText`, which looks the English up
// verbatim. Rewording the English silently disconnects it from every
// translation: on Oct 2 the HRV, HRV-stability and respiratory-rate method texts
// were rewritten to describe the shipped estimators, and from then on the
// Investigate screen showed them in English in every language, while the
// catalogue still held translations of the old wording.
//
// A text counts as untranslated when German, Russian and Thai (the three
// complete catalogues) all hand it back unchanged: no entry at all. A word that
// is legitimately the same in one of them, like "HRV" in German, still passes.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/display_text.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';

/// The same in every language, so there is nothing to translate.
const _universal = {'LF / HF'};

void main() {
  final locales = [
    for (final code in ['de', 'ru', 'th']) lookupAppLocalizations(Locale(code)),
  ];

  test('every metric title and method reaches the translations', () {
    final source =
        File('lib/ui2/screens/metric_detail.dart').readAsStringSync();
    final keys = [
      for (final m in RegExp(r"^  '([a-z0-9_]+)': MetricSpec\(", multiLine: true)
          .allMatches(source))
        m.group(1)!,
    ];
    expect(keys, isNotEmpty, reason: 'the spec table moved; update this test');

    final untranslated = <String>[];
    for (final key in keys) {
      final spec = specOf(key);
      for (final text in [
        spec.title,
        spec.method,
        if (spec.suppress != null) spec.suppress!,
        if (spec.suppressFix != null) spec.suppressFix!,
      ]) {
        if (text.isEmpty || _universal.contains(text)) continue;
        if (locales.every((l) => localizedText(l, text) == text)) {
          untranslated.add('$key: $text');
        }
      }
    }
    expect(untranslated, isEmpty);
  });
}
