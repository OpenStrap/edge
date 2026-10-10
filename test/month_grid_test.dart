// What a cell is allowed to mean. `sideCells` is pure, and the rule it
// enforces — no usual range, no colour at all — is the whole honesty of the
// picture.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show ChartPoint;
import 'package:openstrap_edge/ui2/screens/month_grid.dart';
import 'package:openstrap_edge/ui2/trend.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

void main() {
  group('a cell is a place against your own usual range', () {
    // Dated backwards from NOW, because `denseDays` lays a window out ending
    // today — a fixture pinned to a calendar date silently loses however many
    // days have passed since somebody wrote it.
    List<ChartPoint> pts(List<double> vs) => [
          for (var i = 0; i < vs.length; i++)
            (
              t: DateTime.now().subtract(Duration(days: i)).millisecondsSinceEpoch ~/
                  1000,
              v: vs[i],
            ),
        ];

    test('too little history is no colour at all, not a pale one', () {
      final short = List<double>.generate(kGridMinHistory - 1, (i) => 40 + i * 1.0);
      final r = gridRow('readiness', pts(short));
      expect(r.shaded, isFalse);
      expect(r.cells.every((v) => v == null), isTrue);
    });

    test('below, inside and above the range; an absent day stays absent', () {
      const band = UsualRange(50, 60);
      expect(sideCells([40, 55, 70, null], band),
          [Side.below, Side.inside, Side.above, null]);
      expect(sideCells([55], null), [null]);
    });

    test('recovery uses its ring bands, so the grid and the ring agree', () {
      final r = gridRow('readiness',
          pts([20, ...List<double>.generate(20, (i) => 50), 80]));
      // pts() is newest first, so the 20 is today and the 80 the oldest day.
      expect(r.cells.last, Side.below);
      expect(r.cells.contains(Side.inside), isTrue);
      expect(r.higherBetter, isTrue);
    });

    test('strain has no better side', () {
      final r = gridRow(
          'strain', pts(List<double>.generate(30, (i) => 5 + i % 7)));
      expect(r.higherBetter, isNull);
      // The count is coverage, and coverage cannot reset.
      expect(r.have, kGridDays);
      expect(r.historyDays, 30);
      expect(r.shaded, isTrue);
    });
  });

  group('usual range', () {
    test('priorTo abstains under the minimum and judges the newest day '
        'against the days before it', () {
      expect(UsualRange.priorTo(List<double>.filled(kUsualMinDays, 50)), isNull);
      final h = [for (var i = 0; i < 20; i++) 50.0 + (i.isEven ? 2 : -2), 90.0];
      final r = UsualRange.priorTo(h)!;
      expect(r.usual, 50);
      expect(r.side(90), Side.above);
    });

    test('the pipeline baseline is centre ± 1.253 × spread, and abstains '
        'under the minimum', () {
      final r = UsualRange.fromBaseline(
          {'baseline': 50, 'spread': 4, 'n_valid': 20})!;
      expect(r.lo, closeTo(50 - 5.012, 1e-9));
      expect(UsualRange.fromBaseline(
          {'baseline': 50, 'spread': 4, 'n_valid': 5}), isNull);
    });

    test('the axis holds the band with room either side and never goes '
        'below zero for a positive band', () {
      final a = const UsualRange(2, 10).axis([5, 6])!;
      expect(a.min, 0);
      expect(a.max, greaterThanOrEqualTo(18));
    });
  });

  group('MonthGrid on screen', () {
    List<ChartPoint> pts(List<double> vs, {int skip = 0}) => [
          for (var i = 0; i < vs.length; i++)
            (
              t: DateTime.now()
                      .subtract(Duration(days: i + skip))
                      .millisecondsSinceEpoch ~/
                  1000,
              v: vs[i],
            ),
        ];

    Future<void> host(WidgetTester t, List<GridRow> rows) async {
      t.view.physicalSize = const Size(390 * 3, 1600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: MonthGrid(rows))),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('legend, and the strip speaks its below and above counts',
        (t) async {
      final handle = t.ensureSemantics();
      // Newest first: today 20 (below Steady), yesterday 80 (above), then a
      // run of steady 50s.
      await host(t, [
        gridRow('readiness',
            pts([20, 80, ...List<double>.generate(20, (i) => 50)])),
      ]);
      expect(find.text('Usual for you'), findsOneWidget);
      expect(find.text('Better than usual'), findsOneWidget);
      expect(find.text('Worse than usual'), findsOneWidget);
      expect(
          find.bySemanticsLabel(RegExp(r'1 below and 1 above your usual range')),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets('too little history waits, with the trend cards\' words',
        (t) async {
      await host(t, [gridRow('sleep', pts(List<double>.filled(5, 400)))]);
      expect(find.textContaining(': no usual range yet'), findsOneWidget);
      expect(find.text('Your usual range appears after 14 days. 5 so far.'),
          findsOneWidget);
    });

    testWidgets('a long flat history waits too, and says why', (t) async {
      final r = gridRow('sleep', pts(List<double>.filled(40, 400)));
      expect(r.shaded, isFalse);
      await host(t, [r]);
      expect(find.textContaining('all been about the same'), findsOneWidget);
    });

    test('a long history with no value this month still has a range', () {
      final r = gridRow('sleep',
          pts([for (var i = 0; i < 40; i++) 400.0 + (i.isEven ? 20 : -20)],
              skip: 40));
      expect(r.shaded, isTrue);
      expect(r.have, 0);
      expect(r.cells.every((c) => c == null), isTrue);
    });
  });
}
