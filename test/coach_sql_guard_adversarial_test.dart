// ADVERSARIAL suite for the coach's read-only SQL guard.
//
// The guard is the boundary between on-device health data and a third-party
// LLM endpoint: anything it lets through is serialized into a prompt and
// leaves the device. It is an ALLOW-LIST (only the v_* coach views and CTEs
// declared in the same statement may appear in a table position), so a table
// added to the schema tomorrow is closed by default.
//
// Every case below is an escape attempt. The first one is a verified working
// exploit against the previous FROM/JOIN-only regex: a comma-separated
// implicit cross-join whose SECOND member (on-device GPS coordinates) was
// never examined at all.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_db.dart';

void main() {
  group('CoachDb.guardAndPrepare — allow-list', () {
    test('accepts a plain SELECT over an allowed view + auto-LIMITs', () {
      final out = CoachDb.guardAndPrepare(
          "SELECT date, value FROM v_metric WHERE key='rhr'");
      expect(out.toLowerCase(), contains('from v_metric'));
      expect(out.toLowerCase(), contains('limit 200'));
    });

    test('accepts a comma cross-join when BOTH members are allowed views', () {
      final out = CoachDb.guardAndPrepare(
          'SELECT d.date FROM v_daily d, v_metric m WHERE d.date = m.date');
      expect(out.toLowerCase(), contains('v_daily'));
    });

    test('accepts a LEFT JOIN between two views with AS aliases', () {
      final out = CoachDb.guardAndPrepare('SELECT s.type FROM v_sessions AS s '
          'LEFT JOIN v_daily AS d ON d.date = s.date');
      expect(out.toLowerCase(), contains('left join v_daily'));
    });

    test('accepts multiple CTEs', () {
      final out = CoachDb.guardAndPrepare(
          "WITH a AS (SELECT value v FROM v_metric WHERE key='strain'), "
          "b AS (SELECT value v FROM v_metric WHERE key='rhr') "
          'SELECT (SELECT AVG(v) FROM a) - (SELECT AVG(v) FROM b)');
      expect(out.toLowerCase(), startsWith('with'));
    });

    test('respects an explicit LIMIT', () {
      final out = CoachDb.guardAndPrepare('SELECT * FROM v_daily LIMIT 7');
      expect(RegExp(r'limit\s+200', caseSensitive: false).hasMatch(out), isFalse);
    });
  });

  group('CoachDb.guardAndPrepare — escape attempts', () {
    final attempts = <String, String>{
      // ── THE verified exploit: comma cross-join reaching raw GPS. ──
      'comma cross-join to workout_route (raw GPS)':
          'SELECT r.lat, r.lng, r.ts_ms FROM v_sessions s, workout_route r LIMIT 50',
      'comma cross-join to raw_archive':
          'SELECT * FROM v_metric, raw_archive',
      'comma cross-join to sleep_override':
          'SELECT * FROM v_daily d, sleep_override o',
      'comma cross-join to notif_fired':
          'SELECT * FROM v_metric, notif_fired',
      'comma cross-join to sleep_session_candidates':
          'SELECT * FROM v_metric, sleep_session_candidates',
      'comma cross-join to sqlite_schema':
          'SELECT * FROM v_metric, sqlite_schema',
      'comma cross-join across newlines':
          'SELECT *\nFROM v_sessions\n,workout_route',
      'comma cross-join in UPPERCASE':
          'SELECT * FROM V_SESSIONS S, WORKOUT_ROUTE R',
      'three-way comma list with the payload last':
          'SELECT * FROM v_daily a, v_metric b, workout_route c',
      // ── explicit joins ──
      'CROSS JOIN to workout_route':
          'SELECT * FROM v_metric CROSS JOIN workout_route',
      'INNER JOIN to decoded_onehz':
          'SELECT * FROM v_metric JOIN decoded_onehz ON 1=1',
      // ── subqueries / derived tables ──
      'subquery in FROM': 'SELECT * FROM (SELECT lat FROM workout_route)',
      'subquery in FROM over an allowed view':
          'SELECT * FROM (SELECT date FROM v_daily)',
      'correlated subquery in WHERE reaching a base table':
          'SELECT * FROM v_daily WHERE date IN (SELECT date FROM workout_route)',
      'UNION with a base-table arm':
          'SELECT date FROM v_metric UNION ALL SELECT ts_ms FROM workout_route',
      // ── CTE shadowing ──
      'CTE shadowing a real table name':
          'WITH workout_route AS (SELECT 1 x) SELECT * FROM workout_route',
      'CTE shadowing an allowed view':
          'WITH v_metric AS (SELECT 1 x) SELECT * FROM v_metric',
      // ── name mangling ──
      'schema-qualified base table': 'SELECT * FROM main.workout_route',
      'schema-qualified view': 'SELECT * FROM main.v_metric',
      'double-quoted identifier': 'SELECT * FROM "workout_route"',
      'bracket-quoted identifier': 'SELECT * FROM [workout_route]',
      'backtick-quoted identifier': 'SELECT * FROM `workout_route`',
      // ── functions / internals ──
      'table-valued function in FROM': "SELECT * FROM json_each('[1,2]')",
      'pragma_ function table': "SELECT * FROM pragma_table_info('sessions')",
      'dbstat virtual table': 'SELECT * FROM dbstat',
      'sqlite_master': 'SELECT * FROM sqlite_master',
      // ── unknown-by-default (the whole point of an allow-list) ──
      'a table that does not exist yet': 'SELECT * FROM future_secrets',
      'unknown table behind an alias': 'SELECT * FROM v_daily, future_secrets f',
      // ── statement shape ──
      'second statement': 'SELECT * FROM v_metric; DROP TABLE sessions',
      'trailing line comment': 'SELECT * FROM v_metric -- , workout_route',
      'block comment': 'SELECT * FROM v_metric /* , workout_route */',
      'unterminated string literal': "SELECT * FROM v_metric WHERE key='rhr",
      'no table reference at all': 'SELECT 1',
      'DELETE': 'DELETE FROM v_metric',
      'UPDATE': 'UPDATE v_daily SET hrv=0',
      'INSERT': 'INSERT INTO v_metric VALUES (1)',
      'PRAGMA': 'PRAGMA table_info(sessions)',
      'ATTACH': 'ATTACH DATABASE x AS y',
      'EXPLAIN prefix': 'EXPLAIN SELECT * FROM v_metric',
      // ── recursive CTE DoS: an ephemeral working table layer 2 can't see ──
      'recursive CTE touching zero real tables':
          'WITH RECURSIVE x(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM x) '
          'SELECT count(*) FROM x',
      'recursive CTE, mixed case':
          'With Recursive x(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM x) '
          'SELECT * FROM x',
      'recursive keyword after a comma in a multi-CTE list':
          'WITH a AS (SELECT 1 x), RECURSIVE b(n) AS (SELECT 1 UNION ALL '
          'SELECT n+1 FROM b) SELECT * FROM a, b',
    };

    attempts.forEach((label, sql) {
      test('rejects: $label', () {
        expect(() => CoachDb.guardAndPrepare(sql),
            throwsA(isA<SqlGuardError>()),
            reason: 'ESCAPED THE GUARD: $sql');
      });
    });
  });

  group('CoachDb reserved-name net', () {
    // These five were verified present in the live schema and absent from the
    // old deny-list — the allow-list closes them regardless, but they are
    // named here so a rename shows up as a test failure rather than silence.
    for (final t in const [
      'workout_route',
      'raw_archive',
      'notif_fired',
      'sleep_override',
      'sleep_session_candidates',
    ]) {
      test('reserves the real table $t', () {
        expect(CoachDb.reservedTableNames, contains(t));
      });
    }

    test('does not carry the stale non-existent primitive_artifacts entry', () {
      expect(CoachDb.reservedTableNames, isNot(contains('primitive_artifacts')));
    });
  });
}
