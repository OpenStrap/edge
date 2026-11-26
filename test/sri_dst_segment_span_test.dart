// SLEEP-REGULARITY SEGMENT COVERAGE ACROSS A DST TRANSITION (#914).
//
// `_crossDaySri` marks the clock-minutes-of-day a hypnogram segment covers.
// The old code derived the span from the clock-minute DIFFERENCE of the
// segment's two endpoints, which is wrong across a DST change: in the autumn
// the local clock steps BACK an hour, so a 10-minute segment that straddles the
// fall-back read `endMin - startMin == 1390` and marked nearly the whole day as
// observed (and asleep, if the segment was sleep), inflating SRI. The fix walks
// the segment in ELAPSED minutes and maps each instant to its clock-minute, so
// only the minutes actually lived are marked.
//
// The host running these tests almost certainly does not sit in a DST zone, so
// we move the PROCESS timezone with libc setenv("TZ")+tzset() before asserting
// (same mechanism as day_window_dst_test). Dart's DateTime reads the C
// library's local time on every call, so this genuinely re-homes the local
// calendar. POSIX only — the test self-skips on Windows.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart'
    show segmentClockMinutes;

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

void _setProcessTz(String? tz) {
  final lib = DynamicLibrary.process();
  final key = 'TZ'.toNativeUtf8();
  try {
    if (tz == null) {
      lib.lookupFunction<_UnsetenvNative, _UnsetenvDart>('unsetenv')(key);
    } else {
      final value = tz.toNativeUtf8();
      lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv')(key, value, 1);
      calloc.free(value);
    }
    lib.lookupFunction<_TzsetNative, _TzsetDart>('tzset')();
  } finally {
    calloc.free(key);
  }
}

int _utcSec(int y, int mo, int d, int h, int mi) =>
    DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

void main() {
  final originalTz = Platform.environment['TZ'];
  final skip = Platform.isWindows ? 'POSIX setenv/tzset only' : null;

  setUpAll(() => _setProcessTz('America/New_York'));
  tearDownAll(() => _setProcessTz(originalTz));

  // America/New_York: 2026-03-08 springs forward, 2026-11-01 falls back.
  const d = <String, dynamic>{};

  test(
    'the DST fixture timezone actually applied (guards the whole file)',
    () {
      expect(
        DateTime(2026, 3, 8).timeZoneOffset,
        const Duration(hours: -5),
        reason:
            'setenv(TZ)+tzset() did not re-home the local calendar; the '
            'assertions below would be vacuous',
      );
    },
    skip: skip,
  );

  test(
    'autumn fall-back: a 10-minute segment covers 10 clock-minutes, not 1390',
    () {
      // 05:55 UTC = 01:55 EDT, 06:05 UTC = 01:05 EST — 10 minutes elapsed across
      // the 02:00 EDT -> 01:00 EST fall-back.
      final mins = segmentClockMinutes(
        _utcSec(2026, 11, 1, 5, 55),
        _utcSec(2026, 11, 1, 6, 5),
        d,
      );
      expect(mins.length, 10, reason: 'elapsed minutes, not the 1390 of #914');
      expect(mins.toSet(), {
        115,
        116,
        117,
        118,
        119,
        60,
        61,
        62,
        63,
        64,
      }, reason: '01:55–01:59 EDT then the repeated 01:00–01:04 EST');
    },
    skip: skip,
  );

  test(
    'spring forward: a 10-minute segment covers 10 clock-minutes, not 70',
    () {
      // 06:55 UTC = 01:55 EST, 07:05 UTC = 03:05 EDT — 10 minutes elapsed across
      // the 02:00 EST -> 03:00 EDT jump.
      final mins = segmentClockMinutes(
        _utcSec(2026, 3, 8, 6, 55),
        _utcSec(2026, 3, 8, 7, 5),
        d,
      );
      expect(mins.length, 10);
      expect(
        mins.toSet(),
        {115, 116, 117, 118, 119, 180, 181, 182, 183, 184},
        reason:
            '01:55–01:59 EST then 03:00–03:04 EDT (02:00–02:59 never lived)',
      );
    },
    skip: skip,
  );

  test('ordinary local-midnight crossing still wraps correctly', () {
    // 2026-06-15 23:50 EDT -> 00:10 EDT (no DST change). 20 minutes, wrapping
    // the local-midnight boundary.
    final mins = segmentClockMinutes(
      _utcSec(2026, 6, 16, 3, 50),
      _utcSec(2026, 6, 16, 4, 10),
      d,
    );
    expect(mins.length, 20);
    expect(mins.first, 1430); // 23:50
    expect(mins.contains(1439), isTrue); // 23:59
    expect(mins.contains(0), isTrue); // 00:00
    expect(mins.last, 9); // 00:09
  }, skip: skip);

  test('empty or reversed segment covers nothing', () {
    final t = _utcSec(2026, 6, 16, 3, 50);
    expect(segmentClockMinutes(t, t, d), isEmpty);
    expect(segmentClockMinutes(t + 60, t, d), isEmpty);
  }, skip: skip);
}
