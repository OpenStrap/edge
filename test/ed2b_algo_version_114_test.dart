import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  // WHY: finalized days need a new version when the analytics pin changes outputs.
  test('ED-2b adoption and workout rest repin name their output changes', () {
    expect(kAlgoVersion, 123);
    expect(kAnalyticsPin, '801c82536caf5ce70270aae5215f21cd423a8bd2');
    final src = File('lib/compute/derivation_engine.dart').readAsStringSync();
    final at = src.indexOf('// 121 → 122');
    expect(at, isNonNegative);
    final entry = src.substring(at, src.indexOf('const int kAlgoVersion', at));
    for (final change in ['f8e7d3c', '32', 'hrvTime', 'banisterTrimp',
      'ctlAtlTsb', 'cosinor', 'timeInZone', 'circadianNonparametric',
      'Lomb–Scargle', 'non-finite', 'irregular-screen gaps', 'D35', 'D36',
      'forward-only', 'staging labels unchanged']) {
      expect(entry, contains(change));
    }
    final repin = src.indexOf('// 122 → 123');
    expect(repin, isNonNegative);
    final repinEntry = src.substring(
        repin, src.indexOf('const int kAlgoVersion', repin));
    for (final change in ['801c825', '#98', 'workout rest bridge',
      'duration-cap', 'saved-session overlap']) {
      expect(repinEntry, contains(change));
    }
  });
}
