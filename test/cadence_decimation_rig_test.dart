// THE DECIMATION RIG — measure what a slower band's cadence does to a metric,
// against the only ground truth we have: the same real night at 1 Hz.
//
// The premise: OpenStrap holds real 1 Hz WHOOP data, so the true answer for any
// window-based metric is already known. Take every Nth REAL sample of that same
// data, run the metric again, and compare. A cadence-aware metric converges on
// the 1 Hz answer. Most of ours do not, and this file is where that stops being
// an assertion and becomes a number.
//
// IT DOES NOT ASSERT CORRECTNESS. Today's numbers are wrong on purpose — the
// job right now is to RECORD the baseline error so the group-C agents have
// something to diff against. The only thing asserted here is the decimator
// itself (see the pure-unit test at the bottom, which runs with no database).
//
// Source data: `OPENSTRAP_TEST_DBS=/path/export.db` — same env-var idiom as
// `db_migration_ladder_test.dart` / `db_v42_retention_and_provenance_test.dart`.
// Skipped entirely when unset, because that file is personal and can never be
// committed. The database is opened READ-ONLY and never migrated: the rig reads
// `decoded_onehz` / `decoded_rr`, which have carried those column names since
// well before the v47 re-key, so no ladder is needed and nothing is written.
//
// DECIMATION DOES NOT FABRICATE. Every cadence keeps every Nth real record and
// the RR beats attached to it — no interpolation, no bucket averaging. That is
// also the physically honest model: a 60 s band emits fewer records, it does
// not emit averages of the records it skipped. Per-metric notes below say where
// a metric's own contract would have justified averaging (none of the eleven
// declare a mean input; `relative_odi` computes its own AC/DC windows and
// `cardio_stager` its own epoch means, both from raw samples).
//
// Run:
//   OPENSTRAP_TEST_DBS=~/Documents/openstrap/openstrap_export_1786730410696.db \
//     flutter test test/cadence_decimation_rig_test.dart --concurrency=1
//
// Writes `build/cadence_baseline.json` (gitignored) and prints the same table.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_analytics/onehz.dart';

/// Cadences under test, seconds per record. 1 is the ground truth.
///
/// 301 is not a typo and not decoration: the median-interval helpers in
/// `load_trimp` / `hr_zones` gate on `<= 300`, so a 300 s device is fine and a
/// 301 s device falls off a cliff. `advanced_stager` gates on `< 300`, so it
/// falls one second earlier. Both edges have to be on the table.
///
/// 15 s is here because it is where a POSITIONAL window metric does its worst
/// damage, and it is a cadence real bands actually ship (Fitbit/Garmin publish
/// 15 s HR). `nocturnalRhr` needs 1800 positions; over an 8 h night that holds
/// down to 16 s and abstains below it. So the wrong-NUMBER band is roughly
/// 2–16 s, and the top of it — where "the lowest 30-min mean" has quietly
/// become "the whole-night mean" — is the ceiling C1 has to clear. Below that
/// band the metric already fails safe.
const _cadences = <int>[1, 5, 15, 60, 300, 301];

/// One `decoded_onehz` row, exactly as stored.
class _Row {
  final int recTs;
  final int hr;
  final double ax, ay, az;
  final int red, ir, temp;
  const _Row(this.recTs, this.hr, this.ax, this.ay, this.az, this.red, this.ir,
      this.temp);

  /// Exact (0,0,0) is the documented "never decoded" sentinel, not a reading.
  bool get accelPresent => !(ax == 0 && ay == 0 && az == 0);
}

/// One RR beat, carrying the `rec_ts` of the record that delivered it — which
/// is what decimation acts on. A band that reports every 60 s hands over the
/// beats inside the records it sends and none of the ones it skips.
class _Beat {
  final int recTs;
  final double tsMs;
  final double rrMs;
  const _Beat(this.recTs, this.tsMs, this.rrMs);
}

