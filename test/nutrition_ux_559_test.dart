// #559: the Nutrition tab, made easier to use — search over everything ever
// logged, a meal time that can be set after the fact, entries that can be
// edited rather than only deleted, and today's protein against its target.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart'
    show OsTextField;
import 'package:openstrap_edge/ui2/screens/log_food.dart';
import 'package:openstrap_edge/ui2/screens/nutrition_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

FoodEntry _e(String id, String label,
        {String? date, double? kcal, double? protein, int? at}) =>
    FoodEntry(
      id: id,
      date: date ?? todayLabel(),
      meal: 'lunch',
      label: label,
      atTs: at,
      kcal: kcal,
      proteinG: protein,
      sodiumMg: 400,
      note: 'kept',
    );

/// Real sqflite work runs on another isolate, so fake-async pumping alone
/// never sees it finish.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester t, Widget body, {AppState? app}) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  Widget home = Scaffold(body: body);
  if (app != null) {
    home = ChangeNotifierProvider<AppState>.value(value: app, child: home);
  }
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
    home: home,
  ));
  await _settle(t);
}

Finder _field(String upperLabel) => find.descendant(
      of: find.widgetWithText(OsTextField, upperLabel),
      matching: find.byType(TextField),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ClockFormatController.seed(ClockFormat.h24);
    await LocalDb.close();
    LocalDb.dbName = 'nutrition_ux_559_test.db';
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
    db = await LocalDb.instance;
  });
  tearDown(() async {
    ClockFormatController.debugReset();
    await LocalDb.close();
  });

  test('update rewrites in place: same id, created_at kept, totals follow',
      () async {
    await NutritionDb.put(db, _e('f1', 'Chocolate', kcal: 100, protein: 2));
    final created = (await db.query('food_entry')).single['created_at'];
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await NutritionDb.update(db, _e('f1', 'Chocolate', kcal: 500, protein: 8));
    final rows = await db.query('food_entry');
    expect(rows, hasLength(1));
    expect(rows.single['created_at'], created);
    final day = rollupDay(todayLabel(),
        await NutritionDb.entriesForDay(db, todayLabel()),
        today: todayLabel());
    expect(day.kcal.value, 500);
    expect(day.protein.value, 8);
  });

  test('recent(query) searches the whole history, not the last five',
      () async {
    for (var i = 0; i < 8; i++) {
      await NutritionDb.put(db, _e('f$i', 'Food $i', kcal: 10));
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect((await NutritionDb.recent(db, limit: 5)).map((e) => e.label),
        isNot(contains('Food 0')));
    expect((await NutritionDb.recent(db, query: 'food 0')).single.label,
        'Food 0');
  });

  test('recent(query) reads % and _ as text, not wildcards', () async {
    await NutritionDb.put(db, _e('a', 'Milk 50% less fat', kcal: 10));
    await NutritionDb.put(db, _e('b', 'Milk 500 ml', kcal: 10));
    await NutritionDb.put(db, _e('c', 'a_b bar', kcal: 10));
    await NutritionDb.put(db, _e('d', 'axb bar', kcal: 10));
    expect((await NutritionDb.recent(db, query: '50%')).single.label,
        'Milk 50% less fat');
    expect((await NutritionDb.recent(db, query: 'a_b')).single.label,
        'a_b bar');
  });

  testWidgets('the log sheet searches past foods', (t) async {
    await t.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await NutritionDb.put(db, _e('f$i', 'Food $i', kcal: 10));
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }
      await NutritionDb.put(db, _e('fz', 'Oat porridge', kcal: 300));
    });
    await _pump(t, const LogFoodSheet());
    expect(find.text('Food 0'), findsNothing, reason: 'only five by default');
    await t.enterText(_field('SEARCH YOUR FOODS'), 'Food 0');
    await _settle(t);
    expect(find.widgetWithText(FoodRow, 'Food 0'), findsOneWidget);
    expect(find.text('Oat porridge'), findsNothing);
    await t.enterText(_field('SEARCH YOUR FOODS'), 'zzz');
    await _settle(t);
    expect(find.text('Nothing you have logged matches that.'), findsOneWidget);
  });

  testWidgets('a meal can be logged at a chosen time', (t) async {
    await _pump(t, const LogFoodSheet(meal: 'breakfast'));
    await t.tap(find.text('Time'));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.keyboard_outlined));
    await t.pumpAndSettle();
    final inputs = find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField));
    await t.enterText(inputs.at(0), '07');
    await t.enterText(inputs.at(1), '15');
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(find.text('07:15'), findsOneWidget);

    await t.tap(find.text('I ate breakfast'));
    await _settle(t);
    final e = (await t.runAsync(
        () => NutritionDb.entriesForDay(db, todayLabel())))!.single;
    final at = DateTime.fromMillisecondsSinceEpoch(e.atTs! * 1000);
    expect((at.hour, at.minute), (7, 15));
    expect(dayLabelOf(at), todayLabel());
  });

  testWidgets('an entry is edited from the Today tab, not just deleted',
      (t) async {
    final n = DateTime.now();
    final noon =
        DateTime(n.year, n.month, n.day, 12, 30).millisecondsSinceEpoch ~/ 1000;
    await t.runAsync(() => NutritionDb.put(
        db, _e('f1', 'Chocolate bar', kcal: 120, protein: 2, at: noon)));
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await _pump(t, const NutritionScreen(), app: app);

    await t.tap(find.text('Chocolate bar'));
    await t.pumpAndSettle();
    expect(find.text('Edit this entry'), findsOneWidget);
    await t.enterText(_field('ENERGY (KCAL)'), '480');
    await t.tap(find.descendant(
        of: find.byType(LogFoodSheet), matching: find.text('Dinner')));
    await t.pump();
    await t.ensureVisible(find.text('Save'));
    await t.tap(find.text('Save'));
    await _settle(t);

    final rows = (await t.runAsync(
        () => NutritionDb.entriesForDay(db, todayLabel())))!;
    expect(rows, hasLength(1));
    final e = rows.single;
    expect(e.id, 'f1');
    expect(e.kcal, 480);
    expect(e.meal, 'dinner');
    expect(e.atTs, noon, reason: 'an untouched time stays what it was');
    expect((e.sodiumMg, e.note), (400, 'kept'),
        reason: 'fields the form does not show survive an edit');
    expect(find.text('480'), findsOneWidget, reason: "today's total follows");
  });

  testWidgets("today's protein is shown against the target", (t) async {
    await t.runAsync(() async {
      await NutritionDb.put(db, _e('a', 'Eggs', kcal: 200, protein: 30));
      await NutritionDb.put(db, _e('b', 'Yoghurt', kcal: 100, protein: 15));
    });
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.user = {'protein_target': 120};
    await _pump(t, const NutritionScreen(), app: app);

    expect(find.text('Protein today'), findsOneWidget);
    expect(find.text('45 g'), findsOneWidget);
    expect(find.text('75 g to go'), findsOneWidget);
  });
}
