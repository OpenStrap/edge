import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/coach/coach_responses.dart';

Map<String, dynamic> _body(String model, {bool tools = true}) => {
  'model': model,
  'messages': [
    {'role': 'user', 'content': 'Hello'},
  ],
  'temperature': 0.3,
  if (tools) ...{
    'tools': [
      {
        'type': 'function',
        'function': {
          'name': 'lookup',
          'description': 'Read a value',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
    ],
    'tool_choice': 'auto',
  },
};

Map<String, dynamic> _responsesReply() => {
  'id': 'resp_hello',
  'object': 'response',
  'status': 'completed',
  'output': [
    {
      'id': 'msg_hello',
      'type': 'message',
      'status': 'completed',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': 'Hello back', 'annotations': []},
      ],
    },
  ],
};

/// Inspect the serialized HTTP request, endpoint, and normalized reply.
Future<Map<String, dynamic>> _capture(
  CoachConfig config,
  Map<String, dynamic> body, {
  required bool responses,
}) async {
  Map<String, dynamic>? sent;
  final client = MockClient((request) async {
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      '${config.apiBase}/${responses ? 'responses' : 'chat/completions'}',
    );
    expect(request.headers.containsKey('authorization'), isFalse);
    sent = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode(
        responses
            ? _responsesReply()
            : {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'Hello back'},
                  },
                ],
              },
      ),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  try {
    final reply = await CoachEngine.postChat(config, body, client: client);
    expect(reply['content'], 'Hello back');
    if (responses) {
      expect(reply['_responses_output'], _responsesReply()['output']);
      expect(reply['_responses_model'], body['model']);
      expect(reply['_responses_api_base'], config.apiBase);
    }
    return sent!;
  } finally {
    client.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('official OpenAI Responses requests regardless of model naming', () {
    for (final model in [
      'gpt-5.6-terra',
      'gpt-6-luna',
      'gpt-6.1-sol',
      'opaque-model-id',
      'gpt-4o-mini',
    ]) {
      for (final tools in [true, false]) {
        test(
          '$model uses Responses ${tools ? 'with tools' : 'for text only'}',
          () async {
            final body = _body(model, tools: tools);
            final sent = await _capture(CoachConfig(), body, responses: true);
            expect(sent['model'], model);
            expect(sent['input'], body['messages']);
            expect(sent['store'], isFalse);
            expect(sent['include'], contains('reasoning.encrypted_content'));
            expect(sent, isNot(contains('messages')));
            expect(sent, isNot(contains('temperature')));
            expect(sent, isNot(contains('reasoning_effort')));
            expect(sent, isNot(contains('reasoning')));
            if (tools) {
              expect(sent['tool_choice'], 'auto');
              expect(sent['tools'], [
                {
                  'type': 'function',
                  'name': 'lookup',
                  'description': 'Read a value',
                  'parameters': {'type': 'object', 'properties': {}},
                  'strict': false,
                },
              ]);
            } else {
              expect(sent, isNot(contains('tools')));
            }
          },
        );
      }
    }

    test(
      'uses provider-default reasoning and omits sampling without mutation',
      () async {
        final body = _body('gpt-6.1-sol')
          ..['top_p'] = 0.9
          ..['top_k'] = 10
          ..['logprobs'] = true
          ..['top_logprobs'] = 3;
        final original = jsonDecode(jsonEncode(body));
        final sent = await _capture(CoachConfig(), body, responses: true);
        expect(sent, isNot(contains('reasoning')));
        for (final key in [
          'reasoning_effort',
          'temperature',
          'top_p',
          'top_k',
          'logprobs',
          'top_logprobs',
        ]) {
          expect(sent, isNot(contains(key)));
        }
        expect(body, original);
      },
    );

    test('normalizes a trailing slash on the official API base', () async {
      final config = CoachConfig();
      addTearDown(config.dispose);
      await config.save(baseUrl: 'https://api.openai.com/v1/');
      final sent = await _capture(
        config,
        _body('gpt-6.1-sol'),
        responses: true,
      );
      expect(sent['store'], isFalse);
    });

    test('Responses errors use the existing CoachException contract', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': 'incomplete',
            'incomplete_details': {'reason': 'max_output_tokens'},
            'output': _responsesReply()['output'],
          }),
          200,
        ),
      );
      addTearDown(client.close);
      await expectLater(
        CoachEngine.postChat(
          CoachConfig(),
          _body('gpt-6.1-sol'),
          client: client,
        ),
        throwsA(isA<CoachException>()),
      );
    });

    test(
      'refuses oversized encrypted history before contacting OpenAI',
      () async {
        var contacted = false;
        final client = MockClient((_) async {
          contacted = true;
          return http.Response(jsonEncode(_responsesReply()), 200);
        });
        addTearDown(client.close);
        final assistant = CoachResponses.reply(
          {
            'status': 'completed',
            'output': [
              {
                'id': 'rs_large',
                'type': 'reasoning',
                'summary': <dynamic>[],
                'encrypted_content':
                    'x' * (CoachEngine.kMaxRequestBytes + 1024),
              },
              ...(_responsesReply()['output'] as List),
            ],
          },
          'gpt-6.1-sol',
          apiBase: CoachConfig.defaultBaseUrl,
        );
        await expectLater(
          CoachEngine.postChat(CoachConfig(), {
            'model': 'gpt-6.1-sol',
            'messages': [
              assistant,
              {'role': 'user', 'content': 'Continue'},
            ],
          }, client: client),
          throwsA(isA<CoachException>()),
        );
        expect(contacted, isFalse);
      },
    );
  });

  test('request ceiling counts outgoing UTF-8 bytes', () async {
    var contacted = false;
    final client = MockClient((_) async {
      contacted = true;
      return http.Response(jsonEncode(_responsesReply()), 200);
    });
    addTearDown(client.close);
    final body = _body('gpt-6.1-sol', tools: false);
    body['messages'] = [
      {
        'role': 'user',
        'content': 'é' * (CoachEngine.kMaxRequestBytes ~/ 2 + 1024),
      },
    ];
    expect(jsonEncode(body).length, lessThan(CoachEngine.kMaxRequestBytes));
    await expectLater(
      CoachEngine.postChat(CoachConfig(), body, client: client),
      throwsA(isA<CoachException>()),
    );
    expect(contacted, isFalse);
  });

  group('explicit OpenAI Chat Completions override', () {
    for (final model in [
      'gpt-3.5-turbo',
      'gpt-4o-mini',
      'o1-mini',
      'o1-preview',
      'opaque-model-id',
    ]) {
      test('$model retains Chat Completions and sampling', () async {
        final config = CoachConfig();
        addTearDown(config.dispose);
        await config.save(api: CoachApi.chatCompletions);
        final body = _body(model);
        expect(await _capture(config, body, responses: false), body);
      });
    }
  });

  group('explicit Responses on a custom provider', () {
    for (final base in [
      'http://localhost:11434/v1',
      'https://openrouter.ai/api/v1',
    ]) {
      test('$base uses Responses without classifying the model ID', () async {
        final config = CoachConfig();
        addTearDown(config.dispose);
        await config.save(baseUrl: base, api: CoachApi.responses);
        final body = _body('provider/arbitrary-model-id');
        final before = jsonDecode(jsonEncode(body));
        final sent = await _capture(config, body, responses: true);
        expect(sent['model'], 'provider/arbitrary-model-id');
        expect(sent['input'], body['messages']);
        expect(sent['store'], isFalse);
        expect(sent, isNot(contains('reasoning_effort')));
        expect(sent, isNot(contains('temperature')));
        expect(body, before);
      });
    }
  });

  test(
    'same model switches Responses providers in flight without replaying opaque state',
    () async {
      const model = 'same-model-on-two-providers';
      const destination = 'https://another-responses-provider.example/v1';
      final output = [
        {
          'id': 'rs_endpoint_a',
          'type': 'reasoning',
          'summary': <dynamic>[],
          'encrypted_content': 'encrypted-for-endpoint-a-only',
        },
        {
          'id': 'msg_endpoint_a',
          'type': 'message',
          'status': 'completed',
          'role': 'assistant',
          'content': [
            {
              'type': 'output_text',
              'text': 'Reading your day.',
              'annotations': [],
            },
          ],
        },
        {
          'id': 'fc_endpoint_a',
          'type': 'function_call',
          'status': 'completed',
          'call_id': 'call_lookup',
          'name': 'lookup',
          'arguments': '{}',
        },
      ];
      final config = CoachConfig();
      addTearDown(config.dispose);
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) {
          await config.save(baseUrl: destination, api: CoachApi.responses);
        }
        return http.Response(
          jsonEncode(
            requests.length == 1
                ? {'status': 'completed', 'output': output}
                : _responsesReply(),
          ),
          200,
        );
      });
      addTearDown(client.close);
      final reply = await CoachEngine.postChat(
        config,
        _body(model),
        client: client,
      );
      expect(reply['_responses_api_base'], CoachConfig.defaultBaseUrl);
      expect(config.apiBase, destination);
      final body = {
        'model': model,
        'messages': [
          reply,
          {
            'role': 'tool',
            'tool_call_id': 'call_lookup',
            'content': 'observed data',
          },
          {'role': 'user', 'content': 'Continue'},
        ],
      };
      final before = jsonDecode(jsonEncode(body));
      final finalReply = await CoachEngine.postChat(
        config,
        body,
        client: client,
      );
      expect(finalReply['content'], 'Hello back');
      expect(finalReply['_responses_api_base'], destination);
      expect(requests.map((request) => request.url.toString()), [
        '${CoachConfig.defaultBaseUrl}/responses',
        '$destination/responses',
      ]);
      final sent = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(sent['input'], [
        {'role': 'assistant', 'content': 'Reading your day.'},
        {
          'type': 'function_call',
          'call_id': 'call_lookup',
          'name': 'lookup',
          'arguments': '{}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'call_lookup',
          'output': 'observed data',
        },
        {'role': 'user', 'content': 'Continue'},
      ]);
      for (final privateValue in [
        'encrypted-for-endpoint-a-only',
        'rs_endpoint_a',
        'msg_endpoint_a',
        'fc_endpoint_a',
        '_responses_api_base',
      ]) {
        expect(requests.last.body, isNot(contains(privateValue)));
      }
      expect(body, before);
    },
  );

  group('unaffected provider requests', () {
    for (final base in [
      'https://openrouter.ai/api/v1',
      'http://localhost:11434/v1',
      'http://192.168.1.2:1234/v1',
      'https://api.openai.com.example.com/v1',
      'https://evil-api.openai.com/v1',
      'https://proxy.api.openai.com/v1',
      'http://api.openai.com/v1',
      'https://api.openai.com:8443/v1',
    ]) {
      test('$base retains reasoning-model Chat Completions requests', () async {
        final config = CoachConfig();
        addTearDown(config.dispose);
        await config.save(baseUrl: base);
        for (final model in ['gpt-6-luna', 'gpt-5.6-terra', 'gpt-6.1-sol']) {
          final body = _body(model)..['reasoning_effort'] = 'medium';
          expect(await _capture(config, body, responses: false), body);
        }
      });
    }

    for (final base in [
      'https://openrouter.ai/api/v1',
      'https://api.openai.com/v1',
    ]) {
      test(
        '$base strips private Responses metadata from Chat history',
        () async {
          final config = CoachConfig();
          addTearDown(config.dispose);
          await config.save(baseUrl: base, api: CoachApi.chatCompletions);
          final assistant = CoachResponses.reply(
            _responsesReply(),
            'gpt-6.1-sol',
            apiBase: CoachConfig.defaultBaseUrl,
          );
          final body = {
            'model': 'gpt-4o-mini',
            'messages': [
              assistant,
              {'role': 'user', 'content': 'Continue'},
            ],
            'temperature': 0.3,
          };
          final before = jsonDecode(jsonEncode(body));
          final sent = await _capture(config, body, responses: false);
          expect(sent['messages'], [
            {'role': 'assistant', 'content': 'Hello back'},
            {'role': 'user', 'content': 'Continue'},
          ]);
          expect(body, before);
        },
      );
    }

    test(
      'existing Claude sampling removal still reaches the request',
      () async {
        final config = CoachConfig();
        addTearDown(config.dispose);
        await config.save(baseUrl: 'https://openrouter.ai/api/v1');
        final body = _body('anthropic/claude-opus-4.8')
          ..['top_p'] = 0.9
          ..['top_k'] = 10;
        final expected = {...body}
          ..remove('temperature')
          ..remove('top_p')
          ..remove('top_k');
        expect(await _capture(config, body, responses: false), expected);
        expect(body['temperature'], 0.3);
        expect(body['top_p'], 0.9);
        expect(body['top_k'], 10);
      },
    );
  });
}