/// Keep every Nth REAL sample, phase-locked to the first row's second.
///
/// Not a resample: no value is interpolated, averaged or invented. `everyN <= 1`
/// is the identity. Non-divisor cadences (301) are honoured exactly — the point
/// of the 301 case is that it is NOT 300.
List<T> decimateEveryNth<T>(
    List<T> rows, int Function(T) secOf, int everyN) {
  if (everyN <= 1 || rows.isEmpty) return rows;
  final t0 = secOf(rows.first);
  return [
    for (final r in rows)
      if ((secOf(r) - t0) % everyN == 0) r
  ];
}

/// One measured cell of the table.
class _Cell {
  final String metric;
  final int cadence;
  final double? value;
  final double? truth;
  final bool absent;
  final String unit;
  final String note;
  const _Cell(this.metric, this.cadence, this.value, this.truth, this.absent,
      this.unit, this.note);

  double? get absErr =>
      (value == null || truth == null) ? null : (value! - truth!).abs();
  double? get relErr => (absErr == null || truth == null || truth == 0)
      ? null
      : absErr! / truth!.abs();

  Map<String, dynamic> toJson() => {
        'metric': metric,
        'cadence_s': cadence,
        'value': value,
        'truth_1hz': truth,
        'abs_err': absErr,
        'rel_err': relErr,
        'absent': absent,
        'unit': unit,
        if (note.isNotEmpty) 'note': note,
      };
}

// ── window pickers ──────────────────────────────────────────────────────────
// Both are one deterministic pass over the record, so the rig picks the same
// window every run without a hand-tuned constant in it.

/// The [spanSec] window with the LOWEST mean valid HR. Physiologically that is
/// the night, and it needs no timezone, no staging and no threshold.
(int, int) _lowestHrWindow(List<_Row> all, int spanSec) =>
    _extremeHrWindow(all, spanSec, lowest: true);

/// The [spanSec] window with the HIGHEST mean valid HR — the day's hardest
/// effort, which is what the workout metrics want.
(int, int) _highestHrWindow(List<_Row> all, int spanSec) =>
    _extremeHrWindow(all, spanSec, lowest: false);

(int, int) _extremeHrWindow(List<_Row> all, int spanSec,
    {required bool lowest}) {
  final t0 = all.first.recTs, t1 = all.last.recTs;
  final n = t1 - t0 + 1;
  // Second-indexed prefix sums so every candidate window is O(1).
  final sum = List<double>.filled(n + 1, 0);
  final cnt = List<int>.filled(n + 1, 0);
  final hrAt = List<double>.filled(n, 0);
  for (final r in all) {
    if (r.hr > 0) hrAt[r.recTs - t0] = r.hr.toDouble();
  }
  for (var i = 0; i < n; i++) {
    sum[i + 1] = sum[i] + hrAt[i];
    cnt[i + 1] = cnt[i] + (hrAt[i] > 0 ? 1 : 0);
  }
  var bestStart = t0;
  double? bestMean;
  // 10-min steps: fine enough to land on the night, coarse enough to be free.
  for (var s = 0; s + spanSec <= n; s += 600) {
    final c = cnt[s + spanSec] - cnt[s];
    // Demand real coverage — an empty window has a mean of nothing, and a
    // sparsely-covered one is not the window we mean by "the night".
    if (c < spanSec * 0.8) continue;
    final m = (sum[s + spanSec] - sum[s]) / c;
    if (bestMean == null || (lowest ? m < bestMean : m > bestMean)) {
      bestMean = m;
      bestStart = t0 + s;
    }
  }
  return (bestStart, bestStart + spanSec);
}

// ── metric adapters ─────────────────────────────────────────────────────────
// Each returns ONE scalar plus an absent flag. Absent is a first-class result
// here: "the metric refused at this cadence" is exactly as informative as a
// wrong number, and considerably more honest.

typedef _Probe = (double?, bool); // (scalar, absent)

_Probe _nocturnalRhrProbe(List<_Row> rows) {
  // Fed EXACTLY as the app feeds it: the surviving samples, compacted. That
  // compaction is the C1 defect — `windowSamples = 1800` counts positions, so
  // 1800 positions is 30 min at 1 Hz and 2.5 h at 5 s.
  final m = nocturnalRhr([for (final r in rows) r.hr.toDouble()]);
  return (m.value?.low30Mean, !m.present);
}

