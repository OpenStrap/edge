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

Future<void> seedLegacy(Database db, String dayId, int t0, {int n = 30}) async {
  await db.insert('day_result', {
    'day_id': dayId,
    'algo_version': 47,
    'payload_json': jsonEncode(bundleFor(t0, n: n)),
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
    // Static, so it would otherwise leak into whatever runs after it.
    LocalDb.debugAfterReencodePrepare = null;
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

  test('a concurrent derive is never overwritten with a stale bundle', () async {
    // The prepare is deliberately done outside any transaction, on a worker
    // isolate, and takes hundreds of milliseconds — and derivation itself runs
    // in more than one isolate. The update used to key on (day_id,
    // algo_version) alone, so a bundle read before that work started was
    // written back over whatever the other isolate had committed in the
    // meantime, leaving the row holding the new scalar columns beside the old
    // payload. The walk starts at the NEWEST day and kAlgoVersion is unbumped,
    // so its first targets are exactly the rows a light derive is rewriting.
    //
    // A full heavy batch is seeded so the prepare genuinely occupies the window
    // the write below lands in; the assertion on the return value pins that.
    for (var d = 1; d <= 40; d++) {
      await seedLegacy(db, '2026-01-${d.toString().padLeft(2, '0')}',
          t0 + d * 86400, n: 800);
    }
    const newest = '2026-01-40';

    // The other isolate finishing a derive of the newest day — the first row
    // this walk read. Driven from the seam between the prepare and the write
    // rather than raced against a sleep, so the interleave is placed and the
    // test cannot quietly stop exercising it on a slower runner.
    final fresh = bundleFor(t0 + 40 * 86400 + 3600, n: 900);
    LocalDb.debugAfterReencodePrepare = () async {
      await db.update(
        'day_result',
        {'payload_json': jsonEncode(fresh)},
        where: 'day_id = ? AND algo_version = ?',
        whereArgs: [newest, 47],
      );
    };

    expect(
      await LocalDb.reencodeLegacyDayResults(),
      39,
      reason: 'the moved row must be the one row the walk declines to write',
    );

    final after = SeriesCodec.decodePayloadJson(
      (await db.query(
        'day_result',
        columns: ['payload_json'],
        where: 'day_id = ?',
        whereArgs: [newest],
      )).first['payload_json'],
    );
    expect(jsonEncode(after), jsonEncode(fresh));
  });

  test('a row that lost the compare-and-set is converted later', () async {
    // Declining the write is only half of it: the cursor must not step past
    // the row and latch `done`, or it keeps the legacy shape forever.
    for (var d = 1; d <= 40; d++) {
      await seedLegacy(db, '2026-01-${d.toString().padLeft(2, '0')}',
          t0 + d * 86400, n: 800);
    }
    const newest = '2026-01-40';

    LocalDb.debugAfterReencodePrepare = () async {
      await db.update(
        'day_result',
        {'payload_json': jsonEncode(bundleFor(t0 + 40 * 86400 + 3600, n: 900))},
        where: 'day_id = ? AND algo_version = ?',
        whereArgs: [newest, 47],
      );
    };
    expect(await LocalDb.reencodeLegacyDayResults(), 39,
        reason: 'precondition: the row was skipped');
    // Only the first pass races; the retries below must run clean.
    LocalDb.debugAfterReencodePrepare = null;

    var total = 0;
    for (var i = 0; i < 5; i++) {
      final n = await LocalDb.reencodeLegacyDayResults();
      if (n == 0) break;
      total += n;
    }
    expect(total, 1, reason: 'the skipped row is picked up by a later pass');
    final after = (await db.query(
      'day_result',
      columns: ['payload_json'],
      where: 'day_id = ?',
      whereArgs: [newest],
    )).first['payload_json'] as String;
    expect(SeriesCodec.needsReencode(after), isFalse);
  });

  test('an import rewinds a finished walk', () async {
    // importFromDbFile writes day_result rows with a raw batch.insert, so they
    // arrive in whatever shape the source device stored. The walk latches
    // `done` and is forward-only, so without a rewind those rows would keep the
    // legacy shape forever and the import would silently undo the compression.
    //
    // Driven through the REAL import rather than a hand-written cursor reset:
    // written the other way, this test still passed with the rewind deleted
    // from production, which is the only thing it exists to protect.
    await seedLegacy(db, '2026-01-01', t0);
    expect(await LocalDb.reencodeLegacyDayResults(), 1);
    expect(await LocalDb.reencodeLegacyDayResults(), 0); // walk is done

    // A source export holding one legacy row, the shape an older device wrote.
    final srcPath = p.join(
      await databaseFactory.getDatabasesPath(),
      'openstrap_reencode_src.db',
    );
    await databaseFactory.deleteDatabase(srcPath);
    final src = await databaseFactory.openDatabase(srcPath);
    await src.execute(
      'CREATE TABLE day_result ('
      'day_id TEXT NOT NULL, algo_version INTEGER NOT NULL, '
      'payload_json TEXT, window_json TEXT, computed_at INTEGER, '
      'finalized INTEGER DEFAULT 0, skipped INTEGER DEFAULT 0, '
      'partial INTEGER DEFAULT 0, rhr REAL, rmssd REAL, readiness REAL, '
      'PRIMARY KEY (day_id, algo_version))',
    );
    await src.insert('day_result', {
      'day_id': '2026-02-01',
      'algo_version': 47,
      'payload_json': jsonEncode(bundleFor(t0 + 86400 * 40)),
      'window_json': '{}',
      'computed_at': 1234567,
      'finalized': 0,
      'skipped': 0,
      'partial': 0,
    });
    await src.close();

    final counts = await LocalDb.importFromDbFile(srcPath);
    expect(counts['day_result'], 1);

    var total = 0;
    for (var i = 0; i < 10; i++) {
      final n = await LocalDb.reencodeLegacyDayResults(limit: 2);
      if (n == 0) break;
      total += n;
    }
    expect(total, 1, reason: 'the imported row gets converted');

    final rows = await db.query('day_result', columns: ['payload_json']);
    for (final r in rows) {
      expect(SeriesCodec.needsReencode(r['payload_json'] as String), isFalse);
    }
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
