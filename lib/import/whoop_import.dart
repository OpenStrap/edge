// whoop_import.dart — import a WHOOP data export (BETA).
//
// WHOOP's official "My Data" export is a set of DERIVED CSVs — there is no raw
// 1 Hz — so (unlike the NOOP raw import) this maps to derived-snapshot days, the
// same shape as the cloud import. We recognise the file by its header columns:
//   • physiological_cycles.csv / sleeps.csv → per-day recovery / sleep / strain
//   • workouts.csv → sessions
//
// Robust to column add/reorder: every field is read BY HEADER NAME (with a few
// known aliases), never by fixed position. Lenient timestamp parsing. Days are
// labelled by the WAKE-onset local date (a night's recovery attributes to the day
// you wake into — our day model). Marked BETA; values are WHOOP's own numbers.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../compute/derivation_engine.dart' show kAlgoVersion, DerivationEngine;
import '../compute/profile.dart';
import '../compute/substrate.dart' show localDateLabel;
import '../data/db.dart';
import '../health/health_export.dart';
import 'import_container.dart';
import 'journal_csv_import.dart' show parseCsv;

class WhoopImportResult {
  final int days;
  final int workouts;

  /// Days present in the export that were NOT written because the device
  /// already holds a REAL (1 Hz-derived) day for that date. Vendor snapshots
  /// never replace measured data — see [WhoopImporter._buildAndWriteDay].
  final int skippedExistingDays;
  WhoopImportResult(this.days, this.workouts, [this.skippedExistingDays = 0]);
}

/// One CSV row, addressed BY HEADER NAME. Also exposes WHICH header matched, so
/// unit-bearing columns ("… (cal)" vs "… (kJ)") can be interpreted from their
/// declared unit instead of guessed from the magnitude of the number.
class _Row {
  final Map<String, int> col;
  final List<String> f;
  const _Row(this.col, this.f);

  String get(List<String> names) => _pick(names).$2;

  /// The header name that matched (lower-cased), or '' if none did.
  String header(List<String> names) => _pick(names).$1;

  (String, String) _pick(List<String> names) {
    for (final n in names) {
      final i = col[n];
      if (i != null && i < f.length) return (n, f[i].trim());
    }
    return ('', '');
  }
}

const String _kDeletedWorkoutsPref = 'whoop_import_deleted_workouts';

class WhoopImporter {
  /// Every imported workout's session id starts with this, followed by its
  /// start epoch — the same CSV row always lands on the same id. A row first
  /// imported before the export's zone column was honoured keeps the id of
  /// the instant it was read at then, after its window is corrected.
  static const String workoutIdPrefix = 'whoop_';

  /// Imported workout ids the user has DELETED here. The export still has
  /// them, so without this list the next import would bring each one back.
  static Future<Set<String>> deletedWorkoutIds() async {
    final prefs = await SharedPreferences.getInstance();
    return {...(prefs.getStringList(_kDeletedWorkoutsPref) ?? const [])};
  }

  // Serialized: each write replaces the whole list, so two overlapping calls
  // would each drop the other's id.
  static Future<void> _deletedWrites = Future.value();

  static Future<void> rememberDeletedWorkout(String id) => _deletedWrites =
      _deletedWrites.catchError((_) {}).then((_) async {
        final prefs = await SharedPreferences.getInstance();
        final set = await deletedWorkoutIds();
        if (set.contains(id)) return;
        await prefs.setStringList(_kDeletedWorkoutsPref, [...set, id]);
      });

  /// Column aliases for the energy field. The unit is read from whichever of
  /// these actually matched — never inferred from the value (see [_kcal]).
  static const List<String> _energyCols = [
    'energy burned (cal)',
    'energy burned (kcal)',
    'energy burned (kilocalories)',
    'energy burned (kj)',
    'energy burned (kilojoules)',
    'energy burned (kilojoule)',
    'energy burned',
  ];

