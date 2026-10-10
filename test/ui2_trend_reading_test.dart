// The shared trend reading on the screens that use it: the verdict header,
// the usual-range band and its abstention, press-and-hold on a card, recovery
// bars in their ring colour, and the overnight chart's cursor linked to the
// stage chart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

int _noon(int daysAgo) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - daysAgo, 12).millisecondsSinceEpoch ~/
      1000;
}

Future<void> _host(WidgetTester t, Widget w,
    {double height = 900, bool screen = false}) async {
  t.view.physicalSize = Size(390 * 3, height * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: screen ? w : Scaffold(body: SingleChildScrollView(child: w)),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('TrendCard with a usual range', () {
    Widget card() => TrendCard(
          'Resting heart rate',
          '58',
          'bpm',
          '',
          'as of today',
          const [55, 54, 56, 55, 58],
          C.red,
          band: const UsualRange(53, 57),
          latest: 58,
          higherBetter: false,
          format: (v) => v.round().toString(),
          dayOf: (i) => 'Day $i',
        );

    testWidgets('says the word, the arrow and the difference from usual',
        (t) async {
      final handle = t.ensureSemantics();
      await _host(t, card());
      expect(find.text('Above usual'), findsOneWidget);
      expect(find.text('· +3 bpm from your usual 55 bpm'), findsOneWidget);
      final label = t.getSemantics(find.byType(TrendCard)).label;
      expect(label, contains('Above usual, +3 bpm from your usual 55 bpm'));
      handle.dispose();
    });

    testWidgets('press and hold reads the day under the finger, and lets go',
        (t) async {
      await _host(t, card());
      final plot = find.byType(Scrubber);
      final g = await t.startGesture(t.getBottomRight(plot) - const Offset(2, 2));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('Day 4 · 58 bpm'), findsOneWidget);
      await g.up();
      await t.pump();
      expect(find.text('as of today'), findsOneWidget);
    });

    testWidgets('a tap is still the door, not a reading', (t) async {
      var opened = 0;
      await _host(
          t,
          TrendCard('HRV', '48', 'ms', '', '', const [50, 48], C.green,
              band: const UsualRange(45, 55),
              latest: 48,
              dayOf: (i) => 'Day $i',
              onTap: () => opened++));
      await t.tap(find.byType(Scrubber));
      await t.pumpAndSettle();
      expect(opened, 1);
      expect(find.textContaining('Day '), findsNothing);
    });
  });

  testWidgets('a chart frame draws and speaks the usual range', (t) async {
    final handle = t.ensureSemantics();
    const axis = AxisSpec(min: 40, max: 70, format: axisInt);
    await _host(
      t,
      const ChartFrame(
        title: 'Resting heart rate',
        unit: 'bpm',
        yAxis: axis,
        band: UsualRange(52, 58),
        series: [55, 56],
        child: SizedBox.expand(),
      ),
    );
    expect(find.byType(BandLayer), findsOneWidget);
    expect(t.getSemantics(find.byType(ChartFrame)).label,
        contains('Usual range 52–58'));
    handle.dispose();
  });

  group('Recovery history', () {
    ReadinessData data(List<double?> s) => ReadinessData(
          readiness: const Metric(
              value: 20, unit: '', confidence: .8, tier: MetricTier.estimate),
          series: s,
        );

    testWidgets('each bar takes its ring colour, and holding reads the day',
        (t) async {
      final s = <double?>[for (var i = 0; i < 20; i++) 50, 80, 20];
      await _host(t, ReadinessDetail(data: data(s)), height: 2400, screen: true);
      final bars = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<Bars>()
          .single;
      final p = P.of(t.element(find.byType(ReadinessDetail)));
      expect(bars.colorOf!(20), p.on(C.red));
      expect(bars.colorOf!(80), p.on(C.green));
      expect(bars.colorOf!(30), p.on(C.orange));
      // Enough history: the Steady band is drawn, no abstain note.
      expect(find.byType(BandLayer), findsOneWidget);
      // Steady is green too, so the green key names it; the band has a
      // visible key of its own, not only a spoken one.
      expect(find.text('Good to go / Steady'), findsOneWidget);
      expect(find.text('Usual range 37–61'), findsOneWidget);

      final strip = find.byWidgetPredicate(
          (w) => w is Scrubber && w.label == 'Recovery');
      await t.tapAt(t.getBottomRight(strip) - const Offset(1, 1));
      await t.pumpAndSettle();
      expect(find.textContaining('· 20 · Rest today'), findsOneWidget);
    });

    testWidgets('under two weeks there is no band, and one line says why',
        (t) async {
      await _host(t, ReadinessDetail(data: data(const [50, 55, 20])),
          height: 2400, screen: true);
      expect(find.byType(BandLayer), findsNothing);
      expect(find.text('Your usual range appears after 14 days. 3 so far.'),
          findsOneWidget);
    });
  });

  group('MetricDetail verdict', () {
    MetricData hrv({Map<String, dynamic>? baselines}) => MetricData(
          daysAvailable: 30,
          series: [
            for (var i = 20; i >= 1; i--) (t: _noon(i), v: 55.0),
            (t: _noon(0), v: 48.0),
          ],
          baselines: baselines,
        );

    Future<void> pump(WidgetTester t, MetricData d) async {
      t.view.physicalSize = const Size(390 * 3, 1600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: MetricDetail('hrv', data: d)),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('HRV is judged against the pipeline baseline', (t) async {
      await pump(
          t,
          hrv(baselines: const {
            'hrv': {'baseline': 54, 'spread': 2, 'n_valid': 20},
          }));
      expect(find.text('Below usual'), findsOneWidget);
      expect(find.text('· −6 ms from your usual 54 ms'), findsOneWidget);
      await t.tap(find.text('30 days'));
      await t.pumpAndSettle();
      expect(find.byType(BandLayer), findsOneWidget);
    });

    testWidgets('no pipeline baseline is no band, never one made up from the '
        'chart', (t) async {
      await pump(t, hrv());
      expect(find.text('Below usual'), findsNothing);
      await t.tap(find.text('30 days'));
      await t.pumpAndSettle();
      expect(find.byType(BandLayer), findsNothing);
    });
  });

  testWidgets('the overnight chart scrubs the same instant as the stages',
      (t) async {
    final onset = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;
    t.view.physicalSize = const Size(390 * 3, 5200 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: SleepDetail(
        data: SleepData(
          day: '2026-05-20',
          night: {
            'duration_min': 443,
            'in_bed_min': 486,
            'onset_ts': onset,
            'wake_ts': onset + 486 * 60,
            'hypnogram': [
              {'t': onset, 'stage': 'light'},
              {'t': onset + 3600, 'stage': 'deep'},
              {'t': onset + 486 * 60, 'stage': 'awake'},
            ],
          },
          timeline: {
            'hr': [
              for (var i = 0; i < 60; i++)
                {'t': onset + i * 480, 'v': 52 + (i % 11) - 5},
            ],
          },
        ),
      ),
    ));
    await t.pumpAndSettle();
    // The night's own numbers are on the card.
    expect(find.textContaining('Heart rate 47–57'), findsOneWidget);
    final stack = find.byWidgetPredicate(
        (w) => w is Scrubber && w.label == 'Through the night');
    expect(stack, findsOneWidget);
    await t.tapAt(t.getCenter(stack));
    await t.pumpAndSettle();
    final night = t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<NightStack>()
        .single;
    expect(night.selectedX, closeTo(.5, .02));
    // The hypnogram follows: its scrubber now has a value.
    final hyp = find.byWidgetPredicate(
        (w) => w is Scrubber && w.label == 'Hypnogram');
    expect(t.widget<Scrubber>(hyp).value, closeTo(.5, .02));
  });
}
