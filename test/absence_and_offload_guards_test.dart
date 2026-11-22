// Guards for the "absence read as a measurement" defect class, plus the two
// offload guards that were structurally bypassable.
//
// Each group here corresponds to a shipped bug, not a hypothetical:
//   * a run of absent accelerometer seconds read as a perfectly still wrist to
//     ENMO, immobility, the activity curve and auto-workout detection;
//   * a corrupt-but-CRC-valid HR byte of 250 on the gen4 TRUSTED decode path
//     became the day's max heart rate;
//   * a burst the band counted more frames in than we received was logged and
//     then handed a trim authorisation anyway, so the gap left flash forever;
//   * one non-finite double made `jsonEncode` throw and dropped the ENTIRE
//     cross-day bundle — every user, first week.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';

/// A substrate of [n] seconds where the seconds in [absent] carry no gravity
/// vector (the positional absent marker, exact `(0,0,0)`).
Substrate _sub({required int n, Set<int> absent = const {}}) {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (var i = 0; i < n; i++) {
    ts.add(1780000000 + i);
    hr.add(60);
    final gone = absent.contains(i);
    ax.add(gone ? 0 : 0.1);
    ay.add(gone ? 0 : 0.2);
    az.add(gone ? 0 : 0.95);
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
  );
}

void main() {
  group('accelSamples marks absent seconds invalid, never still', () {
    test('an absent second is carried, but not as a reading', () {
      final s = _sub(n: 10, absent: {3, 4});
      final samples = s.accelSamples();
      // 1:1 with tsSec — dropping them would shift every downstream index.
      expect(samples.length, 10);
      expect(samples[3].valid, isFalse);
      expect(samples[4].valid, isFalse);
      expect(samples[0].valid, isTrue);
    });

    test('the analytics readers that filter on `valid` do not see them', () {
      // enmoSeries filters `valid`, so an all-absent stream has nothing to
      // score — no minutes, rather than a full set of maximally-still ones.
      final absent = _sub(n: 600, absent: {for (var i = 0; i < 600; i++) i});
      expect(ana.enmoSeries(absent.accelSamples()).minutes, isEmpty);
      final present = _sub(n: 600);
      expect(ana.enmoSeries(present.accelSamples()).minutes, isNotEmpty);
    });
  });

  group('plausibleHrOrNull — the gen4 trusted path had no upper bound', () {
    test('a physiological HR passes through untouched', () {
      expect(plausibleHrOrNull(60), 60);
      expect(plausibleHrOrNull(kMinPlausibleHr), kMinPlausibleHr);
      expect(plausibleHrOrNull(kMaxPlausibleHr), kMaxPlausibleHr);
    });

    test('an impossible HR reads ABSENT, and is never clamped into range', () {
      // 250 used to pass the `hr > 0` filter and become the displayed max HR.
      expect(plausibleHrOrNull(250), isNull);
      expect(plausibleHrOrNull(255), isNull);
      expect(plausibleHrOrNull(7), isNull);
      // Clamping would have produced a plausible-looking 230/25 — a number the
      // wrist never reported.
      expect(plausibleHrOrNull(250), isNot(kMaxPlausibleHr));
    });

    test('a zero reading is not a heart rate either', () {
      expect(plausibleHrOrNull(0), isNull);
    });
  });


  group('TrimAckPolicy — the shortfall refusal is last, and only post-commit',
      () {
    TrimAckVerdict eval({bool shortfall = false, bool durable = true}) =>
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: durable,
          shortfallRetry: shortfall,
        );

    test('no shortfall still sends', () => expect(eval(), TrimAckVerdict.send));

    test('a shortfall withholds the token', () {
      expect(eval(shortfall: true), TrimAckVerdict.blockedBurstShortfall);
    });

    test('a hard block still outranks it', () {
      // The others mean "this chunk must not be trimmed at all"; shortfall
      // means "ask for it again". Reporting the weaker reason would lose the
      // stronger one from the ledger.
      expect(eval(shortfall: true, durable: false),
          TrimAckVerdict.blockedCommitFailed);
    });
  });

  group('sanitizeForJson — one bad leaf must not cost the whole artifact', () {
    test('a NaN becomes absent and is recorded by path', () {
      final dropped = <String>[];
      final out = sanitizeForJson({
        'readiness_glassbox': {
          'value': {
            'items': [
              {'label': 'hrv', 'percentile_of_you': double.nan},
            ],
          },
        },
        'vo2max': {'value': 42.0},
      }, dropped);
      // Everything that CAN be encoded still is.
      expect(jsonEncode(out), contains('"vo2max"'));
      expect(jsonEncode(out), contains('42'));
      expect(dropped, [
        'readiness_glassbox.value.items[0].percentile_of_you',
      ]);
    });

    test('infinities go too, and a clean bundle is untouched', () {
      final dropped = <String>[];
      final clean = {
        'a': 1,
        'b': 'two',
        'c': [1.5, true, null],
        'd': {'e': 3.25},
      };
      expect(sanitizeForJson(clean, dropped), clean);
      expect(dropped, isEmpty);

      expect(sanitizeForJson(double.infinity, dropped), isNull);
      expect(sanitizeForJson(double.negativeInfinity, dropped), isNull);
      expect(dropped.length, 2);
    });

    test('an object with no JSON form is dropped, not thrown', () {
      final dropped = <String>[];
      final out = sanitizeForJson(
          {'when': DateTime.utc(2026), 'n': 1}, dropped) as Map;
      expect(out['when'], isNull);
      expect(out['n'], 1);
      expect(dropped, ['when']);
      expect(() => jsonEncode(out), returnsNormally);
    });

    test('the whole point: the encode no longer throws', () {
      final bundle = {'x': double.nan};
      expect(() => jsonEncode(bundle), throwsA(isA<JsonUnsupportedObjectError>()));
      expect(() => jsonEncode(sanitizeForJson(bundle, [])), returnsNormally);
    });
  });

  _respGroups();
}

