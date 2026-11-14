// SCRUB + PANEL ON THE MONTH GRID (Graphs PR phase 5, red tests).
//
// Each shaded row of the month grid is a 30-cell strip: where the day sat
// against the person's usual range. Upstream has no way to read one cell. The
// fork's strip scrubbed (ChartScrub, nearest cell) with a key row naming the
// day's side. The panel reads "Above usual / Normal for you / Below usual"
// for the selected day, a dash for a day with no value, and a row that is not
// shaded (too little history) has neither a strip to scrub nor a panel.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show specOf;
import 'package:openstrap_edge/ui2/screens/month_grid.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/scrub_surface_laws.dart';

/// Oldest first, slot 29 is today. Slot i is below / inside / above by i % 3,
/// except slot 27, which has no value.
const _gapSlot = 27, _scrubSlot = 13; // 13 % 3 == 1 -> inside

Side? _side(int i) =>
    i == _gapSlot ? null : Side.values[(i % 3 == 0 ? 2 : (i % 3 == 1 ? 0 : 1))];

String _word(int slot) => switch (_side(slot)) {
      Side.inside => 'Normalforyou',
      Side.above => 'Aboveusual',
      Side.below => 'Belowusual',
      null => '—',
    };

GridRow _row(String key, {int history = 40}) => GridRow(
      spec: specOf(key),
      key: key,
      cells: [for (var i = 0; i < kGridDays; i++) _side(i)],
      have: kGridDays - 1,
      historyDays: history,
      ranged: true,
      anchor: DateTime.now(),
    );

/// A page with room to scroll above and below the grid.
Widget _page(List<GridRow> rows, {bool sideways = false}) {
  Widget grid = MonthGrid(rows);
  if (sideways) {
    grid = SingleChildScrollView(
      key: const ValueKey('sideways'),
      scrollDirection: Axis.horizontal,
      child: SizedBox(width: 800, child: grid),
    );
  }
  return Scaffold(
    body: ListView(children: [
      const SizedBox(height: 300),
      grid,
      const SizedBox(height: 900),
    ]),
  );
}

Future<void> _mount(WidgetTester t, double scale) async {
  phone(t, 390, 640);
  await t.pumpWidget(scaledApp(scale, _page([_row('readiness')])));
  await t.pumpAndSettle();
  // Controls: the grid is drawn.
  expect(find.text('Today'), findsOneWidget);
}

void main() {
  final rig = SurfaceRig(
    name: 'month grid',
    mount: _mount,
    plot: () => find.byType(Scrubber),
    slots: kGridDays,
    bars: true,
    scrubbed: _scrubSlot,
    gap: _gapSlot,
    valueAt: (slot) => '^${_word(slot)}',
  );
  defineSurfaceLaws(rig);

  testWidgets('every shaded row has its own strip and its own panel',
      (t) async {
    phone(t, 390, 1200);
    await t.pumpWidget(scaledApp(
        1, _page([_row('sleep'), _row('readiness'), _row('strain')])));
    await t.pumpAndSettle();
    expect(find.byType(Scrubber), findsNWidgets(3));
    expect(find.byKey(panelKey), findsNWidgets(3));
  });

  testWidgets('the strip is 22 pt tall but its scrub area is a full tap target',
      (t) async {
    phone(t, 390, 900);
    await t.pumpWidget(scaledApp(1, _page([_row('readiness')])));
    await t.pumpAndSettle();
    final area = t.getSize(find.byType(Scrubber));
    expect(area.height, greaterThanOrEqualTo(S.tap));
    final strip = find.descendant(
        of: find.byType(Scrubber), matching: find.byType(CustomPaint));
    expect(t.getSize(strip.first).height, 22);
  });

  testWidgets('a row without enough history draws no strip to scrub and no '
      'panel: nothing is invented', (t) async {
    phone(t, 390, 900);
    final waiting = GridRow(
      spec: specOf('sleep'),
      key: 'sleep',
      cells: List<Side?>.filled(kGridDays, null),
      have: 3,
      historyDays: 3,
      ranged: false,
      anchor: DateTime.now(),
    );
    await t.pumpWidget(scaledApp(1, _page([waiting, _row('readiness')])));
    await t.pumpAndSettle();
    expect(find.byType(Scrubber), findsOneWidget,
        reason: 'only the shaded row scrubs');
    expect(find.byKey(panelKey), findsOneWidget);
  });

  group('inside a horizontal scroller', () {
    testWidgets('a vertical drag on the strip still scrolls the page and '
        'selects nothing', (t) async {
      phone(t, 390, 640);
      await t.pumpWidget(scaledApp(1, _page([_row('readiness')], sideways: true)));
      await t.pumpAndSettle();
      final strip = find.byType(Scrubber);
      expect(strip, findsOneWidget, reason: 'the strip has no Scrubber');
      final page = t
          .state<ScrollableState>(find
              .byWidgetPredicate(
                  (w) => w is Scrollable && w.axis == Axis.vertical)
              .first)
          .position;
      final before = page.pixels;
      // The strip is 800 wide in a 390 viewport: touch inside the viewport.
      final box = t.getRect(strip);
      await t.timedDragFrom(Offset(100, box.center.dy),
          const Offset(10, -120), const Duration(milliseconds: 350));
      await t.pumpAndSettle();
      expect(page.pixels - before, greaterThan(40));
      expect(t.widget<Scrubber>(strip).value, isNull);
    });

    testWidgets('the scroller still moves from outside the strip, and the '
        'page does not', (t) async {
      phone(t, 390, 640);
      await t.pumpWidget(scaledApp(1, _page([_row('readiness')], sideways: true)));
      await t.pumpAndSettle();
      // Control for the Scrubber, so this cannot pass on an unchanged grid and
      // then be broken by the change.
      expect(find.byType(Scrubber), findsOneWidget,
          reason: 'the strip has no Scrubber');
      final side = t
          .state<ScrollableState>(find
              .descendant(
                  of: find.byKey(const ValueKey('sideways')),
                  matching: find.byType(Scrollable))
              .first)
          .position;
      final page = t
          .state<ScrollableState>(find
              .byWidgetPredicate(
                  (w) => w is Scrollable && w.axis == Axis.vertical)
              .first)
          .position;
      final pageBefore = page.pixels;
      await t.drag(find.text('29 days ago'), const Offset(-120, 4));
      await t.pumpAndSettle();
      expect(side.pixels, greaterThan(40));
      expect(page.pixels, closeTo(pageBefore, 1));
    });
  });
}