  /// Import one or more WHOOP export CSVs. Derived snapshots only. Pass [engine]
  /// + [profile] to run the cross-day rollup / baseline refresh once at the end.
  static Future<WhoopImportResult> importFiles(
    List<String> paths, {
    DerivationEngine? engine,
    Profile? profile,
    void Function(int done)? onProgress,
  }) async {
    var days = 0, workouts = 0, skipped = 0;
    // Day labels that still have raw 1 Hz substrate on device. An imported
    // snapshot for one of these must NEVER be finalized — finalizing locks the
    // day out of DerivationEngine forever, so the real signal could never
    // replace WHOOP's numbers.
    Set<String> rawDays;
    try {
      rawDays = (await LocalDb.decodedRecTsMaxByDay()).keys.toSet();
    } catch (_) {
      rawDays = const {};
    }
    // WHOOP's own "My Data" export arrives as a ZIP of CSVs, and users pick the
    // ZIP — its bytes hit `utf8.decoder` and threw "Unexpected extension byte
    // (at offset 10)" (issue #199). Unwrap it first; anything we can't parse
    // throws an actionable [ImportFormatException] instead.
    final resolved = await resolveImportCsvPaths(paths, flavor: 'WHOOP');
    try {
      return await _importResolvedCsvs(
        resolved.paths,
        rawDays: rawDays,
        engine: engine,
        profile: profile,
        onProgress: onProgress,
        days: days,
        workouts: workouts,
        skipped: skipped,
      );
    } finally {
      // Anything unpacked from an archive is ours to clean up, success or not.
      await resolved.dispose();
    }
  }

  static Future<WhoopImportResult> _importResolvedCsvs(
    List<String> csvPaths, {
    required Set<String> rawDays,
    DerivationEngine? engine,
    Profile? profile,
    void Function(int done)? onProgress,
    required int days,
    required int workouts,
    required int skipped,
  }) async {
    var recognisedFiles = 0;
    final headersSeen = <String>[];
    // A WHOOP export splits one day across multiple _Kind.day files
    // (physiological_cycles.csv → recovery/RHR/RMSSD/strain, sleeps.csv →
    // sleep fields) — accumulate per date across ALL files first, so a later
    // file's row (whose columns don't include the earlier file's fields)
    // can't null out what the earlier file already contributed. Writing per
    // row instead of per date used to whole-row-replace day_result / REPLACE
    // every metric_series key including nulls, silently erasing the first
    // file's data. Merge is "new non-null value wins, else keep prior" so the
    // outcome doesn't depend on file order.
    final pendingDays = <String, Map<String, dynamic>>{};
    Set<String> deletedWorkouts;
    try {
      deletedWorkouts = await deletedWorkoutIds();
    } catch (_) {
      deletedWorkouts = const {};
    }
    for (final path in csvPaths) {
      final rows = await _readCsv(path);
      if (rows.isEmpty) continue;
      final header = rows.first;
      final col = <String, int>{
        for (var i = 0; i < header.length; i++) header[i].trim().toLowerCase(): i
      };
      final kind = _classify(col);
      if (kind == _Kind.unknown) {
        headersSeen.add(header.take(6).join(', '));
        continue;
      }
      // Count the file as recognised on its HEADER, before the empty check
      // below: an export whose files carry the right columns but no rows (a
      // week with no workouts, say) is a valid export we simply have nothing
      // to import from. Skipping it first made it indistinguishable from a
      // file we don't understand, and the caller then told the user to
      // re-download in English.
      recognisedFiles++;
      if (rows.length < 2) continue;
      for (var r = 1; r < rows.length; r++) {
        final f = rows[r];
        if (f.isEmpty) continue;
        final row = _Row(col, f);

        if (kind == _Kind.workout) {
          if (await _writeWorkout(row, deletedWorkouts)) workouts++;
        } else if (kind == _Kind.day) {
          final extracted = _extractDayFields(row);
          if (extracted == null) continue;
          final (date, fields) = extracted;
          final merged = pendingDays.putIfAbsent(date, () => {});
          for (final e in fields.entries) {
            merged.update(e.key, (old) => e.value ?? old, ifAbsent: () => e.value);
          }
        }
      }
    }
    for (final entry in pendingDays.entries) {
      switch (await _buildAndWriteDay(entry.key, entry.value, rawDays)) {
        case _DayWrite.written:
          days++;
          onProgress?.call(days);
        case _DayWrite.keptExisting:
          skipped++;
        case _DayWrite.unusable:
          break;
      }
    }
    // Nothing recognised is a failure, not a "0 days" success. The columns are
    // matched against exact ENGLISH header names, so a WHOOP export downloaded
    // in another language classifies as unknown for every file and used to end
    // silently at "WHOOP: imported 0 days" — reported as the app being broken.
    if (recognisedFiles == 0) {
      throw ImportFormatException(
        csvPaths.isEmpty
            ? 'No CSV files were found to import.'
            : 'None of those files look like a WHOOP export. We match the '
                  'English column names WHOOP writes (e.g. "Recovery score %", '
                  '"Activity name", "Sleep onset"), so an export downloaded in '
                  'another language will not be recognised — re-download it '
                  'with WHOOP set to English.'
                  '${headersSeen.isEmpty ? '' : ' Columns found: ${headersSeen.first}.'}',
      );
    }

    if (engine != null && profile != null) {
      await engine.finalizeImport(profile);
    }
    return WhoopImportResult(days, workouts, skipped);
  }

