// end_workout used to interpolate a missing workout_id as the string 'null'
// and report success for an id that matched no session.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';

class _FakeRepo extends LocalRepository {
  final Set<String> live = {'w1'};
  final List<String> ended = [];

  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) async {
    ended.add(workoutId);
    return {'workout_id': workoutId, 'ended': live.remove(workoutId)};
  }
}

class _ToolCallClient extends http.BaseClient {
  _ToolCallClient(this.args);
  final Map<String, dynamic> args;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    final Map<String, dynamic> message = calls == 1
        ? {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_1',
                'function': {'name': 'end_workout', 'arguments': jsonEncode(args)},
              }
            ],
          }
        : {'role': 'assistant', 'content': 'done'};
    final body = utf8.encode(jsonEncode({
      'choices': [
        {'message': message}
      ]
    }));
    return http.StreamedResponse(Stream.value(body), 200,
        headers: {'content-type': 'application/json'});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<String> run(Map<String, dynamic> args, _FakeRepo repo) async {
    final config = CoachConfig();
    await config.save(model: 'm', api: CoachApi.chatCompletions);
    final engine = CoachEngine(
        config: config, api: repo, client: _ToolCallClient(args));
    await engine.send('stop', onItem: (_) {}, onStatus: (_) {}, confirm: (_) async => true);
    return engine.debugHistory.firstWhere((m) => m['role'] == 'tool')['content'] as String;
  }

  test('a missing workout_id is rejected, never sent as "null"', () async {
    final repo = _FakeRepo();
    final out = await run(<String, dynamic>{}, repo);
    expect(repo.ended, isEmpty);
    expect(out, contains('needs the workout_id'));
  });

  test('an id that matches nothing is reported, not a success', () async {
    final repo = _FakeRepo();
    final out = await run({'workout_id': 'nope'}, repo);
    expect(out, contains('nothing was ended'));
  });

  test('a real id ends the workout', () async {
    final repo = _FakeRepo();
    final out = await run({'workout_id': 'w1'}, repo);
    expect(repo.live, isEmpty);
    expect(jsonDecode(out), {'workout_id': 'w1', 'ended': true});
  });
}
