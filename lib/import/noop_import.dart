// noop_import.dart — import a NOOP raw-sensor CSV export into the local store.
//
// The NOOP export is LONG-FORMAT raw 1 Hz: one row per decoded sample, with a
// `stream` discriminator and only that stream's columns filled. Columns are read
// by NAME from the header, never by fixed position — NOOP has already shipped one
// schema change (see below) and name-keyed reads absorbed it without misparsing.
//
// SCHEMA AS SHIPPED (observed 2026-08, NOOP 9.1/9.2 — OpenStrap/edge#160):
//   unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter,
//   ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,
//   event_kind,event_payload
// `band_sleep_state` was INSERTED at index 15, shifting event_kind/event_payload
// to 16/17 (the older documented layout, still in [_defaultCols], ends at
// event_payload=16). Streams now seen: hr, rr, gravity, skintemp, steps,
// band_sleep_state, ppghr, event. Note `spo2` and `resp` rows are no longer
// emitted at all even though their columns survive in the header.
//
// WHAT WE CONSUME, AND WHY NOT THE REST:
//   • hr / rr / gravity / skintemp / spo2 → the Substrate (full 1 Hz analytics).
//   • steps → `live_coverage` as a REAL step count (see [_flushStepCoverage]).
//   • band_sleep_state → deliberately ignored. `segmentSleep` is the single sleep
//     source (a second one would contradict it), and in the real #160 export this
//     column was constant 0 across all 12,663 rows — no signal to gain.
//   • ppghr → deliberately ignored. The `hr` stream already covers every second
//     the export carries, and PPG-derived HR is not trusted as a substitute.
//   • resp_raw → ignored; respiration rate is derived from RR downstream.
// An unrecognised future `stream` also lands in the default branch and is skipped
// safely, so a further NOOP schema change degrades rather than throws.
//
// Because this is RAW 1 Hz — the SAME signal family as our own Substrate — we run
// it through the FULL local pipeline (full-fidelity analytics, identical to a live
// band sync), NOT degraded snapshots.
//
// LARGE FILES: a 90-day export is hundreds of MB / tens of millions of rows, so we
// NEVER load the file or build one big Substrate. We STREAM the file and derive in
// a 2-day sliding window (the day model needs the prior evening for a sleep that
// starts before midnight), writing + freeing each day as we go. Memory stays flat
// (~2 days) regardless of file size.

import 'dart:convert';
import 'dart:io';

import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import '../compute/substrate.dart';
import '../data/db.dart';
import 'import_container.dart';

/// Last path segment, for error messages (avoids a `package:path` import just
/// for this one use).
String _basenameOf(String path) =>
    path.contains('/') ? path.substring(path.lastIndexOf('/') + 1) : path;

class NoopImportResult {
  final int days;
  final int rows;

  /// Real steps recovered from the export's `step_counter` and banked as
  /// `live_coverage` (0 when the export carries no `steps` stream).
  final int steps;

  /// Rows whose local date had ALREADY been derived and pruned by the time
  /// they appeared in the file (a genuinely out-of-order export). They cannot
  /// be folded back in, so they are counted here rather than silently dropped
  /// — a non-zero value means the export was not fully time-ordered.
  final int lateRows;
  NoopImportResult(this.days, this.rows,
      [this.lateRows = 0, this.steps = 0]);
}

/// One contiguous run of the band's cumulative `step_counter`, ready to bank as
/// a `live_coverage` row: real steps over a known [startSec]..[endSec] window.
class StepRun {
  final int startSec;
  final int endSec;
  final int steps;
  const StepRun(this.startSec, this.endSec, this.steps);

  @override
  String toString() => 'StepRun($startSec..$endSec, $steps)';

  @override
  bool operator ==(Object other) =>
      other is StepRun &&
      other.startSec == startSec &&
      other.endSec == endSec &&
      other.steps == steps;

  @override
  int get hashCode => Object.hash(startSec, endSec, steps);
}

