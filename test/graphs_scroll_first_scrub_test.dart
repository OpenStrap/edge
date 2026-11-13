// SCROLL FIRST, SCRUB DELIBERATELY (Graphs PR, red tests).
//
// WHY: a thumb that starts a page scroll on top of a chart must not drag the
// chart's marker. Upstream's `Scrubber` is a bare `Listener` that moves the
// marker on every pointer-down and pointer-move, and a `Listener` never joins
// the gesture arena, so the page scrolls AND the marker jumps. The intended
// behaviour (the fork's APK1 batch, bf016f7e / 11744b52 / a893e511):
//   * pointer-down alone selects nothing;
//   * a mostly-vertical move belongs to the page: no marker, page scrolls;
//   * a horizontal-dominant move (more than 1.5x the vertical) past the DEVICE
//     touch slop belongs to the chart: marker follows, page does not move;
//   * a tap selects on release; a long press selects and then follows the
//     finger on any axis;
//   * the recognizers use the device's touch slop, not the 18 pt default.
//
// Two production charts are driven (metric detail trend, sleep hypnogram) plus
// the bare Scrubber in a ListView for the slop law.
import 'package:flutter/gestures.dart' show DeviceGestureSettings;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _onset = DateTime(2026, 5, 19, 23).millisecondsSinceEpoch ~/ 1000;
final _wake = DateTime(2026, 5, 20, 7).millisecondsSinceEpoch ~/ 1000;

SleepData _sleep() => SleepData(
      day: '2026-05-20',
      night: {
        'duration_min': 420,
        'in_bed_min': 480,
        'awake_min': 15,
        'efficiency': .88,
        'onset_ts': _onset,
        'wake_ts': _wake,
        'light_min': 200,
        'deep_min': 120,
        'rem_min': 100,
        'hypnogram': [
          {'t': _onset, 'stage': 'light'},
          {'t': _onset + 3600, 'stage': 'deep'},
          {'t': _onset + 10800, 'stage': 'rem'},
          {'t': _wake, 'stage': 'awake'},
        ],
      },
    );

MetricData _metric() {
  final n = DateTime.now();
  return MetricData(daysAvailable: 10, series: [
    for (var back = 9; back >= 0; back--)
      (
        t: DateTime(n.year, n.month, n.day - back, 12).millisecondsSinceEpoch ~/
            1000,
        v: 50.0 + back,
      ),
  ]);
}

class _Rig {
  const _Rig(this.name, this.mount, this.plot);
  final String name;
  final Future<void> Function(WidgetTester t, double scale) mount;
  final Finder Function() plot;
}

