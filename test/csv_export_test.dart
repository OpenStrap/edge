// CSV export — escaping, absence, and that every query actually runs.
//
// The escaping half is ordinary RFC 4180. The half worth caring about is that
// a null becomes an EMPTY field: nobody can recover "not measured" from a 0
// once the file is in a spreadsheet, and a column of zeroes where a metric was
// never computed is a fabrication the user will then average.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/csv_export.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getLibraryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}

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

  group('formula injection', () {
    test('neutralises a text cell a spreadsheet would execute', () {
      // These files go through a share sheet, so whoever opens the spreadsheet
      // runs whatever the cell evaluates to.
      for (final leader in ['=', '+', '-', '@', '\t', '\r']) {
        final out = csvField('${leader}cmd|calc');
        expect(out.startsWith("'") || out.startsWith('"\''), isTrue,
            reason: 'a cell starting "$leader" was left executable');
      }
    });

    test('a negative number stays a number', () {
      // Only strings are prefixed. Quoting every negative delta in the file
      // would make the numeric columns unusable.
      expect(csvField(-5), '-5');
      expect(csvField(-5.5), '-5.5');
      expect(csvField(-5.0), '-5');
    });

    test('ordinary text is untouched', () {
      expect(csvField('felt rough'), 'felt rough');
      expect(csvField('2026-06-01'), '2026-06-01');
    });
  });

  group('exportCsvFiles', () {
    late Directory tmp;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('openstrap_csv_files_');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });

    tearDownAll(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('writes a BOM, skips empty sets, and reports failures', () async {
      final db = await LocalDb.instance;
      await db.insert('metric_series', {
        'date': '2026-07-01',
        'key': 'rhr',
        'value': 51.0,
      });

      const broken = CsvExportSet(
        name: 'broken',
        title: 'Broken',
        columns: ['x'],
        sql: 'SELECT x FROM a_table_that_does_not_exist',
      );
      final daily = kCsvExportSets.firstWhere((s) => s.name == 'daily');
      final labs = kCsvExportSets.firstWhere((s) => s.name == 'labs');

      // Explicit stamps throughout this group: run directories are named by
      // timestamp and pruned newest-first, so a `now()` default here would
      // outrank the fixed dates the later tests use.
      final result = await exportCsvFiles(
        [daily, labs, broken],
        now: DateTime(2026, 1, 1),
      );

      expect(result.paths, hasLength(1), reason: 'labs is empty, so no file');
      expect(result.failed, ['broken']);
      expect(result.hasFailures, isTrue);
      expect(result.isEmpty, isFalse);

      final bytes = await File(result.paths.single).readAsBytes();
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF],
          reason: 'without the BOM, Excel on Windows mangles every note');
    });

    test('an export does not delete the previous run out from under a share',
        () async {
      // exportCsvFiles returns BEFORE the caller finishes handing the files to
      // a share sheet, and the share target reads them lazily. A run that
      // wiped every earlier run would delete files a still-open share session
      // was about to read.
      final daily = kCsvExportSets.firstWhere((s) => s.name == 'daily');
      final first = await exportCsvFiles([daily], now: DateTime(2026, 7, 1));
      final second = await exportCsvFiles([daily], now: DateTime(2026, 7, 2));

      expect(File(first.paths.single).existsSync(), isTrue,
          reason: 'the previous run must survive the next one starting');
      expect(File(second.paths.single).existsSync(), isTrue);
    });

    test('copies stay bounded rather than accumulating forever', () async {
      // The other half of the trade: these are plaintext health files, so old
      // runs are still cleaned up — just not the one that may still be in use.
      final daily = kCsvExportSets.firstWhere((s) => s.name == 'daily');
      final oldest = await exportCsvFiles([daily], now: DateTime(2026, 8, 1));
      await exportCsvFiles([daily], now: DateTime(2026, 8, 2));
      final newest = await exportCsvFiles([daily], now: DateTime(2026, 8, 3));

      expect(File(oldest.paths.single).existsSync(), isFalse);
      expect(File(newest.paths.single).existsSync(), isTrue);

      final parent = Directory(p.dirname(p.dirname(newest.paths.single)));
      expect(parent.listSync().whereType<Directory>(), hasLength(2));
    });

    test('nothing to export is not the same as everything failing', () async {
      const broken = CsvExportSet(
        name: 'broken',
        title: 'Broken',
        columns: ['x'],
        sql: 'SELECT x FROM nope',
      );
      final labs = kCsvExportSets.firstWhere((s) => s.name == 'labs');

      final empty = await exportCsvFiles([labs], now: DateTime(2026, 9, 1));
      expect(empty.isEmpty, isTrue);
      expect(empty.hasFailures, isFalse);

      final failed = await exportCsvFiles([broken], now: DateTime(2026, 9, 2));
      expect(failed.isEmpty, isTrue);
      expect(failed.hasFailures, isTrue);
    });
  });
}
