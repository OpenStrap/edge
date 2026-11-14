// The cycle screen's "day in this cycle" card must fit a phone at any text
// size.
//
// The headline row put the day number and "counted from your last logged
// start" side by side with nothing allowed to wrap, and the header row put
// its label before a Spacer and the phase pill. At a 390 pt width that
// overflowed by 147 pt in the test font, and by less, but still, with larger
// system text (iOS goes to 3.1x) or a longer language.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/cycle_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Repo extends LocalRepository {
  _Repo({this.median});
  final num? median;

  @override
  Future<Map<String, dynamic>> getCycle() async => {
        'enabled': true,
        'phase': 'follicular',
        'cycle_day': 5,
        'median_length': ?median,
        'logs': [
          {'date': '2026-11-09', 'kind': 'start'},
        ],
      };

  @override
  Future<Map<String, List<String>>> getCycleSymptoms() async => const {};
}

Future<void> _pump(WidgetTester t, {num? median, double scale = 1}) async {
  t.view.physicalSize = const Size(390 * 3, 4000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = _Repo(median: median);
  addTearDown(app.dispose);
  await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: CycleTab()),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  for (final scale in const [1.0, 3.1]) {
    testWidgets('no median yet, ${scale}x text', (t) async {
      // The pump is the assertion: a RenderFlex overflow fails it.
      await _pump(t, scale: scale);
      expect(find.textContaining('counted from your last logged start'),
          findsOneWidget);
    });

    testWidgets('with a median, ${scale}x text', (t) async {
      await _pump(t, median: 29, scale: scale);
      expect(find.textContaining('of about 29'), findsOneWidget);
      // The phase name wraps at large text instead of ending in an ellipsis.
      expect(t.widget<Pill>(find.byType(Pill).first).wrap, scale > 1.3);
    });
  }
}
