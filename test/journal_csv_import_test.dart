import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/csv_export.dart';
import 'package:openstrap_edge/import/journal_csv_import.dart';

final _today = DateTime(2026, 8, 17);

JournalCsvParse parse(String s) => parseJournalCsv(s, today: _today);

void main() {
  group('parseCsv', () {
    test('quoted fields keep commas, newlines and doubled quotes', () {
      final r = parseCsv('a,"b,c","line1\nline2","say ""hi"""\n');
      expect(r, [
        ['a', 'b,c', 'line1\nline2', 'say "hi"'],
      ]);
    });

    test('a trailing newline does not invent an empty record', () {
      expect(parseCsv('a,b\nc,d\n').length, 2);
      expect(parseCsv('a,b\nc,d').length, 2);
    });

    test('CRLF line endings read the same as LF', () {
      expect(parseCsv('a,b\r\nc,d\r\n'), [
        ['a', 'b'],
        ['c', 'd'],
      ]);
    });
  });

  group('header', () {
    test('a non-journal CSV is refused outright, not partly imported', () {
      expect(
        () => parse('date,key,value\n2026-01-01,rhr,55\n'),
        throwsA(isA<JournalCsvFormatException>()),
      );
    });

    test('an empty file is refused', () {
      expect(() => parse(''), throwsA(isA<JournalCsvFormatException>()));
    });
  });

  group('rows', () {
    test('the happy path splits tags on the exporter\'s separator', () {
      final p = parse(
        'date,tags,note\n'
        '2026-01-01,"stressed; alcohol",slept badly\n',
      );
      expect(p.rejected, isEmpty);
      expect(p.rows.single.date, '2026-01-01');
      expect(p.rows.single.tags, ['stressed', 'alcohol']);
      expect(p.rows.single.note, 'slept badly');
    });

    test('an impossible date is REJECTED, never rolled into a real one', () {
      // DateTime(2026,2,30) silently becomes 2 March. Storing that would put an
      // entry on a day the user never wrote.
      final p = parse('date,tags,note\n2026-02-30,tag,\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.line, 2);
      expect(p.rejected.single.reason, contains('not a date'));
    });

    test('a future date is rejected', () {
      final p = parse('date,tags,note\n2027-01-01,tag,\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.reason, contains('future'));
    });

    test('an over-long note is rejected, not truncated', () {
      final long = 'x' * (kMaxNoteChars + 1);
      final p = parse('date,tags,note\n2026-01-01,,"$long"\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.reason, contains('limit'));
    });

    test('one bad row does not cost the good ones', () {
      final p = parse(
        'date,tags,note\n'
        '2026-01-01,ok,first\n'
        'not-a-date,ok,second\n'
        '2026-01-03,ok,third\n',
      );
      expect(p.rows.map((r) => r.date), ['2026-01-01', '2026-01-03']);
      expect(p.rejected.single.line, 3);
    });

    test('a row with the wrong column count is rejected by line number', () {
      final p = parse('date,tags,note\n2026-01-01,ok\n');
      expect(p.rejected.single.reason, contains('found 2'));
    });

    test('a duplicate date is rejected rather than silently last-wins', () {
      final p = parse(
        'date,tags,note\n2026-01-01,a,one\n2026-01-01,b,two\n',
      );
      expect(p.rows.single.note, 'one');
      expect(p.rejected.single.reason, contains('more than once'));
    });

    test('an empty row carries nothing and is not imported as a blank day', () {
      final p = parse('date,tags,note\n2026-01-01,,\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.reason, contains('nothing to import'));
    });

    test('duplicate tags on one day collapse', () {
      final p = parse('date,tags,note\n2026-01-01,"a; a; b",\n');
      expect(p.rows.single.tags, ['a', 'b']);
    });

    test('blank lines are skipped, not rejected', () {
      final p = parse('date,tags,note\n\n2026-01-01,a,\n\n');
      expect(p.rows.length, 1);
      expect(p.rejected, isEmpty);
    });
  });

  test('a note the exporter escaped against formula injection comes home '
      'unchanged', () {
    // csvField prefixes a leading =/+/-/@ with an apostrophe. The round trip
    // has to strip exactly that and nothing else.
    const note = '=SUM(A1:A9) was on the whiteboard';
    final line = csvRow(['2026-01-01', 'work', note]);
    final p = parse('date,tags,note\n$line\n');
    expect(p.rows.single.note, note);
  });

  test('a note that legitimately begins with an apostrophe is untouched', () {
    final p = parse("date,tags,note\n2026-01-01,a,'twas fine\n");
    expect(p.rows.single.note, "'twas fine");
  });
  test('a cp1252 file out of a spreadsheet fails as a FormatException, before '
      'any write', () async {
    // The import router falls back to the lenient vendor importer only on
    // FormatException; File.readAsString would throw FileSystemException here.
    final dir = await Directory.systemTemp.createTemp('csv_cp1252_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/export.csv';
    await File(path).writeAsBytes(latin1.encode('date,tags,note\n2026-10-01,alcohol,caf\u00e9\n'));
    await expectLater(importJournalCsvFile(path), throwsA(isA<FormatException>()));
  });
}
