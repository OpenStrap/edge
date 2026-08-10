// The one-time walk that converts pre-codec day_result rows to the compact
// curve format.
//
// This is the only code in the app that REWRITES a durable derived row, so the
// bar is higher than "it shrinks things":
//   • values must survive exactly — a day older than rawRetentionDays has no
//     substrate left to re-derive from, so a lossy rewrite is unrecoverable
//   • nothing but payload_json may change — no re-dating, no re-finalizing
//   • the walk must TERMINATE, and must not re-read converted rows forever
//   • it must be safe to interrupt and resume, because it runs after derivation
//     and the app can be killed at any point

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

Map<String, dynamic> bundleFor(int t0, {int n = 30}) => {
  'scalars': {'rhr': 55.0, 'readiness': 71.0},
  'series': {
    'hr_curve': [
      for (var i = 0; i < n; i++) {'t': t0 + i * 60, 'v': 60 + (i % 17)},
    ],
    'hrv_day': [
      for (var i = 0; i < n; i++) {'t': t0 + i * 61 + (i % 5), 'v': 30.0 + i},
    ],
    'zone_timeline': [
      for (var i = 0; i < n; i++) {'t': t0 + i * 60, 'z': i % 4},
    ],
  },
  'activity_curve': [
    for (var i = 0; i < n; i++) {'t': t0 + i * 300, 'v': i * 1.5},
  ],
};

Future<void> seedLegacy(Database db, String dayId, int t0) async {
  await db.insert('day_result', {
    'day_id': dayId,
    'algo_version': 47,
    'payload_json': jsonEncode(bundleFor(t0)),
    'window_json': '{}',
    'computed_at': 1234567,
    'finalized': 1,
    'skipped': 0,
    'partial': 0,
    'rhr': 55.0,
    'rmssd': 41.0,
    'readiness': 71.0,
  });
}

