// The cycle prediction lead clause is shown for "one day away" and "one day
// overdue" at every cycle boundary, so a plain "{days} days" placeholder read
// "in 1 days" / "1 days late" in most locales.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  AppLocalizations l(String code) => lookupAppLocalizations(Locale(code));

  test('cycle lead clauses use the singular for one day', () {
    final expected = <String, List<String>>{
      'en': ['in 1 day · ', '1 day late · ', '1 day past the end of it · '],
      'de': [
        'in 1 Tag · ',
        '1 Tag überfällig · ',
        '1 Tag nach Ende des Zeitraums · ',
      ],
      'fr': ['dans 1 jour · ', '1 jour de retard · ', '1 jour après sa fin · '],
      'es': [
        'en 1 día · ',
        '1 día de retraso · ',
        '1 día después del final · ',
      ],
    };
    expected.forEach((code, want) {
      final s = l(code);
      expect(
        [s.cycleLeadInDays(1), s.cycleLeadDaysLate(1), s.cyclePastEndOfIt(1)],
        want,
        reason: code,
      );
    });
    expect(l('hi').cycleLeadInDays(1), '1 दिन में · ');
  });

  test('cycle lead clauses keep the plural for more than one day', () {
    final en = l('en');
    expect(en.cycleLeadInDays(3), 'in 3 days · ');
    expect(en.cycleLeadDaysLate(2), '2 days late · ');
    expect(en.cyclePastEndOfIt(4), '4 days past the end of it · ');
    expect(l('fr').cycleLeadInDays(2), 'dans 2 jours · ');
    expect(l('de').cycleLeadInDays(2), 'in 2 Tagen · ');
    expect(l('hi').cycleLeadInDays(2), '2 दिनों में · ');
  });
}
