// Counter spans bucket by LOCAL hour. In a half-hour-offset zone a UTC hour
// runs :30 to :29 local, so two walks in different local hours can share a UTC
// hour; merged into one span, the day chart's even spread moves steps into the
// wrong hour. The process zone is moved to Asia/Kolkata with setenv+tzset (see
// day_window_dst_test.dart) so this fails without the fix on any host.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/substrate.dart';

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
  setUpAll(() => _setProcessTz('Asia/Kolkata'));
  tearDownAll(() => _setProcessTz(originalTz));

  test('walks in two local hours of one UTC hour stay two spans', () {
    // 2026-06-15 10:30 IST = 05:00 UTC, a whole UTC hour.
    final h = DateTime(2026, 6, 15, 10, 30);
    expect(h.timeZoneOffset, const Duration(hours: 5, minutes: 30),
        reason: 'setenv(TZ)+tzset() did not apply; the test would be vacuous');
    final base = h.millisecondsSinceEpoch ~/ 1000;
    // Records every 5 min, 10:30-11:25 local. 1000 steps over 10:40-10:55,
    // 50 over 11:20-11:25, all inside UTC hour 05.
    final counters = [0, 0, 0, 250, 500, 1000, 1000, 1000, 1000, 1000, 1000, 1050];
    final n = counters.length;
    final sub = Substrate(
      tsSec: [for (var i = 0; i < n; i++) base + i * 300],
      hr: List<int>.filled(n, 60),
      rrTsMs: const [],
      rrMs: const [],
      ax: List<double>.filled(n, 0),
      ay: List<double>.filled(n, 0),
      az: List<double>.filled(n, 1),
      spo2Red: List<int>.filled(n, 0),
      spo2Ir: List<int>.filled(n, 0),
      skinTemp: List<int>.filled(n, 0),
      skinContact: List<int>.filled(n, 0),
      stepCount: counters,
    );
    final spans =
        hardwareStepSpansFromCounter(sub, cumulativeCounterModulus: 65536)!;
    expect([for (final s in spans) (s.startTs, s.endTs, s.steps)], [
      (base + 600, base + 1500, 1000),
      (base + 3000, base + 3300, 50),
    ]);
  }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);
}
