// The Home sleep ring as rendered: a scored night as stage arcs (Deep, REM,
// Light, Awake) against a target that says when it is the 8 h default, a slept
// night never an empty bar, and the data HomeData hands it.
//
// ROOT-CAUSE REGRESSIONS (owner saw "of 8h 10m" only BEFORE sleeping and an
// EMPTY bar AFTER sleeping):
//   * the arc and the "of ..." text were both gated on `sleepNeedMin` alone, so
//     a scored night with no learned need drew duration + "No target yet" + an
//     empty bar, and
//   * `HomeData.loadForDay` never loaded `sleepNeedMin` at all, so any dated
//     view of a slept night did the same even when a need existed.
// Both are pinned below: a slept night is never an empty bar, and the need
// reaches the ring from both loaders.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

// ── fixtures ───────────────────────────────────────────────────────────────

Finder _spokenCaption(String text) => find.byWidgetPredicate((widget) =>
    widget is Pressable && (widget.semanticLabel?.contains(text) ?? false));

/// The caption is BOTH spoken in full and VISIBLE: as the full text, or as one
/// of its measured compact wordings (which keep the default qualifier). Exactly one Text shows it.
void _caption(String full, List<String> compact) {
  expect(_spokenCaption(full), findsOneWidget);
  expect(
      find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.data == full ||
                  compact.contains(w.data))),
      findsOneWidget,
      reason: 'visible caption is neither "$full" nor one of $compact; texts: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()}');
}

const _stages = SleepStageMin(deep: 70, rem: 95, light: 277, awake: 30);

Metric _min(num v) => Metric(
      value: v,
      unit: 'min',
      confidence: .8,
      tier: MetricTier.estimate,
    );

HomeData _slept({
  Metric? need,
  SleepStageMin? stages = _stages,
  num duration = 442,
}) =>
    HomeData(
      dayId: '2026-10-09',
      readiness: const Metric(value: 82, confidence: .8, tier: MetricTier.high),
      strain: const Metric(value: 9.0, confidence: .6, tier: MetricTier.estimate),
      sleepMin: _min(duration),
      sleepNeedMin: need ?? Metric.empty,
      sleepStages: stages,
    );

HomeData _unslept({Metric sleepMin = Metric.empty}) => HomeData(
      dayId: '2026-10-08',
      readiness: const Metric(value: 82, confidence: .8, tier: MetricTier.high),
      strain: const Metric(value: 9.0, confidence: .6, tier: MetricTier.estimate),
      sleepMin: sleepMin,
    );

