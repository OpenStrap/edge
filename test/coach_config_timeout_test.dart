// The provider request timeout used to be a hardcoded 120s in coach_engine.dart,
// which is too short for a local model's first response: Ollama loads the full
// model into memory on first use, and that alone can exceed two minutes on
// modest hardware — the user saw total silence for 2:00 then a hard
// TimeoutException, with no way to give it more room.
//
// The fix only makes the timeout configurable for a LOCAL endpoint. A cloud
// provider fails in seconds, not minutes, when something is actually wrong,
// so it always gets a fixed, shorter timeout regardless of what is saved.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a cloud endpoint uses the fixed two-minute timeout by default', () {
    final cfg = CoachConfig(); // default baseUrl is the cloud OpenAI endpoint
    expect(cfg.requestTimeout, const Duration(minutes: 2));
  });

  test('a cloud endpoint ignores a saved timeout', () async {
    final cfg = CoachConfig();
    await cfg.save(timeoutSeconds: 45);
    expect(cfg.requestTimeout, const Duration(minutes: 2),
        reason: 'the configurable timeout only applies to a local endpoint');
  });

  test('a local endpoint defaults to five minutes', () async {
    final cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://localhost:11434/v1');
    expect(cfg.requestTimeout, const Duration(minutes: 5));
  });

  test('a saved timeout applies once the endpoint is local, and survives reload',
      () async {
    final cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://localhost:11434/v1', timeoutSeconds: 45);
    expect(cfg.requestTimeout, const Duration(seconds: 45));

    final reloaded = CoachConfig();
    await reloaded.load();
    expect(reloaded.requestTimeout, const Duration(seconds: 45));
  });

  test('a non-positive timeout is rejected in favour of the previous value',
      () async {
    final cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://localhost:11434/v1', timeoutSeconds: 30);
    await cfg.save(timeoutSeconds: 0);
    expect(cfg.requestTimeout, const Duration(seconds: 30),
        reason: 'a 0s timeout would fail every request instantly');
  });

  test('timeoutSeconds reflects the saved value even while a cloud endpoint '
      'is active', () async {
    final cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://localhost:11434/v1', timeoutSeconds: 90);
    await cfg.save(baseUrl: 'https://api.openai.com/v1');
    expect(cfg.timeoutSeconds, 90,
        reason: 'a UI switching back to local should see its old value again');
    expect(cfg.requestTimeout, const Duration(minutes: 2),
        reason: 'but the cloud endpoint must not actually use it');
  });
}
