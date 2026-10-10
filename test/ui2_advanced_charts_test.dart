// The research charts live behind one door from Health, and the zone, lap
// and strain charts that stay in the main flow read without a key.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

Widget _app(Widget home, {double scale = 1, Brightness b = Brightness.light}) =>
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(theme: buildTheme(b), home: home),
    );

/// [_app] plus the theme controller a pushed route reads, so a link can be
/// tapped rather than its target pumped on its own.
Widget _nav(Widget home) => ChangeNotifierProvider<ThemeController>.value(
    value: ThemeController.seed(AppThemeChoice.light, Brightness.light),
    child: _app(home));

void main() {
  Future<void> tapLink(WidgetTester t, String text) async {
    await t.ensureVisible(find.text(text));
    await t.pumpAndSettle();
    await t.tap(find.text(text));
    await t.pumpAndSettle();
  }

  testWidgets('Health vitals opens the Advanced screen, and it opens both '
      'research views', (t) async {
    t.view.physicalSize = const Size(390 * 3, 4000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(_nav(const HealthScreen(
        data: HealthData(daysWithData: 2), vitals: VitalsData(), tab: 3)));
    await t.pumpAndSettle();
    await tapLink(t, 'Advanced charts');
    expect(find.byType(AdvancedScreen), findsOneWidget);

    await tapLink(t, 'Beat to beat');
    expect(find.byType(Beats), findsOneWidget);
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await t.pumpAndSettle();

    await tapLink(t, 'Sleep timing and daily rhythm');
    expect(
        t.widget<CircadianDetail>(find.byType(CircadianDetail)).advanced, isTrue);
  });

  testWidgets('HRV detail has the same door to Advanced', (t) async {
    t.view.physicalSize = const Size(390 * 3, 4000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final now = DateTime.now();
    await t.pumpWidget(_nav(MetricDetail('hrv',
        data: MetricData(daysAvailable: 7, series: [
          for (var i = 0; i < 7; i++)
            (
              t: DateTime(now.year, now.month, now.day - 6 + i, 12)
                      .millisecondsSinceEpoch ~/
                  1000,
              v: 50.0 + i,
            ),
        ]))));
    await t.pumpAndSettle();
    await tapLink(t, 'Advanced charts');
    expect(find.byType(AdvancedScreen), findsOneWidget);
  });

  testWidgets('the Advanced screen fits 3.1x text in both themes', (t) async {
    for (final b in Brightness.values) {
      await t.pumpWidget(_app(const AdvancedScreen(), scale: 3.1, b: b));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$b overflowed');
    }
  });

  testWidgets('the research rhythm view fits 3.1x text in both themes',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 6000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final d = CircadianData(
        actogram: [for (var i = 0; i < 7; i++) List<double>.filled(24, .5)]);
    for (final b in Brightness.values) {
      await t.pumpWidget(
          _app(CircadianDetail(data: d, advanced: true), scale: 3.1, b: b));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$b overflowed');
      expect(find.text('Sleep, night by night'), findsOneWidget);
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

  testWidgets('a lap is read as its number and time, the fastest said aloud',
      (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(_app(const Scaffold(body: LapRows([60, 52, 58], C.blue))));
    expect(find.bySemanticsLabel(RegExp(r'^Lap 2\s+00:52, fastest$')),
        findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Lap 1\s+01:00$')), findsOneWidget);
    // The bar's percentage is not spoken.
    expect(find.bySemanticsLabel(RegExp('%')), findsNothing);
    h.dispose();
  });
}
