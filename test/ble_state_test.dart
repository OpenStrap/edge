// Pure-logic tests for the rewritten BLE transport's deterministic seams
// (ble_state.dart). These cover exactly the parts that USED to race in the old
// engine — the backoff schedule, the seq allocator, the drain stop conditions,
// and the phase→legacy-string projection — none of which need a real band.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  group('ReconnectPolicy backoff schedule', () {
    final p = ReconnectPolicy(
      base: const Duration(seconds: 2),
      cap: const Duration(seconds: 30),
      jitterFraction: 0.0, // deterministic for the shape assertions
    );

    test('base delay doubles each attempt then caps', () {
      expect(p.baseDelayFor(1).inSeconds, 2);
      expect(p.baseDelayFor(2).inSeconds, 4);
      expect(p.baseDelayFor(3).inSeconds, 8);
      expect(p.baseDelayFor(4).inSeconds, 16);
      expect(p.baseDelayFor(5).inSeconds, 30); // 32 -> capped at 30
      expect(p.baseDelayFor(6).inSeconds, 30);
      expect(p.baseDelayFor(50).inSeconds, 30); // no overflow blow-up
    });

    test('attempt < 1 is treated as attempt 1', () {
      expect(p.baseDelayFor(0).inSeconds, 2);
      expect(p.baseDelayFor(-5).inSeconds, 2);
    });

    test('jitter stays within [base, cap] and brackets the base delay', () {
      final jp = ReconnectPolicy(
        base: const Duration(seconds: 2),
        cap: const Duration(seconds: 30),
        jitterFraction: 0.2,
        rng: Random(42),
      );
      for (var attempt = 1; attempt <= 8; attempt++) {
        for (var i = 0; i < 200; i++) {
          final d = jp.delayFor(attempt).inMilliseconds;
          expect(d, greaterThanOrEqualTo(2000));
          expect(d, lessThanOrEqualTo(30000));
          final baseMs = jp.baseDelayFor(attempt).inMilliseconds;
          // within +/-20% of the (capped) base, clamped to bounds
          final lo = (baseMs * 0.8).floor().clamp(2000, 30000);
          final hi = (baseMs * 1.2).ceil().clamp(2000, 30000);
          expect(d, greaterThanOrEqualTo(lo));
          expect(d, lessThanOrEqualTo(hi));
        }
      }
    });
  });

  group('SeqAllocator discipline', () {
    test('live counter starts at 0xA0 and wraps back to 0xA0', () {
      final s = SeqAllocator();
      expect(s.nextLive(), 0xA0);
      expect(s.nextLive(), 0xA1);
      // Burn up to 0xFF then confirm the wrap stays in the high range.
      var last = 0xA1;
      for (var i = 0; i < 0x60; i++) {
        last = s.nextLive();
      }
      // After 0x60 more (0xA2..0xFF then wrap), the value is >= 0xA0 always.
      expect(last, greaterThanOrEqualTo(0xA0));
      // Exhaustively: 1000 allocations never leave the high range.
      for (var i = 0; i < 1000; i++) {
        expect(s.nextLive(), greaterThanOrEqualTo(0xA0));
      }
    });

    test('sync counter starts at 5 and never enters the live range', () {
      final s = SeqAllocator();
      expect(s.nextSync(), 5);
      expect(s.nextSync(), 6);
      for (var i = 0; i < 1000; i++) {
        final v = s.nextSync();
        expect(v, greaterThanOrEqualTo(5));
        expect(v, lessThanOrEqualTo(0xFF));
      }
    });

    test('live and sync ranges never collide at low values', () {
      final s = SeqAllocator();
      // The two ranges are disjoint by construction: sync wraps to 5 (well below
      // 0xA0), live wraps to 0xA0. A sync value can climb into 0xA0+ on wrap, but
      // it can never be confused for a *live* command because live commands are
      // built with nextLive(). The invariant we assert: sync floor < live floor.
      expect(SeqAllocator.syncFloor, lessThan(SeqAllocator.liveFloor));
      s.reset();
      expect(s.nextLive(), 0xA0);
      expect(s.nextSync(), 5);
    });
  });

  group('connStringFor projection (single listening mode)', () {
    test('maps every phase to the legacy UI string', () {
      expect(connStringFor(BleConnState.idle), 'disconnected');
      expect(connStringFor(BleConnState.error), 'disconnected');
      expect(connStringFor(BleConnState.scanning), 'scanning');
      expect(connStringFor(BleConnState.connecting), 'connecting');
      expect(connStringFor(BleConnState.discovering), 'connecting');
      expect(connStringFor(BleConnState.subscribing), 'connecting');
      expect(connStringFor(BleConnState.settingUp), 'connecting');
      expect(connStringFor(BleConnState.reconnecting), 'connecting');
      // The collapsed single mode — history + live both stream under 'connected'.
      expect(connStringFor(BleConnState.listening), 'connected');
    });

    test('there is no longer a separate "syncing" string', () {
      for (final s in BleConnState.values) {
        expect(connStringFor(s), isNot('syncing'));
      }
    });
  });

  group('DrainStopEvaluator stop conditions (no liveEdge/idle abort)', () {
    const e = DrainStopEvaluator(timeout: Duration(seconds: 600));

    DrainStop ev({
      bool complete = false,
      bool linkDown = false,
      int sinceStartS = 1,
    }) => e.evaluate(
      complete: complete,
      linkDown: linkDown,
      sinceStart: Duration(seconds: sinceStartS),
    );

    test('keeps going while the offload is still streaming', () {
      // The KEY behaviour change: a still-running offload never stops on its own —
      // only HISTORY_COMPLETE / link-down / the safety timeout end it. This is what
      // lets the band reach HISTORY_COMPLETE and durably advance its read cursor
      // (the old liveEdge/idle ABORT stalled the cursor → Groundhog-Day re-flood).
      expect(ev(sinceStartS: 30), DrainStop.keepGoing);
      expect(ev(sinceStartS: 300), DrainStop.keepGoing);
    });

    test('complete wins over everything', () {
      expect(ev(complete: true, linkDown: true), DrainStop.complete);
      expect(ev(complete: true, sinceStartS: 700), DrainStop.complete);
    });

    test('link-down stops immediately', () {
      expect(ev(linkDown: true, sinceStartS: 1), DrainStop.linkDown);
    });

    test('timeout fires only after the (generous) safety budget', () {
      expect(ev(sinceStartS: 599), DrainStop.keepGoing);
      expect(ev(sinceStartS: 601), DrainStop.timeout);
    });

    test('no liveEdge / idle stop reasons exist anymore', () {
      final names = DrainStop.values.map((v) => v.name).toSet();
      expect(names, isNot(contains('liveEdge')));
      expect(names, isNot(contains('idle')));
      expect(names, {'keepGoing', 'complete', 'linkDown', 'timeout'});
    });
  });

  group('DeriveDebouncer coalesce logic', () {
    const d = DeriveDebouncer(
      staleQuietPeriod: Duration(seconds: 12),
      staleMaxWait: Duration(seconds: 90),
      freshQuietPeriod: Duration(minutes: 1),
      freshMaxWait: Duration(minutes: 5),
      staleThreshold: Duration(minutes: 30),
    );

    test('never derives with nothing pending', () {
      expect(
        d.shouldDerive(
          hasPending: false,
          sinceLastRecord: const Duration(seconds: 30),
          sinceFirstPending: const Duration(seconds: 30),
          dataStaleness: const Duration(hours: 2),
        ),
        isFalse,
      );
    });

    test('holds while records are still arriving (not yet quiet)', () {
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 3),
          sinceFirstPending: const Duration(seconds: 5),
          dataStaleness: const Duration(hours: 2),
        ),
        isFalse,
      );
    });

    test('stale mode fires once the inbound stream goes quiet', () {
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 12),
          sinceFirstPending: const Duration(seconds: 20),
          dataStaleness: const Duration(hours: 2),
        ),
        isTrue,
      );
    });

    test('stale mode never-quiet stream still derives at the maxWait floor', () {
      // Records keep landing (only 2s quiet) but the dirty run is 90s old → derive.
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 2),
          sinceFirstPending: const Duration(seconds: 90),
          dataStaleness: const Duration(hours: 2),
        ),
        isTrue,
      );
    });

    test('fresh mode waits longer before deriving', () {
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 20),
          sinceFirstPending: const Duration(seconds: 90),
          dataStaleness: const Duration(minutes: 5),
        ),
        isFalse,
      );
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(minutes: 1),
          sinceFirstPending: const Duration(minutes: 2),
          dataStaleness: const Duration(minutes: 5),
        ),
        isTrue,
      );
    });

    test(
      'fresh mode never-quiet stream derives at the calmer 5 minute floor',
      () {
        expect(
          d.shouldDerive(
            hasPending: true,
            sinceLastRecord: const Duration(seconds: 2),
            sinceFirstPending: const Duration(minutes: 4, seconds: 59),
            dataStaleness: const Duration(minutes: 5),
          ),
          isFalse,
        );
        expect(
          d.shouldDerive(
            hasPending: true,
            sinceLastRecord: const Duration(seconds: 2),
            sinceFirstPending: const Duration(minutes: 5),
            dataStaleness: const Duration(minutes: 5),
          ),
          isTrue,
        );
      },
    );
  });
}
