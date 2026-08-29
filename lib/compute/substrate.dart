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
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

import '../data/day_label.dart';

/// Minimum fraction of a nocturnal search window that must carry a REAL
/// gravity vector before accel-led (van Hees) sleep detection is trusted.
///
/// Below this we do not run it at all and fall through to the HR-led window,
/// which is already the honest low-confidence degraded mode. Set at a half
/// rather than something tiny on purpose: van Hees picks the LONGEST immobile
/// block, and absent seconds are maximally "immobile", so a window that is
/// mostly absent would reliably hand the answer to the missing data.
const double kMinAccelCoverageForVanHees = 0.5;

/// Physiological bound on a 1 Hz heart rate (bpm), inclusive.
///
/// HUMAN PHYSIOLOGY, NOT A SENSOR PROPERTY, so it is the same number on every
/// band: no heart beats 24 times a minute or 231 times a minute for a whole
/// second. Nothing about the strap moves it, which is why it does not go
/// through `calibrationFor` and why an unstamped record still gets it.
///
/// It exists because the gen4 TRUSTED decode path (v24 / v12) returns the HR
/// byte verbatim with no bound — the protocol's `_physiologicallyPlausible`
/// gate runs only on the best-effort versions, and gen5 v18 bounds it
/// independently — so one corrupt-but-CRC-valid byte of 250 used to pass the
/// `hr > 0` filter and land straight in the day's max HR. Applying it in the
/// protocol would cost the WHOLE record (accel and RR with it); applied here it
/// costs only the second.
const int kMinPlausibleHr = 25;
const int kMaxPlausibleHr = 230;

/// [raw] when it is a heart rate a human can have, else NULL — the reading is
/// refused, never clamped to the bound (a corrupt byte must not become a
/// plausible reading) and never reported as a measurement of anything else.
///
/// Callers that must land it in the dense [Substrate.hr] array write
/// `plausibleHrOrNull(raw) ?? 0`, 0 being that array's ONE "no usable HR this
/// second" value — see [Substrate.hr] for why that is not a claim about wear.
int? plausibleHrOrNull(int raw) =>
    (raw >= kMinPlausibleHr && raw <= kMaxPlausibleHr) ? raw : null;

/// Physiological bound on one R-R interval (ms), inclusive — the [kMinPlausibleHr]
/// / [kMaxPlausibleHr] window expressed as the gap between two beats, widened
/// at the long end because a single interval is not a rate: one dropped beat
/// doubles the gap without the heart doing anything unusual, and 2,400 ms still
/// sits inside the range an ordinary Malik/Lipponen ectopic filter is built to
/// see and correct. Below 250 ms (240 bpm sustained across one beat) it is not
/// a beat detection.
const int kMinPlausibleRrMs = 250;
const int kMaxPlausibleRrMs = 2400;

/// [rrMs] when it is an interval a human heart can produce, else NULL.
double? plausibleRrOrNull(num rrMs) =>
    (rrMs >= kMinPlausibleRrMs && rrMs <= kMaxPlausibleRrMs)
        ? rrMs.toDouble()
        : null;

/// The largest acceleration MAGNITUDE (g) a wrist can hold for a WHOLE SECOND.
///
/// These samples are one-second gravity vectors, not raw 100 Hz: an impact, a
/// swing and a free-fall are all sub-second transients that average away before
/// they get here, so this bounds a SUSTAINED magnitude, not a peak. Holding 4 g
/// for a full second is ~3 g of net force for a second — aerobatics and
/// centrifuges, not anything a band is worn through.
///
/// It is deliberately NOT the part's full-scale range: an FSR is an encoding
/// choice, and a part configured to +/-2 g with a scale-error decoder sails
/// through a +/-16 g test. It is also deliberately far above protocol's
/// `_physiologicallyPlausible` gravity window (magSq 0.25..3.24, i.e. 0.5..1.8 g),
/// which assumes a low-pass-filtered gravity vector and had to be dropped from
/// the gen5 decoder in 539a97b because it rejected real workout seconds. There
/// is no lower bound here for the same reason: sustained low-g seconds are real
/// and only EXACT zero is evidence of a fill.
const double kMaxSustainedAccelG = 4.0;

/// Whether a 1 Hz gravity triplet is a MEASUREMENT.
///
/// Two rejections, both physical:
///   * exact `(0, 0, 0)` — no accelerometer reads zero on all three axes at
///     rest or in motion, so it is an all-zero payload (see
///     [Substrate.accelPresentAt] for what that costs if it is trusted).
///   * a magnitude above [kMaxSustainedAccelG] — see there.
bool accelPlausible(double ax, double ay, double az) {
  final magSq = ax * ax + ay * ay + az * az;
  return magSq > 0 && magSq <= kMaxSustainedAccelG * kMaxSustainedAccelG;
}

