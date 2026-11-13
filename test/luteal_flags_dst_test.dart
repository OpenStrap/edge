// The cycle-phase flag counts calendar days between logged cycle starts. Parsed
// as local midnight, a span that holds the 23 h spring-forward day is an hour
// short of whole days and `inDays` floors it one day low, so a cycle measured
// across March came out a day short and the night at its midpoint flipped. The
// process zone is moved to America/New_York with setenv+tzset (see
// day_window_dst_test.dart) so this fails without the fix on any host.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';

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

/// 30 nights ending 2024-01-30, each with a skin-temp reading so the
/// temperature flag has a newest night to publish.
List<Map<String, dynamic>> _days() {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < 30; i++) {
    final d = DateTime.utc(2024, 1, 1).add(Duration(days: i));
    final wobble = (i % 5) - 2;
    out.add({
      'date': d.toIso8601String().substring(0, 10),
      'skin_temp_z': wobble * 0.4,
      'skin_temp_adc': 3000.0 + wobble * 8.0,
    });
  }
  return out;
}

bool _lutealOn(List<String> starts) {
  final out = buildCrossDayBundle(_days(), const {}, cycleStartDates: starts);
  return ((out['temp_illness'] as Map)['luteal'] as bool?) ?? false;
}

void main() {
  final originalTz = Platform.environment['TZ'];
  setUpAll(() => _setProcessTz('America/New_York'));
  tearDownAll(() => _setProcessTz(originalTz));

  test('a cycle spanning spring-forward keeps its full length', () {
    expect(
      DateTime(2023, 3, 12, 12).difference(DateTime(2023, 3, 12)),
      const Duration(hours: 11),
      reason: 'setenv(TZ)+tzset() did not apply; the test would be vacuous',
    );
    // 2023-02-26 → 2023-03-25 is 27 days and holds 2023-03-12, the US
    // spring-forward day. That single completed gap is her median length, so
    // the open cycle from 2024-01-17 is 27 days long and the newest night,
    // 2024-01-30, is day 13 of it: 13 < 13.5, first half.
    expect(
      _lutealOn(const ['2023-02-26', '2023-03-25', '2024-01-17']),
      isFalse,
    );
    // Same shape a day later: day 14 of 27 is the second half.
    expect(_lutealOn(const ['2023-02-26', '2023-03-25', '2024-01-16']), isTrue);
  });
}
