import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_responses.dart';

const _apiBase = 'https://api.openai.com/v1';

Map<String, dynamic> _request(
  Map<String, dynamic> body, {
  String apiBase = _apiBase,
}) => CoachResponses.request(body, apiBase: apiBase);

Map<String, dynamic> _reply(
  Map<String, dynamic> response,
  String model, {
  String apiBase = _apiBase,
}) => CoachResponses.reply(response, model, apiBase: apiBase);

Map<String, dynamic> _message(String id, String text) => {
  'id': id,
  'type': 'message',
  'status': 'completed',
  'role': 'assistant',
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': []},
  ],
};

Map<String, dynamic> _call(String id, String callId, String name) => {
  'id': id,
  'type': 'function_call',
  'status': 'completed',
  'call_id': callId,
  'name': name,
  'arguments': '{"date":"2026-10-04"}',
};

Map<String, dynamic> _response(List<dynamic> output) => {
  'id': 'resp_test',
  'object': 'response',
  'status': 'completed',
  'output': output,
};

void main() {
  group('Responses request conversion', () {
    test('retains message order and optional tool schema fields', () {
      final body = <String, dynamic>{
        'model': 'gpt-6.1-sol',
        'messages': [
          {'role': 'system', 'content': 'Answer from observed data.'},
          {'role': 'user', 'content': 'Read my day.'},
          {
            'role': 'assistant',
            'content': 'I will look that up.',
            'tool_calls': [
              {
                'id': 'call_day',
                'type': 'function',
                'function': {
                  'name': 'lookup',
                  'arguments': '{"date":"2026-10-04"}',
                },
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'call_day',
            'content': '{"steps":100}',
          },
        ],
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': 'lookup',
              'description': 'Read a day',
              'parameters': {
                'type': 'object',
                'properties': {
                  'date': {'type': 'string'},
                  'units': {'type': 'string'},
                },
                'required': ['date'],
              },
            },
          },
        ],
        'tool_choice': 'auto',
        'temperature': 0.3,
      };
      final original = jsonDecode(jsonEncode(body));
      final request = _request(body);
      expect(request['input'], [
        {'role': 'system', 'content': 'Answer from observed data.'},
        {'role': 'user', 'content': 'Read my day.'},
        {'role': 'assistant', 'content': 'I will look that up.'},
        {
          'type': 'function_call',
          'call_id': 'call_day',
          'name': 'lookup',
          'arguments': '{"date":"2026-10-04"}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'call_day',
          'output': '{"steps":100}',
        },
      ]);
      final tool = (request['tools'] as List).single as Map;
      expect(tool['strict'], isFalse);
      expect(tool['parameters'], body['tools'][0]['function']['parameters']);
      expect(tool['parameters']['required'], ['date']);
      expect(tool, isNot(contains('function')));
      expect(body, original);
    });

    test(
      'uses provider-default reasoning and omits sampling without mutation',
      () {
        final body = <String, dynamic>{
          'model': 'gpt-6.1-sol',
          'messages': [
            {'role': 'user', 'content': 'Hello'},
          ],
          'temperature': 0.3,
        };
        final before = jsonDecode(jsonEncode(body));
        expect(_request(body), {
          'model': 'gpt-6.1-sol',
          'input': body['messages'],
          'store': false,
          'include': ['reasoning.encrypted_content'],
        });
        expect(body, before);
      },
    );

    test(
      'replays encrypted reasoning and interleaved output in original order',
      () {
        final reasoning = {
          'id': 'rs_day',
          'type': 'reasoning',
          'summary': <dynamic>[],
          'encrypted_content': 'opaque-encrypted-reasoning',
        };
        final commentary = _message('msg_before', 'Reading the first value.');
        final first = _call('fc_first', 'call_first', 'get_nutrition');
        final between = _message('msg_between', 'Reading the second value.');
        final second = _call('fc_second', 'call_second', 'get_medications');
        final output = [reasoning, commentary, first, between, second];
        final assistant = _reply(_response(output), 'gpt-6.1-sol');
        final body = <String, dynamic>{
          'model': 'gpt-6.1-sol',
          'messages': [
            {'role': 'user', 'content': 'Read two values'},
            assistant,
            {
              'role': 'tool',
              'tool_call_id': 'call_second',
              'content': 'second result',
            },
            {
              'role': 'tool',
              'tool_call_id': 'call_first',
              'content': 'first result',
            },
          ],
        };
        final original = jsonDecode(jsonEncode(body));
        final request = _request(body);
        expect(request['input'], [
          {'role': 'user', 'content': 'Read two values'},
          ...output,
          {
            'type': 'function_call_output',
            'call_id': 'call_second',
            'output': 'second result',
          },
          {
            'type': 'function_call_output',
            'call_id': 'call_first',
            'output': 'first result',
          },
        ]);
        expect(body, original);
        final calls = (assistant['tool_calls'] as List).cast<Map>();
        expect(calls.map((call) => call['id']), ['call_first', 'call_second']);
        expect(calls.first['function']['name'], 'get_nutrition');
      },
    );

    for (final provenance in [
      'another model',
      'another endpoint',
      'missing endpoint',
    ]) {
      test('$provenance reconstructs canonical calls and results', () {
        const model = 'gpt-6-luna';
        final assistant = _reply(
          _response([
            {
              'id': 'rs_source',
              'type': 'reasoning',
              'summary': <dynamic>[],
              'encrypted_content': 'opaque-source-provider-state',
            },
            _message('msg_source', 'Reading your day.'),
            _call('fc_source', 'call_shared', 'lookup'),
          ]),
          model,
        );
        if (provenance == 'missing endpoint') {
          assistant.remove('_responses_api_base');
        }
        final body = <String, dynamic>{
          'model': provenance == 'another model' ? 'gpt-6.1-sol' : model,
          'messages': [
            assistant,
            {
              'role': 'tool',
              'tool_call_id': 'call_shared',
              'content': 'day result',
            },
          ],
        };
        final before = jsonDecode(jsonEncode(body));
        final request = _request(
          body,
          apiBase: provenance == 'another endpoint'
              ? 'https://other-provider.example/v1'
              : _apiBase,
        );
        expect(request['input'], [
          {'role': 'assistant', 'content': 'Reading your day.'},
          {
            'type': 'function_call',
            'call_id': 'call_shared',
            'name': 'lookup',
            'arguments': '{"date":"2026-10-04"}',
          },
          {
            'type': 'function_call_output',
            'call_id': 'call_shared',
            'output': 'day result',
          },
        ]);
        for (final privateValue in [
          'opaque-source-provider-state',
          'rs_source',
          'msg_source',
          'fc_source',
          '_responses_api_base',
        ]) {
          expect(jsonEncode(request), isNot(contains(privateValue)));
        }
        expect(body, before);
      });
    }
  });

  group('Responses reply normalization', () {
    test('normalizes text and keeps private output provenance', () {
      final output = [_message('msg_answer', 'Observed steps: 100.')];
      final reply = _reply(_response(output), 'gpt-6.1-sol');
      expect(reply['role'], 'assistant');
      expect(reply['content'], 'Observed steps: 100.');
      expect(reply['_responses_output'], output);
      expect(reply['_responses_model'], 'gpt-6.1-sol');
      expect(reply['_responses_api_base'], _apiBase);
    });

    test('tool-only reply maps call_id rather than the output item id', () {
      final output = [_call('fc_item', 'call_execution', 'lookup')];
      final reply = _reply(_response(output), 'gpt-6.1-sol');
      expect(reply['content'], anyOf(isNull, isEmpty));
      expect(reply['tool_calls'], [
        {
          'id': 'call_execution',
          'type': 'function',
          'function': {'name': 'lookup', 'arguments': '{"date":"2026-10-04"}'},
        },
      ]);
    });

    test('surfaces refusal text to the existing Coach UI', () {
      final reply = _reply(
        _response([
          {
            'id': 'msg_refusal',
            'type': 'message',
            'status': 'completed',
            'role': 'assistant',
            'content': [
              {'type': 'refusal', 'refusal': 'I cannot answer that request.'},
            ],
          },
        ]),
        'gpt-6.1-sol',
      );
      expect(reply['content'], 'I cannot answer that request.');
    });

    final invalidResponses = <String, Map<String, dynamic>>{
      'failed even with apparent text': {
        'status': 'failed',
        'error': {'message': 'Provider generation failed'},
        'output': [_message('msg_failed', 'Partial text')],
      },
      'incomplete even with apparent text': {
        'status': 'incomplete',
        'incomplete_details': {'reason': 'max_output_tokens'},
        'output': [_message('msg_partial', 'Partial text')],
      },
      'missing output': {'status': 'completed'},
      'output is not a list': {'status': 'completed', 'output': 'text'},
      'empty output': _response([]),
      'reasoning without an answer or a tool call': _response([
        {'id': 'rs_only', 'type': 'reasoning', 'summary': <dynamic>[]},
      ]),
      'output item is not an object': _response(['text']),
      'unknown output type': _response([
        {'type': 'unknown', 'text': 'text'},
      ]),
      'message content is not a list': _response([
        {'type': 'message', 'role': 'assistant', 'content': 'text'},
      ]),
      'message content item is not an object': _response([
        {
          'type': 'message',
          'role': 'assistant',
          'content': ['text'],
        },
      ]),
      'output text is not a string': _response([
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 123},
          ],
        },
      ]),
      'malformed text alongside a valid tool call': _response([
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 123},
          ],
        },
        _call('fc_valid', 'call_valid', 'lookup'),
      ]),
      'function call has no call id': _response([
        {'type': 'function_call', 'name': 'lookup', 'arguments': '{}'},
      ]),
      'function call has no name': _response([
        {'type': 'function_call', 'call_id': 'call_bad', 'arguments': '{}'},
      ]),
      'function call arguments are not a string': _response([
        {
          'type': 'function_call',
          'call_id': 'call_bad',
          'name': 'lookup',
          'arguments': <String, dynamic>{},
        },
      ]),
    };
    for (final entry in invalidResponses.entries) {
      test('rejects ${entry.key}', () {
        expect(
          () => _reply(entry.value, 'gpt-6.1-sol'),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });
}
