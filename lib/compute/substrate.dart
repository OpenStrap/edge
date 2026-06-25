// substrate.dart — the ONE decoded form of the raw R24 ledger (ARCHITECTURE_V2
// invariant 1 "Substrate-first" + the canonical Substrate schema).
//
// Raw R24 (1 Hz) is the canonical, replayable ledger. This file is the SINGLE
// decode point: `decodeSubstrate` turns a list of raw frame hexes into one
// continuous, time-sorted `Substrate`. Every downstream consumer (segmentation,
// per-day coordinator, every metric) slices THIS object — nothing decodes raw a
// second time.
//
// It also owns the V2 DAY MODEL: `physiologicalDays` walks the substrate and
// returns wake-to-wake `PhysioDay`s anchored on each detected WAKE (sleep
// offset), with a noon-to-noon fallback so a day always exists when there's data.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

/// The decoded 1 Hz substrate — the only decoded form (ARCHITECTURE_V2).
///
/// All HR/accel/ADC arrays are parallel and 1:1 with [tsSec] (one sample per
/// retained R24 record, sorted ascending by record time). The RR arrays are
/// SPARSE (~0–4 beats/record) with their own beat-end timestamps.
class Substrate {
  /// Epoch seconds, 1 Hz, sorted ascending. One entry per R24 record.
  final List<int> tsSec;

  /// 1 Hz HR (bpm). 0 = off-skin (never bradycardia). Parallel to [tsSec].
  final List<int> hr;

  /// Beat-to-beat RR: interval end time (epoch ms) + interval (ms). Sparse.
  final List<double> rrTsMs;
  final List<double> rrMs;

  /// 1 Hz tri-axial accel (gravity vector, g). Parallel to [tsSec].
  final List<double> ax;
  final List<double> ay;
  final List<double> az;

  /// Relative-ADC channels (raw counts; NO absolute units). Parallel to [tsSec].
  final List<int> spo2Red;
  final List<int> spo2Ir;
  final List<int> skinTemp;

  const Substrate({
    required this.tsSec,
    required this.hr,
    required this.rrTsMs,
    required this.rrMs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.spo2Red,
    required this.spo2Ir,
    required this.skinTemp,
  });

  static const Substrate empty = Substrate(
    tsSec: [],
    hr: [],
    rrTsMs: [],
    rrMs: [],
    ax: [],
    ay: [],
    az: [],
    spo2Red: [],
    spo2Ir: [],
    skinTemp: [],
  );

  int get length => tsSec.length;
  bool get isEmpty => tsSec.isEmpty;
  int? get firstTs => isEmpty ? null : tsSec.first;
  int? get lastTs => isEmpty ? null : tsSec.last;

  /// 1 Hz accel samples (one gravity vector per second) for the analytics family.
  List<ana.AccelSample> accelSamples() => <ana.AccelSample>[
        for (var i = 0; i < tsSec.length; i++)
          ana.AccelSample(tsSec[i] * 1000.0, ax[i], ay[i], az[i])
      ];

  /// 1 Hz HR as doubles (0 = off-skin). Parallel to [tsSec] / [accelSamples].
  List<double> hr1hz() => [for (final h in hr) h.toDouble()];

  /// Slice to the half-open window [startSec, endSec) by record time. Returns a
  /// new Substrate with the 1 Hz arrays sliced and the sparse RR arrays filtered
  /// to beats whose end time falls in the window.
  Substrate slice(int startSec, int endSec) {
    if (isEmpty) return Substrate.empty;
    final lo = _lowerBound(tsSec, startSec);
    final hi = _lowerBound(tsSec, endSec); // exclusive
    if (hi <= lo) {
      // No 1 Hz samples — still slice RR by time so e.g. a workout window works.
      return _emptyOneHz(startSec, endSec);
    }
    final rr = _filterRr(startSec, endSec);
    return Substrate(
      tsSec: tsSec.sublist(lo, hi),
      hr: hr.sublist(lo, hi),
      ax: ax.sublist(lo, hi),
      ay: ay.sublist(lo, hi),
      az: az.sublist(lo, hi),
      spo2Red: spo2Red.sublist(lo, hi),
      spo2Ir: spo2Ir.sublist(lo, hi),
      skinTemp: skinTemp.sublist(lo, hi),
      rrTsMs: rr.$1,
      rrMs: rr.$2,
    );
  }

