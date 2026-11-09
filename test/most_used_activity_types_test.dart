// The activity picker's quick row: which `sessions.type` values count as
// "most done", in which order, and which rows never count. The picker's own
// widget test lives in ui2_activity_test.dart; this pins the SQL behind it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const int _t0 = 1_800_000_040; // a fixed epoch second

Future<void> _session(String id, String type, int startTs,
    {String status = 'done', String source = 'manual'}) async {
  final db = await LocalDb.instance;
  await db.insert('sessions', {
    'id': id,
    'start_ts': startTs,
    'end_ts': startTs + 1800,
    'type': type,
    'status': status,
    'source': source,
    'created_at': startTs,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'most_used_activity_types_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => await LocalDb.close());

  test('most-used first, live sessions never count', () async {
    await _session('a1', 'running', _t0 - 10 * 86400);
    await _session('a2', 'running', _t0 - 9 * 86400);
    await _session('a3', 'running', _t0 - 8 * 86400);
    await _session('b1', 'cycling', _t0 - 20 * 86400);
    await _session('b2', 'cycling', _t0 - 19 * 86400);
    await _session('c1', 'yoga', _t0 - 30 * 86400);
    await _session('live1', 'swimming', _t0 - 1000, status: 'live');

    final rows = await LocalDb.mostUsedActivityTypes();
    expect([for (final r in rows) r['type']], ['running', 'cycling', 'yoga']);
    expect(rows.first['n'], 3);
    expect(rows.first['last_ts'], _t0 - 8 * 86400);
  });

  test('stored names group by their normalized catalogue key', () async {
    // 'Running', 'running' and 'RUNNING' are one activity to activityByName,
    // so they must count as one here too — not three separate types.
    await _session('a1', 'Running', _t0 - 10 * 86400);
    await _session('a2', 'running', _t0 - 9 * 86400);
    await _session('a3', 'RUNNING', _t0 - 8 * 86400);
    await _session('b1', 'cycling', _t0 - 5 * 86400);

    final rows = await LocalDb.mostUsedActivityTypes();
    expect([for (final r in rows) r['type']], ['running', 'cycling']);
    expect(rows.first['n'], 3);
  });

  test('a tie on count falls back to the most recently used', () async {
    await _session('a1', 'running', _t0 - 10 * 86400);
    await _session('b1', 'cycling', _t0 - 3 * 86400);
    final rows = await LocalDb.mostUsedActivityTypes();
    expect(rows.first['type'], 'cycling');
  });

  test('sinceTs bounds the window and limit caps the rows', () async {
    await _session('a1', 'running', _t0 - 10 * 86400);
    await _session('a2', 'running', _t0 - 200 * 86400); // outside 90 days
    await _session('b1', 'cycling', _t0 - 20 * 86400);
    await _session('c1', 'yoga', _t0 - 5 * 86400);

    final rows =
        await LocalDb.mostUsedActivityTypes(sinceTs: _t0 - 90 * 86400, limit: 2);
    // Both types have n=1 inside the window, so the tiebreaker decides:
    // yoga was used more recently than running.
    expect([for (final r in rows) r['type']], ['yoga', 'running']);
    expect(rows.first['n'], 1,
        reason: 'the 200-day-old run is outside the window');
  });

  test('a full tie (count and last_ts) falls back to the key alphabetically',
      () async {
    await _session('a1', 'yoga', _t0 - 10 * 86400);
    await _session('b1', 'cycling', _t0 - 10 * 86400);
    final rows = await LocalDb.mostUsedActivityTypes();
    expect([for (final r in rows) r['type']], ['cycling', 'yoga']);
  });

  test('imported sources and future-dated rows never count', () async {
    await _session('a1', 'running', _t0 - 10 * 86400);
    await _session('i1', 'cycling', _t0 - 9 * 86400, source: 'scored_import');
    await _session('i2', 'swimming', _t0 - 8 * 86400, source: 'whoop');
    await _session('f1', 'yoga', _t0 + 86400); // future: clock skew

    final rows = await LocalDb.mostUsedActivityTypes(toTs: _t0);
    expect([for (final r in rows) r['type']], ['running']);
  });

  test('an empty table is an empty list, not an error', () async {
    expect(await LocalDb.mostUsedActivityTypes(), isEmpty);
  });
}
