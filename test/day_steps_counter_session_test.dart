// A strap-counter day's hourly spans get the session they sit inside, the
// same as coverage spans do. They used to come back with no activity at all,
// because the sessions read was skipped whenever coverage spans were empty.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_day_steps_counter_session_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('counter spans are named by the session they sit inside', () async {
    const day = '2026-03-10';
    final ten = localDayStartSec(day)! + 10 * 3600;
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'steps': {
          'value': 1500,
          'source': 'strap_counter',
          'spans': [
            {'start_ts': ten - 3600, 'end_ts': ten - 60, 'steps': 300},
            {'start_ts': ten, 'end_ts': ten + 3540, 'steps': 1200},
          ],
        },
      }),
      windowJson: '{}',
      finalized: true,
    );
    await LocalDb.putSession({
      'id': 'auto:$ten',
      'start_ts': ten,
      'end_ts': ten + 45 * 60,
      'type': 'walk',
      'status': 'done',
      'source': 'auto',
      'created_at': ten,
    });

    final out = await LocalRepositoryImpl(getProfileMap: () => null)
        .getDaySteps(day);
    final spans = (out['spans'] as List).cast<Map>();
    expect(spans.map((s) => s['activity']), [null, 'walk']);
    expect(spans.every((s) => s['source'] == LocalDb.kStepSourceBand), isTrue);
  });
}
