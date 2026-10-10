// Widget tests for Home, Health and the shared drill-down: units, dated
// percentiles, and that an absent value is never a bare em-dash.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Deterministic, so a failure is never noise.
List<double> _series(int n, double base, double amp) => List<double>.generate(
  n,
  (i) => base + ((i * 37) % 17) / 17 * amp - amp / 2,
);

/// The same series with the timestamps a real `getChart` carries: one point per
/// day, ending TODAY, stamped at local noon the way `metric_series` reads back.
///
/// Anchored to the run date on purpose. The screens label their axes and their
/// "as of" line RELATIVE to today, so a fixture pinned to a fixed calendar date
/// would render "88 days ago" on one morning and "89 days ago" the next — a
/// test that fails on the passage of time. Anchored here, the rendered text
/// is identical on every run, and a gap in the fixture would show up as one.
List<ChartPoint> _points(int n, double base, double amp) {
  final vs = _series(n, base, amp);
  final now = DateTime.now();
  return [
    for (var i = 0; i < n; i++)
      (
        t:
            DateTime(
              now.year,
              now.month,
              now.day - (n - 1 - i),
              12,
            ).millisecondsSinceEpoch ~/
            1000,
        v: vs[i],
      ),
  ];
}

// ── fixtures ──

/// A first-week user: the band is on, nothing has a baseline yet.
const _homeCold = HomeData(
  name: 'Alex',
  dayId: '2026-05-20',
  readiness: Metric(note: 'need_baseline:have=3,need=14'),
);

const _healthCold = HealthData(daysWithData: 2);

const _readinessCold = ReadinessData(
  readiness: Metric(note: 'need_baseline:have=5,need=14'),
);

/// Onset as a LOCAL wall-clock instant, not a fixed epoch. The screen formats
/// timestamps in the device zone, so anchoring the fixture the same way is what
/// makes the rendered text identical on a machine in another timezone.
final _onsetTs = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;

/// One night, built as segments the way the repo emits them.
List<Map<String, dynamic>> _hypno() {
  final t0 = _onsetTs;
  const plan = [
    ('light', 40),
    ('deep', 55),
    ('light', 30),
    ('rem', 25),
    ('awake', 8),
    ('light', 45),
    ('deep', 30),
    ('rem', 40),
    ('light', 35),
    ('rem', 30),
    ('awake', 12),
    ('light', 20),
  ];
  final out = <Map<String, dynamic>>[];
  var t = t0;
  for (final (stage, mins) in plan) {
    out.add({'t': t, 'stage': stage});
    t += mins * 60;
  }
  out.add({'t': t, 'stage': 'awake'});
  return out;
}

/// One night's map. [elevated] drives the nocturnal-heart-rate detection, which
/// is the one "unusual" item that comes from the night itself rather than from
/// a comparison against history.
Map<String, dynamic> _night({bool elevated = false}) => {
  'duration_min': 443,
  'in_bed_min': 486,
  'awake_min': 20,
  'efficiency': .91,
  'onset_ts': _onsetTs,
  'wake_ts': _onsetTs + 486 * 60,
  'light_min': 170,
  'deep_min': 85,
  'rem_min': 95,
  'hypnogram': _hypno(),
  'cycle_count': 5,
  'cycles_mean_min': 92,
  'advanced': const {'sol_s': 780},
  'nocturnal': {
    'sleeping_hr_avg': 52,
    'sleeping_hr_min': 46,
    'day_hr_avg': 68,
    'vs_baseline_bpm': elevated ? 4.6 : 0.4,
    'dip_pct': .24,
    'elevated': elevated,
  },
  'resp': const {'value': 14.2, 'confidence': .6},
};

