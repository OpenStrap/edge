// Pure tests for BandPromptPolicy (sync_policy.dart): which requester gets
// to program the band's HIGH_FREQ_SYNC prompt, and when a running
// background lease is renewed. No BLE, no DB.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

void main() {
  final now = DateTime(2026, 9, 21, 23, 0);
  final smartWake = BandPromptRequest.smartWake(
    target: now.add(const Duration(hours: 8)),
    lease: const Duration(minutes: 90),
    source: 'habitual',
  );

  group('BandPromptPolicy.plan', () {
    test('nothing wants a prompt → null', () {
      expect(
        BandPromptPolicy.plan(
          smartWake: null,
          iosBackgrounded: false,
          currentReason: null,
          currentUntil: null,
          now: now,
        ),
        isNull,
      );
    });

    test('iOS backgrounded → 900 s prompts on a 2 h lease', () {
      final r = BandPromptPolicy.plan(
        smartWake: null,
        iosBackgrounded: true,
        currentReason: null,
        currentUntil: null,
        now: now,
      )!;
      expect(r.intervalSeconds, kIosBackgroundPromptIntervalSeconds);
      expect(r.intervalSeconds, 900);
      expect(r.duration, kIosBackgroundPromptLease);
      expect(r.until, now.add(kIosBackgroundPromptLease));
      expect(r.reason, kIosBackgroundPromptReason);
    });

    test('smart wake beats the background keep-alive', () {
      final r = BandPromptPolicy.plan(
        smartWake: smartWake,
        iosBackgrounded: true,
        currentReason: kIosBackgroundPromptReason,
        currentUntil: now.add(const Duration(hours: 1)),
        now: now,
      )!;
      expect(r.intervalSeconds, kSmartWakePromptIntervalSeconds);
      expect(r.intervalSeconds, 61);
      expect(r.reason, 'habitual');
      expect(r.until, smartWake.until);
      expect(r.duration, const Duration(minutes: 90));
    });

    test('smart wake alone (foreground) is byte-identical to today', () {
      final r = BandPromptPolicy.plan(
        smartWake: smartWake,
        iosBackgrounded: false,
        currentReason: null,
        currentUntil: null,
        now: now,
      );
      expect(r, smartWake);
    });

    test('a background lease with more than half left is kept as-is', () {
      final until = now.add(const Duration(minutes: 70)); // 70 of 120 min left
      final r = BandPromptPolicy.plan(
        smartWake: null,
        iosBackgrounded: true,
        currentReason: kIosBackgroundPromptReason,
        currentUntil: until,
        now: now,
      )!;
      expect(r.until, until, reason: 'unchanged → the engine writes nothing');
    });

    test('a background lease past half-way is renewed from now', () {
      final until = now.add(const Duration(minutes: 50)); // 50 of 120 min left
      final r = BandPromptPolicy.plan(
        smartWake: null,
        iosBackgrounded: true,
        currentReason: kIosBackgroundPromptReason,
        currentUntil: until,
        now: now,
      )!;
      expect(r.until, now.add(kIosBackgroundPromptLease));
    });

    test('a running smart-wake lease is not mistaken for a background lease',
        () {
      final r = BandPromptPolicy.plan(
        smartWake: null, // window just closed
        iosBackgrounded: true,
        currentReason: 'habitual',
        currentUntil: now.add(const Duration(minutes: 80)),
        now: now,
      )!;
      expect(r.reason, kIosBackgroundPromptReason);
      expect(r.until, now.add(kIosBackgroundPromptLease));
    });

    test('foregrounded with no window → null even if a background lease runs',
        () {
      expect(
        BandPromptPolicy.plan(
          smartWake: null,
          iosBackgrounded: false,
          currentReason: kIosBackgroundPromptReason,
          currentUntil: now.add(const Duration(hours: 1)),
          now: now,
        ),
        isNull,
      );
    });
  });

  group('BandPromptRequest', () {
    test('iosBackground fits gen5 bounds (> 60 s, < 28800 s)', () {
      final r = BandPromptRequest.iosBackground(now);
      expect(r.intervalSeconds, greaterThan(60));
      expect(r.duration.inSeconds, lessThan(28800));
    });
    test('value equality', () {
      expect(
        BandPromptRequest.iosBackground(now),
        BandPromptRequest.iosBackground(now),
      );
    });
  });
}
