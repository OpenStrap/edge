// Local persistence round-trips for the v7 user-data tables (journal / cycle /
// sessions / notifications). Runs the REAL LocalDb against an in-memory sqlite
// via sqflite_common_ffi — no platform plugins needed.
//
// Covers: journal upsert+read (idempotent on date), a workout session
// round-trip (live → done finalize), and notification idempotency (INSERT OR
// IGNORE keeps the generator from duplicating across passes).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  // Route sqflite through the FFI factory so LocalDb.instance opens a real
  // schema (onCreate builds the v7 tables). Delete any leftover file from a
  // prior run so each suite starts clean (LocalDb owns the openstrap.db path).
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_persistence_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('journal upsert + read (idempotent on date)', () async {
    const date = '2026-06-20';
    await LocalDb.putJournal(date, jsonEncode(['caffeine', 'late meal']), 'felt wired');
    var rows = await LocalDb.journalRows();
    final row = rows.firstWhere((r) => r['date'] == date);
    expect(jsonDecode(row['tags_json'] as String), ['caffeine', 'late meal']);
    expect(row['note'], 'felt wired');

    // Re-put the same date → REPLACE, not a duplicate row.
    await LocalDb.putJournal(date, jsonEncode(['rest day']), 'recovered');
    rows = await LocalDb.journalRows();
    final same = rows.where((r) => r['date'] == date).toList();
    expect(same.length, 1);
    expect(jsonDecode(same.first['tags_json'] as String), ['rest day']);
    expect(same.first['note'], 'recovered');

    // sinceDaysEpoch lower bound excludes older rows.
    await LocalDb.putJournal('2020-01-01', '[]', 'ancient');
    final recent = await LocalDb.journalRows(sinceDaysEpoch: '2026-01-01');
    expect(recent.any((r) => r['date'] == '2020-01-01'), isFalse);
    expect(recent.any((r) => r['date'] == date), isTrue);
  });

  test('workout session round-trip (live → finalized done)', () async {
    const id = 'w1700000000000';
    final startSec = 1700000000;
    await LocalDb.putSession({
      'id': id,
      'start_ts': startSec,
      'end_ts': null,
      'type': 'run',
      'status': 'live',
      'source': 'manual',
      'created_at': startSec * 1000,
    });
    var s = await LocalDb.session(id);
    expect(s, isNotNull);
    expect(s!['status'], 'live');

    // Finalize: same id, REPLACE with stats.
    await LocalDb.putSession({
      'id': id,
      'start_ts': startSec,
      'end_ts': startSec + 1800,
      'type': 'run',
      'status': 'done',
      'calories': 220.0,
      'strain': 9.4,
      'max_hr': 171,
      'duration_min': 30,
      'zone_min_json': jsonEncode(const <num>[]),
      'source': 'manual',
      'created_at': startSec * 1000,
    });
    s = await LocalDb.session(id);
    expect(s!['status'], 'done');
    expect(s['calories'], 220.0);
    expect(s['max_hr'], 171);
    expect(s['duration_min'], 30);

    // In-range query finds it; type setter mutates it; delete removes it.
    final inRange = await LocalDb.sessionsInRange(startSec - 10, startSec + 10);
    expect(inRange.any((r) => r['id'] == id), isTrue);
    await LocalDb.setSessionType(id, 'cycling');
    expect((await LocalDb.session(id))!['type'], 'cycling');
    await LocalDb.deleteSession(id);
    expect(await LocalDb.session(id), isNull);
  });

  test('notification idempotency (INSERT OR IGNORE by id) + unread/mark', () async {
    final row = {
      'id': '2026-06-20:illness',
      'kind': 'illness',
      'title': 'Possible illness onset',
      'body': 'Elevated resting HR + suppressed HRV.',
      'date': '2026-06-20',
      'created_at': 1700000000000,
      'read': 0,
    };
    await LocalDb.putNotification(row);
    await LocalDb.putNotification(row); // re-run pass: must NOT duplicate
    final all = await LocalDb.notifications();
    final mine = all.where((r) => r['id'] == '2026-06-20:illness').toList();
    expect(mine.length, 1);

    expect(await LocalDb.unreadCount(), greaterThanOrEqualTo(1));
    await LocalDb.markNotificationsRead(ids: ['2026-06-20:illness']);
    final after = (await LocalDb.notifications())
        .firstWhere((r) => r['id'] == '2026-06-20:illness');
    expect(after['read'], 1);
  });

  test('cycle log round-trip (ordered asc, delete)', () async {
    await LocalDb.putCycleLog('2026-05-01', 'start');
    await LocalDb.putCycleLog('2026-05-29', 'start');
    var logs = await LocalDb.cycleLogs();
    final dates = logs.map((r) => r['date']).toList();
    expect(dates.indexOf('2026-05-01') < dates.indexOf('2026-05-29'), isTrue);
    await LocalDb.deleteCycleLog('2026-05-01');
    logs = await LocalDb.cycleLogs();
    expect(logs.any((r) => r['date'] == '2026-05-01'), isFalse);
  });

  // ── resumable-sync cursor ──────────────────────────────────────────────────────
  // Kept in THIS file (not a separate suite) so it shares the single DB-test
  // isolate — two test files both opening LocalDb's fixed openstrap.db path race
  // on the on-disk sqlite file.
  test('sync cursor set/get round-trip + int parse', () async {
    expect(await LocalDb.getCursor('strap_trim'), isNull);
    await LocalDb.setCursor('strap_trim', 'deadbeef0102');
    expect(await LocalDb.getCursor('strap_trim'), 'deadbeef0102');
    await LocalDb.setCursor('strap_trim', 'cafe'); // REPLACE, not duplicate
    expect(await LocalDb.getCursor('strap_trim'), 'cafe');
    await LocalDb.setCursor('rec_ts_hw', '1750000000');
    expect(await LocalDb.getCursorInt('rec_ts_hw'), 1750000000);
    expect(await LocalDb.getCursorInt('missing'), isNull);
  });

  test('commitSyncBatch persists raw + advances high-water + stores trim token',
      () async {
    RawRecord raw(int counter, int recTs) => RawRecord(
        counter: counter,
        packetType: 47,
        hex: 'aa$counter',
        capturedAt: 1750000000000,
        recTs: recTs);
    await LocalDb.commitSyncBatch(
      [raw(10, 1750000100), raw(11, 1750000200)],
      [
        Sample(tsEpoch: 1750000100, counter: 10, hr: 60),
        Sample(tsEpoch: 1750000200, counter: 11, hr: 61),
      ],
      trimToken: 'aa00bb11cc22dd33',
    );
    final counts = await LocalDb.counts();
    expect(counts['raw'], greaterThanOrEqualTo(2));
    expect(await LocalDb.getCursorInt('counter_hw'), 11);
    expect(await LocalDb.getCursorInt('rec_ts_hw'), 1750000200);
    expect(await LocalDb.getCursor('strap_trim'), 'aa00bb11cc22dd33');
  });

  test('high-water only advances (a re-delivered older batch never regresses it)',
      () async {
    await LocalDb.commitSyncBatch(
      [
        RawRecord(
            counter: 5,
            packetType: 47,
            hex: 'aa5',
            capturedAt: 1750000000000,
            recTs: 1750000050)
      ],
      [Sample(tsEpoch: 1750000050, counter: 5, hr: 59)],
      trimToken: 'beef',
    );
    expect(await LocalDb.getCursorInt('counter_hw'), 11); // unchanged
    expect(await LocalDb.getCursorInt('rec_ts_hw'), 1750000200); // unchanged
    expect(await LocalDb.getCursor('strap_trim'), 'beef'); // always latest ACK
  });
}