_Probe _vanHeesProbe(List<_Row> rows) {
  final m = vanHeesSleepWindow([
    for (final r in rows)
      AccelSample(r.recTs * 1000.0, r.ax, r.ay, r.az, valid: r.accelPresent)
  ]);
  return (m.value?.sptSec.toDouble(), !m.present);
}

_Probe _relativeOdiProbe(List<_Row> rows) {
  final m = relativeOdi(
    [for (final r in rows) r.red.toDouble()],
    [for (final r in rows) r.ir.toDouble()],
    [for (final r in rows) r.recTs.toDouble()],
  );
  return (m.value?.odiPerHour, !m.present);
}

_Probe _cardioStagerProbe(List<_Row> rows, List<_Beat> beats) {
  final r = cardioStager(
    [for (final x in rows) x.hr.toDouble()],
    [
      for (final x in rows)
        AccelSample(x.recTs * 1000.0, x.ax, x.ay, x.az, valid: x.accelPresent)
    ],
    rrMs: [for (final b in beats) b.rrMs],
    rrTsMs: [for (final b in beats) b.tsMs],
  );
  // wakePct is the Cole-Kripke spine's own output and the number a cadence
  // error moves first.
  return (r.base.wakePct, r.base.stages.isEmpty);
}

_Probe _hrRecoveryProbe(List<_Row> rows) {
  if (rows.isEmpty) return (null, true);
  var peak = 0;
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].hr > rows[peak].hr) peak = i;
  }
  final m = hrRecovery(
    [for (final r in rows) r.hr],
    endIndex: peak,
    tsSec: [for (final r in rows) r.recTs],
  );
  return (m.value?.dropBpm, !m.present);
}

_Probe _hrZonesProbe(List<_Row> rows) {
  // Total accounted seconds. At any cadence a correct implementation reports
  // roughly the window span; this is the C9 headline, and 301 s is where it
  // stops doing that.
  final t = HeartRateZones.timeInZone(
    [for (final r in rows) HrSample(r.recTs * 1000.0, r.hr.toDouble())],
    HeartRateZones.zonesFromMaxHr(190, source: 'rig'),
  );
  return (t?.total, t == null);
}

_Probe _orientationProbe(List<_Row> rows) {
  final tilts = positionSeries([
    for (final r in rows)
      AccelSample(r.recTs * 1000.0, r.ax, r.ay, r.az, valid: r.accelPresent)
  ], epochSec: 30);
  return (tilts.length.toDouble(), tilts.isEmpty);
}

_Probe _cyclesProbe(List<_Beat> beats, int onset, int offset) {
  final m = sleepCyclesMetric(
    [for (final b in beats) b.rrMs],
    [for (final b in beats) b.tsMs],
    onset,
    offset,
  );
  return (m.value?.n.toDouble(), !m.present);
}

_Probe _riivProbe(List<_Row> rows) {
  final m = riivRespRate(
    [for (final r in rows) r.ir.toDouble()],
    [for (final r in rows) r.recTs.toDouble()],
  );
  return (m.value?.brpm, !m.present);
}

_Probe _rsaProbe(List<_Beat> beats) {
  final m = rsaRespRate(
    [for (final b in beats) b.rrMs],
    [for (final b in beats) b.tsMs],
    artifactFraction: 0.0,
  );
  return (m.value?.brpm, !m.present);
}

_Probe _advancedStagerProbe(List<_Row> rows, List<_Beat> beats) {
  final sessions = AdvancedSleepStager.detectSleep(
    [
      for (final r in rows)
        GravTs(r.recTs, r.ax, r.ay, r.az, valid: r.accelPresent)
    ],
    [for (final r in rows) HrTs(r.recTs, r.hr.toDouble())],
    rr: [for (final b in beats) RrTs((b.tsMs / 1000).round(), b.rrMs)],
  );
  if (sessions.isEmpty) return (null, true);
  var best = sessions.first;
  for (final s in sessions) {
    if (s.end - s.start > best.end - best.start) best = s;
  }
  return ((best.end - best.start).toDouble(), false);
}

// ── reporting ───────────────────────────────────────────────────────────────

