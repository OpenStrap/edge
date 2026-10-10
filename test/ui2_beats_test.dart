// THE BEATS SCREEN — the four things it may not get wrong.
//
// None of them are layout. Every one is an honesty rule this screen is under,
// and every one of them is a sentence a future edit could delete without
// breaking a pixel:
//
//   * the rhythm screen may not reassure, may not diagnose, and must draw
//     "never screened" as a DIFFERENT MARK from "screened and did not fire" —
//     not a fainter one;
//   * deceleration capacity gets no threshold, no reference range and no
//     verdict colour, and never appears without its anchor count;
//   * a night whose beats have been pruned says the beats are gone and still
//     prints the numbers taken from them — it is not an empty state;
//   * a half-hour bin that abstained stays a hole and is never joined across.
//
// The shape numbers in the fixture are real: they are the owner's night of
// 2026-08-15 as `Export.db` holds it (29 832 clean NN of 30 117 read, SD1 29.9,
// SD2 150.7, 17 bins with one hole, 10 435 PRSA anchors).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/beats.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show ChartPoint;
import 'package:openstrap_edge/ui2/ui2.dart';

/// A plausible night of intervals. The physiology is not under test here — the
/// rendering of a large cloud is — so this is shaped, not sampled.
List<double> _nn(int n) => [
      for (var i = 0; i < n; i++) 880 + (i % 37) * 3.0 - (i % 11) * 4.0,
    ];

/// 17 half-hour bins, the 12th abstaining exactly as `nightHrvShape` does.
List<NightBin> _bins() => [
      for (var i = 0; i < 17; i++)
        i == 11
            ? (startSec: i * 1800, nBeats: 40, v: null, lo: null, hi: null)
            : (
                startSec: i * 1800,
                nBeats: 900,
                v: 30 + i * 1.5,
                lo: 26 + i * 1.5,
                hi: 35 + i * 1.5,
              ),
    ];

/// Newest-last day stamps for a stored series, at local noon.
List<ChartPoint> _days(List<double?> v) {
  final now = DateTime.now();
  final out = <ChartPoint>[];
  for (var i = 0; i < v.length; i++) {
    final x = v[i];
    if (x == null) continue;
    final d = DateTime(now.year, now.month, now.day - (v.length - 1 - i), 12);
    out.add((t: d.millisecondsSinceEpoch ~/ 1000, v: x));
  }
  return out;
}

BeatsData _night({List<double>? nn}) => BeatsData(
      day: '2026-08-15',
      nn: nn ?? _nn(2400),
      rawBeats: (nn ?? _nn(2400)).length + 285,
      cleanFraction: .983,
      poincare: const {'sd1': 29.9, 'sd2': 150.7, 'flag': false},
      bins: _bins(),
      firstThirdMs: 34.1,
      lastThirdMs: 51.2,
      shape: const Metric(value: 1, confidence: .9),
      // Ten days with no stored row, then twenty with one.
      dcPoints: _days([
        for (var i = 0; i < 30; i++) i < 10 ? null : 7.5 + (i % 5) * .4,
      ]),
      dcAnchors: 10435,
      dc: const Metric(value: 8.27, confidence: .95),
      // Ten days never screened, eighteen screened and quiet, two that fired.
      rhythmPoints: _days([
        for (var i = 0; i < 30; i++) i < 10 ? null : (i == 17 || i == 26 ? 1 : 0),
      ]),
      deviceFamily: 'gen4',
    );

Future<void> _pump(WidgetTester t, BeatsData d, {double scale = 1}) async {
  t.view.physicalSize = Size(390 * 3, 6000 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Beats(data: d),
    ),
  ));
  await t.pumpAndSettle();
}

/// Every string the screen renders, joined. `find.textContaining` only reaches
/// one widget at a time and these rules are about the whole surface.
String _allText(WidgetTester t) =>
    t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');

