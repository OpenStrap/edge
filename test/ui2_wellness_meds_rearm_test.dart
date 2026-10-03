// The dose reminder and the strap buzz are armed ahead of time and never look
// at the dose when they fire. Ticking a dose taken in Wellness wrote MedDb and
// repainted, and nothing re-armed — so a dose ticked at 07:56 still buzzed and
// still said "A dose is due" at 08:00. A write on this tab has to re-arm.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Spy extends AppState {
  _Spy() : super.forTesting();
  int rearms = 0;

  @override
  Future<void> refreshAiReminders() async => rearms++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('ticking a dose re-arms the reminders', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    await t.runAsync(() async {
      final db = await LocalDb.instance;
      await db.delete('med_def');
      await db.delete('med_dose');
      // Created days ago, due every day: today always has a slot to tick.
      await MedDb.putDef(
        db,
        MedDef(
          key: 'vitamin_d',
          label: 'Vitamin D',
          schedule: const [MedSchedule(8 * 60, [])],
          createdAt: DateTime.now()
              .subtract(const Duration(days: 3))
              .millisecondsSinceEpoch,
        ),
      );
    });

    final app = _Spy();
    addTearDown(app.dispose);
    WellnessScreen.tabRequest.value = WellnessScreen.medsTab;
    addTearDown(() => WellnessScreen.tabRequest.value = -1);

    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: Builder(
            builder: (c) => Scaffold(
              backgroundColor: P.of(c).bg,
              body: const WellnessScreen(),
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 16));
      }
    }

    await settle();
    expect(find.byType(MedRow), findsOneWidget,
        reason: 'the tab never showed the dose, so nothing after this is a test');
    final before = app.rearms;

    await t.tap(find.byType(MedRow));
    // The write lands on sqflite's real event loop; wait for it, bounded.
    for (var i = 0; i < 50 && app.rearms == before; i++) {
      await settle();
    }

    expect(app.rearms, greaterThan(before));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