  // ── per-row writers ──────────────────────────────────────────────────────────

  // a blank/0/garbage cell is no reading, not a 0% night.
  static num? _pct(num? v, num lo) => v != null && v >= lo && v <= 100 ? v : null;

  /// Pure extraction: (date, raw field map) from one CSV row, or null when
  /// the row has no parseable anchor timestamp. No DB access — callers
  /// accumulate these across every file in the import before writing, so a
  /// later file's row (missing the earlier file's columns) can't null out
  /// what the earlier file already contributed for the same date.
  static (String, Map<String, dynamic>)? _extractDayFields(_Row row) {
    String get(List<String> names) => row.get(names);
    // sleeps.csv lists naps as their own rows, filed under the same date as
    // the night that ended that morning. A nap is not the day's sleep.
    if (get(['nap']).toLowerCase() == 'true') return null;
    final zone = get(_zoneCols);
    final wakeTs = parseExportTs(
        get(['wake onset', 'sleep onset', 'cycle start time']), zone: zone);
    final cycleStart =
        parseExportTs(get(['cycle start time', 'sleep onset']), zone: zone);
    final anchor = wakeTs ?? cycleStart;
    if (anchor == null) return null;
    // File the day under the date the user lived it in the export's own zone,
    // not under whatever zone the phone is in at import time: a night slept in
    // Paris and imported in Los Angeles still belongs to the Paris morning.
    final off = zoneOffset(zone);
    final date = off == null ? localDateLabel(anchor) : _wallDateLabel(anchor, off);

    num? n(List<String> names) => double.tryParse(get(names));
    return (date, {
      'recovery': n(['recovery score %', 'recovery score']),
      'rhr': n(['resting heart rate (bpm)', 'resting heart rate']),
      'rmssd': n(['heart rate variability (ms)', 'heart rate variability (rmssd) (ms)']),
      'strain': n(['day strain', 'strain']),
      // The cycle's 'Energy burned' is WHOOP's whole-day expenditure, resting
      // metabolism included. That is `calories_total` (TDEE) here, not
      // `calories` (active energy over the wake span): filed as active, Health
      // export wrote the full ~2,500 kcal as ACTIVE_ENERGY_BURNED every day.
      // WHOOP's export has no active/basal split, so active stays absent.
      'caloriesTotal': _kcal(get(_energyCols), row.header(_energyCols)),
      'resp': n(['respiratory rate (rpm)', 'respiratory rate']),
      'spo2': _pct(n(['blood oxygen %', 'blood oxygen']), 70),
      'asleepMin': n(['asleep duration (min)', 'asleep duration (minutes)']),
      'inBedMin': n(['in bed duration (min)', 'in bed duration (minutes)']),
      'lightMin': n(['light sleep duration (min)', 'light sleep duration (minutes)']),
      'deepMin': n(['deep (sws) duration (min)', 'deep sleep duration (min)', 'deep (sws) duration (minutes)']),
      'remMin': n(['rem duration (min)', 'rem duration (minutes)']),
      'awakeMin': n(['awake duration (min)', 'awake duration (minutes)']),
      // Efficiency only. 'Sleep performance %' is hours slept against sleep
      // need, a different number; _pick takes the first column that exists,
      // so listing it here stored performance as efficiency.
      'effPct': n(['sleep efficiency %']),
      'sleepOnset': parseExportTs(get(['sleep onset']), zone: zone),
      'sleepWake': parseExportTs(get(['wake onset']), zone: zone),
    });
  }

