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

import 'dart:convert';
import 'dart:io';

import '../compute/derivation_engine.dart' show kAlgoVersion, DerivationEngine;
import '../compute/profile.dart';
import '../compute/substrate.dart' show localDateLabel;
import '../data/db.dart';
import '../data/series_codec.dart';
import 'import_container.dart';

class WhoopImportResult {
  final int days;
  final int workouts;

  /// Days present in the export that were NOT written because the device
  /// already holds a REAL (1 Hz-derived) day for that date. Vendor snapshots
  /// never replace measured data — see [WhoopImporter._writeDay].
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

class WhoopImporter {
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
          if (await _writeWorkout(row)) workouts++;
        } else if (kind == _Kind.day) {
          switch (await _writeDay(row, rawDays)) {
            case _DayWrite.written:
              days++;
              onProgress?.call(days);
            case _DayWrite.keptExisting:
              skipped++;
            case _DayWrite.unusable:
              break;
          }
        }
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

  /// True when [row] is a day the device DERIVED itself (from real 1 Hz), as
  /// opposed to absent, a skip marker, or a previous vendor import. Such a day
  /// is never overwritten: `putDayResult` is INSERT OR REPLACE on both
  /// `day_result` and `metric_series`, so writing over it would permanently
  /// destroy measured data that a returning user cannot get back.
  static bool _isRealDerivedDay(Map<String, dynamic>? row) {
    if (row == null) return false;
    if (((row['skipped'] as num?) ?? 0).toInt() == 1) return false;
    try {
      final p = SeriesCodec.decodePayloadJson(
        (row['payload_json'] as String?) ?? '{}',
      );
      if (p != null) {
        if (p['skipped'] == true) return false;
        // A prior import (this importer, or the cloud one) is replaceable —
        // both are vendor snapshots, neither is measured on-device data.
        if (p['imported'] == true) return false;
      }
    } catch (_) {
      // Present but unreadable — treat as real and refuse to clobber it.
      return true;
    }
    return true;
  }

