// The picker's sensor scan holds the shared scan lock for its whole 15 s
// window. Every screen it pushes runs a scan of its own, and the picker stays
// mounted underneath a push, so unless the picker stops its scan first the
// pushed screen's scan queues behind it ("Find my band" spinning for up to
// ~27 s instead of 12 s). Structural, because the lock and the radio are not
// reachable from a widget test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every push from the device picker stops its own scan first', () {
    final src = File('lib/ui2/pairing/device_picker.dart').readAsStringSync();
    final pushes = RegExp(r'Navigator\.of\(context\)\.push\(').allMatches(src);
    expect(pushes, isNotEmpty);
    for (final m in pushes) {
      final before = src.substring(0, m.start);
      final lastStop = before.lastIndexOf('HrsLink.stopScanIfRunning(this)');
      final lastFn = before.lastIndexOf(RegExp(r'\n  (Future<void>|void) _'));
      expect(lastStop, greaterThan(lastFn),
          reason: 'push at offset ${m.start} is not preceded by '
              'stopScanIfRunning in the same method');
      final between = before.substring(lastStop);
      expect(RegExp(r'Navigator\.of\(context\)\.push\(').hasMatch(between),
          isFalse,
          reason: 'one stop must not be shared by two pushes');
    }
  });
}
