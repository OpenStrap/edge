// Apple's on-device model as an AI provider (coach, briefings, journal).
//
// Every AI request in the app goes through `CoachEngine.postChat`; when the
// user picks "Apple on-device" it lands here instead of on the network. The
// model is small and reads only a few thousand tokens, so:
//
// * the coach's long tool-driven prompt (run_sql over the derived views) is
//   swapped for a short one plus a snapshot of the last two weeks, read
//   here with the same guarded read-only SQL the coach tool uses — the model
//   answers from that, it cannot query on its own;
// * briefing and journal prompts (already self-contained) go through as they
//   are, trimmed to fit;
// * replies are plain text: no tool calls, no actions.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'coach_db.dart';

enum AppleAiStatus {
  available,
  notEnabled,
  notReady,
  deviceNotEligible,
  unsupported;

  static AppleAiStatus parse(String? s) => switch (s) {
        'available' => available,
        'notEnabled' => notEnabled,
        'notReady' => notReady,
        'deviceNotEligible' => deviceNotEligible,
        _ => unsupported,
      };

  /// What the settings screen says about it.
  String get message => switch (this) {
        available => 'Ready. Runs on this iPhone; nothing leaves it.',
        notEnabled =>
          'Turn on Apple Intelligence in Settings to use the on-device model.',
        notReady =>
          'Apple’s on-device model is still downloading. Try again later.',
        deviceNotEligible => 'This iPhone can’t run Apple’s on-device model.',
        unsupported =>
          'Needs an iPhone with Apple Intelligence on iOS 26 or later.',
      };
}

class AppleOnDevice {
  AppleOnDevice._();

  static const _ch = MethodChannel('openstrap/apple_ai');

  /// Budgets in characters (≈3.5 per token): the model's window holds the
  /// instructions, the prompt AND its answer.
  static const int instructionBudget = 3200;
  static const int promptBudget = 4200;

