// French was missing 350 strings outside the supplement catalogue, so whole
// screens (device picker, detected activities, step calibration, trends) fell
// back to English on an otherwise French app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  final fr = lookupAppLocalizations(const Locale('fr'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('french has every english string', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final french = arb('fr');
    final missing = [
      for (final k in arb('en').keys)
        if (!k.startsWith('@') && !french.containsKey(k)) k,
    ];
    expect(missing, isEmpty);
  });

  test('the supplement catalogue reads in french', () {
    expect(fr.supplementNeedNights(3), 'Encore 3 nuits nécessaires');
    expect(fr.supplementNeedDays(2), 'Portez le bracelet encore 2 jours pour débloquer');
    expect(fr.supplementNeedNights(1), 'Encore 1 nuit nécessaire');
    expect(fr.supplementNeedDays(1), 'Portez le bracelet encore 1 jour pour débloquer');
    expect(fr.supplementDidYouNapccbced, 'Avez-vous fait une sieste ?');
    // A pool length, the swim screens' "longueur", not a track lap.
    expect(fr.supplementLapsExport('4'), '4 longueurs');
    expect(fr.supplementLapsExport('1'), '1 longueur');
  });

  test('the newly covered screens read in french', () {
    expect(fr.devicePickerTitle, 'Connectez vos appareils');
    expect(fr.activityReviewTitle, 'Activités détectées');
    expect(fr.stepCalTitle, 'Calibrage des pas');
    expect(fr.stepCalTitle, isNot(en.stepCalTitle));
  });

  test('built-in activities are named in french, custom ones pass through',
      () {
    expect(fr.activityCatalogueName('krunning', 'Running'), 'Course à pied');
    expect(fr.activityCatalogueName('kcardio', 'Cardio'), 'Cardio');
    expect(fr.activityCatalogueName('custom', 'Mon sport'), 'Mon sport');
  });

  test('counts agree with their noun', () {
    expect(fr.stepCalBandSeen(1), 'pas vu par le bracelet');
    expect(fr.stepCalBandSeen(5), 'pas vus par le bracelet');
    expect(fr.homeFirstWeekSoFar(1), '1 jour enregistré jusqu’ici');
    expect(fr.homeFirstWeekSoFar(3), '3 jours enregistrés jusqu’ici');
    expect(fr.welcomeLabResultsWritten(1), '1 résultat d’analyse enregistré');
    expect(fr.devicesSensorLimit(2), contains('2 capteurs'));
  });
}
