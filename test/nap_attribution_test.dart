// HONESTY + DOUBLE-COUNT REGRESSIONS on the nap → sleep-periods seam.
//
// Three separate ways the nap path stated something it did not know:
//
//  1. `_attachNaps` collapsed "judged, and there were no naps" with "could not
//     judge this day at all" — both returned an empty list. `_sleepPeriods`
//     then published `total_asleep_min = mainTstMin` as a CONFIDENT day total
//     on a day whose naps were never assessed, in the very same bundle where
//     `naps.value` is null and `nap_min` was (correctly) left unwritten.
//
//  2. The midnight double-count. Attribution was guarded on the TRAILING edge
//     only (`start < attributionEndSec`, plus the analytics-side backward
//     `unfinished` walk). Nothing guarded the LEADING edge: analytics'
//     `stillAt(0)` short-circuits its discontinuity check at `k == 0`
//     (nap.dart), so the post-midnight remainder of a nap yesterday already
//     emitted whole is re-detected today as a fresh bout at index 0 and
//     credited a second time. Unreachable until `minNapSec` dropped to 15 min.
//
//  3. The leading-edge guard must NOT fire when the record only starts hours
//     into the day: yesterday's detector broke on that same recording
//     discontinuity and dropped the bout too, so today is its only chance to
//     count it. Dropping it there would trade a double-count for data loss.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';

/// A 1 Hz substrate with a single still, low-HR block — the shape `detectNaps`
/// scores as a nap — laid over an otherwise moving, awake-HR day.
///
/// [startSec] is the epoch second of the FIRST sample (so a test can model a
/// record that opens exactly at local midnight, or hours after it).
/// [napFromSec]/[napToSec] are offsets from [startSec].
Substrate _daySubstrate({
  required int startSec,
  required int lengthSec,
  required int napFromSec,
  required int napToSec,
}) {
  final ts = <int>[];
  final hr = <int>[];
  final ax = <double>[];
  final ay = <double>[];
  final az = <double>[];
  for (var i = 0; i < lengthSec; i++) {
    ts.add(startSec + i);
    final inNap = i >= napFromSec && i < napToSec;
    // Awake baseline ~78 bpm; the nap sits well under napRestingHrMult (0.95).
    hr.add(inNap ? 56 : 78);
    if (inNap) {
      // Perfectly still: a constant gravity vector → zero z-angle delta.
      ax.add(0.0);
      ay.add(0.0);
      az.add(1.0);
    } else {
      // Awake movement. It has to be a RAMP, not an alternation: the mask
      // smooths the z-angle with a 5-second rolling MEDIAN, which erases a
      // 1 Hz square wave entirely and would make the whole day read immobile.
      // A 10°/s sweep survives the median and clears the 5° threshold.
      final deg = (i % 9) * 10.0;
      final rad = deg * math.pi / 180.0;
      ax.add(math.cos(rad));
      ay.add(0.0);
      az.add(math.sin(rad));
    }
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(lengthSec, 0),
    spo2Ir: List<int>.filled(lengthSec, 0),
    skinTemp: List<int>.filled(lengthSec, 0),
    skinContact: List<int>.filled(lengthSec, 0),
  );
}