/// What to do with an incoming row given the import's high-water date.
/// [advance] closes out the previous date; [buffer] folds the row into the
/// current rolling window; [late] means its day was already derived + pruned,
/// so the row cannot be used (counted in [NoopImportResult.lateRows]).
enum RowOrder { advance, buffer, late }

/// One second's worth of the 1 Hz channels (sparse — only set streams present).
class _Sec {
  int? hr;
  double? ax, ay, az;
  int? spo2Red, spo2Ir, skinTemp;
}

/// Documented default column order (used only if the export omits its header).
const Map<String, int> _defaultCols = {
  'unix_s': 0, 'iso_utc': 1, 'stream': 2, 'hr_bpm': 3, 'rr_ms': 4,
  'grav_x': 5, 'grav_y': 6, 'grav_z': 7, 'step_counter': 8, 'ppg_bpm': 9,
  'ppg_conf': 10, 'spo2_red': 11, 'spo2_ir': 12, 'skintemp_raw': 13,
  'resp_raw': 14, 'event_kind': 15, 'event_payload': 16,
};

class NoopImporter {
  /// Stream-import [path] and derive each day at full 1 Hz fidelity via [engine].
  /// [onProgress] reports days written so far. Never loads the whole file.
  static Future<NoopImportResult> importFile(
    String path,
    Profile profile,
    DerivationEngine engine, {
    void Function(int days)? onProgress,
  }) async {
    var file = File(path);
    if (!await file.exists()) {
      throw const FileSystemException('CSV not found');
    }
    // What did the user actually pick? A `.noopbak` is a ZIP around NOOP's
    // SQLite database, and feeding its bytes to `utf8.decoder` is what produced
    // the "Invalid UTF-8 byte (at offset 10)" in issues #160/#199. Resolve the
    // container first: a ZIP of CSVs is unwrapped, and anything unusable throws
    // an [ImportFormatException] naming the file we DO want.
    final resolved = await resolveImportCsvPaths([path], flavor: 'NOOP');
    if (resolved.paths.isEmpty) {
      await resolved.dispose();
      throw const ImportFormatException(
        'That archive holds no NOOP CSV export.',
      );
    }
    // A NOOP raw-sensor export is ONE CSV. An archive holding several is not
    // something to guess at: this importer streams a single file and derives in
    // a rolling two-day window, so silently taking the first match would import
    // a fraction of the archive and still report success.
    final candidates = resolved.paths
        .where((p) => p.toLowerCase().contains('raw-sensor'))
        .toList();
    final usable = candidates.isEmpty ? resolved.paths : candidates;
    if (usable.length > 1) {
      final names = usable.map(_basenameOf).take(4).join(', ');
      await resolved.dispose();
      throw ImportFormatException(
        'That archive holds ${usable.length} CSV files ($names…). Import the '
        'raw sensor CSV on its own so nothing is silently skipped.',
      );
    }
    file = File(usable.first);

    try {
      return await _importResolvedFile(
        file,
        profile,
        engine,
        onProgress: onProgress,
      );
    } finally {
      // Anything unpacked from an archive is ours to clean up, success or not.
      await resolved.dispose();
    }
  }