/// Where each beat in one record actually sits, in absolute epoch ms — or
/// null for a beat that cannot be placed. One entry per entry in [rrMs].
///
/// TWO PARTS, AND THEY ARE NOT EQUALLY SOLID. Read them separately.
///
/// THE ANCHOR IS MEASURED. `rec_ts + tsSubsec/32768` is the record's own
/// timestamp, whole seconds and sub-second, exactly as the strap sent it.
/// This app has dropped the second half of that since forever, pinning every
/// record to a whole second. With no sub-second there is no anchor and every
/// beat here is null; a whole second is NOT substituted for one, because the
/// whole point of this column is to say something the old one could not.
///
/// THE PLACEMENT IS A MODEL, and it is one assumption wide: an R-R interval
/// is the gap ENDING at its beat (that part is the definition), and the LAST
/// beat a record reports sits at the record's timestamp. Everything else
/// follows — beat i is the anchor minus the intervals after it. The direction
/// is chosen because backwards is the only one that cannot place a beat in
/// the future, i.e. after the moment we were told about it; a forward walk
/// would also run every multi-beat record past its own second (the intervals
/// sum to 1,426 ms on a 2-beat record and 2,594 ms on a 4-beat one, measured)
/// and straight through the next record's.
///
/// WHAT THE INTERVALS DO NOT DO IS TILE THE SECOND. Over 81 uninterrupted
/// runs of 300+ consecutive records in a real export, the intervals sum to
/// 0.967 of the `rec_ts` span (0.960-0.990 across runs) — so the beat train is
/// a CHAIN that runs a few percent short, which is what a handful of rejected
/// beats looks like, and not a set of per-second buckets. Several of a
/// record's intervals reach back out of its own second. Per-record placement
/// is nevertheless what THIS path can do — records arrive batched, out of
/// order and with gaps, so no cross-record chain is available at the write —
/// and a consumer that wants the chain can walk `rr_ms` itself.
///
/// WHAT MOVES AND WHAT DOES NOT, now that `Substrate.rrTsMs` is fed from here
/// rather than from the `rec_ts * 1000` staircase. The INTERVAL SERIES does
/// not move at all — same values, same order — so `hrvTime(nn)` with no time
/// axis is bit-identical, and so is SDNN, which never pairs. Everything that
/// takes the axis does move: a Lomb-Scargle periodogram handed beats where
/// they happened, a beat put on the same axis as a motion sample, a real
/// inter-record gap. That includes RMSSD and pNNx as production calls them
/// (`hrvTime(nn, nnTimesMs: …)`), because the axis decides which successive
/// pairs count as CONTIGUOUS — measured at +0.03% RMSSD / +0.6% pNN50 over a
/// real 6 h block of 27,114 beats.
///
/// A non-positive interval BREAKS THE CHAIN: the gap before that beat is
/// unknown, so every EARLIER beat in the record becomes unplaceable and gets
/// null rather than a position computed as if the missing gap were zero.
List<int?> beatTimesMs(int recTs, int? tsSubsec, List<int> rrMs) {
  final out = List<int?>.filled(rrMs.length, null);
  if (tsSubsec == null || rrMs.isEmpty) return out;
  // THE TICK COUNT IS BOUNDED, for the same reason [kMaxPlausibleHr] is: this
  // is a u16 read straight off the wire, and a corrupt-but-CRC-valid one is
  // still a number. Ticks are 1/32768 s, so only 0..32767 is a SUB-second;
  // 40000 would put the anchor 1.22 s past the record it came from and walk
  // every beat in it into the wrong second. `beat_ts_ms` is read now, and the
  // axis is what decides which successive pairs count as contiguous for RMSSD
  // and pNNx — so an out-of-range tick is refused, not clamped: null is this
  // function's own word for "cannot be placed".
  if (tsSubsec < 0 || tsSubsec >= 32768) return out;
  final anchor = recTs * 1000 + (tsSubsec * 1000) ~/ 32768;
  var back = 0;
  for (var i = rrMs.length - 1; i >= 0; i--) {
    // Beat i's OWN placement never depends on rrMs[i] — that interval is the
    // gap BEFORE beat i, which only matters for placing beat i-1. Set first,
    // using whatever `back` the beats after i already earned.
    out[i] = anchor - back;
    // Only a PLAUSIBLE interval may extend the chain past this beat. The
    // caller drops an implausible-but-positive interval (`plausibleRrOrNull`
    // in `decodeSubstrate`) exactly as it drops a non-positive one, so an
    // interval outside kMinPlausibleRrMs..kMaxPlausibleRrMs must not still
    // walk every EARLIER beat back by it — that would let a rejected reading
    // silently displace a beat that is kept.
    final rr = plausibleRrOrNull(rrMs[i]);
    if (rr == null) break;
    back += rr.toInt();
  }
  return out;
}

/// The decoded 1 Hz substrate — the only decoded form (ARCHITECTURE_V2).
///
/// All HR/accel/ADC arrays are parallel and 1:1 with [tsSec] (one sample per
/// retained R24 record, sorted ascending by record time). The RR arrays are
/// SPARSE (~0–4 beats/record) with their own beat-end timestamps.
class Substrate {
  /// Epoch seconds, 1 Hz, sorted ascending. One entry per R24 record.
  final List<int> tsSec;

