import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  test('ED-2b takes one version bump and names the output changes', () {
    expect(kAlgoVersion, 120);
    expect(kAnalyticsPin, 'f8e7d3c478cc59707fde41f3edff7736026573fe');
    final src = File('lib/compute/derivation_engine.dart').readAsStringSync();
    final at = src.indexOf('// 119 → 120');
    expect(at, isNonNegative);
    final entry = src.substring(at, src.indexOf('const int kAlgoVersion', at));
    for (final change in ['f8e7d3c', '32', 'hrvTime', 'banisterTrimp',
      'ctlAtlTsb', 'cosinor', 'timeInZone', 'circadianNonparametric',
      'Lomb–Scargle', 'non-finite', 'irregular-screen gaps', 'D35', 'D36',
      'forward-only', 'staging labels unchanged']) {
      expect(entry, contains(change));
    }
  });
}
