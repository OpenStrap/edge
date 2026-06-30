// Coach read-only SQL guard — security-critical: derived views only, no writes,
// no raw tables, single SELECT.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_db.dart';

void main() {
  group('CoachDb.guardAndPrepare', () {
    test('accepts a plain SELECT over an allowed view + auto-LIMITs', () {
      final out = CoachDb.guardAndPrepare(
          "SELECT date, value FROM v_metric WHERE key='rhr'");
      expect(out.toLowerCase(), contains('from v_metric'));
      expect(out.toLowerCase(), contains('limit 200'));
    });

    test('respects an explicit LIMIT', () {
      final out =
          CoachDb.guardAndPrepare('SELECT * FROM v_daily LIMIT 7');
      expect(RegExp(r'limit\s+200', caseSensitive: false).hasMatch(out), isFalse);
    });

    test('accepts a WITH/CTE query', () {
      final out = CoachDb.guardAndPrepare(
          "WITH x AS (SELECT value v FROM v_metric WHERE key='strain') "
          'SELECT AVG(v) FROM x');
      expect(out.toLowerCase(), startsWith('with'));
    });

    for (final bad in <String>[
      'SELECT * FROM raw_records',
      'SELECT * FROM decoded_onehz',
      'SELECT * FROM decoded_rr',
      'SELECT * FROM day_result',
      'SELECT * FROM metric_series',
      'SELECT * FROM sessions',
      'SELECT * FROM sqlite_master',
    ]) {
      test('rejects raw/base table: $bad', () {
        expect(() => CoachDb.guardAndPrepare(bad), throwsA(isA<SqlGuardError>()));
      });
    }

    for (final bad in <String>[
      'DELETE FROM v_metric',
      'UPDATE v_daily SET hrv=0',
      'DROP VIEW v_metric',
      'INSERT INTO v_metric VALUES (1)',
      'SELECT * FROM v_metric; DROP TABLE sessions',
      'SELECT * FROM v_metric -- comment',
      'PRAGMA table_info(sessions)',
      'ATTACH DATABASE x AS y',
      'SELECT * FROM main.v_metric',
      'SELECT 1',
    ]) {
      test('rejects unsafe: $bad', () {
        expect(() => CoachDb.guardAndPrepare(bad), throwsA(isA<SqlGuardError>()));
      });
    }
  });
}
