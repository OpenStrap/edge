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

import '../ui2/activity/catalogue.dart' show exerciseByKey;
import 'db.dart';
import 'series_codec.dart';

/// One exportable table: a filename stem, a header, and the query behind it.
class CsvExportSet {
  const CsvExportSet({
    required this.name,
    required this.title,
    required this.columns,
    required this.sql,
    this.addColumns,
  });

  /// Filename stem, e.g. `daily` → `openstrap_daily_<stamp>.csv`.
  final String name;
  final String title;
  final List<String> columns;
  final String sql;

  /// Values for columns the SQL can't produce, e.g. a label held in Dart.
  final Map<String, Object?> Function(Map<String, Object?> row)? addColumns;
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
      'source',
      'algo_version',
    ],
    // PROVENANCE, on every row. `v_daily` is a pure pivot over `metric_series`
    // with no source and no version, so an imported vendor snapshot day and a
    // 1 Hz-derived day came out of here BYTE-IDENTICAL — a file presenting
    // another vendor's derived score beside your band's measured one,
    // unlabelled. `algo_version` rides along for the same reason: someone
    // comparing two exports six months apart can see the numbers moved because
    // the maths changed, not because they did.
    //
    // LEFT JOIN, not a view change: `v_daily` is in the coach's allow-list and
    // widening it changes what the coach sees. A day with no stamp writes two
    // EMPTY cells — unknown provenance, never a claim.
    sql: '''
      SELECT d.date, d.readiness, d.resting_hr, d.hrv, d.sdnn, d.resp_rate,
             d.stress, d.strain, d.active_calories, d.total_calories,
             d.sleep_min, d.deep_min, d.rem_min, d.light_min, d.nap_min,
             d.sleep_efficiency, d.steps, d.worn_min,
             v.source, v.algo_version
      FROM v_daily d
      LEFT JOIN metric_series_version v ON v.date = d.date
      ORDER BY d.date ASC
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
    // Tags as a readable list, not the storage document: this used to hand the
    // cell `["stressed","alcohol"]`, brackets and quotes and all, in a file
    // whose whole job is being openable in a spreadsheet. json_each falls over
    // on a malformed doc, so an unparseable one is passed through verbatim
    // rather than costing the row.
    sql: """
      SELECT date,
             CASE WHEN json_valid(tags_json)
                  THEN COALESCE((SELECT group_concat(value, '; ')
                                 FROM json_each(journal.tags_json)), '')
                  ELSE replace(tags_json, char(10), ' ') END AS tags,
             note
      FROM journal ORDER BY date ASC
    """,
  ),
  CsvExportSet(
    name: 'labs',
    title: 'Lab results',
    columns: ['taken_on', 'marker', 'value', 'unit', 'note'],
    sql: 'SELECT taken_on, marker, value, unit, note FROM lab_result '
        'ORDER BY taken_on ASC, marker ASC',
  ),
  // ── everything below is data the user TYPED IN ──────────────────────────────
  //
  // The six sets above are all derived, so the export used to be able to hand
  // back everything the band measured and nothing the user had written down —
  // every meal, every dose, every habit, every set, every breathing session
  // and the cycle log came out only as a SQLite file, which is not a format
  // anybody can read. Hand-entered data is the data that is hardest to
  // reproduce and that no re-derive can ever rebuild.
  CsvExportSet(
    name: 'nutrition',
    title: 'Nutrition',
    columns: [
      'date',
      'at_ts',
      'meal',
      'label',
      'quantity',
      'unit',
      'kcal',
      'protein_g',
      'carbs_g',
      'fat_g',
      'fibre_g',
      'sugar_g',
      'sat_fat_g',
      'sodium_mg',
      'source',
    ],
    sql: '''
      SELECT date, at_ts, meal, label, quantity, unit, kcal, protein_g,
             carbs_g, fat_g, fibre_g, sugar_g, sat_fat_g, sodium_mg, source
      FROM food_entry ORDER BY date ASC, at_ts ASC
    ''',
  ),
  CsvExportSet(
    name: 'medication',
    title: 'Medication',
    // Joined to the definition so the file names the medication rather than
    // an opaque key — the export has to be readable without the app.
    columns: [
      'date',
      'medication',
      'kind',
      'slot_min',
      'taken_ts',
      'skipped',
      'dose_value',
      'dose_unit',
      'note',
    ],
    sql: '''
      SELECT d.date, COALESCE(m.label, d.med_key) AS medication,
             COALESCE(m.kind, '') AS kind, d.slot_min, d.taken_ts, d.skipped,
             COALESCE(d.dose_value, m.dose_value) AS dose_value,
             COALESCE(m.dose_unit, '') AS dose_unit, d.note
      FROM med_dose d LEFT JOIN med_def m ON m.key = d.med_key
      ORDER BY d.date ASC, d.slot_min ASC
    ''',
  ),
  CsvExportSet(
    name: 'habits',
    title: 'Habits',
    columns: ['date', 'field', 'label', 'value', 'unit', 'at_min'],
    // Built-in fields live in code, not journal_field_def, so the label and
    // unit are empty for those — the `field` key still identifies them.
    sql: '''
      SELECT j.date, j.field, COALESCE(f.label, '') AS label, j.value,
             COALESCE(f.unit, '') AS unit, j.at_min
      FROM journal_metric j LEFT JOIN journal_field_def f ON f.key = j.field
      ORDER BY j.date ASC, j.field ASC
    ''',
  ),
  CsvExportSet(
    name: 'strength',
    title: 'Strength sets',
    columns: [
      'at_ts',
      'session_id',
      'exercise',
      'exercise_name',
      'set_index',
      'reps',
      'load_kg',
      'rpe',
      'hold_sec',
      'rest_sec',
      'note',
    ],
    // Exercises live as a Dart constant (lib/ui2/activity/catalogue.dart), not
    // in `exercise_def` — nothing inserts into that table — so `exercise` is
    // the storage key and the name is filled in from the catalogue. wger lifts
    // are keyed `wger:<uuid>`, which nobody can read back without it.
    // A private session is out of v_sessions, so its sets stay out too.
    addColumns: _exerciseName,
    sql: '''
      SELECT s.at_ts, s.session_id, s.exercise_key AS exercise,
             s.set_index, s.reps, s.load_kg, s.rpe, s.hold_sec, s.rest_sec, s.note
      FROM strength_set s
      WHERE s.session_id NOT IN (SELECT id FROM sessions WHERE private = 1)
      ORDER BY s.at_ts ASC, s.session_id ASC, s.seq ASC
    ''',
  ),
  CsvExportSet(
    name: 'breathing',
    title: 'Breathing sessions',
    columns: [
      'started_at',
      'ended_at',
      'pattern',
      'seconds',
      'coherence',
      'pre_rmssd',
      'post_rmssd',
    ],
    sql:
        'SELECT started_at, ended_at, pattern, seconds, coherence, '
        'pre_rmssd, post_rmssd FROM breathing_session ORDER BY started_at ASC',
  ),
  CsvExportSet(
    name: 'cycle',
    title: 'Cycle log',
    columns: ['date', 'kind', 'note', 'symptoms'],
    // DRIVEN OFF BOTH TABLES. cycle_log's `date` PK is a period-START marker
    // and cycle_symptom is wholly independent, so a LEFT JOIN off cycle_log
    // dropped every symptom-only day from the file entirely — and deleting a
    // mistakenly-logged start took that date's symptoms out of the export with
    // it. Union of dates, then join each side on.
    sql: '''
      SELECT d.date,
             COALESCE(c.kind, '') AS kind,
             COALESCE(NULLIF(c.note, ''), s.note, '') AS note,
             COALESCE(s.symptoms_json, '') AS symptoms
      FROM (SELECT date FROM cycle_log UNION SELECT date FROM cycle_symptom) d
      LEFT JOIN cycle_log c ON c.date = d.date
      LEFT JOIN cycle_symptom s ON s.date = d.date
      ORDER BY d.date ASC
    ''',
  ),
];

Map<String, Object?> _exerciseName(Map<String, Object?> row) => {
  'exercise_name': exerciseByKey(row['exercise'] as String)?.label,
};

/// What CSV deliberately does NOT carry, and why. Shown to the user on the
/// export screen, because "your data" with a silent gap in it is the same
/// dishonesty as a fabricated number.
///
/// All of it IS in the whole-database export — a `.db` is lossless by
/// construction, which is exactly what makes it the wrong format for reading
/// and the right one for keeping.
const kCsvExportExclusions = <String>[
  'Raw 1 Hz sensor rows and beat-to-beat intervals — millions of rows, and a '
      'spreadsheet cannot open them',
  'Undecodable band frames',
  'GPS route points',
  'Sync state and rolling baselines — internal bookkeeping, not measurements',
  'Your profile, preferences and API key — settings, not data',
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

/// Parent directory for CSV exports. Each run gets its own subdirectory under
/// it, named by timestamp.
const _csvDirName = 'openstrap_csv';

/// How many runs survive a cleanup.
///
/// Not one. `exportCsvFiles` returns before the caller has finished handing
/// the files to a share sheet, and the share target reads them lazily — so
/// wiping every earlier run at the start of a new one would delete files out
/// from under a share session that was still open. Keeping the previous run
/// as well means a second export cannot destroy the first one's files, while
/// still bounding how many copies of plaintext health data survive on disk.
const _csvRunsKept = 2;

/// Write the chosen [sets] to CSV files and return what landed.
///
/// The new run gets its own directory and older runs are then pruned to
/// [_csvRunsKept] — so THIS run's files and the previous run's survive, and
/// nothing older does. These files are plaintext readiness, sleep, journal
/// notes and lab results, and they were previously left in the temp directory
/// indefinitely under a unique per-run stamp, so every export added another
/// copy that nothing ever removed. Two runs is the bound, not one: see
/// [_csvRunsKept] for why an in-flight share sheet needs the previous run.
Future<CsvExportResult> exportCsvFiles(
  List<CsvExportSet> sets, {
  DateTime? now,
}) async {
  final db = await LocalDb.instance;
  final (dir, stamp) = await _newRunDir(now);
  final paths = <String>[];
  final failed = <String>[];

  for (final set in sets) {
    try {
      final add = set.addColumns;
      final rows = [
        for (final r in await db.rawQuery(set.sql))
          add == null ? r : {...r, ...add(r)},
      ];
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

Future<(Directory, int)> _newRunDir(DateTime? now) async {
  final root = await getTemporaryDirectory();
  final parent = Directory(p.join(root.path, _csvDirName));
  await parent.create(recursive: true);
  final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final dir = Directory(p.join(parent.path, '$stamp'));
  await dir.create(recursive: true);
  await _pruneOldRuns(parent, keep: _csvRunsKept);
  return (dir, stamp);
}

const kHeartRateCsvColumns = ['timestamp', 'local_time', 'bpm', 'source'];

/// One CSV row per minute of a day's stored heart-rate curve.
///
/// The curve is the per-minute MEAN of the band's 1 Hz readings, written when
/// the day is derived and kept for as long as the day is — unlike the 1 Hz
/// rows themselves, which are pruned a few days behind the newest sync. So
/// this is every minute the app still knows, at the resolution it still has.
/// [source] is the day's provenance stamp, empty when unknown (never guessed).
List<Map<String, Object?>> heartRateMinuteRows(
    List<Object?> curve, String? source) {
  String two(int v) => v.toString().padLeft(2, '0');
  return [
    for (final e in curve)
      if (e is Map && e['t'] is num && e['v'] is num && (e['v'] as num) > 0)
        () {
          final t = (e['t'] as num).toInt();
          final d = DateTime.fromMillisecondsSinceEpoch(t * 1000);
          return <String, Object?>{
            'timestamp': t,
            'local_time': '${d.year}-${two(d.month)}-${two(d.day)} '
                '${two(d.hour)}:${two(d.minute)}',
            'bpm': e['v'],
            'source': source,
          };
        }(),
  ];
}

/// Write minute-by-minute heart rate for derived days [from]..[to]
/// (inclusive, `yyyy-MM-dd`) to one CSV. Null when there was nothing in the
/// range — no header-only file, same rule as [exportCsvFiles].
Future<String?> exportHeartRateCsv(String from, String to,
    {DateTime? now}) async {
  final db = await LocalDb.instance;
  final days = [
    for (final d in await LocalDb.availableDayIds())
      if (d.compareTo(from) >= 0 && d.compareTo(to) <= 0) d,
  ]..sort();
  final source = {
    for (final r in await db.rawQuery(
        'SELECT date, source FROM metric_series_version '
        'WHERE date >= ? AND date <= ?',
        [from, to]))
      r['date'] as String: r['source'] as String?,
  };
  final rows = <Map<String, Object?>>[];
  for (final day in days) {
    final b = SeriesCodec.decodePayloadJson(
        (await LocalDb.dayResult(day))?['payload_json']);
    final curve = (b?['series'] as Map?)?['hr_curve'];
    if (curve is List) rows.addAll(heartRateMinuteRows(curve, source[day]));
  }
  if (rows.isEmpty) return null;
  final (dir, stamp) = await _newRunDir(now);
  final file =
      File(p.join(dir.path, 'openstrap_heart_rate_${from}_${to}_$stamp.csv'));
  await file.writeAsBytes([
    0xEF,
    0xBB,
    0xBF,
    ...utf8.encode(renderCsv(kHeartRateCsvColumns, rows)),
  ]);
  return file.path;
}

/// Delete all but the [keep] newest run directories under [parent].
///
/// Run directories are named by millisecond timestamp, so a lexicographic sort
/// over equal-length names is chronological. Anything that is not a plausible
/// run directory is left alone rather than deleted — this runs inside the
/// app's temp directory and must never reach beyond its own folder.
Future<void> _pruneOldRuns(Directory parent, {required int keep}) async {
  try {
    final runs =
        parent
            .listSync()
            .whereType<Directory>()
            .where((d) => int.tryParse(p.basename(d.path)) != null)
            .toList()
          ..sort((a, b) {
            final ai = int.parse(p.basename(a.path));
            final bi = int.parse(p.basename(b.path));
            return bi.compareTo(ai);
          });
    for (final old in runs.skip(keep)) {
      await old.delete(recursive: true);
    }
  } catch (_) {
    // Housekeeping only — a failure here must never fail the export itself.
  }
}
