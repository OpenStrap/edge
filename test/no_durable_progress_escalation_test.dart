// P0 REGRESSION — the no-durable-progress refusal loop must be able to escape,
// and must never be silent.
//
// Refusing a HISTORY_END whose burst banked nothing is correct: echoing the
// token lets the band delete flash we never stored, the one irreversible act
// in this protocol. The bug was everything AFTER the refusal.
//
//  1. The refusal streak lived in the engine and was zeroed in the
//     per-connection setup block. But the streak's own remedy is a
//     SET_CLOCK + BOUNCE — a reconnect — and the idle watchdog also tears the
//     session down after a burst that banked nothing. So the count could never
//     climb: every cycle reset it, and the ">= 3 then run the remedy" branch
//     was unreachable in the field. The engine already documents this exact
//     distinction one block up ("marginal-radio + post-bond-loop are NOT reset
//     here — they count consecutive bad cycles across reconnects").
//
//  2. Nothing surfaced a remedy that kept failing. `EmptySyncTracker` (which
//     sets `syncClockLost`) and `StuckStrapDetector` are BOTH only evaluated
//     inside `_onOffloadFinished`, and that needs a HISTORY_COMPLETE which this
//     loop never reaches — the band keeps re-delivering the same un-trimmed
//     chunk. A band with a lost RTC could therefore sit in refuse → bounce →
//     refuse forever behind a debug log.
//
// The escalation still NEVER ACKs. "Keep the data" stays the answer; what
// changes is that a persistently failing remedy becomes visible.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

void main() {
  test('a refusal streak below the threshold does not run the remedy', () {
    final e = NoDurableProgressEscalation(remedyAfter: 3);
    expect(e.trimRefused(), isFalse);
    expect(e.trimRefused(), isFalse);
    expect(e.remedies, 0);
  });

  test('the remedy fires on the Nth consecutive refusal', () {
    final e = NoDurableProgressEscalation(remedyAfter: 3);
    e.trimRefused();
    e.trimRefused();
    expect(e.trimRefused(), isTrue);
    expect(e.remedies, 1);
    expect(e.refusals, 0, reason: 'next remedy needs a fresh streak');
  });

  test(
    'counting SURVIVES the remedy — this is the whole bug. The remedy is a '
    'reconnect, so a per-connection reset made escalation unreachable.',
    () {
      final e = NoDurableProgressEscalation(remedyAfter: 3, giveUpAfter: 3);
      // Three full cycles, each ending in the reconnect that used to zero it.
      for (var cycle = 0; cycle < 3; cycle++) {
        expect(e.trimRefused(), isFalse);
        expect(e.trimRefused(), isFalse);
        expect(e.trimRefused(), isTrue, reason: 'cycle $cycle remedy');
      }
      expect(e.remedies, 3);
      expect(
        e.shouldSurfaceGiveUp(),
        isTrue,
        reason: 'three failed remedies must become user-visible',
      );
    },
  );

  test('give-up is latched — it must not re-notify on every later cycle', () {
    final e = NoDurableProgressEscalation(remedyAfter: 1, giveUpAfter: 2);
    e.trimRefused();
    e.trimRefused();
    expect(e.shouldSurfaceGiveUp(), isTrue);
    expect(e.shouldSurfaceGiveUp(), isFalse);
    e.trimRefused();
    expect(e.shouldSurfaceGiveUp(), isFalse);
    expect(e.gaveUp, isTrue);
  });

  test('give-up does not fire before the remedy has actually failed', () {
    final e = NoDurableProgressEscalation(remedyAfter: 3, giveUpAfter: 3);
    e.trimRefused();
    e.trimRefused();
    e.trimRefused(); // 1 remedy
    expect(e.shouldSurfaceGiveUp(), isFalse);
  });

  test(
    'a successful trim ACK clears everything, including the give-up latch',
    () {
      final e = NoDurableProgressEscalation(remedyAfter: 1, giveUpAfter: 1);
      e.trimRefused();
      expect(e.shouldSurfaceGiveUp(), isTrue);

      e.trimAcked();
      expect(e.refusals, 0);
      expect(e.remedies, 0);
      expect(e.gaveUp, isFalse);

      // A later run must be able to escalate again.
      expect(e.trimRefused(), isTrue);
      expect(e.shouldSurfaceGiveUp(), isTrue);
    },
  );

  test('an interleaved ACK breaks the streak — only CONSECUTIVE refusals count',
      () {
    final e = NoDurableProgressEscalation(remedyAfter: 3);
    e.trimRefused();
    e.trimRefused();
    e.trimAcked(); // real progress happened
    expect(
      e.trimRefused(),
      isFalse,
      reason: 'the streak restarted; two old refusals must not carry over',
    );
  });

  test(
    'after give-up the remedy backs off instead of bouncing every 3 refusals '
    'all night',
    () {
      final e = NoDurableProgressEscalation(remedyAfter: 3, giveUpAfter: 3);
      for (var i = 0; i < 9; i++) {
        e.trimRefused();
      }
      expect(e.remedies, 3);
      expect(e.shouldSurfaceGiveUp(), isTrue);

      // 300 more refusals: the flat threshold would fire 100 more remedies.
      var remedies = 0;
      for (var i = 0; i < 300; i++) {
        if (e.trimRefused()) remedies++;
      }
      // 6 + 12 + 24 + 48 + 96 = 186, then every 192 → 5 remedies in 300.
      expect(remedies, 5);
      expect(e.nextRemedyThreshold, 3 << 6, reason: 'capped');
      expect(e.shouldSurfaceGiveUp(), isFalse, reason: 'still latched');
    },
  );

  test('the threshold is flat until give-up, and a trim ACK resets the backoff',
      () {
    final e = NoDurableProgressEscalation(remedyAfter: 3, giveUpAfter: 3);
    expect(e.nextRemedyThreshold, 3);
    for (var i = 0; i < 6; i++) {
      e.trimRefused();
    }
    expect(e.nextRemedyThreshold, 3, reason: 'two remedies, not given up yet');
    for (var i = 0; i < 3; i++) {
      e.trimRefused();
    }
    expect(e.nextRemedyThreshold, 6);
    e.trimAcked();
    expect(e.nextRemedyThreshold, 3);
  });

  test(
    're-offers of one refused HISTORY_END count once — the band re-sends it '
    'every ~2.5 s, and counting each one ran the remedy 7.5 s into one burst',
    () {
      final e = NoDurableProgressEscalation(remedyAfter: 3, giveUpAfter: 3);
      // Burst 1, offered five times without a result in between.
      for (var i = 0; i < 5; i++) {
        expect(e.trimRefused(burst: 1), isFalse, reason: 're-offer $i');
      }
      expect(e.refusals, 1);
      expect(e.remedies, 0);
      // Two more distinct bursts make the streak of three.
      expect(e.trimRefused(burst: 2), isFalse);
      expect(e.trimRefused(burst: 2), isFalse);
      expect(e.trimRefused(burst: 3), isTrue);
      expect(e.remedies, 1);
      // A re-offer of the burst that triggered the remedy is not a new one.
      expect(e.trimRefused(burst: 3), isFalse);
      expect(e.refusals, 0);
    },
  );

  test('a trim ACK forgets the last refused burst', () {
    final e = NoDurableProgressEscalation(remedyAfter: 3);
    e.trimRefused(burst: 7);
    e.trimAcked();
    e.trimRefused(burst: 7);
    expect(e.refusals, 1, reason: 'counted again after real progress');
  });
}
