// M0 §5.4: the skin-temperature unit gate. gen4's `skin_temp_raw` is a
// ~30 000-count thermistor ADC reading; gen5's/the ring's `skin_temp_c` is
// centi-°C (~3 300). Mixing both in one positional skinTemp[] array is a ~10x
// step change that renders as a fever (spec-m0-m2.md §5.1).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';

void main() {
  group('_skinTempFor via substrateFromDecodedPage (raw-only / c-only / mixed)',
      () {
    test('a raw-only day carries the raw ADC counts through unchanged', () {
      final frames = [
        for (var t = 0; t < 5; t++)
          {'rec_ts': 1000 + t, 'hr': 60, 'skin_temp_raw': 30000 + t},
      ];
      final sub = substrateFromDecodedPage(frames, const []);
      expect(sub.skinTemp, [30000, 30001, 30002, 30003, 30004]);
    });

    test('a c-only day converts to centi-°C unchanged', () {
      final frames = [
        for (var t = 0; t < 3; t++)
          {'rec_ts': 2000 + t, 'hr': 60, 'skin_temp_c': 33.0 + t / 10},
      ];
      final sub = substrateFromDecodedPage(frames, const []);
      expect(sub.skinTemp, [3300, 3310, 3320]);
    });

    test(
        'a mixed day keeps the FIRST row\'s unit and lands the other unit\'s '
        'rows on the absent sentinel (0)', () {
      final frames = [
        {'rec_ts': 3000, 'hr': 60, 'skin_temp_raw': 30000}, // establishes raw
        {'rec_ts': 3001, 'hr': 60, 'skin_temp_c': 33.0}, // minority unit
        {'rec_ts': 3002, 'hr': 60, 'skin_temp_raw': 30002},
      ];
      final sub = substrateFromDecodedPage(frames, const []);
      expect(sub.skinTemp, [30000, 0, 30002],
          reason:
              'the centi-°C row must read as absent, never as a fabricated '
              '~10x-smaller raw ADC count');
    });
  });

  group('structural: skin_temp_raw and skin_temp_c never write from each '
      'other\'s value', () {
    test('no lib/ file crosses skin_temp_raw <-> skin_temp_c', () {
      // Cites lib/ble/adapters/adapter.dart's per-family signal-declaration
      // doc comment as the invariant being enforced: a family reports at
      // most one of these two per row, and no writer may launder one into
      // the other's column.
      final rawKey = RegExp(r"'skin_temp_raw'\s*:");
      final cKey = RegExp(r"'skin_temp_c'\s*:");
      final crossedNameOnRawLine = RegExp(r'skinTempC|skin_temp_c');
      final crossedNameOnCLine = RegExp(r'skinTempRaw|skin_temp_raw');
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        for (final line in f.readAsStringSync().split('\n')) {
          if (rawKey.hasMatch(line) && crossedNameOnRawLine.hasMatch(line)) {
            offenders.add('${f.path}: $line');
          }
          if (cKey.hasMatch(line) && crossedNameOnCLine.hasMatch(line)) {
            offenders.add('${f.path}: $line');
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });
}
