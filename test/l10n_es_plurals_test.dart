import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  final es = lookupAppLocalizations(const Locale('es'));

  test('spanish nutrition counts agree at 1', () {
    expect(es.nutritionLoggedNoEnergy(1), '1 registrada · energía no consignada');
    expect(es.nutritionLoggedNoEnergy(2), '2 registradas · energía no consignada');
    expect(es.nutritionPartialFootnote(1), startsWith('1 parcial, excluido '));
    expect(es.nutritionPartialExcluded(1), startsWith('1 registrado pero parcial,'));
    expect(es.nutritionPartialExcluded(3), startsWith('3 registrados pero parciales,'));
  });

  test('spanish clock-not-set strings are translated', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(es.devicesTimeUnknown, isNot(en.devicesTimeUnknown));
    expect(es.devicesClockNotSetSub, isNot(en.devicesClockNotSetSub));
    expect(es.homeSyncedTimeUnknown, isNot(en.homeSyncedTimeUnknown));
  });
}
