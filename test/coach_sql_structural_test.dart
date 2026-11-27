// Layer 2 of the coach's read-only surface: the STRUCTURAL btree gate.
//
// The text-level guard (coach_sql_guard_adversarial_test.dart) is a parser, and
// a parser is a model of SQL rather than SQL itself. This gate doesn't parse at
// all — it asks SQLite which btrees a statement would actually open (EXPLAIN's
// OpenRead/ReopenIdx root pages) and refuses anything outside the base tables
// the coach's own views are built from. These tests drive it DIRECTLY, past the
// parser, so a future parser regression can never be the only thing standing
// between an LLM prompt and on-device GPS coordinates.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/coach/coach_db.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_coach_structural_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await CoachDb.close();
    await LocalDb.close();
  });

  test('seeds a session + a route + derived scalars', () async {
    final db = await LocalDb.instance;
    await db.insert('metric_series',
        {'date': '2026-07-01', 'key': 'rhr', 'value': 52.0});
    await db.insert('sessions', {
      'id': 's1',
      'start_ts': 1782000000,
      'end_ts': 1782003600,
      'type': 'run',
      'status': 'done',
      'source': 'local',
      'created_at': 0,
    });
    await LocalDb.appendRoutePoints('s1', [
      {
        'session_id': 's1',
        'seq': 0,
        'ts_ms': 1782000000000,
        'lat': 51.5007,
        'lng': -0.1246,
      },
    ]);
    final n = await db.rawQuery('SELECT COUNT(*) c FROM workout_route');
    expect((n.first['c'] as num).toInt(), 1);
  });

  test('allows a legitimate view query through the btree gate', () async {
    await expectLater(
      CoachDb.debugAssertAllowedBtrees(
          "SELECT date, value FROM v_metric WHERE key='rhr' LIMIT 10"),
      completes,
    );
    await expectLater(
      CoachDb.debugAssertAllowedBtrees(
          'SELECT s.type, d.readiness FROM v_sessions s '
          'JOIN v_daily d ON d.date = s.date LIMIT 10'),
      completes,
    );
  });

  for (final sql in const <String>[
    // THE exploit — comma cross-join onto on-device GPS coordinates.
    'SELECT r.lat, r.lng, r.ts_ms FROM v_sessions s, workout_route r LIMIT 50',
    'SELECT * FROM workout_route LIMIT 50',
    'SELECT * FROM raw_archive LIMIT 50',
    'SELECT * FROM sleep_override LIMIT 50',
    'SELECT name, sql FROM sqlite_master LIMIT 50',
    'SELECT * FROM v_daily WHERE date IN (SELECT session_id FROM workout_route)',
    'SELECT lat FROM workout_route UNION ALL SELECT value FROM v_metric',
  ]) {
    test('btree gate rejects (parser bypassed): $sql', () async {
      await expectLater(
        CoachDb.debugAssertAllowedBtrees(sql),
        throwsA(isA<SqlGuardError>()),
        reason: 'REACHED STORAGE OUTSIDE THE COACH VIEWS: $sql',
      );
    });
  }

  test('runCoachSql returns an error (not rows) for the GPS exploit', () async {
    final out = await CoachDb.runCoachSql(
        'SELECT r.lat, r.lng, r.ts_ms FROM v_sessions s, workout_route r LIMIT 50');
    final j = jsonDecode(out) as Map<String, dynamic>;
    expect(j.containsKey('error'), isTrue);
    expect(j.containsKey('rows'), isFalse);
    // No coordinate ever appears in what would be sent to the provider.
    expect(out.contains('51.5'), isFalse);
    expect(out.contains('-0.12'), isFalse);
  });

  test('runCoachSql still serves the allowed views', () async {
    final out = await CoachDb.runCoachSql(
        "SELECT date, value FROM v_metric WHERE key='rhr'");
    final j = jsonDecode(out) as Map<String, dynamic>;
    expect(j['row_count'], 1);
    expect((j['rows'] as List).first['value'], 52.0);
  });

  test('closing the coach handle leaves the app writer open', () async {
    final writer = await LocalDb.instance;
    await CoachDb.runCoachSql("SELECT date FROM v_metric WHERE key='rhr'",
        today: (day: '2026-07-01', readiness: 70));
    // The coach's TEMP views live on its own connection, not the writer.
    expect(
        await writer.rawQuery(
            "SELECT name FROM sqlite_temp_master WHERE name='v_daily'"),
        isEmpty);
    await CoachDb.close();
    expect(writer.isOpen, isTrue);
    await writer.insert('metric_series',
        {'date': '2026-07-02', 'key': 'rhr', 'value': 53.0});
  });
}
