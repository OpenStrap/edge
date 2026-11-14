// The fired-key / notification-slot retention cutoff is "14 calendar days
// before today". It used to be `now.subtract(Duration(days: 14))`, which is
// 336 h: across a DST change one of those days is 23 or 25 h, so in the hour
// either side of midnight the cutoff landed one day early or late. Real
// DST only bites if the PROCESS timezone has DST, so this moves it (libc
// setenv("TZ") + tzset(), as day_window_dst_test does). Windows has neither
// symbol, so the file is skipped there rather than failing in setUpAll.
@TestOn('!windows')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/fired_keys.dart';

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

void main() {
  final originalTz = Platform.environment['TZ'];
  // America/New_York: 2026-03-08 is 23 h long, 2026-11-01 is 25 h long.
  setUpAll(() => _setProcessTz('America/New_York'));
  tearDownAll(() => _setProcessTz(originalTz));

  test('the host really is on a DST zone (or this test proves nothing)', () {
    expect(DateTime(2026, 3, 9).difference(DateTime(2026, 3, 8)).inHours, 23);
  });

  test('just after midnight, past a 23 h day: still 14 calendar days', () {
    // 336 h before 00:30 lands at 23:30 on 02-22, a day too far back.
    expect(FiredKeyStore.cutoffLabel(DateTime(2026, 3, 9, 0, 30)),
        '2026-02-23');
  });

  test('just before midnight, past a 25 h day: still 14 calendar days', () {
    // 336 h before 23:30 lands at 00:30 on 10-20, a day too recent.
    expect(FiredKeyStore.cutoffLabel(DateTime(2026, 11, 2, 23, 30)),
        '2026-10-19');
  });

  test('an ordinary day is unchanged', () {
    expect(FiredKeyStore.cutoffLabel(DateTime(2026, 6, 20, 12)), '2026-06-06');
  });
}
