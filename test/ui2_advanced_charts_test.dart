// The research charts live behind one door from Health, and the zone, lap
// and strain charts that stay in the main flow read without a key.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _app(Widget home, {double scale = 1, Brightness b = Brightness.light}) =>
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(theme: buildTheme(b), home: home),
    );

void main() {
  testWidgets('Health vitals opens the Advanced screen', (t) async {
    t.view.physicalSize = const Size(390 * 3, 4000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(const HealthScreen(
        data: HealthData(daysWithData: 2), vitals: VitalsData(), tab: 3)));
    await t.pumpAndSettle();
    expect(find.text('Advanced charts'), findsOneWidget);
    // `go` needs the app's providers, so the screen is pumped on its own.
    await t.pumpWidget(_app(const AdvancedScreen()));
    await t.pumpAndSettle();
    expect(find.text('Beat to beat'), findsOneWidget);
    expect(find.text('Sleep timing and daily rhythm'), findsOneWidget);
  });

  testWidgets('the Advanced screen fits 3.1x text in both themes', (t) async {
    for (final b in Brightness.values) {
      await t.pumpWidget(_app(const AdvancedScreen(), scale: 3.1, b: b));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$b overflowed');
    }
  });

  testWidgets('the sleep-by-hour grid is on the research view only',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 4000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final d = CircadianData(
        actogram: [for (var i = 0; i < 7; i++) List<double>.filled(24, .5)]);
    await t.pumpWidget(_app(CircadianDetail(data: d)));
    await t.pumpAndSettle();
    expect(find.text('Sleep, night by night'), findsNothing);
    await t.pumpWidget(_app(CircadianDetail(data: d, advanced: true)));
    await t.pumpAndSettle();
    expect(find.text('Sleep, night by night'), findsOneWidget);
  });

  testWidgets('day strain draws the whole 0–21 scale its header names',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 3000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final curve = List<double?>.filled(1440, null);
    for (var m = 7 * 60; m < 9 * 60; m++) {
      curve[m] = (m - 7 * 60) / 30;
    }
    await t.pumpWidget(_app(DayStrainDetail(
        data: DayStrainData(
            day: DateTime(2026, 5, 20),
            curve: curve,
            strain: 4,
            zoneMin: const [30, 20, 10, 5, 1],
            zoneLowerBpm: const [95, 114, 133, 152, 171]))));
    await t.pumpAndSettle();
    final frame = t
        .widgetList<ChartFrame>(find.byType(ChartFrame))
        .firstWhere((f) => f.unit == '0–21');
    expect(frame.yAxis!.min, 0);
    expect(frame.yAxis!.max, 21);
    // The zone split is five named rows with their edges, not a strip.
    expect(find.textContaining('Zone 5'), findsOneWidget);
    expect(find.textContaining('171+ bpm'), findsOneWidget);
    expect(find.text('30 min'), findsOneWidget);
  });

  testWidgets('laps read top to bottom in the order they were swum',
      (t) async {
    await t.pumpWidget(_app(const Scaffold(body: LapRows([60, 52, 58], C.blue))));
    final y = [
      for (final n in [1, 2, 3]) t.getTopLeft(find.text('Lap $n')).dy,
    ];
    expect(y[0], lessThan(y[1]));
    expect(y[1], lessThan(y[2]));
    expect(find.text('00:52'), findsOneWidget);
    final fastest = t.widget<Text>(find.text('00:52'));
    expect(fastest.style!.fontWeight, FontWeight.w700);
  });
}
