// A tool call whose `arguments` do not decode to an object must NOT run.
//
// `_send` used to swallow every parse failure into `args = {}` and call
// `_runTool` anyway. The confirmation was then built from the empty map, and on
// confirm the write ran with fabricated defaults: `start_workout` started
// `other`, `log_period` logged a period on today. Empty, missing and non-object
// arguments are normal provider failures, so "not an object" must mean
// "nothing ran". A valid `{}` is still a real no-argument call.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo extends LocalRepository {
  final cycleLogs = <String>[];
  var todayRead = false;

  @override
  Future<void> postCycleLog(
    String date, {
    String kind = 'start',
    String? note,
  }) async {
    cycleLogs.add('$date:$kind');
  }

  @override
  Future<Map<String, dynamic>> getToday() async {
    todayRead = true;
    return {'day': '2026-01-01'};
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

/// Omits the `arguments` key entirely, the "missing" shape.
const Object _missingArguments = Object();

Map<String, dynamic> _toolReply(String tool, Object? arguments) => {
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {
              'name': tool,
              if (!identical(arguments, _missingArguments))
                'arguments': arguments,
            },
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

Future<({_FakeRepo repo, CoachEngine engine, List<ActionRequest> confirmed})>
_run(String tool, Object? arguments) async {
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
    client: _StubClient([_toolReply(tool, arguments), _finalReply]),
  );
  addTearDown(engine.dispose);
  final confirmed = <ActionRequest>[];
  await engine.send(
    'Do that thing.',
    onItem: (_) {},
    onStatus: (_) {},
    confirm: (request) async {
      confirmed.add(request);
      return true;
    },
  );
  return (repo: repo, engine: engine, confirmed: confirmed);
}

void expectRefused(
  ({_FakeRepo repo, CoachEngine engine, List<ActionRequest> confirmed}) r,
) {
  expect(r.confirmed, isEmpty, reason: 'a broken argument map is not consent');
  expect(r.repo.cycleLogs, isEmpty, reason: 'nothing may be written');
  final tool = r.engine.debugHistory.singleWhere((m) => m['role'] == 'tool');
  expect('${tool['content']}', contains('JSON'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('truncated arguments are refused, not run as an empty object', () async {
    expectRefused(await _run('log_period', '{"date":'));
  });

  test('an empty arguments string is refused', () async {
    expectRefused(await _run('log_period', ''));
  });

  test('missing arguments are refused', () async {
    expectRefused(await _run('log_period', _missingArguments));
  });

  test('null arguments are refused', () async {
    expectRefused(await _run('log_period', null));
  });

  test('non-object JSON arguments are refused', () async {
    expectRefused(await _run('log_period', '[1,2]'));
    expectRefused(await _run('log_period', '123'));
    expectRefused(await _run('log_period', 123));
  });

  test('a read tool that asks for nothing still runs when the provider sends no arguments', () async {
    final r = await _run('get_today', '');
    expect(r.repo.todayRead, isTrue);
  });

  test('...and when the arguments key is missing altogether', () async {
    final r = await _run('get_today', _missingArguments);
    expect(r.repo.todayRead, isTrue);
  });

  test('a read tool is still refused when its arguments are malformed text', () async {
    final r = await _run('get_today', '{"date":');
    expect(r.repo.todayRead, isFalse);
    final tool = r.engine.debugHistory.singleWhere((m) => m['role'] == 'tool');
    expect('${tool['content']}', contains('JSON'));
  });

  test('valid empty string arguments still run the tool', () async {
    final r = await _run('log_period', '{}');
    expect(r.confirmed, hasLength(1));
    expect(r.repo.cycleLogs, hasLength(1));
  });

  test('valid empty map arguments still run the tool', () async {
    final r = await _run('log_period', <String, dynamic>{});
    expect(r.confirmed, hasLength(1));
    expect(r.repo.cycleLogs, hasLength(1));
  });
}
