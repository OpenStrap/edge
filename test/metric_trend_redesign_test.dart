// Redesigned metric-detail + trends + stress surfaces — render tests for the
// PURE content widgets (no repo/AppState): the MetricScreen TrendBoard, the
// Heart / Wear / Oxygen day boards, the Steps board and StressDayContent.
// Each renders in BOTH palettes at phone width with sample data; overflow is
// asserted via takeException. Explicit pump durations (never blind
// pumpAndSettle — some design-system widgets animate on a loop).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/kit/kit.dart' show Ic;
import 'package:openstrap_edge/ui/screens/detail_cards.dart'
    show HeartDayContent, OxygenNightContent, WearDayContent;
import 'package:openstrap_edge/ui/screens/metric_screen.dart'
    show TrendBoard, trendBarLabel;
import 'package:openstrap_edge/ui/screens/screens.dart' show StepsDayContent;
import 'package:openstrap_edge/ui/stress/stress_screen.dart'
    show StressDayContent;

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void _phone(WidgetTester t, {double height = 844}) {
  t.view.physicalSize = Size(390, height);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

String _today() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// A representative /trend payload (week scale, one empty day).
Map<String, dynamic> _sampleTrend() {
  final now = DateTime.now().toUtc();
  final monday = DateTime.utc(now.year, now.month, now.day)
      .subtract(Duration(days: now.weekday - 1));
  return {
    'label': 'Resting HR',
    'unit': 'bpm',
    'summary': {'avg': 52.4, 'delta_vs_prev': -1.2, 'met_count': 5, 'total': 7},
    'buckets': [
      for (var i = 0; i < 7; i++)
        {
          't_start': monday.add(Duration(days: i)).millisecondsSinceEpoch ~/ 1000,
          't_end':
              monday.add(Duration(days: i + 1)).millisecondsSinceEpoch ~/ 1000,
          'value': i == 3 ? 0 : 50 + i,
          'has': i != 3,
        },
    ],
  };
}

Map<String, dynamic> _sampleHeartDay() => {
  'resting_hr': 52,
  'resting_hr_baseline': 54.0,
  'recovery': 78,
  'hrv': {'rmssd': 48, 'sdnn': 61, 'lf_hf': 1.4, 'cv': 8, 'baseline': 52.0},
  'zones': {
    'zone1_min': 40,
    'zone2_min': 22,
    'zone3_min': 12,
    'zone4_min': 6,
    'zone5_min': 1,
  },
  'nocturnal': {'sleeping_hr_avg': 47, 'dip_pct': 0.12, 'vs_baseline_bpm': -1},
  'stress': {'score': 34, 'si': 61, 'lf_hf': 1.4, 'level': 'low'},
  'illness': {'state': 'green', 'cusum': 0.4},
  'irregular': {'confidence': 0.8, 'flag': false, 'sd1': 22, 'sd2': 48},
  'irregular_24h': {
    'value': {'flag': false, 'sd1_sd2': 0.41, 'pnn_pct': 4.0},
  },
  'hrr': 28,
  'resp': {'value': 14.2},
  'spo2': {'odi_per_hour': 1.2},
  'skin_temp': {'value': 0.2},
  'baselines': {
    'resting_hr': {'baseline': 54, 'z': -0.6, 'status': 'trusted'},
    'hrv': {'baseline': 52, 'z': -0.4, 'status': 'provisional'},
  },
  'avg_hr': 68,
  'max_hr': 142,
  'hr': [
    for (var i = 0; i < 24; i++)
      {
        't': DateTime.now()
                .subtract(Duration(hours: 24 - i))
                .millisecondsSinceEpoch ~/
            1000,
        'v': 55 + (i % 7) * 6,
      },
  ],
};

Map<String, dynamic> _sampleOxygenNight() => {
  'spo2': {
    'odi_per_hour': 2.1,
    'dip_count': 14,
    'analyzed_hours': 6.8,
    'signal_coverage': 0.82,
    'trusted_coverage': 0.71,
    'burden_pct': 1.4,
    'mean_dip_pct': 2.2,
    'max_dip_pct': 4.1,
    'longest_dip_sec': 48,
    'severity_counts': {'mild': 10, 'moderate': 3, 'severe': 1},
    'reject_counts': {
      'non_positive': 3,
      'flatline': 12,
      'jump': 5,
      'ratio_outlier': 7,
    },
    'events': [
      {
        'start': 1700000000,
        'end': 1700000060,
        'duration_sec': 60,
        'peak_rise_pct': 3.4,
      },
    ],
    'series': [
      for (var i = 0; i < 30; i++)
        {'t': 1700000000 + i * 600, 'rise_pct': (i % 5) * 0.8},
    ],
  },
  'resp': {'value': 14.1},
  'sleep_window': {'start': 1700000000, 'end': 1700018000},
};

Map<String, dynamic> _sampleWearDay() => {
  'worn_min': 1290,
  'coverage_pct': 90,
  'hourly': [for (var i = 0; i < 24; i++) i == 8 ? 20.0 : 60.0],
  'first_on': 1700000000,
  'last_on': 1700080000,
  'segments': 2,
  'longest_off_min': 40,
};

Map<String, dynamic> _sampleStressDay() => {
  'stress': {'score': 34, 'si': 61, 'lf_hf': 1.4, 'rmssd': 46, 'level': 'low'},
  'sleep_stress': {
    'score': 22,
    'arousal_events': 3,
    'restless_min': 24,
    'restlessness': {'movement_bouts': 18, 'longest_still_min': 94},
  },
  'drivers': [
    {'label': 'Late training', 'detail': 'strain 16.2 after 8pm'},
  ],
  'hr': [
    for (var i = 0; i < 40; i++)
      {'t': 1700000000 + i * 1800, 'v': 58 + (i % 6) * 5},
  ],
};

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  group('TrendBoard (rebuilt MetricScreen hero)', () {
    testWidgets('average, delta, bars and bar taps render in both palettes', (
      t,
    ) async {
      _phone(t);
      for (final p in [kLightPalette, kDarkPalette]) {
        var tapped = -1;
        await t.pumpWidget(
          _host(
            TrendBoard(
              data: _sampleTrend(),
              title: 'Heart',
              icon: Ic.heart,
              metric: 'resting_hr',
              scale: 'week',
              accent: AppColors.coral,
              onTapBar: (i) => tapped = i,
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 900));
        // The BigStat average + its unit + the week hint.
        expect(find.text('52.4'), findsOneWidget);
        expect(find.text('bpm'), findsWidgets);
        expect(find.text('Tap a day for the full breakdown'), findsOneWidget);
        // met-count chip from the summary.
        expect(find.text('5/7 met'), findsOneWidget);
        // Weekday labels come from trendBarLabel.
        expect(find.text('Mon'), findsOneWidget);
        await t.tap(find.text('Mon'));
        await t.pump(const Duration(milliseconds: 300));
        expect(tapped, 0);
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('an all-empty period says so instead of drawing bars', (
      t,
    ) async {
      _phone(t);
      final data = _sampleTrend();
      data['summary'] = null;
      data['buckets'] = [
        for (final b in (data['buckets'] as List))
          {...(b as Map), 'value': 0, 'has': false},
      ];
      await t.pumpWidget(
        _host(
          TrendBoard(
            data: data,
            title: 'Heart',
            icon: Ic.heart,
            metric: 'resting_hr',
            scale: 'week',
            accent: AppColors.coral,
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 700));
      expect(find.text('No data in this period'), findsOneWidget);
      expect(find.text('—'), findsOneWidget); // honest em-dash average
      expect(t.takeException(), isNull);
    });

    test('trendBarLabel maps scales to weekday / week-index / month', () {
      final ts = DateTime.utc(2026, 7, 6).millisecondsSinceEpoch ~/ 1000; // Mon
      expect(trendBarLabel('week', 0, {'t_start': ts}), 'Mon');
      expect(trendBarLabel('month', 2, {'t_start': ts}), 'W3');
      expect(trendBarLabel('quarter', 0, {'t_start': ts}), 'Jul');
    });
  });

  group('HeartDayContent (heart domain board)', () {
    testWidgets('hero + bento + watches render in both palettes', (t) async {
      _phone(t, height: 4200);
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(HeartDayContent(data: _sampleHeartDay(), date: _today()),
              palette: p),
        );
        await t.pump(const Duration(milliseconds: 1200));
        // Recovery hero BigStat figure.
        expect(find.text('78'), findsWidgets);
        expect(find.text('HRV-based recovery'), findsOneWidget);
        expect(find.text('RESTING HR'), findsWidgets);
        // Cardiac bento numbers.
        expect(find.text('48'), findsWidgets); // HRV rmssd
        expect(find.text('47'), findsWidgets); // sleeping HR
        expect(find.text('dip 12%'), findsOneWidget);
        // Honest watches present.
        expect(find.text('All clear'), findsOneWidget);
        expect(find.text('Rhythm looks regular'), findsOneWidget);
        expect(find.text('Normal'), findsWidgets); // 24/7 rhythm screen
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('no-baseline illness watch shows the honest building state', (
      t,
    ) async {
      _phone(t, height: 4200);
      final d = _sampleHeartDay();
      d['illness'] = {
        'state': 'green',
        'note': 'need_baseline:have=3,need=7',
      };
      d['irregular'] = {'confidence': 0};
      await t.pumpWidget(
        _host(HeartDayContent(data: d, date: _today())),
      );
      await t.pump(const Duration(milliseconds: 1000));
      expect(find.text('Need 4 more nights'), findsOneWidget);
      expect(find.text('Listening for your rhythm'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('WearDayContent (wear domain board)', () {
    testWidgets('worn hero + coverage gauge + on/off tiles in both palettes', (
      t,
    ) async {
      _phone(t, height: 2400);
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(WearDayContent(data: _sampleWearDay(), date: _today()),
              palette: p),
        );
        await t.pump(const Duration(milliseconds: 900));
        expect(find.text('21h 30m'), findsOneWidget);
        expect(find.text('90% of the day'), findsOneWidget);
        expect(find.text('90%'), findsWidgets); // gauge value
        expect(find.text('WEAR STRETCHES'), findsOneWidget);
        expect(find.text('2'), findsWidgets);
        expect(find.text('0h 40m'), findsWidgets); // longest off
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('a not-worn day renders the honest quiet state', (t) async {
      _phone(t);
      await t.pumpWidget(
        _host(WearDayContent(data: const {'worn_min': 0}, date: _today())),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Not worn on this day'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('OxygenNightContent (oxygen domain board)', () {
    testWidgets('ODI hero + verdict/severity tiles render in both palettes', (
      t,
    ) async {
      _phone(t, height: 3600);
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(OxygenNightContent(data: _sampleOxygenNight(), date: _today()),
              palette: p),
        );
        await t.pump(const Duration(milliseconds: 1200));
        expect(find.text('2.1'), findsWidgets); // ODI hero
        expect(find.text('82%'), findsWidgets); // signal coverage gauge
        expect(find.text('Usable'), findsOneWidget); // verdict tile
        expect(find.text('Mild'), findsOneWidget); // severity tile
        expect(find.text('REL'), findsOneWidget); // honesty tag: relative-only
        expect(t.takeException(), isNull);
      }
    });
  });

  group('StepsDayContent (steps domain board)', () {
    testWidgets('goal gauge + week of rings + rows in both palettes', (
      t,
    ) async {
      _phone(t, height: 2200);
      for (final p in [kLightPalette, kDarkPalette]) {
        var goals = 0, cals = 0;
        await t.pumpWidget(
          _host(
            StepsDayContent(
              steps: 8412,
              goal: 10000,
              weekValues: const [9000, 12000, null, 4000, 8000, 10000, 8412],
              weekLabels: const ['M', 'T', 'W', 'T', 'F', 'S', 'S'],
              onSetGoal: () => goals++,
              onCalibrate: () => cals++,
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 1000));
        expect(find.text('8412'), findsOneWidget);
        expect(find.text('goal 10000'), findsOneWidget);
        expect(find.text('84%'), findsOneWidget); // of goal gauge
        expect(find.text('THIS WEEK'), findsOneWidget);
        expect(find.text('EST'), findsOneWidget); // honesty tag
        await t.tap(find.text('Daily step goal'));
        await t.tap(find.text('Calibrate steps'));
        await t.pump(const Duration(milliseconds: 300));
        expect(goals, 1);
        expect(cals, 1);
        expect(t.takeException(), isNull);
      }
    });
  });

  group('StressDayContent (stress domain board)', () {
    testWidgets('gauge hero + word + bento + arousal in both palettes', (
      t,
    ) async {
      _phone(t, height: 3200);
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(StressDayContent(data: _sampleStressDay(), date: _today()),
              palette: p),
        );
        await t.pump(const Duration(milliseconds: 1200));
        expect(find.text('34'), findsWidgets); // score in the gauge
        expect(find.text('Low'), findsWidgets); // level word chip
        expect(find.text('61'), findsWidgets); // Baevsky SI tile
        expect(find.text('1.4'), findsWidgets); // LF/HF tile
        expect(find.text('22'), findsWidgets); // sleep-stress tile
        expect(find.text('3 events · 24m'), findsOneWidget);
        expect(find.text('18'), findsWidgets); // restlessness bouts
        expect(find.text('Late training'), findsOneWidget); // driver row
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('relief framing follows the band (calm vs high)', (t) async {
      _phone(t, height: 2600);
      final calm = _sampleStressDay();
      calm['stress'] = <String, dynamic>{
        ...calm['stress'] as Map,
        'score': 12,
        'level': null,
      };
      await t.pumpWidget(_host(StressDayContent(data: calm, date: _today())));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('Calm'), findsOneWidget);
      expect(
        find.text('Your system is settled — a good day to take on load.'),
        findsOneWidget,
      );

      final high = _sampleStressDay();
      high['stress'] = <String, dynamic>{
        ...high['stress'] as Map,
        'score': 82,
        'level': null,
      };
      await t.pumpWidget(_host(StressDayContent(data: high, date: _today())));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('High'), findsOneWidget);
      expect(
        find.text(
          'High sympathetic load — favour easy movement and an early night.',
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  });
}