// ── RESP-05 / TS-03 — the two motion gates wired in this pass ────────────────
//
// Both are the same rule as the groups above, applied at a different seam: a
// second with no gravity vector is ABSENT, and absence may neither corroborate
// an effort nor certify stillness. And both are per-FAMILY, so an unstamped
// strap gets no answer rather than gen4's.

/// A substrate of [n] seconds carrying RR beats at a fixed 1 s interval, with
/// the seconds in [moving] holding a large gravity swing.
Substrate _rrSub({
  required int n,
  Set<int> moving = const {},
  Set<int> absent = const {},
  String? family = 'gen4',
  int hrBpm = 60,
  double stillAz = 1.005,
}) {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  final rrTs = <double>[], rr = <double>[];
  for (var i = 0; i < n; i++) {
    final t = 1780000000 + i;
    ts.add(t);
    hr.add(hrBpm);
    if (absent.contains(i)) {
      ax.add(0);
      ay.add(0);
      az.add(0);
    } else if (moving.contains(i)) {
      ax.add(0.0);
      ay.add(0.0);
      az.add(1.30); // |‖a‖−1| = 0.30 g, far above the 0.02 g quiet cut
    } else {
      ax.add(0.0);
      ay.add(0.0);
      az.add(stillAz); // still
    }
    // One beat per second, gently modulated so the estimator has something to
    // chew on. The gate runs BEFORE the estimator, so its result is irrelevant.
    rrTs.add(t * 1000.0);
    rr.add(1000.0 + 40.0 * (i % 5 - 2));
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: rrTs,
    rrMs: rr,
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    deviceFamily: family,
  );
}

