import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/csv_export.dart';
import 'package:openstrap_edge/import/lab_csv_import.dart';

final _today = DateTime(2026, 8, 17);

LabCsvParse parse(String s) => parseLabCsv(s, today: _today);

void main() {
  group('header', () {
    test('a non-labs CSV is refused outright, not partly imported', () {
      expect(
        () => parse('date,tags,note\n2026-01-01,x,y\n'),
        throwsA(isA<LabCsvFormatException>()),
      );
    });

    test('an empty file is refused', () {
      expect(() => parse(''), throwsA(isA<LabCsvFormatException>()));
    });
  });

  group('rows', () {
    test('the happy path', () {
      final p = parse(
        'taken_on,marker,value,unit,note\n'
        '2026-01-01,ferritin,42.5,ng/mL,fasted draw\n',
      );
      expect(p.rejected, isEmpty);
      expect(p.rows.single.takenOn, '2026-01-01');
      expect(p.rows.single.marker, 'ferritin');
      expect(p.rows.single.value, 42.5);
      expect(p.rows.single.unit, 'ng/mL');
      expect(p.rows.single.note, 'fasted draw');
    });

    test('an impossible date is REJECTED, never rolled into a real one', () {
      final p = parse('taken_on,marker,value,unit,note\n2026-02-30,ferritin,42,ng/mL,\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.line, 2);
      expect(p.rejected.single.reason, contains('not a date'));
    });

    test('a future date is rejected', () {
      final p = parse('taken_on,marker,value,unit,note\n2027-01-01,ferritin,42,ng/mL,\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.reason, contains('future'));
    });

    test('a non-numeric value is rejected, never coerced', () {
      final p = parse('taken_on,marker,value,unit,note\n2026-01-01,ferritin,"78 ng/mL",ng/mL,\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.reason, contains('not a number'));
    });

    test('unit whitespace is validated trimmed but stored exactly as written', () {
      final p = parse('taken_on,marker,value,unit,note\n2026-01-01,ferritin,42," ng/mL ",\n');
      expect(p.rejected, isEmpty);
      expect(p.rows.single.unit, ' ng/mL ');
    });

    test('a missing unit is rejected', () {
      final p = parse('taken_on,marker,value,unit,note\n2026-01-01,ferritin,42,,\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.reason, contains('no unit'));
    });

    test('a missing marker is rejected', () {
      final p = parse('taken_on,marker,value,unit,note\n2026-01-01,,42,ng/mL,\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.reason, contains('no marker'));
    });

    test('an over-long note is rejected, not truncated', () {
      final long = 'x' * (kMaxLabNoteChars + 1);
      final p = parse('taken_on,marker,value,unit,note\n2026-01-01,ferritin,42,ng/mL,"$long"\n');
      expect(p.rows, isEmpty);
      expect(p.rejected.single.reason, contains('limit'));
    });

    test('one bad row does not cost the good ones', () {
      final p = parse(
        'taken_on,marker,value,unit,note\n'
        '2026-01-01,ferritin,42,ng/mL,\n'
        'not-a-date,ferritin,10,ng/mL,\n'
        '2026-01-03,ferritin,44,ng/mL,\n',
      );
      expect(p.rows.map((r) => r.takenOn), ['2026-01-01', '2026-01-03']);
      expect(p.rejected.single.line, 3);
    });

    test('a row with the wrong column count is rejected by line number', () {
      final p = parse('taken_on,marker,value,unit,note\n2026-01-01,ferritin,42\n');
      expect(p.rejected.single.reason, contains('found 3'));
    });

    test('a duplicate (marker, date) is rejected rather than silently last-wins', () {
      final p = parse(
        'taken_on,marker,value,unit,note\n'
        '2026-01-01,ferritin,42,ng/mL,\n'
        '2026-01-01,ferritin,50,ng/mL,\n',
      );
      expect(p.rows.single.value, 42);
      expect(p.rejected.single.reason, contains('more than once'));
    });

    test('the same marker on different days is fine', () {
      final p = parse(
        'taken_on,marker,value,unit,note\n'
        '2026-01-01,ferritin,42,ng/mL,\n'
        '2026-02-01,ferritin,50,ng/mL,\n',
      );
      expect(p.rows.length, 2);
      expect(p.rejected, isEmpty);
    });

    test('blank lines are skipped, not rejected', () {
      final p = parse('taken_on,marker,value,unit,note\n\n2026-01-01,ferritin,42,ng/mL,\n\n');
      expect(p.rows.length, 1);
      expect(p.rejected, isEmpty);
    });
  });

  test('a note the exporter escaped against formula injection comes home unchanged', () {
    const note = '=SUM(A1:A9) was on the report';
    final line = csvRow(['2026-01-01', 'ferritin', '42', 'ng/mL', note]);
    final p = parse('taken_on,marker,value,unit,note\n$line\n');
    expect(p.rows.single.note, note);
  });

  test('a note that legitimately begins with an apostrophe is untouched', () {
    final p = parse("taken_on,marker,value,unit,note\n2026-01-01,ferritin,42,ng/mL,'twas fine\n");
    expect(p.rows.single.note, "'twas fine");
  });
}
