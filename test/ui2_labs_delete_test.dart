// LABS, REMOVABLE — the surface for a store that already had the deletes.
//
// `LocalDb.deleteLabResult` and `deleteLabMarkerDef` were both written and
// both tested, and neither had a caller anywhere in the app: blood work typed
// by hand was permanent. This is that path end to end, RENDERED rather than
// read, because a Row that overflows or a control under the 44 pt floor is not
// something the widget tree tells you about.
//
// Two acts, deliberately not one. Removing a RESULT destroys a reading.
// Removing a MARKER destroys a label — and because a result is labelled
// THROUGH its marker, one that still holds results is refused rather than left
// rendering under its raw storage key.
//
// The screen is handed its first LabsData (it is loaded on the sub-tab TAP in
// production, and a fake clock never lets sqflite answer), but every delete
// below goes to the real database and the row that comes back is a real read —
// which is the point: gone from the store AND gone from the screen, with no
// tab switch in between.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Frames until [f] appears, or give up. Real time, because the write behind
/// it is real: sqflite answers from another isolate and the fake clock never
/// lets that reply land. Same idiom as ui2_revision_reload_test.
Future<void> _until(WidgetTester t, Finder f, {int n = 60}) async {
  for (var i = 0; i < n && f.evaluate().isEmpty; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }
}

/// The same, waiting for something to GO.
Future<void> _untilGone(WidgetTester t, Finder f, {int n = 60}) async {
  for (var i = 0; i < n && f.evaluate().isNotEmpty; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }
}

/// The row-wide control whose label STARTS with [label] — a Pressable wrapping
/// a row merges its children's text into its own semantics node, so the whole
/// row reads as "Remove Ferritin from 2026-03-04, Ferritin, Typical 30–400 …".
/// The action is asserted to come first, which is the part that matters when
/// the control destroys something.
Finder _control(String label) =>
    find.bySemanticsLabel(RegExp('^${RegExp.escape(label)}'));

/// Write the rows, then read back what the screen would have loaded.
Future<LabsData> _seed(
  WidgetTester t,
  List<List<Object>> results, {
  List<Map<String, Object?>> defs = const [],
}) async =>
    (await t.runAsync(() async {
      for (final d in defs) {
        await LocalDb.putLabMarkerDef(d);
      }
      for (final r in results) {
        await LocalDb.putLabResult(
          marker: r[0] as String,
          takenOn: r[1] as String,
          value: (r[2] as num).toDouble(),
          unit: r[3] as String,
        );
      }
      return LabsData.load();
    }))!;