  static Future<_DayWrite> _buildAndWriteDay(
    String date,
    Map<String, dynamic> f,
    Set<String> rawDays,
  ) async {
    // NEVER clobber a real derived day: a returning user with months of band
    // data importing their WHOOP export used to have every overlapping day's
    // payload and scalars replaced by the vendor's numbers — and
    // `finalized: true` then locked the day so DerivationEngine could never
    // rebuild it from raw. The guard now lives in LocalDb so the other three
    // import paths share it rather than each forgetting it.
    if (await LocalDb.isMeasuredDay(date)) return _DayWrite.keptExisting;

    final recovery = f['recovery'] as num?;
    final rhr = f['rhr'] as num?;
    final rmssd = f['rmssd'] as num?;
    final strain = f['strain'] as num?;
    final caloriesTotal = f['caloriesTotal'] as num?;
    final resp = f['resp'] as num?;
    final spo2 = f['spo2'] as num?;
    final asleepMin = f['asleepMin'] as num?;
    final inBedMin = f['inBedMin'] as num?;
    final lightMin = f['lightMin'] as num?;
    final deepMin = f['deepMin'] as num?;
    final remMin = f['remMin'] as num?;
    final awakeMin = f['awakeMin'] as num?;
    // No efficiency column: asleep over in bed is the definition.
    final effPct = f['effPct'] as num? ??
        (asleepMin != null && inBedMin != null && inBedMin > 0
            ? asleepMin / inBedMin * 100
            : null);
    final sleepOnset = f['sleepOnset'] as int?;
    final sleepWake = f['sleepWake'] as int?;

    final hasSleep = asleepMin != null && asleepMin > 0;
    Map<String, dynamic>? acct, win;
    if (hasSleep) {
      final tstSec = (asleepMin * 60).round();
      final spt = (inBedMin ?? asleepMin) * 60;
      acct = {
        'tst_sec': tstSec,
        'in_bed_sec': spt.round(),
        'efficiency_pct': effPct,
        'light_sec': lightMin == null ? null : (lightMin * 60).round(),
        'deep_sec': deepMin == null ? null : (deepMin * 60).round(),
        'rem_sec': remMin == null ? null : (remMin * 60).round(),
        'nrem_sec': (lightMin != null && deepMin != null)
            ? ((lightMin + deepMin) * 60).round()
            : null,
        'wake_sec': awakeMin == null ? null : (awakeMin * 60).round(),
        'deep_low_confidence': true,
        'imported': true,
      };
      win = {
        'onset_ms': sleepOnset == null ? null : sleepOnset * 1000,
        'offset_ms': sleepWake == null ? null : sleepWake * 1000,
        'spt_sec': spt.round(),
      };
    }

    Map<String, dynamic> env(Object? v, {String tier = 'HIGH'}) => {
          'value': v ?? '—',
          'confidence': v == null ? 0 : 0.7,
          'tier': tier,
          'inputs_used': const ['whoop_export'],
        };

    final bundle = <String, dynamic>{
      'date': date,
      'imported': true,
      'source': 'whoop_export',
      'day_confidence': 0.7,
      'flags': const ['IMPORTED_WHOOP_BETA'],
      'clinical': {
        if (rmssd != null) 'hrv_time': env({'rmssd': rmssd}),
        if (rhr != null) 'resting_hr': env({'low30Mean': rhr}),
        if (strain != null) 'strain': env(strain, tier: 'ESTIMATE'),
      },
      if (acct != null)
        'sleep': {
          'window': {'value': win, 'confidence': 0.7, 'tier': 'HIGH', 'inputs_used': const ['whoop_export']},
          'accounting': {'value': acct, 'confidence': 0.7, 'tier': 'ESTIMATE', 'inputs_used': const ['whoop_export']},
        },
      'scalars': {
        'rhr': rhr,
        'rmssd': rmssd,
        'readiness': recovery,
        'strain': strain,
        'resp_rate': resp,
        'calories_total': caloriesTotal,
        'spo2': spo2,
        // no skin_temp_z: WHOOP exports absolute °C and every reader of that
        // key treats it as SDs off your own baseline (33 °C showed as +33 SD).
        'tst_min': asleepMin,
        'rem_min': remMin,
        'deep_min': deepMin,
        'light_min': lightMin,
        'efficiency': effPct,
      },
    };

    double? d(num? v) => v?.toDouble();
    await LocalDb.putDayResult(
      dayId: date,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(bundle),
      windowJson: jsonEncode(win ?? const {}),
      // Finalizing locks a day out of DerivationEngine permanently. Only safe
      // when there is no raw substrate left to re-derive from; a day that still
      // has 1 Hz raw stays open so the real signal supersedes WHOOP's numbers.
      finalized: !rawDays.contains(date),
      // export-provenance — WHOSE maths these scalars are. Every number in this
      // bundle is WHOOP's own derived score read out of their CSV, not one this
      // app computed from 1 Hz records, and unlabelled in an export the two are
      // byte-identical. Same tag the payload already carries, so the side table
      // and the bundle cannot drift apart.
      source: 'whoop_export',
      rhr: d(rhr),
      rmssd: d(rmssd),
      readiness: d(recovery),
      series: {
        'rhr': d(rhr),
        'rmssd': d(rmssd),
        'readiness': d(recovery),
        'strain': d(strain),
        'resp_rate': d(resp),
        'calories_total': d(caloriesTotal),
        // Earlier imports filed this total under `calories` (active energy);
        // the series row is only replaced for keys written, so clear it.
        'calories': null,
        'spo2': d(spo2),
        'tst_min': d(asleepMin),
        'rem_min': d(remMin),
        'deep_min': d(deepMin),
        'light_min': d(lightMin),
        'efficiency': d(effPct),
      },
    );
    return _DayWrite.written;
  }

