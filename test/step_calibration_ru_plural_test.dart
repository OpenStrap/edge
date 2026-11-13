// Russian inflects the noun by count; the calibration strings carry the count
// so 1, 2 and 5 each read correctly.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  final ru = lookupAppLocalizations(const Locale('ru'));

  test('the band counter label agrees with its number', () {
    expect(ru.stepCalBandSeen(1), 'шаг по данным браслета');
    expect(ru.stepCalBandSeen(2), 'шага по данным браслета');
    expect(ru.stepCalBandSeen(5), 'шагов по данным браслета');
  });

  test('the gait result inflects both counts and names no single gait', () {
    final one = ru.stepCalDoneGait(1, 2, 10);
    expect(one, contains('1 шаг,'));
    expect(one, contains('2 шага'));
    expect(ru.stepCalDoneGait(100, 112, -11), contains('100 шагов'));
    expect(one, isNot(contains('ходьба')));
  });

  test('the calibrated row inflects the run count', () {
    expect(ru.stepCalCalibrated(1), endsWith('1 замер'));
    expect(ru.stepCalCalibrated(3), endsWith('3 замера'));
    expect(ru.stepCalCalibrated(5), endsWith('5 замеров'));
  });
}