/// The Labs sub-tab at a real phone width.
Future<void> _pumpLabs(WidgetTester t, LabsData labs, {double scale = 1}) async {
  t.view.physicalSize = Size(390 * 3, 2400 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: HealthScreen(data: const HealthData(), labs: labs, tab: 4),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

const _ferritinAndHba1c = [
  ['ferritin', '2026-03-04', 42, 'ng/mL'],
  ['hba1c', '2026-03-04', 5.2, '%'],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_labs_delete_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async => LocalDb.close());

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('lab_result');
    await db.delete('lab_marker_def');
  });

  testWidgets('every result carries its own way out, at 390 and at large text',
      (t) async {
    final labs = await _seed(t, _ferritinAndHba1c);
    for (final scale in const [1.0, 2.0, 3.0]) {
      await _pumpLabs(t, labs, scale: scale);
      expect(find.text('Ferritin'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(
        _control('Remove Ferritin from 2026-03-04'),
        findsOneWidget,
        reason: 'a control at ${scale}x text, not only at 1x',
      );
      expect(_control('Remove HbA1c from 2026-03-04'),
          findsOneWidget);
      expect(t.takeException(), isNull,
          reason: 'nothing overflowed at ${scale}x');
    }
  });

  testWidgets('the confirm names the reading, and Keep it keeps it', (t) async {
    final labs = await _seed(t, _ferritinAndHba1c);
    await _pumpLabs(t, labs);
    await t.tap(_control('Remove Ferritin from 2026-03-04'));
    await t.pumpAndSettle();

    // The marker, the number, the unit and the date — all four, because this
    // sheet is the last thing between a column of blood results and the wrong
    // one going.
    expect(find.text('Remove Ferritin from 2026-03-04?'), findsOneWidget);
    expect(find.textContaining('42 ng/mL'), findsOneWidget);
    expect(find.textContaining('no undo'), findsOneWidget);

    await t.tap(find.text('Keep it'));
    await t.pumpAndSettle();
    expect(find.text('Ferritin'), findsOneWidget);
    expect(
      (await t.runAsync(() => LocalDb.labResults(marker: 'ferritin')))!,
      hasLength(1),
    );
  });

  testWidgets('a removed result leaves the store AND the screen, in place',
      (t) async {
    final labs = await _seed(t, _ferritinAndHba1c);
    await _pumpLabs(t, labs);
    final before = t.state(find.byType(HealthScreen));

    await t.tap(_control('Remove Ferritin from 2026-03-04'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove'));
    await _until(t, find.textContaining('No Ferritin results left'));

    expect((await t.runAsync(() => LocalDb.labResults(marker: 'ferritin')))!,
        isEmpty);
    // No tab switch, no relaunch: the row is gone from the tab it was tapped
    // on, the screen says what happened, and it is the SAME State — it
    // re-read, it was not thrown away and rebuilt.
    expect(find.text('Ferritin'), findsNothing);
    expect(find.text('HbA1c'), findsOneWidget);
    expect(identical(t.state(find.byType(HealthScreen)), before), isTrue);
  });

  testWidgets('an earlier draw takes its place, and is said to', (t) async {
    final labs = await _seed(t, const [
      ['ferritin', '2025-11-02', 61, 'ng/mL'],
      ['ferritin', '2026-03-04', 42, 'ng/mL'],
    ]);
    await _pumpLabs(t, labs);

    await t.tap(_control('Remove Ferritin from 2026-03-04'));
    await t.pumpAndSettle();
    // Warned BEFORE the tap, so "I deleted it and it is still there" never
    // happens: only the newest draw of a marker is on screen, so the one
    // underneath surfaces in its place.
    expect(find.textContaining('2025-11-02 draw stays'), findsOneWidget);
    await t.tap(find.text('Remove'));
    await _until(t, find.text('61'));

    expect(find.text('Ferritin'), findsOneWidget);
    expect(find.textContaining('Showing your 2025-11-02 draw now'),
        findsOneWidget);
  });

  testWidgets('the last result gone leaves a stated absence, not a blank',
      (t) async {
    final labs = await _seed(t, const [
      ['ferritin', '2026-03-04', 42, 'ng/mL'],
    ]);
    await _pumpLabs(t, labs);
    await t.tap(_control('Remove Ferritin from 2026-03-04'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove'));
    await _until(t, find.text('No lab results'));

    expect(find.text('—'), findsNothing);
    expect(find.text('Add a result'), findsOneWidget);
  });

  group('adding a result', () {
    testWidgets('Save writes the row and Cancel writes nothing', (t) async {
      final labs = await _seed(t, const []);
      await _pumpLabs(t, labs);

      // Cancel: the dialog closes, nothing is written, and — this is the
      // regression this test guards — no TextEditingController it created
      // survives the method (they were plain locals with no dispose(), so
      // every open of this dialog used to leak two of them for the life of
      // the process).
      await t.tap(find.text('Add a result'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect((await t.runAsync(LocalDb.labMarkerDefs))!, isEmpty);
      expect(
        (await t.runAsync(() => LocalDb.labResults(marker: 'ferritin')))!,
        isEmpty,
      );

      // Save: the row lands, through the same controllers, torn down the
      // same way.
      await t.tap(find.text('Add a result'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, '42');
      await t.tap(find.text('Save'));
      await _until(t, find.text('42'));
      expect(find.text('42'), findsOneWidget);
    });
  });

  group('a marker you named yourself', () {
    const lpa = <Map<String, Object?>>[
      {
        'key': 'custom_lp_a',
        'label': 'Lp(a)',
        'unit': 'nmol/L',
        'category': 'lipids',
        'decimals': 0,
      }
    ];

    testWidgets('is refused while it still labels a reading', (t) async {
      final labs = await _seed(t, const [
        ['custom_lp_a', '2026-03-04', 90, 'nmol/L'],
      ], defs: lpa);
      await _pumpLabs(t, labs);

      expect(find.text('Markers you named'), findsOneWidget);
      expect(find.text('1 result · nmol/L'), findsOneWidget);

      await t.tap(_control('Remove the Lp(a) marker'));
      await t.pumpAndSettle();
      // Not a confirm — a refusal, with the way forward. The store KEEPS the
      // readings when a definition goes, and this screen has nothing left to
      // label them with, so neither destroying nor degrading them is offered.
      expect(find.text('Remove Lp(a)?'), findsNothing);
      expect(find.textContaining('still holds 1 result'), findsOneWidget);
      expect((await t.runAsync(LocalDb.labMarkerDefs))!, hasLength(1));
    });

    testWidgets('goes once nothing is logged under it', (t) async {
      final labs = await _seed(t, const [], defs: lpa);
      await _pumpLabs(t, labs);

      expect(find.text('Nothing logged under it'), findsOneWidget);
      await t.tap(_control('Remove the Lp(a) marker'));
      await t.pumpAndSettle();
      expect(find.text('Remove Lp(a)?'), findsOneWidget);
      expect(find.textContaining('Nothing measured goes with it'),
          findsOneWidget);

      await t.tap(find.text('Remove'));
      await _untilGone(t, find.text('Markers you named'));
      expect(find.text('Markers you named'), findsNothing);
      expect((await t.runAsync(LocalDb.labMarkerDefs))!, isEmpty);
    });
  });
}