  static Future<AppleAiStatus> status() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return AppleAiStatus.unsupported;
    }
    try {
      return AppleAiStatus.parse(await _ch.invokeMethod<String>('status'));
    } catch (_) {
      return AppleAiStatus.unsupported;
    }
  }

  /// One chat turn: `body` is the chat-completions-style request the engine
  /// builds. Returns the normalized assistant message (`{'content': text}`).
  /// Throws a [StateError] whose message is user-facing.
  static Future<Map<String, dynamic>> reply(Map<String, dynamic> body) async {
    final messages = [
      for (final m in (body['messages'] as List? ?? const []))
        if (m is Map) m.cast<String, dynamic>(),
    ];
    final isCoach = body['tools'] is List && (body['tools'] as List).isNotEmpty;
    final instructions = isCoach
        ? '$kAppleCoachInstructions\n\n${await _snapshot()}'
        : _clip(
            messages
                .where((m) => m['role'] == 'system')
                .map((m) => _text(m['content']))
                .join('\n\n'),
            instructionBudget,
            keepEnd: false);
    final prompt = buildPrompt(messages);
    final temperature = (body['temperature'] as num?)?.toDouble();
    try {
      final text = await _ch.invokeMethod<String>('respond', {
        'instructions': _clip(instructions, instructionBudget + 2600,
            keepEnd: false),
        'prompt': prompt,
        'temperature': ?temperature,
      });
      return {'content': (text ?? '').trim()};
    } on PlatformException catch (e) {
      throw StateError(e.message ?? 'Apple’s on-device model couldn’t answer.');
    } on MissingPluginException {
      throw StateError(AppleAiStatus.unsupported.message);
    }
  }

  /// The conversation as one prompt, newest last, trimmed from the oldest
  /// end. Tool traffic is dropped: this route never calls tools.
  @visibleForTesting
  static String buildPrompt(List<Map<String, dynamic>> messages) {
    final turns = <String>[];
    for (final m in messages) {
      final role = m['role'];
      if (role != 'user' && role != 'assistant') continue;
      final t = _text(m['content']).trim();
      if (t.isEmpty) continue;
      turns.add(role == 'user' ? t : 'Previously you answered: $t');
    }
    if (turns.isEmpty) return '';
    if (turns.length == 1) return _clip(turns.single, promptBudget);
    final last = turns.removeLast();
    final history = turns.join('\n\n');
    final room = promptBudget - last.length - 40;
    return room <= 200
        ? _clip(last, promptBudget)
        : 'Earlier in this chat:\n${_clip(history, room)}\n\nNow: $last';
  }

  static String _text(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .map((p) => p is Map ? '${p['text'] ?? ''}' : '$p')
          .join(' ');
    }
    return content == null ? '' : '$content';
  }

  static String _clip(String s, int max, {bool keepEnd = true}) {
    if (s.length <= max) return s;
    return keepEnd
        ? '…${s.substring(s.length - max + 1)}'
        : '${s.substring(0, max - 1)}…';
  }

  /// The last 14 days from the coach's own guarded read-only view.
  static Future<String> _snapshot() async {
    try {
      final rows = await CoachDb.runCoachSql(
          'SELECT date, readiness, strain, sleep_min, deep_min, rem_min, '
          'resting_hr, hrv, resp_rate, stress, steps FROM v_daily '
          'ORDER BY date DESC LIMIT 14',
          rowCap: 14);
      final week = await CoachDb.runCoachSql(
          'WITH d AS (SELECT date, readiness, strain, sleep_min, resting_hr, '
          'hrv FROM v_daily ORDER BY date DESC LIMIT 14), n AS (SELECT *, '
          'ROW_NUMBER() OVER (ORDER BY date DESC) AS i FROM d) '
          "SELECT CASE WHEN i <= 7 THEN 'this week' ELSE 'last week' END AS "
          'week, ROUND(AVG(readiness)) AS recovery, ROUND(AVG(strain), 1) AS '
          'strain, ROUND(AVG(sleep_min)) AS sleep_min, ROUND(AVG(resting_hr)) '
          'AS resting_hr, ROUND(AVG(hrv)) AS hrv FROM n GROUP BY 1',
          rowCap: 2);
      final today = await CoachDb.runCoachSql(
          'SELECT date, readiness AS recovery, strain, sleep_min, resting_hr, '
          'hrv FROM v_daily ORDER BY date DESC LIMIT 1',
          rowCap: 1);
      return 'TODAY: ${_clip(today, 300, keepEnd: false)}\n'
          'THE WEEK (averages): ${_clip(week, 500, keepEnd: false)}\n'
          'THE DATA (newest first; null = not measured). Columns: date, '
          'Recovery 0-100, Strain 0-21, sleep min, deep min, REM min, resting '
          'HR, HRV ms, breathing rate, stress, steps.\n'
          '${_clip(rows, 2400, keepEnd: false)}';
    } catch (e) {
      return 'THE DATA: could not be read right now ($e).';
    }
  }
}

/// The coach's rules, cut to what a small model can hold.
const String kAppleCoachInstructions = '''
You are the Edge coach inside the user's own health app, running on their
iPhone. Answer only about their sleep, recovery, strain, training, heart rate,
HRV and habits, using ONLY the data below. Rules:
- Never state a number that is not in the data. If something is missing, say
  it is missing.
- Recovery is 0-100, Strain is 0-21. Say "HRV" and "your usual".
- Compare with their own recent days, not population norms.
- Never diagnose. For worrying patterns suggest asking a clinician. Only if
  the user mentions chest pain, fainting or severe breathlessness: urgent
  care first.
- Talk naturally: don't repeat the words TODAY, THE WEEK or THE DATA.
- TODAY is today's numbers; quote them exactly. Use THE WEEK for "this
  week vs last".
- Recovery 67+ is a good day to push, 34-66 train moderately, under 34 keep
  it easy and prioritise sleep.
- Be short and practical: 2-5 sentences or a few bullets. Plain language.
- You cannot log food, workouts or medications on this model; if asked, say
  to use the app's Log screens.''';
