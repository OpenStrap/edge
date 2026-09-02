// M2 §14 roll-up: a `?? kWhoopGen4` / `?? BandProfile.gen4` (or a field
// default of the same shape) is a place a SECOND device is silently treated
// as a WHOOP 4. Class A (`kWhoopGen4`) picks a registry fact — wrong opcode
// or field offset. Class B (`BandProfile.gen4`) picks the frame envelope
// itself — wrong header length/CRC, which the band drops silently. Both are
// counted here so the count can only go down; lower a value in the same
// commit that retires a site, never raise either.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// -> 0 by the end of M2 (§18 gate).
const _kWhoopGen4Defaults = 13;
const _bandProfileGen4Defaults = 8;

final _pureComment = RegExp(r'^\s*(///|//|\*|/\*)');

int _countMatches(RegExp pattern) {
  var total = 0;
  for (final f in Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))) {
    for (final line in f.readAsStringSync().split('\n')) {
      if (_pureComment.hasMatch(line)) continue;
      total += pattern.allMatches(line).length;
    }
  }
  return total;
}

void main() {
  test('kWhoopGen4 default-fallback count only goes down', () {
    // `?? kWhoopGen4` sites plus the one field default (`= kWhoopGen4`).
    final count = _countMatches(RegExp(r'\?\?\s*kWhoopGen4')) +
        _countMatches(RegExp(r'=\s*kWhoopGen4\b'));
    expect(count, _kWhoopGen4Defaults,
        reason: 'kWhoopGen4-default count drifted from the tracked value. '
            'If a commit just retired a site, lower _kWhoopGen4Defaults in '
            'this file to match — never raise it.');
  });

  test('BandProfile.gen4 default-fallback count only goes down', () {
    // `?? BandProfile.gen4` sites plus the one field/parameter default
    // (`= BandProfile.gen4`).
    final count = _countMatches(RegExp(r'\?\?\s*BandProfile\.gen4')) +
        _countMatches(RegExp(r'=\s*BandProfile\.gen4\b'));
    expect(count, _bandProfileGen4Defaults,
        reason: 'BandProfile.gen4-default count drifted from the tracked '
            'value. If a commit just retired a site, lower '
            '_bandProfileGen4Defaults in this file to match — never raise '
            'it.');
  });
}