  /// 1 Hz HR (bpm). Parallel to [tsSec]. **`0` means NO USABLE HEART RATE this
  /// second — it is not a claim that the band was off your wrist.**
  ///
  /// The doc here used to say "0 = off-skin", and that was a second assertion
  /// smuggled in beside the first. Three different facts land on this 0: the
  /// record carried no HR field, the sensor found no beat, and the byte was
  /// outside [kMinPlausibleHr]..[kMaxPlausibleHr]. Read as "off-skin" the last
  /// of those censors a reading AND replaces it with a wear verdict, which
  /// biases anything that counts on-skin seconds — nocturnal RHR most of all,
  /// on exactly the calm nights that push HR toward the low bound.
  ///
  /// It is one value rather than two because the ledger has already collapsed
  /// them: `decoded_onehz.hr` stores NULL for every record with no heart rate
  /// (db.dart `_queueDecodedOneHz`, `decoded.hr > 0 ? decoded.hr : null`), so
  /// "the band said zero" cannot reach this array as anything else. Every
  /// reader gates `> 0`. Wear truth lives in the HELLO body, the wrist on/off
  /// events and the record-presence runs (`_wearBlock`) — never here.
  final List<int> hr;

  /// Beat-to-beat RR: interval end time (epoch ms) + interval (ms). Sparse.
  final List<double> rrTsMs;
  final List<double> rrMs;

  /// 1 Hz tri-axial accel (gravity vector, g). Parallel to [tsSec].
  final List<double> ax;
  final List<double> ay;
  final List<double> az;

  /// Relative-ADC channels (raw counts; NO absolute units). Parallel to [tsSec].
  ///
  /// [spo2Red] / [spo2Ir] are named after the LED, not after a metric. NO
  /// oxygen number may be derived from them, at any tier: `ir − red` is a fixed
  /// integer within a capture session while both channels drift together, so
  /// every ratio built from the pair measures one channel's baseline drift.
  /// they are carried because they ARE the bytes at those offsets and the
  /// substrate round-trips the record; they are not carried because something
  /// downstream is meant to consume them. gen5's `spo2CandidateRaw` is
  /// deliberately not in this struct either — see `Spo2Data` in
  /// models/payloads.dart for the whole refusal, including why the gen5 field
  /// is the tempting one.
  final List<int> spo2Red;
  final List<int> spo2Ir;
  final List<int> skinTemp;
  final List<int> skinContact;

  /// Gen5 on-chip CUMULATIVE step counter (u16, wraps at 65536, no midnight
  /// reset). Parallel to [tsSec]. **`-1` means the record carried no counter at
  /// all** — gen4 R24 has no pedometer field, so every gen4 second reads -1.
  ///
  /// The sentinel is load-bearing: `0` is a real reading (a band that has not
  /// moved since its last wrap/reset) and must not be confused with "this
  /// generation cannot count steps". Same absent-marker discipline as
  /// [accelPresentAt].
  final List<int> stepCount;

  /// The band's own "heart rate and RR are valid this second" flag. Parallel to
  /// [tsSec]. **`-1` means the record carried no flag at all** — gen4's R24 has
  /// no such field, so every gen4 second reads -1, and reading that as `false`
  /// would turn "this band cannot say" into "the band said no".
  ///
  /// GATED ON THE SENTINEL ALONE — see [hrValidAt] for why the band-id check
  /// that used to sit beside it is gone. A strap that reports this flag and a
  /// strap that cannot will tier DIFFERENTLY on identical physiology because of
  /// exactly this kind of extra evidence, so a reader that weights by it has to
  /// say so somewhere the user can see.
  /// Same absent-marker discipline as [stepCount] and [accelPresentAt].
  final List<int> hrValid;

  /// WHICH STRAP MEASURED THIS SUBSTRATE — `'gen4'`, `'gen5'`, or null.
  ///
  /// Stamped at ingest into `decoded_onehz.device_family` and carried here so
  /// the pure pipeline can dispatch on it (analytics: `calibrationFor`, whose
  /// map of families is open — a stamp is a key or it is not). It is ONE value for the whole substrate, not a
  /// per-second array, because the question a metric asks is "which sensor
  /// package produced this window", and a window that mixes two answers has no
  /// single answer.
  ///
  /// NULL means UNKNOWN — no stamp (every row predating schema v41, anything
  /// imported, anything replayed from raw hex), OR the rows disagree. Both are
  /// the same instruction to a reader: REFUSE, do not assume gen4. A gen4 skin
  /// temp is an ADC count and a gen5 one is centi-°C in the same column, so
  /// guessing here is how a fabricated number gets published.
  final String? deviceFamily;

  /// Pack a `List<double>` into a `Float64List` (an already-packed list passes
  /// straight through).
  ///
  /// A growable `List<double>` in Dart AOT is a list of POINTERS to boxed
  /// doubles — an 8-byte slot plus a 16-byte heap object per element, 24 B in
  /// all. `Float64List` stores the bits inline at 8. These five arrays are the
  /// substrate's whole memory story: ~6.9 MB/day of pure boxing at 1 Hz, held
  /// across three overlapping windows per day and three concurrent derive
  /// lanes. It also turns the isolate hand-off into a memcpy of a typed buffer
  /// instead of an object-graph walk over ~400 000 boxes.
  ///
  /// Bit-exact: a `Float64List` holds the same IEEE-754 doubles, so nothing
  /// derived from them moves. (The int arrays are deliberately left alone —
  /// Dart already stores small ints inline as Smis, so an `Int32List` would buy
  /// 4 B/element in exchange for a silent-truncation edge.)
  static List<double> _packed(List<double> l) =>
      l is Float64List ? l : Float64List.fromList(l);

