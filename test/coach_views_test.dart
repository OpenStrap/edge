// Coach derived-only SQL views — verify they CREATE (json1 available) and that
// CoachDb.runCoachSql reads them through a read-only handle while rejecting raw.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/coach/coach_db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_coach_views_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await CoachDb.close();
    await LocalDb.close();
  });

  test('views create + json1 unnest works; CoachDb reads, rejects raw', () async {
    final db = await LocalDb.instance; // onCreate builds tables + views

    // Seed derived data.
    await db.insert('metric_series', {'date': '2026-06-29', 'key': 'rhr', 'value': 55.0});
    await db.insert('metric_series', {'date': '2026-06-29', 'key': 'hrr_bpm', 'value': 31.0});
    await db.insert('day_result', {
      'day_id': '2026-06-29',
      'algo_version': 25,
      'payload_json': jsonEncode({
        'series': {
          'hr_curve': [
            {'t': 0, 'v': 60},
            {'t': 60, 'v': 62},
          ],
        },
      }),
      'window_json': '{}',
      'computed_at': 0,
      'finalized': 0,
      'rhr': 55.0,
    });

    // Views via the RW handle (json1 sanity).
    final daily = await db.rawQuery('SELECT resting_hr, hrr_bpm FROM v_daily');
    expect((daily.first['resting_hr'] as num).toInt(), 55);
    expect((daily.first['hrr_bpm'] as num).toInt(), 31);
    final series = await db.rawQuery(
        "SELECT t, v FROM v_series WHERE date='2026-06-29' AND series='hr_curve' ORDER BY t");
    expect(series.length, 2);
    expect((series.last['v'] as num).toInt(), 62);

    // End-to-end through the read-only handle + shaping.
    final ok = await CoachDb.runCoachSql(
        "SELECT date, value FROM v_metric WHERE key='rhr'");
    final decoded = jsonDecode(ok) as Map<String, dynamic>;
    expect(decoded['row_count'], 1);
    expect((decoded['rows'] as List).first['value'], 55.0);

    // Raw access is rejected with a self-correct reason, not rows.
    final bad = await CoachDb.runCoachSql('SELECT * FROM raw_records');
    final badDec = jsonDecode(bad) as Map<String, dynamic>;
    expect(badDec.containsKey('error'), isTrue);
  });

  test("today's readiness in v_daily / v_metric follows the headline rule",
      () async {
    final db = await LocalDb.instance;
    // Mid-sync the last derive wrote a partial night's 2 for today.
    await db.insert('metric_series',
        {'date': '2026-10-08', 'key': 'readiness', 'value': 2.0});
    await db.insert('metric_series',
        {'date': '2026-10-07', 'key': 'readiness', 'value': 40.0});
    Future<Map<String, Object?>> rows(String sql,
        ({String day, num? readiness})? today) async {
      final out = jsonDecode(await CoachDb.runCoachSql(sql, today: today))
          as Map<String, dynamic>;
      expect(out.containsKey('error'), isFalse, reason: '$out');
      return {
        for (final r in (out['rows'] as List).cast<Map>())
          r['date'] as String: r.values.last,
      };
    }

    const daily =
        'SELECT date, readiness FROM v_daily WHERE readiness IS NOT NULL '
        'OR date >= \'2026-10-07\' ORDER BY date';
    const metric =
        "SELECT date, value FROM v_metric WHERE key='readiness' ORDER BY date";
    // Not final yet: no number for today, earlier days untouched.
    const pending = (day: '2026-10-08', readiness: null);
    expect((await rows(daily, pending))['2026-10-08'], isNull);
    expect((await rows(daily, pending))['2026-10-07'], 40.0);
    expect((await rows(metric, pending))['2026-10-08'], isNull);
    // Final: the headline's number (the pin), not the series value.
    const done = (day: '2026-10-08', readiness: 28);
    expect((await rows(daily, done))['2026-10-08'], 28);
    expect((await rows(metric, done))['2026-10-08'], 28);
    // No headline read: the stored views as before.
    expect((await rows(daily, null))['2026-10-08'], 2.0);
    // A pinned day with no stored readiness row still reads as the headline.
    const pinnedOnly = (day: '2026-10-09', readiness: 31);
    expect((await rows(daily, pinnedOnly))['2026-10-09'], 31);
    expect((await rows(metric, pinnedOnly))['2026-10-09'], 31);
    const noPin = (day: '2026-10-09', readiness: null);
    expect((await rows(metric, noPin)).containsKey('2026-10-09'), isFalse);
  });
}
