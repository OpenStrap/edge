import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo extends LocalRepository {}

// Flutter's test binding replaces HttpClient; this override's base factory
// creates a real client. The transport below sends only to our loopback server.
class _RealHttpOverrides extends HttpOverrides {}

class _LoopbackClient extends http.BaseClient {
  _LoopbackClient(this.endpoint)
    : _inner = IOClient(_RealHttpOverrides().createHttpClient(null));

  final Uri endpoint;
  final http.Client _inner;
  final destinations = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    destinations.add(request.url);
    final local =
        http.Request(request.method, endpoint.replace(path: request.url.path))
          ..headers.addAll(request.headers)
          ..bodyBytes = await request.finalize().toBytes();
    return _inner.send(local);
  }

  @override
  void close() => _inner.close();
}

Map<String, dynamic> _message(String id, String text, String phase) => {
  'id': id,
  'type': 'message',
  'status': 'completed',
  'role': 'assistant',
  'phase': phase,
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': []},
  ],
};

bool _containsOnce(List<Map> input, String field, Object value, Map expected) {
  final matching = input.where((item) => item[field] == value).toList();
  return matching.length == 1 &&
      const DeepCollectionEquality().equals(matching.single, expected);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final model in ['gpt-6-luna', 'gpt-5.6-terra', 'gpt-6.1-sol']) {
    test('$model completes a real HTTP Responses tool round trip', () async {
      final requests = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final reasoning = {
        'id': 'rs_render_1',
        'type': 'reasoning',
        'summary': <dynamic>[],
        'encrypted_content': 'encrypted-render-reasoning',
      };
      final commentary = _message(
        'msg_commentary_1',
        'I will render the compatibility table.',
        'commentary',
      );
      final toolCall = {
        'id': 'fc_render_1',
        'type': 'function_call',
        'status': 'completed',
        'call_id': 'call_render_1',
        'name': 'render',
        'arguments': jsonEncode({
          'type': 'table',
          'title': 'Compatibility check',
          'columns': ['status'],
          'rows': [
            ['ok'],
          ],
        }),
      };
      final finalMessage = _message(
        'msg_final_1',
        'The compatibility check passed.',
        'final_answer',
      );
      final subscription = server.listen((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        requests.add(body);
        final input = (body['input'] as List?)?.cast<Map>() ?? <Map>[];
        final results = input
            .where((item) => item['type'] == 'function_call_output')
            .toList();
        final continuationValid =
            requests.length == 1 ||
            ((requests.length == 2 || requests.length == 3) &&
                _containsOnce(input, 'type', 'reasoning', reasoning) &&
                _containsOnce(input, 'type', 'function_call', toolCall) &&
                _containsOnce(input, 'id', 'msg_commentary_1', commentary) &&
                results.length == 1 &&
                results.single['call_id'] == 'call_render_1' &&
                results.single['output'] == 'Rendered "table" for the user.' &&
                (requests.length == 2
                    ? input.last['type'] == 'function_call_output'
                    : _containsOnce(input, 'id', 'msg_final_1', finalMessage) &&
                          input.last['role'] == 'user' &&
                          input.last['content'] ==
                              'What did that table show?'));
        final tools = (body['tools'] as List?)?.cast<Map>() ?? <Map>[];
        final valid =
            request.method == 'POST' &&
            request.uri.path == '/v1/responses' &&
            request.headers.contentType?.mimeType == 'application/json' &&
            body['model'] == model &&
            body['store'] == false &&
            (body['include'] as List?)?.contains(
                  'reasoning.encrypted_content',
                ) ==
                true &&
            !body.containsKey('messages') &&
            !body.containsKey('reasoning_effort') &&
            !body.containsKey('temperature') &&
            body['tool_choice'] == 'auto' &&
            tools.isNotEmpty &&
            tools.every(
              (tool) =>
                  tool['type'] == 'function' &&
                  tool['name'] is String &&
                  tool['parameters'] is Map &&
                  tool['strict'] == false &&
                  !tool.containsKey('function'),
            ) &&
            continuationValid;
        final output = requests.length == 1
            ? [reasoning, commentary, toolCall]
            : requests.length == 2
            ? [finalMessage]
            : [
                _message(
                  'msg_final_2',
                  'The table showed an ok status.',
                  'final_answer',
                ),
              ];
        request.response
          ..statusCode = valid ? 200 : 400
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(
              valid
                  ? {
                      'id': 'resp_${requests.length}',
                      'object': 'response',
                      'status': 'completed',
                      'output': output,
                    }
                  : {
                      'error': {
                        'message': 'Invalid request or Responses continuation',
                      },
                    },
            ),
          );
        await request.response.close();
      });
      addTearDown(subscription.cancel);

      final client = _LoopbackClient(
        Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final config = CoachConfig();
      await config.save(model: model);
      addTearDown(config.dispose);
      final engine = CoachEngine(
        config: config,
        api: _FakeRepo(),
        client: client,
      );
      addTearDown(engine.dispose);
      final items = <CoachItem>[];
      final statuses = <String?>[];
      Future<void> send(String text) => engine.send(
        text,
        onItem: items.add,
        onStatus: statuses.add,
        confirm: (_) async => fail('A render must not request a write'),
      );
      await send('Render a compatibility check table, then confirm it worked.');
      await send('What did that table show?');

      expect(requests, hasLength(3));
      expect(
        client.destinations,
        everyElement(Uri.parse('https://api.openai.com/v1/responses')),
      );
      final renderTool = (requests.first['tools'] as List)
          .cast<Map>()
          .singleWhere((tool) => tool['name'] == 'render');
      expect(renderTool['parameters']['required'], contains('type'));
      expect(items.map((item) => item.kind), [
        CoachItemKind.user,
        CoachItemKind.assistant,
        CoachItemKind.render,
        CoachItemKind.assistant,
        CoachItemKind.user,
        CoachItemKind.assistant,
      ]);
      expect(items[1].text, commentary['content'][0]['text']);
      expect(items[2].render?['title'], 'Compatibility check');
      expect(items[3].text, 'The compatibility check passed.');
      expect(items.last.text, 'The table showed an ok status.');
      expect(statuses.last, isNull);
      expect(engine.debugHistory.last['content'], items.last.text);
      expect(
        engine.debugHistory
            .where((message) => message['tool_calls'] != null)
            .single['tool_calls'][0]['id'],
        'call_render_1',
      );
    });
  }
}