final _timeline = {
  'hr': [
    for (var i = 0; i < 120; i++)
      {'t': _onsetTs + i * 240, 'v': 52 + (i % 11) - 5},
  ],
  'hrv': [
    for (var i = 0; i < 120; i++)
      {'t': _onsetTs + i * 240, 'v': 62 + (i % 17) - 8},
  ],
  'resp': [
    for (var i = 0; i < 120; i++)
      {'t': _onsetTs + i * 240, 'v': 14 + (i % 5) / 2},
  ],
  // Relative skin temperature — the fourth lane, in deviation units, never °C.
  'skin_temp': [
    for (var i = 0; i < 60; i++)
      {'t': _onsetTs + i * 480, 'v': -0.2 + (i % 7) / 20},
  ],
};

/// A first-week user: a real night, and no history to judge it against. This is
/// what the screen looks like for a fortnight, and it must not pretend.
final _sleepNew = SleepData(
  day: '2026-05-20',
  night: _night(),
  timeline: _timeline,
  tstHistory: const [430, 465, 410],
);

const _sleepCold = SleepData();

/// A cycle with four logged starts — three measured gaps, so the prediction
/// can state a width — plus a partial current cycle of derived nights behind
/// it.
final _cycle = CycleData(
  enabled: true,
  phase: 'luteal',
  cycleDay: 19,
  daysUntilNext: 9,
  medianLength: 28,
  gapN: 3,
  // A phase only exists once she has declared she cycles (WH-07).
  reproState: 'cycling',
  predictedNext: '2026-05-29',
  predictedFrom: '2026-05-25',
  predictedTo: '2026-06-02',
  logs: const [
    {'date': '2026-02-18', 'kind': 'start'},
    {'date': '2026-03-14', 'kind': 'start'},
    {'date': '2026-04-13', 'kind': 'start'},
    {'date': '2026-05-11', 'kind': 'start'},
  ],
  overlay: [
    for (var i = 1; i <= 19; i++)
      {
        'date': '2026-05-${(10 + i).toString().padLeft(2, '0')}',
        'cycle_day': i,
        'resting_hr': 52.0 + ((i * 31) % 9) / 3,
        'hrv_rmssd': 64.0,
        'skin_temp_idx': 0.2,
      },
  ],
  // Enough logged days across three cycles for the WH-06 look-back to have
  // something to count. It renders folded away; the disclosure is the point.
  symptoms: const {
    '2026-02-19': ['cramps', 'fatigue'],
    '2026-02-21': ['cramps'],
    '2026-03-01': ['bloating'],
    '2026-03-15': ['cramps', 'low mood'],
    '2026-04-14': ['cramps'],
    '2026-04-30': ['acne'],
    '2026-05-12': ['cramps', 'fatigue'],
  },
);

/// Tracking on, nothing logged: the state a user lands in the moment they
/// enable it, and the only one with no numbers in it.
const _cycleEmpty = CycleData(enabled: true);

Widget _scroll(Widget child) => ListView(
  padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x16),
  children: [child],
);

final _shot = GlobalKey();

/// Full-viewport, because these are pages: a shrink-wrapped page hides the
/// overflow these tests exist to catch.
Widget _frame(Widget child, Brightness b, double scale) => MediaQuery(
  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(b),
    home: Builder(
      builder: (c) => RepaintBoundary(
        key: _shot,
        child: child is Scaffold
            ? child
            : Scaffold(
                backgroundColor: P.of(c).bg,
                body: SafeArea(child: child),
              ),
      ),
    ),
  ),
);

Future<void> _loadType() async {
  final files = Directory(
    'assets/fonts/Manrope',
  ).listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'));
  for (final family in const ['Manrope', '.SF Pro Text', 'Menlo']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(
        f.readAsBytes().then(
          (b) => ByteData.sublistView(Uint8List.fromList(b)),
        ),
      );
    }
    await loader.load();
  }
}


