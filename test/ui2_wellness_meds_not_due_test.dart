// "in wellness medication, after I added medication, the medicine component —
// the actual tracking component — isn't visible."
//
// `_medication` branched on `_meds`, then rendered `_slots`. They are not the
// same list: a medication due on days that are not today — or added after its
// own time had already passed, which `slotsForDay` deliberately does not
// backfill — leaves `_meds` non-empty and `_slots` empty, and the `Surface`
// drew an empty Column. Added a medication, no tracker, no reason given.
//
// One case, at one size: a medication present, nothing due today. The tab has
// to say why and print the schedule instead of an empty box.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The slot time follows the user's clock format; pin the 24-hour one.
    ClockFormatController.seed(ClockFormat.h24);
  });
  tearDown(ClockFormatController.debugReset);

  testWidgets('a medication with nothing due today says so', (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    // `runAsync`, not a bare await: sqflite answers on the real event loop and
    // the test zone's fake clock never gets there on its own.
    await t.runAsync(() async {
      final db = await LocalDb.instance;
      await db.delete('med_def');
      await db.delete('med_dose');
      // Due only on the day AFTER today, so this never resolves a slot for the
      // day the screen is on, whatever day the suite runs.
      final tomorrow = DateTime.now().add(const Duration(days: 1)).weekday;
      await MedDb.putDef(
        db,
        MedDef(
          key: 'vitamin_d',
          label: 'Vitamin D',
          schedule: [MedSchedule(8 * 60, [tomorrow])],
        ),
      );
    });

    final app = AppState.forTesting();
    addTearDown(app.dispose);

    // The deep link the dose reminder uses, which is what makes an invisible
    // tracker reachable from the lock screen.
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
    // sqflite answers on a real event loop; pumping alone leaves the spinner up
    // and every finder below passing against an empty tab.
    for (var i = 0; i < 40; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 16));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 32));
    }

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the tab never loaded, so nothing after this is a test');
    // Not "Nothing scheduled" — something IS scheduled, just not today.
    expect(find.text('Nothing due today'), findsOneWidget);
    expect(find.text('Nothing scheduled'), findsNothing);
    // What you take and when, which is the reason itself.
    expect(find.text('Vitamin D'), findsOneWidget);
    expect(find.textContaining('08:00'), findsWidgets);
    expect(find.byType(MedRow), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
