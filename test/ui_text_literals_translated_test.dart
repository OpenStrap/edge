// `uiText`, `localizedText` and `presentationText` translate English text by
// looking it up verbatim. A literal handed to one of them with no entry behind
// it is shown in English in every language, and nothing fails: the ChatGPT
// sign-in flow, including its data-sharing notice and the OpenAI terms step,
// shipped that way.
//
// This reads every literal passed to those helpers under lib/ and requires each
// one to translate in at least one of German, Russian and Thai (the complete
// catalogues). A word that is legitimately the same in one language still
// passes; a missing entry fails in all three at once.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/display_text.dart';
import 'package:openstrap_edge/l10n/presentation_text.dart';

final _call = RegExp(
  r"""\b(uiText|localizedText|presentationText)\(\s*[\w.?!]+(?:\([^()]*\))?[\w.?!]*\s*,\s*((?:'(?:[^'\\]|\\.)*'\s*|"(?:[^"\\]|\\.)*"\s*)+)\)""",
);
final _piece =
    RegExp(r"'((?:[^'\\]|\\.)*)'" '|' r'"((?:[^"\\]|\\.)*)"');

void main() {
  final locales = [
    for (final code in ['de', 'ru', 'th']) lookupAppLocalizations(Locale(code)),
  ];

  test('every literal handed to the translation helpers has a translation',
      () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.contains('/l10n/'));
    var checked = 0;
    final missing = <String>[];
    for (final file in files) {
      final src = file.readAsStringSync();
      for (final m in _call.allMatches(src)) {
        final text = [
          for (final p in _piece.allMatches(m.group(2)!)) p.group(1) ?? p.group(2)!,
        ].join().replaceAll(r"\'", "'").replaceAll(r'\"', '"');
        // Interpolated text can't be looked up verbatim; it is translated
        // through its own message, not through this map.
        if (text.contains(r'$') || text.trim().isEmpty) continue;
        checked++;
        String tr(AppLocalizations l) => m.group(1) == 'presentationText'
            ? presentationText(l, text)
            : localizedText(l, text);
        if (locales.every((l) => tr(l) == text)) {
          final line = src.substring(0, m.start).split('\n').length;
          missing.add('${file.path}:$line  $text');
        }
      }
    }
    expect(checked, greaterThan(20), reason: 'the scan found too little');
    expect(missing, isEmpty);
  });
}