  static Future<NoopImportResult> _importResolvedFile(
    File file,
    Profile profile,
    DerivationEngine engine, {
    void Function(int days)? onProgress,
  }) async {
    // Rolling buffer: keeps at most the CURRENT + PREVIOUS local date of samples.
    final secs = <int, _Sec>{}; // ts(sec) → channels
    final rrTs = <double>[]; // beat end time (epoch ms)
    final rrMs = <double>[];
    String? curDate;
    final derived = <String>{}; // dates already derived + pruned out of `secs`
    var totalRows = 0, daysDone = 0, lateRows = 0, stepsBanked = 0;

    // Band step counter, ts(sec) → cumulative value, keyed by local date so a
    // run is never attributed across midnight. Flushed to `live_coverage`
    // BEFORE the date derives, since the derivation reads real steps from there.
    final stepsByDate = <String, Map<int, int>>{};

    Future<void> deriveAndPrune(String date) async {
      // Real steps must be banked BEFORE deriving: _deriveDay reads them via
      // LocalDb.liveStepsForDay/coverageWindowsOverlapping at derive time.
      final st = stepsByDate.remove(date);
      if (st != null) stepsBanked += await _flushStepCoverage(st, date);
      // Build a Substrate from everything buffered (prev + current date) and
      // derive ONLY [date]; calendarDays gives [date] its prior-evening context.
      final sub = _buildSubstrate(secs, rrTs, rrMs);
      final n = await engine.deriveImportedDays(sub, profile, {date});
      daysDone += n;
      onProgress?.call(daysDone);
      // Keep [date]'s samples as the prior evening for the NEXT date; drop older.
      secs.removeWhere((ts, _) => localDateLabel(ts) != date);
      var w = 0;
      for (var i = 0; i < rrMs.length; i++) {
        if (localDateLabel((rrTs[i] / 1000).floor()) == date) {
          rrTs[w] = rrTs[i];
          rrMs[w] = rrMs[i];
          w++;
        }
      }
      rrTs.length = w;
      rrMs.length = w;
    }

    // Column name → index, parsed from the header row. Reading by NAME (not fixed
    // position) means added/reordered columns in a future export don't misparse —
    // as long as the known column names persist. Falls back to the documented
    // default layout if a header is somehow absent.
    var col = _defaultCols;
    int? idx(String name) => col[name];
    String at(List<String> f, String name) {
      final i = idx(name);
      return (i != null && i < f.length) ? f[i] : '';
    }

    // `allowMalformed` — a CSV exported under a non-UTF-8 locale should import
    // with a mangled character in a column we don't read, not abort the whole
    // file. (This is NOT what issues #160/#199 hit; those were ZIPs, handled
    // above. It is the smaller, real second-order problem underneath them.)
    final lines = file
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    var sawHeader = false;
    String? firstLine;
    await for (final line in lines) {
      if (line.isEmpty || line.startsWith('#')) continue;
      firstLine ??= line;
      if (line.startsWith('unix_s,')) {
        sawHeader = true;
        // Header → (re)build the name→index map and skip.
        final h = line.split(',');
        col = {for (var i = 0; i < h.length; i++) h[i].trim(): i};
        continue;
      }
      final f = line.split(',');
      final ts = int.tryParse(at(f, 'unix_s'));
      if (ts == null) continue;
      final stream = at(f, 'stream');

      final date = localDateLabel(ts);
      //
      // OUT-OF-ORDER ROWS. `curDate` is a HIGH-WATER mark and must only ever
      // move forward. It used to be assigned unconditionally, so one backwards
      // timestamp rewound it; the next forward row then called
      // deriveAndPrune(<older date>), whose `secs.removeWhere(label != date)`
      // discarded every buffered sample for the newer day — silent, unbounded
      // loss with nothing surfaced.
      //
      // Now: a forward row closes out the previous date (derive + prune); a
      // backwards row for a day we have NOT derived yet is simply folded into
      // the buffer at its own timestamp (the Substrate is rebuilt sorted by ts,
      // so arrival order never mattered); and a row for a day already derived
      // is genuinely too late to use — counted in
      // [NoopImportResult.lateRows] and reported instead of being allowed to
      // wipe the current day.
      switch (decideRow(date, curDate, derived)) {
        case RowOrder.advance:
          if (curDate != null) {
            await deriveAndPrune(curDate);
            derived.add(curDate);
          }
          curDate = date;
        case RowOrder.buffer:
          break;
        case RowOrder.late:
          lateRows++;
          continue;
      }
      totalRows++;

      switch (stream) {
        case 'hr':
          final v = int.tryParse(at(f, 'hr_bpm'));
          if (v != null) (secs[ts] ??= _Sec()).hr = v;
          break;
        case 'rr':
          final v = double.tryParse(at(f, 'rr_ms'));
          if (v != null && v > 0) {
            rrTs.add(ts * 1000.0);
            rrMs.add(v);
          }
          break;
        case 'gravity':
          final s = secs[ts] ??= _Sec();
          s.ax = double.tryParse(at(f, 'grav_x'));
          s.ay = double.tryParse(at(f, 'grav_y'));
          s.az = double.tryParse(at(f, 'grav_z'));
          break;
        case 'spo2':
          final s = secs[ts] ??= _Sec();
          s.spo2Red = int.tryParse(at(f, 'spo2_red'));
          s.spo2Ir = int.tryParse(at(f, 'spo2_ir'));
          break;
        case 'skintemp':
          (secs[ts] ??= _Sec()).skinTemp = int.tryParse(at(f, 'skintemp_raw'));
          break;
        case 'steps':
          // CUMULATIVE band counter, not a per-second increment — differenced
          // into real step windows at flush time (see [stepRuns]). Kept out of
          // the Substrate: it is a real count, not a 1 Hz signal to analyse.
          final v = int.tryParse(at(f, 'step_counter'));
          if (v != null && v >= 0) (stepsByDate[date] ??= <int, int>{})[ts] = v;
          break;
        // band_sleep_state / ppghr / resp / event: intentionally not consumed —
        // see the stream inventory in the file header for why each is skipped.
        // An unknown future `stream` value also lands here and is skipped safely.
        default:
          break;
      }
    }
    // EOF — derive the final buffered date.
    if (curDate != null && secs.isNotEmpty) {
      final st = stepsByDate.remove(curDate);
      if (st != null) stepsBanked += await _flushStepCoverage(st, curDate);
      final sub = _buildSubstrate(secs, rrTs, rrMs);
      daysDone += await engine.deriveImportedDays(sub, profile, {curDate});
      onProgress?.call(daysDone);
    }
    // Any date whose steps were buffered but which never derived (e.g. a date
    // that carried ONLY a `steps` stream) still banks its real count — dropping
    // it would silently lose steps the band actually measured.
    for (final e in stepsByDate.entries) {
      stepsBanked += await _flushStepCoverage(e.value, e.key);
    }

    // A file we could read but could not USE is a failure, not a "0 days"
    // success. Without a recognised header the positional fallback silently
    // misparses (it is the pre-drift layout), and a localized or unrelated CSV
    // simply drops every row — both used to end at "NOOP: imported 0 days",
    // which reads as "the app is broken" with nothing to act on.
    if (totalRows == 0) {
      final head = firstLine ?? '';
      final preview = head.isEmpty
          ? ''
          : ' (first line: "${head.length > 80 ? '${head.substring(0, 80)}…' : head}")';
      throw ImportFormatException(
        sawHeader
            ? 'That NOOP export has a header we recognise but no rows we could '
                  'read — every row was empty or out of range.'
            : 'That file does not look like a NOOP raw-sensor export: no '
                  '"unix_s,…" header row was found$preview. In NOOP, use '
                  'Export → raw sensor CSV.',
      );
    }

    await engine.finalizeImport(profile);
    return NoopImportResult(daysDone, totalRows, lateRows, stepsBanked);
  }

