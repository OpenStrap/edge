// Notification bodies that carry a number cannot hit the exact-match
// dictionary, so each one needs a parse-back in localizedNotificationText.
// Without one the lock screen showed a translated title over an English body
// (the overnight battery forecast, wind-down, the idle-workout nudge), and the
// forecast's rate kept its '.' decimal in locales that use ','.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/display_text.dart';
import 'package:openstrap_edge/notify/battery_forecast.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/workout_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => ClockFormatController.seed(ClockFormat.h24));
  tearDown(ClockFormatController.debugReset);

  AppLocalizations l(String code) => lookupAppLocalizations(Locale(code));

  final wakeAt = DateTime(2026, 10, 18, 7, 0);
  BatteryForecast forecast({required DateTime empty, double? atWake}) =>
      BatteryForecast(
        samplesUsed: 6,
        spanUsed: const Duration(hours: 3),
        drainPctPerHour: 4.1,
        currentPct: 20,
        predictedPctAtWake: atWake,
        predictedEmptyAt: empty,
      );

  // Built inside each test: the clock text reads the controller seeded in
  // setUp, which has not run yet when main() itself executes.
  Map<String, String> bodies() => {
    'forecast before wake': BatteryForecaster.describe(
      forecast(empty: DateTime(2026, 10, 18, 3, 10)),
      wakeAt: wakeAt,
    ),
    'forecast inside reserve': BatteryForecaster.describe(
      forecast(empty: DateTime(2026, 10, 18, 8, 30), atWake: 4),
      wakeAt: wakeAt,
    ),
    'forecast after wake': BatteryForecaster.describe(
      forecast(empty: DateTime(2026, 10, 18, 11, 0), atWake: 40),
      wakeAt: wakeAt,
    ),
    'wind-down': NotificationCenter.windDownBody(1360.0),
    'idle workout': WorkoutController.idleNudgeBody(20),
  };

  test('every numbered body is translated, in every shipped locale', () {
    for (final code in ['de', 'es', 'fr', 'hi', 'ru', 'zh']) {
      for (final e in bodies().entries) {
        expect(e.value, isNotEmpty, reason: e.key);
        expect(localizedNotificationText(l(code), e.value),
            isNot(e.value), reason: '$code ${e.key}');
      }
    }
  });

  test('the numbers survive, with the locale decimal separator', () {
    final ru = l('ru');
    final before = localizedNotificationText(ru, bodies()['forecast before wake']!);
    expect(before, contains('4,1'));
    expect(before, isNot(contains('4.1')));
    expect(before, contains('03:10'));
    final reserve =
        localizedNotificationText(ru, bodies()['forecast inside reserve']!);
    expect(reserve, contains('08:30'));
    expect(reserve, contains('4%'));
    expect(localizedNotificationText(ru, bodies()['wind-down']!),
        contains('22:40'));
    expect(localizedNotificationText(ru, bodies()['idle workout']!),
        contains('20'));
    expect(localizedNotificationText(l('de'), bodies()['forecast after wake']!),
        contains('4,1'));
  });

  test('English passes through untouched', () {
    for (final body in bodies().values) {
      expect(localizedNotificationText(l('en'), body), body);
    }
  });

  test('the titles over these bodies are translated too', () {
    for (final code in ['de', 'es', 'fr', 'hi', 'ru', 'zh']) {
      for (final title in [
        'Charge your strap before bed',
        'Wind down',
        'Still working out?',
      ]) {
        expect(localizedNotificationText(l(code), title), isNot(title),
            reason: '$code $title');
      }
    }
  });
}
