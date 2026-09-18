// Smart Wake Window's light-sleep proxy — pure, no DB, no BLE. Builds fake
// SmartWakeSample windows directly rather than going through decoded_onehz
// rows, since the heuristic itself (state/smart_wake.dart) takes samples, not
// rows — the DB read is a separate, thin, untested-here mapping
// (LocalDb.onehzHrAccelBetween + SmartWakeSample.fromRow).

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/state/smart_wake.dart';

List<SmartWakeSample> _still(double hr, int n) =>
    List.generate(n, (_) => SmartWakeSample(hr, 0, 0, 1.0)); // resting, 1g

List<SmartWakeSample> _moving(double hr, int n) =>
    List.generate(n, (i) => SmartWakeSample(hr, 0.5, 0.4, 1.0));

void main() {
  group('likelyLightSleep', () {
    test('too-short baseline → false, never guesses', () {
      expect(
          likelyLightSleep(
              baseline: _still(55, 5), recent: _still(65, 60)),
          isFalse);
    });

    test('too-short recent window → false, never guesses', () {
      expect(
          likelyLightSleep(
              baseline: _still(55, 90), recent: _still(65, 5)),
          isFalse);
    });

    test('HR elevated above baseline with no big movement → light sleep '
        'likely (true)', () {
      final baseline = _still(52, 90); // deep-sleep-ish resting HR
      final recent = _still(58, 60); // +6 bpm, still, no movement
      expect(likelyLightSleep(baseline: baseline, recent: recent), isTrue);
    });

    test('HR flat against baseline (no arousal) → false', () {
      final baseline = _still(52, 90);
      final recent = _still(53, 60); // +1 bpm — under the default threshold
      expect(likelyLightSleep(baseline: baseline, recent: recent), isFalse);
    });

    test('HR elevated BUT with wake-level movement → false (moving, not '
        'lightening sleep)', () {
      final baseline = _still(52, 90);
      final recent = _moving(60, 60); // +8 bpm but actually moving
      expect(likelyLightSleep(baseline: baseline, recent: recent), isFalse);
    });

    test('HR below baseline (deeper, not lighter) → false', () {
      final baseline = _still(60, 90);
      final recent = _still(54, 60);
      expect(likelyLightSleep(baseline: baseline, recent: recent), isFalse);
    });
  });
}