/// Reset the forward-only cursor so each test starts a fresh walk.
Future<void> clearCursor(Database db) async {
  await db.delete(
    'compute_freshness',
    where: 'key = ?',
    whereArgs: [LocalDb.kReencodeCursorKey],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  const t0 = 1783572180;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_reencode_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    db = await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('rewrites legacy rows and shrinks them', () async {
    await seedLegacy(db, '2026-01-01', t0);
    final before =
        (await db.query('day_result', columns: ['payload_json'])).first['payload_json']
            as String;

    expect(await LocalDb.reencodeLegacyDayResults(), 1);

    final after =
        (await db.query('day_result', columns: ['payload_json'])).first['payload_json']
            as String;
    expect(after.length, lessThan(before.length));
    expect(SeriesCodec.needsReencode(after), isFalse);
  });

  test('every value survives the rewrite exactly', () async {
    await seedLegacy(db, '2026-01-01', t0);
    await LocalDb.reencodeLegacyDayResults();

    final after = SeriesCodec.decodePayloadJson(
      (await db.query('day_result', columns: ['payload_json'])).first['payload_json'],
    );
    expect(jsonEncode(after), jsonEncode(bundleFor(t0)));
  });

  test('nothing but payload_json is touched', () async {
    // A rewrite that moved computed_at would look like a fresh derivation; one
    // that cleared `finalized` would put a locked day back in the recompute
    // queue. Neither is this function's business.
    await seedLegacy(db, '2026-01-01', t0);
    final before = (await db.query('day_result')).first;
    await LocalDb.reencodeLegacyDayResults();
    final after = (await db.query('day_result')).first;

    for (final key in before.keys) {
      if (key == 'payload_json') continue;
      expect(after[key], before[key], reason: 'column $key changed');
    }
  });

  test('an already-encoded row is left alone and reports zero', () async {
    await db.insert('day_result', {
      'day_id': '2026-01-01',
      'algo_version': 47,
      'payload_json': jsonEncode(SeriesCodec.encodePayload(bundleFor(t0))),
      'window_json': '{}',
      'computed_at': 0,
    });
    expect(await LocalDb.reencodeLegacyDayResults(), 0);
  });

  test('the walk terminates and does not rescan converted rows', () async {
    for (var d = 1; d <= 9; d++) {
      await seedLegacy(db, '2026-01-0$d', t0 + d * 86400);
    }

    // Small batches so the cursor has to carry progress across calls.
    var total = 0;
    var calls = 0;
    while (calls < 20) {
      final n = await LocalDb.reencodeLegacyDayResults(limit: 2);
      calls++;
      total += n;
      if (n == 0) break;
    }
    expect(total, 9, reason: 'every seeded day should be converted once');

    // Once done it stays done — further calls must not re-read anything.
    expect(await LocalDb.reencodeLegacyDayResults(limit: 2), 0);
    expect(await LocalDb.reencodeLegacyDayResults(limit: 2), 0);

    final rows = await db.query('day_result', columns: ['payload_json']);
    for (final r in rows) {
      expect(SeriesCodec.needsReencode(r['payload_json'] as String), isFalse);
    }
  });

  test('it is resumable — an interrupted walk finishes later', () async {
    for (var d = 1; d <= 6; d++) {
      await seedLegacy(db, '2026-01-0$d', t0 + d * 86400);
    }
    expect(await LocalDb.reencodeLegacyDayResults(limit: 2), 2);

    // Simulate a relaunch mid-walk: the cursor is durable, the handle is not.
    await LocalDb.close();
    db = await LocalDb.instance;

    var total = 2;
    for (var i = 0; i < 10; i++) {
      final n = await LocalDb.reencodeLegacyDayResults(limit: 2);
      if (n == 0) break;
      total += n;
    }
    expect(total, 6);
  });

  test('a corrupt cursor restarts the walk instead of wedging it', () async {
    await seedLegacy(db, '2026-01-01', t0);
    await LocalDb.putComputeFreshness(LocalDb.kReencodeCursorKey, 'not json');
    expect(await LocalDb.reencodeLegacyDayResults(), 1);
  });

  test('an unparseable payload is skipped, not destroyed', () async {
    await db.insert('day_result', {
      'day_id': '2026-01-01',
      'algo_version': 47,
      'payload_json': '{ this is not json',
      'window_json': '{}',
      'computed_at': 0,
    });
    await clearCursor(db);
    expect(await LocalDb.reencodeLegacyDayResults(), 0);
    final after =
        (await db.query('day_result', columns: ['payload_json'])).first['payload_json'];
    expect(after, '{ this is not json');
  });

  test('a row it cannot shrink is left as it is', () async {
    // Curves too short to encode: the walk must not write an equal-or-larger
    // payload back just to say it did something.
    final tiny = {
      'series': {
        'hr_curve': [
          {'t': t0, 'v': 60},
          {'t': t0 + 60, 'v': 61},
        ],
      },
    };
    await db.insert('day_result', {
      'day_id': '2026-01-01',
      'algo_version': 47,
      'payload_json': jsonEncode(tiny),
      'window_json': '{}',
      'computed_at': 0,
    });
    await clearCursor(db);
    expect(await LocalDb.reencodeLegacyDayResults(), 0);
    final after =
        (await db.query('day_result', columns: ['payload_json'])).first['payload_json'];
    expect(after, jsonEncode(tiny));
  });

  test('every algo_version generation of a day is converted', () async {
    // day_result is keyed (day_id, algo_version); a day can hold more than one
    // generation and the walk must not stop at the newest.
    for (final v in const [45, 46, 47]) {
      await db.insert('day_result', {
        'day_id': '2026-01-01',
        'algo_version': v,
        'payload_json': jsonEncode(bundleFor(t0)),
        'window_json': '{}',
        'computed_at': 0,
      });
    }
    var total = 0;
    for (var i = 0; i < 10; i++) {
      final n = await LocalDb.reencodeLegacyDayResults(limit: 1);
      if (n == 0) break;
      total += n;
    }
    expect(total, 3);
  });
}
