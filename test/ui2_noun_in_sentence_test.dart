// German capitalises nouns. The "Using X for Y" caption on the metric detail
// lowercased the signal name for every locale, so a German user read
// "WHOOP wird für durchgehende herzfrequenz verwendet." Keeping it as written
// gave "für Durchgehende Herzfrequenz", a capitalised adjective mid-sentence,
// so the DE caption leads with the label.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

void main() {
  test('german keeps the noun case in the using caption', () {
    final l = lookupAppLocalizations(const Locale('de'));
    final name = nounInSentence(l, 'Durchgehende Herzfrequenz');
    expect(l.metricDetailUsingForX('WHOOP', name),
        'Durchgehende Herzfrequenz kommt von WHOOP.');
  });

  test('english still lowercases it', () {
    final l = lookupAppLocalizations(const Locale('en'));
    expect(nounInSentence(l, 'Resting heart rate'), 'resting heart rate');
    expect(nounInSentence(null, 'Resting heart rate'), 'resting heart rate');
  });
}
