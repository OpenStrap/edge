// Tests for the journal AI extractor: parsing the model's JSON contract into a
// structured entry, cumulative merge, and the chat engine round-trip (mocked).

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ai/journal_ai.dart';
import 'package:openstrap_edge/coach/coach_config.dart';

void main() {
  group('parseJournalAiResponse', () {
    test('parses the JSON contract into tags + note', () {
      final t = parseJournalAiResponse(
          '{"reply":"Got it.","tags":["alcohol","late meal"],'
          '"note":"Two beers with a late dinner."}');
      expect(t.reply, 'Got it.');
      expect(t.tags, ['alcohol', 'late meal']);
      expect(t.note, contains('late dinner'));
    });

    test('tolerates code fences and surrounding prose', () {
      final t = parseJournalAiResponse(
          'Sure!\n```json\n{"reply":"ok","tags":["stress"],"note":"Rough day."}\n```');
      expect(t.tags, ['stress']);
      expect(t.note, 'Rough day.');
    });

    test('non-JSON falls back to reply-only, nothing fabricated', () {
      final t = parseJournalAiResponse('I could not parse that.');
      expect(t.reply, 'I could not parse that.');
      expect(t.tags, isEmpty);
      expect(t.note, isEmpty);
    });

    test('tags are lowercased and trimmed', () {
      final t = parseJournalAiResponse('{"tags":[" Caffeine ","WORKOUT"]}');
      expect(t.tags, ['caffeine', 'workout']);
    });
  });

  group('mergeJournalEntry', () {
    test('unions tags and appends distinct notes', () {
      final m = mergeJournalEntry(
        existingTags: ['caffeine'],
        existingNote: 'Coffee at noon.',
        newTags: ['caffeine', 'stress'],
        newNote: 'Stressful afternoon.',
      );
      expect(m.tags, ['caffeine', 'stress']);
      expect(m.note, 'Coffee at noon.\nStressful afternoon.');
    });

    test('does not duplicate an already-contained note', () {
      final m = mergeJournalEntry(
        existingTags: const [],
        existingNote: 'Long note about the day.',
        newTags: const [],
        newNote: 'the day',
      );
      expect(m.note, 'Long note about the day.');
    });
  });

  group('JournalAiEngine', () {
    test('send() feeds transcript to the (mocked) LLM and parses', () async {
      final seen = <List<Map<String, dynamic>>>[];
      final engine = JournalAiEngine(
        config: CoachConfig(),
        chat: (messages) async {
          seen.add(messages);
          return '{"reply":"Logged your run.","tags":["workout"],'
              '"note":"Ran 5k this evening."}';
        },
      );
      final turn = await engine.send('I went for a 5k run tonight.');
      expect(turn.tags, ['workout']);
      expect(turn.note, contains('5k'));
      // The transcript carried a system prompt + the user turn.
      expect(seen.single.first['role'], 'system');
      expect(seen.single.last['content'], contains('5k run'));
    });

    test('a failed turn is rolled back so the next retry is clean', () async {
      var calls = 0;
      final engine = JournalAiEngine(
        config: CoachConfig(),
        chat: (messages) async {
          calls++;
          if (calls == 1) throw Exception('network');
          // On retry the transcript must contain exactly ONE user turn.
          final users =
              messages.where((m) => m['role'] == 'user').toList();
          expect(users.length, 1);
          return '{"reply":"ok","tags":[],"note":""}';
        },
      );
      await expectLater(engine.send('hi'), throwsA(isA<Exception>()));
      final t = await engine.send('hi again');
      expect(t.reply, 'ok');
    });
  });
}
