// Day Strain had no day stepper. Opened from Activity's "Today's strain" link,
// or once Home's past-day ring had brought you to one day, there was no way to
// reach another day's strain-by-time curve (OS-VHZ4Z7). It now wears the same
// stepper as Day Steps and Sleep, over the days that derived.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav, dayNavLabel;
import 'package:openstrap_edge/ui2/ui2.dart';

const _days = ['2026-11-14', '2026-11-13', '2026-11-12']; // newest first

/// Serves a strain curve for whichever day is asked, and records the asks.
class _Repo extends LocalRepository {
  final asked = <String>[];

  @override
  Future<List<String>> availableDays() async => _days;

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async {
    asked.add(date);
    final d = DateTime.parse(date);
    int at(int h) => DateTime(d.year, d.month, d.day, h).millisecondsSinceEpoch ~/ 1000;
    return {
      'strain': 5.0,
      'curve': [
        {'t': at(9), 'v': 1.0},
        {'t': at(18), 'v': 5.0},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {};
}

/// The load reaches the repo on a real event loop.
Future<void> _settle(WidgetTester t) async {
  for (final sw = Stopwatch()..start();
      sw.elapsed < const Duration(seconds: 10);) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
  }
}

Future<_Repo> _open(WidgetTester t, {String? day}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final repo = _Repo();
  final app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ChangeNotifierProvider<AppState>.value(
      value: app,
      child: DayStrainDetail(day: day),
    ),
  ));
  await _settle(t);
  return repo;
}

void main() {
  testWidgets('a past day steps back to the day before', (t) async {
    final repo = await _open(t, day: '2026-11-13');
    expect(repo.asked, ['2026-11-13']);
    expect(find.byType(DayNav), findsOneWidget);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(repo.asked.last, '2026-11-12');
    expect(find.text(dayNavLabel('2026-11-12')), findsOneWidget);
  });

  testWidgets('opened for today, it can still reach an earlier day',
      (t) async {
    final repo = await _open(t);
    expect(find.byType(DayNav), findsOneWidget);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(repo.asked.last, isNot(repo.asked.first));
    expect(_days, contains(repo.asked.last));
  });
}
