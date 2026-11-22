// The coach's run_sql result must SAY when it is a truncated page.
//
// guardAndPrepare appends `LIMIT rowCap` to a query the model wrote without a
// LIMIT, so `rows.length > rowCap` is unreachable on the common path: the model
// gets exactly 200 rows, `row_count: 200`, and no note. Asked "how has my
// resting HR moved over the last year", it then describes 200 of ~730 days as
// the whole window — a number the data does not support (AGENTS.md §3.3).
//
// A full page from an injected LIMIT is not proof there is more; it is proof
// the answer may be incomplete. The note says that, not "there are more".
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
    LocalDb.dbName = 'openstrap_coach_sql_cap_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    final db = await LocalDb.instance;
    // 250 stored metric rows: more than the 200-row cap.
    for (var i = 0; i < 250; i++) {
      await db.insert('metric_series', {
        'date': '2026-01-01',
        'key': 'row_$i',
        'value': i.toDouble(),
      });
    }
    // A second page wide enough that 200 rows serialized exceed the
    // 16,000-character clip, so the cap note has to survive that clip.
    final wide = 'k' * 180;
    for (var i = 0; i < 200; i++) {
      await db.insert('metric_series', {
        'date': '2026-01-02',
        'key': '${wide}_$i',
        'value': i.toDouble(),
      });
    }
  });
  tearDownAll(() async {
    await CoachDb.close();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  test('an auto-limited query says its page may be incomplete', () async {
    final out =
        jsonDecode(
              await CoachDb.runCoachSql(
                'SELECT date, key, value FROM v_metric',
              ),
            )
            as Map<String, dynamic>;
    expect(out['row_count'], 200);
    expect(
      out['note'],
      isNotNull,
      reason: 'the model cannot know 200 is a page and not the whole answer',
    );
    expect('${out['note']}', contains('200'));
  });

  test('a query the model limited itself gets no invented warning', () async {
    final out =
        jsonDecode(
              await CoachDb.runCoachSql(
                'SELECT date, key FROM v_metric LIMIT 5',
              ),
            )
            as Map<String, dynamic>;
    expect(out['row_count'], 5);
    expect(out['note'], isNull);
  });

  test(
    'an explicit LIMIT at the cap still says the page may be incomplete',
    () async {
      final out =
          jsonDecode(
                await CoachDb.runCoachSql(
                  "SELECT date, key FROM v_metric WHERE date = '2026-01-01' "
                  'LIMIT 200',
                ),
              )
              as Map<String, dynamic>;
      expect(out['row_count'], 200);
      expect(out['note'], isNotNull);

      // SQLite's legacy `LIMIT <offset>, <count>` form: the count is the second
      // number, and this is still a full page.
      final legacy =
          jsonDecode(
                await CoachDb.runCoachSql(
                  "SELECT date, key FROM v_metric WHERE date = '2026-01-01' "
                  'LIMIT 0, 200',
                ),
              )
              as Map<String, dynamic>;
      expect(legacy['row_count'], 200);
      expect(legacy['note'], isNotNull);
    },
  );

  test('an inner LIMIT does not decide the page warning', () async {
    // A subquery limit cannot fill the outer page, so this 5-row result is not
    // a full page and carries no warning.
    final small =
        jsonDecode(
              await CoachDb.runCoachSql(
                "WITH t AS (SELECT date, key FROM v_metric "
                "WHERE date = '2026-01-01' LIMIT 5) "
                'SELECT * FROM t LIMIT 200',
              ),
            )
            as Map<String, dynamic>;
    expect(small['row_count'], 5);
    expect(small['note'], isNull);

    // An inner limit large enough to fill the outer 200-row page still warns.
    // The rule looks at the RESULT count, not at the first LIMIT number.
    final full =
        jsonDecode(
              await CoachDb.runCoachSql(
                "WITH t AS (SELECT date, key FROM v_metric "
                "WHERE date = '2026-01-01' LIMIT 500) "
                'SELECT * FROM t LIMIT 200',
              ),
            )
            as Map<String, dynamic>;
    expect(full['row_count'], 200);
    expect(full['note'], isNotNull);
  });

  test('a LIMIT that does not bound the outer query still gets capped',
      () async {
    for (final q in <String>[
      'SELECT date, key FROM v_metric WHERE date IN (SELECT date FROM '
          "v_metric WHERE date = '2026-01-01' LIMIT 2)",
      "SELECT date, key FROM v_metric WHERE date = '2026-01-01' LIMIT 100000",
    ]) {
      expect(CoachDb.guardAndPrepare(q), endsWith('LIMIT 200'));
      final out = jsonDecode(await CoachDb.runCoachSql(q))
          as Map<String, dynamic>;
      expect(out['row_count'], 200, reason: q);
      expect(out['note'], isNotNull, reason: q);
    }
  });

  test('the cap note survives the 16,000-character clip', () async {
    final raw = await CoachDb.runCoachSql(
      "SELECT key FROM v_metric WHERE date = '2026-01-02'",
    );
    expect(raw.length, lessThanOrEqualTo(16020));
    expect(raw, contains('"note"'));
    expect(raw, contains('There may be more'));
  });
}
