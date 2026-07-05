// Widget tests for the revamped CORE screens' pure content (Today / Workouts /
// Sleep) on the design system, plus the AiSummaryCard slot. Each renders in
// BOTH palettes with sample data; explicit pump durations (never blind
// pumpAndSettle — some kit widgets repeat).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/today/ai_summary_card.dart';
import 'package:openstrap_edge/ui/today/today_screen.dart' show TodayVitals;
import 'package:openstrap_edge/ui/workouts/workouts_screen.dart'
    show WorkoutFeedCard, TrainingSummaryCard, WorkoutDetailContent;
import 'package:openstrap_edge/ui/sleep/sleep_detail_screen.dart'
    show SleepNightContent;

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(
      body: SingleChildScrollView(child: child),
    ),
  );
}

/// A representative /today payload (metric envelopes, hrv/stress/spo2 blocks).
Map<String, dynamic> _sampleToday() => {
  'daily': {
    'readiness': {'value': 82, 'confidence': 0.9},
    'strain': {'value': 12.4, 'confidence': 0.8},
    'resting_hr': {'value': 52, 'confidence': 0.9},
    'resting_hr_delta': {'value': -2.0, 'confidence': 0.9},
    'calories': {'value': 640, 'confidence': 0.6, 'tier': 'estimate'},
    'steps': {'value': 8412, 'confidence': 0.5},
    'wear_min': {'value': 1380, 'confidence': 1.0},
  },
  'sleep': {
    'duration_min': {'value': 462, 'confidence': 0.9},
    'need_min': {'value': 480, 'confidence': 0.9},
  },
  'hrv': {'rmssd': 48.0, 'confidence': 0.8, 'baseline': 52.0},
  'stress': {'score': 34},
  'spo2': {'odi_per_hour': 1.2, 'confidence': 0.5},
};

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  group('AiSummaryCard', () {
    testWidgets('empty state: greeting + graceful placeholder + generate cue', (
      t,
    ) async {
      var taps = 0;
      await t.pumpWidget(
        _host(AiSummaryCard(summary: null, onTap: () => taps++)),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.text('Your morning briefing will appear here.'),
        findsOneWidget,
      );
      expect(find.text('Tap to generate'), findsOneWidget);
      expect(find.textContaining('GOOD '), findsOneWidget); // greeting overline
      await t.tap(find.text('Tap to generate'));
      await t.pump(const Duration(milliseconds: 300));
      expect(taps, 1);
    });

    testWidgets('filled + busy states render; dark palette clean', (t) async {
      await t.pumpWidget(
        _host(
          Column(
            children: [
              AiSummaryCard(
                summary: 'Solid recovery — a good day to push.',
                onTap: () {},
              ),
              const AiSummaryCard(summary: null, busy: true),
            ],
          ),
          palette: kDarkPalette,
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Solid recovery — a good day to push.'), findsOneWidget);
      expect(find.text('Tap for the breakdown'), findsOneWidget);
      expect(find.text('Writing your briefing…'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('TodayVitals', () {
    testWidgets('renders the vitals bento from sample data + routes taps', (
      t,
    ) async {
      final opened = <String>[];
      await t.pumpWidget(
        _host(
          TodayVitals(
            t: TodayData.fromJson(_sampleToday()),
            sparks: const {
              'hrv': [44.0, 46, 51, 47, 49, 45, 48],
              'resting_hr': [54.0, 53, 55, 52, 51, 53, 52],
            },
            onOpen: opened.add,
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 1200));
      expect(find.text('READINESS'), findsOneWidget);
      expect(find.text('Primed'), findsOneWidget); // 82 → primed
      expect(find.text('48'), findsWidgets); // HRV value
      expect(find.text('52'), findsWidgets); // RHR value
      expect(find.text('12.4'), findsWidgets); // strain — tile + orbit satellite
      expect(find.text('7h 42m'), findsWidgets); // sleep — tile + orbit satellite
      expect(find.text('8412'), findsOneWidget); // steps
      expect(find.text('Records & streaks'), findsOneWidget);
      expect(t.takeException(), isNull);

      await t.tap(find.text('READINESS'));
      await t.pump(const Duration(milliseconds: 250));
      expect(opened, contains('readiness'));
    });

    testWidgets('Stress + Sleep tiles show their numeric value', (t) async {
      await t.pumpWidget(
        _host(
          TodayVitals(
            t: TodayData.fromJson(_sampleToday()),
            stageMin: (awakeMin: 24, remMin: 96, lightMin: 258, deepMin: 84),
            onOpen: (_) {},
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 1200));
      // Stress pill shows its 0–100 score (was rendering blank).
      expect(find.text('Stress'.toUpperCase()), findsOneWidget);
      expect(find.text('34'), findsWidgets); // stress — tile + orbit satellite
      // Sleep pill shows its duration number.
      expect(find.text('7h 42m'), findsWidgets); // tile + orbit satellite
      expect(t.takeException(), isNull);
    });

    testWidgets('honest building state: nights-to-go ring, no fake score', (
      t,
    ) async {
      final building = {
        'daily': {
          'readiness': {'note': 'need_baseline:have=2,need=5'},
        },
        'sleep': <String, dynamic>{},
      };
      await t.pumpWidget(
        _host(
          TodayVitals(t: TodayData.fromJson(building), onOpen: (_) {}),
        ),
      );
      await t.pump(const Duration(milliseconds: 1200));
      expect(find.text('Learning you'), findsOneWidget);
      expect(find.text('3'), findsOneWidget); // 5 − 2 nights remaining
      expect(find.text('NIGHTS'), findsOneWidget);
      expect(find.text('—'), findsWidgets); // absent metrics stay honest
      expect(t.takeException(), isNull);
    });

    testWidgets('renders clean in the dark palette', (t) async {
      await t.pumpWidget(
        _host(
          TodayVitals(t: TodayData.fromJson(_sampleToday()), onOpen: (_) {}),
          palette: kDarkPalette,
        ),
      );
      await t.pump(const Duration(milliseconds: 1200));
      expect(find.text('READINESS'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('WorkoutFeedCard', () {
    final startTs = DateTime.now()
            .subtract(const Duration(hours: 3))
            .millisecondsSinceEpoch ~/
        1000;
    Map<String, dynamic> w() => {
      'id': 'w1',
      'type': 'run',
      'status': 'done',
      'start_ts': startTs,
      'duration_min': 42,
      'avg_hr': 148,
      'max_hr': 172,
      'strain': 14.2,
      'steps': 6100,
      'zone_min': [2.0, 6, 12, 16, 6],
    };

    testWidgets('shows type, numbers, zone bar, PR badge; taps through', (
      t,
    ) async {
      var taps = 0;
      await t.pumpWidget(
        _host(
          WorkoutFeedCard(
            w(),
            topWorkout: 14.2, // this session IS the record
            onTap: () => taps++,
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('Run'), findsOneWidget);
      expect(find.text('14.2'), findsOneWidget); // strain mini-gauge
      expect(find.textContaining('42m'), findsOneWidget);
      expect(find.text('PR · TOP WORKOUT'), findsOneWidget);
      await t.tap(find.text('Run'));
      await t.pump(const Duration(milliseconds: 300));
      expect(taps, 1);
      // Let the PR shimmer finish so teardown is clean.
      await t.pump(const Duration(milliseconds: 1600));
    });

    testWidgets('renders clean in the dark palette without PR', (t) async {
      await t.pumpWidget(_host(WorkoutFeedCard(w()), palette: kDarkPalette));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('Run'), findsOneWidget);
      expect(find.text('PR · TOP WORKOUT'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('TrainingSummaryCard', () {
    testWidgets('renders totals + zone legend in both palettes', (t) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            TrainingSummaryCard(
              summary: const {
                'count': 4,
                'total_min': 185,
                'total_calories': 1520,
                'zone_min': [12.0, 40, 66, 50, 17],
              },
              range: 'Week',
              workouts: const [
                {'status': 'done', 'strain': 12.0, 'avg_hr': 141},
                {'status': 'done', 'strain': 16.0, 'avg_hr': 152},
              ],
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 900));
        expect(find.text('TRAINING · WEEK'), findsOneWidget);
        expect(find.text('3h 5m'), findsOneWidget); // 185 min
        expect(find.text('4'), findsOneWidget);
        expect(find.text('1520'), findsOneWidget);
        expect(find.text('14.0'), findsOneWidget); // avg strain
        expect(t.takeException(), isNull);
      }
    });
  });

  group('WorkoutDetailContent', () {
    Map<String, dynamic> detail() {
      final start =
          DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch ~/
              1000;
      return {
        'id': 'w1',
        'type': 'run',
        'status': 'done',
        'start_ts': start,
        'end_ts': start + 42 * 60,
        'duration_min': 42,
        'avg_hr': 148,
        'max_hr': 172,
        'calories': 512,
        'strain': 14.2,
        'steps': 6100,
        'hr': [
          for (var i = 0; i < 20; i++)
            {'t': start + i * 120, 'v': 120 + (i % 7) * 8},
        ],
        'zone_bands': [
          {'zone': 1, 'name': 'Warm-up', 'lo': 98, 'hi': 117, 'min': 6, 'pct': 14},
          {'zone': 2, 'name': 'Fat burn', 'lo': 118, 'hi': 136, 'min': 12, 'pct': 29},
          {'zone': 3, 'name': 'Aerobic', 'lo': 137, 'hi': 156, 'min': 16, 'pct': 38},
          {'zone': 4, 'name': 'Threshold', 'lo': 157, 'hi': 175, 'min': 8, 'pct': 19},
          {'zone': 5, 'name': 'Max effort', 'lo': 176, 'hi': 195, 'min': 0, 'pct': 0},
        ],
        'recovery_curve': [
          {'sec': 60, 'drop': 24},
          {'sec': 120, 'drop': 38},
        ],
        'hr_drift_pct': 2.1,
        'time_to_peak_min': 31,
      };
    }

    testWidgets('renders hero, HR chart, zones and HRR in both palettes', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      for (final p in [kLightPalette, kDarkPalette]) {
        AppColors.active = p;
        await t.pumpWidget(
          MaterialApp(
            theme: buildOpenStrapTheme(p),
            home: Scaffold(
              body: WorkoutDetailContent(
                d: detail(),
                route: null, // no GPS in tests
                maxHr: 190,
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 1200));
        expect(find.text('RUN'), findsOneWidget);
        expect(find.text('0h 42m'), findsOneWidget); // duration hero
        expect(find.text('148'), findsWidgets); // avg bpm
        expect(find.text('Heart rate'), findsOneWidget);
        expect(find.text('Time in zones'), findsOneWidget);
        expect(find.text('Z3 · Aerobic'), findsOneWidget);
        expect(find.text('Heart-rate recovery'), findsOneWidget);
        expect(find.text('−24'), findsOneWidget);
        expect(find.text('Drift +2.1%'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });
  });

  group('SleepNightContent', () {
    Map<String, dynamic> night() {
      // Onset last night 23:10 local, wake 06:42 — recent → hypnogram shows.
      final now = DateTime.now();
      final wake = DateTime(now.year, now.month, now.day, 6, 42);
      final onset = wake.subtract(const Duration(hours: 7, minutes: 32));
      final onsetTs = onset.millisecondsSinceEpoch ~/ 1000;
      final wakeTs = wake.millisecondsSinceEpoch ~/ 1000;
      const stages = ['light', 'deep', 'light', 'rem', 'light', 'awake', 'rem'];
      return {
        'has_sleep': true,
        'sleep_source': 'auto',
        'stages_beta': true,
        'duration_min': 452,
        'need_min': 480,
        'in_bed_min': 470,
        'awake_min': 18,
        'debt_min': 28,
        'efficiency': 0.92,
        'regularity': 78,
        'onset_ts': onsetTs,
        'wake_ts': wakeTs,
        'light_min': 250,
        'deep_min': 62,
        'rem_min': 118,
        'hypnogram': [
          for (var i = 0; i < stages.length; i++)
            {'t': onsetTs + i * 3600, 'stage': stages[i]},
        ],
      };
    }

    String today() {
      final d = DateTime.now();
      return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }

    testWidgets('renders hero, bento, stages and breakdown in both palettes', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      for (final p in [kLightPalette, kDarkPalette]) {
        AppColors.active = p;
        await t.pumpWidget(
          MaterialApp(
            theme: buildOpenStrapTheme(p),
            home: Scaffold(
              body: SingleChildScrollView(
                child: SleepNightContent(
                  data: night(),
                  date: today(),
                  onEditTimes: () {},
                  onConfirmFallback: () {},
                  onClearOverride: () {},
                ),
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 1200));
        expect(find.text('TIME ASLEEP'), findsOneWidget);
        expect(find.text('7h 32m'), findsWidgets); // hero + trends row
        expect(find.text('94%'), findsOneWidget); // 452/480 of need
        expect(find.text('TO BED'), findsOneWidget);
        expect(find.text('WOKE'), findsOneWidget);
        expect(find.text('92'), findsWidgets); // efficiency (bento + trends)
        expect(find.text('Stages'), findsOneWidget);
        expect(find.text('Deep'), findsWidgets);
        expect(find.text('REM'), findsWidgets);
        expect(find.text('Sleep times look off? Fix them'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('fallback night shows the confirm banner; confirm fires', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      var confirmed = 0;
      final data = night()..['sleep_source'] = 'auto_fallback';
      await t.pumpWidget(
        _host(
          SleepNightContent(
            data: data,
            date: today(),
            onEditTimes: () {},
            onConfirmFallback: () => confirmed++,
            onClearOverride: () {},
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('Estimated from your heart rate'), findsOneWidget);
      await t.tap(find.text('Looks right'));
      await t.pump(const Duration(milliseconds: 300));
      expect(confirmed, 1);
    });
  });
}
