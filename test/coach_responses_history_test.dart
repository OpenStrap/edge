import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/coach/coach_responses.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo extends LocalRepository {}

class _DocumentsProvider extends PathProviderPlatform {
  _DocumentsProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

Future<Directory> _temporaryDocuments() async {
  final directory = await Directory.systemTemp.createTemp('coach-responses-');
  final original = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _DocumentsProvider(directory.path);
  addTearDown(() async {
    PathProviderPlatform.instance = original;
    await directory.delete(recursive: true);
  });
  return directory;
}

Map<String, dynamic> _reasoning(String id, int chars) => {
  'id': id,
  'type': 'reasoning',
  'summary': <dynamic>[],
  'encrypted_content': 'x' * chars,
};

Map<String, dynamic> _renderCall() => {
  'id': 'fc_render',
  'type': 'function_call',
  'status': 'completed',
  'call_id': 'call_render',
  'name': 'render',
  'arguments': jsonEncode({
    'type': 'table',
    'title': 'Observed data',
    'columns': ['status'],
    'rows': [
      ['ok'],
    ],
  }),
};

Map<String, dynamic> _answer(String id, String text) => {
  'id': id,
  'type': 'message',
  'status': 'completed',
  'role': 'assistant',
  'phase': 'final_answer',
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': []},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'oversized current reasoning turn fails before a broken continuation',
    () async {
      var requests = 0;
      final output = [
        _reasoning('rs_current', CoachEngine.kMaxHistoryChars + 1000),
        _renderCall(),
      ];
      final client = MockClient((request) async {
        requests++;
        expect(request.url.path, '/v1/responses');
        return http.Response(
          jsonEncode({'status': 'completed', 'output': output}),
          200,
        );
      });
      final config = CoachConfig();
      await config.save(model: 'gpt-6.1-sol');
      addTearDown(config.dispose);
      final engine = CoachEngine(
        config: config,
        api: _FakeRepo(),
        client: client,
      );
      addTearDown(engine.dispose);
      final items = <CoachItem>[];
      await expectLater(
        engine.send(
          'Render the observed data.',
          onItem: items.add,
          onStatus: (_) {},
          confirm: (_) async => fail('Render must not request a write.'),
        ),
        throwsA(isA<CoachException>()),
      );

      expect(
        requests,
        1,
        reason: 'An orphaned continuation must never be sent.',
      );
      expect(items.map((item) => item.kind), [
        CoachItemKind.user,
        CoachItemKind.render,
      ]);
      expect(engine.debugHistory.map((message) => message['role']), [
        'user',
        'assistant',
        'tool',
      ]);
      final assistant = engine.debugHistory[1];
      expect(assistant['_responses_output'], output);
      expect(assistant['tool_calls'][0]['id'], 'call_render');
      expect(engine.debugHistory.last['tool_call_id'], 'call_render');
    },
  );

