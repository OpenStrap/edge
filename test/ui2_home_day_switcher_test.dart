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
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
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

/// Walk the app through [states] one transition at a time, the way the
/// engine reports them.
void _lifecycle(WidgetTester t, List<AppLifecycleState> states) {
  for (final st in states) {
    t.binding.handleAppLifecycleStateChanged(st);
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

  const background = [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ];

  test('a past day is kept only for a short absence on the same day', () {
    const day = '2026-10-31';
    expect(
        homeReturnsToToday(
            dayAtHide: day, dayNow: day, away: const Duration(minutes: 5)),
        isFalse);
    expect(
        homeReturnsToToday(
            dayAtHide: day, dayNow: day, away: const Duration(minutes: 29)),
        isFalse);
    expect(
        homeReturnsToToday(dayAtHide: day, dayNow: day, away: kHomeKeepDayAway),
        isTrue);
    // Midnight while away: today, however short the trip.
    expect(
        homeReturnsToToday(
            dayAtHide: day,
            dayNow: '2026-11-01',
            away: const Duration(minutes: 2)),
        isTrue);
    // The leave was never seen: the absence is unknown.
    expect(homeReturnsToToday(dayAtHide: null, dayNow: day, away: Duration.zero),
        isTrue);
  });

  testWidgets('a quick trip to another app keeps the past day', (t) async {
    debugHomeAwayOverride = const Duration(minutes: 2);
    addTearDown(() => debugHomeAwayOverride = null);
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
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(find.text('42'), findsOneWidget);

    _lifecycle(t, background);
    await _settle(t);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('Back to today'), findsOneWidget);
  });

  testWidgets('following today stays on today after any absence', (t) async {
    debugHomeAwayOverride = const Duration(minutes: 2);
    addTearDown(() => debugHomeAwayOverride = null);
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
    expect(find.text('70'), findsOneWidget);

    _lifecycle(t, background);
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    expect(find.text('Back to today'), findsNothing);
  });

  testWidgets('coming back after a long absence opens on today', (t) async {
    // Home lives on in the tab stack, so a day stepped back onto used to
    // survive a night in the background: Saturday morning opened on Friday's
    // rings with "Back to today" under them.
    debugHomeAwayOverride = kHomeKeepDayAway;
    addTearDown(() => debugHomeAwayOverride = null);
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
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(find.text('42'), findsOneWidget);

    // A glance at Control Center only makes the app inactive: stay put.
    _lifecycle(t, const [AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await _settle(t);
    expect(find.text('42'), findsOneWidget);

    // Backgrounded and reopened: today, and no "Back to today".
    _lifecycle(t, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    expect(find.text('42'), findsNothing);
    expect(find.text('Back to today'), findsNothing);
  });

  testWidgets('a failed read on the way back drops the past day', (t) async {
    // The past day's rings must not stay up under today's header while the
    // read runs, nor for good when it fails.
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _FlakyTodayRepo();
    app.repo = repo;

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
    expect(find.text('42'), findsOneWidget);

    repo.failToday = true;
    debugHomeAwayOverride = const Duration(hours: 8);
    addTearDown(() => debugHomeAwayOverride = null);
    _lifecycle(t, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await t.pump();
    expect(find.text('42'), findsNothing);
    await _settle(t);
    expect(find.text('42'), findsNothing);
    expect(find.text('Today could not be read'), findsOneWidget);
  });

  testWidgets('"Back to today" follows today instead of pinning a date',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeController>.value(
            value: ThemeController.seed(
                AppThemeChoice.light, Brightness.light)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    await t.tap(find.text('Back to today'));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    // Stored as "today" (null), which is what the day ring opens on — a
    // pinned date would hand the detail screen today's label instead.
    t.widget<RingTrio>(find.byType(RingTrio)).onOpen!(HomeRingKind.sleep);
    await _settle(t);
    expect(t.widget<SleepDetail>(find.byType(SleepDetail)).day, isNull);
  });

  testWidgets('on a past day the day breakdown opens THAT day', (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    // Providers above the app, so the pushed route can see them too.
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeController>.value(
            value: ThemeController.seed(
                AppThemeChoice.light, Brightness.light)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);

    final row = find.text('Breakdown of your day');
    await t.scrollUntilVisible(row, 300,
        scrollable: find.byType(Scrollable).first);
    await t.tap(row);
    await _settle(t);
    expect(t.widget<DayTimelineScreen>(find.byType(DayTimelineScreen)).day,
        _yesterday);
  });

  // The glance tiles show the switcher's day, so the screen behind a tap has
  // to be that day too. They used to open the trend screen on today's window:
  // a past day's "2,500" steps landed on today's count.
  for (final (label, key) in [
    ('2,500', 'steps'),
    ('60', 'resting_hr'),
    ('300', 'calories'),
  ]) {
    testWidgets('on a past day the $key tile opens THAT day', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.repo = _Repo();

      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ThemeController>.value(
              value: ThemeController.seed(
                  AppThemeChoice.light, Brightness.light)),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: HomeScreen(hour: 9)),
        ),
      ));
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);

      final tile = find.text(label);
      await t.scrollUntilVisible(tile, 300,
          scrollable: find.byType(Scrollable).first);
      await t.tap(tile);
      await _settle(t);

      expect(find.byType(MetricDetail), findsNothing);
      if (key == 'steps') {
        expect(t.widget<DayStepsDetail>(find.byType(DayStepsDetail)).day,
            _yesterday);
      } else {
        final inv = t.widget<Investigate>(find.byType(Investigate));
        expect(inv.metricKey, key);
        expect(inv.day, _yesterday);
      }
    });
  }

  testWidgets('back on today the sleep ring opens the held-over night',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeController>.value(
            value: ThemeController.seed(
                AppThemeChoice.light, Brightness.light)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Next day'));
    await _settle(t);

    // Today, reached through the switcher, is still today: no explicit day,
    // so Sleep resolves the night the ring is drawn from.
    t.widget<RingTrio>(find.byType(RingTrio)).onOpen!(HomeRingKind.sleep);
    await _settle(t);
    expect(t.widget<SleepDetail>(find.byType(SleepDetail)).day, isNull);
  });

  test('a past day carries the learned sleep need, so its ring has a target',
      () async {
    final d = await HomeData.loadForDay(_NeedRepo(), _yesterday);
    expect(d.sleepMin.value, 250);
    expect(d.sleepNeedMin.value, 465);
  });

  test('a past day with no learned need stays without a target', () async {
    final d = await HomeData.loadForDay(_Repo(), _yesterday);
    expect(d.sleepNeedMin.value, isNull);
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

  testWidgets('the past-day empty card follows the app language', (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _EmptyPastRepo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);

    final l = AppLocalizations.of(t.element(find.byType(HomeScreen)))!;
    await t.tap(find.bySemanticsLabel(l.metricDetailPreviousDay));
    await _settle(t);

    expect(find.text('Keine Daten für diesen Tag'), findsOneWidget);
    expect(find.text('No data for this day'), findsNothing);
  });

  testWidgets('a past day with gaps does not call itself today', (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _PartialPastRepo();

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

    final title = find.text('Some of this day\'s data is missing');
    await t.scrollUntilVisible(title, 300,
        scrollable: find.byType(Scrollable).first);
    expect(title, findsOneWidget);
    expect(find.text('Some of today\'s data is missing'), findsNothing);
  });

  testWidgets('a failed read still shows the alarm door', (t) async {
    // The alarm lives on AppState, not HomeData, so the error card must not
    // take it down with it.
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _FailingRepo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);

    expect(find.text('Today could not be read'), findsOneWidget);
    expect(find.text('Set an alarm'), findsOneWidget);
  });

  // A day switch kept the old day on screen while it loaded, and for good if
  // the read threw: the stepper named yesterday while the rings, tiles and
  // greeting date were still today's, and nothing said the read had failed.
  testWidgets('a past day that fails to load does not keep today on screen',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _PastDayThrowsRepo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);

    expect(find.text('70'), findsNothing);
    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.text('Today could not be read'), findsNothing);

    await t.ensureVisible(find.text('Back to today'));
    await t.tap(find.text('Back to today'));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    expect(find.textContaining('could not be read'), findsNothing);
  });

  // Home is never disposed (the shell's IndexedStack), so "Back to today"
  // storing today's literal date left the tab pinned to that date once the
  // clock crossed midnight.
  test('stepping onto today stores "today", not a date that goes stale', () {
    final evening = DateTime(2026, 10, 16, 22);
    expect(homeSwitcherDay('2026-10-16', now: evening), isNull);
    expect(homeSwitcherDay('2026-10-15', now: evening), '2026-10-15');
    expect(homeSwitcherDay(_today), isNull);
    expect(homeSwitcherDay(_yesterday), _yesterday);
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

class _FailingRepo extends _EmptyPastRepo {
  @override
  Future<List<String>> availableDays() async => throw StateError('read failed');
}

/// Yesterday has a readiness and a strain but no resting HR and no
/// calories, so the glance has more than one absence to summarise.
class _PartialPastRepo extends _EmptyPastRepo {
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async =>
      {'readiness': 42};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async =>
      {'strain': 9.9};
}

/// `getDaySleepV2` as the live repo writes it once a need has been learned:
/// `need_min` is a plain minute count beside the night's duration.
class _NeedRepo extends _Repo {
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async =>
      {'has_sleep': true, 'duration_min': 250, 'need_min': 465};
}

/// Today reads fine; any past day throws on its first per-day read.
class _PastDayThrowsRepo extends _Repo {
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async =>
      throw StateError('read failed');
}

/// [_Repo] whose today read can be made to throw.
class _FlakyTodayRepo extends _Repo {
  bool failToday = false;
  @override
  Future<Map<String, dynamic>> getToday() async {
    if (failToday) throw StateError('read failed');
    return super.getToday();
  }
}
