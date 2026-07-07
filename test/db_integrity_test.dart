// DB integrity regressions, run against the REAL LocalDb over sqflite_ffi:
//
//  1. decoded_rr ORPHAN GUARD — a post-reboot rec_ts collision (two counters,
//     one second) must not strand the evicted counter's RR beats under a
//     counter with no decoded_onehz row (the counter-joined prune can never
//     select those → permanent leak, and the loser's extra beat indexes would
//     survive the winner's UNIQUE(rr_ts_ms, beat_index) REPLACE).
//  2. prune ORPHAN SWEEP — pre-existing orphans (written by pre-guard builds)
//     are cleaned by pruneRawBeforeRecTs once their window is pruned.
//  3. importFromDbFile FINALIZED protection — a foreign export never overwrites
//     a locally-finalized (day_id, algo_version) day_result row; non-finalized
//     rows keep the merge-REPLACE behavior.
//  4. schema smoke — a fresh onCreate database passes schemaHealth(). (A true
//     old-version fixture upgrade is too brittle to hand-build here; the
//     fresh-create + health assertion is the sanctioned fallback.)

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

Sample _sample(int ts, int counter, List<int> rr) => Sample(
      tsEpoch: ts,
      counter: counter,
      hr: 70,
      rrIntervalsMs: rr,
      ax: 0,
      ay: 0,
      az: 0,
      spo2RedRaw: 0,
      spo2IrRaw: 0,
      skinTempRaw: 0,
    );

RawRecord _raw(int ts, int counter) => RawRecord(
      counter: counter,
      packetType: 47,
      hex: 'feed$counter',
      capturedAt: ts * 1000,
      recTs: ts,
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_integrity_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await databaseFactory.deleteDatabase(p.join(dir, 'foreign_export_test.db'));
  });

  test('fresh schema passes schemaHealth (migration smoke)', () async {
    final health = await LocalDb.schemaHealth();
    expect(health['ok'], isTrue, reason: '$health');
  });

  test('rec_ts collision leaves no orphaned decoded_rr beats', () async {
    const ts = 1780000000;
    // Pre-reboot record: high counter, THREE beats.
    await LocalDb.insertRecord(_raw(ts, 100), _sample(ts, 100, [800, 810, 820]));
    // Post-reboot record for the SAME second: counter reset low, TWO beats.
    // REPLACE on UNIQUE(rec_ts) evicts counter 100's decoded_onehz row; without
    // the guard its beats (incl. beat_index 2, which the winner's two-beat
    // REPLACE never touches) would be orphaned forever.
    await LocalDb.insertRecord(_raw(ts, 5), _sample(ts, 5, [900, 910]));

    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz', where: 'rec_ts = ?', whereArgs: [ts]);
    expect(onehz.length, 1);
    expect(onehz.first['counter'], 5); // newest-wins

    // No RR beats survive under the evicted counter…
    final loserBeats =
        await db.query('decoded_rr', where: 'counter = ?', whereArgs: [100]);
    expect(loserBeats, isEmpty);
    // …and globally: zero orphans (every beat's counter owns a decoded row).
    final orphans = await db.rawQuery(
      'SELECT COUNT(*) c FROM decoded_rr '
      'WHERE counter NOT IN (SELECT counter FROM decoded_onehz)',
    );
    expect(orphans.first['c'], 0);

    // The RR read path (decodedRrByCounterRange, joined to frames by counter in
    // derive_prepare.addDecodedPage) sees ONLY the winner's beats.
    final rr = await LocalDb.decodedRrByCounterRange(fromCounter: 0, toCounter: 1 << 30);
    expect([for (final r in rr) r['rr_ms']], [900, 910]);
    expect({for (final r in rr) r['counter']}, {5});
  });

  test('prune sweeps pre-existing decoded_rr orphans', () async {
    const oldTs = 1700000000; // strictly before the cutoff below
    final db = await LocalDb.instance;
    // Simulate a pre-guard leak: an RR beat whose counter has no decoded row.
    await db.insert('decoded_rr', {
      'counter': 999999,
      'beat_index': 0,
      'rr_ts_ms': oldTs * 1000,
      'rr_ms': 850,
    });
    // A live (post-cutoff) substrate row + beat that must SURVIVE the prune.
    const keepTs = 1780000500;
    await LocalDb.insertRecord(_raw(keepTs, 7), _sample(keepTs, 7, [700]));

    await LocalDb.pruneDecodedBeforeRecTs(oldTs + 1000);

    final orphan = await db.query('decoded_rr', where: 'counter = ?', whereArgs: [999999]);
    expect(orphan, isEmpty, reason: 'orphan sweep must clean the leaked beat');
    final kept = await db.query('decoded_rr', where: 'counter = ?', whereArgs: [7]);
    expect(kept.length, 1);
  });

  test('importFromDbFile never overwrites a locally-FINALIZED day_result', () async {
    const v = 30;
    await LocalDb.putDayResult(
      dayId: '2026-07-01',
      algoVersion: v,
      payloadJson: '{"src":"local-finalized"}',
      windowJson: '{}',
      finalized: true,
    );
    await LocalDb.putDayResult(
      dayId: '2026-07-02',
      algoVersion: v,
      payloadJson: '{"src":"local-open"}',
      windowJson: '{}',
      finalized: false,
    );

    // Build a foreign export carrying: a collision with the finalized day, a
    // collision with the open day, and a brand-new day.
    final dir = await databaseFactory.getDatabasesPath();
    final srcPath = p.join(dir, 'foreign_export_test.db');
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute('''
      CREATE TABLE day_result (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        window_json TEXT NOT NULL DEFAULT '{}',
        computed_at INTEGER NOT NULL,
        finalized INTEGER NOT NULL DEFAULT 0,
        rhr REAL, rmssd REAL, readiness REAL,
        PRIMARY KEY (day_id, algo_version)
      )
    ''');
    for (final day in ['2026-07-01', '2026-07-02', '2026-06-30']) {
      await src.insert('day_result', {
        'day_id': day,
        'algo_version': v,
        'payload_json': '{"src":"foreign"}',
        'window_json': '{}',
        'computed_at': 1,
        'finalized': 1,
      });
    }
    await src.close();

    final counts = await LocalDb.importFromDbFile(srcPath);
    expect(counts['day_result'], 2); // finalized collision skipped

    Future<String> payload(String day) async =>
        (await LocalDb.dayResult(day))!['payload_json'] as String;
    // Locally finalized → protected.
    expect(await payload('2026-07-01'), '{"src":"local-finalized"}');
    // Non-finalized → merge-REPLACE (import wins).
    expect(await payload('2026-07-02'), '{"src":"foreign"}');
    // New day → imported.
    expect(await payload('2026-06-30'), '{"src":"foreign"}');
  });
}