  /// Slice to a window expressed by 1 Hz INDEX range [loIdx, hiIdx) into THIS
  /// substrate's arrays (used to slice the day to the segmentSleep window, whose
  /// onset/offset indices index the day-sliced arrays).
  Substrate sliceIdx(int loIdx, int hiIdx) {
    final lo = loIdx.clamp(0, length);
    final hi = hiIdx.clamp(lo, length);
    if (hi <= lo) return Substrate.empty;
    final startSec = tsSec[lo];
    final endSec = tsSec[hi - 1] + 1; // inclusive of last second
    final rr = _filterRr(startSec, endSec);
    return Substrate(
      tsSec: tsSec.sublist(lo, hi),
      hr: hr.sublist(lo, hi),
      ax: ax.sublist(lo, hi),
      ay: ay.sublist(lo, hi),
      az: az.sublist(lo, hi),
      spo2Red: spo2Red.sublist(lo, hi),
      spo2Ir: spo2Ir.sublist(lo, hi),
      skinTemp: skinTemp.sublist(lo, hi),
      rrTsMs: rr.$1,
      rrMs: rr.$2,
    );
  }

  Substrate _emptyOneHz(int startSec, int endSec) {
    final rr = _filterRr(startSec, endSec);
    return Substrate(
      tsSec: const [],
      hr: const [],
      ax: const [],
      ay: const [],
      az: const [],
      spo2Red: const [],
      spo2Ir: const [],
      skinTemp: const [],
      rrTsMs: rr.$1,
      rrMs: rr.$2,
    );
  }

  /// Filter THIS substrate's sparse RR to beats whose end time (epoch ms) falls
  /// in [startSec, endSec). Returns (rrTsMs, rrMs).
  (List<double>, List<double>) _filterRr(int startSec, int endSec) {
    final loMs = startSec * 1000.0, hiMs = endSec * 1000.0;
    final ts = <double>[], rr = <double>[];
    for (var i = 0; i < rrMs.length; i++) {
      final t = rrTsMs[i];
      if (t >= loMs && t < hiMs) {
        ts.add(t);
        rr.add(rrMs[i]);
      }
    }
    return (ts, rr);
  }
}

/// Decode the WHOLE retained raw ledger into one continuous, time-sorted
/// Substrate. THE single decode point.
///
/// Each frame is parsed as a type-24 (R24) historical record (the 1 Hz
/// substrate). Live RR-bearing frames (0x28 / R10), if any leaked into the
/// store, contribute their beats only. Records are sorted by record time so the
/// substrate is monotonic regardless of decode/insert order.
Substrate decodeSubstrate(List<String> hexes) {
  // Collect per-record tuples, then sort by ts to guarantee monotonicity.
  final recs = <_Rec>[];
  final looseRr = <_Beat>[]; // RR-only live frames
  for (final hex in hexes) {
    proto.R24? r;
    try {
      r = proto.parseR24(proto.hexToBytes(hex));
    } catch (_) {
      r = null;
    }
    if (r != null && r.tsEpoch > 0) {
      recs.add(_Rec(r));
      continue;
    }
    final live = proto.realtimeRr(hex);
    if (live != null && live.ts > 0) {
      for (final v in live.rrMs) {
        if (v > 0) looseRr.add(_Beat(live.ts * 1000.0, v.toDouble()));
      }
    }
  }
  recs.sort((a, b) => a.ts.compareTo(b.ts));

  final n = recs.length;
  final tsSec = List<int>.filled(n, 0);
  final hr = List<int>.filled(n, 0);
  final ax = List<double>.filled(n, 0);
  final ay = List<double>.filled(n, 0);
  final az = List<double>.filled(n, 0);
  final spo2Red = List<int>.filled(n, 0);
  final spo2Ir = List<int>.filled(n, 0);
  final skinTemp = List<int>.filled(n, 0);
  final rrTsMs = <double>[], rrMs = <double>[];

  for (var i = 0; i < n; i++) {
    final r = recs[i].r;
    tsSec[i] = r.tsEpoch;
    hr[i] = r.hr;
    if (r.accelG.length == 3) {
      ax[i] = r.accelG[0];
      ay[i] = r.accelG[1];
      az[i] = r.accelG[2];
    }
    spo2Red[i] = r.spo2RedRaw;
    spo2Ir[i] = r.spo2IrRaw;
    skinTemp[i] = r.skinTempRaw;
    // RR beats: anchored at the record second (epoch ms). Beats within a record
    // share its second; time order is preserved by the record sort above.
    final t = r.tsEpoch * 1000.0;
    for (final rr in r.rrIntervalsMs) {
      if (rr > 0) {
        rrMs.add(rr.toDouble());
        rrTsMs.add(t);
      }
    }
  }
  // Fold any loose live RR in, then re-sort the RR pair by time.
  if (looseRr.isNotEmpty) {
    for (final b in looseRr) {
      rrTsMs.add(b.ts);
      rrMs.add(b.rr);
    }
    final order = List<int>.generate(rrTsMs.length, (i) => i)
      ..sort((a, b) => rrTsMs[a].compareTo(rrTsMs[b]));
    final st = [for (final i in order) rrTsMs[i]];
    final sr = [for (final i in order) rrMs[i]];
    rrTsMs
      ..clear()
      ..addAll(st);
    rrMs
      ..clear()
      ..addAll(sr);
  }

  return Substrate(
    tsSec: tsSec,
    hr: hr,
    rrTsMs: rrTsMs,
    rrMs: rrMs,
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: spo2Red,
    spo2Ir: spo2Ir,
    skinTemp: skinTemp,
  );
}

