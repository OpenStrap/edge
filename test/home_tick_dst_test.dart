// RED (Home + labels, phase 0). WHY: the sleep ring's unslept estimate is
// "wake minus now", so Home re-reads the clock on every minute boundary. The
// delay to the next minute must come from the UTC instant: in the repeated
// fall-back hour `DateTime(y, m, d, h, min + 1)` resolves to the FIRST
// occurrence of that wall time, an hour in the past, which became a zero-delay
// Timer and a setState loop. Ported from the fork's test/home_tick_dst_test.dart
// (the pure delay function only; the screen-level ticking is pinned in
// home_sleep_ring_widget_test.dart).
//
// The process timezone is moved with the shared setProcessTz helper (POSIX
// setenv/tzset) and restored afterwards, so the repeated hour is real on any
// host. Every instant is built from UTC; nothing reads the system clock.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/process_tz.dart';

void main() {
  final originalTz = Platform.environment['TZ'];

  setUp(() {
    if (Platform.isWindows) markTestSkipped('POSIX-only (libc setenv)');
    setProcessTz('America/Denver');
  });
  tearDown(() => setProcessTz(originalTz));

  group('nextMinuteTickDelay', () {
    test('fall back 2026-11-01, second 01:30:30 MST (08:30:30Z): 30 s', () {
      final now = DateTime.utc(2026, 11, 1, 8, 30, 30).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 30));
    });

    test('every second of the repeated hour waits (0, 60 s]', () {
      final start = DateTime.utc(2026, 11, 1, 7, 55);
      for (var s = 0; s < 15 * 60; s += 7) {
        final now = start.add(Duration(seconds: s)).toLocal();
        final d = nextMinuteTickDelay(now);
        expect(d > Duration.zero, isTrue, reason: '$now -> $d');
        expect(d <= const Duration(seconds: 60), isTrue, reason: '$now -> $d');
      }
    });

    test('on a whole minute the next tick is a full minute away', () {
      final now = DateTime.utc(2026, 11, 1, 8, 30).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 60));
    });

    test('one millisecond before the boundary', () {
      final now = DateTime.utc(2026, 11, 1, 8, 30, 59, 999).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(milliseconds: 1));
    });

    test('spring forward 2026-03-08: 01:59:30 MST (08:59:30Z) is 30 s', () {
      final now = DateTime.utc(2026, 3, 8, 8, 59, 30).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 30));
    });

    test('spring forward: the first MDT second waits a full minute', () {
      final now = DateTime.utc(2026, 3, 8, 9, 0).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 60));
    });

    test('a half-hour zone has the same minute boundaries', () {
      setProcessTz('Asia/Kolkata');
      final now = DateTime.utc(2026, 11, 1, 8, 30, 45).toLocal();
      expect(nextMinuteTickDelay(now), const Duration(seconds: 15));
    });
  });
}
