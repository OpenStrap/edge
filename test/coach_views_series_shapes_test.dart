// v_series must be BLIND to how a curve is stored.
//
// day_result.payload_json holds curves in three shapes at once — `legacy`
// ([{t,v},…]) from before data/series_codec.dart existed, and the `grid`
// ({t0,dt,v[]}) / `offset` ({t0,to[],v[]}) forms written since. Old rows keep
// their legacy shape forever (there is no rewriting migration), so a real
// database holds a MIXTURE and the coach must not be able to tell.
//
// This is the regression pin for that: the same day, stored both ways, has to
// come out of the view identically — and a mixed database must not emit a row
// twice or drop one, which is what a wrong branch guard would do.
//
// It also pins the reason the payload could not simply be gzipped: these views
// read the column with SQL (json_each/json_extract), so the stored bytes have
// to stay something json1 can walk.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

/// A day bundle covering every curve the view exposes, in LEGACY shape:
///   • a regular grid (hr_curve, strain_curve, skin_temp_day)
///   • an irregular curve (hrv_day, resp_day)
///   • the odd value key (zone_timeline → 'z')
///   • a root-level curve (activity_curve)
///   • a curve too short to encode, which must stay legacy (hrv_timeline)
///   • hypnogram, which has no `t` and must never be touched
Map<String, dynamic> legacyBundle(int t0) => {
  'scalars': {'rhr': 55.0},
  'series': {
    'hr_curve': [
      for (var i = 0; i < 12; i++) {'t': t0 + i * 60, 'v': 60 + i},
    ],
    'strain_curve': [
      for (var i = 0; i < 8; i++) {'t': t0 + i * 60, 'v': i * 0.37},
    ],
    'skin_temp_day': [
      for (var i = 0; i < 5; i++) {'t': t0 + i * 300, 'v': -1.5 + i},
    ],
    // Irregular on purpose — this is the branch that pairs `to` with `v`.
    'hrv_day': [
      {'t': t0 + 9, 'v': 36.8},
      {'t': t0 + 71, 'v': 56.1},
      {'t': t0 + 325, 'v': 72.5},
      {'t': t0 + 400, 'v': 41.2},
    ],
    'resp_day': [
      {'t': t0 + 52, 'v': 14.9},
      {'t': t0 + 2738, 'v': 15.4},
      {'t': t0 + 3548, 'v': 13.1},
    ],
    'zone_timeline': [
      for (var i = 0; i < 8; i++) {'t': t0 + i * 60, 'z': i % 4},
    ],
    // Two points — below minPoints, so it must survive as a legacy array even
    // in the "encoded" row.
    'hrv_timeline': [
      {'t': 9, 'v': 36.8},
      {'t': 69, 'v': 44.1},
    ],
    'hypnogram': [
      {'start': t0, 'end': t0 + 3600, 'stage': 'light'},
      {'start': t0 + 3600, 'end': t0 + 4200, 'stage': 'deep'},
      {'start': t0 + 4200, 'end': t0 + 7200, 'stage': 'rem'},
    ],
  },
  'activity_curve': [
    for (var i = 0; i < 10; i++) {'t': t0 + i * 300, 'v': i * 1.5},
  ],
};

Future<void> insertDay(
  Database db,
  String dayId,
  Map<String, dynamic> bundle,
) async {
  await db.insert('day_result', {
    'day_id': dayId,
    'algo_version': 47,
    'payload_json': jsonEncode(bundle),
    'window_json': '{}',
    'computed_at': 0,
    'finalized': 0,
  });
}

