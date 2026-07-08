// Feed-logic tests for Today's steps week-of-rings (stepWeekRingData) —
// goal-relative fills aligned Monday→Sunday with today's index + live
// fold-in and honest nulls for missing/future days.
// (The Body week-load wheel this file used to also cover was removed along
// with its screen usage — the wheel duplicated the strain figure already
// shown once in the strain detail hero.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/design/domains.dart';
import 'package:openstrap_edge/ui/design/ring_week.dart';
import 'package:openstrap_edge/ui/today/today_screen.dart'
    show stepWeekRingData;

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void _phone(WidgetTester t) {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

void main() {
  group('stepWeekRingData (Today steps week-of-rings feed)', () {
    test('goal-relative Mon→Sun fills with honest nulls', () {
      final ring = stepWeekRingData(
        weekSteps: const [5000.0, null, 12000.0, 2500.0, null, null, null],
        goal: 10000,
        todayWeekday: DateTime.friday, // 5 → index 4
      );
      expect(ring.values.length, 7);
      expect(ring.values[0], closeTo(0.5, 1e-9));
      expect(ring.values[1], isNull);
      expect(ring.values[2], 1.0); // clamped at goal
      expect(ring.values[3], closeTo(0.25, 1e-9));
      expect(ring.values[4], isNull); // today: no series row, no live steps
      expect(ring.values[5], isNull);
      expect(ring.values[6], isNull); // future day stays empty
      expect(ring.todayIndex, 4);
    });

    test('today folds in the live figure (never lags the steps tile)', () {
      final ring = stepWeekRingData(
        weekSteps: const [8000.0, null, null, null, null, null, null],
        goal: 10000,
        todayWeekday: DateTime.wednesday, // index 2
        todaySteps: 4000,
      );
      expect(ring.todayIndex, 2);
      expect(ring.values[2], closeTo(0.4, 1e-9));
      // A larger series value is never shrunk by a smaller live figure.
      final ring2 = stepWeekRingData(
        weekSteps: const [null, null, 9000.0, null, null, null, null],
        goal: 10000,
        todayWeekday: DateTime.wednesday,
        todaySteps: 4000,
      );
      expect(ring2.values[2], closeTo(0.9, 1e-9));
    });

    test('short series pads to 7 rings; bad goal falls back safely', () {
      final ring = stepWeekRingData(
        weekSteps: const [10000.0, 5000.0],
        goal: 0, // guarded → default 10000
        todayWeekday: DateTime.monday,
      );
      expect(ring.values.length, 7);
      expect(ring.values[0], 1.0);
      expect(ring.values[1], closeTo(0.5, 1e-9));
      expect(ring.values.sublist(2), everyElement(isNull));
      expect(ring.todayIndex, 0);
    });

    testWidgets('feeds RingWeek with default Monday-first labels', (t) async {
      _phone(t);
      final ring = stepWeekRingData(
        weekSteps: const [8000.0, 12000.0, null, 6000.0, null, null, null],
        goal: 10000,
        todayWeekday: DateTime.thursday,
        todaySteps: 6500,
      );
      await t.pumpWidget(
        _host(
          RingWeek(
            values: ring.values,
            todayIndex: ring.todayIndex,
            color: DomainAccent.steps,
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('M'), findsOneWidget);
      expect(find.text('W'), findsOneWidget);
      expect(find.text('F'), findsOneWidget);
      expect(find.text('T'), findsNWidgets(2));
      expect(find.text('S'), findsNWidgets(2));
      expect(t.takeException(), isNull);
    });
  });
}
