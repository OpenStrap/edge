// Re-import the journal CSV this app exported.
//
// SCOPE, and it is narrow on purpose. HAND-ENTERED data only, and of the eight
// hand-entered sets this does ONE: the journal. Phone loss and a bad restore
// are already covered — the app exports a lossless `.db`, imports raw SQLite,
// and auto-backup gzips the whole database on a schedule. A CSV round trip of
// anything DERIVED could only be a worse copy that then has to explain itself.
// What a CSV is genuinely good for is the thing a database file is bad at: you
// opened it in a spreadsheet, fixed a month of typos, and want it back.
//
// REJECT, NEVER CLAMP. A row with a date that is not a date, or a note the
// length of a novel, is REFUSED and reported by line number. A clamped value is
// a fabricated one: silently turning `2026-13-45` into a real day, or trimming
// a field to fit, writes something the user never typed into the one table
// whose entire content is what the user typed. If the validation is annoying
// for one row, that is the honest cost of not corrupting the other 300.
//
// The header signature is the one `csv_export.dart` writes for the `journal`
// set: `date,tags,note`, with tags joined by "; ".

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/day_label.dart' show dayLabelOf;
import '../data/db.dart';

/// Exactly the columns `csv_export.dart` emits for the journal set. A file
/// whose header is anything else is a different file, and guessing at column
/// meaning is how the wrong column lands in `note`.
const List<String> kJournalCsvHeader = ['date', 'tags', 'note'];

/// Caps. These REJECT a row; they never truncate one.
const int kMaxNoteChars = 20000;
const int kMaxTagChars = 64;
const int kMaxTagsPerDay = 64;

/// A row that could not be accepted, and why — by line number, so the user can
/// go and look at it.
@immutable
class RejectedRow {
  const RejectedRow(this.line, this.reason);
  final int line;
  final String reason;
  @override
  String toString() => 'line $line: $reason';
}

@immutable
class JournalCsvRow {
  const JournalCsvRow(this.date, this.tags, this.note);
  final String date; // YYYY-MM-DD
  final List<String> tags;
  final String note;
}

@immutable
class JournalCsvParse {
  const JournalCsvParse(this.rows, this.rejected);
  final List<JournalCsvRow> rows;
  final List<RejectedRow> rejected;

  bool get isEmpty => rows.isEmpty && rejected.isEmpty;
}

/// A file that is not a journal CSV at all — wrong header, or no header.
class JournalCsvFormatException implements Exception {
  const JournalCsvFormatException(this.message);
  final String message;
  @override
  String toString() => 'JournalCsvFormatException: $message';
}

/// RFC 4180 reader: fields may be quoted, quoted fields may contain commas,
/// newlines and doubled quotes. Returns one list of fields per record.
///
/// Written out rather than pulled from a package because the writing half is
/// also six lines in this repo (`csvField`), and a reader that disagrees with
/// its own writer is the actual risk here. THE one CSV reader in lib/ —
/// whoop_import reads through it too (its old line-based reader broke on
/// quoted embedded newlines).
List<List<String>> parseCsv(String text) {
  final records = <List<String>>[];
  var fields = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var sawAny = false;

  void endField() {
    fields.add(field.toString());
    field.clear();
    sawAny = true;
  }

  void endRecord() {
    endField();
    records.add(fields);
    fields = <String>[];
    sawAny = false;
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
      continue;
    }
    switch (c) {
      case '"':
        quoted = true;
        sawAny = true;
      case ',':
        endField();
      case '\r':
        break; // CRLF and lone CR both end the record on the \n / next pass
      case '\n':
        endRecord();
      default:
        field.write(c);
        sawAny = true;
    }
  }
  // A trailing newline must not manufacture an empty final record.
  if (sawAny || field.isNotEmpty || fields.isNotEmpty) endRecord();
  return records;
}

/// True for a real calendar day in `YYYY-MM-DD` — `2026-02-30` is rejected,
/// because `DateTime` would happily roll it to March and store a day the user
/// never wrote. Shared with `lab_csv_import.dart`, the other hand-entered CSV
/// importer with the same date column.
bool isValidDayLabel(String s) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return false;
  final y = int.parse(s.substring(0, 4));
  final m = int.parse(s.substring(5, 7));
  final d = int.parse(s.substring(8, 10));
  if (m < 1 || m > 12 || d < 1 || d > 31) return false;
  final dt = DateTime(y, m, d);
  return dt.year == y && dt.month == m && dt.day == d;
}

