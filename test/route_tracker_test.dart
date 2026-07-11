// Tests for RouteTracker: buffering, batched persistence, de-noising, and the
// live ValueNotifiers — driven by a FAKE GpsSample stream and a fake sink (no
// geolocator, no DB).

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gps/route_models.dart';
import 'package:openstrap_edge/gps/route_tracker.dart';

const double _mPerDegLngAtEq = 111319.49;

GpsSample _fix(
  int i, {
  double stepMeters = 20,
  double? accuracy,
  double? speed,
}) => GpsSample(
  lat: 0,
  lng: i * (stepMeters / _mPerDegLngAtEq),
  tsMs: i * 1000,
  accuracy: accuracy,
  speed: speed,
);

void main() {
  test('flushes a batch once batchSize points buffer', () async {
    final batches = <List<RoutePoint>>[];
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (b) async => batches.add(b),
      batchSize: 4,
    );
    t.start(ctrl.stream);

    for (var i = 0; i < 4; i++) {
      ctrl.add(_fix(i));
    }
    await pumpEventQueue();

    expect(batches.length, 1);
    expect(batches.first.length, 4);
    // seq is monotonic from 0.
    expect(batches.first.map((p) => p.seq).toList(), [0, 1, 2, 3]);
    expect(t.pointCount, 4);

    await t.stop();
    await ctrl.close();
  });

  test('stop() flushes the buffered tail', () async {
    final batches = <List<RoutePoint>>[];
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(sink: (b) async => batches.add(b), batchSize: 10);
    t.start(ctrl.stream);

    for (var i = 0; i < 3; i++) {
      ctrl.add(_fix(i));
    }
    await pumpEventQueue();
    expect(batches, isEmpty); // below batchSize, not yet flushed

    await t.stop();
    expect(batches.length, 1);
    expect(batches.first.length, 3);

    await ctrl.close();
  });

  test('drops low-accuracy fixes', () async {
    final batches = <List<RoutePoint>>[];
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (b) async => batches.add(b),
      batchSize: 2,
      maxAccuracyM: 30,
    );
    t.start(ctrl.stream);

    ctrl.add(_fix(0, accuracy: 8)); // good
    ctrl.add(_fix(1, accuracy: 99)); // dropped (99 > 30)
    ctrl.add(_fix(2, accuracy: 10)); // good → triggers flush at 2
    await pumpEventQueue();

    expect(t.pointCount, 2);
    expect(batches.single.length, 2);

    await t.stop();
    await ctrl.close();
  });

  test('rejects an implausible GPS spike', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (_) async {},
      batchSize: 100,
      maxJumpM: 200,
    );
    t.start(ctrl.stream);

    ctrl.add(_fix(0));
    // A 5 km jump in one step — a spike, should be rejected.
    ctrl.add(GpsSample(lat: 0, lng: 5000 / _mPerDegLngAtEq, tsMs: 1000));
    ctrl.add(_fix(1)); // near the first point again
    await pumpEventQueue();

    // Spike excluded → 2 accepted points.
    expect(t.pointCount, 2);
    await t.stop();
    await ctrl.close();
  });

  test('updates path / current / distance notifiers', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (_) async {},
      batchSize: 100,
      zoneNow: () => 3,
    );
    t.start(ctrl.stream);

    ctrl.add(_fix(0, stepMeters: 20));
    ctrl.add(_fix(1, stepMeters: 20));
    ctrl.add(_fix(2, stepMeters: 20));
    await pumpEventQueue();

    expect(t.path.value.length, 3);
    expect(t.path.value.first.zone, 3); // live zone stamped
    expect(t.current.value, isNotNull);
    // Two 20 m segments ≈ 40 m.
    expect(t.distanceMeters.value, closeTo(40, 2));

    await t.stop();
    await ctrl.close();
  });

  test('recovers after a real gap: N consecutive rejections start a fresh '
      'anchor segment (no distance for the jump)', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (_) async {},
      batchSize: 100,
      maxJumpM: 200,
      rejectStreakLimit: 3,
    );
    t.start(ctrl.stream);

    // Two 20 m fixes → ~20 m of distance.
    ctrl.add(_fix(0));
    ctrl.add(_fix(1));
    await pumpEventQueue();
    final distBefore = t.distanceMeters.value;

    // The athlete goes through a tunnel: fixes resume 5 km away, 1 s apart
    // (implausible vs the stale anchor). Old behavior: rejected FOREVER.
    double km5(int i) => (5000 + i * 20) / _mPerDegLngAtEq;
    ctrl.add(GpsSample(lat: 0, lng: km5(0), tsMs: 2000)); // reject #1
    ctrl.add(GpsSample(lat: 0, lng: km5(1), tsMs: 3000)); // reject #2
    ctrl.add(GpsSample(lat: 0, lng: km5(2), tsMs: 4000)); // #3 → fresh anchor
    ctrl.add(GpsSample(lat: 0, lng: km5(3), tsMs: 5000)); // normal again
    await pumpEventQueue();

    // The anchor fix + the follow-up were accepted (2 + the original 2).
    expect(t.pointCount, 4);
    // The 5 km jump added NO distance; only the post-gap 20 m segment did.
    expect(t.distanceMeters.value - distBefore, closeTo(20, 2));
    // The polyline breaks at the fresh anchor (no straight line across the gap).
    expect(t.path.value[2].gapBefore, isTrue);
    expect(t.path.value[3].gapBefore, isFalse);

    await t.stop();
    await ctrl.close();
  });

  test('speed-based allowance: a far fix after a LONG gap is plausible travel '
      '(distance counted, no segment break)', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(sink: (_) async {}, batchSize: 100, maxJumpM: 200);
    t.start(ctrl.stream);

    ctrl.add(_fix(0));
    // 400 m away but 60 s later → 6.7 m/s, well under the plausible max.
    ctrl.add(GpsSample(lat: 0, lng: 400 / _mPerDegLngAtEq, tsMs: 60000));
    await pumpEventQueue();

    expect(t.pointCount, 2);
    expect(t.distanceMeters.value, closeTo(400, 5));
    expect(t.path.value[1].gapBefore, isFalse);

    await t.stop();
    await ctrl.close();
  });

  test('movingSeconds sums inter-fix time but excludes >60s gaps', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(sink: (_) async {}, batchSize: 100);
    t.start(ctrl.stream);

    ctrl.add(_fix(0)); // t=0
    ctrl.add(_fix(1)); // t=1s → +1
    ctrl.add(_fix(2)); // t=2s → +1
    // 5-minute pause (no fixes), then resume nearby: gap excluded.
    ctrl.add(GpsSample(lat: 0, lng: 3 * 20 / _mPerDegLngAtEq, tsMs: 302000));
    ctrl.add(GpsSample(lat: 0, lng: 4 * 20 / _mPerDegLngAtEq, tsMs: 303000));
    await pumpEventQueue();

    expect(t.movingSeconds, 3); // 1 + 1 + (gap skipped) + 1

    await t.stop();
    await ctrl.close();
  });

  test('stop() retries the tail flush once when the sink fails', () async {
    var calls = 0;
    final persisted = <RoutePoint>[];
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (b) async {
        calls++;
        if (calls == 1) throw Exception('disk busy');
        persisted.addAll(b);
      },
      batchSize: 100, // never auto-flushes — everything rides on stop()
    );
    t.start(ctrl.stream);

    ctrl.add(_fix(0));
    ctrl.add(_fix(1));
    await pumpEventQueue();

    await t.stop();
    // First flush threw; the retry persisted the tail instead of dropping it.
    expect(calls, 2);
    expect(persisted.length, 2);

    await ctrl.close();
  });

  test('surfaces a stream error instead of waiting forever', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(sink: (_) async {}, batchSize: 100);
    t.start(ctrl.stream);

    ctrl.addError(Exception('location service died'));
    await pumpEventQueue();
    expect(t.error.value, isNotNull);

    // A fix arriving again clears the error.
    ctrl.add(_fix(0));
    await pumpEventQueue();
    expect(t.error.value, isNull);

    await t.stop();
    await ctrl.close();
  });

  test('re-queues a batch when the sink throws, retries on next flush',
      () async {
    var calls = 0;
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (b) async {
        calls++;
        if (calls == 1) throw Exception('disk busy');
      },
      batchSize: 2,
    );
    t.start(ctrl.stream);

    ctrl.add(_fix(0));
    ctrl.add(_fix(1)); // flush #1 → throws, re-queued
    await pumpEventQueue();
    ctrl.add(_fix(2));
    ctrl.add(_fix(3)); // flush #2 → succeeds with re-queued tail
    await pumpEventQueue();

    // Nothing lost: the tracker still holds all 4 points.
    expect(t.pointCount, 4);
    expect(calls, greaterThanOrEqualTo(2));

    await t.stop();
    await ctrl.close();
  });

  test('currentSpeedMps smooths the platform-reported speed', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(sink: (_) async {}, batchSize: 100);
    t.start(ctrl.stream);

    ctrl.add(_fix(0, speed: 3.0));
    await pumpEventQueue();
    expect(t.currentSpeedMps.value, 3.0); // first sample, unsmoothed

    ctrl.add(_fix(1, speed: 30.0)); // one wild spike
    await pumpEventQueue();
    // Damped by the EMA, not jumped straight to 30.
    expect(t.currentSpeedMps.value, isNotNull);
    expect(t.currentSpeedMps.value!, lessThan(15));
    expect(t.currentSpeedMps.value!, greaterThan(3.0));

    await t.stop();
    await ctrl.close();
  });

  test('currentSpeedMps clamps an implausible platform-reported speed '
      'before smoothing, not just after', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(sink: (_) async {}, batchSize: 100);
    t.start(ctrl.stream);

    ctrl.add(_fix(0, speed: 3.0));
    await pumpEventQueue();

    // A platform-reported speed way beyond any plausible run/ride/walk —
    // a Doppler/multipath glitch, not real motion.
    ctrl.add(_fix(1, speed: 50.0));
    await pumpEventQueue();

    // Clamped to kMaxPlausibleSpeedMps (25) BEFORE the EMA runs, so the
    // result is bounded by smoothing toward 25, never toward 50.
    final v = t.currentSpeedMps.value!;
    final maxIfClampedFirst = 3.0 + 0.15 * (25.0 - 3.0); // ~6.3
    expect(v, lessThanOrEqualTo(maxIfClampedFirst + 0.01));

    await t.stop();
    await ctrl.close();
  });

  test(
    'currentSpeedMps falls back to a fix-to-fix derivation when the '
    'platform reports none',
    () async {
      final ctrl = StreamController<GpsSample>();
      final t = RouteTracker(sink: (_) async {}, batchSize: 100);
      t.start(ctrl.stream);

      // No `speed` on either fix — platform doesn't report it.
      ctrl.add(_fix(0, stepMeters: 20));
      ctrl.add(_fix(1, stepMeters: 40)); // 20 m in 1 s ≈ 20 m/s
      await pumpEventQueue();

      expect(t.currentSpeedMps.value, isNotNull);
      expect(t.currentSpeedMps.value!, greaterThan(0));

      await t.stop();
      await ctrl.close();
    },
  );

  test('stalled flips true after stallAfter with no accepted fix, and '
      'clears the moment a fix resumes', () {
    fakeAsync((async) {
      final ctrl = StreamController<GpsSample>();
      final t = RouteTracker(
        sink: (_) async {},
        batchSize: 100,
        stallAfter: const Duration(seconds: 15),
      );
      t.start(ctrl.stream);

      ctrl.add(_fix(0));
      async.flushMicrotasks();
      expect(t.stalled.value, isFalse);

      // Silence for longer than stallAfter — no error, just nothing arriving
      // (exactly the "silently stopped, never errored" gap this closes).
      async.elapse(const Duration(seconds: 16));
      expect(t.stalled.value, isTrue);
      expect(t.error.value, isNull); // NOT an error — distinct signal

      // A fix arrives again → clears immediately, no need to wait out the
      // watchdog's next poll.
      ctrl.add(GpsSample(lat: 0, lng: 0.001, tsMs: 16000));
      async.flushMicrotasks();
      expect(t.stalled.value, isFalse);

      unawaited(t.stop());
      async.flushMicrotasks();
      unawaited(ctrl.close());
    });
  });

  test('drops GPS-noise-floor jitter: no distance, no new vertex, anchor '
      'unchanged', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (_) async {},
      batchSize: 100,
      minMovementM: 5,
    );
    t.start(ctrl.stream);

    ctrl.add(_fix(0, stepMeters: 0)); // anchor at lng=0
    // Three fixes jittering back and forth within 5 m of the anchor —
    // classic stationary multipath drift (e.g. lying in bed).
    ctrl.add(GpsSample(lat: 0, lng: 2 / _mPerDegLngAtEq, tsMs: 1000));
    ctrl.add(GpsSample(lat: 0, lng: -1 / _mPerDegLngAtEq, tsMs: 2000));
    ctrl.add(GpsSample(lat: 0, lng: 3 / _mPerDegLngAtEq, tsMs: 3000));
    await pumpEventQueue();

    // Only the anchor itself was accepted — every jitter fix was dropped.
    expect(t.pointCount, 1);
    expect(t.distanceMeters.value, 0);
    expect(t.path.value.length, 1);

    await t.stop();
    await ctrl.close();
  });

  test('genuine slow movement still accumulates across noise-floor drops, '
      'captured coarsely once it clears the floor', () async {
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(
      sink: (_) async {},
      batchSize: 100,
      minMovementM: 5,
    );
    t.start(ctrl.stream);

    ctrl.add(_fix(0, stepMeters: 0)); // anchor
    // Each step is only 2 m from the PREVIOUS raw fix, but since dropped
    // fixes never advance the anchor, distance-from-anchor keeps growing:
    // 2 m, 4 m (still < 5 m floor, both dropped)... then 6 m clears it.
    ctrl.add(GpsSample(lat: 0, lng: 2 / _mPerDegLngAtEq, tsMs: 1000));
    ctrl.add(GpsSample(lat: 0, lng: 4 / _mPerDegLngAtEq, tsMs: 2000));
    ctrl.add(GpsSample(lat: 0, lng: 6 / _mPerDegLngAtEq, tsMs: 3000));
    await pumpEventQueue();

    // The anchor + the one fix that finally cleared the floor.
    expect(t.pointCount, 2);
    expect(t.distanceMeters.value, closeTo(6, 0.5)); // full distance kept
    expect(t.path.value.length, 2);

    await t.stop();
    await ctrl.close();
  });

  test('a route dominated by stationary jitter keeps a tight, real bounding '
      'box (no phantom vertices to inflate it)', () async {
    // Regression for the map-zoom bug: a stationary period used to add a
    // vertex per jittery fix, which could make the route's LatLngBounds
    // degenerate. With the noise floor, a long stationary spell before real
    // movement starts contributes exactly ONE vertex (the anchor), not one
    // per fix.
    final ctrl = StreamController<GpsSample>();
    final t = RouteTracker(sink: (_) async {}, batchSize: 100, minMovementM: 5);
    t.start(ctrl.stream);

    ctrl.add(_fix(0, stepMeters: 0));
    for (var i = 1; i <= 20; i++) {
      // Small pseudo-random jitter, all within the floor.
      final jitter = (i.isEven ? 1 : -1) * (1 + (i % 3));
      ctrl.add(GpsSample(lat: 0, lng: jitter / _mPerDegLngAtEq, tsMs: i * 1000));
    }
    await pumpEventQueue();

    expect(t.path.value.length, 1); // still just the anchor

    // Now real movement starts — should be captured normally.
    ctrl.add(GpsSample(lat: 0, lng: 500 / _mPerDegLngAtEq, tsMs: 21000));
    await pumpEventQueue();
    expect(t.path.value.length, 2);
    expect(t.distanceMeters.value, closeTo(500, 5));

    await t.stop();
    await ctrl.close();
  });

  test('stalled never trips for a session shorter than stallAfter', () {
    fakeAsync((async) {
      final ctrl = StreamController<GpsSample>();
      final t = RouteTracker(
        sink: (_) async {},
        batchSize: 100,
        stallAfter: const Duration(seconds: 15),
      );
      t.start(ctrl.stream);

      ctrl.add(_fix(0));
      async.elapse(const Duration(seconds: 5));
      expect(t.stalled.value, isFalse);

      unawaited(t.stop());
      async.flushMicrotasks();
      unawaited(ctrl.close());
    });
  });
}
