// CSV export — your data in a shape a spreadsheet can open.
//
// The whole-database export already exists and is the complete, lossless
// thing; this is the one people actually asked for, because "open it in
// Excel" and "restore it onto another phone" are different jobs and a SQLite
// file only does the second.
//
// Everything here reads through the derived views the coach already reads, so
// an export can never contain something the app itself would not show you, and
// it can never reach raw sensor rows or GPS.
//
// Absence is written as an EMPTY FIELD, never as 0. A spreadsheet cannot tell
// the difference afterwards, and a column of zeroes where a metric was simply
// not computed is the same fabrication the rest of the app refuses to make —
// except now it is in a file the user will average.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';

/// One exportable table: a filename stem, a header, and the query behind it.
class CsvExportSet {
  const CsvExportSet({
    required this.name,
    required this.title,
    required this.columns,
    required this.sql,
  });

  /// Filename stem, e.g. `daily` → `openstrap_daily_<stamp>.csv`.
  final String name;
  final String title;
  final List<String> columns;
  final String sql;
}

/// What can be exported. Ordered as the picker shows them.
const kCsvExportSets = <CsvExportSet>[
  CsvExportSet(
    name: 'daily',
    title: 'Daily metrics',
    columns: [
      'date',
      'readiness',
      'resting_hr',
      'hrv',
      'sdnn',
      'resp_rate',
      'stress',
      'strain',
      'active_calories',
      'total_calories',
      'sleep_min',
      'deep_min',
      'rem_min',
      'light_min',
      'nap_min',
      'sleep_efficiency',
      'steps',
      'worn_min',
    ],
    sql: '''
      SELECT date, readiness, resting_hr, hrv, sdnn, resp_rate, stress, strain,
             active_calories, total_calories, sleep_min, deep_min, rem_min,
             light_min, nap_min, sleep_efficiency, steps, worn_min
      FROM v_daily ORDER BY date ASC
    ''',
  ),
  CsvExportSet(
    name: 'workouts',
    title: 'Workouts',
    columns: [
      'date',
      'start_ts',
      'end_ts',
      'type',
      'status',
      'duration_min',
      'strain',
      'calories',
      'max_hr',
      'steps',
      'hrr_bpm',
      'source',
    ],
    sql: '''
      SELECT date, start_ts, end_ts, type, status, duration_min, strain,
             calories, max_hr, steps, hrr_bpm, source
      FROM v_sessions ORDER BY start_ts ASC
    ''',
  ),
  CsvExportSet(
    name: 'sleep',
    title: 'Sleep stages',
    columns: ['date', 'start_ts', 'end_ts', 'stage'],
    sql: 'SELECT date, start_ts, end_ts, stage FROM v_hypnogram '
        'ORDER BY date ASC, start_ts ASC',
  ),
  CsvExportSet(
    name: 'metrics',
    title: 'Metric history',
    columns: ['date', 'key', 'value'],
    sql: 'SELECT date, key, value FROM v_metric ORDER BY date ASC, key ASC',
  ),
  CsvExportSet(
    name: 'journal',
    title: 'Journal',
    columns: ['date', 'tags', 'note'],
    sql: "SELECT date, replace(tags_json, char(10), ' ') AS tags, note "
        'FROM journal ORDER BY date ASC',
  ),
  CsvExportSet(
    name: 'labs',
    title: 'Lab results',
    columns: ['taken_on', 'marker', 'value', 'unit', 'note'],
    sql: 'SELECT taken_on, marker, value, unit, note FROM lab_result '
        'ORDER BY taken_on ASC, marker ASC',
  ),
];

/// Characters that make Excel, Google Sheets and LibreOffice treat a cell as a
/// FORMULA rather than text.
///
/// Journal notes, journal tags and lab notes are free text the user typed, and
/// these files are handed to a share sheet — so whoever opens the spreadsheet
/// executes whatever a cell starting with one of these evaluates to. A note
/// beginning "=" is a formula in every mainstream spreadsheet, and formulas
/// can reach the network and the filesystem.
final _formulaLeaders = RegExp(r'^[=+\-@\t\r]');

