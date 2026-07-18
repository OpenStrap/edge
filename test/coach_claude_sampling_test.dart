// claudeRejectsSampling — which model ids get their OpenAI sampling params
// (temperature/top_p/top_k) stripped before the chat-completions POST.
//
// Recent Claude versions reject those params with a 400 (Opus >= 4.7,
// Sonnet/Haiku >= 5, Fable/Mythos); older Claude models and every non-Claude
// model must keep them. Claude is served under several provider namings
// (bare, OpenRouter "anthropic/…", Bedrock "anthropic.…-v1:0"), all of which
// must be recognized.

import 'package:test/test.dart';

import 'package:openstrap_edge/coach/coach_engine.dart';

void main() {
  group('claudeRejectsSampling — models that reject sampling params', () {
    const rejecting = [
      'claude-opus-4-7',
      'claude-opus-4-8',
      'claude-opus-4.8', // dotted separator
      'claude-opus-5', // future major
      'claude-sonnet-5',
      'claude-sonnet-5-20260203', // dated snapshot of a rejecting version
      'claude-haiku-5',
      'claude-fable-5',
      'claude-mythos-5',
      'anthropic/claude-opus-4.8', // OpenRouter naming
      'anthropic.claude-opus-4-8', // Bedrock-style naming
      'us.anthropic.claude-sonnet-5-v1:0', // Bedrock regional prefix
      'CLAUDE-OPUS-4-8', // case-insensitive
    ];
    for (final id in rejecting) {
      test(id, () => expect(CoachEngine.claudeRejectsSampling(id), isTrue));
    }
  });

  group('claudeRejectsSampling — models that keep sampling params', () {
    const accepting = [
      'claude-opus-4-6',
      'claude-opus-4-5',
      'claude-opus-4-20250514', // Opus 4.0 — date suffix is not a minor version
      'claude-sonnet-4-6',
      'claude-sonnet-4-5-20250929',
      'claude-haiku-4-5',
      'claude-3-5-sonnet-20241022', // legacy version-first ids
      'claude-3-opus-20240229',
      'anthropic/claude-sonnet-4.5', // OpenRouter naming, accepting version
      'gpt-4o', // non-Claude models are never touched
      'llama3.1:8b',
      'mistral-large-latest',
      '',
    ];
    for (final id in accepting) {
      test(id.isEmpty ? '(empty string)' : id,
          () => expect(CoachEngine.claudeRejectsSampling(id), isFalse));
    }
  });
}
