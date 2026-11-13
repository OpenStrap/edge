// Moves the PROCESS timezone with libc setenv("TZ") + tzset(), the way
// test/day_window_dst_test.dart does. Dart's DateTime reads the C library's
// local time on every call, so this genuinely re-homes the local calendar. The
// host is very unlikely to sit in a DST zone, and CI runs under UTC, where a
// UTC-placed or fixed-24-hour day would pass every ordinary date. POSIX only.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

/// Sets the process timezone to [tz] (an IANA name), or clears it when null.
void setProcessTz(String? tz) {
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
