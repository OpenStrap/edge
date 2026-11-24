// A metric with no history at all tells the user what to do about it. Every
// metric used to say "Wear the band overnight to start the series", which is
// right for resting heart rate or sleep and wrong for a step count: steps,
// energy, strain and wear come from the day. Those now say "Wear the band
// through the day" (the strain screen's existing, translated hint).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

Future<void> _pump(WidgetTester t, String key) async {
  t.view.physicalSize = const Size(390 * 3, 1600 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: MetricDetail(key, data: MetricData())),
  ));
  await t.pumpAndSettle();
}

const _overnight = 'Wear your device overnight to start the series';
const _daytime = 'Wear your device through the day';

// Written out, not read from kDaytimeMetricKeys: a key dropped from the set
// must fail here rather than quietly lose its test.
const _daytimeKeys = [
  'steps',
  'calories',
  'strain',
  'trimp',
  'active_min',
  'wear',
  'hrr',
  'nap_min',
];

void main() {
  test('the daytime set is exactly the keys tested here', () {
    expect(kDaytimeMetricKeys, _daytimeKeys.toSet());
  });

  for (final key in _daytimeKeys) {
    testWidgets('$key, never recorded: wear it through the day', (t) async {
      await _pump(t, key);
      expect(find.text(_daytime), findsOneWidget);
      expect(find.text(_overnight), findsNothing);
    });
  }

  for (final key in ['resting_hr', 'hrv', 'sleep']) {
    testWidgets('$key, never recorded: still overnight', (t) async {
      await _pump(t, key);
      expect(find.text(_overnight), findsOneWidget);
      expect(find.text(_daytime), findsNothing);
    });
  }

  testWidgets('hrv with no band: the chart needs beats, not more nights',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const MetricDetail('hrv', data: MetricData()),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('beat-to-beat intervals'), findsOneWidget);
    expect(find.text(_overnight), findsNothing);
  });
}
