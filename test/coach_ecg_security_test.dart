// The AI coach may read ECG SUMMARIES and nothing else. `v_ecg_readings` is
// on the allow-list; the three base tables are blocked at layer 1 (token
// net) and — for the two packet tables, which no view reads — at layer 2 (the
// structural btree gate) as well. `ecg_reading` IS a base table of an allowed
// view, so its btree is structurally reachable; the token net is what keeps
// its `device_id` and `notes` columns out. Both facts are pinned here.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_db.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_coach_ecg_security_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.insertEcgReading(
      {
        'id': 'ecg_1',
        'device_id': 'SERIAL-SECRET',
        'source': 'mg_labrador',
        'wrist': 'left',
        'start_ts': 1787823754,
        'end_ts': 1787823784,
        'result_code': 6,
        'category': 'inconclusive',
        'avg_hr': 80,
        'quality': 2,
        'unreadable_mask': 0,
        'interruptions': 1,
        'sample_count': 2,
        'status': 'inconclusive',
        'notes': 'private note',
        'created_at': 1787823784000,
      },
      [
        {
          'sequence': 1,
          'sample_count': 2,
          'samples': [1, 0, 255, 255],
          'inner_hex': '2b11deadbeef',
          'is_placeholder': 0,
        },
      ],
    );
  });

  tearDownAll(() async {
    await CoachDb.close();
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('the summary view is readable through run_sql', () async {
    final out = await CoachDb.runCoachSql(
      'SELECT id, category, avg_hr, duration_s, date FROM v_ecg_readings',
    );
    expect(out, contains('"ecg_1"'));
    expect(out, contains('inconclusive'));
    expect(out, contains('"duration_s":30'));
    expect(out, isNot(contains('SERIAL-SECRET')));
    expect(out, isNot(contains('private note')));
    expect(out, isNot(contains('deadbeef')));
  });

  test('the view exposes no identity, notes or bytes columns', () async {
    final out = await CoachDb.runCoachSql('SELECT * FROM v_ecg_readings');
    expect(out, isNot(contains('device_id')));
    expect(out, isNot(contains('notes')));
    expect(out, isNot(contains('inner_hex')));
    expect(out, isNot(contains('samples')));
  });

  for (final t in ['ecg_reading', 'ecg_reading_packet', 'ecg_raw_packet']) {
    test('layer 1 rejects the base table $t', () {
      expect(
        () => CoachDb.guardAndPrepare('SELECT * FROM $t'),
        throwsA(isA<SqlGuardError>()),
      );
      expect(
        () => CoachDb.guardAndPrepare('SELECT device_id FROM $t'),
        throwsA(isA<SqlGuardError>()),
      );
      expect(
        () => CoachDb.guardAndPrepare(
          'WITH x AS (SELECT 1) SELECT * FROM v_ecg_readings, $t',
        ),
        throwsA(isA<SqlGuardError>()),
      );
    });
  }

  for (final t in ['ecg_reading_packet', 'ecg_raw_packet']) {
    test('layer 2 (parser bypassed) rejects $t — no view reads it', () async {
      await expectLater(
        CoachDb.debugAssertAllowedBtrees('SELECT * FROM $t LIMIT 5'),
        throwsA(isA<SqlGuardError>()),
      );
    });
  }

  test(
    'runCoachSql over the packet table returns a rejection, not bytes',
    () async {
      final out = await CoachDb.runCoachSql(
        'SELECT inner_hex FROM ecg_reading_packet',
      );
      expect(out, contains('error'));
      expect(out, isNot(contains('deadbeef')));
    },
  );
}
