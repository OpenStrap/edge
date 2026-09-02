// M5 §2.2's real-export payload-diff gate, run against the actual export DB
// (openstrap_export_1788006514220.db, the one M0/M3 used).
//
// The literal spec §2.2 SQL (`day_result` at algo_version=86 vs 87) is
// VACUOUS on this specific export: `SELECT MAX(algo_version) FROM
// day_result` on the untouched file is 82 — it predates v86, so there are
// no v86 rows to diff against at all, and the query trivially returns zero
// rows regardless of whether M5 changed anything. Stated here rather than
// reported as a real pass.
//
// The real, stronger check available on this file: it is a genuine
// single-device install (`SELECT COUNT(DISTINCT device_id) FROM
// decoded_onehz` = 1), so M5's own identity proof (coverage_resolver.dart
// §2) predicts every day derived from it takes the candidates==1
// short-circuit for every anchor signal — meaning `series.coverage` must be
// ABSENT from every bundle a v87 derive produces here. That is asserted
// below on real historical data, not just the synthetic fixture in
// multidevice_coverage_derive_test.dart.
//
// Never mutates the source file — copies it into the sqflite_common_ffi
// scratch databases directory first. Skips cleanly if the export is not
// present in this environment.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

const _sourcePath =
    '/Users/abdulsahil/Downloads/openstrap_export_1788006514220.db';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final source = File(_sourcePath);
  if (!source.existsSync()) {
    test('M5 real-export gate', () {}, skip: 'no real export DB in this env');
    return;
  }

  test('real single-device export: every v87-derived day has NO '
      'series.coverage key (the identity path, on real historical data)',
      () async {
    await LocalDb.close();
    LocalDb.dbName = 'm5_real_export_gate.db';
    final dbPath = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
    await databaseFactory.deleteDatabase(dbPath);
    // Never touch the source — copy it into the scratch slot LocalDb opens.
    await File(dbPath).parent.create(recursive: true);
    await source.copy(dbPath);

    // Opens through the REAL migration ladder (this is exactly what M0/M3
    // did — verified once more here, harmlessly, since M5 adds no DDL).
    final db = await LocalDb.instance;

    final singleDeviceRows = await db.rawQuery(
      'SELECT COUNT(DISTINCT device_id) AS n FROM decoded_onehz',
    );
    final singleDevice = (singleDeviceRows.first['n'] as num).toInt();
    expect(singleDevice, 1,
        reason: 'this gate\'s conclusion (identity path on every day) only '
            'holds because this specific export is single-device — if a '
            'future export is not, this assertion needs to change with it');

    final dayIds = (await db.rawQuery('SELECT DISTINCT day_id FROM day_result'))
        .map((r) => r['day_id'] as String)
        .toSet();
    expect(dayIds, isNotEmpty);

    final done = await DerivationEngine()
        .runDays(const Profile(), dayIds, force: true);
    expect(done, greaterThan(0),
        reason: 'at least some of these 34 days must actually derive under '
            'the real M5 code, not merely be skipped');

    final rows = await db.rawQuery(
      'SELECT day_id, payload_json FROM day_result WHERE algo_version = ?',
      [kAlgoVersion],
    );
    expect(rows, isNotEmpty);
    for (final r in rows) {
      final bundle = jsonDecode(r['payload_json'] as String) as Map;
      final series = bundle['series'];
      if (series is Map) {
        expect(series.containsKey('coverage'), isFalse,
            reason: '${r['day_id']}: a single-device install must never '
                'get a coverage key — its resolver never leaves the '
                'identity short-circuit');
      }
    }

    await LocalDb.close();
    await databaseFactory.deleteDatabase(dbPath);
  });
}
