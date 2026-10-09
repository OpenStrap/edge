/// Converts the Coach's canonical history to Chat Completions and back.
/// HTTP, tool execution, and persistence remain owned by CoachEngine.
class CoachChatCompletions {
  static Map<String, dynamic> request(Map<String, dynamic> body) {
    final messages = body['messages'];
    if (messages is! List || messages.any((message) => message is! Map)) {
      throw const FormatException('Invalid conversation messages.');
    }
    return {
      ...body,
      'messages': [
        for (final message in messages)
          Map<String, dynamic>.from(message as Map)
            ..remove('_responses_output')
            ..remove('_responses_model')
            ..remove('_responses_api_base'),
      ],
    };
  }

  static Map<String, dynamic> reply(Map<String, dynamic> response) {
    final choices = response['choices'];
    if (choices == null || (choices is List && choices.isEmpty)) {
      throw const FormatException('Empty response from provider.');
    }
    if (choices is! List || choices.first is! Map) {
      throw const FormatException('Unexpected response from provider.');
    }
    // Compatible proxies also return delta chunks and legacy text choices.
    final first = choices.first as Map;
    final message = first['message'] ?? first['delta'];
    if (message is Map) return message.cast<String, dynamic>();
    final text = first['text'];
    if (text is String) return {'content': text};
    throw const FormatException(
      'Provider returned an unsupported response shape (no message/delta). '
      'Streaming-only endpoints are not supported — use a standard '
      'OpenAI-compatible /chat/completions endpoint.',
    );
  }
}