  /// Build a Substrate from the buffered seconds + RR beats. Gravity / SpO₂ /
  /// skin-temp are forward-filled across seconds that lack their stream (the real
  /// 1 Hz substrate carries a value every second); HR stays 0 when absent
  /// (off-wrist semantics — meaningful, never forward-filled).
  static Substrate _buildSubstrate(
      Map<int, _Sec> secs, List<double> rrTs, List<double> rrMs) {
    final tsList = secs.keys.toList()..sort();
    final n = tsList.length;
    final tsSec = List<int>.filled(n, 0);
    final hr = List<int>.filled(n, 0);
    final ax = List<double>.filled(n, 0);
    final ay = List<double>.filled(n, 0);
    final az = List<double>.filled(n, 0);
    final spo2Red = List<int>.filled(n, 0);
    final spo2Ir = List<int>.filled(n, 0);
    final skinTemp = List<int>.filled(n, 0);

    double fax = 0, fay = 0, faz = 0; // forward-fill carry
    int fRed = 0, fIr = 0, fTemp = 0;
    for (var i = 0; i < n; i++) {
      final t = tsList[i];
      final s = secs[t]!;
      tsSec[i] = t;
      hr[i] = s.hr ?? 0;
      if (s.ax != null) {
        fax = s.ax!;
        fay = s.ay ?? fay;
        faz = s.az ?? faz;
      }
      ax[i] = fax;
      ay[i] = fay;
      az[i] = faz;
      if (s.spo2Red != null) fRed = s.spo2Red!;
      if (s.spo2Ir != null) fIr = s.spo2Ir!;
      if (s.skinTemp != null) fTemp = s.skinTemp!;
      spo2Red[i] = fRed;
      spo2Ir[i] = fIr;
      skinTemp[i] = fTemp;
    }

    // RR beats sorted by time.
    final order = List<int>.generate(rrMs.length, (i) => i)
      ..sort((a, b) => rrTs[a].compareTo(rrTs[b]));
    return Substrate(
      tsSec: tsSec,
      hr: hr,
      rrTsMs: [for (final i in order) rrTs[i]],
      rrMs: [for (final i in order) rrMs[i]],
      ax: ax,
      ay: ay,
      az: az,
      spo2Red: spo2Red,
      spo2Ir: spo2Ir,
      skinTemp: skinTemp,
      skinContact: ax.map((_) => 0).toList(),
    );
  }

