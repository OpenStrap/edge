// cleanDeviceLabel — the guard that keeps "?*" junk (from a bad HELLO parse) out
// of the persisted/displayed device label, while allowing real serials and
// user-set strap names.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/paired_device.dart';

void main() {
  group('cleanDeviceLabel', () {
    test('accepts real serials and strap names', () {
      expect(cleanDeviceLabel('4C2248092'), '4C2248092');
      expect(cleanDeviceLabel("Abdul's WHOOP"), "Abdul's WHOOP");
      expect(cleanDeviceLabel('WHOOP 4.0'), 'WHOOP 4.0');
      expect(cleanDeviceLabel('  4C2248092  '), '4C2248092'); // trimmed
    });
    test('rejects "?*"-style junk', () {
      expect(cleanDeviceLabel('?*'), isNull);
      expect(cleanDeviceLabel('4C?*92'), isNull);
      expect(cleanDeviceLabel('abc'), isNull); // control chars
      expect(cleanDeviceLabel('serial#@!'), isNull);
    });
    test('rejects empty / punctuation-only', () {
      expect(cleanDeviceLabel(null), isNull);
      expect(cleanDeviceLabel(''), isNull);
      expect(cleanDeviceLabel('   '), isNull);
      expect(cleanDeviceLabel("--' ."), isNull);
    });
  });
}
