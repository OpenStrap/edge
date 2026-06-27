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

class WhoopImportResult {
  final int days;
  final int workouts;
  WhoopImportResult(this.days, this.workouts);
}

class WhoopImporter {
  /// Import one or more WHOOP export CSVs. Derived snapshots only. Pass [engine]
  /// + [profile] to run the cross-day rollup / baseline refresh once at the end.
  static Future<WhoopImportResult> importFiles(
    List<String> paths, {
    DerivationEngine? engine,
    Profile? profile,
    void Function(int done)? onProgress,
  }) async {
    var days = 0, workouts = 0;
    for (final path in paths) {
      final rows = await _readCsv(path);
      if (rows.length < 2) continue;
      final header = rows.first;
      final col = <String, int>{
        for (var i = 0; i < header.length; i++) header[i].trim().toLowerCase(): i
      };
      final kind = _classify(col);
      for (var r = 1; r < rows.length; r++) {
        final f = rows[r];
        if (f.isEmpty) continue;
        String get(List<String> names) {
          for (final n in names) {
            final i = col[n];
            if (i != null && i < f.length) return f[i].trim();
          }
          return '';
        }

        if (kind == _Kind.workout) {
          if (await _writeWorkout(get)) workouts++;
        } else if (kind == _Kind.day) {
          if (await _writeDay(get)) days++;
          onProgress?.call(days);
        }
      }
    }
    if (engine != null && profile != null) {
      await engine.finalizeImport(profile);
    }
    return WhoopImportResult(days, workouts);
  }

  // ── per-row writers ──────────────────────────────────────────────────────────

  static Future<bool> _writeDay(String Function(List<String>) get) async {
    final wakeTs = _parseTs(get(['wake onset', 'sleep onset', 'cycle start time']));
    final cycleStart = _parseTs(get(['cycle start time', 'sleep onset']));
    final anchor = wakeTs ?? cycleStart;
    if (anchor == null) return false;
    final date = localDateLabel(anchor);

    num? n(List<String> names) => double.tryParse(get(names));
    final recovery = n(['recovery score %', 'recovery score']);
    final rhr = n(['resting heart rate (bpm)', 'resting heart rate']);
    final rmssd = n(['heart rate variability (ms)', 'heart rate variability (rmssd) (ms)']);
    final strain = n(['day strain', 'strain']);
    final calories = _kcal(get(['energy burned (cal)', 'energy burned']));
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
      finalized: true,
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
    return true;
  }

  static Future<bool> _writeWorkout(String Function(List<String>) get) async {
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
      'calories': _kcal(get(['energy burned (cal)', 'energy burned']))?.toDouble(),
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

  /// "Energy burned" in WHOOP exports is sometimes kilojoules; values >4000 are
  /// almost certainly kJ → convert to kcal. Otherwise treat as kcal.
  static num? _kcal(String s) {
    final v = double.tryParse(s);
    if (v == null) return null;
    return v > 4000 ? v / 4.184 : v;
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
        .transform(utf8.decoder)
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