Future<void> _pump(
  WidgetTester t,
  HomeData d, {
  double textScale = 1,
}) async {
  t.view.physicalSize = const Size(390 * 3, 800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: SingleChildScrollView(
          child: RingTrio(d: d),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// Every ring painter on screen, in tree order: recovery, strain, sleep.
List<CustomPainter> _ringPainters(WidgetTester t) => [
      for (final e in find.byType(CustomPaint).evaluate())
        if ((e.widget as CustomPaint).painter case final CustomPainter p
            when p is Ring || p is StageRing || p is DashedRing)
          p,
    ];

CustomPainter _sleepPainter(WidgetTester t) => _ringPainters(t).last;

P _p(WidgetTester t) => P.of(t.element(find.byType(RingTrio)));

// ── a fake repository, for the loaders ─────────────────────────────────────

class _Repo extends LocalRepository {
  _Repo({
    this.today = const {},
    this.insights = const {},
    this.night = const {},
  });

  final Map<String, dynamic> today, insights, night;

  @override
  Future<Map<String, dynamic>> getToday() async => today;
  @override
  Future<Map<String, dynamic>> getInsights() async => insights;
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => night;
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => const {};
}

Map<String, dynamic> _env(num v) => {
      'value': v,
      'confidence': .8,
      'tier': 'ESTIMATE',
      'unit': 'min',
    };

const _needInsights = {
  'sleep_coach': {
    'need': {
      'value': {'need_sec': 27720}, // 462 min
      'confidence': .7,
      'tier': 'ESTIMATE',
    },
  },
};

Map<String, dynamic> get _sleptToday => {
      'daily': const {},
      'sleep': {'duration_min': _env(442)},
      'status': {
        'today_day': '2026-10-09',
        'overnight_state': 'ready',
        'overnight_day': '2026-10-09',
        'showing_prior_overnight': false,
      },
    };

const _nightMap = {
  'has_sleep': true,
  'duration_min': 442,
  'deep_min': 70,
  'rem_min': 95,
  'light_min': 277,
  'awake_min': 30,
};

void main() {
  group('bounded scores are clamped at the call site', () {
    testWidgets('recovery 130 and strain 30 draw one lap, not a spiral',
        (t) async {
      await _pump(
        t,
        HomeData(
          dayId: '2026-10-09',
          readiness:
              const Metric(value: 130, confidence: .8, tier: MetricTier.high),
          strain: const Metric(
              value: 30, confidence: .6, tier: MetricTier.estimate),
          sleepMin: _min(442),
          sleepStages: _stages,
        ),
      );
      final rings = _ringPainters(t).whereType<Ring>().toList();
      expect(rings, hasLength(2));
      for (final r in rings) {
        expect(r.v, 1.0);
      }
    });
  });

  group('slept: stage arcs', () {
    testWidgets('Deep, REM, Light, Awake in the hypnogram colours, '
        'contiguous, on the track', (t) async {
      await _pump(t, _slept());
      final painter = _sleepPainter(t);
      expect(painter, isA<StageRing>());
      final ring = painter as StageRing;
      final cols = Hypnogram.cols(_p(t));
      expect([for (final a in ring.arcs) a.color], [
        cols[SleepStage.deep],
        cols[SleepStage.rem],
        cols[SleepStage.light],
        cols[SleepStage.awake],
      ]);
      // All 472 staged minutes divide the earned 442/480-lap sweep.
      expect([for (final a in ring.arcs) a.fraction], [
        closeTo(442 / 480 * 70 / 472, 1e-9),
        closeTo(442 / 480 * 95 / 472, 1e-9),
        closeTo(442 / 480 * 277 / 472, 1e-9),
        closeTo(442 / 480 * 30 / 472, 1e-9),
      ]);
      expect(ring.arcs.fold<double>(0, (s, a) => s + a.fraction),
          closeTo(442 / 480, 1e-9));
      expect(ring.track, _p(t).track);
    });

    testWidgets('value is the duration; sub is "92% of 8h 00m (default)" when '
        'the target is the default', (t) async {
      await _pump(t, _slept());
      expect(find.text('7h 22m'), findsOneWidget);
      _caption('92% of 8h 00m (default)', ['92% of 8h · default target', '92% of default 8h']);
    });

    testWidgets('a learned need is the target and is NOT labelled default',
        (t) async {
      await _pump(t, _slept(need: _min(462)));
      expect(find.text('96% of 7h 42m'), findsOneWidget);
      expect(find.textContaining('default'), findsNothing);
      final ring = _sleepPainter(t) as StageRing;
      expect(ring.arcs.first.fraction, closeTo(442 / 462 * 70 / 472, 1e-9));
    });

    testWidgets('no stage totals => ONE solid arc in the sleep colour, never '
        'a split', (t) async {
      await _pump(t, _slept(stages: null));
      final painter = _sleepPainter(t);
      expect(painter, isNot(isA<StageRing>()));
      expect(painter, isA<Ring>());
      final ring = painter as Ring;
      expect(ring.color, _p(t).on(C.blue));
      expect(ring.v, closeTo(442 / 480, 1e-9));
      expect(ring.solid, isTrue);
    });

    testWidgets('a night longer than the target is drawn past a full circle',
        (t) async {
      await _pump(
        t,
        _slept(
          duration: 540,
          stages: const SleepStageMin(deep: 90, rem: 120, light: 330, awake: 20),
        ),
      );
      final ring = _sleepPainter(t) as StageRing;
      final sweep = ring.arcs.fold<double>(0, (s, a) => s + a.fraction);
      expect(sweep, closeTo(540 / 480, 1e-9));
      _caption('113% of 8h 00m (default)', ['113% of 8h · default target', '113% of default 8h']);
    });

    testWidgets('stages still draw at the accessibility text size',
        (t) async {
      await _pump(t, _slept(), textScale: 2);
      expect(_sleepPainter(t), isA<StageRing>());
      _caption('92% of 8h 00m (default)', ['92% of 8h · default target', '92% of default 8h']);
    });

    testWidgets('spoken text carries the percentage and the default label',
        (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _slept());
      expect(
        find.bySemanticsLabel(
            RegExp(r'Sleep\. 7h 22m\. 92% of 8h 00m \(default\)')),
        findsOneWidget,
      );
      h.dispose();
    });
  });

  group('regression: a slept night is never an empty bar', () {
    testWidgets('scored night + NO learned need: arc is drawn against the '
        'labelled default, not "No target yet" and an empty bar', (t) async {
      await _pump(t, _slept(need: Metric.empty, stages: null));
      expect(find.text('No target yet'), findsNothing);
      final ring = _sleepPainter(t) as Ring;
      expect(ring.v, greaterThan(0));
      _caption('92% of 8h 00m (default)', ['92% of 8h · default target', '92% of default 8h']);
    });

    testWidgets('scored night + learned need present: the "of" target is '
        'there AND the bar is filled', (t) async {
      await _pump(t, _slept(need: _min(462), stages: null));
      expect(find.text('96% of 7h 42m'), findsOneWidget);
      expect((_sleepPainter(t) as Ring).v, closeTo(442 / 462, 1e-9));
    });

    test('HomeData.load carries the learned need and the stage totals of a '
        'night that scored', () async {
      final repo = _Repo(
        today: _sleptToday,
        insights: _needInsights,
        night: _nightMap,
      );
      final d = await HomeData.load(repo);
      expect(d.sleepMin.value, 442);
      expect(d.sleepNeedMin.value, 462);
      expect(d.sleepStages?.deep, 70);
      expect(d.sleepStages?.rem, 95);
      expect(d.sleepStages?.light, 277);
      expect(d.sleepStages?.awake, 30);
    });

    test('HomeData.loadForDay (a dated view of a slept night) carries the '
        'need the night itself reports', () async {
      final repo = _Repo(
        night: {..._nightMap, 'need_min': _env(462)},
      );
      final d = await HomeData.loadForDay(repo, '2026-10-08');
      expect(d.sleepMin.value, 442);
      expect(d.sleepNeedMin.value, 462);
      expect(d.sleepStages?.deep, 70);
    });

    test('HomeData.loadForDay with no learned need leaves it absent (the ring '
        'then shows the labelled default, never a made-up need)', () async {
      final repo = _Repo(night: _nightMap);
      final d = await HomeData.loadForDay(repo, '2026-10-08');
      expect(d.sleepNeedMin.value, isNull);
      expect(d.sleepMin.value, 442);
    });

    testWidgets('a dated slept night with no need renders a filled bar and the '
        'default label', (t) async {
      final d = await t.runAsync(() => HomeData.loadForDay(
          _Repo(night: _nightMap), '2026-10-08'));
      await _pump(t, d!);
      expect(find.text('No target yet'), findsNothing);
      _caption('92% of 8h 00m (default)', ['92% of 8h · default target', '92% of default 8h']);
      expect(_sleepPainter(t), isA<StageRing>());
    });
  });

  group('loaders: no stale stages', () {
    test('a night that is NOT today\'s never lends its stages to today',
        () async {
      final repo = _Repo(
        today: {
          'daily': const {},
          'sleep': const {},
          'status': {
            'today_day': '2026-10-09',
            'overnight_state': 'building',
            'overnight_day': '2026-10-08',
            'showing_prior_overnight': true,
          },
        },
        insights: _needInsights,
        night: _nightMap, // last night's, which the ring must not borrow
      );
      final d = await HomeData.load(repo);
      expect(d.sleepMin.value, isNull);
      expect(d.sleepStages, isNull);
      expect(d.sleepNeedMin.value, 462);
    });
  });

  group('no scored night', () {
    testWidgets('an honest absence and an empty ring — never a guessed time',
        (t) async {
      await _pump(t, _unslept());
      // An absence is a dash in the ring; the reason is a row under the rings.
      final gap = find.byKey(const ValueKey('home-note:gap:sleep'));
      expect(find.descendant(of: gap, matching: find.text('Sleep')),
          findsOneWidget);
      expect(
          find.descendant(
              of: gap,
              matching: find.textContaining(
                  'No night long enough to score was recorded.')),
          findsOneWidget);
      final ring = _sleepPainter(t) as Ring;
      expect(ring.v, 0);
    });

    testWidgets('the pipeline\'s own reason comes first', (t) async {
      await _pump(
        t,
        _unslept(
          sleepMin: const Metric(note: 'Last night is still being processed.'),
        ),
      );
      expect(
        find.textContaining('Last night is still being processed.',
            findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('RingTrio.has: a scored night is something to draw; nothing '
        'is not', (t) async {
      expect(RingTrio.has(_slept()), isTrue);
      expect(RingTrio.has(const HomeData()), isFalse);
    });
  });

  group('calibrating is unchanged', () {
    testWidgets('a baseline note still draws the dashed ring', (t) async {
      await _pump(
        t,
        _unslept(sleepMin: const Metric(note: 'need_baseline:have=3,need=14')),
      );
      final p = _sleepPainter(t);
      expect(p, isA<DashedRing>());
      expect((p as DashedRing).segments, 14);
    });
  });
}