  static Future<_DayWrite> _writeDay(_Row row, Set<String> rawDays) async {
    String get(List<String> names) => row.get(names);
    final wakeTs = _parseTs(get(['wake onset', 'sleep onset', 'cycle start time']));
    final cycleStart = _parseTs(get(['cycle start time', 'sleep onset']));
    final anchor = wakeTs ?? cycleStart;
    if (anchor == null) return _DayWrite.unusable;
    final date = localDateLabel(anchor);

    // NEVER clobber a real derived day. The import is reachable from onboarding
    // AND from Profile, so a returning user with months of band data importing
    // their WHOOP export used to have every overlapping day's payload and
    // scalars replaced by the vendor's numbers — and `finalized: true` then
    // locked the day so DerivationEngine could never rebuild it from raw.
    if (_isRealDerivedDay(await LocalDb.dayResult(date))) {
      return _DayWrite.keptExisting;
    }

    num? n(List<String> names) => double.tryParse(get(names));
    final recovery = n(['recovery score %', 'recovery score']);
    final rhr = n(['resting heart rate (bpm)', 'resting heart rate']);
    final rmssd = n(['heart rate variability (ms)', 'heart rate variability (rmssd) (ms)']);
    final strain = n(['day strain', 'strain']);
    final calories = _kcal(get(_energyCols), row.header(_energyCols));
    final resp = n(['respiratory rate (rpm)', 'respiratory rate']);
    final spo2 = n(['blood oxygen %', 'blood oxygen']);
    final skinTempC = n(['skin temp (celsius)', 'skin temperature (celsius)']);
    final asleepMin = n(['asleep duration (min)', 'asleep duration (minutes)']);
    final inBedMin = n(['in bed duration (min)', 'in bed duration (minutes)']);
    final lightMin = n(['light sleep duration (min)', 'light sleep duration (minutes)']);
    final deepMin = n(['deep (sws) duration (min)', 'deep sleep duration (min)', 'deep (sws) duration (minutes)']);
    final remMin = n(['rem duration (min)', 'rem duration (minutes)']);
    final awakeMin = n(['awake duration (min)', 'awake duration (minutes)']);
    final effPct = n(['sleep performance %', 'sleep efficiency %', 'sleep performance']);
    final sleepOnset = _parseTs(get(['sleep onset']));
    final sleepWake = _parseTs(get(['wake onset']));

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
        'calories': calories,
        'spo2': spo2,
        // WHOOP gives absolute °C; we store as a relative-ish scalar for trends.
        'skin_temp_z': skinTempC,
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
      rhr: d(rhr),
      rmssd: d(rmssd),
      readiness: d(recovery),
      series: {
        'rhr': d(rhr),
        'rmssd': d(rmssd),
        'readiness': d(recovery),
        'strain': d(strain),
        'resp_rate': d(resp),
        'calories': d(calories),
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

  static Future<bool> _writeWorkout(_Row row) async {
    String get(List<String> names) => row.get(names);
    final start = _parseTs(get(['workout start time', 'start time']));
    final end = _parseTs(get(['workout end time', 'end time']));
    if (start == null) return false;
    num? n(List<String> names) => double.tryParse(get(names));
    await LocalDb.putSession({
      'id': 'whoop_$start',
      'start_ts': start,
      'end_ts': end,
      'type': _slug(get(['activity name', 'activity'])),
      'status': 'done',
      'source': 'whoop',
      'calories': _kcal(get(_energyCols), row.header(_energyCols))?.toDouble(),
      'strain': n(['activity strain', 'strain'])?.toDouble(),
      'max_hr': n(['max hr (bpm)', 'max heart rate (bpm)'])?.toInt(),
      'duration_min': (end != null) ? ((end - start) / 60).round() : null,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
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

  /// Lenient timestamp → unix seconds. Handles ISO ("2024-01-15T06:30:12Z" /
  /// "+00:00"), the export's "2024-01-15 06:30:12", and "+0000" offsets.
  static int? _parseTs(String s) {
    if (s.isEmpty) return null;
    var t = s.trim();
    // Normalise "+0000" → "+00:00" so DateTime.parse accepts it.
    final m = RegExp(r'([+-]\d{2})(\d{2})$').firstMatch(t);
    if (m != null) t = '${t.substring(0, m.start)}${m.group(1)}:${m.group(2)}';
    final dt = DateTime.tryParse(t);
    if (dt != null) return dt.millisecondsSinceEpoch ~/ 1000;
    // Fallback: pull a yyyy-mm-dd and treat as local midnight.
    final d = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(t);
    if (d != null) {
      return DateTime(int.parse(d.group(1)!), int.parse(d.group(2)!),
                  int.parse(d.group(3)!))
              .millisecondsSinceEpoch ~/
          1000;
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

  static String _slug(String s) {
    final t = s.trim().toLowerCase();
    return t.isEmpty ? 'other' : t;
  }

  /// Minimal quote-aware CSV reader (handles fields wrapped in double-quotes with
  /// embedded commas / escaped ""). Streams lines so a large export isn't all in
  /// memory at once for the split step.
  static Future<List<List<String>>> _readCsv(String path) async {
    final lines = File(path)
        .openRead()
        // Lenient: a WHOOP export saved under a non-UTF-8 locale should lose a
        // character, not the whole import.
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    final out = <List<String>>[];
    await for (final line in lines) {
      if (line.isEmpty) continue;
      out.add(_splitCsvLine(line));
    }
    return out;
  }

  static List<String> _splitCsvLine(String line) {
    final out = <String>[];
    final sb = StringBuffer();
    var inQ = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (inQ) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            sb.write('"');
            i++;
          } else {
            inQ = false;
          }
        } else {
          sb.write(c);
        }
      } else if (c == '"') {
        inQ = true;
      } else if (c == ',') {
        out.add(sb.toString());
        sb.clear();
      } else {
        sb.write(c);
      }
    }
    out.add(sb.toString());
    return out;
  }
}

enum _Kind { day, workout, unknown }

/// Outcome of one day row: written, deliberately kept (a real derived day
/// already exists for that date), or unusable (no parseable anchor timestamp).
enum _DayWrite { written, keptExisting, unusable }