  factory Substrate({
    required List<int> tsSec,
    required List<int> hr,
    required List<double> rrTsMs,
    required List<double> rrMs,
    required List<double> ax,
    required List<double> ay,
    required List<double> az,
    required List<int> spo2Red,
    required List<int> spo2Ir,
    required List<int> skinTemp,
    required List<int> skinContact,
    List<int> stepCount = const [],
    List<int> hrValid = const [],
    String? deviceFamily,
  }) =>
      Substrate._(
        deviceFamily: deviceFamily,
        tsSec: tsSec,
        hr: hr,
        rrTsMs: _packed(rrTsMs),
        rrMs: _packed(rrMs),
        ax: _packed(ax),
        ay: _packed(ay),
        az: _packed(az),
        spo2Red: spo2Red,
        spo2Ir: spo2Ir,
        skinTemp: skinTemp,
        skinContact: skinContact,
        stepCount: stepCount,
        hrValid: hrValid,
      );

  const Substrate._({
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
    required this.skinContact,
    this.stepCount = const [],
    this.hrValid = const [],
    this.deviceFamily,
  });

  static const Substrate empty = Substrate._(
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
    skinContact: [],
  );

  int get length => tsSec.length;
  bool get isEmpty => tsSec.isEmpty;
  int? get firstTs => isEmpty ? null : tsSec.first;
  int? get lastTs => isEmpty ? null : tsSec.last;

  /// 1 Hz accel samples (one gravity vector per second) for the analytics family.
  ///
  /// Seconds with no gravity vector are carried with `valid: false` rather than
  /// dropped, so the stream stays 1:1 with [tsSec] while `enmoSeries`,
  /// `positionSeries` and the zone readers — all of which filter on `valid` —
  /// see them as ABSENT instead of as a perfectly still wrist. See
  /// [accelPresentAt].
  List<ana.AccelSample> accelSamples() => <ana.AccelSample>[
        for (var i = 0; i < tsSec.length; i++)
          ana.AccelSample(tsSec[i] * 1000.0, ax[i], ay[i], az[i],
              valid: accelPresentAt(i))
      ];

  /// Whether second [i] carries a REAL gravity vector.
  ///
  /// `decoded_onehz.ax/ay/az` are nullable as of schema v39, but the 1 Hz
  /// arrays here are POSITIONAL, so a record decoded without a usable gravity
  /// vector — gen5 v18 keeps HR/RR and reports the accel as absent rather than
  /// discarding the second, and the gen4 R10-historical path decodes HR only —
  /// still occupies its slot, as exact `(0, 0, 0)`.
  /// That is not a reading a real device can produce: an accelerometer at rest
  /// reads ~1 g and one in motion reads more, so all three axes landing on
  /// EXACTLY 0.0 is an all-zero payload, i.e. no measurement. Exact zero is
  /// therefore the ABSENT marker.
  ///
  /// The upper end is [kMaxSustainedAccelG] — a second-long mean no wrist
  /// holds — so a decoder whose scale factor is wrong by an order of magnitude
  /// stops reading as violent movement and starts reading as absent. There is
  /// no lower bound beyond exact zero; see [accelPlausible].
  ///
  /// This used to rest on "every decoder gates on `magSq >= 0.25`", which is no
  /// longer true — protocol 539a97b dropped that gate from the gen5 v18 decoder
  /// (it is a bound on a NORMALISED gravity vector and gen5 emits per-axis raw
  /// means, so it rejected real workout seconds). A gen5 all-zero accel payload
  /// now decodes as `gravityG: [0,0,0]` and lands here, where it reads as
  /// absent — the right answer, but reached by physics rather than by a gate
  /// upstream. Restoring an all-zero ⇒ absent check in the gen5 decoder would
  /// make it explicit again.
  ///
  /// This matters because absent accel does not merely go unused: a run of
  /// `(0, 0, 0)` has a constant z-angle of exactly 0.0°, which the van Hees
  /// rule reads as PERFECT IMMOBILITY. Eight hours of missing accel scores
  /// 28 501 immobile seconds and yields a fabricated ~7.9 h sleep window,
  /// fully staged. Absent input must produce no claim, never a confident one.
  bool accelPresentAt(int i) => accelPlausible(ax[i], ay[i], az[i]);

  /// Fraction of [lo, hi) seconds carrying a real gravity vector (0..1).
  /// Returns 0 for an empty range — no evidence, not "all present".
  double accelPresentFraction(int lo, int hi) {
    final a = lo < 0 ? 0 : lo;
    final b = hi > tsSec.length ? tsSec.length : hi;
    if (b <= a) return 0;
    var present = 0;
    for (var i = a; i < b; i++) {
      if (accelPresentAt(i)) present++;
    }
    return present / (b - a);
  }

  /// 1 Hz HR as doubles (0 = off-skin). Parallel to [tsSec] / [accelSamples].
  List<double> hr1hz() => [for (final h in hr) h.toDouble()];

  /// The on-chip step counter at second [i], or `null` when this record carried
  /// none (gen4, or a gen5 record whose counter field was absent).
  int? stepCounterAt(int i) {
    if (i < 0 || i >= stepCount.length) return null;
    final v = stepCount[i];
    return v < 0 ? null : v;
  }