/// Parse and validate a journal CSV.
///
/// Throws [JournalCsvFormatException] when the file is not a journal export at
/// all. Individual bad ROWS do not throw — they land in
/// [JournalCsvParse.rejected] with their line number, so one typo cannot cost
/// the other 300 rows.
JournalCsvParse parseJournalCsv(String text, {DateTime? today}) {
  final records = parseCsv(text);
  if (records.isEmpty) {
    throw const JournalCsvFormatException('the file is empty');
  }
  final header = [for (final h in records.first) h.trim().toLowerCase()];
  if (!listEquals(header, kJournalCsvHeader)) {
    throw JournalCsvFormatException(
      'this is not a journal export — expected the columns '
      '${kJournalCsvHeader.join(', ')}, found ${header.join(', ')}',
    );
  }

  final now = today ?? DateTime.now();
  final todayLabel = dayLabelOf(now);

  final rows = <JournalCsvRow>[];
  final rejected = <RejectedRow>[];
  final seen = <String>{};

  for (var i = 1; i < records.length; i++) {
    final line = i + 1; // 1-based, header is line 1
    final r = records[i];
    if (r.length == 1 && r.first.trim().isEmpty) continue; // blank line
    if (r.length != kJournalCsvHeader.length) {
      rejected.add(RejectedRow(line, 'expected 3 columns, found ${r.length}'));
      continue;
    }
    final date = r[0].trim();
    if (!isValidDayLabel(date)) {
      rejected.add(RejectedRow(line, '"$date" is not a date (YYYY-MM-DD)'));
      continue;
    }
    // A journal entry is a record of a day that happened. Accepting a future
    // date would put an entry on a day the user has not lived yet, and it is
    // far more often a typo in the year than an intention.
    if (date.compareTo(todayLabel) > 0) {
      rejected.add(RejectedRow(line, '$date is in the future'));
      continue;
    }
    if (!seen.add(date)) {
      rejected.add(RejectedRow(line, '$date appears more than once'));
      continue;
    }

    // The exporter neutralises a leading =/+/-/@ with an apostrophe so a
    // spreadsheet cannot execute a note as a formula. Undo exactly that, and
    // only that: it is our own escape coming home, not user content.
    String unescape(String s) =>
        (s.startsWith("'") && s.length > 1 && RegExp(r'^[=+\-@\t\r]').hasMatch(s[1]))
            ? s.substring(1)
            : s;

    final note = unescape(r[2]);
    if (note.length > kMaxNoteChars) {
      rejected.add(RejectedRow(
        line,
        'note is ${note.length} characters (limit $kMaxNoteChars)',
      ));
      continue;
    }

    final rawTags = r[1]
        .split(';')
        .map((t) => unescape(t.trim()))
        .where((t) => t.isNotEmpty)
        .toList();
    if (rawTags.any((t) => t.length > kMaxTagChars)) {
      rejected.add(RejectedRow(line, 'a tag is longer than $kMaxTagChars characters'));
      continue;
    }
    if (rawTags.length > kMaxTagsPerDay) {
      rejected.add(RejectedRow(line, '${rawTags.length} tags (limit $kMaxTagsPerDay)'));
      continue;
    }
    // Duplicate tags within one day collapse — that is the same tag, not two.
    final tags = <String>[];
    for (final t in rawTags) {
      if (!tags.contains(t)) tags.add(t);
    }

    if (tags.isEmpty && note.trim().isEmpty) {
      rejected.add(RejectedRow(line, 'no tags and no note — nothing to import'));
      continue;
    }
    rows.add(JournalCsvRow(date, tags, note));
  }
  return JournalCsvParse(rows, rejected);
}

@immutable
class JournalImportResult {
  const JournalImportResult(this.imported, this.rejected);
  final int imported;
  final List<RejectedRow> rejected;
}

/// Read [path], validate it, and write the accepted rows.
///
/// REPLACES the journal for each date it carries — the file is the corrected
/// copy, which is the entire point of editing it in a spreadsheet. Dates the
/// file does not mention are untouched, so a partial file is a partial import
/// and never a deletion.
Future<JournalImportResult> importJournalCsvFile(
  String path, {
  DateTime? today,
}) async {
  final text = await File(path).readAsString();
  final parsed = parseJournalCsv(text, today: today);
  for (final row in parsed.rows) {
    await LocalDb.putJournal(row.date, jsonEncode(row.tags), row.note);
  }
  return JournalImportResult(parsed.rows.length, parsed.rejected);
}
