// Regression tests for readiness DRIFTING through the day (#128 — "morning it
// was 49, now 45").
//
// Root cause: a day stays recomputable for ~48 h and every re-derive overwrites
// the persisted readiness scalar; as the night's flash finishes draining and the
// trailing 28-day baseline shifts, the surfaced value legitimately moves. The fix
// FREEZES the morning headline once today's overnight is genuinely COMPLETE and
// pins that first value for the rest of the day.
//
// `nextFrozenHeadline` is the pure decision at the heart of that freeze. These
// tests pin its semantics: the headline does NOT move after the first
// complete-overnight settle, and a new day resets it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  group('nextFrozenHeadline', () {
    const d1 = '2026-07-21';
    const d2 = '2026-07-22';

    test('before a complete overnight → no pin (headline tracks the live value)',
        () {
      final pin = nextFrozenHeadline(
        today: d1,
        overnightComplete: false,
        liveReadiness: 49,
        current: null,
      );
      expect(pin, isNull);
    });

    test('first complete overnight → pins the live value', () {
      final pin = nextFrozenHeadline(
        today: d1,
        overnightComplete: true,
        liveReadiness: 49,
        current: null,
      );
      expect(pin, isNotNull);
      expect(pin!.day, d1);
      expect(pin.value, 49);
    });

    test('absent readiness at completion → still no pin', () {
      final pin = nextFrozenHeadline(
        today: d1,
        overnightComplete: true,
        liveReadiness: null,
        current: null,
      );
      expect(pin, isNull);
    });

    test(
        'ready→ready with a changing value → the frozen headline does NOT move '
        'after the first complete settle', () {
      // Morning: the overnight completes and 49 is pinned.
      var frozen = nextFrozenHeadline(
        today: d1,
        overnightComplete: true,
        liveReadiness: 49,
        current: null,
      );
      expect(frozen, isNotNull);
      expect(frozen!.value, 49);

      // Midday re-derive: baseline shifted, the live value dropped to 45 — the
      // exact drift from #128. The pin must hold.
      frozen = nextFrozenHeadline(
        today: d1,
        overnightComplete: true,
        liveReadiness: 45,
        current: frozen,
      );
      expect(frozen!.value, 49, reason: 'a lower re-derive must not move it');

      // Afternoon re-derive that would RAISE it: still pinned (product call —
      // stability wins over a same-day improvement).
      frozen = nextFrozenHeadline(
        today: d1,
        overnightComplete: true,
        liveReadiness: 53,
        current: frozen,
      );
      expect(frozen!.value, 49, reason: 'a higher re-derive must not move it');
    });

    test('a new day → the prior pin is dropped and re-pins on completion', () {
      final day1Pin = (day: d1, value: 49);

      // New day, overnight not complete yet → the day-1 pin no longer applies
      // (getToday also guards by day, but the decision drops it too).
      var frozen = nextFrozenHeadline(
        today: d2,
        overnightComplete: false,
        liveReadiness: 61,
        current: day1Pin,
      );
      expect(frozen, isNull, reason: 'yesterday\'s pin must not carry over');

      // Day-2 overnight completes → a fresh pin for the new day.
      frozen = nextFrozenHeadline(
        today: d2,
        overnightComplete: true,
        liveReadiness: 61,
        current: day1Pin,
      );
      expect(frozen, isNotNull);
      expect(frozen!.day, d2);
      expect(frozen.value, 61);
    });

    test(
        'settling before completion then completing → pins the COMPLETE-night '
        'value, not the partial one', () {
      // Early morning: overnight present but not yet complete → no pin; the live
      // partial-night 70 is shown but never frozen.
      var frozen = nextFrozenHeadline(
        today: d1,
        overnightComplete: false,
        liveReadiness: 70,
        current: null,
      );
      expect(frozen, isNull);

      // Once the night is genuinely complete the (now different) value pins.
      frozen = nextFrozenHeadline(
        today: d1,
        overnightComplete: true,
        liveReadiness: 66,
        current: frozen,
      );
      expect(frozen!.value, 66, reason: 'the complete-night value is pinned');
    });
  });
}