/// RFC 4180 field escaping, plus formula-injection neutralisation.
///
/// Null becomes an EMPTY field rather than the string "null" or a 0 — the
/// distinction between "not measured" and "measured as nothing" has to survive
/// into the file, because nobody can recover it once it is a spreadsheet.
String csvField(Object? v) {
  if (v == null) return '';
  var s = v is double
      // Whole doubles as integers: `55.0` in a resting-HR column invites a
      // false impression of precision the metric does not have.
      ? (v == v.roundToDouble() ? v.toInt().toString() : v.toString())
      : v.toString();
  // A leading apostrophe is the convention every mainstream spreadsheet reads
  // as "this is text" — it is not displayed, and the value stays legible.
  // Applied only to strings: a negative NUMBER starts with `-` and must stay a
  // number, or every negative delta in the file becomes unusable text.
  if (v is String && _formulaLeaders.hasMatch(s)) s = "'$s";
  if (s.contains(RegExp('[",\n\r]'))) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String csvRow(Iterable<Object?> values) => values.map(csvField).join(',');

/// Render [rows] under [columns]. A column missing from a row is empty, not
/// dropped, so every line has the same field count.
String renderCsv(List<String> columns, List<Map<String, Object?>> rows) {
  final b = StringBuffer()..writeln(csvRow(columns));
  for (final r in rows) {
    b.writeln(csvRow([for (final c in columns) r[c]]));
  }
  return b.toString();
}

/// What an export produced.
class CsvExportResult {
  const CsvExportResult({required this.paths, required this.failed});

  /// Files actually written. A set with no rows writes nothing, so an empty
  /// list here genuinely means there was nothing to export.
  final List<String> paths;

  /// Sets whose query or write threw, by name. Kept separate from [paths] so
  /// the caller can tell "you have no data yet" apart from "the export broke",
  /// which the previous single-list return could not express — a total failure
  /// looked exactly like an empty database.
  final List<String> failed;

  bool get isEmpty => paths.isEmpty;
  bool get hasFailures => failed.isNotEmpty;
}

/// Subdirectory every CSV export writes into, so the previous run can be
/// cleared wholesale.
const _csvDirName = 'openstrap_csv';

/// Write the chosen [sets] to CSV files and return what landed.
///
/// The output directory is WIPED first. These files are plaintext readiness,
/// sleep, journal notes and lab results, and they were previously left in the
/// temp directory indefinitely under a unique per-run stamp, so every export
/// added another copy that nothing ever removed. One export's worth exists at
/// a time now.
Future<CsvExportResult> exportCsvFiles(
  List<CsvExportSet> sets, {
  DateTime? now,
}) async {
  final db = await LocalDb.instance;
  final root = await getTemporaryDirectory();
  final dir = Directory(p.join(root.path, _csvDirName));
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);

  final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final paths = <String>[];
  final failed = <String>[];

  for (final set in sets) {
    try {
      final rows = await db.rawQuery(set.sql);
      // No rows means no file. A header-only CSV is not "your data", and
      // emitting one made an empty database indistinguishable from a working
      // export to the caller.
      if (rows.isEmpty) continue;
      final file = File(p.join(dir.path, 'openstrap_${set.name}_$stamp.csv'));
      // utf8 with a BOM: without it Excel on Windows reads the file as the
      // local code page and mangles every non-ASCII character in a note.
      await file.writeAsBytes([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(renderCsv(set.columns, rows)),
      ]);
      paths.add(file.path);
    } catch (_) {
      // One set failing must not lose the other five — but it is reported
      // rather than swallowed, which is what the bare catch used to do.
      failed.add(set.name);
    }
  }
  return CsvExportResult(paths: paths, failed: failed);
}
