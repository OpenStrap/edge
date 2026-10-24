// ED-1 E2 RED: ported from cb81734f onto upstream's LocalDb restore owner.
// Upstream still reads 2,000 rows into Dart maps and batches the writes.
// The proposed bulk path copies inside SQLite with ATTACH + INSERT SELECT,
// in 25,000-row chunks. These tests hold that path to the existing merge:
//   1. the same final database, rule by rule (LocalDb.debugMergeRowByRow is
//      the oracle);
//   2. a bounded number of sqflite calls per big table, not one per page;
//   3. chunks commit separately and a rerun converges;
//   4. the source is detached on success and on failure.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';

// Every sqflite call LocalDb makes, while [_counting] is on.
final _invokes = <SqfliteLoggerInvokeEvent>[];
var _counting = false;

/// The SQL strings one sqflite call carries (a batch carries one per op).
Iterable<String> _sqlOf(Object? args) sync* {
  if (args is Map) {
    final sql = args['sql'];
    if (sql is String) yield sql;
    for (final v in args.values) {
      if (v is List || v is Map) yield* _sqlOf(v);
    }
  } else if (args is List) {
    for (final v in args) {
      yield* _sqlOf(v);
    }
  }
}

Iterable<Map> _operations(Object? args) sync* {
  if (args is Map) {
    if (args['sql'] is String) yield args;
    for (final v in args.values) {
      if (v is List || v is Map) yield* _operations(v);
    }
  } else if (args is List) {
    for (final v in args) {
      yield* _operations(v);
    }
  }
}

/// sqflite calls whose SQL names [table].
int _callsTouching(String table) {
  final re = RegExp('\\b$table\\b');
  return _invokes
      .where((e) => _sqlOf(e.arguments).any(re.hasMatch))
      .length;
}

const _t0 = 1790000000; // 2026-09-21, an arbitrary fixed second

/// Stamped with DateTime.now(): differs between any two
/// runs, so the equivalence dump leaves it out.
const _wallClockColumns = {
  'compute_freshness': {'updated_at'},
  'activity_review_meta': {'activated_at', 'alert_after_ts'},
  'substrate_archive': {'updated_at'},
};

Map<String, Object?> archiveSecond(int ts, int hr) => {
  'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts, 'counter': ts - _t0,
  'hr': hr,
};

Map<String, Object?> archiveRow(List<Map<String, Object?>> rows) {
  final table = (ArchiveTableBuilder()..addRows(rows)).build();
  final w = SubstrateArchiveCodec.encodeMergeVerify(
      ArchiveBucket(table, ArchiveTable.empty));
  return {
    'device_id': '', 'utc_day': _t0 ~/ 86400,
    'codec': SubstrateArchiveCodec.codecId,
    'from_ts': w.fromTs, 'to_ts': w.toTs,
    'onehz_rows': w.onehzRows, 'rr_rows': w.rrRows,
    'raw_bytes': w.rawBytes, 'fingerprint': w.fingerprint,
    'blob': w.blob, 'created_at': 1, 'updated_at': 1,
  };
}

