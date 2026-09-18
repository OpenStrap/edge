// Re-import the lab-results CSV this app exported.
//
// Same job as `journal_csv_import.dart`, one field down the list of the eight
// hand-entered sets `csv_export.dart` names in its own header comment: a blood
// panel typed in by hand, corrected in a spreadsheet, and brought back.
//
// REJECT, NEVER CLAMP — same rule as the journal importer, for the same
// reason. A value with a typo in the marker column is refused by line number,
// never guessed at.
//
// The header signature is the one `csv_export.dart` writes for the `labs`
// set: `taken_on,marker,value,unit,note`.
//
// `unit` is stored exactly as the row says, never re-looked-up from the
// catalogue — `db.dart`'s own comment on `lab_result` explains why: a value
// keeps the unit it was entered under even if a later release changes the
// marker's canonical unit, and silently reinterpreting one unit as another is
// a fabrication.

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/db.dart';
import '../data/lab_catalogue.dart';
import 'journal_csv_import.dart'
    show RejectedRow, isValidDayLabel, parseCsv;

/// Exactly the columns `csv_export.dart` emits for the labs set.
const List<String> kLabCsvHeader = ['taken_on', 'marker', 'value', 'unit', 'note'];

const int kMaxLabNoteChars = 20000;
const int kMaxLabUnitChars = 32;

@immutable
class LabCsvRow {
  const LabCsvRow(this.line, this.takenOn, this.marker, this.value, this.unit, this.note);
  /// 1-based source line, kept so a rejection found later (the marker-key
  /// check, which needs a DB read [parseLabCsv] does not do) can still point
  /// at the right row.
  final int line;
  final String takenOn; // YYYY-MM-DD
  final String marker;
  final double value;
  final String unit;
  final String note;
}

@immutable
class LabCsvParse {
  const LabCsvParse(this.rows, this.rejected);
  final List<LabCsvRow> rows;
  final List<RejectedRow> rejected;

  bool get isEmpty => rows.isEmpty && rejected.isEmpty;
}

/// A file that is not a lab-results CSV at all — wrong header, or no header.
class LabCsvFormatException implements Exception {
  const LabCsvFormatException(this.message);
  final String message;
  @override
  String toString() => 'LabCsvFormatException: $message';
}

/// Parse and validate a lab-results CSV. Marker keys are NOT checked against
/// the catalogue here — that needs the custom-marker table, which is a DB
/// read — so an unknown marker surfaces from [importLabCsvFile], not here.
///
/// Throws [LabCsvFormatException] when the file is not a labs export at all.
/// Individual bad rows land in [LabCsvParse.rejected] with their line number.
LabCsvParse parseLabCsv(String text, {DateTime? today}) {
  final records = parseCsv(text);
  if (records.isEmpty) {
    throw const LabCsvFormatException('the file is empty');
  }
  final header = [for (final h in records.first) h.trim().toLowerCase()];
  if (!listEquals(header, kLabCsvHeader)) {
    throw LabCsvFormatException(
      'this is not a lab-results export — expected the columns '
      '${kLabCsvHeader.join(', ')}, found ${header.join(', ')}',
    );
  }

  final now = today ?? DateTime.now();
  final todayLabel = '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';

  final rows = <LabCsvRow>[];
  final rejected = <RejectedRow>[];
  final seen = <String>{}; // 'marker|taken_on'

  for (var i = 1; i < records.length; i++) {
    final line = i + 1; // 1-based, header is line 1
    final r = records[i];
    if (r.length == 1 && r.first.trim().isEmpty) continue; // blank line
    if (r.length != kLabCsvHeader.length) {
      rejected.add(RejectedRow(line, 'expected 5 columns, found ${r.length}'));
      continue;
    }
    final takenOn = r[0].trim();
    if (!isValidDayLabel(takenOn)) {
      rejected.add(RejectedRow(line, '"$takenOn" is not a date (YYYY-MM-DD)'));
      continue;
    }
    // A draw dated after today is a typo far more often than a real future
    // blood test.
    if (takenOn.compareTo(todayLabel) > 0) {
      rejected.add(RejectedRow(line, '$takenOn is in the future'));
      continue;
    }

    final marker = r[1].trim();
    if (marker.isEmpty) {
      rejected.add(RejectedRow(line, 'no marker'));
      continue;
    }

    final value = double.tryParse(r[2].trim());
    if (value == null || !value.isFinite) {
      rejected.add(RejectedRow(line, '"${r[2]}" is not a number'));
      continue;
    }

    final unit = r[3].trim();
    if (unit.isEmpty) {
      rejected.add(RejectedRow(line, 'no unit'));
      continue;
    }
    if (unit.length > kMaxLabUnitChars) {
      rejected.add(RejectedRow(line, 'unit is longer than $kMaxLabUnitChars characters'));
      continue;
    }

    // The exporter neutralises a leading =/+/-/@ with an apostrophe so a
    // spreadsheet cannot execute a note as a formula. Undo exactly that.
    String unescape(String s) =>
        (s.startsWith("'") && s.length > 1 && RegExp(r'^[=+\-@\t\r]').hasMatch(s[1]))
            ? s.substring(1)
            : s;
    final note = unescape(r[4]);
    if (note.length > kMaxLabNoteChars) {
      rejected.add(RejectedRow(line, 'note is ${note.length} characters (limit $kMaxLabNoteChars)'));
      continue;
    }

    final key = '$marker|$takenOn';
    if (!seen.add(key)) {
      rejected.add(RejectedRow(line, '$marker on $takenOn appears more than once'));
      continue;
    }

    rows.add(LabCsvRow(line, takenOn, marker, value, unit, note));
  }
  return LabCsvParse(rows, rejected);
}

@immutable
class LabImportResult {
  const LabImportResult(this.imported, this.rejected);
  final int imported;
  final List<RejectedRow> rejected;
}

/// Read [path], validate it, and write the accepted rows.
///
/// A marker key not found in the built-in catalogue OR this device's custom
/// markers is REJECTED, not silently created — a typo'd key would otherwise
/// spawn a new marker with no label, no unit, no reference range, on the one
/// table nothing else here fabricates. REPLACES the result for each
/// (marker, taken_on) pair the file carries, matching `putLabResult`'s own
/// upsert semantics.
Future<LabImportResult> importLabCsvFile(String path, {DateTime? today}) async {
  final text = await File(path).readAsString();
  final parsed = parseLabCsv(text, today: today);
  final customKeys = {for (final d in await LocalDb.labMarkerDefs()) d['key'].toString()};

  var imported = 0;
  final rejected = [...parsed.rejected];
  for (final row in parsed.rows) {
    if (!kLabMarkersByKey.containsKey(row.marker) && !customKeys.contains(row.marker)) {
      rejected.add(RejectedRow(row.line, '"${row.marker}" is not a known marker key'));
      continue;
    }
    await LocalDb.putLabResult(
      marker: row.marker,
      takenOn: row.takenOn,
      value: row.value,
      unit: row.unit,
      note: row.note,
    );
    imported++;
  }
  return LabImportResult(imported, rejected);
}