void main() {
  testWidgets('the four panels draw, and the cloud is the whole night', (
    t,
  ) async {
    await _pump(t, _night());

    // The scatter exists, is the new painter, and holds every interval it was
    // given — a silently decimated cloud would be a different picture.
    final scatter = t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<Poincare>()
        .toList();
    expect(scatter, hasLength(1));
    expect(scatter.single.nn, hasLength(2400));

    final text = _allText(t);
    for (final panel in const [
      'Every beat against the one before it',
      'Variability across the night',
      'Deceleration capacity',
      'Rhythm screen',
    ]) {
      expect(text, contains(panel), reason: '$panel is missing');
    }
    // The Poincaré numbers are printed BESIDE the cloud they describe.
    // At `metricValue`'s ms precision — a tenth of a millisecond is not a
    // precision beat timing recovered from 1 Hz records carries.
    expect(text, contains('30 ms'));
    expect(text, contains('151 ms'));
    // Nerd stats is one tap away, and this screen is where the picture is.
    expect(text, contains('Nerd stats'));
  });

  testWidgets('the rhythm panel screens, never diagnoses, and never reassures',
      (t) async {
    await _pump(t, _night());
    final text = _allText(t).toLowerCase();

    // The banned surface, verbatim from the design system's own list plus the
    // arrhythmia vocabulary this panel may not reach for.
    for (final banned in const [
      'ahi',
      'apnea-hypopnea',
      'apnoea',
      'you have',
      'atrial fibrillation',
      'afib',
      'a-fib',
      'pvc',
      'ectopy',
      'ectopic',
      'arrhythmia',
      'normal rhythm',
      'no issues',
      'looks healthy',
    ]) {
      expect(text, isNot(contains(banned)),
          reason: '"$banned" may not appear on this screen');
    }
    // Severity bands are an individual assignment; none of the three words may
    // be used to grade anything here.
    for (final band in const ['mild', 'moderate', 'severe']) {
      expect(text, isNot(contains(band)));
    }

    // It may not reassure, and it terminates in a clinician rather than a
    // number. Both lines are on the card, not in a tooltip.
    expect(text, contains('not a day you were cleared'));
    expect(text, contains('cannot rule anything out'));
    // The project's settled termination for this whole surface — the same
    // sentence the CVHR card on Nerd stats ends on. It ends in a person.
    expect(text, contains('a clinician can test that properly'));
    // No count of abnormal beats, in either grammar.
    expect(text, isNot(contains('% of beats')));
    expect(text, isNot(contains('abnormal')));
  });

  testWidgets('the pipeline\'s own notes do not leak onto the card', (t) async {
    // The REAL strings the estimators attach when they succeed. Both were
    // being rendered verbatim, and the rhythm one carries "you have" — the
    // grammar of a diagnosis, banned across this whole surface. Verbatim
    // pipeline diagnostics belong on Nerd stats; this is density 2.
    await _pump(t, BeatsData(
      day: '2026-08-15',
      nn: _nn(600),
      rawBeats: 640,
      cleanFraction: .97,
      poincare: const {'sd1': 29.9, 'sd2': 150.7},
      bins: _bins(),
      shape: const Metric(
        value: 1,
        confidence: .8,
        note: 'per-bin RMSSD (30-min bins, PRV not ECG-HRV) — a DESCRIPTION '
            'of the night, never a cause. Render each bin as a band, not a '
            'point.',
      ),
      rhythmPoints: _days([for (var i = 0; i < 30; i++) 0]),
      rhythm24h: const {
        'value': {'sd1_ms': 44.6, 'sd2_ms': 194.2, 'flag': false},
        'confidence': 0.9,
        'note': 'irregular-rhythm SCREEN (not a diagnosis): Poincaré SD1/SD2 '
            '+ pNN70. PRV not ECG — wrist pulse misses P-waves. Discuss with '
            'a clinician only if you have symptoms.',
      },
    ));
    final text = _allText(t).toLowerCase();
    expect(text, isNot(contains('you have')));
    expect(text, isNot(contains('render each bin')));
    // A screen that ABSTAINED still states its reason — that is the case the
    // note is for, and dropping it would be a bare absence.
    expect(text, isNot(contains('last night was not screened')));
  });

  testWidgets('an abstention states the reason it abstained', (t) async {
    await _pump(t, BeatsData(
      day: '2026-08-15',
      nn: _nn(600),
      rawBeats: 640,
      cleanFraction: .6,
      poincare: const {'sd1': 29.9, 'sd2': 150.7},
      bins: _bins(),
      rhythmPoints: _days([for (var i = 0; i < 30; i++) null]),
      rhythm24h: const {
        'value': null,
        'confidence': 0.0,
        'note': 'artifact fraction 41% > 30% — screen suppressed on noisy RR',
      },
    ));
    final text = _allText(t);
    expect(text, contains('Last night was not screened: artifact fraction 41%'));
  });

  testWidgets('never screened is a different MARK from screened and quiet', (
    t,
  ) async {
    await _pump(t, _night());

    // The absence channel is a shape, not a shade: an outline with no fill.
    // Ten days were never screened, and one half-hour bin abstained.
    final outlined = t
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((w) => w.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.border != null && d.color == null)
        .length;
    expect(outlined, 11,
        reason: '10 unscreened days + 1 abstaining HRV bin should each be '
            'drawn as an outline. A fill of any shade makes "we never looked" '
            'and "we looked and saw nothing" the same mark.');

    // And the key says which is which, in three entries rather than two.
    final frame = t
        .widgetList<ChartFrame>(find.byType(ChartFrame))
        .firstWhere((f) => f.legend.length == 3);
    expect([for (final (l, _) in frame.legend) l],
        ['Screen did not fire', 'Screen fired', 'Not screened']);
  });

  testWidgets('deceleration capacity carries no threshold and no verdict', (
    t,
  ) async {
    await _pump(t, _night());
    final text = _allText(t).toLowerCase();

    // No stratum, no reference range, no colour word — and specifically not
    // Bauer's tiers, which are ECG post-MI and read "low risk" or worse for
    // every healthy wrist night we have ever measured.
    for (final banned in const [
      'low risk',
      'high risk',
      'intermediate',
      'normal range',
      'healthy range',
      'above average',
      'below average',
      'good',
      'poor',
    ]) {
      expect(text, isNot(contains(banned)),
          reason: '"$banned" is a threshold on a number that has none');
    }
    // The two caveats that must travel with the number, always.
    expect(text, contains('cleaner signal'));
    expect(text, contains('10,435')); // the anchor count, beside it
    expect(text, contains('98.3%')); // the artifact gate, beside it

    // The line is drawn in neutral ink. An accent would be a verdict.
    final line = t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<LineChart>()
        .single;
    const p = P(false);
    expect(line.color, p.ink2);
    expect(line.fill, isFalse);
  });

  testWidgets('a pruned night says the beats are gone, not "no data"', (
    t,
  ) async {
    // The steady state after a few days: the bundle survives, the raw does not.
    await _pump(t, BeatsData(
      day: _night().day,
      poincare: _night().poincare,
      bins: _night().bins,
      shape: _night().shape,
      dcPoints: _night().dcPoints,
      dc: _night().dc,
      rhythmPoints: _night().rhythmPoints,
    ));
    final text = _allText(t);

    expect(text, contains('no longer on this phone'));
    // The numbers taken from those beats are still real and still printed.
    expect(text, contains('SD1 30 ms'));
    expect(text, isNot(contains('No data')));
    // And nothing pretends to plot a cloud that is not there.
    expect(
      t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<Poincare>(),
      isEmpty,
    );
  });

  // iOS reaches 3.1x effective and this screen is mostly long honest prose, so
  // it is the exact shape that overflows. Nothing here is in the gallery's
  // sweep — it is a route — so the sweep happens here instead.
  for (final scale in const [1.4, 2.0, 3.1]) {
    testWidgets('nothing overflows at ${scale}x text', (t) async {
      await _pump(t, _night(), scale: scale);
      expect(t.takeException(), isNull);
      expect(find.textContaining('cannot rule anything out'), findsOneWidget);
    });
  }

  testWidgets('an abstaining bin is a hole, and the card says how many', (
    t,
  ) async {
    await _pump(t, _night());
    final text = _allText(t);
    expect(text, contains('1 bin holds'));
    expect(text, contains('left empty rather than joined across'));
    // The band is a band: every drawn bin carries its lo/hi, so the series
    // handed to the frame keeps the hole in place rather than compacting it.
    final frame = t
        .widgetList<ChartFrame>(find.byType(ChartFrame))
        .firstWhere((f) => f.title == 'HRV in half-hour blocks');
    expect(frame.series, hasLength(17));
    expect(frame.series[11], isNull);
  });
}
