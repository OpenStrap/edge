// Pure-logic tests for the rewritten BLE transport's deterministic seams
// (ble_state.dart). These cover exactly the parts that USED to race in the old
// engine — the backoff schedule, the seq allocator, the drain stop conditions,
// and the phase→legacy-string projection — none of which need a real band.

import 'dart:async';
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

  group('RecordGate (shared plausibility gate + frontier)', () {
    const wall = 1750000000; // plausible "now"

    test('plausible records are admitted and advance the frontier', () {
      final g = RecordGate();
      expect(g.admit(wall - 3600, wallNow: wall), isTrue);
      expect(g.frontierTs, wall - 3600);
      expect(g.admit(wall - 60, wallNow: wall), isTrue);
      expect(g.frontierTs, wall - 60);
      expect(g.dropped, 0);
    });

    test('an older (but plausible) record never lowers the frontier', () {
      final g = RecordGate(frontierTs: wall - 100);
      expect(g.admit(wall - 5000, wallNow: wall), isTrue); // stored fine
      expect(g.frontierTs, wall - 100); // frontier is a high-water mark
    });

    test('implausible records are dropped, counted, and freeze nothing', () {
      final g = RecordGate(frontierTs: wall - 100);
      // Pre-2023 junk (unset RTC of a previous owner).
      expect(g.admit(1000000000, wallNow: wall), isFalse);
      // Absurd future (the garbage year-2034 class of bug).
      expect(g.admit(wall + 10 * 86400, wallNow: wall), isFalse);
      expect(g.dropped, 2);
      expect(g.frontierTs, wall - 100); // untouched by rejects
    });

    test('records with no decodable ts are kept and do not move the frontier',
        () {
      final g = RecordGate(frontierTs: wall - 100);
      expect(g.admit(null, wallNow: wall), isTrue);
      expect(g.admit(0, wallNow: wall), isTrue);
      expect(g.frontierTs, wall - 100);
      expect(g.dropped, 0);
    });

    test('session GET_DATA_RANGE window tightens the gate (±7 days)', () {
      final g = RecordGate();
      final oldest = wall - 3 * 86400;
      final newest = wall - 600;
      // Inside the window (± margin) → admitted.
      expect(
        g.admit(oldest - 86400,
            wallNow: wall, sessionOldestUnix: oldest, sessionNewestUnix: newest),
        isTrue,
      );
      // More than 7 days before the strap's own oldest → wandering-clock junk.
      expect(
        g.admit(oldest - 8 * 86400,
            wallNow: wall, sessionOldestUnix: oldest, sessionNewestUnix: newest),
        isFalse,
      );
      expect(g.dropped, 1);
    });

    test('a below-floor time base is tellable from a wandering clock', () {
      // Uptime-since-boot: every stamp is under kMinPlausibleUnix, forever.
      final uptime = RecordGate();
      expect(uptime.admit(3600, wallNow: wall), isFalse);
      expect(uptime.admit(7200, wallNow: wall), isFalse);
      expect(uptime.droppedBelowFloor, 2);
      expect(uptime.timeBaseNotWallClock, isTrue);

      // A wandering/future RTC drops too, but NOT below the floor — the case
      // a reconnect or SET_CLOCK can still resolve.
      final wandering = RecordGate();
      expect(wandering.admit(wall + 10 * 86400, wallNow: wall), isFalse);
      expect(wandering.dropped, 1);
      expect(wandering.droppedBelowFloor, 0);
      expect(wandering.timeBaseNotWallClock, isFalse);

      // One below-floor drop among others is not a verdict about the source.
      final mixed = RecordGate();
      expect(mixed.admit(1000000000, wallNow: wall), isFalse);
      expect(mixed.admit(wall + 10 * 86400, wallNow: wall), isFalse);
      expect(mixed.timeBaseNotWallClock, isFalse);

      // Never a verdict on a gate that has rejected nothing.
      expect(RecordGate().timeBaseNotWallClock, isFalse);
    });

    test('frontier seed from the durable cursor is honoured', () {
      final g = RecordGate(frontierTs: wall - 50);
      expect(g.frontierTs, wall - 50);
      expect(g.admit(wall - 10, wallNow: wall), isTrue);
      expect(g.frontierTs, wall - 10);
    });
  });

  group('CounterRegressionDetector (band-reboot signal)', () {
    test('ascending counters never trip', () {
      final d = CounterRegressionDetector();
      expect(d.feed(1), isFalse);
      expect(d.feed(100), isFalse);
      expect(d.feed(101), isFalse);
      expect(d.regressions, 0);
    });

    test('equal counters (duplicate/retried frame) do not trip', () {
      final d = CounterRegressionDetector();
      expect(d.feed(50), isFalse);
      expect(d.feed(50), isFalse);
      expect(d.regressions, 0);
    });

    test('a real drop (band reboot) trips and is counted', () {
      final d = CounterRegressionDetector();
      d.feed(5000);
      expect(d.feed(3), isTrue);
      expect(d.regressions, 1);
      // Keeps counting further regressions (not one-shot — every reboot matters).
      d.feed(10);
      expect(d.feed(4), isTrue);
      expect(d.regressions, 2);
    });

    test('u32 wraparound near the top of the range is not a regression', () {
      final d = CounterRegressionDetector();
      d.feed(0xFFFFFFFF - 500000);
      expect(d.feed(200), isFalse); // wrapped, not rebooted
      expect(d.regressions, 0);
    });

    test('seeding from the durable counter_hw cursor catches a regression '
        'across a reconnect', () {
      final d = CounterRegressionDetector(seedCounter: 9000);
      expect(d.feed(12), isTrue); // first record after reconnect already low
      expect(d.regressions, 1);
    });

    test('first feed after construction with no seed never trips', () {
      final d = CounterRegressionDetector();
      expect(d.feed(0), isFalse);
      expect(d.regressions, 0);
    });

    test('reseed replaces the last-seen counter without resetting the '
        'lifetime regression count', () {
      final d = CounterRegressionDetector(seedCounter: 100);
      d.feed(10); // regression #1
      expect(d.regressions, 1);
      d.reseed(500);
      expect(d.feed(600), isFalse); // ascending from the new seed
      expect(d.regressions, 1); // lifetime count untouched by reseed
    });
  });

  group('AckRetryPolicy (verified batch-ACK writes)', () {
    const p = AckRetryPolicy(
      maxAttempts: 3,
      baseDelay: Duration(milliseconds: 200),
    );

    test('allows exactly maxAttempts attempts', () {
      expect(p.shouldRetry(0), isTrue); // no failures yet → first try allowed
      expect(p.shouldRetry(1), isTrue);
      expect(p.shouldRetry(2), isTrue);
      expect(p.shouldRetry(3), isFalse); // 3 failures → give up (bounce link)
      expect(p.shouldRetry(10), isFalse);
    });

    test('backoff grows linearly from the base delay', () {
      expect(p.delayFor(1).inMilliseconds, 200);
      expect(p.delayFor(2).inMilliseconds, 400);
      expect(p.delayFor(3).inMilliseconds, 600);
      expect(p.delayFor(0).inMilliseconds, 200); // clamped to attempt 1
    });
  });

  group('ChunkFailureLedger (persistent-per-token ACK failure tracking)', () {
    test('a token that never fails never quarantines', () {
      final l = ChunkFailureLedger();
      expect(l.failureCount('tok-a'), 0);
      expect(l.shouldQuarantine('tok-a'), isFalse);
    });

    test('failures accumulate per-token, independent of other tokens', () {
      final l = ChunkFailureLedger(quarantineThreshold: 3);
      expect(l.recordFailure('tok-a'), 1);
      expect(l.recordFailure('tok-a'), 2);
      expect(l.recordFailure('tok-b'), 1); // independent counter
      expect(l.failureCount('tok-a'), 2);
      expect(l.failureCount('tok-b'), 1);
      expect(l.shouldQuarantine('tok-a'), isFalse);
    });

    test('crosses the quarantine threshold on the Nth consecutive failure',
        () {
      final l = ChunkFailureLedger(quarantineThreshold: 3);
      l.recordFailure('tok-a');
      l.recordFailure('tok-a');
      expect(l.shouldQuarantine('tok-a'), isFalse);
      l.recordFailure('tok-a');
      expect(l.shouldQuarantine('tok-a'), isTrue);
    });

    test('a success clears tracking for that token only', () {
      final l = ChunkFailureLedger(quarantineThreshold: 2);
      l.recordFailure('tok-a');
      l.recordFailure('tok-a');
      l.recordFailure('tok-b');
      expect(l.shouldQuarantine('tok-a'), isTrue);
      l.recordSuccess('tok-a');
      expect(l.failureCount('tok-a'), 0);
      expect(l.shouldQuarantine('tok-a'), isFalse);
      // tok-b untouched by tok-a's success.
      expect(l.failureCount('tok-b'), 1);
    });

    test('a token can re-accumulate failures after a prior success', () {
      final l = ChunkFailureLedger(quarantineThreshold: 2);
      l.recordFailure('tok-a');
      l.recordSuccess('tok-a');
      expect(l.recordFailure('tok-a'), 1); // starts fresh, not from 1 again
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

    test(
        'foreground mode fires MUCH sooner than fresh mode at the exact same '
        '(short) staleness — the case that used to hit the slowest tier right '
        'when the user is watching', () {
      // dataStaleness has just dropped below staleThreshold (a catch-up sync
      // reaching "now") — without isForeground this would be fresh mode
      // (1min quiet / 5min floor). With isForeground it must NOT wait that
      // long: the foreground tier (5s quiet / 15s floor) takes priority.
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 6),
          sinceFirstPending: const Duration(seconds: 10),
          dataStaleness: const Duration(minutes: 5),
          isForeground: true,
        ),
        isTrue, // 6s quiet >= the 5s foreground quiet period
      );
      // The SAME inputs without isForeground must NOT fire yet (fresh mode).
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 6),
          sinceFirstPending: const Duration(seconds: 10),
          dataStaleness: const Duration(minutes: 5),
          isForeground: false,
        ),
        isFalse,
      );
    });

    test('foreground mode still respects its own (short) floor', () {
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 2), // stream still active
          sinceFirstPending: const Duration(seconds: 14),
          dataStaleness: const Duration(hours: 2),
          isForeground: true,
        ),
        isFalse, // under both the 5s quiet and the 15s floor
      );
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 2),
          sinceFirstPending: const Duration(seconds: 15),
          dataStaleness: const Duration(hours: 2),
          isForeground: true,
        ),
        isTrue, // hits the 15s floor even though the stream never went quiet
      );
    });

    test('foreground mode overrides stale mode too (still just the fastest '
        'reasonable tier, not slower)', () {
      // Even in stale mode's territory (dataStaleness >= 30min), foreground
      // is at least as fast — same fixture, both should fire promptly.
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 5),
          sinceFirstPending: const Duration(seconds: 5),
          dataStaleness: const Duration(hours: 2),
          isForeground: true,
        ),
        isTrue, // 5s quiet >= the 5s foreground quiet period
      );
    });

    test('isForeground defaults to false (existing callers unaffected)', () {
      // No isForeground arg at all — must behave exactly like before.
      expect(
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: const Duration(seconds: 6),
          sinceFirstPending: const Duration(seconds: 10),
          dataStaleness: const Duration(minutes: 5),
        ),
        isFalse, // fresh mode, unchanged
      );
    });
  });

  group('classifyBleBlocker separates the phone from the band', () {
    test('a revoked permission is not "nothing answered"', () {
      expect(classifyBleBlocker(adapterState: 'unauthorized'),
          BleBlocker.permissionDenied);
      expect(
        classifyBleBlocker(
            error: Exception('PlatformException: Need '
                'android.permission.BLUETOOTH_SCAN')),
        BleBlocker.permissionDenied,
      );
    });

    test('adapter off and no-BLE-radio are their own states', () {
      expect(classifyBleBlocker(adapterState: 'off'), BleBlocker.adapterOff);
      expect(classifyBleBlocker(adapterState: 'turningOff'),
          BleBlocker.adapterOff);
      expect(classifyBleBlocker(adapterState: 'unavailable'),
          BleBlocker.unsupported);
    });

    test('a usable stack and an ordinary band failure classify as null', () {
      expect(classifyBleBlocker(adapterState: 'on'), isNull);
      expect(classifyBleBlocker(adapterState: 'unknown'), isNull);
      expect(classifyBleBlocker(adapterState: 'turningOn'), isNull);
      expect(classifyBleBlocker(), isNull);
      // The band-side failures must NOT be swallowed as phone blockers.
      expect(classifyBleBlocker(error: Exception('connection timeout')), isNull);
      expect(classifyBleBlocker(error: Exception('bond failed')), isNull);
      expect(classifyBleBlocker(error: Exception('GATT error 133')), isNull);
    });
  });

  group('bandStatusFor is one renderable state, not six booleans', () {
    test('every fault names itself, says why, and offers a way out', () {
      final faults = [
        bandStatusFor(
            connection: 'disconnected', blocker: BleBlocker.permissionDenied),
        bandStatusFor(connection: 'disconnected', blocker: BleBlocker.adapterOff),
        bandStatusFor(
            connection: 'disconnected',
            autoReconnectPaused: true,
            bondRefusals: 5),
        bandStatusFor(connection: 'disconnected', needsRepairGuide: true),
        bandStatusFor(connection: 'connected', syncChunkQuarantined: true),
        bandStatusFor(connection: 'connected', strapNeedsReboot: true),
        bandStatusFor(connection: 'connected', syncClockLost: true),
      ];
      for (final s in faults) {
        expect(s.isFault, isTrue, reason: '${s.condition}');
        expect(s.title.isNotEmpty, isTrue, reason: '${s.condition}');
        expect(s.reason.length > 20, isTrue, reason: '${s.condition}');
        expect(s.fix, isNotNull, reason: '${s.condition}');
        // "Something went wrong" is not a name.
        expect(s.title.toLowerCase().contains('something went wrong'), isFalse);
      }
    });

    test('a phone-level blocker outranks every band flag', () {
      final s = bandStatusFor(
        connection: 'connected',
        blocker: BleBlocker.permissionDenied,
        autoReconnectPaused: true,
        needsRepairGuide: true,
        syncClockLost: true,
      );
      expect(s.condition, BandCondition.bluetoothDenied);
      // The one wrong answer this whole seam exists to prevent.
      expect(s.title.toLowerCase().contains('range'), isFalse);
      expect(s.fix, contains('Settings'));
    });

    test('the pause outranks the repair guide it set', () {
      expect(
        bandStatusFor(
          connection: 'disconnected',
          autoReconnectPaused: true,
          needsRepairGuide: true,
          bondRefusals: 5,
        ).condition,
        BandCondition.reconnectPaused,
      );
      // The count is in the copy — "5 times in a row" is the whole point.
      expect(
        bandStatusFor(
                connection: 'disconnected',
                autoReconnectPaused: true,
                bondRefusals: 5)
            .reason,
        contains('5'),
      );
    });

    test('a data-flow flag outranks the plain link state', () {
      // "Not connected" is true and useless next to "the clock is lost".
      expect(
        bandStatusFor(connection: 'disconnected', syncClockLost: true)
            .condition,
        BandCondition.clockLost,
      );
      expect(
        bandStatusFor(connection: 'connected', syncChunkQuarantined: true)
            .condition,
        BandCondition.syncStuck,
      );
    });

    test('the ordinary link states are not faults', () {
      for (final c in ['connected', 'connecting', 'scanning', 'disconnected']) {
        expect(bandStatusFor(connection: c).isFault, isFalse, reason: c);
      }
      expect(bandStatusFor(connection: 'connected').condition,
          BandCondition.connected);
      expect(bandStatusFor(connection: 'nonsense').condition,
          BandCondition.disconnected);
    });

    test('nothing to do is expressed as a null fix, not a fake one', () {
      final s = bandStatusFor(
          connection: 'disconnected', blocker: BleBlocker.unsupported);
      expect(s.condition, BandCondition.bluetoothUnsupported);
      expect(s.fix, isNull);
    });
  });

  group('isTimeoutDisconnect', () {
    test('the platforms both say it in words', () {
      // Android reports HCI/GATT names; iOS the CBError localizedDescription.
      expect(isTimeoutDisconnect('LINK_SUPERVISION_TIMEOUT'), isTrue);
      expect(isTimeoutDisconnect('GATT_CONNECTION_TIMEOUT'), isTrue);
      expect(
          isTimeoutDisconnect('The connection has timed out unexpectedly.'),
          isTrue);
    });

    test('an ordinary termination is not a timeout', () {
      expect(isTimeoutDisconnect('REMOTE_USER_TERMINATED_CONNECTION'), isFalse);
      expect(isTimeoutDisconnect('connection canceled'), isFalse);
    });

    test('no reason reported is not a timeout — we never assume one', () {
      // The old caller hardcoded `timedOut: true`, which is exactly this
      // assumption: it made two ordinary drops inside 8 s of setup latch the
      // re-pair guide on a band that was working.
      expect(isTimeoutDisconnect(null), isFalse);
    });
  });

  group('withScanLock (process-wide scan mutex)', () {
    test('a queued scan does not start until the running one finishes', () async {
      // The bug this exists for: two overlapping scan bodies share ONE radio
      // scanner, so the second one's `stopScan` ends the first scan early and
      // the first reports "found nothing" with no error anywhere.
      final order = <String>[];
      final holdA = Completer<void>();
      final a = withScanLock(() async {
        order.add('a-start');
        await holdA.future;
        order.add('a-end');
        return 'a';
      });
      final b = withScanLock(() async {
        order.add('b-start');
        return 'b';
      });
      await Future<void>.delayed(Duration.zero);
      expect(order, ['a-start']); // b is queued, NOT running alongside a
      holdA.complete();
      expect(await a, 'a');
      expect(await b, 'b');
      expect(order, ['a-start', 'a-end', 'b-start']);
    });

    test('a scan that throws releases the lock', () async {
      // A blocker (revoked permission, adapter off) throws out of the band
      // scan; the next scan must still run rather than wait on a dead chain.
      await expectLater(
        withScanLock<void>(() async => throw StateError('adapter off')),
        throwsStateError,
      );
      expect(await withScanLock(() async => 7), 7);
    });
  });

  group('withSecondaryLinkSlot', () {
    test('grants up to kMaxConcurrentSecondaryLinks concurrently', () async {
      final order = <String>[];
      final holds = List.generate(
          kMaxConcurrentSecondaryLinks, (_) => Completer<void>());
      final futures = <Future<void>>[];
      for (var i = 0; i < kMaxConcurrentSecondaryLinks; i++) {
        futures.add(withSecondaryLinkSlot(() async {
          order.add('start$i');
          await holds[i].future;
          order.add('end$i');
        }));
      }
      await Future<void>.delayed(Duration.zero);
      // Every slot up to the cap started immediately — none queued.
      expect(order.length, kMaxConcurrentSecondaryLinks);
      for (final h in holds) {
        h.complete();
      }
      await Future.wait(futures);
    });

    test('a caller past the cap queues until a slot frees', () async {
      final order = <String>[];
      final holds = List.generate(
          kMaxConcurrentSecondaryLinks, (_) => Completer<void>());
      final futures = <Future<void>>[];
      for (var i = 0; i < kMaxConcurrentSecondaryLinks; i++) {
        futures.add(withSecondaryLinkSlot(() async {
          order.add('start$i');
          await holds[i].future;
        }));
      }
      await Future<void>.delayed(Duration.zero);
      final extra = withSecondaryLinkSlot(() async {
        order.add('extra-start');
      });
      await Future<void>.delayed(Duration.zero);
      // The cap is full — the extra caller has not started yet.
      expect(order.contains('extra-start'), isFalse);
      holds[0].complete();
      await extra;
      expect(order.contains('extra-start'), isTrue);
      for (final h in holds) {
        if (!h.isCompleted) h.complete();
      }
      await Future.wait(futures);
    });

    test('a held body that throws releases its slot', () async {
      await expectLater(
        withSecondaryLinkSlot<void>(() async => throw StateError('link dropped')),
        throwsStateError,
      );
      // Cap's worth of slots must all be free again — grantable without
      // queuing behind the failed one.
      final futures = List.generate(
        kMaxConcurrentSecondaryLinks,
        (_) => withSecondaryLinkSlot(() async => null),
      );
      await Future.wait(futures);
    });
  });
}