class _Rec {
  final proto.R24 r;
  final int ts;
  _Rec(this.r) : ts = r.tsEpoch;
}

class _Beat {
  final double ts;
  final double rr;
  _Beat(this.ts, this.rr);
}

// ── V2 DAY MODEL: wake-to-wake physiological days ───────────────────────────

/// One physiological day = wake → next wake (ARCHITECTURE_V2 frozen day model).
///
/// A day is anchored on the WAKE (sleep offset) that opens it: the sleep that
/// ends at this wake closes the PRIOR day and its recovery is attributed HERE.
/// So a day carries the sleep window whose offset == this day's start wake.
class PhysioDay {
  /// Local-date label of the day's anchoring wake (YYYY-MM-DD). Display + key.
  final String date;

  /// Day container bounds (epoch seconds), half-open [startSec, endSec).
  final int startSec;
  final int endSec;

  /// The sleep segmentation for THIS day (the sleep whose wake anchors the day).
  /// `present == false` when no qualifying sleep (fallback container day).
  final ana.SleepSegmentation sleep;

  /// Index range [sleepLoIdx, sleepHiIdx) of the sleep window INTO the day-sliced
  /// substrate arrays (so the coordinator can slice the substrate to the sleep
  /// window for HRV/RHR/recovery). Both 0 when no sleep.
  final int sleepLoIdx;
  final int sleepHiIdx;

  /// 0..1 day confidence (sleep confidence, or low for a fallback container).
  final double confidence;

  /// Honest flags (e.g. LOW_CONFIDENCE_RECOVERY for fallback days).
  final List<String> flags;

  const PhysioDay({
    required this.date,
    required this.startSec,
    required this.endSec,
    required this.sleep,
    required this.sleepLoIdx,
    required this.sleepHiIdx,
    required this.confidence,
    required this.flags,
  });

  bool get hasSleep => sleep.present;
}