void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadType();
  });

  testWidgets('a min-unit metric does not print its unit twice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // `metricValue('min', v)` is already "7h 23m"; the hero used to print
    // `spec.unit` beside it, so Time asleep read "7h 23m min".
    await tester.pumpWidget(
      _frame(
        MetricDetail(
          'sleep',
          data: MetricData(series: _points(30, 443, 0), daysAvailable: 30),
        ),
        Brightness.light,
        1,
      ),
    );
    await tester.pumpAndSettle();
    final mins = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => (t.data ?? '').contains('m min'));
    expect(mins, isEmpty, reason: 'the unit is baked into the formatted value');
    expect(find.text('7h 23m'), findsWidgets);
  });

  testWidgets('the percentile sentence dates itself when the newest stored '
      'reading is not today\'s', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // Four days of stored points ending FOUR DAYS AGO. The rank the rollup
    // carries is that day's; "Today sits at the 22nd percentile" was printed
    // unconditionally, two rows under a hero saying "4 days ago".
    final stale = [
      for (final p in _points(8, 54, 6)) (t: p.t - 4 * 86400, v: p.v),
    ];
    await tester.pumpWidget(
      _frame(
        MetricDetail(
          'resting_hr',
          data: MetricData(
            series: stale,
            daysAvailable: 30,
            percentile: const {'percentile_of_you': 22.0},
          ),
        ),
        Brightness.light,
        1,
      ),
    );
    await tester.pumpAndSettle();
    // The screen opens on Today, which has no stored point here — the rank is
    // a property of the history, so the sentence lives on a wider range.
    await tester.tap(find.text('30 days'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Your reading from 4 days ago is higher than 22%'),
      findsOneWidget,
    );
  });

  testWidgets('an absent metric never renders a bare em-dash', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    for (final w in <Widget>[
      const HomeScreen(data: _homeCold),
      const HealthScreen(data: _healthCold),
      const ReadinessDetail(data: _readinessCold),
      const SleepDetail(data: _sleepCold),
      SleepDetail(data: _sleepNew),
      const CircadianDetail(data: CircadianData()),
      const MetricDetail('resting_hr', data: MetricData()),
      const MetricDetail('skin_temp', data: MetricData()),
      const Investigate('hrv', data: InvestigateData()),
      const Investigate('steps', data: InvestigateData()),
      const HealthScreen(data: _healthCold, vitals: VitalsData(), tab: 3),
      const HealthScreen(data: _healthCold, labs: LabsData(), tab: 4),
      const HealthScreen(data: _healthCold, explore: ExploreData(), tab: 1),
      _scroll(const CycleTab(data: CycleData())),
      _scroll(const CycleTab(data: _cycleEmpty)),
      const JournalFindings(rows: [], weekday: {}),
      // The readiness row that used to hold the app's one reachable em-dash:
      // a driver marked used whose weighted contribution never arrived.
      const ReadinessDetail(
        data: ReadinessData(
          readiness: Metric(value: 74, confidence: .8, tier: MetricTier.high),
          breakdown: [
            {'label': 'hrv', 'weight': .4, 'used': true, 'past_mdc': true},
          ],
          inputsUsed: 1,
        ),
      ),
    ]) {
      await tester.pumpWidget(_frame(w, Brightness.light, 1));
      await tester.pumpAndSettle();
      final dashes = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => (t.data ?? '').trim() == '—');
      expect(
        dashes,
        isEmpty,
        reason:
            '${w.runtimeType} rendered a bare em-dash. An absent value '
            'is a StatusCard: what is missing, why, what fixes it.',
      );
    }
  });

  testWidgets("a ring's provisional skin deviation says so on the Vitals row",
      (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    Future<void> show(bool provisional) async {
      await tester.pumpWidget(_frame(
        HealthScreen(
          key: ValueKey(provisional),
          data: HealthData(daysWithData: 30, today: {
            'skin_temp': {
              'value': 0.4,
              'confidence': 0.25,
              if (provisional) 'provisional': true,
            },
          }),
          vitals: const VitalsData(),
          tab: 3,
        ),
        Brightness.light,
        1,
      ));
      await tester.pumpAndSettle();
    }

    await show(true);
    expect(find.textContaining('Provisional'), findsOneWidget);
    await show(false);
    expect(find.textContaining('Provisional'), findsNothing);
  });

  // ── MIND-01 / MIND-04 / MT-06 / MT-07 ────────────────────────────────────
  testWidgets(
    'journal findings say nothing when nothing survived, and phrase a dose and '
    'a tick box as the different things they are',
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 1800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      // MIND-01's required empty state. 36 simultaneous tests corrected as one
      // family means most people see this, and it has to be shippable copy.
      await tester.pumpWidget(
        _frame(
          const JournalFindings(rows: [], weekday: {}),
          Brightness.light,
          1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nothing separated itself yet'), findsOneWidget);

      await tester.pumpWidget(
        _frame(
          const JournalFindings(
            key: ValueKey('rows'),
            rows: [
              // MIND-04: a habit is a group difference, with both day counts.
              {
                'field': 'walk_after_lunch',
                'field_label': 'Walk after lunch',
                'binary': true,
                'outcome_label': 'HRV',
                'unit': 'ms',
                'delta': 4.2,
                'cohens_d': .61,
                'n_with': 9,
                'n_without': 21,
                'n': 30,
              },
              // MT-07: the outcome's own units on the days she logged it, not
              // a rank correlation read out loud.
              {
                'field': 'alcohol_units',
                'field_label': 'Alcohol',
                'field_unit': 'units',
                'binary': false,
                'outcome_label': 'Resting HR',
                'unit': 'bpm',
                'rho': .52,
                'rho_low': .18,
                'rho_high': .74,
                'slope_per_unit': 2.0,
                'n': 11,
              },
              // MT-06: minutes past midnight is unreadable per minute, and a
              // cutoff time is a threshold read off a dozen self-reports.
              {
                'field': 'caffeine_last_min',
                'field_label': 'Last caffeine, clock time',
                'field_unit': 'min past midnight',
                'binary': false,
                'outcome_label': 'Sleep efficiency',
                'unit': '%',
                'rho': -.44,
                'rho_low': -.7,
                'rho_high': -.1,
                'slope_per_unit': -0.05,
                'n': 14,
              },
            ],
            weekday: {},
          ),
          Brightness.light,
          1,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('On the 9 days you logged Walk after lunch'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Against the 21 days you did not'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'On the 11 days you logged Alcohol, Resting HR ran 2.0 bpm '
          'higher per unit',
        ),
        findsOneWidget,
      );
      // Per hour, never a cutoff time.
      expect(
        find.textContaining('Sleep efficiency ran 3.0 % lower per hour later'),
        findsOneWidget,
      );
      expect(
        find.textContaining('only your last caffeine of the day'),
        findsOneWidget,
      );
      // Nothing here may read as a cause or a recommendation.
      expect(find.textContaining('never a cause'), findsOneWidget);
    },
  );

  // ── WH-06 ────────────────────────────────────────────────────────────────
  testWidgets(
    'the symptom look-back counts against the days she LOGGED, is folded away '
    'until asked for, and stays absent under two cycles',
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _frame(_scroll(CycleTab(data: _cycle)), Brightness.light, 1),
      );
      await tester.pumpAndSettle();
      // Folded: the chips are the thing, the history is behind a tap.
      expect(find.text('What you usually notice'), findsOneWidget);
      expect(find.textContaining('per week of the cycle'), findsNothing);

      await tester.tap(find.text('What you usually notice'));
      await tester.pumpAndSettle();
      // cramps on 5 of the 7 logged days; the denominator sentence names the
      // days she logged, never the calendar.
      expect(find.text('cramps'), findsWidgets);
      expect(find.textContaining('logged days per week'), findsOneWidget);

      // One logged start is not two cycles — nothing to count over, so the
      // control is not offered at all.
      await tester.pumpWidget(
        _frame(
          // Own key: CycleTab takes its fixture in initState, so reusing the
          // element would keep the previous one alive.
          _scroll(
            CycleTab(
              key: const ValueKey('one-start'),
              data: CycleData(
                enabled: true,
                cycleDay: 3,
                logs: const [
                  {'date': '2026-05-11', 'kind': 'start'},
                ],
                symptoms: _cycle.symptoms,
              ),
            ),
          ),
          Brightness.light,
          1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('What you usually notice'), findsNothing);
    },
  );
}
