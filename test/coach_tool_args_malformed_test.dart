// A tool call whose `arguments` string does not parse must NOT run.
//
// `_send` used to swallow every parse failure into `args = {}` and call
// `_runTool` anyway. The confirmation the user then saw was built from the
// empty map, and on confirm the write ran with fabricated defaults:
// `start_workout` started `other`, `log_period` logged a period on today.
// A truncated arguments string is a normal failure from flaky
// OpenAI-compatible providers, so "no JSON" must mean "nothing ran".
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo extends LocalRepository {
  final cycleLogs = <String>[];

  @override
  Future<void> postCycleLog(
    String date, {
    String kind = 'start',
    String? note,
  }) async {
    cycleLogs.add('$date:$kind');
  }
}

/// Returns [replies] in order, then repeats the last one.
class _StubClient extends http.BaseClient {
  _StubClient(this.replies);
  final List<Map<String, dynamic>> replies;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final reply = replies[calls < replies.length ? calls : replies.length - 1];
    calls++;
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(reply))),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}

Map<String, dynamic> _toolReply(String arguments) => {
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {'name': 'log_period', 'arguments': arguments},
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> get _finalReply => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': 'Nothing was written.'},
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('truncated arguments are refused, not run as an empty object', () async {
    final repo = _FakeRepo();
    final config = CoachConfig();
    await config.save(
      api: CoachApi.chatCompletions,
      baseUrl: 'https://example.test/v1',
      model: 'test-model',
    );
    addTearDown(config.dispose);
    final engine = CoachEngine(
      config: config,
      api: repo,
      client: _StubClient([_toolReply('{"date":'), _finalReply]),
    );
    addTearDown(engine.dispose);
    final confirmed = <ActionRequest>[];
    await engine.send(
      'Log that my period started today.',
      onItem: (_) {},
      onStatus: (_) {},
      confirm: (request) async {
        confirmed.add(request);
        return true;
      },
    );
    expect(confirmed, isEmpty, reason: 'a broken argument map is not consent');
    expect(repo.cycleLogs, isEmpty, reason: 'nothing may be written');
    final tool = engine.debugHistory.singleWhere((m) => m['role'] == 'tool');
    expect('${tool['content']}', contains('JSON'));
  });

  test('valid empty arguments still run the tool', () async {
    final repo = _FakeRepo();
    final config = CoachConfig();
    await config.save(
      api: CoachApi.chatCompletions,
      baseUrl: 'https://example.test/v1',
      model: 'test-model',
    );
    addTearDown(config.dispose);
    final engine = CoachEngine(
      config: config,
      api: repo,
      client: _StubClient([_toolReply('{}'), _finalReply]),
    );
    addTearDown(engine.dispose);
    final confirmed = <ActionRequest>[];
    await engine.send(
      'Log that my period started today.',
      onItem: (_) {},
      onStatus: (_) {},
      confirm: (request) async {
        confirmed.add(request);
        return true;
      },
    );
    expect(confirmed, hasLength(1));
    expect(repo.cycleLogs, hasLength(1));
  });
}
