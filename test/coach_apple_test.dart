import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_apple.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one question goes through as it is', () {
    expect(
        AppleOnDevice.buildPrompt([
          {'role': 'system', 'content': 'rules'},
          {'role': 'user', 'content': 'How did I sleep?'},
        ]),
        'How did I sleep?');
  });

  test('a chat keeps the latest question whole and drops tool traffic', () {
    final p = AppleOnDevice.buildPrompt([
      {'role': 'user', 'content': 'first ' * 2000},
      {'role': 'assistant', 'content': 'an answer'},
      {'role': 'tool', 'content': 'SECRET ROWS'},
      {'role': 'user', 'content': 'And today?'},
    ]);
    expect(p.endsWith('Now: And today?'), isTrue);
    expect(p.contains('SECRET ROWS'), isFalse);
    expect(p.length, lessThanOrEqualTo(AppleOnDevice.promptBudget + 40));
  });

  test('choosing Apple needs no key and counts as on-device', () async {
    SharedPreferences.setMockInitialValues({});
    final cfg = CoachConfig();
    await cfg.load();
    expect(cfg.configured, isFalse);
    await cfg.save(useApple: true);
    expect(cfg.usesApple, isTrue);
    expect(cfg.configured, isTrue);
    expect(cfg.remindersConfigured, isTrue);
    expect(cfg.isPrivateEndpoint, isTrue);
    expect(cfg.usesChatGpt, isFalse);
    expect(cfg.model, kAppleOnDeviceModel);
    final again = CoachConfig();
    await again.load();
    expect(again.usesApple, isTrue);
  });
}
