import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  // WHY: finalized days need a new version when the analytics pin changes outputs.
  test('ED-2b adoption and workout rest repin name their output changes', () {
    expect(kAlgoVersion, 127);
    expect(kAnalyticsPin, 'a438df40b38a4586a52a68ab7e1c100fca111ccd');
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
    final repinEntry = src.substring(repin, src.indexOf('// 123 → 124', repin));
    for (final change in ['801c825', '#98', 'workout rest bridge',
      'duration-cap', 'saved-session overlap']) {
      expect(repinEntry, contains(change));
    }
    final mainRepin = src.substring(
        src.indexOf('// 123 → 124'), src.indexOf('// 124 → 125'));
    for (final change in ['a438df4', '#102-#110', '#110', 'regressing clocks',
      '5%', 'Cosinor', 'SDNN', 'uncertainty', 'HrvFreqStream v2',
      'CardioRowCache v3', 'PRSA']) {
      expect(mainRepin, contains(change));
    }
    // A bump must name its output change: v126 is the stress recalibration.
    final stressEntry = src.substring(
        src.indexOf('// 125 → 126'), src.indexOf('const int kAlgoVersion'));
    for (final change in ['#631', 'stress', 'kStressScoreFloorSi',
      'stress_backfill']) {
      expect(stressEntry, contains(change));
    }
    final deriveEntry = src.substring(
        src.indexOf('// 126 → 127'), src.indexOf('const int kAlgoVersion'));
    for (final change in ['stillness', 'active_min', 'vendor', 'ring naps']) {
      expect(deriveEntry, contains(change));
    }
  });
}