/// Local YYYY-MM-DD label for an epoch-second instant.
String localDateLabel(int epochSec) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: false);
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// Walk the substrate and segment it into wake-to-wake physiological days.
///
/// Iterative walk: from a cursor, detect the next sleep window (scanning a
/// forward horizon), anchor a day on its WAKE (offset), advance the cursor past
/// that wake, repeat. A day's container spans from its anchoring wake to the
/// next wake (or end of data). The sleep attributed to a day is the one whose
/// OFFSET equals the day's start wake (recovery follows the wake into the day).
///
/// FALLBACK: when no sleep is found within a ~36 h horizon from the cursor, emit
/// a noon-to-noon container day flagged LOW_CONFIDENCE_RECOVERY so a day always
/// exists when there is data.
///
/// Single-night data yields exactly ONE physiological day (the day of the wake).
List<PhysioDay> physiologicalDays(Substrate sub) {
  if (sub.isEmpty) return const [];
  final accel = sub.accelSamples();
  final hr = sub.hr1hz();

  final days = <PhysioDay>[];
  final dataStart = sub.tsSec.first;
  final dataEnd = sub.tsSec.last + 1;
  const horizon = 36 * 3600; // ~36 h fallback span

  var cursorIdx = 0; // index into sub arrays where the current search begins
  var guard = 0;

  while (cursorIdx < sub.length && guard++ < 64) {
    final searchStartSec = sub.tsSec[cursorIdx];
    final searchEndSec = math.min(dataEnd, searchStartSec + horizon);
    final hiIdx = _lowerBound(sub.tsSec, searchEndSec);

    // Daytime HR baseline for the dip-consensus: HR before the search window
    // (the most recent waking period). Falls back to whole-history valid HR.
    final base = <double>[
      for (var i = 0; i < cursorIdx; i++)
        if (hr[i] > 0) hr[i]
    ];
    final hrBaseline = base.length >= 60 ? base : null;

    final segAccel = accel.sublist(cursorIdx, hiIdx);
    final segHr = hr.sublist(cursorIdx, hiIdx);
    final seg = ana.segmentSleep(segAccel, segHr, hrBaseline: hrBaseline);

    if (seg.present && seg.window != null) {
      final w = seg.window!;
      // Window indices are into the SEARCH slice; rebase to the full substrate.
      final loIdx = cursorIdx + w.onsetIdx;
      final hiWin = cursorIdx + w.offsetIdx;
      final wakeSec = sub.tsSec[(hiWin - 1).clamp(0, sub.length - 1)] + 1;

      // Day container starts at this wake. Its end is the NEXT wake — but we
      // don't know it yet, so we provisionally extend to data end and trim when
      // the next day is found.
      days.add(PhysioDay(
        date: localDateLabel(wakeSec),
        startSec: wakeSec,
        endSec: dataEnd,
        sleep: seg,
        sleepLoIdx: loIdx,
        sleepHiIdx: hiWin,
        confidence: seg.confidence,
        flags: const [],
      ));

      // Advance past this wake to look for the next sleep.
      final nextIdx = _lowerBound(sub.tsSec, wakeSec);
      cursorIdx = nextIdx > cursorIdx ? nextIdx : cursorIdx + 1;
    } else {
      // No sleep found from the cursor through the horizon. If we ALREADY have a
      // day, this trailing wake-span is just the tail of the current day (the
      // user simply hasn't slept again) — extend the last day to data end and
      // stop; do NOT spawn a spurious fallback day. Only when NO day exists at
      // all (we never found any sleep) do we emit a noon-to-noon fallback
      // container flagged LOW_CONFIDENCE_RECOVERY so a day always exists.
      if (days.isNotEmpty) {
        final last = days.last;
        days[days.length - 1] = PhysioDay(
          date: last.date,
          startSec: last.startSec,
          endSec: dataEnd,
          sleep: last.sleep,
          sleepLoIdx: last.sleepLoIdx,
          sleepHiIdx: last.sleepHiIdx,
          confidence: last.confidence,
          flags: last.flags,
        );
        break;
      }
      final noon = _noonOnOrAfter(searchStartSec);
      final endNoon = math.min(dataEnd, noon + 24 * 3600);
      days.add(PhysioDay(
        date: localDateLabel(searchStartSec),
        startSec: searchStartSec,
        endSec: endNoon,
        sleep: ana.SleepSegmentation.absent,
        sleepLoIdx: 0,
        sleepHiIdx: 0,
        confidence: 0.2,
        flags: const ['LOW_CONFIDENCE_RECOVERY'],
      ));
      final nextIdx = _lowerBound(sub.tsSec, endNoon);
      cursorIdx = nextIdx > cursorIdx ? nextIdx : sub.length;
    }
  }

  // Trim each day's container end to the next day's start so containers tile.
  for (var i = 0; i < days.length - 1; i++) {
    final d = days[i];
    final next = days[i + 1];
    if (next.startSec < d.endSec && next.startSec > d.startSec) {
      days[i] = PhysioDay(
        date: d.date,
        startSec: d.startSec,
        endSec: next.startSec,
        sleep: d.sleep,
        sleepLoIdx: d.sleepLoIdx,
        sleepHiIdx: d.sleepHiIdx,
        confidence: d.confidence,
        flags: d.flags,
      );
    }
  }

  // If there's data BEFORE the first day's wake (the leading sleep's own night),
  // that pre-wake span has no anchoring wake of its own — it belongs to the day
  // it wakes into, which IS days[0]. So we extend days[0] backward to data start
  // so the sleep window (which precedes the wake) is inside the day's container.
  if (days.isNotEmpty && days.first.startSec > dataStart) {
    final d = days.first;
    days[0] = PhysioDay(
      date: d.date,
      startSec: dataStart,
      endSec: d.endSec,
      sleep: d.sleep,
      sleepLoIdx: d.sleepLoIdx,
      sleepHiIdx: d.sleepHiIdx,
      confidence: d.confidence,
      flags: d.flags,
    );
  }

  return days;
}

/// Local noon (epoch sec) at or after [epochSec].
int _noonOnOrAfter(int epochSec) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: false);
  var noon = DateTime(d.year, d.month, d.day, 12);
  if (noon.millisecondsSinceEpoch ~/ 1000 < epochSec) {
    noon = noon.add(const Duration(days: 1));
  }
  return noon.millisecondsSinceEpoch ~/ 1000;
}

/// First index i in sorted [xs] with xs[i] >= target (std lower_bound).
int _lowerBound(List<int> xs, int target) {
  var lo = 0, hi = xs.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (xs[mid] < target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
