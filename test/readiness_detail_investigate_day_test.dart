// Recovery opened for a past day (Home's day stepper, or the "See what was
// missing" card) showed that day's score, but Nerd stats opened Investigate
// with no day, so it read the newest derived day instead. Sleep and Beats
// already pass their day through; this pins Recovery to the same contract.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every detail screen hands its day to Investigate', () {
    final src = <String, String>{
      'readiness_detail': "Investigate('readiness', day: d.day)",
      'sleep_detail': "Investigate('sleep', day:",
      'beats': "Investigate('hrv', day:",
    };
    for (final e in src.entries) {
      final text = File('lib/ui2/screens/${e.key}.dart').readAsStringSync();
      expect(text, contains(e.value),
          reason: '${e.key} opens Nerd stats on the newest day, not its own');
    }
    expect(
        File('lib/ui2/screens/readiness_detail.dart').readAsStringSync(),
        isNot(contains("const Investigate('readiness')")));
  });
}
