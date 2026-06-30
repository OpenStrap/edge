// substrate.dart — the ONE decoded form of the raw R24 ledger (ARCHITECTURE_V2
// invariant 1 "Substrate-first" + the canonical Substrate schema).
//
// Raw R24 (1 Hz) is the canonical, replayable ledger. This file is the SINGLE
// decode point: `decodeSubstrate` turns a list of raw frame hexes into one
// continuous, time-sorted `Substrate`. Every downstream consumer (segmentation,
// per-day coordinator, every metric) slices THIS object — nothing decodes raw a
// second time.
//
// It also owns the DAY MODEL: `calendarDays` walks the substrate and
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

  Map<String, dynamic> toJson() => {
        'ts_sec': tsSec,
        'hr': hr,
        'rr_ts_ms': rrTsMs,
        'rr_ms': rrMs,
        'ax': ax,
        'ay': ay,
        'az': az,
        'spo2_red': spo2Red,
        'spo2_ir': spo2Ir,
        'skin_temp': skinTemp,
      };

  static Substrate fromJson(Map<String, dynamic> m) {
    List<int> ints(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    List<double> dbls(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
    return Substrate(
      tsSec: ints('ts_sec'),
      hr: ints('hr'),
      rrTsMs: dbls('rr_ts_ms'),
      rrMs: dbls('rr_ms'),
      ax: dbls('ax'),
      ay: dbls('ay'),
      az: dbls('az'),
      spo2Red: ints('spo2_red'),
      spo2Ir: ints('spo2_ir'),
      skinTemp: ints('skin_temp'),
    );
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

  /// Where this day's sleep WINDOW came from:
  ///   'auto'          — accel-led van Hees detection (the normal path)
  ///   'auto_fallback' — HR-led fallback (van Hees found nothing); LOW confidence,
  ///                     surface a "is this right?" prompt
  ///   'manual'        — user typed the window (Approach 1)
  ///   'confirmed'     — user accepted the fallback's proposal
  ///   'none'          — no sleep at all
  final String sleepSource;

  const PhysioDay({
    required this.date,
    required this.startSec,
    required this.endSec,
    required this.sleep,
    required this.sleepLoIdx,
    required this.sleepHiIdx,
    required this.confidence,
    required this.flags,
    this.sleepSource = 'auto',
  });

  bool get hasSleep => sleep.present;
}

/// A user-asserted sleep window for one day — manual entry (Approach 1) or a
/// confirmation of the HR-led fallback (Approach 2). Passed into [calendarDays]
/// so it overrides auto detection for the matching [dayId].
class SleepWindowOverride {
  final String dayId;
  final int onsetSec;
  final int offsetSec;
  final String source; // 'manual' | 'confirmed'

  const SleepWindowOverride({
    required this.dayId,
    required this.onsetSec,
    required this.offsetSec,
    required this.source,
  });
}

/// Local YYYY-MM-DD label for an epoch-second instant.
String localDateLabel(int epochSec) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: false);
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// Split the substrate into CALENDAR days (local midnight → next local midnight).
///
/// Each day owns its 24 h of data. A day's SLEEP is the main sleep that ENDED
/// that morning (last night's sleep): we search the nocturnal window (~previous
/// 18:00 → this noon) and attribute the detected window ONLY if its WAKE
/// (offset) lands inside this calendar day. So recovery attributes to the day
/// you woke INTO and strain to that day's waking activity — "recovery for the
/// last 24 h." Deterministic midnight boundaries: no wake-scan day model, no
/// search horizon, no back-extension. A day with no detected morning sleep is
/// still emitted (flag NO_SLEEP_DETECTED) so a calendar day always exists.
///
/// A sleep that crosses midnight is attributed to the day it ENDS; its window
/// indices (sleepLoIdx/Hi) point into the full substrate, so the coordinator
/// still slices the whole window for HRV/RHR/recovery regardless of the boundary.
List<PhysioDay> calendarDays(Substrate sub, {SleepWindowOverride? override}) {
  if (sub.isEmpty) return const [];
  final accel = sub.accelSamples();
  final hr = sub.hr1hz();
  final dataStart = sub.tsSec.first;
  final dataEnd = sub.tsSec.last + 1;

  final days = <PhysioDay>[];
  final sleepHistory = <({int startSec, int endSec, String dayKey})>[];
  var dayStart = _localMidnight(dataStart);
  var guard = 0;
  while (dayStart < dataEnd && guard++ < 400) {
    final dayEnd = _nextLocalMidnight(dayStart);
    final cs = math.max(dayStart, dataStart);
    final ce = math.min(dayEnd, dataEnd);
    if (ce <= cs) {
      dayStart = dayEnd;
      continue;
    }

    // The main sleep that ENDS in this calendar day: search from the previous
    // local noon through this local midnight, then let the sleep selector pick
    // the overnight main block from any naps / split fragments it sees. The old
    // prev-18:00 → noon window missed late wakes and forced the detector to act
    // like there was only one candidate sleep. The richer selector needs the
    // full set of sessions that can legitimately end today.
    final searchStart = math.max(dataStart, dayStart - 12 * 3600);
    final searchEnd = math.min(dataEnd, dayEnd);
    final loS = _lowerBound(sub.tsSec, searchStart);
    final hiS = _lowerBound(sub.tsSec, searchEnd);

    var seg = ana.SleepSegmentation.absent;
    var sleepLo = 0, sleepHi = 0;
    var sleepSource = 'none';
    final dayLabel = localDateLabel(dayStart);
    // Does the user have an override (manual / confirmed) for THIS day?
    final ov =
        (override != null && override.dayId == dayLabel) ? override : null;
    if (hiS - loS >= 600 || ov != null) {
      final habitualMidsleepSec = ana.habitualMidsleepSecFromHistory(
        sleepHistory,
        tzOffsetSeconds: DateTime.now().timeZoneOffset.inSeconds,
      );
      // Daytime HR baseline = valid HR before the nocturnal search window.
      final base = <double>[for (var i = 0; i < loS; i++) if (hr[i] > 0) hr[i]];
      final hrBaseline = base.length >= 60 ? base : null;
      final accelSlice = accel.sublist(loS, hiS);
      final hrSlice = hr.sublist(loS, hiS);
      // RR beats within the search slice (absolute ms) for RMSSD-based staging.
      final s0 = sub.tsSec[loS.clamp(0, sub.length - 1)] * 1000;
      final s1 = sub.tsSec[(hiS - 1).clamp(0, sub.length - 1)] * 1000;
      final rrMsSeg = <double>[];
      final rrTsSeg = <double>[];
      for (var k = 0; k < sub.rrMs.length; k++) {
        final t = sub.rrTsMs[k];
        if (t >= s0 && t <= s1) {
          rrMsSeg.add(sub.rrMs[k]);
          rrTsSeg.add(t);
        }
      }

      ana.SleepSegmentation s;
      String src;
      if (ov != null) {
        // The user's word — force the window, skip detection entirely.
        s = ana.segmentSleep(
          accelSlice,
          hrSlice,
          hrBaseline: hrBaseline,
          rrMs: rrMsSeg,
          rrTsMs: rrTsSeg,
          forcedWindow: (onsetSec: ov.onsetSec, offsetSec: ov.offsetSec),
        );
        src = ov.source; // 'manual' | 'confirmed'
      } else {
        s = ana.segmentSleep(
          accelSlice,
          hrSlice,
          hrBaseline: hrBaseline,
          rrMs: rrMsSeg,
          rrTsMs: rrTsSeg,
          habitualMidsleepSec: habitualMidsleepSec,
        );
        src = 'auto';
        if (!s.present) {
          // Approach 2: accel-led detection found nothing → HR-led fallback.
          // Propose the longest sustained nocturnal HR dip, then STAGE it via the
          // forced-window path. Marked low-confidence for a "is this right?" prompt.
          final tsSlice = [for (var i = loS; i < hiS; i++) sub.tsSec[i]];
          final cand =
              ana.hrLedSleepWindow(hrSlice, tsSlice, hrBaseline: hrBaseline);
          if (cand != null) {
            final s2 = ana.segmentSleep(
              accelSlice,
              hrSlice,
              hrBaseline: hrBaseline,
              rrMs: rrMsSeg,
              rrTsMs: rrTsSeg,
              forcedWindow:
                  (onsetSec: cand.onsetSec, offsetSec: cand.offsetSec),
            );
            if (s2.present) {
              s = s2;
              src = 'auto_fallback';
            }
          }
        }
      }

      if (s.present && s.window != null) {
        final offSec = s.window!.offsetMs! ~/ 1000;
        // Auto/fallback: attribute only if the wake lands in this calendar day.
        // Manual/confirmed: trust the user — attribute to the day they set it on.
        final userSet = ov != null;
        if (userSet || (offSec >= dayStart && offSec < dayEnd)) {
          seg = s;
          sleepLo = loS + s.window!.onsetIdx;
          sleepHi = loS + s.window!.offsetIdx;
          sleepSource = src;
          final onsetSec = s.window!.onsetMs == null
              ? 0
              : (s.window!.onsetMs! / 1000).round();
          if (onsetSec > 0 && offSec > onsetSec) {
            sleepHistory.add((
              startSec: onsetSec,
              endSec: offSec,
              dayKey: dayLabel,
            ));
          }
        }
      }
    }

    days.add(PhysioDay(
      date: dayLabel,
      startSec: cs,
      endSec: ce,
      sleep: seg,
      sleepLoIdx: sleepLo,
      sleepHiIdx: sleepHi,
      confidence: seg.present ? seg.confidence : 0.0,
      sleepSource: sleepSource,
      flags: seg.present
          ? (sleepSource == 'auto_fallback'
              ? const <String>['SLEEP_FALLBACK']
              : (sleepSource == 'manual' || sleepSource == 'confirmed'
                  ? const <String>['SLEEP_MANUAL']
                  : const <String>[]))
          : const <String>['NO_SLEEP_DETECTED'],
    ));
    dayStart = dayEnd;
  }
  return days;
}

/// Local midnight (epoch sec) at/before [epochSec].
int _localMidnight(int epochSec) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: false);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;
}

/// The next local midnight strictly after the local midnight of [epochSec].
int _nextLocalMidnight(int epochSec) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: false);
  return DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch ~/ 1000;
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
