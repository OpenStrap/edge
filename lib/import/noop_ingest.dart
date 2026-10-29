// noop_ingest.dart — the one place NOOP samples become derived days.
//
// Extracted from noop_import.dart when the `.noopbak` path arrived. Both NOOP
// sources — the raw-sensor CSV and the SQLite database inside a `.noopbak` —
// carry the SAME 1 Hz signal family, so they must land through the same rolling
// window, the same step-coverage banking and the same out-of-order contract. A
// second copy of this logic would be a second answer to "what is this day",
// which is the class of bug the single-sleep-source and single-frame-ingest
// rules exist to prevent.
//
// MEMORY. A full backup is millions of rows and a 90-day CSV is hundreds of MB,
// so nothing here accumulates: at most the CURRENT and PREVIOUS local date are
// buffered, and each date is derived and freed as the next one opens.

import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import '../compute/substrate.dart';
import '../data/db.dart';
import '../sync/reset_gate.dart';

/// One contiguous run of the band's cumulative step counter, ready to bank as a
/// `live_coverage` row: real steps over a known [startSec]..[endSec] window.
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

/// Plausible unix seconds. A timestamp outside this range is corrupt, RTC-unset
/// (the band ships with its clock unset) or milli/microsecond-scaled. One such
/// row reaching [NoopIngest.offer] either opens a date decades away — every
/// later real date is then "older" than the high-water date and strands — or
/// buffers a 1970 sample that stretches the next Substrate past the
/// 400-day `calendarDays` guard, so the real day silently derives nothing.
/// A microsecond value overflows `DateTime` outright.
const int kNoopMinPlausibleTs = 1000000000; // 2001-09-09
const int kNoopMaxPlausibleTs = 4102444800; // 2100-01-01

/// What to do with an incoming row given the import's high-water date.
/// [advance] closes out the previous date; [buffer] folds the row into the
/// current rolling window; [late] means its day was already derived + pruned,
/// so the row cannot be used.
enum RowOrder { advance, buffer, late }

/// One second's worth of the 1 Hz channels (sparse — only the streams present).
class _Sec {
  int? hr;
  double? ax, ay, az;
  int? spo2Red, spo2Ir, skinTemp;
}

/// Streams a NOOP source into derived days, one local date at a time.
///
/// Call [offer] with each sample's timestamp FIRST — it decides whether the row
/// is usable and closes out the previous date when time moves forward — then the
/// per-channel setters, then [finish] at end of input.
class NoopIngest {
  NoopIngest(this._profile, this._engine, {this.onProgress});

  /// A "delete everything" can run while an import carries on in the
  /// background after its screen is closed. Everything still buffered then
  /// belongs to the deleted store, so the import stops at its next write
  /// instead of banking it into the fresh one.
  final int _resetGen = ResetGate.generation;

  void _stopIfReset() {
    if (ResetGate.changedSince(_resetGen)) {
      throw StateError('import stopped: the app data was deleted');
    }
  }

  final Profile _profile;
  final DerivationEngine _engine;
  final void Function(int days)? onProgress;

  /// Rolling buffer: at most the CURRENT + PREVIOUS local date of samples.
  final Map<int, _Sec> _secs = {};
  final List<double> _rrTs = []; // beat end time (epoch ms)
  final List<double> _rrMs = [];

  /// Band step counter, ts(sec) → cumulative value, keyed by local date so a run
  /// is never attributed across midnight. Flushed to `live_coverage` BEFORE its
  /// date derives, because the derivation reads real steps from there.
  final Map<String, Map<int, int>> _stepsByDate = {};

  String? _curDate;
  final Set<String> _derived = {}; // dates already derived + pruned

  int rows = 0;
  int days = 0;
  int steps = 0;

  /// Samples whose local date had ALREADY been derived and pruned by the time
  /// they arrived (a genuinely out-of-order source). They cannot be folded back
  /// in, so they are counted rather than silently dropped.
  int lateRows = 0;

  /// Samples whose timestamp fell outside [kNoopMinPlausibleTs]..
  /// [kNoopMaxPlausibleTs] and were skipped.
  int implausibleRows = 0;

  /// Dates that arrived AFTER a later date had already opened, so they were
  /// folded in as context but never derived in their own right. Non-empty means
  /// the source was not time-ordered and those days are missing from the
  /// import — surfaced rather than silently dropped.
  final Set<String> _strandedDates = {};
  Set<String> get strandedDates =>
      Set.unmodifiable(_strandedDates.difference(_derived));

