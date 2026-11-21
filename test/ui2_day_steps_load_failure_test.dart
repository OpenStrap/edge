// A read that throws on the Steps screen (a busy or locked database is
// enough) used to just clear the spinner. On a first load that drew the empty
// default as "No steps counted"; after a day change it left the previous
// day's numbers under the new day's label. Both now end in a retryable card.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/day_steps.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav;
import 'package:openstrap_edge/ui2/ui2.dart';

final _nine = DateTime(2026, 10, 2, 9).millisecondsSinceEpoch ~/ 1000;

/// Answers 2026-10-02 with one walk; throws for any day in [failDays].
class _Repo extends LocalRepository {
  _Repo(this.failDays);
  final Set<String> failDays;

  @override
  Future<List<String>> availableDays() async =>
      const ['2026-10-02', '2026-10-01'];

  @override
  Future<Map<String, dynamic>> getDaySteps(String date) async {
    if (failDays.contains(date)) throw StateError('database is locked');
    return {
      'spans': [
        {
          'start_ts': _nine,
          'end_ts': _nine + 1800,
          'steps': 4321,
          'source': 'phone',
        },
      ],
      'total': 4321,
      'phone': 4321,
    };
  }
}

Future<void> _pump(WidgetTester t, LocalRepository repo) async {
  t.view.physicalSize = const Size(390 * 3, 2000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo;
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const DayStepsDetail(day: '2026-10-02'),
    ),
  ));
  await t.pump();
  await t.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a first read that throws is not "no steps"', (t) async {
    final repo = _Repo({'2026-10-02'});
    await _pump(t, repo);
    expect(find.textContaining('No steps counted'), findsNothing);
    expect(find.textContaining('could not be read'), findsOneWidget);

    repo.failDays.clear();
    await t.tap(find.text('Try again'));
    await t.pump();
    await t.pump();
    expect(find.textContaining('could not be read'), findsNothing);
    expect(find.textContaining('4,321'), findsWidgets);
  });

  testWidgets('a failed day change drops the old day\'s numbers', (t) async {
    await _pump(t, _Repo({'2026-10-01'}));
    expect(find.textContaining('4,321'), findsWidgets);

    await t.tap(find.descendant(
        of: find.byType(DayNav),
        matching: find.byIcon(LucideIcons.chevronLeft)));
    await t.pump();
    await t.pump();
    expect(find.textContaining('4,321'), findsNothing);
    expect(find.textContaining('could not be read'), findsOneWidget);
  });
}
