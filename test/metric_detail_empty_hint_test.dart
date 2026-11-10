// A metric with no history at all tells the user what to do about it. Every
// metric used to say "Wear the band overnight to start the series", which is
// right for resting heart rate or sleep and wrong for a step count: steps,
// energy, strain and wear come from the day. Those now say "Wear the band
// through the day" (the strain screen's existing, translated hint).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

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

const _overnight = 'Wear the band overnight to start the series';
const _daytime = 'Wear the band through the day';

void main() {
  for (final key in kDaytimeMetricKeys) {
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
}
