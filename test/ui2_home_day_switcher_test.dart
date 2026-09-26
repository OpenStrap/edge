// Home used to be fixed to today, with no way to look at yesterday's rings
// without leaving the tab for a detail screen. This pins the switcher: it
// reuses [DayNav] (the same day-stepper the Sleep/Strain/HRV detail screens
// already wear) rather than a new control, and it steps through a PAST day
// on the app's own live-repo path — not an injected `HomeData` — so a real
// regression in the wiring between `HomeScreen` and `HomeData.loadForDay`
// would actually fail this.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

// The real device day, not a fixed string: `HomeScreen._load` decides
// "today" by comparing the switcher's day against `todayLabel()`, exactly
// as `HomeData.load`'s own callers do, so the fixture has to agree with the
// same clock or "step forward back to today" would (wrongly, for the
// fixture's sake only) take the `loadForDay` path instead.
final _today = todayLabel();
final _yesterday = dayLabelOf(DateTime.now().subtract(const Duration(days: 1)));

/// Two distinct days, each with its own readiness/strain/steps — so a test
/// asserting the switcher actually swapped the screen's numbers, not just
/// re-rendered the same ones.
class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 70, 'confidence': .8, 'tier': 'HIGH'},
          'resting_hr': {'value': 50, 'confidence': .8, 'tier': 'HIGH'},
          'strain': {'value': 5.0, 'confidence': .8, 'tier': 'ESTIMATE'},
          'steps': {'value': 1000, 'confidence': .8, 'tier': 'ESTIMATE'},
        },
        'sleep': {
          'duration_min': {'value': 400, 'confidence': .8, 'tier': 'HIGH'},
        },
        'status': {'today_day': _today},
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {'name': 'Alex'};
  @override
  Future<List<String>> availableDays() async => [_today, _yesterday];

  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async =>
      {'readiness': 42, 'resting_hr': 60};

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async =>
      {'strain': 9.9, 'steps': 2500, 'calories': 300, 'calories_total': 2000};

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async =>
      {'has_sleep': true, 'duration_min': 250};
}

Future<void> _settle(WidgetTester t, {int n = 40}) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('stepping to the previous day loads and shows ITS numbers',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);

    // Today's own readiness ring is showing (its number is real Text, not
    // canvas-painted), and so is the stepper.
    expect(find.text('70'), findsOneWidget);
    expect(find.bySemanticsLabel('Previous day'), findsOneWidget);
    // The newest day: forward is a dead arrow.
    expect(find.bySemanticsLabel('Next day'), findsOneWidget);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);

    // Yesterday's readiness (42, off getDayOverview) replaced today's (70) —
    // proof the screen actually reloaded through `HomeData.loadForDay`
    // rather than just relabelling the same data.
    expect(find.text('70'), findsNothing);
    expect(find.text('42'), findsOneWidget);

    // Stepping forward again returns to today's own number.
    await t.tap(find.bySemanticsLabel('Next day'));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
  });

  testWidgets('a past day with nothing recorded says so, not "sync the band"',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _EmptyPastRepo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);

    expect(find.text('No data for this day'), findsOneWidget);
    expect(find.text('Sync the band'), findsNothing);
  });
}

/// Today has a real reading; every past day is genuinely bare (no bundle at
/// all, not just an absent field) — the case that used to fall through to
/// the first-run "Sync the band" card regardless of which day it was.
class _EmptyPastRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 70, 'confidence': .8, 'tier': 'HIGH'},
        },
        'sleep': <String, dynamic>{},
        'status': {'today_day': _today},
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<List<String>> availableDays() async => [_today, _yesterday];
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => const {};
}
