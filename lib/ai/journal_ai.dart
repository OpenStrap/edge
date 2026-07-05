// journal_ai.dart — the pre-sleep "tell me about your day" chat that turns a
// natural-language recap into a STRUCTURED journal entry (tags + note) via the
// user's own BYOK key. The model never writes to the store: it PROPOSES a log,
// the UI shows exactly what will be saved, and the save path is the same
// repo.postJournal(date, tags, note) the manual editor uses.

import 'dart:convert';

import '../coach/coach_config.dart';
import '../coach/coach_engine.dart';

/// The journal's preset tag vocabulary — the single list shared by the manual
/// editor chips, the AI extractor and the correlation engine's tag space.
const List<String> kJournalPresetTags = <String>[
  'caffeine', 'alcohol', 'late meal', 'stress', 'poor sleep', 'travel',
  'screens late', 'meds', 'sick', 'sauna', 'cold plunge', 'social',
  'workout', 'rest day',
];

/// One assistant turn: the conversational reply + the CUMULATIVE proposed log.
class JournalAiTurn {
  final String reply;
  final List<String> tags;
  final String note;
  const JournalAiTurn(
      {required this.reply, required this.tags, required this.note});
}

/// Parse the model's JSON contract `{reply, tags, note}` leniently (fences,
/// stray prose around the object). Falls back to treating the whole text as the
/// reply with nothing extracted — the chat stays usable, nothing is fabricated.
JournalAiTurn parseJournalAiResponse(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    final nl = text.indexOf('\n');
    if (nl > 0) text = text.substring(nl + 1);
    if (text.endsWith('```')) text = text.substring(0, text.length - 3);
    text = text.trim();
  }
  dynamic j;
  try {
    j = jsonDecode(text);
  } catch (_) {
    final s = text.indexOf('{'), e = text.lastIndexOf('}');
    if (s >= 0 && e > s) {
      try {
        j = jsonDecode(text.substring(s, e + 1));
      } catch (_) {}
    }
  }
  if (j is! Map) {
    return JournalAiTurn(reply: text, tags: const [], note: '');
  }
  final tags = <String>[
    if (j['tags'] is List)
      for (final t in j['tags'] as List)
        if (t is String && t.trim().isNotEmpty) t.trim().toLowerCase(),
  ];
  return JournalAiTurn(
    reply: (j['reply'] as String?)?.trim() ?? '',
    tags: tags,
    note: (j['note'] as String?)?.trim() ?? '',
  );
}

/// Merge an AI/compose save into whatever the day already holds: tags union
/// (existing order first), notes concatenated (skipping an exact duplicate).
({List<String> tags, String note}) mergeJournalEntry({
  required List<String> existingTags,
  required String existingNote,
  required List<String> newTags,
  required String newNote,
}) {
  final tags = <String>[...existingTags];
  for (final t in newTags) {
    if (!tags.contains(t)) tags.add(t);
  }
  final a = existingNote.trim(), b = newNote.trim();
  final note = a.isEmpty
      ? b
      : (b.isEmpty || a == b || a.contains(b) ? a : '$a\n$b');
  return (tags: tags, note: note);
}

String journalAiSystemPrompt() =>
    'You help someone log their day in a health journal, right before sleep. '
    'They tell you about their day in their own words; you keep a short '
    'structured log of it.\n'
    'Respond with ONLY a JSON object, no other text:\n'
    '{"reply": string, "tags": [string], "note": string}\n'
    '- reply: 1-3 warm sentences reflecting what you heard. You may ask at '
    'most ONE short follow-up if something health-relevant is unclear. No '
    'advice, no diagnosis, no emojis.\n'
    '- tags: the CUMULATIVE behaviours mentioned so far this conversation, '
    'preferring this vocabulary: ${kJournalPresetTags.join(', ')}. Add a '
    'short lowercase custom tag only when nothing fits.\n'
    '- note: a CUMULATIVE 1-3 sentence summary of the day so far, factual, '
    'in their voice. Only include things they actually said.';

/// Multi-turn chat wrapper over the shared BYOK plumbing. Holds the transcript
/// so each turn re-sends the conversation (the tags/note are cumulative).
class JournalAiEngine {
  final CoachConfig config;

  /// Test seam: given the full messages list, return the model text.
  final Future<String> Function(List<Map<String, dynamic>> messages)? chat;

  JournalAiEngine({required this.config, this.chat});

  final List<Map<String, dynamic>> _history = [];

  bool get configured => chat != null || config.configured;

  /// One user turn → parsed assistant turn. Throws [CoachException] on
  /// provider errors / missing key.
  Future<JournalAiTurn> send(String userText) async {
    if (!configured) {
      throw CoachException('Add your AI key to use the journal chat.');
    }
    _history.add({'role': 'user', 'content': userText});
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': journalAiSystemPrompt()},
      // Keep the last 16 turns — a pre-sleep log, not a saga.
      ..._history.length <= 16
          ? _history
          : _history.sublist(_history.length - 16),
    ];
    final String raw;
    try {
      raw = await (chat != null
          ? chat!(messages)
          : CoachEngine.chatOnce(config: config, messages: messages));
    } catch (_) {
      _history.removeLast(); // failed turn shouldn't poison the transcript
      rethrow;
    }
    _history.add({'role': 'assistant', 'content': raw});
    return parseJournalAiResponse(raw);
  }
}