  /// The band's own HR-validity verdict for second [i], or `null` when this
  /// record carried none — which is EVERY gen4 second, and every second of a
  /// substrate whose provenance is unknown.
  ///
  /// ABSENT, NEVER FALSE. A gen4 strap has no such field and a NULL read as
  /// `false` would silently mark a whole generation's beats untrustworthy.
  bool? hrValidAt(int i) {
    // THE ROW ANSWERS FOR ITSELF. This used to also require
    // `deviceFamily == 'gen5'` — a band id hardcoded inside the class whose
    // whole job is to be neutral, which meant a second band that reports the
    // same flag would have been silently ignored while its data sat right here.
    // The sentinel is the evidence: only a decoder that read the flag off the
    // wire writes a non-negative value into this column (db.dart writes NULL
    // otherwise, and derive_prepare lands NULL on -1), so a value >= 0 IS a
    // declaration by the source that produced the row. An unstamped substrate
    // carrying real flags is a source that told us the flag and not the badge —
    // refusing it discards a measurement to punish missing metadata.
    if (i < 0 || i >= hrValid.length) return null;
    final v = hrValid[i];
    return v < 0 ? null : v != 0;
  }

  /// A per-second companion array sliced to [lo, hi), tolerating the legacy
  /// empty list (an older payload that predates the array entirely).
  List<int> _perSecSlice(List<int> src, int lo, int hi) =>
      src.length == tsSec.length ? src.sublist(lo, hi) : const [];

