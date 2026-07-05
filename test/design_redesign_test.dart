// Widget tests for the redesign's new design-system components (OrbitScore,
// BentoTile tones/ToneScope, BentoColumns, BigStat, Hypnogram/StageBars,
// RadialHeatmap, RingWeek, StateChips, RecapCard, MedalCard,
// AiHero) plus the rebuilt Today bento — rendered in BOTH palettes at phone
// width, asserting no overflow. Explicit pump durations (never blind
// pumpAndSettle — some widgets animate on a loop).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/design/ai_hero.dart';
import 'package:openstrap_edge/ui/design/bento.dart';
import 'package:openstrap_edge/ui/design/big_stat.dart';
import 'package:openstrap_edge/ui/design/domains.dart';
import 'package:openstrap_edge/ui/design/hypnogram.dart';
import 'package:openstrap_edge/ui/design/orbit_score.dart';
import 'package:openstrap_edge/ui/design/radial_heatmap.dart';
import 'package:openstrap_edge/ui/design/recap_card.dart';
import 'package:openstrap_edge/ui/design/ring_week.dart';
import 'package:openstrap_edge/ui/design/state_chips.dart';
import 'package:openstrap_edge/ui/kit/kit.dart' show Ic;
import 'package:openstrap_edge/ui/today/today_screen.dart' show TodayVitals;

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
  'step_goal': 10000,
};

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  group('OrbitScore', () {
    testWidgets('score, word, label render; core + satellite taps fire', (
      t,
    ) async {
      _phone(t);
      var core = 0;
      final opened = <String>[];
      await t.pumpWidget(
        _host(
          OrbitScore(
            score: 82,
            label: 'Readiness',
            word: 'Primed',
            onTap: () => core++,
            satellites: [
              OrbitSatellite(
                icon: Ic.moon,
                label: 'Sleep',
                onTap: () => opened.add('sleep'),
              ),
              OrbitSatellite(
                icon: Ic.heart,
                label: 'Heart',
                onTap: () => opened.add('heart'),
              ),
            ],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 1200));
      expect(find.text('READINESS'), findsOneWidget);
      expect(find.text('82'), findsOneWidget);
      expect(find.text('Primed'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(t.takeException(), isNull);

      await t.tap(find.text('82'));
      await t.pump(const Duration(milliseconds: 250));
      expect(core, 1);
      await t.tap(find.text('Sleep'));
      await t.pump(const Duration(milliseconds: 250));
      expect(opened, ['sleep']);
    });

    testWidgets('null score with ringFill + custom center stays honest', (
      t,
    ) async {
      _phone(t);
      await t.pumpWidget(
        _host(
          OrbitScore(
            score: null,
            ringFill: 0.4,
            confidence: 0.3,
            center: const Text('3 nights left'),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 1200));
      expect(find.text('3 nights left'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('BentoTile + ToneScope + BigStat + BentoColumns', () {
    testWidgets('all four tones render BigStat with tone-correct fg', (
      t,
    ) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        _phone(t);
        var taps = 0;
        await t.pumpWidget(
          _host(
            BentoColumns(
              entrance: false,
              left: [
                BentoTile(
                  onTap: () => taps++,
                  child: const BigStat(value: '48', unit: 'ms', label: 'HRV'),
                ),
                const BentoTile(
                  tone: BentoTone.accent,
                  child: BigStat(value: '640', unit: 'kcal', label: 'Calories'),
                ),
              ],
              right: [
                const BentoTile(
                  tone: BentoTone.ink,
                  child: BigStat(value: '52', unit: 'bpm', label: 'RHR'),
                ),
                const BentoTile(
                  tone: BentoTone.soft,
                  child: BigStat.dash(label: 'O2'),
                ),
              ],
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 400));
        expect(find.text('48'), findsOneWidget);
        expect(find.text('52'), findsOneWidget);
        expect(find.text('640'), findsOneWidget);
        expect(find.text('—'), findsOneWidget); // honest dash
        expect(t.takeException(), isNull);

        // Ink tile's number uses the invariant paper-on-night ink.
        final rhr = t.widget<Text>(find.text('52'));
        expect(rhr.style?.color, AppColors.onNight);
        // Accent tile's number is white.
        final cal = t.widget<Text>(find.text('640'));
        expect(cal.style?.color, Colors.white);

        await t.tap(find.text('48'));
        await t.pump(const Duration(milliseconds: 250));
        expect(taps, 1);
      }
    });

    testWidgets(
      'a long value in a very narrow tile scales down and stays fully visible '
      '(no ellipsis / no overflow)',
      (t) async {
        _phone(t);
        await t.pumpWidget(
          _host(
            // A deliberately tiny box for a long figure — the FittedBox must
            // shrink it, never clip it to "12 3…".
            Center(
              child: SizedBox(
                width: 72,
                child: BentoTile(
                  child: const BigStat(
                    value: '12 345',
                    unit: 'steps',
                    label: 'STEPS',
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
        // The full string is present and rendered exactly once — untrimmed.
        final numFinder = find.text('12 345');
        expect(numFinder, findsOneWidget);
        final txt = t.widget<Text>(numFinder);
        expect(txt.overflow, isNot(TextOverflow.ellipsis));
        // No render overflow was thrown while laying it out in the narrow box.
        expect(t.takeException(), isNull);
      },
    );
  });

  group('Hypnogram + StageBars', () {
    testWidgets('segments render with row labels + time captions', (t) async {
      _phone(t);
      await t.pumpWidget(
        _host(
          const Hypnogram(
            [
              HypnoSeg(SleepStage.awake, 0.0, 0.05),
              HypnoSeg(SleepStage.light, 0.05, 0.4),
              HypnoSeg(SleepStage.deep, 0.4, 0.6),
              HypnoSeg(SleepStage.rem, 0.6, 1.0),
            ],
            startLabel: '11:24 pm',
            endLabel: '7:05 am',
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      for (final s in ['Awake', 'REM', 'Light', 'Deep']) {
        expect(find.text(s), findsOneWidget);
      }
      expect(find.text('11:24 pm'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    test('hypnoSegmentsFromPoints normalizes and maps stages', () {
      final segs = hypnoSegmentsFromPoints([
        {'t': 100, 'stage': 'light'},
        {'t': 160, 'stage': 'deep'},
        {'t': 200, 'stage': 'rem'},
        {'t': 300, 'stage': 'rem'}, // closing point
      ]);
      expect(segs.length, 3);
      expect(segs.first.stage, SleepStage.light);
      expect(segs.first.start, 0.0);
      expect(segs.last.end, 1.0);
      // Garbage in → nothing out, never a throw.
      expect(hypnoSegmentsFromPoints([]), isEmpty);
      expect(
        hypnoSegmentsFromPoints([
          {'t': 5, 'stage': 'martian'},
        ]),
        isEmpty,
      );
    });

    testWidgets('StageBars renders legend; all-null renders nothing', (
      t,
    ) async {
      _phone(t);
      await t.pumpWidget(
        _host(
          const Column(
            children: [
              StageBars(awakeMin: 20, remMin: 90, lightMin: 250, deepMin: 80),
              StageBars(), // honest empty
            ],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('REM'), findsOneWidget);
      expect(find.textContaining('Deep'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('RadialHeatmap + RingWeek', () {
    testWidgets('RadialHeatmap handles nulls + labels without throwing', (
      t,
    ) async {
      _phone(t);
      await t.pumpWidget(
        _host(
          RadialHeatmap(
            values: const [0.1, null, 0.8, 1.0, 0.4, 0.0, null, 0.6],
            color: DomainAccent.strain,
            labels: const ['12a', '6a', '12p', '6p'],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 1100));
      expect(t.takeException(), isNull);
    });

    testWidgets('RingWeek renders custom labels + null days', (t) async {
      _phone(t);
      await t.pumpWidget(
        _host(
          const RingWeek(
            values: [0.9, 1.0, null, 0.5, 0.7, 0.2, 0.8],
            todayIndex: 6,
            labels: ['T', 'F', 'S', 'S', 'M', 'T', 'W'],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('F'), findsOneWidget);
      expect(find.text('W'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('StateChips + RecapCard + MedalCard + AiHero', () {
    testWidgets('StateChips selects on tap', (t) async {
      _phone(t);
      var sel = 0;
      await t.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => StateChips(
              chips: const [
                StateChip('Energize', emoji: '⚡'),
                StateChip('Recover', emoji: '🛌'),
              ],
              selected: sel,
              onSelect: (i) => setState(() => sel = i),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('Recover'));
      await t.pump(const Duration(milliseconds: 300));
      expect(sel, 1);
    });

    testWidgets('RecapCard + MedalCard render and tap through', (t) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        _phone(t);
        var taps = 0;
        await t.pumpWidget(
          _host(
            Column(
              children: [
                RecapCard(
                  title: 'Weekly recap',
                  highlight: 'You slept 40 min more than usual.',
                  value: '7h 12m',
                  caption: 'daily average',
                  bars: const [6.2, 7.5, 8.1, 6.9, 7.2, 8.4, 7.1],
                  onTap: () => taps++,
                ),
                const SizedBox(height: Sp.x3),
                MedalCard(
                  medal: '5K',
                  overline: 'Personal record',
                  title: 'Fastest 5k — 24:31',
                  subtitle: 'Tuesday morning run',
                  onTap: () {},
                ),
              ],
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 500));
        expect(find.text('WEEKLY RECAP'), findsOneWidget);
        expect(find.text('7h 12m'), findsOneWidget);
        expect(find.text('Fastest 5k — 24:31'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.tap(find.text('7h 12m'));
        await t.pump(const Duration(milliseconds: 250));
        expect(taps, 1);
      }
    });

    testWidgets('AiHero filled/empty/busy + ask pill fires', (t) async {
      _phone(t);
      var asked = 0;
      await t.pumpWidget(
        _host(
          Column(
            children: [
              AiHero(
                overline: 'Good morning',
                line: 'Solid recovery — push today.',
                hint: 'Ask about your day…',
                cta: 'Tap for the breakdown',
                onTap: () {},
                onAsk: () => asked++,
              ),
              const AiHero(overline: 'Good morning', line: null),
              const AiHero(overline: 'Good morning', line: null, busy: true),
            ],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Solid recovery — push today.'), findsOneWidget);
      expect(
        find.text('Your morning briefing will appear here.'),
        findsOneWidget,
      );
      expect(find.text('Writing your briefing…'), findsOneWidget);
      await t.tap(find.text('Ask about your day…'));
      await t.pump(const Duration(milliseconds: 250));
      expect(asked, 1);
      expect(t.takeException(), isNull);
    });
  });

  group('Rebuilt Today bento', () {
    testWidgets(
      'full composition (orbit hero + mixed-tone bento + stages + week rings) '
      'renders at phone width in BOTH palettes without overflow',
      (t) async {
        for (final p in [kLightPalette, kDarkPalette]) {
          _phone(t);
          final opened = <String>[];
          await t.pumpWidget(
            _host(
              TodayVitals(
                t: TodayData.fromJson(_sampleToday()),
                sparks: const {
                  'hrv': [44.0, 46, 51, 47, 49, 45, 48],
                  'resting_hr': [54.0, 53, 55, 52, 51, 53, 52],
                },
                stepsWeek: const [
                  8000.0,
                  12000,
                  6000,
                  null,
                  9000,
                  11000,
                  8412,
                ],
                stageMin: (
                  awakeMin: 24,
                  remMin: 96,
                  lightMin: 258,
                  deepMin: 84,
                ),
                hypno: const [
                  HypnoSeg(SleepStage.light, 0.0, 0.4),
                  HypnoSeg(SleepStage.deep, 0.4, 0.6),
                  HypnoSeg(SleepStage.rem, 0.6, 1.0),
                ],
                onOpen: opened.add,
              ),
              palette: p,
            ),
          );
          await t.pump(const Duration(milliseconds: 1400));
          // Hero + satellites.
          expect(find.text('READINESS'), findsOneWidget);
          expect(find.text('Primed'), findsOneWidget);
          expect(find.text('Sleep'), findsOneWidget); // satellite route
          // Bento numbers. Sleep/Heart(RHR)/Strain now also appear on their
          // orbit satellite, so those match >1; HRV is bento-only.
          expect(find.text('48'), findsOneWidget); // HRV — bento only
          expect(find.text('52'), findsWidgets); // RHR — tile + Heart satellite
          expect(find.text('12.4'), findsWidgets); // strain — tile + satellite
          expect(find.text('7h 42m'), findsWidgets); // sleep — tile + satellite
          expect(find.text('8412'), findsOneWidget);
          expect(find.text('640'), findsOneWidget);
          // Week rings card present (steps spark provided).
          expect(find.text('STEPS GOAL (WEEK)'), findsOneWidget);
          // No sync-anxiety copy anywhere in the composition.
          expect(find.textContaining('Sync'), findsNothing);
          expect(find.textContaining('stored to'), findsNothing);
          expect(t.takeException(), isNull, reason: 'palette $p');

          // Satellite routes.
          await t.tap(find.text('Heart'));
          await t.pump(const Duration(milliseconds: 250));
          expect(opened, contains('heart'));
        }
      },
    );

    testWidgets('long-press on the HRV tile opens the InfoSheet', (t) async {
      _phone(t);
      await t.pumpWidget(
        _host(
          TodayVitals(t: TodayData.fromJson(_sampleToday()), onOpen: (_) {}),
        ),
      );
      await t.pump(const Duration(milliseconds: 1200));
      await t.longPress(find.text('HRV'));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('HRV (RMSSD)'), findsOneWidget);
      await t.pumpAndSettle(const Duration(milliseconds: 200));
    });
  });
}
