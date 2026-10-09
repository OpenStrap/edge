import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  CoachConfig config() {
    final result = CoachConfig();
    addTearDown(result.dispose);
    return result;
  }

  test(
    'new OpenAI configuration defaults to Responses with no model selected',
    () {
      final cfg = config();
      expect(cfg.baseUrl, CoachConfig.defaultBaseUrl);
      expect(cfg.model, isEmpty);
      expect(cfg.api, CoachApi.responses);
    },
  );

  for (final base in [
    'https://openrouter.ai/api/v1',
    'http://localhost:11434/v1',
    'https://api.openai.com.example.com/v1',
    'http://api.openai.com/v1',
    'https://api.openai.com:8443/v1',
  ]) {
    test('$base defaults to Chat Completions independently of model', () async {
      final cfg = config();
      await cfg.save(baseUrl: base, model: 'gpt-6.1-sol');
      expect(cfg.api, CoachApi.chatCompletions);
      await cfg.save(model: 'an-opaque-model-id');
      expect(cfg.api, CoachApi.chatCompletions);
    });
  }

  group('settings migration', () {
    for (final entry in {
      'https://api.openai.com/v1': CoachApi.responses,
      'http://localhost:11434/v1': CoachApi.chatCompletions,
    }.entries) {
      for (final storedApi in <String?>[null, 'unknown-api', '']) {
        test(
          '${storedApi ?? 'missing'} API defaults from ${entry.key}',
          () async {
            SharedPreferences.setMockInitialValues({
              'coach_base_url': entry.key,
              'coach_model': 'arbitrary-model-id',
              'coach_api': ?storedApi,
            });
            final cfg = config();
            await cfg.load();
            expect(cfg.api, entry.value);
            expect(cfg.model, 'arbitrary-model-id');
            expect(cfg.apiBase, entry.key);
          },
        );
      }
    }

    test(
      'missing all saved settings loads the OpenAI Responses default',
      () async {
        final cfg = config();
        await cfg.load();
        expect(cfg.api, CoachApi.responses);
      },
    );
  });

  group('explicit API persistence', () {
    for (final entry in {
      'https://api.openai.com/v1': CoachApi.chatCompletions,
      'http://localhost:11434/v1': CoachApi.responses,
    }.entries) {
      test(
        '${entry.key} retains its explicit ${entry.value.name} override',
        () async {
          final cfg = config();
          await cfg.save(baseUrl: entry.key, api: entry.value);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('coach_api'), entry.value.name);
          final reloaded = config();
          await reloaded.load();
          expect(reloaded.api, entry.value);
          expect(reloaded.apiBase, entry.key);
        },
      );
    }
  });

  group('endpoint changes', () {
    test(
      'moving from OpenAI to another origin resets to Chat Completions',
      () async {
        final cfg = config();
        await cfg.save(api: CoachApi.responses);
        await cfg.save(baseUrl: 'http://localhost:11434/v1');
        expect(cfg.api, CoachApi.chatCompletions);
        final reloaded = config();
        await reloaded.load();
        expect(reloaded.api, CoachApi.chatCompletions);
      },
    );

    test('moving back to OpenAI resets to Responses', () async {
      final cfg = config();
      await cfg.save(
        baseUrl: 'https://openrouter.ai/api/v1',
        api: CoachApi.chatCompletions,
      );
      await cfg.save(baseUrl: CoachConfig.defaultBaseUrl);
      expect(cfg.api, CoachApi.responses);
    });

    test(
      'moving between custom origins resets an explicit Responses choice',
      () async {
        final cfg = config();
        await cfg.save(
          baseUrl: 'http://localhost:11434/v1',
          api: CoachApi.responses,
        );
        await cfg.save(baseUrl: 'http://localhost:1234/v1');
        expect(cfg.api, CoachApi.chatCompletions);
      },
    );

    test(
      'an explicit choice wins when saved with a different origin',
      () async {
        final cfg = config();
        await cfg.save(
          baseUrl: 'http://localhost:11434/v1',
          api: CoachApi.responses,
        );
        expect(cfg.api, CoachApi.responses);
        await cfg.save(
          baseUrl: CoachConfig.defaultBaseUrl,
          api: CoachApi.chatCompletions,
        );
        expect(cfg.api, CoachApi.chatCompletions);
      },
    );

    test(
      'a same-origin path or trailing slash preserves explicit Chat',
      () async {
        final cfg = config();
        await cfg.save(api: CoachApi.chatCompletions);
        await cfg.save(baseUrl: 'https://api.openai.com/v1/');
        expect(cfg.api, CoachApi.chatCompletions);
        await cfg.save(baseUrl: 'https://api.openai.com/another-path');
        expect(cfg.api, CoachApi.chatCompletions);
        final reloaded = config();
        await reloaded.load();
        expect(reloaded.api, CoachApi.chatCompletions);
      },
    );

    test('a same-origin custom path preserves explicit Responses', () async {
      final cfg = config();
      await cfg.save(
        baseUrl: 'http://localhost:11434/v1',
        api: CoachApi.responses,
      );
      await cfg.save(baseUrl: 'http://localhost:11434/another-path');
      expect(cfg.api, CoachApi.responses);
    });

    test('empty base URL resets to the OpenAI provider default', () async {
      final cfg = config();
      await cfg.save(baseUrl: 'http://localhost:11434/v1');
      expect(cfg.api, CoachApi.chatCompletions);
      await cfg.save(baseUrl: '   ');
      expect(cfg.apiBase, CoachConfig.defaultBaseUrl);
      expect(cfg.api, CoachApi.responses);
    });
  });

  test(
    'model, key, and timeout edits preserve the explicit API choice',
    () async {
      final cfg = config();
      await cfg.save(api: CoachApi.chatCompletions);
      await cfg.save(model: 'gpt-6.1-sol');
      expect(cfg.api, CoachApi.chatCompletions);
      await cfg.save(apiKey: 'synthetic-test-key');
      expect(cfg.api, CoachApi.chatCompletions);
      await cfg.save(timeoutSeconds: 60);
      expect(cfg.api, CoachApi.chatCompletions);
      final reloaded = config();
      await reloaded.load();
      expect(reloaded.api, CoachApi.chatCompletions);
      expect(reloaded.model, 'gpt-6.1-sol');
      expect(reloaded.apiKey, 'synthetic-test-key');
    },
  );
}