  /// Offer a sample at [ts] (epoch seconds). Returns false when the sample is
  /// too late to use, or its timestamp is implausible — the caller must then
  /// skip it entirely.
  Future<bool> offer(int ts) async {
    _stopIfReset();
    if (ts < kNoopMinPlausibleTs || ts > kNoopMaxPlausibleTs) {
      implausibleRows++;
      return false;
    }
    final date = localDateLabel(ts);
    switch (decideRow(date, _curDate, _derived)) {
      case RowOrder.advance:
        final prev = _curDate;
        if (prev != null) {
          await _deriveAndPrune(prev);
          _derived.add(prev);
          // The retained prior evening is only prior if it is ADJACENT. Across
          // a gap — a band left in a drawer, two export ranges stitched
          // together — the buffer would otherwise hand the next day a Substrate
          // spanning the whole gap, and `calendarDays` walks that span a day at
          // a time under a 400-iteration guard: past ~400 days it never reaches
          // the target date, `deriveImportedDays` returns 0, and the day is
          // silently missing from an import that reported success.
          if (!_isDayAfter(prev, date)) {
            _secs.clear();
            _rrTs.clear();
            _rrMs.clear();
          }
        }
        _curDate = date;
        _strandedDates.remove(date);
      case RowOrder.buffer:
        // Older than the high-water date and not yet derived: usable as
        // prior-evening context, but this date will never become the high-water
        // date itself, so it never derives on its own and its samples are
        // pruned once the current date does. Record it — a source that is not
        // time-ordered loses whole days here, and the loss used to be silent.
        if (date != _curDate) _strandedDates.add(date);
        break;
      case RowOrder.late:
        lateRows++;
        return false;
    }
    rows++;
    return true;
  }

  // Same physiological gate as the band decode. A NOOP row is otherwise taken
  // at face value, so an off-wrist sentinel (255) or a 1 bpm glitch would land
  // in max HR, strain and the resting-HR window for imported days only. 0 keeps
  // the second (and its accel / SpO2 context) while saying "no usable HR".
  void hr(int ts, int bpm) =>
      (_secs[ts] ??= _Sec()).hr = plausibleHrOrNull(bpm) ?? 0;

  void rr(int ts, double ms) {
    // FINITE and positive. `ms <= 0` alone lets NaN through (it fails every
    // comparison) and `!(ms > 0)` alone lets infinity through; either one
    // propagates into the Substrate and poisons the whole day's HRV rather than
    // costing a single interval. Both are reachable: a CSV column can spell
    // `NaN`, and a SQLite REAL can hold either outright.
    if (!ms.isFinite || ms <= 0) return;
    // Then the band path's 250-2400 ms bound: outside it the interval is a
    // missed or doubled detection, not a rhythm, and one of them is enough to
    // move RMSSD / SDNN / pNNx for the whole imported night.
    final rr = plausibleRrOrNull(ms);
    if (rr == null) return;
    _rrTs.add(ts * 1000.0);
    _rrMs.add(rr);
  }

  void gravity(int ts, double? x, double? y, double? z) {
    final s = _secs[ts] ??= _Sec();
    s.ax = x;
    s.ay = y;
    s.az = z;
  }

  void spo2(int ts, int? red, int? ir) {
    final s = _secs[ts] ??= _Sec();
    s.spo2Red = red;
    s.spo2Ir = ir;
  }

  void skinTemp(int ts, int? raw) => (_secs[ts] ??= _Sec()).skinTemp = raw;

  /// A CUMULATIVE counter reading, not a per-second increment — differenced into
  /// real step windows at flush time (see [stepRuns]). Deliberately kept out of
  /// the Substrate: it is a real count, not a 1 Hz signal to analyse.
  void stepCounter(int ts, int counter) {
    if (counter < 0) return;
    (_stepsByDate[localDateLabel(ts)] ??= <int, int>{})[ts] = counter;
  }

  /// End of input: derive the last buffered date, bank any steps whose date
  /// never derived, and roll the import's day rollups forward.
  Future<void> finish() async {
    _stopIfReset();
    final last = _curDate;
    // `_secs` OR the RR buffer: `rr()` is the one channel that creates no
    // per-second entry, so a final date carrying only beats would otherwise be
    // buffered and then dropped without ever deriving.
    if (last != null && (_secs.isNotEmpty || _rrMs.isNotEmpty)) {
      final st = _stepsByDate.remove(last);
      if (st != null) steps += await flushStepCoverage(st, last);
      final sub = _buildSubstrate(_secs, _rrTs, _rrMs);
      days += await _engine.deriveImportedDays(sub, _profile, {last},
          resetGeneration: _resetGen);
      onProgress?.call(days);
    }
    // A date that carried ONLY a step counter still banks its real count —
    // dropping it would lose steps the band actually measured.
    for (final e in _stepsByDate.entries) {
      _stopIfReset();
      steps += await flushStepCoverage(e.value, e.key);
    }
    _stepsByDate.clear();
    _stopIfReset();
    await _engine.finalizeImport(_profile);
  }

  Future<void> _deriveAndPrune(String date) async {
    _stopIfReset();
    // Real steps must be banked BEFORE deriving: the derivation reads them via
    // LocalDb.liveStepsForDay / coverageWindowsOverlapping at derive time.
    final st = _stepsByDate.remove(date);
    if (st != null) steps += await flushStepCoverage(st, date);
    // Build a Substrate from everything buffered (prev + current date) and
    // derive ONLY [date]; the prior evening gives a sleep that started before
    // midnight its context.
    final sub = _buildSubstrate(_secs, _rrTs, _rrMs);
    days += await _engine.deriveImportedDays(sub, _profile, {date},
        resetGeneration: _resetGen);
    onProgress?.call(days);
    // Keep [date]'s samples as the prior evening for the NEXT date; drop older.
    _secs.removeWhere((ts, _) => localDateLabel(ts) != date);
    var w = 0;
    for (var i = 0; i < _rrMs.length; i++) {
      if (localDateLabel((_rrTs[i] / 1000).floor()) == date) {
        _rrTs[w] = _rrTs[i];
        _rrMs[w] = _rrMs[i];
        w++;
      }
    }
    _rrTs.length = w;
    _rrMs.length = w;
  }

