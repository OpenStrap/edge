import 'dart:convert';

/// Converts the Coach's canonical chat history to OpenAI Responses and back.
/// HTTP, tool execution, and persistence remain owned by CoachEngine.
/// https://developers.openai.com/api/docs/guides/migrate-to-responses
/// https://developers.openai.com/api/docs/guides/reasoning
class CoachResponses {
  static Map<String, dynamic> request(
    Map<String, dynamic> body, {
    required String apiBase,
  }) {
    final model = body['model'] as String? ?? '';
    final input = <Map<String, dynamic>>[];
    for (final message in _maps(body['messages'])) {
      final role = message['role'];
      if (role == 'assistant' &&
          message['_responses_model'] == model &&
          message['_responses_api_base'] == apiBase &&
          message['_responses_output'] is List) {
        // Replay this endpoint's full output in order, including opaque
        // reasoning and assistant phase. Other endpoints get canonical history.
        input.addAll(
          _maps(
            message['_responses_output'],
          ).map((item) => Map<String, dynamic>.from(item)),
        );
        continue;
      }
      if (role == 'tool') {
        input.add({
          'type': 'function_call_output',
          'call_id': message['tool_call_id'],
          'output': message['content'] ?? '',
        });
        continue;
      }
      if (role != 'user' &&
          role != 'assistant' &&
          role != 'system' &&
          role != 'developer') {
        throw const FormatException('Unsupported conversation role.');
      }
      final content = message['content'];
      if (role != 'assistant' ||
          (content is String && content.isNotEmpty) ||
          content is List) {
        input.add({'role': role, 'content': content ?? ''});
      }
      for (final call in _maps(message['tool_calls'] ?? const [])) {
        final function = call['function'];
        if (function is! Map) {
          throw const FormatException('Invalid function call in history.');
        }
        input.add({
          'type': 'function_call',
          'call_id': call['id'],
          'name': function['name'],
          'arguments': function['arguments'] is String
              ? function['arguments']
              : jsonEncode(function['arguments'] ?? {}),
        });
      }
    }
    // Sampling params (temperature/top_p) are deliberately not forwarded:
    // OpenAI reasoning models reject them on Responses, and the protocol is
    // never chosen from model names. Chat Completions keeps them.
    return {
      'model': model,
      'input': input,
      'store': false,
      'include': ['reasoning.encrypted_content'],
      if (body['tools'] != null)
        'tools': [for (final tool in _maps(body['tools'])) _functionTool(tool)],
      if (body['tool_choice'] != null) 'tool_choice': body['tool_choice'],
    };
  }

  static Map<String, dynamic> _functionTool(Map tool) {
    final function = tool['function'];
    if (tool['type'] != 'function' || function is! Map) {
      throw const FormatException('Only function tools are supported.');
    }
    return {
      'type': 'function',
      ...function.cast<String, dynamic>(),
      // Chat functions are non-strict. Keep optional fields and render's
      // open payload usable rather than normalizing them into strict schemas.
      'strict': function['strict'] ?? false,
    };
  }

  static Map<String, dynamic> reply(
    Map<String, dynamic> response,
    String model, {
    required String apiBase,
  }) {
    final status = response['status'];
    if ((status != null && status != 'completed') ||
        response['error'] != null) {
      throw const FormatException('Provider did not complete the response.');
    }
    final output = _maps(response['output']).toList();
    final text = <String>[];
    final calls = <Map<String, dynamic>>[];
    for (final item in output) {
      switch (item['type']) {
        case 'reasoning':
          break; // Opaque state is replayed, never rendered as an answer.
        case 'message':
          if (item['status'] != null && item['status'] != 'completed') {
            throw const FormatException(
              'Provider returned an incomplete message.',
            );
          }
          for (final content in _maps(item['content'])) {
            if (content['type'] == 'output_text' && content['text'] is String) {
              text.add(content['text'] as String);
            } else if (content['type'] == 'refusal' &&
                content['refusal'] is String) {
              text.add(content['refusal'] as String);
            } else {
              throw const FormatException(
                'Provider returned invalid message content.',
              );
            }
          }
          break;
        case 'function_call':
          if (item['call_id'] is! String ||
              (item['call_id'] as String).isEmpty ||
              item['name'] is! String ||
              (item['name'] as String).isEmpty ||
              item['arguments'] is! String ||
              (item['status'] != null && item['status'] != 'completed')) {
            throw const FormatException(
              'Provider returned an invalid function call.',
            );
          }
          calls.add({
            'id': item['call_id'],
            'type': 'function',
            'function': {'name': item['name'], 'arguments': item['arguments']},
          });
          break;
        default:
          throw const FormatException(
            'Provider returned an unsupported output item.',
          );
      }
    }
    if (text.every((part) => part.trim().isEmpty) && calls.isEmpty) {
      throw const FormatException('Empty response from provider.');
    }
    return {
      'role': 'assistant',
      'content': text.join('\n'),
      if (calls.isNotEmpty) 'tool_calls': calls,
      '_responses_output': output,
      '_responses_model': model,
      '_responses_api_base': apiBase,
    };
  }

  static Iterable<Map> _maps(Object? value) sync* {
    if (value is! List) {
      throw const FormatException('Provider returned an invalid list.');
    }
    for (final item in value) {
      if (item is! Map) {
        throw const FormatException('Provider returned an invalid item.');
      }
      yield item;
    }
  }
}
