// Regressions for the crashes reported through Crashlytics against 0.9.21.
//
// Each group pins the exact mechanism that reached production, so a future
// refactor that reintroduces it fails here rather than in the field.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/telemetry/error_classification.dart';
import 'package:openstrap_edge/ui/kit/share_origin.dart';
import 'package:openstrap_edge/ui/timeline/timeline_screen.dart';

void main() {
  group('activityBandExtent (the inverted clamp)', () {
    // The painter used `x1.clamp(x0 + 1, size.width)`. x(t) saturates at
    // size.width, so a band starting in the final pixel made lowerLimit exceed
    // upperLimit and double.clamp threw — reported from JourneyScreen as
    // "Invalid argument(s): 330.7788280945566" (the value IS x0 + 1).
    const w = 330.7788280945566;

    void expectSane(({double left, double right}) e) {
      expect(e.left, lessThanOrEqualTo(e.right),
          reason: 'an inverted rect is the crash');
      expect(e.right, lessThanOrEqualTo(w));
      expect(e.right - e.left, greaterThanOrEqualTo(1.0),
          reason: 'a band must stay visible');
    }

    test('a band starting exactly at the right edge', () {
      expectSane(activityBandExtent(w, w, w));
    });

    test('a band starting within the last pixel', () {
      // The exact production case: x0 = 329.7788, so x0 + 1 > width.
      expectSane(activityBandExtent(w - 0.2, w, w));
    });

    test('a zero-length band mid-plot still gets a visible width', () {
      final e = activityBandExtent(100, 100, w);
      expect(e.right - e.left, 1.0);
    });

    test('an end before its start does not invert', () {
      expectSane(activityBandExtent(200, 100, w));
    });

    test('an ordinary band is left untouched', () {
      final e = activityBandExtent(40, 200, w);
      expect(e.left, 40);
      expect(e.right, 200);
    });

    test('the old expression really did throw on these inputs', () {
      // Pins WHY the function exists: without it, this is the production crash.
      expect(() => w.clamp(w + 1, w), throwsArgumentError);
    });
  });

  group('shareOriginFor', () {
    // iOS 26 rejects a missing origin AND a zero one, so `null` was never a
    // safe fallback — it is the crashing input.
    testWidgets('returns the widget rect when laid out', (tester) async {
      late Rect origin;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          origin = shareOriginFor(context);
          return const SizedBox(width: 100, height: 40);
        }),
      ));
      expect(origin.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
    });

    testWidgets('falls back to a non-zero rect with no render box',
        (tester) async {
      late Rect origin;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          // A LayoutBuilder's context has no RenderBox of its own at this point.
          origin = shareOriginFor(context);
          return const SizedBox.shrink();
        }),
      ));
      expect(origin.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
      expect(origin, isNot(Rect.zero));
    });
  });

  group('isTransientError', () {
    test('network failures are not crashes', () {
      for (final e in [
        "ClientException with SocketException: Failed host lookup: "
            "'c.basemaps.cartocdn.com' (OS Error: No address associated with "
            'hostname, errno = 7)',
        'SocketException: Network is unreachable (OS Error: Network is '
            'unreachable, errno = 51)',
        'HandshakeException: Connection terminated during handshake',
        'ClientException: Connection closed while receiving data',
      ]) {
        expect(isTransientError(_Err(e)), isTrue, reason: e);
      }
    });

    test('real defects still count as crashes', () {
      expect(isTransientError(ArgumentError('330.77')), isFalse);
      expect(isTransientError(StateError('readiness_absent')), isFalse);
      expect(isTransientError(_Err('Null check operator used on a null value')),
          isFalse);
    });
  });

  group('carryForwardDetail', () {
    // A timed-out second half produced a headline-only bundle, and putDayResult
    // replaces the row wholesale — so re-deriving a complete day destroyed its
    // naps, workouts, HRR, wear and curves.
    test('restores detail blocks the failed pass never produced', () {
      final prev = <String, dynamic>{
        'scalars': {'readiness': 71.0, 'nap_min': 24.0},
        'series': {'rhr': 52.0},
        'naps': [
          {'start': 1, 'end': 2}
        ],
        'sessions': [
          {'sport': 'run'}
        ],
      };
      final next = <String, dynamic>{
        'scalars': {'readiness': 68.0},
        'series': {'rhr': 53.0},
      };

      expect(DerivationEngine.carryForwardDetail(prev, next), isTrue);
      expect(next['naps'], prev['naps']);
      expect(next['sessions'], prev['sessions']);
      // Second-half scalar restored...
      expect((next['scalars'] as Map)['nap_min'], 24.0);
      // ...but the freshly computed headline always wins.
      expect((next['scalars'] as Map)['readiness'], 68.0);
      expect((next['series'] as Map)['rhr'], 53.0);
    });

    test('a deliberate null is absence, not a hole to backfill', () {
      // Isolate 1 succeeded and measured no readiness today. Carrying yesterday's
      // value forward would fabricate a metric — the honesty contract forbids it.
      final prev = <String, dynamic>{
        'scalars': {'readiness': 71.0},
      };
      final next = <String, dynamic>{
        'scalars': {'readiness': null},
      };
      DerivationEngine.carryForwardDetail(prev, next);
      expect((next['scalars'] as Map)['readiness'], isNull);
    });

    test('reports nothing carried when the previous result was no richer', () {
      final prev = <String, dynamic>{
        'scalars': {'readiness': 71.0},
      };
      final next = <String, dynamic>{
        'scalars': {'readiness': 68.0},
      };
      expect(DerivationEngine.carryForwardDetail(prev, next), isFalse);
    });
  });

  group('recoveryOutcome (cross-version carry-forward)', () {
    // dayResult returns the HIGHEST algo_version stored, so right after a bump
    // the row handed back is the previous version's. Carrying its detail into a
    // current-version row and marking that finished would lock last version's
    // curves in under this version's number — and the bump exists precisely
    // because those curves are computed differently now.
    test('a same-version carry restores completeness', () {
      final r = DerivationEngine.recoveryOutcome(
        recovered: true,
        prevPartial: false,
        prevVersion: kAlgoVersion,
        prevFinalized: true,
        finalizedByAge: false,
      );
      expect(r.partial, isFalse);
      expect(r.finalized, isTrue, reason: 'keeps the flag it had earned');
    });

    test('a cross-version carry stays partial and unfinalized', () {
      final r = DerivationEngine.recoveryOutcome(
        recovered: true,
        prevPartial: false,
        prevVersion: kAlgoVersion - 1,
        prevFinalized: true,
        finalizedByAge: false,
      );
      expect(r.partial, isTrue,
          reason: 'a later pass must recompute it for real');
      expect(r.finalized, isFalse,
          reason: 'never lock the previous version detail in as current');
    });

    test('carrying from an already-partial row stays partial', () {
      final r = DerivationEngine.recoveryOutcome(
        recovered: true,
        prevPartial: true,
        prevVersion: kAlgoVersion,
        prevFinalized: false,
        finalizedByAge: false,
      );
      expect(r.partial, isTrue);
    });

    test('an import still force-finalizes a partial day', () {
      // There is no stored raw to recompute an import from, so forceFinalize
      // must survive the version gate.
      final r = DerivationEngine.recoveryOutcome(
        recovered: true,
        prevPartial: false,
        prevVersion: kAlgoVersion - 1,
        prevFinalized: false,
        finalizedByAge: true,
      );
      expect(r.partial, isTrue);
      expect(r.finalized, isTrue);
    });

    test('nothing carried leaves the day partial', () {
      final r = DerivationEngine.recoveryOutcome(
        recovered: false,
        prevPartial: false,
        prevVersion: kAlgoVersion,
        prevFinalized: true,
        finalizedByAge: false,
      );
      expect(r.partial, isTrue);
      expect(r.finalized, isFalse);
    });
  });

  group('day curve cadence (the per-beat rework)', () {
    // Both curves left their cadence cursor behind whenever an estimate came
    // back unusable, so the next beat re-entered and redid the whole window.
    // For respiration that window is a triple Lomb-Scargle, which is what
    // exhausted the 90 s day-blocks budget.
    Substrate subFromRr(List<double> rrMs, {int startSec = 1786100000}) {
      final tsMs = <double>[];
      var t = startSec * 1000.0;
      for (final r in rrMs) {
        t += r;
        tsMs.add(t);
      }
      final secs = <int>[for (var i = 0; i < 10; i++) startSec + i];
      return Substrate(
        tsSec: secs,
        hr: List<int>.filled(secs.length, 60),
        rrTsMs: tsMs,
        rrMs: rrMs,
        ax: List<double>.filled(secs.length, 0),
        ay: List<double>.filled(secs.length, 0),
        az: List<double>.filled(secs.length, 1),
        spo2Red: List<int>.filled(secs.length, 0),
        spo2Ir: List<int>.filled(secs.length, 0),
        skinTemp: List<int>.filled(secs.length, 0),
        skinContact: List<int>.filled(secs.length, 0),
      );
    }

    // ~2 hours of clean beats, then the emission count is bounded by the
    // cadence. Before the fix an attempt could recur every beat; the cursor now
    // moves on every attempt, so the count can never exceed span/cadence.
    List<double> clean(int n) =>
        [for (var i = 0; i < n; i++) 850.0 + (i % 7) * 10];

    // Alternating long/short pairs trip the Malik 20% ectopic reject, so a
    // window yields too few usable pairs to estimate — the branch that used to
    // leave the cursor behind.
    List<double> artifacty(int n) =>
        [for (var i = 0; i < n; i++) i.isEven ? 400.0 : 1600.0];

    test('hrv points are never closer than the 60 s cadence', () {
      final pts = DerivationEngine.dayHrvCurve(subFromRr(clean(8000)));
      expect(pts, isNotEmpty);
      for (var i = 1; i < pts.length; i++) {
        expect(pts[i]['t']! - pts[i - 1]['t']!, greaterThanOrEqualTo(60));
      }
    });

    test('respiration points are never closer than the 5 min cadence', () {
      final pts = DerivationEngine.dayRespCurve(subFromRr(clean(8000)));
      for (var i = 1; i < pts.length; i++) {
        expect(pts[i]['t']! - pts[i - 1]['t']!, greaterThanOrEqualTo(300));
      }
    });

    test('an absent estimate still advances the 5 min cursor', () {
      // THE regression. With the estimator forced to abstain, the fixed code
      // attempts once per cadence interval; the old code attempted once per
      // BEAT, because lastEmit only moved inside the success branch.
      addTearDown(() {
        DerivationEngine.debugRespEstimator = null;
        DerivationEngine.debugRespAttempts = 0;
      });
      DerivationEngine.debugRespEstimator = (_, _) => null;
      DerivationEngine.debugRespAttempts = 0;

      final rr = clean(8000); // ~7000 s of beats at ~880 ms
      final sub = subFromRr(rr);
      final spanSec = rr.reduce((a, b) => a + b) / 1000;
      final pts = DerivationEngine.dayRespCurve(sub);

      expect(pts, isEmpty, reason: 'an absent estimate must emit nothing');
      // One attempt per 5 min of span, plus a little slack. The old code would
      // land in the thousands here.
      final cadenceCeiling = (spanSec / 300).ceil() + 2;
      expect(DerivationEngine.debugRespAttempts,
          lessThanOrEqualTo(cadenceCeiling),
          reason: 'the estimator must not re-run per beat while abstaining');
      expect(DerivationEngine.debugRespAttempts, greaterThan(1),
          reason: 'it must still keep trying across the day');
    });

    test('a usable window after an absent stretch still emits', () {
      // Advancing on failure must not silence the curve once quality returns.
      addTearDown(() {
        DerivationEngine.debugRespEstimator = null;
        DerivationEngine.debugRespAttempts = 0;
      });
      var calls = 0;
      DerivationEngine.debugRespEstimator = (_, _) {
        calls++;
        return calls <= 3 ? null : 14.5;
      };
      final pts = DerivationEngine.dayRespCurve(subFromRr(clean(8000)));
      expect(pts, isNotEmpty);
      expect(pts.first['v'], 14.5);
    });

    test('an unusable stretch emits nothing and does not re-run per beat', () {
      // Alternating long/short pairs trip the Malik reject, so no window ever
      // reaches 8 usable pairs — the branch that used to strand the cursor.
      addTearDown(() => DerivationEngine.debugHrvAttempts = 0);
      DerivationEngine.debugHrvAttempts = 0;
      final rr = artifacty(6000);
      final spanSec = rr.reduce((a, b) => a + b) / 1000;
      expect(DerivationEngine.dayHrvCurve(subFromRr(rr)), isEmpty);
      expect(DerivationEngine.debugHrvAttempts,
          lessThanOrEqualTo((spanSec / 60).ceil() + 2),
          reason: 'the window sum must not re-run per beat while unusable');
    });

    test('a clean stretch after an unusable one still produces points', () {
      // Advancing on failure must not silence the curve once quality returns.
      final pts = DerivationEngine.dayHrvCurve(
        subFromRr([...artifacty(2000), ...clean(6000)]),
      );
      expect(pts, isNotEmpty);
    });
  });
}

/// Stands in for the platform exception types, which carry their identity in
/// their message the same way `ClientException` does.
class _Err implements Exception {
  final String message;
  const _Err(this.message);
  @override
  String toString() => message;
}