  test(
    'a fresh turn drops old reasoning and its entire tool continuation',
    () async {
      Map<String, dynamic>? sent;
      final client = MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'status': 'completed',
            'output': [_answer('msg_fresh', 'Fresh answer')],
          }),
          200,
        );
      });
      final config = CoachConfig();
      await config.save(model: 'gpt-6.1-sol');
      addTearDown(config.dispose);
      final engine = CoachEngine(
        config: config,
        api: _FakeRepo(),
        client: client,
      );
      addTearDown(engine.dispose);
      engine.debugHistory.addAll([
        {'role': 'user', 'content': 'Old question'},
        CoachResponses.reply(
          {
            'status': 'completed',
            'output': [
              _reasoning('rs_old', CoachEngine.kMaxHistoryChars + 1000),
              _renderCall(),
            ],
          },
          'gpt-6.1-sol',
          apiBase: CoachConfig.defaultBaseUrl,
        ),
        {
          'role': 'tool',
          'tool_call_id': 'call_render',
          'content': 'Rendered "table" for the user.',
        },
        {'role': 'assistant', 'content': 'Old answer'},
      ]);

      final items = <CoachItem>[];
      await engine.send(
        'Fresh question',
        onItem: items.add,
        onStatus: (_) {},
        confirm: (_) async => fail('Text must not request a write.'),
      );

      final input = (sent!['input'] as List).cast<Map>();
      expect(input, hasLength(2));
      expect(input.first['role'], 'system');
      expect(input.last, {'role': 'user', 'content': 'Fresh question'});
      expect(jsonEncode(sent), isNot(contains('rs_old')));
      expect(jsonEncode(sent), isNot(contains('call_render')));
      expect(engine.debugHistory.first['content'], 'Fresh question');
      expect(items.last.text, 'Fresh answer');
    },
  );

  test(
    'saved session preserves encrypted state and resumes the tool history',
    () async {
      final directory = await _temporaryDocuments();
      final reasoning = _reasoning('rs_saved', 128);
      final commentary = _answer('msg_commentary', 'Reading the observed data.')
        ..['phase'] = 'commentary';
      final call = _renderCall();
      final finalAnswer = _answer(
        'msg_saved_final',
        'The observed status is ok.',
      );
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(
          jsonEncode({
            'status': 'completed',
            'output': requests == 1
                ? [reasoning, commentary, call]
                : [finalAnswer],
          }),
          200,
        );
      });
      final config = CoachConfig();
      await config.save(model: 'gpt-6.1-sol');
      addTearDown(config.dispose);
      final engine = CoachEngine(
        config: config,
        api: _FakeRepo(),
        client: client,
        storageKey: 'saved_session',
      );
      addTearDown(engine.dispose);
      await engine.send(
        'Render the observed data.',
        onItem: (_) {},
        onStatus: (_) {},
        confirm: (_) async => fail('Render must not request a write.'),
      );
      expect(requests, 2);
      await engine.persist();

      final session = File(
        '${directory.path}/coach_s_saved_session_${engine.sessionId}.json',
      );
      expect(await session.exists(), isTrue);
      final saved = jsonDecode(await session.readAsString()) as Map;
      expect(saved['history'], engine.debugHistory);
      Map<String, dynamic>? resumedRequest;
      final resumedClient = MockClient((request) async {
        resumedRequest = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'status': 'completed',
            'output': [_answer('msg_resumed', 'The saved table showed ok.')],
          }),
          200,
        );
      });
      final resumed = CoachEngine(
        config: config,
        api: _FakeRepo(),
        client: resumedClient,
        storageKey: 'saved_session',
      );
      addTearDown(resumed.dispose);
      await resumed.openSession(engine.sessionId);
      expect(resumed.debugHistory, saved['history']);
      expect(resumed.transcript.map((item) => item.kind), [
        CoachItemKind.user,
        CoachItemKind.assistant,
        CoachItemKind.render,
        CoachItemKind.assistant,
      ]);
      final pending = resumed.debugHistory[1];
      expect(pending['_responses_model'], 'gpt-6.1-sol');
      expect(pending['_responses_api_base'], CoachConfig.defaultBaseUrl);
      expect(pending['_responses_output'], [reasoning, commentary, call]);
      expect(resumed.debugHistory.last['_responses_output'], [finalAnswer]);

      await resumed.send(
        'What did the table show?',
        onItem: (_) {},
        onStatus: (_) {},
        confirm: (_) async => fail('Text must not request a write.'),
      );
      final input = (resumedRequest!['input'] as List).cast<Map>();
      expect(input.skip(1).take(7), [
        {'role': 'user', 'content': 'Render the observed data.'},
        reasoning,
        commentary,
        call,
        {
          'type': 'function_call_output',
          'call_id': 'call_render',
          'output': 'Rendered "table" for the user.',
        },
        finalAnswer,
        {'role': 'user', 'content': 'What did the table show?'},
      ]);
      expect(resumed.transcript.last.text, 'The saved table showed ok.');
    },
  );

  test(
    'saved message cap retains complete user turns and call-result groups',
    () async {
      final directory = await _temporaryDocuments();
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': 'completed',
            'output': [_answer('msg_newest', 'Newest answer')],
          }),
          200,
        ),
      );
      final config = CoachConfig();
      await config.save(model: 'gpt-6.1-sol');
      addTearDown(config.dispose);
      final engine = CoachEngine(
        config: config,
        api: _FakeRepo(),
        client: client,
        storageKey: 'message_cap',
      );
      addTearDown(engine.dispose);
      for (var turn = 0; turn < 16; turn++) {
        final call = _renderCall()
          ..['id'] = 'fc_turn_$turn'
          ..['call_id'] = 'call_turn_$turn';
        engine.debugHistory.addAll([
          {'role': 'user', 'content': 'Old question $turn'},
          CoachResponses.reply(
            {
              'status': 'completed',
              'output': [_reasoning('rs_turn_$turn', 32), call],
            },
            'gpt-6.1-sol',
            apiBase: CoachConfig.defaultBaseUrl,
          ),
          {
            'role': 'tool',
            'tool_call_id': 'call_turn_$turn',
            'content': 'Rendered "table" for the user.',
          },
          {'role': 'assistant', 'content': 'Old answer $turn'},
        ]);
      }
      await engine.send(
        'Newest question',
        onItem: (_) {},
        onStatus: (_) {},
        confirm: (_) async => fail('Text must not request a write.'),
      );
      expect(engine.debugHistory, hasLength(66));
      await engine.persist();
      final session = File(
        '${directory.path}/coach_s_message_cap_${engine.sessionId}.json',
      );
      expect(await session.exists(), isTrue);
      final saved = jsonDecode(await session.readAsString()) as Map;
      final history = (saved['history'] as List).cast<Map>();
      expect(history.length, lessThanOrEqualTo(60));
      expect(history.first, {'role': 'user', 'content': 'Old question 2'});
      expect(history.last['_responses_model'], 'gpt-6.1-sol');
      expect(history.last['_responses_api_base'], CoachConfig.defaultBaseUrl);
      expect(history.last['content'], 'Newest answer');
      final input =
          (CoachResponses.request({
                    'model': 'gpt-6.1-sol',
                    'messages': history,
                  }, apiBase: CoachConfig.defaultBaseUrl)['input']
                  as List)
              .cast<Map>();
      final calls = input
          .where((item) => item['type'] == 'function_call')
          .toList();
      final results = input
          .where((item) => item['type'] == 'function_call_output')
          .toList();
      expect(calls, hasLength(14));
      expect(results, hasLength(calls.length));
      for (final result in results) {
        final call = calls.singleWhere(
          (candidate) => candidate['call_id'] == result['call_id'],
        );
        expect(input.indexOf(call), lessThan(input.indexOf(result)));
      }
      expect(input.where((item) => item['type'] == 'reasoning'), hasLength(14));
      expect(jsonEncode(saved), isNot(contains('rs_turn_0')));
      expect(jsonEncode(saved), isNot(contains('rs_turn_1"')));
    },
  );
}
