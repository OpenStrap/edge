// The cross-day input artifact is rebuilt on every pass that derived anything,
// light passes included. Only the days whose row changed should be re-read and
// re-decoded; the rest reuse the record built last time.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_crossday_incremental_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<void> putDay(String dayId, double rhr) => LocalDb.putDayResult(
        dayId: dayId,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({
          'scalars': {'rhr': rhr, 'rmssd': 60.0, 'readiness': 70.0},
        }),
        windowJson: '{}',
        finalized: true,
        rhr: rhr,
        rmssd: 60,
        readiness: 70,
      );

  Future<Map<String, dynamic>> artifact() async => jsonDecode(
        (await LocalDb.baseline('crossday_input'))!['payload_json'] as String,
      ) as Map<String, dynamic>;

  test('only a changed day is rebuilt', () async {
    await putDay('2026-01-10', 50);
    await putDay('2026-01-11', 51);
    await DerivationEngine().finalizeImport(const Profile());
    final a = await artifact();
    expect(a['days'] as List, hasLength(2));
    expect((a['row_sigs'] as Map).keys, containsAll(['2026-01-10', '2026-01-11']));

    // Mark both cached records, then rewrite one day.
    for (final r in a['days'] as List) {
      (r as Map)['marker'] = 1;
    }
    expect(
      await LocalDb.putReviewedBaseline('crossday_input', jsonEncode(a),
          await LocalDb.activityReviewRevision()),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await putDay('2026-01-11', 58);
    await DerivationEngine().finalizeImport(const Profile());

    final days = {
      for (final r in (await artifact())['days'] as List)
        (r as Map)['date']: r,
    };
    expect(days['2026-01-10']!['marker'], 1, reason: 'unchanged: reused');
    expect(days['2026-01-11']!['marker'], isNull, reason: 'changed: rebuilt');
    expect(days['2026-01-11']!['rhr'], 58);
  });
}
