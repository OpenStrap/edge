// shouldAttemptBangleJsSync gates the ~20s connect-and-listen window (see
// background_sync.dart's call site doc) behind a cooldown so a headless wake
// doesn't pay for it every single time, regardless of how recently we tried.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/background_sync.dart';

void main() {
  test('never attempted (null) always attempts', () {
    expect(shouldAttemptBangleJsSync(null, 1000), isTrue);
  });

  test('inside the cooldown window does not attempt', () {
    final last = 1000;
    final now = last + const Duration(minutes: 19).inMilliseconds;
    expect(shouldAttemptBangleJsSync(last, now), isFalse);
  });

  test('exactly at the cooldown boundary attempts', () {
    final last = 1000;
    final now = last + const Duration(minutes: 20).inMilliseconds;
    expect(shouldAttemptBangleJsSync(last, now), isTrue);
  });

  test('past the cooldown window attempts', () {
    final last = 1000;
    final now = last + const Duration(hours: 1).inMilliseconds;
    expect(shouldAttemptBangleJsSync(last, now), isTrue);
  });
}
