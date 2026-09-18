// log_journal / log_period were the only two date-taking coach tools
// implemented inline in CoachEngine._runTool, and the only two that skipped
// CoachActions.day() — every sibling tool (log_food, log_journal_fields,
// add_completed_workout, mark_medication) already routes through it. A model
// sending a missing or relative date ("today", "yesterday") interpolated
// straight into the write, silently keying a journal/cycle_log row under a
// string nothing else can ever read back (CoachActions.day's own doc comment
// names this exact failure mode).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';

class _FakeRepo extends LocalRepository {
  String? journalDate;
  String? cycleDate;

  @override
  Future<void> postJournal(String date, List<String> tags, String note) async {
    journalDate = date;
  }

  @override
  Future<void> postCycleLog(String date, {String kind = 'start', String? note}) async {
    cycleDate = date;
  }
}

/// Replies once with a single tool call, then a plain assistant message so
/// the loop terminates.
class _ToolCallClient extends http.BaseClient {
  _ToolCallClient(this.toolName, this.args);
  final String toolName;
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
                'function': {'name': toolName, 'arguments': jsonEncode(args)},
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

  Future<CoachEngine> run(String tool, Map<String, dynamic> args, _FakeRepo repo) async {
    final engine = CoachEngine(
      config: CoachConfig()..save(model: 'm'),
      api: repo,
      client: _ToolCallClient(tool, args),
    );
    await engine.send('log it', onItem: (_) {}, onStatus: (_) {}, confirm: (_) async => true);
    return engine;
  }

  group('log_journal', () {
    test('a well-formed date is written verbatim', () async {
      final repo = _FakeRepo();
      await run('log_journal', {'date': '2026-08-14', 'note': 'x'}, repo);
      expect(repo.journalDate, '2026-08-14');
    });

    test('a missing date defaults to today, not the literal "null"', () async {
      final repo = _FakeRepo();
      await run('log_journal', {'note': 'x'}, repo);
      expect(repo.journalDate, isNotNull);
      expect(repo.journalDate, isNot('null'));
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(repo.journalDate!), isTrue);
    });

    test('a relative date is rejected, never written', () async {
      final repo = _FakeRepo();
      final engine = await run('log_journal', {'date': 'yesterday', 'note': 'x'}, repo);
      expect(repo.journalDate, isNull);
      final toolResult = engine.debugHistory.firstWhere((m) => m['role'] == 'tool');
      expect(toolResult['content'], contains('is not a day'));
    });
  });

  group('log_period', () {
    test('a well-formed date is written verbatim', () async {
      final repo = _FakeRepo();
      await run('log_period', {'date': '2026-08-14'}, repo);
      expect(repo.cycleDate, '2026-08-14');
    });

    test('a missing date defaults to today, not the literal "null"', () async {
      final repo = _FakeRepo();
      await run('log_period', <String, dynamic>{}, repo);
      expect(repo.cycleDate, isNotNull);
      expect(repo.cycleDate, isNot('null'));
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(repo.cycleDate!), isTrue);
    });

    test('a relative date is rejected, never written', () async {
      final repo = _FakeRepo();
      final engine = await run('log_period', {'date': 'today'}, repo);
      expect(repo.cycleDate, isNull);
      final toolResult = engine.debugHistory.firstWhere((m) => m['role'] == 'tool');
      expect(toolResult['content'], contains('is not a day'));
    });
  });
}