Future<List<Map<String, Object?>>> seriesRows(Database db, String dayId) async =>
    db.rawQuery(
      'SELECT series, t, v FROM v_series WHERE date = ? '
      'ORDER BY series ASC, t ASC, v ASC',
      [dayId],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  const t0 = 1783572180;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_series_shapes_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    db = await LocalDb.instance;

    await insertDay(db, '2026-01-01', legacyBundle(t0));
    await insertDay(
      db,
      '2026-01-02',
      SeriesCodec.encodePayload(legacyBundle(t0)),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('an encoded day and a legacy day yield identical view rows', () async {
    final legacy = await seriesRows(db, '2026-01-01');
    final encoded = await seriesRows(db, '2026-01-02');

    expect(legacy, isNotEmpty, reason: 'the fixture must produce rows at all');
    expect(encoded.length, legacy.length);
    for (var i = 0; i < legacy.length; i++) {
      expect(encoded[i]['series'], legacy[i]['series']);
      expect(encoded[i]['t'], legacy[i]['t'], reason: 'row $i timestamp');
      expect(encoded[i]['v'], legacy[i]['v'], reason: 'row $i value');
    }
  });

  test('every curve the view exposes is actually covered', () async {
    final got = (await seriesRows(db, '2026-01-02'))
        .map((r) => r['series'] as String)
        .toSet();
    expect(got, {
      'hr_curve',
      'strain_curve',
      'skin_temp_day',
      'hrv_day',
      'resp_day',
      'zone_timeline',
      'hrv_timeline',
      'activity_curve',
    });
  });

  test('the fixture really exercises all three shapes', () {
    final encoded = SeriesCodec.encodePayload(legacyBundle(t0));
    final series = encoded['series'] as Map;
    // grid
    expect((series['hr_curve'] as Map).containsKey('dt'), isTrue);
    // offset
    expect((series['hrv_day'] as Map).containsKey('to'), isTrue);
    // legacy passthrough — too short to encode
    expect(series['hrv_timeline'], isA<List>());
    // never touched
    expect(series['hypnogram'], isA<List>());
  });

  test('a mixed database emits each row exactly once', () async {
    // The branch guards are what prevent double-counting: legacy needs an
    // `array`, grid needs `.dt`, offset needs `.to`. A row satisfying two would
    // appear twice and silently double every curve the coach reads.
    final dupes = await db.rawQuery('''
      SELECT date, series, t, COUNT(*) n FROM v_series
      GROUP BY date, series, t, v HAVING n > 1
    ''');
    expect(dupes, isEmpty);

    final total = await db.rawQuery('SELECT COUNT(*) c FROM v_series');
    final legacy = await seriesRows(db, '2026-01-01');
    expect(
      (total.first['c'] as num).toInt(),
      legacy.length * 2,
      reason: 'both days must contribute the same number of rows',
    );
  });

  test('a curve carrying BOTH dt and to is not doubled', () async {
    // The codec never writes both, but the storage layer does not enforce that
    // — an import from a foreign device or a corrupted row can. When the grid
    // and offset branches were only guarded on their own field, such a curve
    // matched both and the coach saw every point twice.
    await db.insert('day_result', {
      'day_id': '2026-01-03',
      'algo_version': 47,
      'payload_json': jsonEncode({
        'series': {
          'hr_curve': {
            't0': 100,
            'dt': 60,
            'to': [0, 60, 120],
            'v': [1, 2, 3],
          },
        },
      }),
      'window_json': '{}',
      'computed_at': 0,
    });

    final rows = await seriesRows(db, '2026-01-03');
    expect(rows, hasLength(3), reason: 'each point exactly once');
    // `dt` wins, matching SeriesCodec.decodeCurve, so SQL and Dart agree on
    // what an ambiguous curve means rather than disagreeing.
    expect(rows.map((r) => r['t']), [100, 160, 220]);
  });

  test('one corrupt payload does not fail the whole view', () async {
    // json_extract RAISES on a malformed document. Without a json_valid guard
    // in the `latest` CTE, a single unparseable row took down every other day's
    // curves with it — the coach got an error instead of the data it could
    // still have had.
    await db.insert('day_result', {
      'day_id': '2026-01-04',
      'algo_version': 47,
      'payload_json': '{ this is not json',
      'window_json': '{}',
      'computed_at': 0,
    });
    try {
      final rows = await db.rawQuery(
        "SELECT COUNT(*) c FROM v_series WHERE date = '2026-01-01'",
      );
      expect((rows.first['c'] as num).toInt(), greaterThan(0));
      expect(await seriesRows(db, '2026-01-04'), isEmpty);
    } finally {
      // Removed here rather than left for the shared teardown: this row is
      // deliberately malformed, and the "encoder never emits invalid JSON"
      // assertion further down scans the whole table.
      await db.delete(
        'day_result',
        where: 'day_id = ?',
        whereArgs: ['2026-01-04'],
      );
    }
  });

  test('the offset branch stays linear in the curve length', () async {
    // SQLite cannot index a table-valued function. Written as json_each over
    // `.to` JOINed to json_each over `.v` on `key`, the offset branch therefore
    // has no way to resolve the join except a full cross product of the two,
    // and its cost grows with the SQUARE of the curve length — 877 ms against
    // 89 ms on a year of real days, worse the denser the sampling gets. Since
    // hrv_day, hrv_timeline and resp_day are all irregularly sampled, every one
    // of them takes that path.
    //
    // The shape is what the plan shows: one virtual-table scan nested inside
    // another. v_series has exactly three json_each calls, one per branch, so a
    // fourth scan appearing here means the join came back.
    final plan = await db.rawQuery('EXPLAIN QUERY PLAN SELECT * FROM v_series');
    final scans = plan
        .map((r) => r['detail'] as String? ?? '')
        .where((d) => d.contains('VIRTUAL TABLE'))
        .toList();
    expect(
      scans,
      hasLength(3),
      reason:
          'one json_each per branch, never a TVF joined to a TVF:\n'
          '${plan.map((r) => r['detail']).join('\n')}',
    );
  });

  test('an offset curve with fewer offsets than values gains no rows', () async {
    // Only a foreign or corrupt payload can carry a `to` shorter than its `v` —
    // the codec writes them in lockstep. It still pins the bound that keeps the
    // linear form row-for-row identical to the join it replaced: the join
    // emitted min(len(to), len(v)) rows, so a value with no offset has to be
    // dropped rather than emitted with a NULL timestamp.
    await db.insert('day_result', {
      'day_id': '2026-01-05',
      'algo_version': 47,
      'payload_json': jsonEncode({
        'series': {
          'hrv_day': {
            't0': 100,
            'to': [0, 5],
            'v': [1, 2, 3, 4],
          },
        },
      }),
      'window_json': '{}',
      'computed_at': 0,
    });
    try {
      final rows = await seriesRows(db, '2026-01-05');
      expect(rows.map((r) => r['t']), [100, 105]);
    } finally {
      await db.delete(
        'day_result',
        where: 'day_id = ?',
        whereArgs: ['2026-01-05'],
      );
    }
  });

  test('one corrupt payload does not fail v_hypnogram either', () async {
    // Same failure and same guard as v_series above. Without json_valid in the
    // `latest` CTE, one unparseable row made json_extract raise for the whole
    // query, so a single corrupt day removed EVERY day's sleep stages from the
    // coach rather than only its own.
    await db.insert('day_result', {
      'day_id': '2026-01-06',
      'algo_version': 47,
      'payload_json': '{ this is not json',
      'window_json': '{}',
      'computed_at': 0,
    });
    try {
      // Scanned unfiltered, the way csv_export and the coach actually read it.
      // A `WHERE date = …` proves nothing here: SQLite pushes that predicate
      // into the CTE and never evaluates json_extract on the corrupt row.
      final rows = await db.rawQuery(
        'SELECT date, start_ts, end_ts, stage FROM v_hypnogram '
        'ORDER BY date ASC, start_ts ASC',
      );
      expect(rows.where((r) => r['date'] == '2026-01-01'), hasLength(3));
    } finally {
      await db.delete(
        'day_result',
        where: 'day_id = ?',
        whereArgs: ['2026-01-06'],
      );
    }
  });

  test('v_hypnogram is unaffected by the encoding', () async {
    final legacy = await db.rawQuery(
      "SELECT start_ts, end_ts, stage FROM v_hypnogram "
      "WHERE date='2026-01-01' ORDER BY start_ts",
    );
    final encoded = await db.rawQuery(
      "SELECT start_ts, end_ts, stage FROM v_hypnogram "
      "WHERE date='2026-01-02' ORDER BY start_ts",
    );
    expect(legacy.length, 3);
    expect(encoded, legacy);
  });

  test('the encoded row is materially smaller on disk', () async {
    final rows = await db.rawQuery(
      'SELECT day_id, LENGTH(payload_json) n FROM day_result ORDER BY day_id',
    );
    final legacyLen = (rows.first['n'] as num).toInt();
    final encodedLen = (rows.last['n'] as num).toInt();
    expect(encodedLen, lessThan(legacyLen));
  });

  test('the stored payload is still valid JSON to SQLite', () async {
    // The reason this is an encoding change and not a gzip: json1 has to be
    // able to walk the column, or the views above cannot exist.
    final rows = await db.rawQuery(
      'SELECT day_id FROM day_result WHERE NOT json_valid(payload_json)',
    );
    expect(rows, isEmpty);
  });
}
