// Feed-logic tests for the two week views the redesign surfaces:
//   • Body's week-load wheel (BodyWeekLoadHero → weekLoadWheelData +
//     WeekLoadWheelTile) — must show ALL 7 Mon→Sun segments with per-day
//     labels and NO duplicate strain BigStat (the strain figure lives once,
//     in the strain detail hero).
//   • Today's steps week-of-rings (stepWeekRingData) — goal-relative fills
//     aligned Monday→Sunday with today's index + live fold-in and honest
//     nulls for missing/future days.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/design/big_stat.dart';
import 'package:openstrap_edge/ui/design/domains.dart';
import 'package:openstrap_edge/ui/design/radial_heatmap.dart';
import 'package:openstrap_edge/ui/design/ring_week.dart';
import 'package:openstrap_edge/ui/screens/screens.dart'
    show WeekLoadWheelTile, weekLoadWheelData;
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

/// A /trend week payload for a fixed Mon→Sun week (2026-06-29 is a Monday),
/// mirroring the repository shape: {value, has, t_start, t_end} per bucket.
Map<String, dynamic> _weekTrend(List<double?> strain) {
  final mon = DateTime.utc(2026, 6, 29);
  return {
    'buckets': [
      for (var i = 0; i < 7; i++)
        {
          'value': strain[i] ?? 0.0,
          'has': strain[i] != null,
          't_start':
              mon.add(Duration(days: i)).millisecondsSinceEpoch ~/ 1000,
          't_end':
              mon.add(Duration(days: i + 1)).millisecondsSinceEpoch ~/ 1000,
        },
    ],
  };
}

void main() {
  group('weekLoadWheelData (Body week-load wheel feed)', () {
    test('maps a Mon→Sun payload to 7 segments with per-day labels', () {
      final wheel = weekLoadWheelData(
        _weekTrend(const [10.5, null, 21.0, 5.25, null, null, 30.0]),
      );
      expect(wheel.values.length, 7);
      expect(wheel.labels, [
        'Mon',
        'Tue',
        'Wed',
        'Thu',
        'Fri',
        'Sat',
        'Sun',
      ]);
      expect(wheel.values[0], closeTo(0.5, 1e-9)); // 10.5 / 21
      expect(wheel.values[1], isNull); // has:false stays honest null
      expect(wheel.values[2], 1.0);
      expect(wheel.values[3], closeTo(0.25, 1e-9));
      expect(wheel.values[4], isNull);
      expect(wheel.values[6], 1.0); // clamped, never > 1
    });

    test('empty / missing payloads yield no segments (hero hides)', () {
      expect(weekLoadWheelData(null).values, isEmpty);
      expect(weekLoadWheelData(const {'buckets': []}).values, isEmpty);
    });

    test('one loaded day still yields the full 7-segment week', () {
      final wheel = weekLoadWheelData(
        _weekTrend(const [12.0, null, null, null, null, null, null]),
      );
      expect(wheel.values.length, 7);
      expect(wheel.values.whereType<double>().length, 1);
      expect(wheel.labels.length, 7);
    });
  });

  group('WeekLoadWheelTile (Body hero presentation)', () {
    testWidgets('renders the full-week heatmap and NO strain BigStat', (
      t,
    ) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        _phone(t);
        final wheel = weekLoadWheelData(
          _weekTrend(const [10.5, null, 18.0, null, 6.0, null, null]),
        );
        await t.pumpWidget(
          _host(
            WeekLoadWheelTile(values: wheel.values, labels: wheel.labels),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 1100));
        final heat = t.widget<RadialHeatmap>(find.byType(RadialHeatmap));
        expect(heat.values.length, 7);
        expect(heat.labels, hasLength(7));
        // The dedupe: no strain number in the hero — the figure lives once,
        // in the strain detail below.
        expect(find.byType(BigStat), findsNothing);
        expect(find.textContaining('latest strain'), findsNothing);
        expect(find.textContaining('of 21'), findsNothing);
        expect(find.text('WEEK LOAD'), findsOneWidget);
        expect(t.takeException(), isNull, reason: 'palette $p');
      }
    });
  });

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