void main() {
  // ── 1. absent is not zero, and it is not a confident total either ────────
  group('_sleepPeriods distinguishes "no naps" from "naps not judged"', () {
    test(
      'a JUDGED day with no naps still publishes a confident total',
      () {
        final out = DerivationEngine.debugSleepPeriods(
          1000,
          1000 + 7 * 3600,
          const <Map<String, dynamic>>[], // judged; there were none
          mainTstMin: 420,
        );
        expect(
          out['total_asleep_min'],
          420,
          reason: 'nothing is unknown here — the day was assessed',
        );
      },
    );

    test(
      'an UNJUDGED day publishes NO total, even though the main sleep is known',
      () {
        final out = DerivationEngine.debugSleepPeriods(
          1000,
          1000 + 7 * 3600,
          null, // detector abstained / threw — naps never assessed
          mainTstMin: 420,
        );
        expect(
          out['total_asleep_min'],
          isNull,
          reason:
              'the day may hold unmeasured naps; 420 would be a claim that it '
              'does not. The screen renders "—" instead.',
        );
        // The main sleep is still listed — only the SUM is withheld.
        expect((out['periods'] as List), hasLength(1));
        expect((out['periods'] as List).first['duration_min'], 420);
      },
    );
  });

  // ── 2 + 3. day-boundary attribution ──────────────────────────────────────
  group('_attachNaps day-boundary attribution', () {
    const midnight = 1750000800; // arbitrary local-midnight-ish epoch second
    const napLen = 40 * 60;

    test(
      'a nap in progress at the first sample of a CONTIGUOUS record is '
      'yesterday\'s and is not counted again today',
      () {
        // The record opens exactly at midnight and the block is already
        // underway — i.e. it started before midnight, where yesterday's
        // buffered window saw it whole and emitted it.
        final s = _daySubstrate(
          startSec: midnight,
          lengthSec: 6 * 3600,
          napFromSec: 0,
          napToSec: napLen,
        );
        final bundle = <String, dynamic>{};
        final sc = <String, dynamic>{};

        final candidates = <Map<String, dynamic>>[];
        final periods = DerivationEngine.debugAttachNaps(
          bundle,
          sc,
          s,
          0,
          0,
          candidates: candidates,
          attributionStartSec: midnight,
          attributionEndSec: midnight + 86400,
        );

        expect(
          periods,
          isNotNull,
          reason: 'the day WAS judged — this is a real empty, not an abstain',
        );
        expect(
          periods,
          isEmpty,
          reason: 'yesterday already credited these minutes',
        );
        expect(
          sc['nap_min'],
          0.0,
          reason: 'judged, and none of it belongs to today',
        );
      },
    );

    test(
      'the same bout is proposed when the record only starts hours into the '
      'day — yesterday could not have seen it',
      () {
        // A recording gap across the boundary: the first sample is 08:00.
        // Yesterday's detector broke on that same discontinuity and dropped
        // the bout, so today is its only chance to be counted.
        const firstSample = midnight + 8 * 3600;
        final s = _daySubstrate(
          startSec: firstSample,
          lengthSec: 6 * 3600,
          napFromSec: 0,
          napToSec: napLen,
        );
        final bundle = <String, dynamic>{};
        final sc = <String, dynamic>{};

        final candidates = <Map<String, dynamic>>[];
        final periods = DerivationEngine.debugAttachNaps(
          bundle,
          sc,
          s,
          0,
          0,
          candidates: candidates,
          attributionStartSec: midnight,
          attributionEndSec: midnight + 86400,
        );

        expect(periods, isNotNull);
        expect(
          candidates,
          hasLength(1),
          reason: 'the candidate must survive until reviewed',
        );
        expect(periods, isEmpty);
        expect(sc['nap_min'], 0);
      },
    );

    test(
      'a mid-day nap is unaffected by the leading-edge guard',
      () {
        // Same contiguous-at-midnight record, but the block starts 2 h in.
        final s = _daySubstrate(
          startSec: midnight,
          lengthSec: 6 * 3600,
          napFromSec: 2 * 3600,
          napToSec: 2 * 3600 + napLen,
        );
        final bundle = <String, dynamic>{};
        final sc = <String, dynamic>{};

        final candidates = <Map<String, dynamic>>[];
        final periods = DerivationEngine.debugAttachNaps(
          bundle,
          sc,
          s,
          0,
          0,
          candidates: candidates,
          attributionStartSec: midnight,
          attributionEndSec: midnight + 86400,
        );

        expect(periods, isEmpty);
        expect(candidates, hasLength(1));
        expect((candidates.first['start'] as int) > midnight, isTrue);
      },
    );

    test(
      'a day too short to judge returns NULL, not an empty list',
      () {
        final s = _daySubstrate(
          startSec: midnight,
          lengthSec: 30, // < the 60-sample floor
          napFromSec: 0,
          napToSec: 0,
        );
        final sc = <String, dynamic>{};
        expect(
          DerivationEngine.debugAttachNaps(<String, dynamic>{}, sc, s, 0, 0),
          isNull,
        );
        expect(
          sc.containsKey('nap_min'),
          isFalse,
          reason: 'absent is not zero',
        );
      },
    );


    // CodeRabbit, on the first version of this commit: the abstention paths
    // disagreed about how they encode "unknown". `!m.present` wrote
    // `naps.value: null`; the short-input and error paths returned without
    // writing `naps` at all, so the key was simply missing. Two encodings of
    // one fact, told apart only by HOW the abstention happened.
    test(
      'EVERY abstention publishes the same explicit unknown envelope',
      () {
        final s = _daySubstrate(
          startSec: midnight,
          lengthSec: 30, // below the 60-sample floor
          napFromSec: 0,
          napToSec: 0,
        );
        final bundle = <String, dynamic>{};
        expect(
          DerivationEngine.debugAttachNaps(bundle, <String, dynamic>{}, s, 0, 0),
          isNull,
        );
        expect(
          bundle.containsKey('naps'),
          isTrue,
          reason: 'the key must exist, not be silently missing',
        );
        final naps = bundle['naps'] as Map<String, dynamic>;
        expect(naps['value'], isNull);
        expect(naps['count'], isNull);
        expect(naps['confidence'], 0);
        expect(naps['note'], isNotNull);
      },
    );

    // Also CodeRabbit: the PR threads wristOff/charging into detectNaps but
    // nothing exercised either. A band on a charger is perfectly still and is
    // the dominant nap false positive, so this is the guard doing real work.
    test('a nap-shaped block fully inside an OFF-WRIST span is not a nap', () {
      final s = _daySubstrate(
        startSec: midnight,
        lengthSec: 6 * 3600,
        napFromSec: 2 * 3600,
        napToSec: 2 * 3600 + napLen,
      );
      final sc = <String, dynamic>{};
      final candidates = <Map<String, dynamic>>[];
        final periods = DerivationEngine.debugAttachNaps(
        <String, dynamic>{},
        sc,
        s,
        0,
        0,
        candidates: candidates,
          attributionStartSec: midnight,
        attributionEndSec: midnight + 86400,
        wristOff: [
          [midnight + 2 * 3600 - 60, midnight + 2 * 3600 + napLen + 60],
        ],
      );
      expect(periods, isNotNull, reason: 'judged — the day had data');
      expect(periods, isEmpty, reason: 'a band off the wrist is not asleep');
      expect(sc['nap_min'], 0.0);
    });

    test(
      'analytics#40: a fragment CHAINED onto the edge bout by a brief arousal '
      'is also yesterday\'s, even though it does not itself start at index 0',
      () {
        // bout0 [0, 6min) is too short to be a nap on its own (< 15 min) but
        // still touches index 0, so analytics flags it (and anything chained
        // to it within napChainGapSec) as record-edge. A 10 min arousal
        // separates it from bout1 [16min, 36min) — far enough to NOT bridge
        // into one bout (> napBridgeSec = 5 min) but close enough to still
        // chain as one edge-anchored episode (< napChainGapSec = 1 h). Only
        // bout1 is long enough to be emitted as a nap, with `startSec > 0` —
        // the old `nap.startSec == 0` proxy would have missed it and double
        // -counted the same physical episode today.
        const lengthSec = 6 * 3600;
        final ts = <int>[];
        final hr = <int>[];
        final ax = <double>[], ay = <double>[], az = <double>[];
        for (var i = 0; i < lengthSec; i++) {
          ts.add(midnight + i);
          final inBout0 = i < 6 * 60;
          final inBout1 = i >= 16 * 60 && i < 36 * 60;
          final still = inBout0 || inBout1;
          hr.add(still ? 56 : 78);
          if (still) {
            ax.add(0.0);
            ay.add(0.0);
            az.add(1.0);
          } else {
            final deg = (i % 9) * 10.0;
            final rad = deg * math.pi / 180.0;
            ax.add(math.cos(rad));
            ay.add(0.0);
            az.add(math.sin(rad));
          }
        }
        final s = Substrate(
          tsSec: ts,
          hr: hr,
          rrTsMs: const [],
          rrMs: const [],
          ax: ax,
          ay: ay,
          az: az,
          spo2Red: List<int>.filled(lengthSec, 0),
          spo2Ir: List<int>.filled(lengthSec, 0),
          skinTemp: List<int>.filled(lengthSec, 0),
          skinContact: List<int>.filled(lengthSec, 0),
        );
        final bundle = <String, dynamic>{};
        final sc = <String, dynamic>{};

        final candidates = <Map<String, dynamic>>[];
        final periods = DerivationEngine.debugAttachNaps(
          bundle,
          sc,
          s,
          0,
          0,
          candidates: candidates,
          attributionStartSec: midnight,
          attributionEndSec: midnight + 86400,
        );

        expect(periods, isNotNull, reason: 'the day WAS judged');
        expect(
          periods,
          isEmpty,
          reason:
              'bout1 is chained to the edge-anchored bout0, so it is still '
              "yesterday's tail, not a fresh nap today",
        );
        expect(sc['nap_min'], 0.0);
      },
    );

    test('a nap-shaped block fully inside a CHARGING span is not a nap', () {
      final s = _daySubstrate(
        startSec: midnight,
        lengthSec: 6 * 3600,
        napFromSec: 2 * 3600,
        napToSec: 2 * 3600 + napLen,
      );
      final sc = <String, dynamic>{};
      final candidates = <Map<String, dynamic>>[];
        final periods = DerivationEngine.debugAttachNaps(
        <String, dynamic>{},
        sc,
        s,
        0,
        0,
        candidates: candidates,
          attributionStartSec: midnight,
        attributionEndSec: midnight + 86400,
        charging: [
          [midnight + 2 * 3600 - 60, midnight + 2 * 3600 + napLen + 60],
        ],
      );
      expect(periods, isNotNull);
      expect(periods, isEmpty, reason: 'a band on a charger is not asleep');
      expect(sc['nap_min'], 0.0);
    });
  });
}
