// A user delete must not run under a derive pass already in flight: that pass
// built its substrate before the delete and writes day_result, metric_series
// and the baselines after it, bringing the deleted days back with nothing left
// to ever re-derive or remove them.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_user_delete_waits_for_derive_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => DerivationEngine.debugRunning = false);

  test('whileIdle waits for a running pass and holds the latch for its body',
      () async {
    DerivationEngine.debugRunning = true; // a heavy pass mid-backfill
    final engine = DerivationEngine();
    var ran = false;
    bool? latchedInside;
    final held = Completer<void>();
    final done = DerivationEngine.whileIdle(() async {
      ran = true;
      latchedInside = engine.running;
      await held.future;
    });

    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(ran, isFalse, reason: 'the delete ran under a pass in flight');

    DerivationEngine.debugRunning = false;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(ran, isTrue);
    expect(latchedInside, isTrue);
    // A pass the scheduler starts now is dropped as busy, not run alongside.
    expect(engine.running, isTrue);

    held.complete();
    await done;
    expect(engine.running, isFalse);
  });

  test('deleteDays waits out a derive pass already in flight', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    DerivationEngine.debugRunning = true;

    var finished = false;
    final del = app.deleteDays({'2026-09-20'}).then((_) => finished = true);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(finished, isFalse);

    DerivationEngine.debugRunning = false;
    await del;
    expect(finished, isTrue);
  });
}
