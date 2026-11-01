// A day old enough to finalize, whose next day has not stored its window yet
// in the same pass, is held: not finalized and not recorded as unchanged, so
// the next pass reads tonight's window and locks the day then. The hold is
// forced through the test seam rather than by racing two workers.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const _profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

// Three days of data: the day before the first is old enough to finalize on
// the first pass.
final _days = [
  for (var i = 0; i < 3; i++) SyntheticDay(DateTime(2026, 7, 13 + i)),
];
const _held = '2026-07-12';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    DerivationEngine.debugHoldTonight = {};
    await LocalDb.close();
  });

  test('a held day is neither finalized nor fingerprinted, then settles',
      () async {
    const name = 'derive_tonight_pending.db';
    SharedPreferences.setMockInitialValues({});
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory
        .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
    var committed = 0;
    for (final d in _days) {
      for (final (raws, samples) in d.primaryBatches()) {
        final keep = [
          for (var j = 0; j < raws.length; j++)
            if (raws[j].recTs! > committed) j,
        ];
        if (keep.isEmpty) continue;
        await LocalDb.commitSyncBatch(
          [for (final j in keep) raws[j]],
          [for (final j in keep) samples[j]],
          deviceFamily: 'gen4',
        );
        committed = raws[keep.last].recTs!;
      }
    }

    // Two held passes: the second derives from unchanged inputs, which is
    // where a fingerprint would be recorded and the day skipped for good.
    DerivationEngine.debugHoldTonight = {_held};
    for (var i = 0; i < 2; i++) {
      await DerivationEngine().run(_profile, heavy: true);
      expect(await LocalDb.dayResult(_held), isNotNull);
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), isNot(contains(_held)),
          reason: 'held pass $i');
      expect(await LocalDb.deriveFingerprint(_held), isNull,
          reason: 'held pass $i');
    }

    DerivationEngine.debugHoldTonight = {};
    await DerivationEngine().run(_profile, heavy: true);
    expect(await LocalDb.finalizedDayIds(kAlgoVersion), contains(_held));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