void _respGroups() {
  group('RESP-05 — the resting-breathing curve is motion-gated', () {
    test('a still hour is attempted; the same hour spent moving is not', () {
      DerivationEngine.debugRespGateRejects = 0;
      DerivationEngine.debugRespAttempts = 0;
      DerivationEngine.dayRespCurve(_rrSub(n: 1800));
      final stillAttempts = DerivationEngine.debugRespAttempts;
      expect(stillAttempts, greaterThan(0));
      expect(DerivationEngine.debugRespGateRejects, 0);

      DerivationEngine.debugRespGateRejects = 0;
      DerivationEngine.debugRespAttempts = 0;
      DerivationEngine.dayRespCurve(
        _rrSub(n: 1800, moving: {for (var i = 0; i < 1800; i += 4) i}),
      );
      // Nothing reached the triple Lomb-Scargle: that is the whole point, and
      // it is where the perf win is banked.
      expect(DerivationEngine.debugRespAttempts, 0);
      expect(DerivationEngine.debugRespGateRejects, greaterThan(0));
    });

    test('a still wrist reading 1.03 g is still, not moving', () {
      // |a| sits near 1.03 g on a real band; the gate must read movement,
      // not the posture's offset from 1 g.
      DerivationEngine.debugRespGateRejects = 0;
      DerivationEngine.debugRespAttempts = 0;
      final sub = _rrSub(n: 1800, stillAz: 1.03);
      DerivationEngine.dayRespCurve(sub);
      expect(DerivationEngine.debugRespAttempts, greaterThan(0));
      expect(DerivationEngine.debugRespGateRejects, 0);
      expect(DerivationEngine.daytimeHrv(sub, 0, 0)['n_buckets'],
          greaterThan(0));
    });

    test('absent accel is not stillness — it rejects like motion does', () {
      DerivationEngine.debugRespAttempts = 0;
      DerivationEngine.dayRespCurve(
        _rrSub(n: 1800, absent: {for (var i = 0; i < 1800; i++) i}),
      );
      expect(DerivationEngine.debugRespAttempts, 0);
    });

    test('an unstamped strap gets no curve, not gen4\'s cut', () {
      DerivationEngine.debugRespAttempts = 0;
      expect(DerivationEngine.dayRespCurve(_rrSub(n: 1800, family: null)),
          isEmpty);
      expect(DerivationEngine.debugRespAttempts, 0);
    });
  });

  group('TS-03 — the day\'s observed HR ceiling', () {
    List<Map<String, dynamic>> session(int n) => [
          {
            'id': 's1',
            'type': 'run',
            'start_ts': 1780000000,
            'end_ts': 1780000000 + n,
          }
        ];

    test('a held, corroborated high HR sets it; a 2 s spike does not', () {
      // 60 s of movement at 170 bpm — held and corroborated.
      final held = _rrSub(
        n: 60,
        moving: {for (var i = 0; i < 60; i++) i},
        hrBpm: 170,
      );
      final out = DerivationEngine.dayHrCeiling(held, session(60));
      expect((out['value'] as Map)['bpm'], 170);
      expect(out['session_id'], 's1');
      expect(out['session_type'], 'run');

      // The same session, still: a high HR with no movement is a stress
      // response, a fever or an artifact — never a ceiling.
      final stillHigh = _rrSub(n: 60, hrBpm: 170);
      expect(DerivationEngine.dayHrCeiling(stillHigh, session(60))['value'],
          '—');
    });

    test('an unstamped strap refuses rather than borrowing gen4\'s gate', () {
      final s = _rrSub(
        n: 60,
        moving: {for (var i = 0; i < 60; i++) i},
        hrBpm: 170,
        family: null,
      );
      expect(DerivationEngine.dayHrCeiling(s, session(60))['value'], '—');
    });

    test('no saved session on the day is an honest absence, not a zero', () {
      final out = DerivationEngine.dayHrCeiling(_rrSub(n: 60), const []);
      expect(out['value'], '—');
      expect(out['confidence'], 0);
      expect(out.containsKey('session_id'), isFalse);
    });
  });
}