void _phone(WidgetTester t, double h) {
  t.view.physicalSize = Size(390 * 3, h * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Widget _scaled(double scale, Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

final _rigs = <_Rig>[
  _Rig(
    'metric detail trend',
    (t, scale) async {
      _phone(t, 640);
      await t.pumpWidget(_scaled(
          scale, Scaffold(body: MetricDetail('resting_hr', data: _metric()))));
      await t.pumpAndSettle();
      await t.tap(find.text('7 days'));
      await t.pumpAndSettle();
    },
    () => find.descendant(
        of: find.byType(ChartFrame).first, matching: find.byType(Scrubber)),
  ),
  _Rig(
    'sleep hypnogram',
    (t, scale) async {
      _phone(t, 640);
      await t.pumpWidget(_scaled(scale, SleepDetail(data: _sleep())));
      await t.pumpAndSettle();
    },
    () => find.byWidgetPredicate(
        (w) => w is Scrubber && w.label == 'Hypnogram'),
  ),
];

Finder get _verticalScroll => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axis == Axis.vertical);

Future<ScrollPosition> _mount(WidgetTester t, _Rig r, double scale) async {
  await r.mount(t, scale);
  final plot = r.plot();
  expect(plot, findsOneWidget, reason: '${r.name}: the chart is on screen');
  await t.ensureVisible(plot);
  await t.pumpAndSettle();
  expect(t.widget<Scrubber>(plot).value, isNull,
      reason: 'nothing is selected before a touch');
  final scroll = t
      .state<ScrollableState>(
          find.ancestor(of: plot, matching: _verticalScroll).first)
      .position;
  expect(scroll.maxScrollExtent, greaterThan(100),
      reason: 'a real scrollable page, not a chart in an unscrollable box');
  expect(t.takeException(), isNull, reason: '${r.name} lays out at $scale');
  return scroll;
}

/// Brings the chart back on screen without touching it (a drag can carry it off
/// and rebuild a lazy item), then reads the marker.
Future<double?> _marker(WidgetTester t, _Rig r) async {
  await t.ensureVisible(r.plot());
  await t.pumpAndSettle();
  return t.widget<Scrubber>(r.plot()).value;
}

void main() {
  for (final r in _rigs) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          '${r.name}: a mostly vertical drag on the chart scrolls the page '
          'and never moves the marker (x$scale)', (t) async {
        final scroll = await _mount(t, r, scale);
        final before = scroll.pixels;
        final dy = scroll.extentAfter > 150 ? -130.0 : 130.0;
        await t.timedDrag(
            r.plot(), Offset(12, dy), const Duration(milliseconds: 350));
        await t.pumpAndSettle();
        expect((scroll.pixels - before).abs(), greaterThan(40),
            reason: 'a vertical drag that begins on the chart belongs to the page');
        expect(await _marker(t, r), isNull,
            reason: 'neither pointer-down nor a vertical move may scrub');
        expect(t.takeException(), isNull);
      });

      testWidgets(
          '${r.name}: a first move of 24 across and 60 down scrolls without '
          'selecting (x$scale)', (t) async {
        final scroll = await _mount(t, r, scale);
        final before = scroll.pixels;
        final dy = scroll.extentAfter > 150 ? -60.0 : 60.0;
        final g = await t.startGesture(t.getCenter(r.plot()));
        // One event crosses BOTH slops, so the dominance check decides, not
        // whichever axis happened to cross first.
        await g.moveBy(Offset(24, dy));
        await t.pump();
        expect(t.widget<Scrubber>(r.plot()).value, isNull);
        await g.moveBy(Offset(0, dy));
        await g.up();
        await t.pumpAndSettle();
        expect((scroll.pixels - before).abs(), greaterThan(40));
        expect(await _marker(t, r), isNull);
        expect(t.takeException(), isNull);
      });

      testWidgets(
          '${r.name}: pointer-down alone selects nothing; a horizontal drag '
          'past slop scrubs and the page stays put (x$scale)', (t) async {
        final scroll = await _mount(t, r, scale);
        final before = scroll.pixels;
        final pending = await t.startGesture(t.getCenter(r.plot()));
        await t.pump();
        expect(t.widget<Scrubber>(r.plot()).value, isNull,
            reason: 'an unresolved pointer-down must not flash a marker '
                'during what may be a page scroll');
        await pending.up();
        await t.pump();
        // A few points of vertical noise must not turn a deliberate sideways
        // scrub into a page scroll.
        await t.drag(r.plot(), const Offset(60, 5));
        await t.pumpAndSettle();
        expect(scroll.pixels, closeTo(before, 1),
            reason: 'a horizontal-dominant drag does not scroll the page');
        expect(t.widget<Scrubber>(r.plot()).value, isNotNull,
            reason: 'the chart took the drag');
        expect(t.takeException(), isNull);
      });

      testWidgets(
          '${r.name}: a long press then a vertical drag selects without '
          'scrolling (x$scale)', (t) async {
        final scroll = await _mount(t, r, scale);
        final before = scroll.pixels;
        final g = await t.startGesture(t.getCenter(r.plot()));
        await t.pump(const Duration(milliseconds: 700));
        await g.moveBy(const Offset(0, 40));
        await t.pump();
        expect(t.widget<Scrubber>(r.plot()).value, isNotNull,
            reason: 'a held finger is a deliberate scrub on any axis');
        expect(scroll.pixels, closeTo(before, 1));
        await g.up();
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });

      testWidgets('${r.name}: a tap still places the marker (x$scale)',
          (t) async {
        await _mount(t, r, scale);
        await t.tapAt(t.getCenter(r.plot()));
        await t.pumpAndSettle();
        expect(t.widget<Scrubber>(r.plot()).value, closeTo(.5, .1));
      });
    }
  }

  // The recognizers must take the DEVICE's touch slop, as GestureDetector
  // does. With an 8 pt device slop and the 18 pt default, a gradual
  // horizontal-dominant drag would lose to the page scroll at 9 pt.
  testWidgets('with an 8 pt device slop a gradual horizontal-dominant drag '
      'scrubs instead of scrolling', (t) async {
    final picked = ValueNotifier<double?>(null);
    await t.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
            size: Size(360, 800),
            gestureSettings: DeviceGestureSettings(touchSlop: 8)),
        child: Scaffold(
          body: ListView(children: [
            const SizedBox(height: 200),
            ValueListenableBuilder<double?>(
              valueListenable: picked,
              builder: (_, v, _) => Scrubber(
                value: v,
                onChanged: (x) => picked.value = x,
                label: 'Chart',
                describe: (x) => x.toStringAsFixed(2),
                child: const SizedBox(height: 160, width: 360),
              ),
            ),
            const SizedBox(height: 2000),
          ]),
        ),
      ),
    ));
    final scroll = t.state<ScrollableState>(find.byType(Scrollable)).position;
    final g = await t.startGesture(t.getCenter(find.byType(Scrubber)));
    // Small steps, each 14:9 (horizontal dominant by more than 1.5x).
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(14 / 3, 3));
      await t.pump();
    }
    await g.up();
    await t.pump();
    expect(picked.value, isNotNull, reason: 'the scrubber won the arena');
    expect(scroll.pixels, 0, reason: 'the page did not scroll');
  });
}
