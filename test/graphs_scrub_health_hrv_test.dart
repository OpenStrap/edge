// SCRUB + PANEL ON THE HEALTH HRV CHART (Graphs PR phase 5, red tests).
//
// The Vitals tab's "Heart rate variability" deep-dive card draws thirty nights
// of RMSSD as a line, with no scrub at all on upstream, and the whole card is a
// tap target that opens Investigate. The fork made this chart scroll-first
// scrubbable (87f9654f). The chart must read a night under the finger without
// the card navigating, and the page must still scroll from the chart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/scrub_surface_laws.dart';

const _nights = 30, _gapBack = 3, _scrubbedBack = 10;

/// RMSSD of 80 - back on every night except a hole at [_gapBack]; noon local
/// on each calendar day.
HealthData _data() {
  final n = DateTime.now();
  return HealthData(charts: {
    'hrv': [
      for (var back = _nights - 1; back >= 0; back--)
        if (back != _gapBack)
          (
            t: DateTime(n.year, n.month, n.day - back, 12)
                    .millisecondsSinceEpoch ~/
                1000,
            v: 80.0 - back,
          ),
    ],
  });
}

Future<void> _mount(WidgetTester t, double scale) async {
  phone(t, 390, 640);
  await t.pumpWidget(scaledApp(
      scale,
      Scaffold(
          body: HealthScreen(
        data: _data(),
        vitals: const VitalsData(day: '2026-01-01', days: ['2026-01-01'], hrv: {'rmssd': 80}),
        tab: 3,
      ))));
  await t.pumpAndSettle();
  // Controls: the card and its chart frame are on screen.
  expect(find.text('Heart rate variability'), findsWidgets);
  expect(find.byType(ChartFrame), findsOneWidget);
}

void main() {
  final rig = SurfaceRig(
    name: 'health HRV',
    mount: _mount,
    plot: () => find.descendant(
        of: find.byType(ChartFrame), matching: find.byType(Scrubber)),
    slots: _nights,
    bars: false,
    scrubbed: _nights - 1 - _scrubbedBack,
    gap: _nights - 1 - _gapBack,
    lastWord: 'last night',
    valueAt: (slot) => '^${(80 - (_nights - 1 - slot))}ms',
  );
  defineSurfaceLaws(rig);

  testWidgets('a tap on the chart reads a night and does not open the card',
      (t) async {
    await _mount(t, 1);
    final plot = rig.plot();
    expect(plot, findsOneWidget, reason: 'the chart has no Scrubber');
    await t.ensureVisible(plot);
    await t.pumpAndSettle();
    await t.tapAt(t.getCenter(plot));
    await t.pumpAndSettle();
    expect(t.widget<Scrubber>(plot).value, isNotNull);
    expect(find.byType(HealthScreen), findsOneWidget,
        reason: 'the card navigates only from outside the chart');
    expect(find.text('Heart rate variability'), findsWidgets);
  });
}
