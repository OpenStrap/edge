// Tests for the AI briefing engine: input collection from a fake repository,
// pure prompt building + response parsing, and the day+period cache round-trip.
// The LLM is mocked (BriefingComplete injected) — no network.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';

/// A repository stub returning canned Today/sleep/session shapes.
class _FakeRepo extends LocalRepository {
  Map<String, dynamic> today;
  Map<String, dynamic> daySleep;
  List<Map<String, dynamic>> sessions;

  _FakeRepo({
    Map<String, dynamic>? today,
    Map<String, dynamic>? daySleep,
    List<Map<String, dynamic>>? sessions,
  })  : today = today ?? {},
        daySleep = daySleep ?? {},
        sessions = sessions ?? const [];

  @override
  Future<Map<String, dynamic>> getToday() async => today;
  @override
  Future<Map<String, dynamic>> getDaySleep(String date) async => daySleep;
  @override
  Future<List<Map<String, dynamic>>> getSessions({int? from, int? to}) async =>
      sessions;
}

Map<String, dynamic> _sampleToday() => {
      'daily': {
        'readiness': {'value': 74},
        'resting_hr': {'value': 52},
        'strain': {'value': 12.4},
        'steps': {'value': 8300},
        'calories_total': {'value': 2450},
        'wear_min': {'value': 1380},
      },
      'hrv': {'rmssd': 61.2},
      'stress': {'score': 33},
      'status': {'overnight_day': todayLabel()},
      'step_goal': 10000,
    };

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  group('collectBriefingInputs', () {
    test('morning pulls sleep + recovery, absent fields stay absent', () async {
      final repo = _FakeRepo(
        today: _sampleToday(),
        daySleep: {
          'has_sleep': true,
          'duration_min': 445,
          'efficiency': 0.91, // 0..1 from the store → *100 in the snapshot
          'deep_min': 78,
          'rem_min': 96,
          'debt_min': 35,
        },
      );
      final inp = await collectBriefingInputs(repo, BriefingPeriod.morning);
      expect(inp['readiness'], 74);
      expect(inp['resting_hr'], 52);
      expect(inp['hrv_rmssd'], 61.2);
      expect(inp['sleep_min'], 445);
      expect(inp['sleep_efficiency_pct'], 91);
      expect(inp['deep_min'], 78);
      // Evening-only metrics never leak into a morning snapshot.
      expect(inp.containsKey('strain_0_21'), isFalse);
      expect(inp.containsKey('steps'), isFalse);
    });

    test('evening pulls activity + workouts, not sleep', () async {
      final repo = _FakeRepo(
        today: _sampleToday(),
        sessions: [
          {
            'type': 'run',
            'start_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'duration_min': 42,
          },
        ],
      );
      final inp = await collectBriefingInputs(repo, BriefingPeriod.evening);
      expect(inp['strain_0_21'], 12.4);
      expect(inp['steps'], 8300);
      expect(inp['calories_total_kcal'], 2450);
      expect(inp['stress_0_100'], 33);
      expect(inp['workouts'], isA<List>());
      expect((inp['workouts'] as List).first, contains('run'));
      expect(inp.containsKey('readiness'), isFalse);
      expect(inp.containsKey('sleep_min'), isFalse);
    });

    test('missing metrics produce an empty-ish snapshot, never fabricated',
        () async {
      final repo = _FakeRepo(today: {'daily': {}});
      final inp = await collectBriefingInputs(repo, BriefingPeriod.morning);
      expect(inp.containsKey('readiness'), isFalse);
      expect(inp.containsKey('sleep_min'), isFalse);
    });
  });

  group('prompt building (pure)', () {
    test('system prompt scopes by period and forbids invention', () {
      final m = briefingSystemPrompt(BriefingPeriod.morning);
      expect(m, contains('ONLY the numbers provided'));
      expect(m.toLowerCase(), contains('sleep'));
      final e = briefingSystemPrompt(BriefingPeriod.evening);
      expect(e.toLowerCase(), contains('strain'));
    });

    test('user prompt lists provided metrics and marks empty data', () {
      final p = buildBriefingUserPrompt(
          BriefingPeriod.morning, '2026-07-04', {'readiness': 74});
      expect(p, contains('readiness: 74'));
      final empty = buildBriefingUserPrompt(
          BriefingPeriod.evening, '2026-07-04', {});
      expect(empty, contains('no metrics available'));
    });
  });

  group('response parsing', () {
    test('splits one-liner from bullets on the --- separator', () {
      final r = parseBriefingResponse(
          'You recovered well overnight.\n---\n- HRV up 6ms\n- RHR steady at 52');
      expect(r.oneLiner, 'You recovered well overnight.');
      expect(r.breakdownMd, contains('- HRV up 6ms'));
    });

    test('tolerates a missing separator and code fences', () {
      final r = parseBriefingResponse(
          '```\nSolid day.\n- Good strain\n```');
      expect(r.oneLiner, 'Solid day.');
      expect(r.breakdownMd, contains('Good strain'));
    });

    test('a single-line reply leaves the breakdown empty (no echo — #107)', () {
      // A model that ignores the format and returns one line must NOT have that
      // line copied back as a lone bullet, or the UI renders it twice.
      final r = parseBriefingResponse('User Safety: safe');
      expect(r.oneLiner, 'User Safety: safe');
      expect(r.breakdownMd, isEmpty);
    });
  });

  group('BriefingEngine + cache', () {
    test('generate calls the (mocked) LLM, parses, and caches', () async {
      final repo = _FakeRepo(today: _sampleToday());
      var seenSystem = '';
      final engine = BriefingEngine(
        config: CoachConfig(), // unconfigured — the mocked completer bypasses it
        repo: repo,
        complete: ({required system, required user}) async {
          seenSystem = system;
          return 'Recovered and ready.\n---\n- Readiness 74\n- RHR 52';
        },
      );
      final b = await engine.generate(BriefingPeriod.morning);
      expect(b.oneLiner, 'Recovered and ready.');
      expect(b.inputs['readiness'], 74);
      expect(seenSystem, isNotEmpty);

      // Cached under today+period; a different period reads back null.
      final cached = BriefingStore.read(BriefingPeriod.morning);
      expect(cached?.oneLiner, 'Recovered and ready.');
      expect(BriefingStore.read(BriefingPeriod.evening), isNull);
    });

    test('cache read is scoped to the day (stale day → null)', () {
      BriefingStore.write(Briefing(
        day: '1999-01-01',
        period: BriefingPeriod.morning,
        oneLiner: 'stale',
        breakdownMd: '- stale',
        generatedAtMs: 0,
        inputs: const {},
      ));
      expect(BriefingStore.read(BriefingPeriod.morning), isNull);
      expect(
          BriefingStore.read(BriefingPeriod.morning, day: '1999-01-01')
              ?.oneLiner,
          'stale');
    });
  });

  test('journal-done flag round-trips per day', () {
    expect(BriefingStore.journalDoneToday(), isFalse);
    BriefingStore.markJournalDone();
    expect(BriefingStore.journalDoneToday(), isTrue);
    expect(BriefingStore.journalDoneToday('1999-01-01'), isFalse);
  });
}
