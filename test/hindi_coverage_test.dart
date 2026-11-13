// Hindi was missing 350 strings outside the supplement catalogue, so whole
// screens (device picker, detected activities, step calibration, trends) fell
// back to English on an otherwise Hindi app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  final hi = lookupAppLocalizations(const Locale('hi'));
  final en = lookupAppLocalizations(const Locale('en'));

  test('hindi has every english string outside the supplement catalogue', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final hindi = arb('hi');
    final missing = [
      for (final k in arb('en').keys)
        if (!k.startsWith('@') && !hindi.containsKey(k)) k,
    ];
    // Still to do: the supplement catalogue.
    missing.removeWhere((k) => k.startsWith('supplement'));
    expect(missing, isEmpty);
  });

  test('the newly covered screens read in hindi', () {
    expect(hi.devicePickerTitle, 'अपने डिवाइस कनेक्ट करें');
    expect(hi.activityReviewTitle, 'पहचानी गई गतिविधियाँ');
    expect(hi.stepCalTitle, 'कदम कैलिब्रेशन');
    expect(hi.stepCalTitle, isNot(en.stepCalTitle));
  });

  test('built-in activities are named in hindi, custom ones pass through',
      () {
    expect(hi.activityCatalogueName('krunning', 'Running'), 'दौड़');
    expect(hi.activityCatalogueName('custom', 'मेरा खेल'), 'मेरा खेल');
  });

  test('counts agree with their noun', () {
    expect(hi.homeFirstWeekSoFar(1), 'अब तक 1 दिन रिकॉर्ड हुआ');
    expect(hi.homeFirstWeekSoFar(3), 'अब तक 3 दिन रिकॉर्ड हुए');
    expect(hi.homeRecoveryStartsIn(1), 'रिकवरी 1 रात में शुरू होगी');
    expect(hi.devicesSensorLimit(2), contains('2 सेंसर'));
  });
}
