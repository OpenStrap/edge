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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/day_label.dart';
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
        available => 'Ready.',
        notEnabled =>
          'Turn on Apple Intelligence in Settings to use the on-device model.',
        notReady =>
          'Apple’s on-device model is still downloading. Try again later.',
        deviceNotEligible => 'This iPhone can’t run Apple’s on-device model.',
        unsupported =>
          'Needs an iPhone with Apple Intelligence on iOS 26 or later.',
      };
}

/// User-facing failures of the on-device route. English here; the coach's
/// error card translates them through `localizedText`.
const String kAppleFailedMessage =
    'Apple’s on-device model couldn’t answer. Try again.';
const String kAppleTooLongMessage =
    'That was too long for Apple’s on-device model. Start a new chat or ask a shorter question.';
const String kAppleDeclinedMessage =
    'Apple’s on-device model declined to answer that. Try wording it differently.';
const String kAppleTimeoutMessage =
    'Apple’s on-device model took too long to answer. Try again, or ask a shorter question.';
const String kAppleNoEcgMessage =
    'Apple’s on-device model can’t read an ECG waveform. To analyse this reading, switch Apple Intelligence off in the coach’s AI settings and use another model.';

class AppleOnDevice {
  AppleOnDevice._();

  static const _ch = MethodChannel('openstrap/apple_ai');

  /// Budgets in cost units (see [cost]): about 3.5 Latin characters per
  /// token, so a unit is roughly a Latin character. The model's window holds
  /// the instructions, the prompt AND its answer.
  static const int instructionBudget = 3200;
  static const int promptBudget = 4200;

  /// The native side gives up at 60 s; this backstop only covers a bridge
  /// that never answers at all. Settable for tests only.
  @visibleForTesting
  static Duration respondTimeout = const Duration(seconds: 75);

  /// Cost of a text against the budgets. Scripts outside Latin (Cyrillic,
  /// Devanagari, Thai, CJK…) take far more tokens per character, so each of
  /// their characters counts as 4: a long Thai or Chinese chat is clipped
  /// well before it can overflow the context window.
  @visibleForTesting
  static int cost(String s) {
    var n = 0;
    for (final r in s.runes) {
      n += _runeCost(r);
    }
    return n;
  }

  static int _runeCost(int rune) => rune < 0x0370 ? 1 : 4;

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
  ///
  /// [today] is the coach's headline readiness for today (the engine's
  /// `_todayReadiness`), so the snapshot never shows a mid-sync partial night.
  static Future<Map<String, dynamic>> reply(
    Map<String, dynamic> body, {
    Future<({String day, num? readiness})?> Function()? today,
  }) async {
    final messages = [
      for (final m in (body['messages'] as List? ?? const []))
        if (m is Map) m.cast<String, dynamic>(),
    ];
    final isCoach = body['tools'] is List && (body['tools'] as List).isNotEmpty;
    // The ECG screen's "Analyze" asks for get_ecg_reading, a tool this route
    // cannot call: say so instead of answering without the waveform.
    if (isCoach && asksForEcgReading(messages)) {
      throw StateError(kAppleNoEcgMessage);
    }
    final instructions = isCoach
        ? '$kAppleCoachInstructions\n\n'
            '${await _snapshot(today == null ? null : await today())}'
        : _clip(
            messages
                .where((m) => m['role'] == 'system')
                .map((m) => _text(m['content']))
                .join('\n\n'),
            instructionBudget,
            keepEnd: false);
    final prompt = buildPrompt(messages);
    final temperature = (body['temperature'] as num?)?.toDouble();
    final String? text;
    try {
      text = await _ch.invokeMethod<String>('respond', {
        'instructions': _clip(instructions, instructionBudget + 2600,
            keepEnd: false),
        'prompt': prompt,
        'temperature': ?temperature,
      }).timeout(respondTimeout);
    } on TimeoutException {
      throw StateError(kAppleTimeoutMessage);
    } on PlatformException catch (e) {
      debugPrint('apple_ai respond: ${e.code}: ${e.message}');
      throw StateError(errorMessage(e.code));
    } on MissingPluginException {
      throw StateError(AppleAiStatus.unsupported.message);
    }
    final t = (text ?? '').trim();
    if (t.isEmpty) throw StateError(kAppleFailedMessage);
    return {'content': t};
  }