String _fmt(double? v) {
  if (v == null) return '—';
  if (v.abs() >= 1000) return v.toStringAsFixed(0);
  if (v.abs() >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(3);
}

String _pct(double? v) => v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';

String _renderTable(List<_Cell> cells) {
  final b = StringBuffer();
  final head = ['metric', 'unit', 'cad', '1 Hz truth', 'value', 'abs err',
    'rel err', 'absent'];
  final rows = <List<String>>[
    head,
    for (final c in cells)
      [
        c.metric,
        c.unit,
        '${c.cadence}s',
        _fmt(c.truth),
        c.absent ? 'ABSENT' : _fmt(c.value),
        _fmt(c.absErr),
        _pct(c.relErr),
        c.absent ? 'yes' : '',
      ],
  ];
  final w = List<int>.generate(head.length,
      (i) => rows.map((r) => r[i].length).reduce(math.max));
  for (var ri = 0; ri < rows.length; ri++) {
    b.writeln([
      for (var i = 0; i < head.length; i++) rows[ri][i].padRight(w[i])
    ].join('  ').trimRight());
    if (ri == 0) b.writeln(List.generate(w.length, (i) => '-' * w[i]).join('  '));
  }
  return b.toString();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // The decimator is the one piece of logic in this file that could be
  // silently wrong, so it gets the one check that runs without a database.
  test('decimateEveryNth takes every Nth REAL sample, phase-locked, no interp',
      () {
    final rows = [for (var t = 100; t < 130; t++) t];
    int at(int v) => v;
    expect(decimateEveryNth(rows, at, 1), rows);
    expect(decimateEveryNth(rows, at, 0), rows);
    expect(decimateEveryNth(rows, at, 5), [100, 105, 110, 115, 120, 125]);
    // Phase-locked to the FIRST row, not to the epoch.
    expect(
        decimateEveryNth(rows.sublist(3), at, 5), [103, 108, 113, 118, 123, 128]);
    // Non-divisor cadence: exact, not rounded to a divisor.
    expect(decimateEveryNth(rows, at, 7), [100, 107, 114, 121, 128]);
    // Holes survive as holes — nothing is filled in.
    expect(decimateEveryNth([100, 101, 107, 110], at, 5), [100, 110]);
    expect(decimateEveryNth(<int>[], at, 5), isEmpty);
  });

  final real = (Platform.environment['OPENSTRAP_TEST_DBS'] ?? '')
      .split(',')
      .where((s) => s.trim().isNotEmpty)
      .toList();

  for (final src in real) {
    test('cadence baseline over ${p.basename(src)}', () async {
      final db = await databaseFactory.openDatabase(src,
          options: OpenDatabaseOptions(readOnly: true));

      final all = <_Row>[
        for (final r in await db.query('decoded_onehz',
            columns: [
              'rec_ts', 'hr', 'ax', 'ay', 'az',
              'spo2_red_raw', 'spo2_ir_raw', 'skin_temp_raw'
            ],
            orderBy: 'rec_ts'))
          _Row(
            r['rec_ts'] as int,
            r['hr'] as int,
            (r['ax'] as num).toDouble(),
            (r['ay'] as num).toDouble(),
            (r['az'] as num).toDouble(),
            (r['spo2_red_raw'] as num).toInt(),
            (r['spo2_ir_raw'] as num).toInt(),
            (r['skin_temp_raw'] as num).toInt(),
          )
      ];
      expect(all.length, greaterThan(1000),
          reason: 'need a real 1 Hz record to decimate');

      final (nightA, nightB) = _lowestHrWindow(all, 8 * 3600);
      final (dayA, dayB) = _highestHrWindow(all, 90 * 60);

      List<_Row> slice(int a, int b) =>
          [for (final r in all) if (r.recTs >= a && r.recTs < b) r];
      final night = slice(nightA, nightB);
      final day = slice(dayA, dayB);

      Future<List<_Beat>> beatsIn(int a, int b) async => [
            for (final r in await db.rawQuery(
                'SELECT o.rec_ts AS rec_ts, r.rr_ts_ms AS ts, r.rr_ms AS rr '
                'FROM decoded_rr r JOIN decoded_onehz o ON o.counter = r.counter '
                'WHERE o.rec_ts >= ? AND o.rec_ts < ? ORDER BY r.rr_ts_ms',
                [a, b]))
              _Beat(r['rec_ts'] as int, (r['ts'] as num).toDouble(),
                  (r['rr'] as num).toDouble())
          ];
      final nightBeats = await beatsIn(nightA, nightB);
      await db.close();

      // ignore: avoid_print
      print('[rig] ${p.basename(src)}  rows=${all.length}\n'
          '[rig] night window $nightA..$nightB  '
          'rows=${night.length} beats=${nightBeats.length}\n'
          '[rig] day window   $dayA..$dayB  rows=${day.length}');

      final cells = <_Cell>[];
      final truth = <String, double?>{};

      void run(String metric, String unit, int cadence, _Probe probe,
          {String note = ''}) {
        final (v, absent) = probe;
        if (cadence == 1) truth[metric] = v;
        cells.add(
            _Cell(metric, cadence, v, truth[metric], absent, unit, note));
      }

      for (final n in _cadences) {
        final nRows = decimateEveryNth(night, (r) => r.recTs, n);
        final dRows = decimateEveryNth(day, (r) => r.recTs, n);
        // A beat rides its record: keep the beats whose parent second survived.
        final keptSec = {for (final r in nRows) r.recTs};
        final nBeats = [
          for (final b in nightBeats)
            if (keptSec.contains(b.recTs)) b
        ];

        run('nocturnalRhr', 'bpm', n, _nocturnalRhrProbe(nRows));
        run('vanHees.sptSec', 's', n, _vanHeesProbe(nRows));
        run('relativeOdi.perHour', '/h', n, _relativeOdiProbe(nRows));
        run('cardioStager.wakePct', '%', n, _cardioStagerProbe(nRows, nBeats));
        run('hrRecovery.dropBpm', 'bpm', n, _hrRecoveryProbe(dRows));
        run('hrZones.totalSec', 's', n, _hrZonesProbe(dRows));
        run('orientation.epochs', 'n', n, _orientationProbe(nRows));
        run('cycles.n', 'n', n, _cyclesProbe(nBeats, nightA, nightB));
        run('respRate.riiv', 'brpm', n, _riivProbe(nRows));
        run('respRate.rsa', 'brpm', n, _rsaProbe(nBeats));
        run('advancedStager.tstSec', 's', n, _advancedStagerProbe(nRows, nBeats));
      }

      // `steps` is in the group-C list and CANNOT be measured here. The
      // pedometer's cadence defect (C7) lives at 50–100 Hz; the only accel this
      // project ever persists is the 1 Hz substrate (invariant 1 keeps the
      // 0x2B/0x33 high-rate streams RAM-only), so there is no faster source to
      // decimate DOWN from. Decimating 1 Hz cannot reach it. Recorded as an
      // explicit hole rather than silently dropped from the table.
      cells.add(const _Cell('steps.pedometer', 0, null, null, true, 'steps',
          'NOT MEASURABLE BY DECIMATION — needs a >=50 Hz source; the 1 Hz '
          'substrate is the fastest thing persisted. C7 needs a synthetic '
          'rate sweep, not this rig.'));

      final table = _renderTable(cells);
      // ignore: avoid_print
      print('\n$table');

      final out = File(p.join(Directory.current.path, 'build',
          'cadence_baseline.json'));
      await out.parent.create(recursive: true);
      await out.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'source': p.basename(src),
        'rows': all.length,
        'night_window': [nightA, nightB],
        'day_window': [dayA, dayB],
        'cadences_s': _cadences,
        'decimation': 'every Nth real sample, phase-locked to window start; '
            'no interpolation, no bucket averaging; RR beats ride their record',
        'cells': [for (final c in cells) c.toJson()],
      }));
      // ignore: avoid_print
      print('[rig] wrote ${out.path}');

      // NO correctness assertions. Only that the rig produced a full grid —
      // if a probe starts throwing, this is what notices.
      expect(cells.length, _cadences.length * 11 + 1);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