  /// True when [next] is the calendar day immediately after [prev]. Built
  /// through DateTime so a month, year or DST boundary is handled by the
  /// calendar rather than by string arithmetic.
  static bool _isDayAfter(String prev, String next) {
    final p = DateTime.tryParse(prev), n = DateTime.tryParse(next);
    if (p == null || n == null) return false;
    final after = DateTime(p.year, p.month, p.day + 1);
    return after.year == n.year && after.month == n.month && after.day == n.day;
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
  /// next forward row derived the OLDER date — whose prune threw away every
  /// buffered sample of the newer day, silently and with no error surfaced.
  static RowOrder decideRow(String date, String? curDate, Set<String> derived) {
    if (curDate == null || _after(date, curDate)) return RowOrder.advance;
    if (date == curDate) return RowOrder.buffer;
    // Older than the high-water day. Still usable as prior-evening context
    // unless its day has already been derived and pruned.
    return derived.contains(date) ? RowOrder.late : RowOrder.buffer;
  }

  /// Build a Substrate from the buffered seconds + RR beats. Gravity / SpO₂ /
  /// skin-temp are forward-filled across seconds that lack their stream (the
  /// real 1 Hz substrate carries a value every second); HR stays 0 when absent
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
      // Each axis carries on its own. Gating y and z behind x meant a row that
      // reported only y or z left all three on the previous carry — silently
      // wrong rather than merely incomplete.
      if (s.ax != null) fax = s.ax!;
      if (s.ay != null) fay = s.ay!;
      if (s.az != null) faz = s.az!;
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

    final order = rrOrder(rrTs);
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

  /// Indices of the buffered RR beats in time order.
  ///
  /// NOOP stamps beats with whole seconds, so several beats routinely share one
  /// timestamp and the sort is mostly ties. Those beats already arrive in the
  /// order the strap detected them, and that order is the interval series:
  /// swapping two of them invents successive differences the heart never made
  /// (RMSSD, pNN50, ectopic rejection, PRSA). `List.sort` is not stable past a
  /// few dozen elements, so ties fall back to buffer position explicitly.
  static List<int> rrOrder(List<double> rrTs) =>
      List<int>.generate(rrTs.length, (i) => i)
        ..sort((a, b) {
          final c = rrTs[a].compareTo(rrTs[b]);
          return c != 0 ? c : a.compareTo(b);
        });

  /// Maximum gap (seconds) between consecutive step-counter samples that is
  /// still treated as one continuous run. Both sources sample every second but
  /// drop out whenever the band is off-wrist or unsynced; a gap wider than this
  /// is a hole we know nothing about, so we refuse to span it.
  static const int stepRunMaxGapSec = 60;

  /// Turn the band's CUMULATIVE step counter into discrete [StepRun]s that can
  /// be banked as real (non-estimated) step counts.
  ///
  /// [samples] is ts(sec) → counter value, any order. Runs are split on a gap
  /// wider than [stepRunMaxGapSec], so a 20 h hole in a source never becomes one
  /// window claiming to cover the day.
  ///
  /// Only POSITIVE deltas within a run are summed: the counter resets to 0 on a
  /// band reboot, and a negative delta is that reset, not −24,000 steps. Deltas
  /// ACROSS a run boundary are deliberately NOT counted — we cannot attribute
  /// steps to a window we have no samples for.
  ///
  /// A run with zero steps yields no window: `live_coverage` exists to suppress
  /// the 1 Hz estimate over minutes the real counter already covered, and a
  /// 0-step run would suppress a real estimate while contributing nothing.
  ///
  /// [covered] lists spans ALREADY banked in `live_coverage` (device-time
  /// seconds, inclusive). A per-second delta whose interval intersects one of
  /// them is skipped and BREAKS the run, so those steps are never banked twice.
  /// This is what makes a re-import safe in general rather than only for a
  /// byte-identical file: an exact-window check alone is defeated the moment the
  /// user exports again over a longer span (09:00-09:20 then 09:00-09:40), where
  /// the run boundary shifts, no exact window matches, and the overlap is banked
  /// a second time — measured at 3,598 steps against a true 2,399 before this.
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
  /// them a real gait measurement rather than an estimate.
  ///
  /// IDEMPOTENT BY TIME SPAN, not by exact window: `live_coverage` is an
  /// append-only SUM with no uniqueness constraint, so anything already banked
  /// over a second must not be banked again. The spans covering this batch are
  /// read back and passed to [stepRuns], which clips them out.
  ///
  /// Returns the steps actually banked (0 when the span was fully covered).
  static Future<int> flushStepCoverage(
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
}
