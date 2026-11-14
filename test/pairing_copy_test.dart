// Two pieces of pairing copy that made claims the app cannot back:
//  - the strap note said "Both need ..." on a sheet that shows no table, so
//    "both" had nothing to point at;
//  - the Pebble 2 lead promised recovery, but the adapter decodes heart rate,
//    steps and sleep only, and readiness needs two inputs it does not provide.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _locales = ['en', 'de', 'es', 'fr', 'hi', 'ru', 'th', 'zh'];

// The word for "recovery" in each locale's own copy.
const _recovery = {
  'en': 'recovery',
  'de': 'Erholung',
  'es': 'recuperación',
  'fr': 'récupération',
  'hi': 'रिकवरी',
  'ru': 'восстановлен',
  'th': 'การฟื้นตัว',
  'zh': '恢复',
};

// Words that only make sense with a table in view.
const _both = {
  'en': 'Both',
  'de': 'beides',
  'es': 'Ambos',
  'fr': 'Les deux',
  'hi': 'दोनों',
  'ru': 'обоих',
  'th': 'ทั้งสองอย่าง',
  'zh': '两项',
};

Map<String, dynamic> _arb(String l) =>
    jsonDecode(File('lib/l10n/app_$l.arb').readAsStringSync()) as Map<String, dynamic>;

void main() {
  for (final l in _locales) {
    group(l, () {
      test('the strap note stands alone: no "both", and it names the switch', () {
        final note = _arb(l)['pairStrapNote'] as String;
        expect(note.contains(_both[l]!), isFalse,
            reason: '"$note" refers to a table this sheet does not show');
        // It quotes the localized name of the switch it tells the user to turn on.
        final switchName =
            RegExp('[“«„](.+?)[”»“]').firstMatch(note)?.group(1) ??
                RegExp('« (.+?) »').firstMatch(note)?.group(1);
        expect(switchName, isNotNull, reason: 'the note must name the switch: $note');
        expect(note, contains(switchName!));
      });

      test('the Pebble 2 lead does not promise recovery', () {
        final lead = _arb(l)['pairWearableLeadPebble'] as String;
        // Only the part before "Pebble 2 SE" describes what Pebble 2 provides.
        // What follows says what an SE (no heart-rate sensor) cannot give.
        final first = lead.split('Pebble 2 SE').first;
        expect(first.contains(_recovery[l]!), isFalse,
            reason: 'Pebble 2 supplies at most one readiness input: "$first"');
      });
    });
  }
}