  /// [stepCount] sliced to [lo, hi), tolerating the legacy empty list.
  List<int> _stepSlice(int lo, int hi) => _perSecSlice(stepCount, lo, hi);

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
      skinContact: skinContact.sublist(lo, hi),
      stepCount: _stepSlice(lo, hi),
      hrValid: _perSecSlice(hrValid, lo, hi),
      deviceFamily: deviceFamily,
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
      skinContact: skinContact.sublist(lo, hi),
      stepCount: _stepSlice(lo, hi),
      hrValid: _perSecSlice(hrValid, lo, hi),
      deviceFamily: deviceFamily,
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
      skinContact: const [],
      deviceFamily: deviceFamily,
      rrTsMs: rr.$1,
      rrMs: rr.$2,
    );
  }

  /// Filter THIS substrate's sparse RR to beats whose end time (epoch ms) falls
  /// in [startSec, endSec). Returns (rrTsMs, rrMs).
  /// Counted first, then filled, so the beats land straight in a `Float64List`.
  /// A growable `<double>[]` here would box every beat only for the constructor
  /// to pack it back — and this runs on every slice, of which there are three
  /// per day.
  (List<double>, List<double>) _filterRr(int startSec, int endSec) {
    final loMs = startSec * 1000.0, hiMs = endSec * 1000.0;
    var n = 0;
    for (var i = 0; i < rrMs.length; i++) {
      final t = rrTsMs[i];
      if (t >= loMs && t < hiMs) n++;
    }
    final ts = Float64List(n), rr = Float64List(n);
    var j = 0;
    for (var i = 0; i < rrMs.length; i++) {
      final t = rrTsMs[i];
      if (t >= loMs && t < hiMs) {
        ts[j] = t;
        rr[j] = rrMs[i];
        j++;
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
        'skin_contact': skinContact,
        'step_count': stepCount,
        'hr_valid': hrValid,
        // Null (unknown provenance) is a real answer — emit the key regardless.
        'device_family': deviceFamily,
      };

  static Substrate fromJson(Map<String, dynamic> m) {
    List<int> ints(Map<String, dynamic> m, String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    // Straight into a Float64List — see [_packed]. This runs on the RECEIVING
    // (main) isolate for every substrate handed back from a worker, so the
    // growable intermediate was ~400 000 boxes allocated and immediately
    // thrown away, on the UI thread.
    Float64List dbls(String k) {
      final src = (m[k] as List?) ?? const [];
      final out = Float64List(src.length);
      for (var i = 0; i < src.length; i++) {
        out[i] = (src[i] as num).toDouble();
      }
      return out;
    }


    final tsSec = ints(m, 'ts_sec');
    final n = tsSec.length;
    
    List<int> safeI(String k) {
      final l = ints(m, k);
      return (l.isEmpty && n > 0) ? List<int>.filled(n, 0) : l;
    }
    List<double> safeD(String k) {
      final l = dbls(k);
      return (l.isEmpty && n > 0) ? Float64List(n) : l;
    }

    return Substrate(
      tsSec: tsSec,
      hr: safeI('hr'),
      rrTsMs: dbls('rr_ts_ms'), // rrTsMs and rrMs don't have to match n
      rrMs: dbls('rr_ms'),
      ax: safeD('ax'),
      ay: safeD('ay'),
      az: safeD('az'),
      spo2Red: safeI('spo2_red'),
      spo2Ir: safeI('spo2_ir'),
      skinTemp: safeI('skin_temp'),
      skinContact: safeI('skin_contact'),
      // NOT `safeI`: a missing/short list means the counter was ABSENT, and the
      // absent marker is -1, not 0 (0 is a real, unmoved counter reading).
      stepCount: () {
        final l = ints(m, 'step_count');
        return l.length == n ? l : List<int>.filled(n, -1);
      }(),
      // Same reason as `step_count`: the absent marker is -1. 0 is a real
      // reading — the band saying THIS second's beat is not trustworthy.
      hrValid: () {
        final l = ints(m, 'hr_valid');
        return l.length == n ? l : List<int>.filled(n, -1);
      }(),
      deviceFamily: m['device_family'] as String?,
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
  // One shared decoder for the whole page: legacy decoder first, firmware-
  // fallback chain second (see FirmwareAwareR24Decoder) — sharing it across
  // the batch means a firmware quirk detected on the first record isn't
  // re-probed for every subsequent one in this page.
  final decoder = proto.FirmwareAwareR24Decoder();
  for (final hex in hexes) {
    proto.R24? r;
    try {
      r = decoder.decode(proto.hexToBytes(hex));
    } catch (_) {
      r = null;
    }
    // v25 is DROPPED, not decoded. `FirmwareAwareR24Decoder` routes it to
    // `_parseV25`, whose `accelG` is not an accelerometer reading: measured
    // across all 28,395 v25 records in `whoop-4.db`, the "z" axis takes three
    // distinct values, the "y" seventeen (68% of them one value), the "x" is
    // the upper half of an f32 starting two bytes earlier — and the median
    // angle to the REAL gravity vector from the v24 record for the same
    // second is 83°. Near-constant, so it reads as a perfectly still wrist to
    // van Hees. The record carries no HR either, so dropping it costs
    // nothing this path can use. Same refusal as `LocalDb._decodeOneHzSample`.
    if (r != null && r.histVersion == 25) continue;
    if (r != null && r.tsEpoch > 0) {
      recs.add(_Rec(r));
      continue;
    }
    final live = proto.realtimeRr(hex);
    if (live != null && live.ts > 0) {
      for (final v in live.rrMs) {
        final rr = plausibleRrOrNull(v);
        if (rr != null) looseRr.add(_Beat(live.ts * 1000.0, rr));
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
  final skinContact = List<int>.filled(n, 0);
  final rrTsMs = <double>[], rrMs = <double>[];

  for (var i = 0; i < n; i++) {
    final r = recs[i].r;
    tsSec[i] = r.tsEpoch;
    hr[i] = plausibleHrOrNull(r.hr) ?? 0;
    if (r.accelG.length == 3) {
      ax[i] = r.accelG[0];
      ay[i] = r.accelG[1];
      az[i] = r.accelG[2];
    }
    spo2Red[i] = r.spo2RedRaw;
    spo2Ir[i] = r.spo2IrRaw;
    // both deprecated: neither field is what its name says. still filled here so
    // the substrate keeps round-tripping, but _daySkinTempCurve and the
    // fit_quality diagnostic both derive from them and shouldn't — separate fix,
    // it moves user-facing output and needs an algo version bump.
    // ignore: deprecated_member_use
    skinTemp[i] = r.skinTempRaw;
    // ignore: deprecated_member_use
    skinContact[i] = r.skinContact;
    // RR beats: placed at their MEASURED instant (`beatTimesMs` — the record's
    // own sub-second anchor, intervals walked backwards from it), falling back
    // to the record second only when the record carries no sub-second. Beats
    // used to all share the record's whole second here, which says two beats
    // 800 ms apart happened at the same millisecond. Emission ORDER is
    // unchanged (record order, then beat order) so no interval series moves —
    // only where the beats sit on the clock.
    final t = r.tsEpoch * 1000.0;
    final beatTs = beatTimesMs(r.tsEpoch, r.tsSubsec, r.rrIntervalsMs);
    for (var b = 0; b < r.rrIntervalsMs.length; b++) {
      // A non-positive interval was already dropped here; the bound only widens
      // that to intervals no heart produces. It drops the BEAT, not the record:
      // `beatTimesMs` has already placed the survivors, and an interval this
      // far out is a missed or doubled detection, not a rhythm.
      final rr = plausibleRrOrNull(r.rrIntervalsMs[b]);
      if (rr != null) {
        rrMs.add(rr);
        rrTsMs.add(beatTs[b]?.toDouble() ?? t);
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
    skinContact: skinContact,
    // Gen4 R24 carries no pedometer field: every second is ABSENT (-1), never
    // a confident zero. Gen5 counters reach the substrate through the
    // decoded_onehz loader (derive_prepare.addDecodedPage), not this path.
    stepCount: List<int>.filled(n, -1),
    // Same story for the band's HR-validity flag, and this path is raw-hex
    // replay, which carries no device stamp either — so it would refuse at
    // `hrValidAt` regardless.
    hrValid: List<int>.filled(n, -1),
  );
}

/// Steps MEASURED by the band's own pedometer over [sub], or `null` when this
/// substrate carries no counter at all — which is every gen4 (WHOOP 4.0) day,
/// since R24 has no pedometer field. Null means "this hardware cannot count
/// steps", never "you took no steps".
///
/// [cumulativeCounterModulus] IS A DECLARATION AND IT IS NOT OPTIONAL —
/// null abstains. It says two things about the source's counter, and this
/// function is only correct if both hold: it wraps at that modulus, and it is
/// CUMULATIVE, i.e. it does not reset inside the window being summed. Both used
/// to be assumed (`wrap = 65536`, hardcoded), and the second one is the
/// expensive assumption: this reads DELTAS, so a counter that resets at
/// midnight silently loses every step taken before the day's first synced
/// record — 12,500 walked, 8,300 published, at tier HIGH and confidence 0.9,
/// with nothing in the output saying so. Nothing on a record distinguishes a
/// reset from a wrap after the fact, so an undeclared counter gets no number
/// rather than a guessed one. The caller declares it because the caller knows
/// which band stamped the rows; see `DerivationEngine._stepCounterModulus`.
///
/// The counter is also reset by a strap reboot/re-pair, so the total is the sum
/// of positive per-record deltas, not `last - first`. Two hazards, both handled
/// here (`wrap` below is [cumulativeCounterModulus]):
///
///   * **wrap** (65500 → 100): the raw delta is negative. Re-reading it modulo
///     65536 gives the true small delta, which passes the plausibility budget.
///   * **reset** (40000 → 0): the raw delta is also negative, and modulo 65536
///     gives an absurd 25536. It FAILS the budget and contributes nothing —
///     the boundary delta is dropped rather than invented. Losing at most one
///     inter-record delta is the honest cost of an ambiguity the counter
///     genuinely cannot resolve.
///
/// The plausibility budget is `clamp(gap, 60 s, 3600 s) × [maxStepsPerSecond]`,
/// and both ends of that clamp are load-bearing:
///
///   * the FLOOR (300 steps) exists because the counter's on-band update cadence
///     is not verified on hardware. If the strap advances it in bursts rather
///     than every second, a literal `gap × 5` budget would reject almost every
///     real delta and silently report near-zero steps — a far worse failure than
///     the one this guard is for. 300 steps between two records still cannot be
///     confused with a 25 000-step reset artefact.
///   * the CEILING keeps a reset after a long unsynced stretch from buying
///     enough budget to pass as a wrap.
///
/// A delta is either credited in full or dropped in full, so this function can
/// never return a negative or an absurd total, whatever the counter does.
int? hardwareStepsFromCounter(
  Substrate sub, {
  required int? cumulativeCounterModulus,
  int maxStepsPerSecond = 5,
}) {
  final wrap = cumulativeCounterModulus;
  if (wrap == null || wrap <= 0) return null;
  const minGapSecForBudget = 60;
  const maxGapSecForBudget = 3600;
  int? prev;
  int? prevTs;
  var total = 0;
  var seen = false;
  for (var i = 0; i < sub.length; i++) {
    final c = sub.stepCounterAt(i);
    if (c == null) continue;
    seen = true;
    final ts = sub.tsSec[i];
    if (prev != null && prevTs != null && ts > prevTs) {
      final gap = ts - prevTs;
      final budget =
          gap.clamp(minGapSecForBudget, maxGapSecForBudget) * maxStepsPerSecond;
      var delta = c - prev;
      if (delta < 0) delta += wrap; // wrap candidate; a reset overshoots below
      if (delta > 0 && delta <= budget) total += delta;
    }
    prev = c;
    prevTs = ts;
  }
  return seen ? total : null;
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

  /// Index range [sleepLoIdx, sleepHiIdx) of the sleep window INTO THE FULL
  /// substrate — the same one passed to [calendarDays], NOT the day slice.
  /// (`calendarDays` builds them as `loS + onsetIdx`, where `loS` is a lower
  /// bound into the full arrays, and both live callers slice the full substrate
  /// with them; this doc used to say "day-sliced", contradicting `calendarDays`'
  /// own doc and pointing a future caller at a window offset by up to the
  /// nocturnal lookback.) Both 0 when no sleep.
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

/// How far BEFORE a calendar day's local midnight [calendarDays] searches for
/// the main sleep that ends in that day — the previous local NOON.
///
/// Exported because the coordinator has to LOAD at least this much substrate
/// before the day start, or `searchStart = math.max(dataStart, …)` silently
/// clips the window back to wherever the loaded slice happens to begin and any
/// sleep onset before that instant is truncated (see
/// `DerivationEngine._targetDayWindow`). One constant, two call sites — they
/// cannot drift apart again.
const int kNocturnalSearchLookbackSec = 12 * 3600;

/// A user-asserted sleep window for one day — manual entry (Approach 1) or a
/// confirmation of the HR-led fallback (Approach 2). Passed into [calendarDays]
/// so it overrides auto detection for the matching [dayId].
class SleepWindowOverride {
  final String dayId;
  final int onsetSec;
  final int offsetSec;
  final String source; // 'manual' | 'confirmed' | 'rejected'
  // 'rejected': onsetSec/offsetSec still carry the window being rejected (the
  // auto-detected window at the time of rejection, same convention the
  // already-shipped rejected-nap rows use), but the window is never staged —
  // see calendarDays' `ov.source == 'rejected'` branch.

  const SleepWindowOverride({
    required this.dayId,
    required this.onsetSec,
    required this.offsetSec,
    required this.source,
  });
}

/// Local YYYY-MM-DD label for an epoch-second instant.
String localDateLabel(int epochSec) =>
    dayLabelOf(DateTime.fromMillisecondsSinceEpoch(epochSec * 1000));

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
///
/// [tzOffsetAt] resolves the local UTC offset in effect at an epoch second;
/// it defaults to [tzOffsetSecondsAt] and exists so tests can pin that the
/// habitual-midsleep prior is resolved AT THE DAY BEING SEGMENTED rather than
/// at "now" (a zone-independent way to test the DST/travel fix, since the
/// machine running the test may sit in a zone that never changes offset).
///
/// [priorSleep] seeds the habitual-midsleep prior with sleep windows ALREADY
/// STORED for earlier days. Without it the prior is unreachable in production:
/// the history is accumulated as this function walks days, every live call
/// spans at most ~36 h (one target day + its nocturnal lookback), and
/// `habitualMidsleepSecFromHistory` needs 14 distinct days — so the selector
/// always fell back to the fixed 03:30 cold-start anchor, and a night-shift
/// sleeper's 4 h main block lost the alignment bonus to a shorter block nearer
/// 03:30. Days found in THIS call still win (a full restage sees them all).
List<PhysioDay> calendarDays(
  Substrate sub, {
  SleepWindowOverride? override,
  int Function(int epochSec)? tzOffsetAt,
  List<({int startSec, int endSec, String dayKey})> priorSleep = const [],
}) {
  final tzOffset = tzOffsetAt ?? tzOffsetSecondsAt;
  if (sub.isEmpty) return const [];
  final accel = sub.accelSamples();
  final hr = sub.hr1hz();
  final dataStart = sub.tsSec.first;
  final dataEnd = sub.tsSec.last + 1;

  final days = <PhysioDay>[];
  final sleepHistory = <({int startSec, int endSec, String dayKey})>[
    ...priorSleep,
  ];
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
    final searchStart = math.max(dataStart, dayStart - kNocturnalSearchLookbackSec);
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
      // The habitual-midsleep prior converts each HISTORICAL sleep block's epoch
      // seconds to a local time-of-day. Using `DateTime.now()`'s offset applied
      // the CURRENT UTC offset to those historical instants, so re-deriving days
      // from the other side of a DST transition (or a trip) shifted every
      // historical midsleep by an hour — which can change which candidate sleep
      // the selector's alignment bonus picks. Resolve the offset AT EACH BLOCK'S
      // OWN INSTANT instead of "whenever this code happens to run", so a
      // re-derive of an old day is reproducible regardless of today's zone.
      // One offset frozen for the whole history is the DST bypass analytics
      // warns about — with a real ≥14-day history (see [priorSleep]) it will
      // regularly straddle a transition — and `tzOffset` is already a pure
      // ts → offset function, so pass it as the resolver.
      final habitualMidsleepSec = ana.habitualMidsleepSecFromHistory(
        sleepHistory,
        tzOffsetResolver: tzOffset,
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
      if (ov != null && ov.source == 'rejected') {
        // The user's word again, the other direction: this was NOT sleep at
        // all. Skip detection/staging entirely rather than force a window —
        // the day derives with no main sleep, same as the already-shipped
        // rejected-nap path (`sleep_nap` source='rejected').
        s = ana.SleepSegmentation.absent;
        src = 'rejected';
      } else if (ov != null) {
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
        // Accel-led detection is only meaningful if we actually HAVE accel.
        // Absent gravity is stored as exact (0,0,0) (see `accelPresentAt`) and
        // van Hees scores a run of it as perfect immobility, so a night whose
        // records all decoded without a gravity vector would otherwise produce
        // a confident, fully-staged sleep window built entirely out of missing
        // data. `immobilityMask` has no validity input to tell it otherwise —
        // it is a pure index-wise angle rule, so neither a NaN sentinel (NaN
        // comparisons are false, so the "angle changed" test never trips and
        // it reads as immobile) nor omitting the seconds (no gap awareness)
        // reaches it. The only honest move at this layer is not to let it
        // anchor the window in the first place.
        final accelCoverage = sub.accelPresentFraction(loS, hiS);
        if (accelCoverage >= kMinAccelCoverageForVanHees) {
          s = ana.segmentSleep(
            accelSlice,
            hrSlice,
            hrBaseline: hrBaseline,
            rrMs: rrMsSeg,
            rrTsMs: rrTsSeg,
            habitualMidsleepSec: habitualMidsleepSec,
          );
        } else {
          // Not an error and not "no sleep" — just no accel evidence. Fall
          // through to the HR-led path below, which is exactly the degraded
          // mode for this and is already marked low-confidence.
          s = ana.SleepSegmentation.absent;
        }
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
      } else if (src == 'rejected') {
        // No window to stage (deliberately), but the day still needs to know
        // it was a rejection rather than an ordinary absence — sleep_detail
        // reads this to keep the "not sleep" state from re-prompting.
        sleepSource = 'rejected';
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
          : (sleepSource == 'rejected'
              ? const <String>['SLEEP_REJECTED']
              : const <String>['NO_SLEEP_DETECTED']),
    ));
    dayStart = dayEnd;
  }
  return days;
}

/// The LOCAL UTC offset in effect AT [epochSec] — not the offset in effect now.
///
/// `DateTime.now().timeZoneOffset` answers "what is the offset today", which is
/// the wrong question for any historical instant: a day derived from the other
/// side of a DST transition (or from before a trip) sits at a different offset,
/// and using today's would shift that day's local clock-times by up to an hour.
/// `DateTime.fromMillisecondsSinceEpoch(..., isUtc: false).timeZoneOffset` asks
/// the platform zone database for the offset that actually applied then.
int tzOffsetSecondsAt(int epochSec) =>
    DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: false)
        .timeZoneOffset
        .inSeconds;

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
