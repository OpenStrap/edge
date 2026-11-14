import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _HistoryRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getProfile() async => {'weight_kg': 70.0};
  @override
  Future<Map<String, dynamic>> getInsights() async => {};
  @override
  Future<Map<String, dynamic>> getRecords() async => {'workouts_tracked': 1};
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      {'points': []};
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async => {
        'workouts': [
          {
            'id': 'layout-session',
            'type': 'running',
            'start_ts': DateTime(2026, 11, 10, 7).millisecondsSinceEpoch ~/ 1000,
            'duration_min': 42,
            'strain': 8.1,
            'calories': 410,
            'max_hr': 171,
          },
        ],
      };
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    // Layout is under test. Keep SQLite replies on the widget test's event
    // loop so rendering needs no real-time waits for another isolate.
    databaseFactory = databaseFactoryFfiNoIsolate;
    await LocalDb.close();
    LocalDb.dbName = 'ui2_workout_history_layout_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
  });
  tearDownAll(() async => LocalDb.close());

  for (final scale in [1.0, 1.3]) {
    testWidgets('German History at 390 px and ${scale}x keeps session actions inside the card', (t) async {
      // WHY: CLAIM(history-retime-fits). The clock and unconstrained German
      // "Fix the times" label overflowed the real History card at 1.3x.
      // Exercise the screen without a guide, then check the rendered action
      // against its card and keep the delete control usable as well.
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final app = AppState.forTesting()..repo = _HistoryRepo();
      addTearDown(app.dispose);
      final l = lookupAppLocalizations(const Locale('de'));
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<UnitsController>(
              create: (_) => UnitsController.seed(UnitSystem.metric)),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          locale: const Locale('de'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: WorkoutScreen()),
        ),
      ));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text(l.workoutTabHistory));
      await t.pumpAndSettle();
      await t.tap(find.text(l.workoutTabHistory));
      await t.pumpAndSettle();
      final retime = find.byWidgetPredicate((w) =>
          w is Pressable && w.semanticLabel == l.workoutFixTimesOnSessionLabel);
      await t.ensureVisible(retime);
      await t.pumpAndSettle();
      expect(retime.hitTestable(), findsOneWidget);
      final label = find.text(l.workoutFixTimes);
      expect(label, findsOneWidget);
      final surface = find.ancestor(of: label, matching: find.byType(Surface)).first;
      final card = t.getRect(surface);
      final text = t.getRect(label);
      expect(text.left, greaterThanOrEqualTo(card.left + S.x4));
      expect(text.right, lessThanOrEqualTo(card.right - S.x4));
      final paragraph = t.renderObject<RenderParagraph>(label);
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'the action stays readable in full');
      final delete = find.byWidgetPredicate((w) =>
          w is Pressable && w.semanticLabel == l.workoutDeleteSessionLabel);
      await t.ensureVisible(delete);
      await t.pumpAndSettle();
      expect(delete.hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
