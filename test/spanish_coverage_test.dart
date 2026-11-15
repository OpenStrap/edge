// Spanish was missing 321 strings outside the supplement catalogue, so whole
// screens (device picker, detected activities, step calibration, trends) fell
// back to English on an otherwise Spanish app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  final es = lookupAppLocalizations(const Locale('es'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('spanish has every english string outside the two known gaps', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final spanish = arb('es');
    final missing = [
      for (final k in arb('en').keys)
        if (!k.startsWith('@') && !spanish.containsKey(k)) k,
    ];
    // Still to do: the supplement catalogue. The WHOOP firmware warning is
    // added by its own change.
    missing.removeWhere((k) =>
        k.startsWith('supplement') || k.startsWith('whoopFirmwareWarning'));
    expect(missing, isEmpty);
  });

  test('the newly covered screens read in spanish', () {
    expect(es.devicePickerTitle, 'Conecta tus dispositivos');
    expect(es.activityReviewTitle, 'Actividades detectadas');
    expect(es.stepCalTitle, 'Calibración de pasos');
    expect(es.stepCalTitle, isNot(en.stepCalTitle));
  });

  test('built-in activities are named in spanish, custom ones pass through',
      () {
    expect(es.activityCatalogueName('krunning', 'Running'), 'Carrera');
    expect(es.activityCatalogueName('kcardio', 'Cardio'), 'Cardio');
    expect(es.activityCatalogueName('custom', 'Mi deporte'), 'Mi deporte');
  });

  test('counts agree with their noun', () {
    expect(es.stepCalBandSeen(1), 'paso visto por la banda');
    expect(es.stepCalBandSeen(5), 'pasos vistos por la banda');
    expect(es.homeFirstWeekSoFar(1), '1 día registrado hasta ahora');
    expect(es.homeFirstWeekSoFar(3), '3 días registrados hasta ahora');
    expect(es.welcomeLabResultsWritten(1), '1 resultado de laboratorio escrito');
    expect(es.devicesSensorLimit(2), contains('2 sensores'));
  });
}
