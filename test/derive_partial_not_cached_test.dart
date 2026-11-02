// A derive whose second half failed stores a partial row. Two failures in a
// row can store the same partial row, and if that pass then recorded the
// day's input fingerprint, every later pass would skip the day as unchanged
// and the missing detail would never be filled in. Only a complete derive
// may record one. Its own file: the derive passes are heavy, and the
// equivalence test next door already runs ten of them.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const _profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

// One day, mid-July, still pending (the data edge is inside it).
final _day = SyntheticDay(DateTime(2026, 7, 13));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    DerivationEngine.debugSecondHalfHook = null;
    await LocalDb.close();
  });

  test('a partial derive never records its fingerprint', () async {
    const name = 'derive_partial_not_cached.db';
    SharedPreferences.setMockInitialValues({});
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory
        .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
    for (final (raws, samples) in _day.primaryBatches()) {
      await LocalDb.commitSyncBatch(raws, samples, deviceFamily: 'gen4');
    }

    DerivationEngine.debugSecondHalfHook =
        (_) async => throw StateError('second half down');
    // The passes that reach the fixed point: the second stores the same
    // partial row as the first, the third derives from it unchanged.
    for (var i = 0; i < 3; i++) {
      final e = DerivationEngine();
      await e.run(_profile, heavy: true);
      final derived = await _derivedDays();
      expect(derived, isNotEmpty);
      for (final d in derived) {
        expect(await LocalDb.deriveFingerprint(d), isNull,
            reason: 'pass $i stored a fingerprint for partial day $d');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<List<String>> _derivedDays() async => [
      for (final r in await (await LocalDb.instance)
          .query('day_result', columns: ['day_id'], distinct: true))
        r['day_id'] as String,
    ];
