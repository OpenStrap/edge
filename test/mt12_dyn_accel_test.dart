// MT-12 — `decoded_onehz.dyn_accel_g`, the last gen5 channel the mapper
// decoded and dropped.
//
// What this asserts is deliberately small, because the column claims nothing:
// the value protocol decoded reaches the row, a gen4 row reads NULL rather
// than 0, and the column arrives on an existing install without losing a row.
// Nothing reads `dyn_accel_g`; there is no derived number to test.
//
// The REAL-DB half (`OPENSTRAP_TEST_DBS=/path/one.db,/path/two.db`) runs the
// whole ladder over old-schema exports and counts every substrate table before
// and after. Skipped when the env var is unset — those files are not in the
// repo.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

Future<void> _useFreshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
}

Future<List<String>> _columns(String table) async {
  final db = await LocalDb.instance;
  return [
    for (final c in await db.rawQuery('PRAGMA table_info($table)'))
      c['name'] as String,
  ];
}

RawRecord _raw(int ts, int counter) => RawRecord(
  counter: counter,
  packetType: 47,
  hex: 'feed$counter',
  capturedAt: ts * 1000,
  recTs: ts,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await LocalDb.close();
  });

  test('a gen5 value round-trips; a gen4 second reads NULL, not 0', () async {
    await _useFreshDb('mt12_dyn_accel_test.db');
    expect(await _columns('decoded_onehz'), contains('dyn_accel_g'));

    // gen5: the band reported a motion magnitude for this second.
    await LocalDb.insertRecord(
      _raw(1700000000, 1),
      Sample(
        tsEpoch: 1700000000,
        counter: 1,
        hr: 61,
        dynAccelG: 0.00916, // protocol's own v18 fixture value
        tempCh2C: 24.7,
        tempCh3C: 26.5,
        signalQualityLogVar: -5.2307,
      ),
    );
    // gen4: the record has no such field at all. NULL, never a still wrist.
    await LocalDb.insertRecord(
      _raw(1700000001, 2),
      Sample(tsEpoch: 1700000001, counter: 2, hr: 62, ax: 0.1, ay: 0.2, az: 0.9),
    );

    final db = await LocalDb.instance;
    final rows = await db.query(
      'decoded_onehz',
      columns: ['rec_ts', 'dyn_accel_g'],
      orderBy: 'rec_ts ASC',
    );
    expect(rows.length, 2);
    expect(rows[0]['dyn_accel_g'], closeTo(0.00916, 1e-9));
    // The whole point of the column: absence is absence.
    expect(rows[1]['dyn_accel_g'], isNull);
  });

  // Old-schema exports: the ladder, end to end, with a row census either side.
  final real = (Platform.environment['OPENSTRAP_TEST_DBS'] ?? '')
      .split(',')
      .where((s) => s.trim().isNotEmpty)
      .toList();
  for (final src in real) {
    test('migrates ${p.basename(src)} with no row loss', () async {
      const tables = [
        'decoded_onehz',
        'decoded_rr',
        'raw_archive',
        'sessions',
        'day_result',
        'metric_series',
      ];
      // Census BEFORE, straight off the file, with no ladder involved.
      final before = <String, int>{};
      final probe = await databaseFactory.openDatabase(
        src,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      for (final t in tables) {
        final present = await probe.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
          [t],
        );
        if (present.isEmpty) continue;
        before[t] =
            (await probe.rawQuery('SELECT COUNT(*) AS n FROM $t')).first['n']
                as int;
      }
      await probe.close();

      final name = 'mt12_${p.basenameWithoutExtension(src)}.db';
      await _useFreshDb(name);
      final dir = await databaseFactory.getDatabasesPath();
      await File(src).copy(p.join(dir, name));

      final db = await LocalDb.instance; // runs the whole ladder
      expect(await _columns('decoded_onehz'), contains('dyn_accel_g'));

      for (final e in before.entries) {
        final after =
            (await db.rawQuery('SELECT COUNT(*) AS n FROM '
                    '${e.key == 'raw_archive' ? LocalDb.rawArchiveView : e.key}'))
                .first['n'] as int;
        // GREATER-OR-EQUAL, not equal: the v44 rung replays archived records
        // into decoded_onehz, so that table may legitimately GAIN rows. No
        // table may lose one.
        expect(
          after,
          greaterThanOrEqualTo(e.value),
          reason: '$src ${e.key}: $after < ${e.value}',
        );
        // ignore: avoid_print
        print('[mt12] ${p.basename(src)} ${e.key} ${e.value} -> $after');
      }

      // NEVER backfilled: a row written before the column existed has no
      // motion magnitude to claim, and a guess would be a fabricated reading.
      final stamped = (await db.rawQuery(
        'SELECT COUNT(*) AS n FROM decoded_onehz WHERE dyn_accel_g IS NOT NULL',
      )).first['n'] as int;
      // ignore: avoid_print
      print('[mt12] ${p.basename(src)} dyn_accel_g populated=$stamped');

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$src $health');
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
