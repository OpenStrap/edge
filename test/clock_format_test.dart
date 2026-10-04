// The 12/24-hour display preference. One formatter for every clock time on
// screen, so a bedtime cannot read `22:40` on Home and `10:40 PM` two screens
// away — and so the choice the user makes in Settings reaches all of them.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/state/clock_format.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(ClockFormatController.debugReset);

  group('formatClock', () {
    test('24-hour pads the hour and has no suffix', () {
      ClockFormatController.seed(ClockFormat.h24);
      expect(formatClock(0, 0), '00:00');
      expect(formatClock(7, 5), '07:05');
      expect(formatClock(12, 0), '12:00');
      expect(formatClock(23, 59), '23:59');
    });

    test('12-hour maps midnight and noon to 12', () {
      ClockFormatController.seed(ClockFormat.h12);
      expect(formatClock(0, 0), '12:00 AM');
      expect(formatClock(7, 5), '7:05 AM');
      expect(formatClock(12, 0), '12:00 PM');
      expect(formatClock(23, 59), '11:59 PM');
    });

    test("12-hour uses the app locale's AM/PM and order", () async {
      ClockFormatController.seed(ClockFormat.h12);
      Future<void> bind(String lang) async => bindClockLocalizations(
          await GlobalMaterialLocalizations.delegate.load(Locale(lang)));

      await bind('zh');
      expect(formatClock(7, 30), '上午 7:30');
      expect(formatClock(19, 30), '下午 7:30');
      await bind('es');
      expect(formatClock(19, 30), '7:30 p. m.');
      await bind('en');
      expect(formatClock(19, 30), '7:30 PM');
    });

    test('minute of day wraps rather than printing an impossible hour', () {
      ClockFormatController.seed(ClockFormat.h24);
      expect(formatClockMinute(24 * 60 + 30), '00:30');
      expect(formatClockMinute(-30), '23:30');
    });

    test('the journal formatter follows the same choice', () {
      final c = ClockFormatController.seed(ClockFormat.h12);
      expect(formatMinuteOfDay(20 * 60 + 30), '8:30 PM');
      c.setFormat(ClockFormat.h24);
      expect(formatMinuteOfDay(20 * 60 + 30), '20:30');
    });
  });

  group('system', () {
    test('follows the OS setting, with or without a controller', () {
      final binding = TestWidgetsFlutterBinding.instance;
      addTearDown(binding.platformDispatcher
          .clearAlwaysUse24HourTestValue);

      binding.platformDispatcher.alwaysUse24HourFormatTestValue = true;
      expect(formatClock(19, 30), '19:30', reason: 'no controller yet');
      ClockFormatController.seed(ClockFormat.system);
      expect(formatClock(19, 30), '19:30');

      binding.platformDispatcher.alwaysUse24HourFormatTestValue = false;
      expect(formatClock(19, 30), '7:30 PM');
    });

    test('an explicit choice overrides the OS', () {
      final binding = TestWidgetsFlutterBinding.instance;
      addTearDown(binding.platformDispatcher
          .clearAlwaysUse24HourTestValue);
      binding.platformDispatcher.alwaysUse24HourFormatTestValue = true;

      ClockFormatController.seed(ClockFormat.h12);
      expect(formatClock(19, 30), '7:30 PM');
    });
  });

  group('time picker', () {
    Future<void> openPicker(WidgetTester tester, {required bool h12}) async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('de'),
        supportedLocales: const [Locale('de')],
        localizationsDelegates: [
          ClockMaterialLocalizationsDelegate(twelveHour: h12),
          ...GlobalMaterialLocalizations.delegates,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: !h12),
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTimePicker(
                context: context,
                initialTime: const TimeOfDay(hour: 22, minute: 0)),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('12-hour in German gets an AM/PM dial, still in German',
        (tester) async {
      await openPicker(tester, h12: true);
      expect(find.text('PM'), findsOneWidget);
      expect(find.text('10'), findsWidgets);
      expect(find.text('Abbrechen'), findsOneWidget);
    });

    testWidgets('24-hour in German keeps the 24-hour dial', (tester) async {
      await openPicker(tester, h12: false);
      expect(find.text('PM'), findsNothing);
      expect(find.text('22'), findsWidgets);
    });
  });

  group('ClockFormatController', () {
    test('persists the choice and bootstraps it back', () async {
      final c = await ClockFormatController.bootstrap();
      expect(c.format, ClockFormat.system, reason: 'nothing stored yet');
      await c.setFormat(ClockFormat.h12);

      final again = await ClockFormatController.bootstrap();
      expect(again.format, ClockFormat.h12);
    });

    test('an unknown stored value lands on system', () async {
      SharedPreferences.setMockInitialValues({'clock_format': 'h36'});
      final c = await ClockFormatController.bootstrap();
      expect(c.format, ClockFormat.system);
    });

    test('cycles system → 24-hour → 12-hour → system and notifies', () async {
      final c = ClockFormatController.seed(ClockFormat.system);
      var notified = 0;
      c.addListener(() => notified++);
      await c.cycle();
      expect(c.format, ClockFormat.h24);
      await c.cycle();
      expect(c.format, ClockFormat.h12);
      await c.cycle();
      expect(c.format, ClockFormat.system);
      expect(notified, 3);
    });
  });
}