  /// Maximum gap (seconds) between consecutive `step_counter` samples that is
  /// still treated as one continuous run. The #160 export samples steps every
  /// second, but drops out whenever the band is off-wrist or unsynced; a gap
  /// wider than this is a hole we know nothing about, so we refuse to span it.
  static const int stepRunMaxGapSec = 60;

  /// Turn the band's CUMULATIVE `step_counter` samples into discrete
  /// [StepRun]s that can be banked as real (non-estimated) step counts.
  ///
  /// [samples] is ts(sec) → counter value, any order. Runs are split on a gap
  /// wider than [stepRunMaxGapSec], so a 20 h hole in the export (exactly what
  /// the #160 file has) never becomes one window claiming to cover the day.
  ///
  /// Only POSITIVE deltas within a run are summed: the counter resets to 0 on a
  /// band reboot, and a negative delta is that reset, not −24,000 steps. Deltas
  /// ACROSS a run boundary are deliberately NOT counted — we cannot attribute
  /// steps to a window we have no samples for, and inventing that attribution is
  /// exactly the kind of fabrication the honesty contract forbids.
  ///
  /// A run with zero steps still yields no window: `live_coverage` exists to
  /// suppress the 1 Hz estimate over minutes the real counter already covered,
  /// and a 0-step run would suppress a real estimate while contributing nothing.
  ///
  /// [covered] lists time spans ALREADY banked in `live_coverage` (device-time
  /// seconds, inclusive). A per-second delta whose interval intersects one of
  /// them is skipped and BREAKS the run, so those steps are never banked twice.
  /// This is what makes a re-import safe in general rather than only for a
  /// byte-identical file: an exact-window check alone is defeated the moment the
  /// user exports again over a longer span (09:00-09:20 then 09:00-09:40), where
  /// the run boundary shifts, no exact window matches, and the overlap is banked
  /// a second time — measured at 3,598 steps against a true 2,399 before this.
  /// Clipping is exact, not pro-rated: we hold the counter value at every
  /// second, so the uncovered sub-intervals are summed from real deltas.
  /// It also means an imported span cannot double-count against a LIVE 100 Hz
  /// pedometer window, which shares this table.
  static List<StepRun> stepRuns(
    Map<int, int> samples, {
    List<List<int>> covered = const [],
  }) {
    if (samples.isEmpty) return const [];
    final ts = samples.keys.toList()..sort();

    // Does the half-open delta interval (a, b] touch anything already banked?
    bool isCovered(int a, int b) {
      for (final w in covered) {
        if (b > w[0] && a < w[1]) return true;
      }
      return false;
    }

    final out = <StepRun>[];
    int? runStart, runLast;
    var runSteps = 0;
    void closeRun() {
      if (runStart != null &&
          runLast != null &&
          runSteps > 0 &&
          runLast! > runStart!) {
        out.add(StepRun(runStart!, runLast!, runSteps));
      }
      runStart = null;
      runLast = null;
      runSteps = 0;
    }

    for (var i = 1; i <= ts.length; i++) {
      final bankable = i < ts.length &&
          ts[i] - ts[i - 1] <= stepRunMaxGapSec &&
          !isCovered(ts[i - 1], ts[i]);
      if (!bankable) {
        closeRun();
        continue;
      }
      runStart ??= ts[i - 1];
      final d = samples[ts[i]]! - samples[ts[i - 1]]!;
      if (d > 0) runSteps += d;
      runLast = ts[i];
    }
    return out;
  }