  static Future<bool> _writeWorkout(_Row row, Set<String> deleted) async {
    String get(List<String> names) => row.get(names);
    final zone = get(_zoneCols);
    final start =
        parseExportTs(get(['workout start time', 'start time']), zone: zone);
    final end = parseExportTs(get(['workout end time', 'end time']), zone: zone);
    if (start == null) return false;
    num? n(List<String> names) => double.tryParse(get(names));
    final id = '$workoutIdPrefix$start';
    // A re-import (a newer export picking up recent days) carries every old
    // workout again. putSession is INSERT-OR-REPLACE over the whole row, so
    // rewriting one already here would revert the user's type correction,
    // wipe their RPE and clear its private flag — and the export below would
    // then write a workout they had made private into the health store. What
    // the export says about a past workout does not change; keep the row.
    // A deleted one stays deleted.
    if (deleted.contains(id) || await LocalDb.session(id) != null) {
      return false;
    }
    // Imports before the export's own zone was honoured read these times in
    // the phone's zone, so a workout recorded elsewhere is already here under
    // that wrong instant's id. Inserting at the corrected id would show it
    // twice (and write it to Health twice); move the old row onto the right
    // instant instead, under its old id so its edits, tombstone and child rows
    // stay attached. Only when its window is still exactly what that import
    // wrote — a row the user retimed, or one healed by an earlier re-import,
    // is left alone.
    final legacyStart =
        parseExportTs(get(['workout start time', 'start time']));
    if (legacyStart != null && legacyStart != start) {
      final legacyId = '$workoutIdPrefix$legacyStart';
      if (deleted.contains(legacyId)) return false;
      final legacy = await LocalDb.session(legacyId);
      if (legacy != null) {
        final legacyEnd = parseExportTs(get(['workout end time', 'end time']));
        final oldStart = (legacy['start_ts'] as num?)?.toInt();
        final oldEnd = (legacy['end_ts'] as num?)?.toInt();
        if (oldStart == legacyStart &&
            oldEnd == legacyEnd &&
            legacy['source'] == 'whoop' &&
            await LocalDb.setSessionWindow(legacyId, start, end) > 0) {
          unawaited(() async {
            if (oldEnd != null) {
              await HealthExporter.deleteWorkoutWindow(legacyStart, oldEnd);
            }
            await HealthExporter.exportWorkoutId(legacyId);
          }());
        }
        return false;
      }
    }
    // A row moved onto this instant by an earlier re-import keeps its old id,
    // so the id check above misses it once the phone's zone matches the
    // export's.
    if (await LocalDb.hasSessionStartingAt('whoop', start)) return false;
    await LocalDb.putSession({
      'id': id,
      'start_ts': start,
      'end_ts': end,
      'type': activityTypeKey(get(['activity name', 'activity'])),
      'status': 'done',
      'source': 'whoop',
      'calories': _kcal(get(_energyCols), row.header(_energyCols))?.toDouble(),
      'strain': n(['activity strain', 'strain'])?.toDouble(),
      'max_hr': n(['max hr (bpm)', 'max heart rate (bpm)'])?.toInt(),
      'duration_min': (end != null) ? ((end - start) / 60).round() : null,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    // exportAll only scans dates already present in day_result, so an
    // imported workout on a date this import brought no day_result row for
    // would otherwise never reach Health export — trigger it directly off
    // the completed session row instead (edge#277).
    unawaited(HealthExporter.exportWorkoutId(id));
    return true;
  }

  // ── parsing helpers ──────────────────────────────────────────────────────────

  static _Kind _classify(Map<String, int> col) {
    bool has(String k) => col.containsKey(k);
    if (has('activity name') || has('workout start time')) return _Kind.workout;
    if (has('recovery score %') ||
        has('asleep duration (min)') ||
        has('day strain') ||
        has('sleep onset')) {
      return _Kind.day;
    }
    return _Kind.unknown;
  }

  /// The export writes wall-clock times with no offset ("2024-03-09 23:10:00")
  /// and puts the offset they were recorded in in a separate column.
  static const List<String> _zoneCols = ['cycle timezone', 'timezone'];

  /// "UTC+01:00" / "UTC-0800" / "GMT+5:30" / "+01:00" / "UTC" → its offset
  /// from UTC; null for anything else (blank, an IANA name we can't resolve
  /// without a tz database), which falls back to the phone's own zone.
  @visibleForTesting
  static Duration? zoneOffset(String tz) {
    final t = tz.trim().toUpperCase();
    if (t == 'UTC' || t == 'GMT' || t == 'Z') return Duration.zero;
    final m = RegExp(r'^(?:UTC|GMT)?\s*([+-])(\d{1,2})(?::?(\d{2}))?$').firstMatch(t);
    if (m == null) return null;
    final h = int.parse(m.group(2)!);
    final min = int.parse(m.group(3) ?? '0');
    if (h > 14 || min > 59) return null;
    final d = Duration(hours: h, minutes: min);
    return m.group(1) == '-' ? -d : d;
  }

  static String _wallDateLabel(int epochSec, Duration off) {
    final w = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: true)
        .add(off);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${w.year.toString().padLeft(4, '0')}-${two(w.month)}-${two(w.day)}';
  }

  /// Lenient timestamp → unix seconds. Handles ISO ("2024-01-15T06:30:12Z" /
  /// "+00:00"), the export's "2024-01-15 06:30:12", and "+0000" offsets.
  ///
  /// An offset-less time is read in [zone] (the row's "Cycle timezone") when
  /// that parses. Reading it in the phone's current zone instead put every
  /// night or workout recorded elsewhere at the wrong instant — a Paris night
  /// imported in Los Angeles landed in Apple Health nine hours late.
  @visibleForTesting
  static int? parseExportTs(String s, {String zone = ''}) {
    if (s.isEmpty) return null;
    var t = s.trim();
    // Normalise "+0000" → "+00:00" so DateTime.parse accepts it.
    final m = RegExp(r'([+-]\d{2})(\d{2})$').firstMatch(t);
    if (m != null) t = '${t.substring(0, m.start)}${m.group(1)}:${m.group(2)}';
    final off = zoneOffset(zone);
    final hasOwnOffset = RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(t);
    if (off != null && !hasOwnOffset) {
      final asUtc = DateTime.tryParse('${t}Z');
      if (asUtc != null) return asUtc.subtract(off).millisecondsSinceEpoch ~/ 1000;
    }
    final dt = DateTime.tryParse(t);
    if (dt != null) return dt.millisecondsSinceEpoch ~/ 1000;
    // Fallback: pull a yyyy-mm-dd and treat as midnight in the row's zone
    // (local midnight when it has none).
    final d = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(t);
    if (d != null) {
      final y = int.parse(d.group(1)!);
      final mo = int.parse(d.group(2)!);
      final da = int.parse(d.group(3)!);
      final mid = off != null
          ? DateTime.utc(y, mo, da).subtract(off)
          : DateTime(y, mo, da);
      return mid.millisecondsSinceEpoch ~/ 1000;
    }
    return null;
  }

  /// "Energy burned" is exported in kcal by some WHOOP locales and in
  /// kilojoules by others. The unit comes from the COLUMN HEADER that matched,
  /// never from the magnitude of the value: the old `v > 4000 ? v / 4.184 : v`
  /// heuristic silently rewrote a real 4,500 kcal day (an ultra, a long ride)
  /// as 1,076 kcal, and that number then flowed into `metric_series` and into
  /// Apple Health / Health Connect as active energy.
  ///
  /// If the header carries no unit at all, the value is genuinely ambiguous and
  /// we drop it rather than guess — a missing calorie figure is honest, a
  /// wrong one is not.
  static num? _kcal(String s, String header) {
    final v = double.tryParse(s);
    if (v == null) return null;
    final h = header.toLowerCase();
    if (h.contains('kj') || h.contains('kilojoule')) return v / 4.184;
    if (h.contains('cal')) return v; // cal / kcal / kilocalories
    return null;
  }

  /// WHOOP activity names spelt as this app's stored `sessions.type` keys
  /// (`Activity.typeKey`: lower case, spaces as underscores). Storing WHOOP's
  /// raw name kept the space in 'mountain biking' and WHOOP's own words for
  /// things the catalogue names differently, so the health export fell
  /// through to OTHER for every weightlifting session (#184 again, through
  /// the importer) and the workout list found no catalogue entry for them.
  static const Map<String, String> _whoopActivityAliases = {
    'weightlifting': 'weight_training',
    'strength_trainer': 'weight_training',
    'functional_fitness': 'functional',
    'spin': 'indoor_bike',
    'hiking/rucking': 'hiking',
    'rock_climbing': 'climbing',
  };

  @visibleForTesting
  static String activityTypeKey(String s) {
    final t = s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
    if (t.isEmpty) return 'other';
    return _whoopActivityAliases[t] ?? t;
  }

  /// Read a CSV via the repo's one RFC 4180 parser ([parseCsv],
  /// journal_csv_import). The line-based reader that lived here split records
  /// on newlines BEFORE quote-parsing, so a quoted WHOOP field containing an
  /// embedded newline (free-text activity names/notes) was torn into two
  /// malformed records — quote state cannot survive a LineSplitter. Lenient
  /// decode preserved: a WHOOP export saved under a non-UTF-8 locale should
  /// lose a character, not the whole import. Blank lines are dropped, as the
  /// old reader did.
  static Future<List<List<String>>> _readCsv(String path) async {
    final bytes = await File(path).readAsBytes();
    final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    return [
      for (final r in parseCsv(text))
        if (r.length != 1 || r.single.isNotEmpty) r,
    ];
  }
}

enum _Kind { day, workout, unknown }

/// Outcome of one day row: written, deliberately kept (a real derived day
/// already exists for that date), or unusable (no parseable anchor timestamp).
enum _DayWrite { written, keptExisting, unusable }
