// CSV export — escaping, absence, and that every query actually runs.
//
// The escaping half is ordinary RFC 4180. The half worth caring about is that
// a null becomes an EMPTY field: nobody can recover "not measured" from a 0
// once the file is in a spreadsheet, and a column of zeroes where a metric was
// never computed is a fabrication the user will then average.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/csv_export.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('csvField', () {
    test('leaves a plain value alone', () {
      expect(csvField('run'), 'run');
      expect(csvField(42), '42');
    });

    test('an absent value is an empty field, not a zero and not "null"', () {
      expect(csvField(null), '');
      expect(csvField(null), isNot('0'));
      expect(csvField(null), isNot('null'));
    });

    test('a real zero still prints as zero', () {
      // Absence and zero have to stay distinguishable in the file too.
      expect(csvField(0), '0');
      expect(csvField(0.0), '0');
    });

    test('a whole double drops its decimal', () {
      // "55.0" in a resting-HR column implies a precision the metric does not
      // have.
      expect(csvField(55.0), '55');
      expect(csvField(55.5), '55.5');
    });

    test('quotes a field containing a comma, quote or newline', () {
      expect(csvField('felt rough, slept badly'), '"felt rough, slept badly"');
      expect(csvField('he said "fine"'), '"he said ""fine"""');
      expect(csvField('line one\nline two'), '"line one\nline two"');
      expect(csvField('carriage\rreturn'), '"carriage\rreturn"');
    });
  });

  group('renderCsv', () {
    test('writes a header and one line per row', () {
      final out = renderCsv(
        ['date', 'rhr'],
        [
          {'date': '2026-06-01', 'rhr': 52},
          {'date': '2026-06-02', 'rhr': 54},
        ],
      );
      expect(out.trim().split('\n'), [
        'date,rhr',
        '2026-06-01,52',
        '2026-06-02,54',
      ]);
    });

    test('a column missing from a row is empty, not dropped', () {
      // Every line must have the same field count or the file will not parse.
      final out = renderCsv(
        ['date', 'rhr', 'hrv'],
        [
          {'date': '2026-06-01', 'rhr': 52},
        ],
      );
      expect(out.trim().split('\n').last, '2026-06-01,52,');
      expect(out.trim().split('\n').last.split(',').length, 3);
    });

    test('no rows still produces a usable header', () {
      expect(renderCsv(['date', 'rhr'], const []).trim(), 'date,rhr');
    });
  });

  group('the export sets themselves', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_csv_export_test.db';
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
    });

    tearDownAll(() async => LocalDb.close());

    test('every set has a unique name and a non-empty header', () {
      final names = kCsvExportSets.map((s) => s.name).toList();
      expect(names.toSet().length, names.length);
      for (final s in kCsvExportSets) {
        expect(s.columns, isNotEmpty);
        expect(s.columns.toSet().length, s.columns.length,
            reason: '${s.name} has a duplicate column');
      }
    });

    test('every query parses and runs against the real schema', () async {
      // The failure mode this guards: a view gets renamed or loses a column,
      // and the export quietly produces a file of empty fields. SQLite throws
      // on an unknown column or table, so simply running each one is the
      // check — it is the declared-columns test below that catches a header
      // drifting away from what the query returns.
      final db = await LocalDb.instance;
      for (final s in kCsvExportSets) {
        await expectLater(
          db.rawQuery(s.sql),
          completes,
          reason: '${s.name} does not run against the current schema',
        );
      }
    });

    test('a daily row comes back under the declared column names', () async {
      final db = await LocalDb.instance;
      await db.insert('metric_series', {
        'date': '2026-06-01',
        'key': 'rhr',
        'value': 52.0,
      });
      await db.insert('metric_series', {
        'date': '2026-06-01',
        'key': 'readiness',
        'value': 71.0,
      });

      final daily = kCsvExportSets.firstWhere((s) => s.name == 'daily');
      final rows = await db.rawQuery(daily.sql);
      expect(rows, hasLength(1));
      for (final c in daily.columns) {
        expect(rows.first.containsKey(c), isTrue,
            reason: '"$c" is declared but the query does not return it');
      }
      expect(rows.first['resting_hr'], 52.0);
      expect(rows.first['readiness'], 71.0);

      // And a metric that was never computed stays absent all the way into the
      // rendered file.
      final csv = renderCsv(daily.columns, rows);
      final line = csv.trim().split('\n').last.split(',');
      expect(line[daily.columns.indexOf('hrv')], '');
      expect(line[daily.columns.indexOf('resting_hr')], '52');
    });
  });
}
