// A write landed underneath a screen that is already on screen. Does it show?
//
// The bug this pins: "I imported something, and to see those workouts in
// Workouts I have to switch to another tab and come back." Every screen here
// loads in `initState`, and three of the five tabs are kept alive by the
// shell's IndexedStack for the life of the process — so "loads once" means
// "until the app is relaunched", and leaving the tab was the workaround.
//
// The test below writes UNDERNEATH a live screen and asserts the screen
// updates while keeping the SAME State object. Asserting only that the text
// appears would pass for the same wrong reason switching tabs does — a fresh
// widget reading the database for the first time.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// The rows an import would have written, behind the repo the screen reads.
///
/// Water is a JOURNAL metric: written by the journal screen, by an imported
/// journal CSV, and by this tab itself — exactly the "somebody else wrote it"
/// case the report is about.
class _Repo extends LocalRepository {
  Map<String, JournalMetricValue> journal = const {};
  int reads = 0;

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async {
    reads++;
    return journal;
  }

  Map<String, JournalMetricValue>? posted;
  @override
  Future<void> postJournalMetrics(
      String date, Map<String, JournalMetricValue> fields) async {
    posted = journal = {...fields};
  }
}

/// Frames until [f] appears, or give up.
///
/// `runAsync` and not `pumpAndSettle`: the screen's load goes to sqflite, which
/// answers from another isolate in REAL time, and a widget test's fake clock
/// never lets that reply land. `pumpAndSettle` would not help either — the
/// loading state draws an indeterminate spinner, which never settles.
Future<void> _until(WidgetTester t, Finder f, {int n = 60}) async {
  for (var i = 0; i < n && f.evaluate().isEmpty; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }
}

Widget _app(AppState app, {LocaleController? locale}) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<LocaleController>.value(
            value: locale ?? LocaleController.seed(null),
          ),
        ],
        child: const Scaffold(body: NutritionScreen()),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_revision_reload_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('water logged underneath the live tab reaches it', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _Repo();
    app.repo = repo;

    await t.pumpWidget(_app(app));
    await _until(t, find.text('None yet'));
    expect(find.text('None yet'), findsOneWidget);

    // The screen that is about to be asked to notice.
    final before = t.state(find.byType(NutritionScreen));

    // Something else writes — an import, the journal screen, a headless
    // derive. All of them raise the one signal.
    repo.journal = const {'water_ml': JournalMetricValue(1500)};
    app.bumpInsights();
    await _until(t, find.text('1.5 L'));

    expect(find.text('1.5 L'), findsOneWidget);
    // THE POINT: same State, so the number arrived by re-reading and not by
    // the screen being thrown away and built again — which is what leaving the
    // tab and coming back used to do.
    expect(identical(t.state(find.byType(NutritionScreen)), before), isTrue,
        reason:
            'the screen was remounted — that is the workaround, not the fix');
  });

  testWidgets('a rebuild is not a write', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _Repo();
    app.repo = repo;

    await t.pumpWidget(_app(app));
    await _until(t, find.text('None yet'));
    final first = repo.reads;
    expect(first, greaterThan(0));

    // AppState ticks at ~1 Hz with live HR and a log line. A refresh signal
    // riding on that would re-read the database every second — the rebuild
    // storm this must not become, and the harder bug of the two to diagnose.
    for (var i = 0; i < 5; i++) {
      app.notifyListeners();
      await t.pump();
    }
    expect(repo.reads, first,
        reason: 'the screen re-read with nothing having landed');
  });

  testWidgets('a language switch reaches the live tab', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _Repo();
    app.repo = repo;
    final locale = LocaleController.seed(null);
    addTearDown(locale.dispose);

    await t.pumpWidget(_app(app, locale: locale));
    await _until(t, find.text('None yet'));
    final before = t.state(find.byType(NutritionScreen));
    final reads = repo.reads;
    expect(reads, greaterThan(0));

    // Nothing wrote underneath the screen — only the language changed.
    // `NutritionData` bakes `AppLocalizations` strings into what it reads, so
    // this has to reach the screen exactly like a durable write does, or a
    // switch to Spanish leaves English on screen until something else forces
    // a reload.
    await locale.setCode('es');
    for (var i = 0; i < 60 && repo.reads <= reads; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }

    expect(repo.reads, greaterThan(reads),
        reason: 'the screen did not notice the language changed');
    expect(identical(t.state(find.byType(NutritionScreen)), before), isTrue,
        reason:
            'the screen was remounted — that is the workaround, not the fix');
  });

  // ── the signal has to be raised where the writes are ──────────────────────
  //
  // A behavioural test of the importers needs a vendor export, a database and
  // the derivation engine; what it would actually be checking is one line, so
  // this checks that line. Every import path lands rows into a database the
  // live tabs have already finished reading.
  test('every AppState importer raises the signal', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();
    for (final m in const [
      'Future<int> importNoopCsv(',
      'Future<int> importWhoopCsvs(',
      'Future<int> importEdgeBackup(',
    ]) {
      final at = src.indexOf(m);
      expect(at, greaterThan(0), reason: '$m has moved or been renamed');
      // The method body, to its `return` — long enough to hold the whole of
      // any of the three, short enough not to reach the next one.
      final body = src.substring(at, at + 2600);
      expect(body, contains('bumpInsights()'),
          reason: '$m writes durable rows and no screen is told');
    }
  });

  test('the screens the shell keeps alive re-read', () {
    // Home, Health, Nutrition, Workout, Wellness are the five tabs; Cycle
    // lives inside Wellness and shares its lifetime.
    for (final f in const [
      'home_screen',
      'health_screen',
      'nutrition_screen',
      'workout_screen',
      'wellness_screen',
      'cycle_screen',
    ]) {
      expect(File('lib/ui2/screens/$f.dart').readAsStringSync(),
          contains('with RevisionReload'),
          reason: '$f loads once and never reads again');
    }
  });

  testWidgets('a water tap steps from the stored day, not the last load',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _Repo()
      ..journal = const {'water_ml': JournalMetricValue(2000)};
    app.repo = repo;

    await t.pumpWidget(_app(app));
    await _until(t, find.text('2.0 L'));
    expect(find.text('2.0 L'), findsOneWidget);

    // Midnight passes with the tab open and nothing bumps it: the tile still
    // holds yesterday's 2.0 L, but today has nothing stored yet.
    repo.journal = const {};
    await t.tap(find.byIcon(LucideIcons.plus).last);
    for (var i = 0; i < 20 && repo.posted == null; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }

    expect(repo.posted?['water_ml']?.value, 250,
        reason: 'yesterday\'s total was carried into today');
  });
}