void main() {
  late Directory tmp;
  late String dbDir;

  setUpAll(() async {
    sqfliteFfiInit();
    // The logger is the only public hook that sees every sqflite call.
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.invoke,
        log: (e) {
          if (_counting && e is SqfliteLoggerInvokeEvent) _invokes.add(e);
        },
      ),
    );
    SharedPreferences.setMockInitialValues({});
    LocalDb.dbName = 'openstrap_bulk_restore_test.db';
    dbDir = await databaseFactory.getDatabasesPath();
    tmp = await Directory.systemTemp.createTemp('openstrap_bulk_');
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  tearDown(() {
    _counting = false;
    _invokes.clear();
    expect(LocalDb.debugRowByRowMerge, isFalse);
  });

  /// A brand-new, empty local database.
  Future<Database> freshLocal() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    SharedPreferences.setMockInitialValues({});
    return LocalDb.instance;
  }

  /// Every table, every row, as SQL literals (quote() keeps the storage
  /// class: 1, 1.0 and '1' differ), sorted so row order does not matter.
  Future<Map<String, List<String>>> dump(
      {Set<String>? only, Set<String> except = const {}}) async {
    final db = await LocalDb.instance;
    final tables = [
      for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_stat%' ORDER BY name"))
        r['name'] as String,
    ].where((t) => (only == null || only.contains(t)) && !except.contains(t));
    final out = <String, List<String>>{};
    for (final t in tables) {
      final cols = [
        for (final c in await db.rawQuery('PRAGMA table_info("$t")'))
          if (!(_wallClockColumns[t]?.contains(c['name']) ?? false))
            c['name'] as String,
      ];
      final rows = await db.rawQuery(
          'SELECT ${cols.map((c) => 'quote("$c")').join(" || '|' || ")} '
          'AS r FROM "$t"');
      out[t] = [for (final r in rows) r['r'] as String]..sort();
    }
    return out;
  }

  // ── fixture: one source row per per-row rule ───────────────────────────────

  /// The local state the import lands on: a finalized day, a non-finalized
  /// day, and beats from two devices on one second.
  Future<void> seedLocal() async {
    final db = await LocalDb.instance;
    // Collision must REPLACE the 1 Hz value, including replacing it with NULL.
    await db.insert('decoded_onehz', {
      'device_id': '', 'ts_ms': _t0 * 1000, 'rec_ts': _t0,
      'counter': 99, 'hr': 99, 'step_count': 123,
    });
    await db.insert('day_result', {
      'day_id': '2026-09-01', 'algo_version': 100,
      'payload_json': '{"who":"local"}', 'computed_at': 1, 'finalized': 1,
    });
    await db.insert('day_result', {
      'day_id': '2026-09-03', 'algo_version': 100,
      'payload_json': '{"who":"local3"}', 'computed_at': 1, 'finalized': 0,
    });
    await db.insert('metric_series',
        {'date': '2026-09-01', 'key': 'rhr', 'value': 50.0});
    await db.insert('metric_series_version',
        {'date': '2026-09-01', 'algo_version': 100, 'source': 'band'});
    await db.insert('metric_method', {
      'date': '2026-09-01', 'key': 'rhr',
      'method': 'local', 'family': 'f', 'class': 'c',
    });
    await db.insert('baselines', {
      'key': 'movement_floor', 'payload_json': '{"who":"local"}',
      'updated_at': 1,
    });
    for (final dev in ['', 'band2']) {
      for (var b = 0; b < 4; b++) {
        await db.insert('decoded_rr', {
          'device_id': dev, 'ts_ms': _t0 * 1000, 'rec_ts': _t0,
          'beat_index': b, 'rr_ts_ms': _t0 * 1000 + b * 800, 'rr_ms': 700 + b,
        });
      }
    }
    // A second the source never mentions: untouched.
    for (var b = 0; b < 2; b++) {
      await db.insert('decoded_rr', {
        'device_id': '', 'ts_ms': (_t0 + 20) * 1000, 'rec_ts': _t0 + 20,
        'beat_index': b, 'rr_ts_ms': (_t0 + 20) * 1000, 'rr_ms': 900 + b,
      });
    }
    // Upstream's documented restore gap: a 1 Hz second without source RR
    // does NOT clear local beats. Keep that behavior in this performance PR.
    await db.insert('decoded_rr', {
      'device_id': '', 'ts_ms': (_t0 + 1) * 1000, 'rec_ts': _t0 + 1,
      'beat_index': 0, 'rr_ts_ms': (_t0 + 1) * 1000, 'rr_ms': 888,
    });
    await db.insert('raw_archive', {
      'device_id': '', 'hex': 'local-only', 'counter': 1,
      'packet_type': 32, 'rec_ts': _t0, 'captured_at': 1,
      'reason': 'undecodable_rec_v20',
    });
    await db.insert('substrate_archive', archiveRow([archiveSecond(_t0, 65)]));
  }

  /// A foreign export exercising every per-row rule. No PRIMARY KEYs and no
  /// NOT NULLs, so a value of the wrong storage class can be planted.
  Future<String> buildRulesSource() async {
    final path = p.join(tmp.path, 'rules_src.db');
    await databaseFactoryFfi.deleteDatabase(path);
    final src = await databaseFactoryFfi.openDatabase(path);
    // decoded_onehz: a column this build does not know (future_col), columns
    // this build has that the source lacks (step_count etc.), legacy
    // on_wrist/hr_valid values and the -50 °C sentinel.
    await src.execute('''CREATE TABLE decoded_onehz (
      device_id TEXT, ts_ms INTEGER, rec_ts, counter INTEGER, hr INTEGER,
      ax REAL, skin_temp_c REAL, on_wrist INTEGER, hr_valid INTEGER,
      future_col TEXT)''');
    Future<void> onehz(Object? dev, Object? tsMs, Object? recTs, int counter,
            double? skin) =>
        src.insert('decoded_onehz', {
          'device_id': dev, 'ts_ms': tsMs, 'rec_ts': recTs,
          'counter': counter, 'hr': 60 + counter, 'ax': 0.5,
          'skin_temp_c': skin, 'on_wrist': 1, 'hr_valid': 1,
          'future_col': 'x$counter',
        });
    await onehz(null, null, _t0, 1, -50.0); // sentinel -> NULL, key derived
    await onehz(null, null, _t0 + 1, 2, -49.99); // just above: kept
    await onehz('band2', (_t0 + 2) * 1000, _t0 + 2, 3, 33.5); // keyed: as is
    await onehz(null, null, 'abc', 4, 33.0); // non-numeric rec_ts: dropped
    await onehz(null, null, '${_t0 + 4}', 5, 33.0); // numeric TEXT: dropped
    await onehz('', null, (_t0 + 6).toDouble(), 6, 33.0); // REAL rec_ts
    await onehz(null, null, _t0 + 7, 7, -49.995); // boundary: NULL

    // decoded_rr, legacy: no rec_ts, no device_id, no ts_ms.
    await src.execute('''CREATE TABLE decoded_rr (
      counter INTEGER, beat_index INTEGER, rr_ts_ms, rr_ms INTEGER)''');
    Future<void> rr(int counter, int beat, Object? rrTsMs, int ms) =>
        src.insert('decoded_rr', {
          'counter': counter, 'beat_index': beat,
          'rr_ts_ms': rrTsMs, 'rr_ms': ms,
        });
    await rr(1, 0, _t0 * 1000, 500); // over local primary beats 0..3
    await rr(1, 1, _t0 * 1000 + 600, 510);
    await rr(9, 0, 'bad', 520); // non-numeric: dropped
    await rr(11, 0, (_t0 + 10) * 1000, 530);
    await rr(11, 1, (_t0 + 10) * 1000 + 700, 540);
    await rr(11, 2, (_t0 + 10) * 1000 + 900, 550);

    // samples, legacy: no device_id / ts_ms.
    await src.execute('CREATE TABLE samples (counter INTEGER, ts, hr INTEGER)');
    await src.insert('samples', {'counter': 1, 'ts': _t0, 'hr': 61});
    await src.insert('samples', {'counter': 2, 'ts': _t0 + 1, 'hr': 62});
    await src.insert('samples', {'counter': 3, 'ts': 'nope', 'hr': 63});

    // day_result without window_json / skipped / partial (dest defaults).
    await src.execute('''CREATE TABLE day_result (
      day_id TEXT, algo_version INTEGER, payload_json TEXT,
      computed_at INTEGER, finalized INTEGER, rhr REAL, rmssd REAL,
      readiness REAL)''');
    Future<void> day(String d, int v, String who, int fin) =>
        src.insert('day_result', {
          'day_id': d, 'algo_version': v, 'payload_json': '{"who":"$who"}',
          'computed_at': 2, 'finalized': fin, 'rhr': 55.0,
        });
    await day('2026-09-01', 100, 'src', 1); // locally finalized: protected
    await day('2026-09-01', 101, 'src101', 1); // new version: written
    await day('2026-09-02', 100, 'staleSrc2', 1); // duplicate: later row wins
    await day('2026-09-02', 100, 'src2', 1);
    await day('2026-09-03', 100, 'src3', 0); // local not finalized: replaced

    await src.execute(
        'CREATE TABLE metric_series (date TEXT, key TEXT, value REAL)');
    for (final r in [
      ['2026-09-01', 'rhr', 60.0],
      ['2026-09-01', 'hrv', 40.0],
      ['2026-09-02', 'rhr', 55.0],
      ['2026-09-03', 'rhr', 57.0],
    ]) {
      await src.insert(
          'metric_series', {'date': r[0], 'key': r[1], 'value': r[2]});
    }
    await src.execute('CREATE TABLE metric_series_version '
        '(date TEXT, algo_version INTEGER, source TEXT)');
    for (final d in ['2026-09-01', '2026-09-02']) {
      await src.insert('metric_series_version',
          {'date': d, 'algo_version': 101, 'source': 'src'});
    }
    await src.execute('CREATE TABLE metric_method (date TEXT, key TEXT, '
        'method TEXT, family TEXT, class TEXT)');
    for (final d in ['2026-09-01', '2026-09-02']) {
      await src.insert('metric_method', {
        'date': d, 'key': 'rhr', 'method': 'src', 'family': 'f', 'class': 'c',
      });
    }
    await src.execute('CREATE TABLE baselines '
        '(key TEXT, payload_json TEXT, updated_at INTEGER)');
    for (final key in ['movement_floor', 'new_baseline']) {
      await src.insert('baselines', {
        'key': key, 'payload_json': '{"who":"source"}', 'updated_at': 2,
      });
    }

    // events: upstream's shape plus an unknown column.
    await src.execute('''CREATE TABLE events (device_id TEXT, hex TEXT,
      event_id INTEGER, ts INTEGER, captured_at INTEGER, extra TEXT)''');
    await src.insert('events', {
      'device_id': '', 'hex': 'aa01', 'event_id': 3, 'ts': _t0,
      'captured_at': _t0 * 1000, 'extra': 'zz',
    });
    await src.execute('CREATE TABLE band_battery (device_id TEXT, ts INTEGER, '
        'battery_pct REAL, source TEXT)');
    await src.insert('band_battery', {
      'device_id': '', 'ts': _t0, 'battery_pct': 70.0, 'source': 'history',
    });
    await src.execute('CREATE TABLE band_events (device_id TEXT, hex TEXT, '
        'event_id INTEGER, name TEXT, ts INTEGER, captured_at INTEGER)');
    await src.insert('band_events', {
      'device_id': '', 'hex': 'bb01', 'event_id': 3, 'name': 'test',
      'ts': _t0, 'captured_at': 2,
    });
    await src.execute('CREATE TABLE raw_archive (device_id TEXT, hex TEXT, '
        'counter INTEGER, packet_type INTEGER, rec_ts INTEGER, '
        'captured_at INTEGER, reason TEXT)');
    for (final hex in ['src-a', 'src-b']) {
      await src.insert('raw_archive', {
        'device_id': '', 'hex': hex, 'counter': 1, 'packet_type': 32,
        'rec_ts': _t0, 'captured_at': 1, 'reason': 'undecodable_rec_v20',
      });
    }
    // Use upstream's lossless archive, including a collision and a new second.
    // A straight REPLACE of this bucket would lose the local value.
    final db = await LocalDb.instance;
    final ddl = (await db.rawQuery("SELECT sql FROM sqlite_master "
        "WHERE type = 'table' AND name = 'substrate_archive'")).single;
    await src.execute(ddl['sql'] as String);
    await src.insert('substrate_archive', archiveRow([
      archiveSecond(_t0, 1), archiveSecond(_t0 + 1, 66),
    ]));
    await src.close();
    return path;
  }

  group('equivalence law: bulk == per-row', () {
    late String rulesSrc;
    setUpAll(() async => rulesSrc = await buildRulesSource());

    Future<(Map<String, int>, Map<String, List<String>>)> run(
        Future<Map<String, int>> Function(String) merge) async {
      await freshLocal();
      await seedLocal();
      final counts = await merge(rulesSrc);
      return (counts, await dump());
    }

    test('every table ends byte-identical, and the counts agree', () async {
      final (oracleCounts, oracle) = await run(LocalDb.debugMergeRowByRow);
      final (bulkCounts, bulk) = await run(LocalDb.importFromDbFile);
      for (final t in oracle.keys) {
        expect(bulk[t], oracle[t], reason: 'table $t');
      }
      expect(bulk.keys.toSet(), oracle.keys.toSet());
      expect(bulkCounts, oracleCounts);
    });

    group('each rule, by hand', () {
      late Map<String, int> counts;
      late Database db;
      setUpAll(() async {
        db = await freshLocal();
        await seedLocal();
        counts = await LocalDb.importFromDbFile(rulesSrc);
      });

      test('decoded_onehz: retired columns NULL, sentinel NULL, keys derived, '
          'non-numeric rec_ts dropped, unknown column dropped', () async {
        final rows = await db.rawQuery(
            'SELECT device_id, ts_ms, rec_ts, counter, skin_temp_c, on_wrist, '
            'hr_valid, step_count FROM decoded_onehz ORDER BY device_id, ts_ms');
        expect([for (final r in rows) r['counter']], [1, 2, 6, 7, 3]);
        final by = {for (final r in rows) r['counter']: r};
        expect(by[1]!['device_id'], '');
        expect(by[1]!['ts_ms'], _t0 * 1000);
        expect(by[1]!['skin_temp_c'], isNull);
        expect(by[2]!['skin_temp_c'], -49.99);
        expect(by[7]!['skin_temp_c'], isNull);
        expect(by[3]!['device_id'], 'band2');
        expect(by[3]!['ts_ms'], (_t0 + 2) * 1000);
        expect(by[6]!['ts_ms'], (_t0 + 6) * 1000);
        for (final r in rows) {
          expect(r['on_wrist'], isNull);
          expect(r['hr_valid'], isNull);
          expect(r['step_count'], isNull, reason: 'missing column: default');
        }
        expect(counts['decoded_onehz'], 5);
      });

      test('decoded_rr: rec_ts from rr_ts_ms, bad row dropped, stale local '
          'tail cleared for the writing device only', () async {
        final rows = await db.rawQuery(
            'SELECT device_id, ts_ms, rec_ts, beat_index, rr_ms FROM decoded_rr '
            'ORDER BY device_id, ts_ms, beat_index');
        expect([
          for (final r in rows)
            '${r['device_id']}/${r['ts_ms']}/${r['beat_index']}/${r['rr_ms']}'
        ], [
          '/${_t0 * 1000}/0/500',
          '/${_t0 * 1000}/1/510',
          '/${(_t0 + 1) * 1000}/0/888',
          '/${(_t0 + 10) * 1000}/0/530',
          '/${(_t0 + 10) * 1000}/1/540',
          '/${(_t0 + 10) * 1000}/2/550',
          '/${(_t0 + 20) * 1000}/0/900',
          '/${(_t0 + 20) * 1000}/1/901',
          'band2/${_t0 * 1000}/0/700',
          'band2/${_t0 * 1000}/1/701',
          'band2/${_t0 * 1000}/2/702',
          'band2/${_t0 * 1000}/3/703',
        ]);
        expect(rows.firstWhere((r) => r['ts_ms'] == (_t0 + 10) * 1000)['rec_ts'],
            _t0 + 10);
        expect(counts['decoded_rr'], 5);
      });

      test('samples: legacy rows keyed to the primary band at ts*1000', () async {
        final rows = await db.rawQuery(
            'SELECT device_id, ts_ms, ts FROM samples ORDER BY ts_ms');
        expect([for (final r in rows) '${r['device_id']}/${r['ts_ms']}'],
            ['/${_t0 * 1000}', '/${(_t0 + 1) * 1000}']);
      });

      test('1 Hz without source beats retains local RR, the upstream restore '
          'gap; the replacement 1 Hz value still wins', () async {
        final rows = await db.query('decoded_onehz',
            where: 'device_id = ? AND ts_ms = ?',
            whereArgs: ['', _t0 * 1000]);
        expect(rows.single['hr'], 61);
        expect(rows.single['step_count'], isNull);
        final beats = await db.query('decoded_rr',
            where: 'device_id = ? AND ts_ms = ?',
            whereArgs: ['', (_t0 + 1) * 1000]);
        expect(beats.single['rr_ms'], 888);
      });

      test('day_result: a finalized local (day, version) is never overwritten; '
          '_days counts distinct days written', () async {
        final rows = await db.rawQuery(
            'SELECT day_id, algo_version, payload_json, window_json, skipped, '
            'partial FROM day_result ORDER BY day_id, algo_version');
        expect([
          for (final r in rows)
            '${r['day_id']}/${r['algo_version']}/${r['payload_json']}'
        ], [
          '2026-09-01/100/{"who":"local"}',
          '2026-09-01/101/{"who":"src101"}',
          '2026-09-02/100/{"who":"src2"}',
          '2026-09-03/100/{"who":"src3"}',
        ]);
        final imported = rows.where((r) => r['payload_json'] != '{"who":"local"}');
        for (final r in imported) {
          expect(r['window_json'], '{}', reason: 'dest default');
          expect(r['skipped'], 0);
          expect(r['partial'], 0);
        }
        expect(counts['_days'], 3);
        expect(counts['day_result'], 4);
      });

      test('metric_series / _version / metric_method skip a locally '
          'finalized day', () async {
        final series = await db.rawQuery(
            'SELECT date, key, value FROM metric_series ORDER BY date, key');
        expect([for (final r in series) '${r['date']}/${r['key']}/${r['value']}'],
            [
              '2026-09-01/rhr/50.0',
              '2026-09-02/rhr/55.0',
              '2026-09-03/rhr/57.0',
            ]);
        final ver = await db.rawQuery(
            'SELECT date, algo_version FROM metric_series_version ORDER BY date');
        expect([for (final r in ver) '${r['date']}/${r['algo_version']}'],
            ['2026-09-01/100', '2026-09-02/101']);
        final method = await db.rawQuery(
            'SELECT date, method FROM metric_method ORDER BY date');
        expect([for (final r in method) '${r['date']}/${r['method']}'],
            ['2026-09-01/local', '2026-09-02/src']);
      });

      test('a table the export lacks is skipped; an unknown column is dropped',
          () async {
        expect(counts.containsKey('external_hr'), isFalse);
        final ev = await db.rawQuery('SELECT * FROM events');
        expect(ev, hasLength(1));
        expect(ev.single.containsKey('extra'), isFalse);
      });

      test('finalized history keeps local baselines and admits missing keys',
          () async {
        final rows = await db.query('baselines', orderBy: 'key');
        expect([for (final r in rows) '${r['key']}/${r['payload_json']}'], [
          'movement_floor/{"who":"local"}', 'new_baseline/{"who":"source"}',
        ]);
      });

      test('raw archive keeps every frame; substrate archive merges losslessly '
          'with local winning collisions', () async {
        final raw = await db.query('raw_archive', orderBy: 'hex');
        expect([for (final r in raw) r['hex']], ['local-only', 'src-a', 'src-b']);
        expect(counts['raw_archive'], 2);
        final row = (await db.query('substrate_archive')).single;
        final bucket = SubstrateArchiveCodec.decode(row['blob'] as Uint8List)!;
        expect(bucket.onehz.rowCount, 2);
        expect([for (var i = 0; i < 2; i++) bucket.onehz.valueAt('hr', i)],
            [65, 66]);
        expect(counts['substrate_archive'], 1);
      });
    });

    test('a corrupt source rethrows (a restore is not tolerant)', () async {
      final path = await buildCorruptSource(tmp.path);
      await freshLocal();
      await expectLater(
          LocalDb.importFromDbFile(path), throwsA(isA<DatabaseException>()));
    });
  });

  group('25k boundary equivalence', () {
    late String boundarySrc;
    const n = 25001;
    setUpAll(() async {
      boundarySrc = p.join(tmp.path, 'boundary_src.db');
      final src = await databaseFactoryFfi.openDatabase(boundarySrc);
      // No PK: rows 1 and 25001 derive the same 1 Hz key. Give the last
      // row an explicit, sparse rowid so range paging must cross a gap too.
      await src.execute('CREATE TABLE decoded_onehz '
          '(rec_ts INTEGER, counter INTEGER, hr INTEGER)');
      await src.execute('''
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n
                                WHERE i < $n)
        INSERT INTO decoded_onehz(rowid, rec_ts, counter, hr)
        SELECT CASE WHEN i = $n THEN 50001 ELSE i END,
               CASE WHEN i IN (1, $n) THEN $_t0 ELSE $_t0 + i END,
               i, CASE WHEN i = $n THEN 87 ELSE 60 END FROM n''');
      await src.execute('''CREATE TABLE decoded_rr (
        device_id TEXT, ts_ms INTEGER, rec_ts INTEGER, beat_index INTEGER,
        rr_ts_ms INTEGER, rr_ms INTEGER)''');
      // Higher beat first at rowid 24999, lower beat last at rowid 25001.
      // Both fall in the SAME upstream 2k page, but DIFFERENT bulk chunks.
      // Thus the oracle keeps both, while a per-25k-chunk tail max loses 1.
      await src.execute('''
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n
                                WHERE i < $n)
        INSERT INTO decoded_rr
        SELECT '',
               (CASE WHEN i IN (24999, 25001) THEN $_t0 ELSE $_t0 + i END) * 1000,
               CASE WHEN i IN (24999, 25001) THEN $_t0 ELSE $_t0 + i END,
               CASE WHEN i = 24999 THEN 1 ELSE 0 END,
               ($_t0 + i) * 1000, 500 + i % 100 FROM n''');
      await src.close();
    });

    test('later source row wins across chunks and rowid gaps; whole-source '
        'beat maximum keeps an earlier higher index', () async {
      Future<(Map<String, int>, Map<String, List<String>>)> run(
          Future<Map<String, int>> Function(String) merge) async {
        await freshLocal();
        await seedLocal();
        final counts = await merge(boundarySrc);
        return (counts, await dump());
      }
      final (refCounts, ref) = await run(LocalDb.debugMergeRowByRow);
      final (counts, actual) = await run(LocalDb.importFromDbFile);
      expect(counts, refCounts);
      expect(actual, ref);
      final db = await LocalDb.instance;
      final onehz = await db.query('decoded_onehz',
          where: 'device_id = ? AND ts_ms = ?', whereArgs: ['', _t0 * 1000]);
      expect(onehz.single['hr'], 87, reason: 'last source row wins');
      final rr = await db.query('decoded_rr',
          where: 'device_id = ? AND ts_ms = ?', whereArgs: ['', _t0 * 1000],
          orderBy: 'beat_index');
      expect([for (final r in rr) r['beat_index']], [0, 1]);
      expect([for (final r in rr) r['rr_ms']], [501, 599]);
      expect(await db.query('decoded_rr', where: 'device_id = ?',
          whereArgs: ['band2']), hasLength(4));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('whole-source RR max preparation is paged at 25k rows', () async {
      await freshLocal();
      _invokes.clear();
      _counting = true;
      try {
        await LocalDb.importFromDbFile(boundarySrc);
      } finally {
        _counting = false;
      }
      final prep = [
        for (final e in _invokes)
          for (final op in _operations(e.arguments))
            if (RegExp(r'INSERT[\s\S]*\btemp\.[\s\S]*\bMAX\s*\('
                r'[\s\S]*\bdecoded_rr\b', caseSensitive: false)
                .hasMatch(op['sql'] as String)) op,
      ];
      expect(prep, hasLength(2),
          reason: 'whole-source beat maxima need two bounded scans for 25001 rows');
      for (var i = 0; i < prep.length; i++) {
        final sql = prep[i]['sql'] as String;
        expect(sql, matches(RegExp(r'rowid\s*>\s*\?', caseSensitive: false)));
        expect(sql, matches(RegExp(r'rowid\s*<=\s*\?', caseSensitive: false)));
        final args = prep[i]['arguments'] as List;
        expect(args, hasLength(2));
        expect(args[0], i * 25000);
        expect(args[1], inInclusiveRange(i == 0 ? 25000 : n, (i + 1) * 25000));
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  test("bulk keeps a second's higher beats that a later source page omits "
      '(row-by-row drops them)', () async {
    final path = p.join(tmp.path, 'rr_page_tail_src.db');
    final src = await databaseFactoryFfi.openDatabase(path);
    // No PK: repeated lower indices must get later rowids while the
    // earlier higher beats remain in the source's union.
    await src.execute('''CREATE TABLE decoded_rr (
      device_id TEXT, ts_ms INTEGER, rec_ts INTEGER, beat_index INTEGER,
      rr_ts_ms INTEGER, rr_ms INTEGER)''');
    Future<void> beat(int b) => src.insert('decoded_rr', {
      'device_id': '', 'ts_ms': _t0 * 1000, 'rec_ts': _t0,
      'beat_index': b, 'rr_ts_ms': _t0 * 1000 + b * 700, 'rr_ms': 700 + b,
    });
    for (var b = 0; b < 6; b++) {
      await beat(b);
    }
    await src.execute('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n
                              WHERE i < 2001)
      INSERT INTO decoded_rr
      SELECT '', ($_t0 + i) * 1000, $_t0 + i, 0,
             ($_t0 + i) * 1000, 800 FROM n''');
    // Rowids 2008 and 2009 land on the oracle's second 2k page.
    for (var b = 0; b < 2; b++) {
      await beat(b);
    }
    final sourceBeats = await src.rawQuery(
        'SELECT DISTINCT beat_index, rr_ts_ms, rr_ms FROM decoded_rr '
        'WHERE device_id = ? AND ts_ms = ? ORDER BY beat_index',
        ['', _t0 * 1000]);
    await src.close();
    expect([for (final r in sourceBeats) r['beat_index']], [0, 1, 2, 3, 4, 5]);

    Future<List<Map<String, Object?>>> restoredBeats(Database db) =>
        db.query('decoded_rr', columns: ['beat_index', 'rr_ts_ms', 'rr_ms'],
            where: 'device_id = ? AND ts_ms = ?',
            whereArgs: ['', _t0 * 1000], orderBy: 'beat_index');

    final bulkDb = await freshLocal();
    await LocalDb.importFromDbFile(path);
    final bulk = await restoredBeats(bulkDb);
    expect([for (final r in bulk) r['beat_index']], [0, 1, 2, 3, 4, 5]);
    expect(bulk, sourceBeats, reason: 'bulk retains the whole-source union');

    final oracleDb = await freshLocal();
    await LocalDb.debugMergeRowByRow(path);
    final oracle = await restoredBeats(oracleDb);
    expect([for (final r in oracle) r['beat_index']], [0, 1],
        reason: 'the later page maximum of 1 deletes earlier beats 2..5');
    expect(oracle, sourceBeats.take(2).toList());
  });

  test('RR with a supplied key but no usable record time is dropped', () async {
    final path = p.join(tmp.path, 'invalid_rr_src.db');
    final src = await databaseFactoryFfi.openDatabase(path);
    await src.execute('CREATE TABLE decoded_rr (device_id TEXT, ts_ms INTEGER, '
        'rec_ts, beat_index INTEGER, rr_ts_ms, rr_ms INTEGER)');
    await src.insert('decoded_rr', {
      'device_id': '', 'ts_ms': _t0 * 1000, 'rec_ts': null,
      'beat_index': 0, 'rr_ts_ms': 'bad', 'rr_ms': 700,
    });
    await src.close();
    await freshLocal();
    final refCounts = await LocalDb.debugMergeRowByRow(path);
    final ref = await dump();
    await freshLocal();
    final counts = await LocalDb.importFromDbFile(path);
    expect(counts, refCounts);
    expect(await dump(), ref);
    expect(counts['decoded_rr'], 0);
    expect(await (await LocalDb.instance).query('decoded_rr'), isEmpty);
  });

  test('a source RR column named d or k does not change the beat maxima',
      () async {
    final path = p.join(tmp.path, 'rr_alias_column_src.db');
    await databaseFactoryFfi.deleteDatabase(path);
    final src = await databaseFactoryFfi.openDatabase(path);
    // GROUP BY prefers a source column over a result alias of the same name.
    await src.execute('''CREATE TABLE decoded_rr (
      device_id TEXT, ts_ms INTEGER, rec_ts INTEGER, beat_index INTEGER,
      rr_ts_ms INTEGER, rr_ms INTEGER, d TEXT, k INTEGER)''');
    for (var b = 0; b < 4; b++) {
      await src.insert('decoded_rr', {
        'device_id': '', 'ts_ms': _t0 * 1000, 'rec_ts': _t0,
        'beat_index': b, 'rr_ts_ms': _t0 * 1000 + b * 700, 'rr_ms': 700 + b,
        'd': b == 3 ? 'a' : 'b', 'k': 3 - b,
      });
    }
    await src.close();
    await freshLocal();
    final refCounts = await LocalDb.debugMergeRowByRow(path);
    final ref = await dump();
    final db = await freshLocal();
    final counts = await LocalDb.importFromDbFile(path);
    expect(counts, refCounts);
    expect(await dump(), ref);
    expect([for (final r in await db.query('decoded_rr', orderBy: 'beat_index'))
      r['beat_index']], [0, 1, 2, 3]);
  });

  test('sparse source rowids are paged by row, not by rowid range', () async {
    final path = p.join(tmp.path, 'sparse_rowid_src.db');
    await databaseFactoryFfi.deleteDatabase(path);
    final src = await databaseFactoryFfi.openDatabase(path);
    // A legacy `rec_ts INTEGER PRIMARY KEY` table has rowids near 1.79e9.
    // A smaller gap keeps the red run short: 40 empty 25k ranges.
    await src.execute('CREATE TABLE decoded_onehz '
        '(rec_ts INTEGER PRIMARY KEY, counter INTEGER, hr INTEGER)');
    await src.execute('''CREATE TABLE decoded_rr (
      device_id TEXT, ts_ms INTEGER, rec_ts INTEGER, beat_index INTEGER,
      rr_ts_ms INTEGER, rr_ms INTEGER)''');
    for (final rowid in [1, 1000001]) {
      await src.insert('decoded_onehz',
          {'rec_ts': rowid, 'counter': rowid, 'hr': 60});
      await src.insert('decoded_rr', {
        'rowid': rowid, 'device_id': '', 'ts_ms': (_t0 + rowid) * 1000,
        'rec_ts': _t0 + rowid, 'beat_index': 0,
        'rr_ts_ms': (_t0 + rowid) * 1000, 'rr_ms': 700,
      });
    }
    await src.close();
    await freshLocal();
    final refCounts = await LocalDb.debugMergeRowByRow(path);
    final ref = await dump();
    await freshLocal();
    _invokes.clear();
    _counting = true;
    final Map<String, int> counts;
    try {
      counts = await LocalDb.importFromDbFile(path);
    } finally {
      _counting = false;
    }
    expect(counts, refCounts);
    expect(await dump(), ref);
    for (final t in ['decoded_onehz', 'decoded_rr']) {
      final inserts = [
        for (final e in _invokes)
          for (final sql in _sqlOf(e.arguments))
            if (sql.startsWith('INSERT OR REPLACE INTO main."$t"')) sql,
      ];
      expect(inserts, hasLength(1), reason: '$t: 2 rows are one chunk');
    }
    expect(_callsTouching('decoded_rr'), lessThanOrEqualTo(15));
  });

  test('plain tables use ATTACH and INSERT SELECT on the public restore path',
      () async {
    final src = await buildRulesSource();
    await freshLocal();
    _invokes.clear();
    _counting = true;
    try {
      await LocalDb.importFromDbFile(src);
    } finally {
      _counting = false;
    }
    final sql = [for (final e in _invokes) ..._sqlOf(e.arguments)];
    expect(sql.any((s) => RegExp(r'^ATTACH\b', caseSensitive: false)
        .hasMatch(s.trimLeft())), isTrue,
        reason: 'bulk restore must attach the source on the destination handle');
    for (final t in [
      'decoded_onehz', 'decoded_rr', 'samples', 'raw_archive', 'events',
      'band_events', 'band_battery', 'day_result', 'metric_series',
      'metric_series_version', 'metric_method',
    ]) {
      expect(sql.any((s) => RegExp(
          'INSERT\\s+OR\\s+REPLACE\\s+INTO\\s+(?:main\\.)?["`]?'
          '$t\\b[\\s\\S]*\\bSELECT\\b', caseSensitive: false).hasMatch(s)),
          isTrue, reason: '$t must copy inside SQLite');
    }
  });

  // ── volume: sqflite calls per table, chunk commits ────────────────────────

  group('200k decoded_onehz + 100k decoded_rr', () {
    const nOneHz = 200000, nRr = 100000;
    late String bigSrc;

    setUpAll(() async {
      bigSrc = p.join(tmp.path, 'big_src.db');
      await databaseFactoryFfi.deleteDatabase(bigSrc);
      final src = await databaseFactoryFfi.openDatabase(bigSrc);
      await src.execute('''CREATE TABLE decoded_onehz (
        device_id TEXT NOT NULL DEFAULT '', ts_ms INTEGER NOT NULL DEFAULT 0,
        rec_ts INTEGER, counter INTEGER NOT NULL, hr INTEGER, ax REAL, ay REAL,
        az REAL, PRIMARY KEY (device_id, ts_ms))''');
      await src.execute('''CREATE TABLE decoded_rr (
        device_id TEXT NOT NULL DEFAULT '', ts_ms INTEGER NOT NULL DEFAULT 0,
        rec_ts INTEGER NOT NULL, beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
        PRIMARY KEY (device_id, ts_ms, beat_index))''');
      await src.execute('''
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n
                                WHERE i < $nOneHz)
        INSERT INTO decoded_onehz
        SELECT '', ($_t0 + i) * 1000, $_t0 + i, i, 40 + i % 100, 0.0, 0.0, 1.0
        FROM n''');
      await src.execute('''
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n
                                WHERE i < ${nRr ~/ 2}),
             b(k) AS (VALUES (0), (1))
        INSERT INTO decoded_rr
        SELECT '', ($_t0 + i) * 1000, $_t0 + i, k,
               ($_t0 + i) * 1000 + k * 700, 700 + i % 50
        FROM n, b ORDER BY i, k''');
      await src.close();
    });

    test('a bounded number of sqflite calls per table, not one per page',
        () async {
      await freshLocal();
      _invokes.clear();
      _counting = true;
      final Map<String, int> counts;
      try {
        counts = await LocalDb.importFromDbFile(bigSrc);
      } finally {
        _counting = false;
      }
      expect(counts['decoded_onehz'], nOneHz);
      expect(counts['decoded_rr'], nRr);
      final onehz = _callsTouching('decoded_onehz');
      final rr = _callsTouching('decoded_rr');
      // Allow two calls per 25k 1 Hz chunk, five per RR chunk (including
      // the paged whole-source max build and tail sweep), plus preparation.
      // Upstream uses about two calls per 2k rows and exceeds both bounds.
      expect(onehz, lessThanOrEqualTo(2 * (nOneHz ~/ 25000) + 10),
          reason: 'decoded_onehz: $onehz sqflite calls');
      expect(rr, lessThanOrEqualTo(5 * (nRr ~/ 25000) + 15),
          reason: 'decoded_rr: $rr sqflite calls');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('a failure in a later chunk leaves earlier chunks committed, and a '
        'rerun converges to the clean result', () async {
      const data = {'decoded_onehz', 'decoded_rr'};
      await freshLocal();
      await LocalDb.debugMergeRowByRow(bigSrc);
      final clean = await dump(only: data);

      final db = await freshLocal();
      // The LAST source row fails, whatever the chunk size.
      await db.execute('CREATE TRIGGER inject_fail BEFORE INSERT ON '
          'decoded_onehz WHEN NEW.counter = $nOneHz '
          "BEGIN SELECT RAISE(ABORT, 'injected'); END");
      await expectLater(LocalDb.importFromDbFile(bigSrc), throwsA(anything));
      final span = (await db.rawQuery(
              'SELECT COUNT(*) AS n, MAX(counter) AS hi FROM decoded_onehz'))
          .single;
      final landed = span['n'] as int;
      final maxCounter = span['hi'] as int?;
      expect(landed, greaterThan(0), reason: 'chunk 1 committed');
      expect(landed, lessThan(nOneHz), reason: 'the failing chunk rolled back');
      expect(maxCounter, landed, reason: 'a contiguous rowid prefix');

      await db.execute('DROP TRIGGER inject_fail');
      await LocalDb.importFromDbFile(bigSrc);
      expect(await dump(only: data), clean);
    }, timeout: const Timeout(Duration(minutes: 15)));

    test('bulk commits 25000 rows before a failure in the next chunk', () async {
      final db = await freshLocal();
      await db.execute('CREATE TRIGGER inject_fail BEFORE INSERT ON '
          'decoded_onehz WHEN NEW.counter = 25001 '
          "BEGIN SELECT RAISE(ABORT, 'injected-25001'); END");
      try {
        await expectLater(LocalDb.importFromDbFile(bigSrc), throwsA(
            isA<DatabaseException>().having((e) => e.toString(), 'message',
                contains('injected-25001'))));
        final span = (await db.rawQuery('SELECT COUNT(*) AS n, '
            'MAX(counter) AS hi FROM decoded_onehz')).single;
        expect(span, {'n': 25000, 'hi': 25000},
            reason: 'exactly one 25k chunk must remain committed');
      } finally {
        await db.execute('DROP TRIGGER inject_fail');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  // ── ATTACH hygiene ─────────────────────────────────────────────────────────

  group('the source is detached', () {
    Future<void> expectClean() async {
      final db = await LocalDb.instance;
      expect([
        for (final r in await db.rawQuery('PRAGMA database_list'))
          if (r['name'] != 'temp') r['name'] as String,
      ], ['main']);
      expect(await db.rawQuery("SELECT name FROM sqlite_temp_master "
          "WHERE type = 'table'"), isEmpty,
          reason: 'restore preparation and carried-beat tables must be dropped');
      // Exercise the same handle after cleanup. A leaked transaction or
      // attachment must not prevent the next band-sync write.
      await db.transaction((txn) => txn.rawQuery('SELECT 1'));
    }

    test('after a successful restore', () async {
      final src = await buildRulesSource();
      await freshLocal();
      await LocalDb.importFromDbFile(src);
      await expectClean();
    });

    test('after a restore that threw mid-copy', () async {
      final src = await buildRulesSource();
      final db = await freshLocal();
      await db.execute('CREATE TRIGGER inject_fail BEFORE INSERT ON '
          "decoded_onehz BEGIN SELECT RAISE(ABORT, 'injected'); END");
      await expectLater(LocalDb.importFromDbFile(src), throwsA(
          isA<DatabaseException>().having((e) => e.toString(), 'message',
              contains('injected'))));
      await db.execute('DROP TRIGGER inject_fail');
      await expectClean();
      await LocalDb.importFromDbFile(src);
      await expectClean();
    });

    for (final table in ['decoded_rr', 'day_result']) {
      test('after $table preparation and a failed insert', () async {
        final src = await buildRulesSource();
        final db = await freshLocal();
        await db.execute('CREATE TRIGGER inject_fail BEFORE INSERT ON '
            "$table BEGIN SELECT RAISE(ABORT, 'injected-$table'); END");
        await expectLater(LocalDb.importFromDbFile(src), throwsA(
            isA<DatabaseException>().having((e) => e.toString(), 'message',
                contains('injected-$table'))));
        await db.execute('DROP TRIGGER inject_fail');
        await expectClean();
        await LocalDb.importFromDbFile(src);
        await expectClean();
      });
    }

    test('after a corrupt source', () async {
      final path = await buildCorruptSource(tmp.path);
      await freshLocal();
      await expectLater(LocalDb.importFromDbFile(path), throwsA(anything));
      await expectClean();
    });
  });
}

/// An export whose header and schema read fine but whose decoded_onehz pages
/// are garbage: opening works, reading the table fails SQLITE_CORRUPT.
Future<String> buildCorruptSource(String dir) async {
  final path = p.join(dir, 'corrupt_src.db');
  await databaseFactoryFfi.deleteDatabase(path);
  final src = await databaseFactoryFfi.openDatabase(path);
  await src.execute('''CREATE TABLE decoded_onehz (
    device_id TEXT NOT NULL DEFAULT '', ts_ms INTEGER NOT NULL DEFAULT 0,
    rec_ts INTEGER, counter INTEGER NOT NULL, hr INTEGER, pad TEXT,
    PRIMARY KEY (device_id, ts_ms))''');
  await src.execute('''
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n
                            WHERE i < 4000)
    INSERT INTO decoded_onehz
    SELECT '', ($_t0 + i) * 1000, $_t0 + i, i, 60, hex(randomblob(40)) FROM n''');
  await src.close();
  final bytes = File(path).readAsBytesSync();
  bytes.fillRange(4096 * 3, bytes.length, 0xA5);
  File(path).writeAsBytesSync(bytes, flush: true);
  return path;
}
