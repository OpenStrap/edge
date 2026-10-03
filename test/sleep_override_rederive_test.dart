// A sleep correction has to reach the derived day: it must not be dropped
// because another derive pass holds the latch, and the morning readiness pin
// must not keep showing the uncorrected night.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_sleep_override_rederive_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an edit made while another derive pass runs waits for it', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    DerivationEngine.debugRunning = true; // a drain pass / rescan in flight
    addTearDown(() => DerivationEngine.debugRunning = false);

    var done = false;
    final edit = app.reanalyzeForNapEdit().then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(done, isFalse,
        reason: 'run() would have returned 0 and the edit was lost');

    DerivationEngine.debugRunning = false;
    await edit;
    expect(done, isTrue);
  });

  test('a pass already running when the edit lands can\'t re-pin the old night',
      () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    DerivationEngine.debugRunning = true; // a drain pass deriving today
    addTearDown(() => DerivationEngine.debugRunning = false);

    final day = todayLabel();
    await LocalDb.setFrozenHeadline(day, 45);
    final edit = app.setSleepOverride(
      day,
      DateTime(2026, 9, 30, 0, 30),
      DateTime(2026, 9, 30, 7),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await LocalDb.frozenHeadline(), isNull);

    // The in-flight pass prepared today from the old window and pins it as
    // it finishes; the force pass's nextFrozenHeadline would then hold it.
    await LocalDb.setFrozenHeadline(day, 45);
    DerivationEngine.debugRunning = false;
    await edit;
    expect(await LocalDb.frozenHeadline(), isNull);
  });

  test('an edit doesn\'t wait for a health export already running', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final exporting = Completer<void>();
    final running = HealthExporter.shared.debugRunLocked(
      () => exporting.future,
    );
    addTearDown(() async {
      if (!exporting.isCompleted) exporting.complete();
      await running;
    });

    var done = false;
    final edit = app
        .setSleepOverride(
          '2026-09-20',
          DateTime(2026, 9, 19, 23),
          DateTime(2026, 9, 20, 7),
        )
        .then((_) => done = true);
    for (var i = 0; i < 40 && !done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(done, isTrue, reason: 'the sleep sheet spins until the export ends');
    expect(app.reanalyzing, isFalse);

    exporting.complete();
    await running;
    await edit;
  });

  test('correcting the pinned day releases the morning pin', () async {
    await LocalDb.setFrozenHeadline('2026-09-30', 45);
    await LocalDb.putSleepOverride(
      dayId: '2026-09-29',
      onsetTs: 1000,
      offsetTs: 2000,
      source: 'manual',
    );
    expect((await LocalDb.frozenHeadline())?.value, 45,
        reason: 'another day\'s edit leaves today\'s pin alone');

    await LocalDb.putSleepOverride(
      dayId: '2026-09-30',
      onsetTs: 1000,
      offsetTs: 2000,
      source: 'manual',
    );
    expect(await LocalDb.frozenHeadline(), isNull);

    await LocalDb.setFrozenHeadline('2026-09-30', 62);
    await LocalDb.deleteSleepOverride('2026-09-30');
    expect(await LocalDb.frozenHeadline(), isNull);
  });
}
