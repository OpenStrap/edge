// "Re-analyze data" exists for screens that are blank despite stored data,
// which is when a failing derive is the likely cause. run() returns the days it
// derived, so a pass that threw and a pass with nothing to derive both return
// 0; the re-analyze note used to render either one as an ordinary
// "0 days re-analyzed." These pin that the failure is told apart.
//
// Order matters: the first two tests run before any database factory exists,
// so every query inside the pass throws.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a pass that throws reports its error, not just 0 days', () async {
    final eng = DerivationEngine(log: (_) {});
    String? reported;
    final n = await eng.run(
      const Profile(),
      heavy: true,
      force: true,
      onOutcome: (_, error) => reported = error,
    );
    expect(n, 0);
    expect(eng.lastRunError, isNotNull);
    // The per-call outcome survives a later pass on the same engine resetting
    // the shared fields.
    eng.lastRunError = null;
    expect(reported, isNotNull);
  });

  test('reanalyzeAll hands a failed pass back as an error', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final out = await app.reanalyzeAll();
    expect(out.days, 0);
    expect(out.error, isNotNull);
    expect(app.reanalyzing, isFalse);
  });

  test('a pass with nothing to derive is 0 days and no error', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_reanalyze_outcome_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    addTearDown(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    final eng = DerivationEngine(log: (_) {});
    // Left over from a failed pass on the same engine: a clean run resets it.
    eng.lastRunError = 'stale';
    eng.lastRunFailedDays = 3;
    var called = false;
    int? failed;
    String? error = 'unset';
    final n = await eng.run(
      const Profile(),
      heavy: true,
      force: true,
      onOutcome: (f, e) {
        called = true;
        failed = f;
        error = e;
      },
    );
    expect(n, 0);
    expect(eng.lastRunError, isNull);
    expect(eng.lastRunFailedDays, 0);
    expect(called, isTrue);
    expect(failed, 0);
    expect(error, isNull);
  });
}
