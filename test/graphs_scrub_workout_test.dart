// SCRUB + PANEL ON THE WORKOUT "HEART EFFORT BY DAY" CHART (Graphs PR phase 5,
// red tests).
//
// The For-you tab's Training load section draws seven day bars of heart effort
// (TRIMP). Upstream cannot read a bar; the fork's chart scrubbed (ChartScrub,
// bars). The panel reads LATEST on today, SELECTED on the touched bar, and a
// dash on a day that derived nothing, in the same inset box as every chart.
//
// The "Mechanical load" (tonnage) card above/below it takes the identical
// change but needs strength-set rows from the real database (LocalDb), which a
// widget test cannot seed without sqflite; it is covered at green by the same
// helper and listed as untested-by-fixture in phase5.report.md.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/scrub_surface_laws.dart';

/// Heart effort of 20 + 10 * (6 - back) points: today 80 ... 6 days ago 20,
/// with no figure 3 days ago.
const _gapBack = 3, _scrubbedBack = 5;

class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getProfile() async => {};

  @override
  Future<Map<String, dynamic>> getInsights() async => {
        'load': {
          'value': {'ctl': 34.0, 'atl': 40.0, 'tsb': -6.0}
        }
      };

  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from,
      int? to,
      Set<String> signals = const {},
      Set<String> extra = const {}}) async {
    final n = DateTime.now();
    return {
      'points': [
        for (var back = 6; back >= 0; back--)
          if (back != _gapBack)
            {
              't': DateTime(n.year, n.month, n.day - back, 12)
                      .millisecondsSinceEpoch ~/
                  1000,
              'v': 20.0 + 10 * (6 - back),
            },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async =>
      {'workouts': const []};

  @override
  Future<Map<String, dynamic>> getRecords() async => {};
}

Future<void> _mount(WidgetTester t, double scale) async {
  SharedPreferences.setMockInitialValues({});
  phone(t, 390, 700);
  // KNOWN, NOT THIS CHANGE: StartCard puts a Spacer in a Column that a scrolling
  // page gives unbounded height, which asserts in debug (release lays it out as
  // 0). It is on the For-you tab above the chart, so every pump here trips it.
  // Only that one assertion is dropped.
  final onError = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.exceptionAsString().contains('non-zero flex but incoming height')) {
      return;
    }
    onError?.call(d);
  };
  addTearDown(() => FlutterError.onError = onError);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = _Repo();
  await t.pumpWidget(scaledApp(
      scale,
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<LocaleController>.value(
              value: LocaleController.seed(null)),
        ],
        child: const Scaffold(body: WorkoutScreen()),
      )));
  // Bounded, not pumpAndSettle: the broken StartCard layout above can keep a
  // frame scheduled forever.
  for (var i = 0; i < 30; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  // The page is a lazy list: bring the chart's card in range first.
  await t.scrollUntilVisible(find.text('Heart effort by day'), 300,
      scrollable: find.byType(Scrollable).first);
  // Controls: the load section and its one chart are on screen.
  expect(find.text('Heart effort by day'), findsOneWidget);
  expect(find.byType(ChartFrame), findsOneWidget);
}

void main() {
  defineSurfaceLaws(SurfaceRig(
    name: 'workout heart effort',
    mount: _mount,
    plot: () => find.descendant(
        of: find.byType(ChartFrame), matching: find.byType(Scrubber)),
    slots: 7,
    bars: true,
    scrubbed: 6 - _scrubbedBack,
    gap: 6 - _gapBack,
    valueAt: (slot) => '^${20 + 10 * slot}points',
  ));
}