  /// Bank [date]'s step runs into `live_coverage` so the derivation picks them
  /// up as REAL steps (`liveStepsForDay`) — the same contract the live 100 Hz
  /// pedometer uses, so imported and live days are counted identically. These
  /// are BAND-sourced counts (the strap's own step counter), which is what makes
  /// them a real gait measurement rather than the deleted 1 Hz estimate.
  ///
  /// IDEMPOTENT BY TIME SPAN, not by exact window: `live_coverage` is an
  /// append-only SUM with no uniqueness constraint, so anything already banked
  /// over a second must not be banked again. The spans covering this batch are
  /// read back and passed to [stepRuns], which clips them out. An exact-window
  /// check is deliberately NOT used — it only catches a byte-identical
  /// re-import and silently double-counts the overlap when the user exports
  /// again over a longer span (see the note on [stepRuns]).
  ///
  /// Returns the steps actually banked (0 when the span was fully covered).
  static Future<int> _flushStepCoverage(
      Map<int, int> stepSamples, String date) async {
    if (stepSamples.isEmpty) return 0;
    final ts = stepSamples.keys.toList()..sort();
    final existing =
        await LocalDb.coverageWindowsOverlapping(ts.first, ts.last + 1);
    var banked = 0;
    for (final r in stepRuns(stepSamples, covered: existing)) {
      await LocalDb.addLiveCoverage(r.startSec, r.endSec, r.steps, date);
      banked += r.steps;
    }
    return banked;
  }

  /// String date compare 'YYYY-MM-DD' — true when [a] is strictly after [b].
  static bool _after(String a, String b) => a.compareTo(b) > 0;

  /// Where a row belongs given the import's high-water date [curDate] and the
  /// set of dates already [derived] (and therefore already pruned out of the
  /// rolling buffer).
  ///
  /// This is the whole out-of-order contract, isolated so it can be tested
  /// without a database: `curDate` only ever moves FORWARD. It used to be
  /// assigned unconditionally, so one backwards timestamp rewound it and the
  /// next forward row called `deriveAndPrune(<older date>)` — whose
  /// `secs.removeWhere(label != date)` threw away every buffered sample of the
  /// NEWER day, silently and with no error surfaced.
  static RowOrder decideRow(String date, String? curDate, Set<String> derived) {
    if (curDate == null || _after(date, curDate)) return RowOrder.advance;
    if (date == curDate) return RowOrder.buffer;
    // Older than the high-water day. Still usable as prior-evening context
    // unless its day has already been derived and pruned.
    return derived.contains(date) ? RowOrder.late : RowOrder.buffer;
  }
}