  /// The user-facing message for a native error code.
  @visibleForTesting
  static String errorMessage(String code) => switch (code) {
        'notEnabled' => AppleAiStatus.notEnabled.message,
        'notReady' => AppleAiStatus.notReady.message,
        'deviceNotEligible' => AppleAiStatus.deviceNotEligible.message,
        'unsupported' => AppleAiStatus.unsupported.message,
        'tooLong' => kAppleTooLongMessage,
        'declined' => kAppleDeclinedMessage,
        'timeout' => kAppleTimeoutMessage,
        _ => kAppleFailedMessage,
      };

  /// Whether the newest user turn asks for an ECG reading's waveform.
  @visibleForTesting
  static bool asksForEcgReading(List<Map<String, dynamic>> messages) {
    for (final m in messages.reversed) {
      if (m['role'] != 'user') continue;
      return _text(m['content']).contains('get_ecg_reading');
    }
    return false;
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
    final room = promptBudget - cost(last) - 40;
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

  /// [s] cut to [max] cost units (see [cost]), marking the cut with '…'.
  static String _clip(String s, int max, {bool keepEnd = true}) {
    if (cost(s) <= max) return s;
    final runes = s.runes.toList();
    final kept = <int>[];
    var n = 1; // the '…'
    for (var i = 0; i < runes.length; i++) {
      final r = runes[keepEnd ? runes.length - 1 - i : i];
      n += _runeCost(r);
      if (n > max) break;
      kept.add(r);
    }
    final body =
        String.fromCharCodes(keepEnd ? kept.reversed.toList() : kept);
    return keepEnd ? '…$body' : '$body…';
  }

  /// The last 14 calendar days from the coach's own guarded read-only view,
  /// anchored on today's LOCAL date. [today] is the Home headline readiness
  /// (the same value the engine hands run_sql), so a mid-sync partial night
  /// never reaches the model as today's recovery.
  static Future<String> _snapshot(({String day, num? readiness})? today) async {
    try {
      // Re-formatted from its parsed parts: only a clean label reaches the SQL.
      final d0 = dayLabelBefore(today?.day ?? '', 0) ?? todayLabel();
      final d6 = dayLabelBefore(d0, 6)!, d13 = dayLabelBefore(d0, 13)!;
      final rows = await CoachDb.runCoachSql(
          'SELECT date, readiness, strain, sleep_min, deep_min, rem_min, '
          'resting_hr, hrv, resp_rate, stress, steps FROM v_daily '
          "WHERE date BETWEEN '$d13' AND '$d0' ORDER BY date DESC LIMIT 14",
          rowCap: 14,
          today: today);
      final week = await CoachDb.runCoachSql(
          "SELECT CASE WHEN date >= '$d6' THEN 'last 7 days' ELSE "
          "'the 7 days before' END AS period, ROUND(AVG(readiness)) AS "
          'recovery, ROUND(AVG(strain), 1) AS strain, ROUND(AVG(sleep_min)) '
          'AS sleep_min, ROUND(AVG(resting_hr)) AS resting_hr, '
          'ROUND(AVG(hrv)) AS hrv FROM v_daily '
          "WHERE date BETWEEN '$d13' AND '$d0' GROUP BY 1",
          rowCap: 2,
          today: today);
      final todayRow = await CoachDb.runCoachSql(
          'SELECT date, readiness AS recovery, strain, sleep_min, resting_hr, '
          "hrv FROM v_daily WHERE date = '$d0'",
          rowCap: 1,
          today: today);
      return 'TODAY ($d0): ${_hasRows(todayRow) ? _clip(todayRow, 300, keepEnd: false) : 'no data for today yet.'}\n'
          'THE WEEK (averages): ${_clip(week, 500, keepEnd: false)}\n'
          'THE DATA (newest first; null = not measured). Columns: date, '
          'Recovery 0-100, Strain 0-21, sleep min, deep min, REM min, resting '
          'HR, HRV ms, breathing rate, stress, steps.\n'
          '${_clip(rows, 2400, keepEnd: false)}';
    } catch (e) {
      return 'THE DATA: could not be read right now ($e).';
    }
  }

  static bool _hasRows(String result) {
    try {
      final j = jsonDecode(result);
      return j is Map && (j['row_count'] as num? ?? 0) > 0;
    } catch (_) {
      return false;
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
- TODAY is today's numbers; quote them exactly. If it says there is no
  data for today yet, say so. Use THE WEEK for "this week vs last".
- Recovery 67+ is a good day to push, 34-66 train moderately, under 34 keep
  it easy and prioritise sleep.
- Be short and practical: 2-5 sentences or a few bullets. Plain language.
- You cannot log food, workouts or medications on this model; if asked, say
  to use the app's Log screens. You cannot see ECG readings.''';
