// Tests for the AI briefing engine: input collection from a fake repository,
// pure prompt building + response parsing, and the day+period cache round-trip.
// The LLM is mocked (BriefingComplete injected) — no network.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/ai/nightly_sweep.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';

/// A repository stub returning canned Today/sleep/session shapes.
class _FakeRepo extends LocalRepository {
  Map<String, dynamic> today;
  Map<String, dynamic> daySleep;
  List<Map<String, dynamic>> sessions;

  /// Trend series keyed by the name getChart speaks — the nightly sweep's
  /// only source of history.
  Map<String, Map<String, dynamic>> charts;
  Map<String, dynamic> insights;

  _FakeRepo({
    Map<String, dynamic>? today,
    Map<String, dynamic>? daySleep,
    List<Map<String, dynamic>>? sessions,
    Map<String, Map<String, dynamic>>? charts,
    Map<String, dynamic>? insights,
  })  : today = today ?? {},
        daySleep = daySleep ?? {},
        sessions = sessions ?? const [],
        charts = charts ?? const {},
        insights = insights ?? const {};

  @override
  Future<Map<String, dynamic>> getToday() async => today;
  @override
  Future<Map<String, dynamic>> getDaySleep(String date) async => daySleep;
  @override
  Future<List<Map<String, dynamic>>> getSessions({
    int? from,
    int? to,
    bool includeDetected = true,
  }) async => sessions;
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => charts[metric] ?? const {'points': <Map<String, dynamic>>[]};
  @override
  Future<Map<String, dynamic>> getInsights() async => insights;
}

/// [history] values ending YESTERDAY, then today's — the shape getChart
/// returns (local-noon epoch seconds per day, oldest first).
Map<String, dynamic> _series(List<double> history, double todayValue) {
  final now = DateTime.now();
  int at(int daysAgo) =>
      DateTime(now.year, now.month, now.day - daysAgo, 12)
              .millisecondsSinceEpoch ~/
          1000;
  return {
    'points': [
      for (var i = 0; i < history.length; i++)
        {'t': at(history.length - i), 'v': history[i]},
      {'t': at(0), 'v': todayValue},
    ],
  };
}

List<double> _steady(double around, int n) =>
    [for (var i = 0; i < n; i++) around + (i % 3) - 1];

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
      // This night carries no onset/wake. They are NAMED rather than silently
      // dropped — the prompt's refusal rule is keyed off this list, so a field
      // that is absent from both is one the model may invent.
      expect(inp[kWithheldKey], containsAll(<String>['bedtime', 'wake_time']));
    });

    test('evening carries findings — never the day read back', () async {
      final repo = _FakeRepo(
        today: _sampleToday(),
        charts: {'resting_hr': _series(_steady(54, 45), 68)},
        insights: {
          'sleep_coach': {
            'bedtime': {
              'value': {'bedtime_min_of_day': 1365}
            }
          }
        },
      );
      final inp = await collectBriefingInputs(repo, BriefingPeriod.evening);
      expect((inp['unusual_for_you'] as List).single,
          contains('resting heart rate 68 bpm'));
      expect(inp['recommended_bedtime'], '22:45');
      // The old evening snapshot, every entry of which is a number the user
      // had just looked at. Handing those over is what produced a recap that
      // restated the day back and was worth nothing.
      for (final k in [
        'strain_0_21',
        'steps',
        'calories_total_kcal',
        'stress_0_100',
        'workouts',
        'readiness',
        'sleep_min',
      ]) {
        expect(inp.containsKey(k), isFalse, reason: k);
      }
    });

    test('an ordinary evening sends nothing at all', () async {
      final repo = _FakeRepo(
        today: _sampleToday(),
        charts: {'resting_hr': _series(_steady(54, 45), 54)},
      );
      expect(await collectBriefingInputs(repo, BriefingPeriod.evening), isEmpty);
    });

    test('missing metrics produce an empty-ish snapshot, never fabricated',
        () async {
      final repo = _FakeRepo(today: {'daily': {}});
      final inp = await collectBriefingInputs(repo, BriefingPeriod.morning);
      expect(inp.containsKey('readiness'), isFalse);
      expect(inp.containsKey('sleep_min'), isFalse);
    });
  });

  // A metric the honesty layer REFUSED must not reach the prompt as a value,
  // and must not reach it as a silence either — a silence is the shape the
  // model fills in from whatever else it was handed (see kWithheldKey).
  group('refused metrics', () {
    test('a refusal is stated with its reason, never sent as a value',
        () async {
      final repo = _FakeRepo(
        today: {
          'daily': {
            // Exactly what local_repository_impl._scalarMetric writes for an
            // absent metric: the em-dash placeholder plus the machine note.
            'readiness': {
              'value': '—',
              'confidence': 0,
              'tier': 'HIGH',
              'note': 'need_baseline:have=6,need=14',
            },
            'resting_hr': {
              'value': '—',
              'confidence': 0,
              'tier': 'HIGH',
              'note': 'need_input:name=scored_night',
            },
          },
          'hrv': {'rmssd': 61.2},
          'status': {'overnight_day': todayLabel()},
        },
        daySleep: {'has_sleep': true, 'duration_min': 445},
      );
      final inp = await collectBriefingInputs(repo, BriefingPeriod.morning);
      expect(inp.containsKey('readiness'), isFalse);
      expect(inp.containsKey('resting_hr'), isFalse);
      expect(inp['hrv_rmssd'], 61.2);
      final w = (inp[kWithheldKey] as List).cast<String>();
      expect(w, contains('readiness (Need 8 more nights)'));
      expect(
          w,
          contains('resting_hr (There is no scored night to read this '
              'from.)'));
      // A night with no deep/REM behind it is refused per field, not silently
      // dropped — that is the one the model narrates from total sleep time.
      expect(w, contains('deep_min'));
      expect(w, contains('rem_min'));

      final p = buildBriefingUserPrompt(
          BriefingPeriod.morning, '2026-07-04', inp, 'morning');
      expect(p, contains('withheld (refused'));
      expect(p, contains('- readiness (Need 8 more nights)'));
      // The refused number never appears as data.
      expect(p, isNot(contains('readiness: ')));
      expect(p, isNot(contains('resting_hr: ')));
      expect(p, contains('hrv_rmssd: 61.2'));
    });

    test('a whole missing night is one refusal, not five', () async {
      final repo = _FakeRepo(today: {'daily': {}});
      final inp = await collectBriefingInputs(repo, BriefingPeriod.morning);
      final w = (inp[kWithheldKey] as List).cast<String>();
      expect(w, contains('sleep (no scored night)'));
      expect(w.where((e) => e.startsWith('deep_min')), isEmpty);
      // Nothing measured, so the prompt still says so — the refusals are not
      // mistaken for a payload.
      final p = buildBriefingUserPrompt(
          BriefingPeriod.morning, '2026-07-04', inp, 'morning');
      expect(p, contains('no metrics available'));
      expect(p, contains('withheld (refused'));
    });

    test('an absent value can never render as prose, whoever built the map',
        () {
      // The structural half of the gate: `\$v` would print these as the word
      // "null" and as an em dash, both of which read as a reading.
      final p = buildBriefingUserPrompt(
        BriefingPeriod.morning,
        '2026-07-04',
        {'readiness': null, 'resting_hr': '—', 'hrv_rmssd': 61.2},
        'morning',
      );
      expect(p, isNot(contains('null')));
      expect(p, isNot(contains('—')));
      expect(p, contains('hrv_rmssd: 61.2'));
    });

    test('the system prompt forbids inferring a withheld metric', () {
      final m = briefingSystemPrompt(BriefingPeriod.morning);
      expect(m, contains('withheld'));
      expect(m, contains('REFUSED'));
      expect(m, contains('reasoned out of the numbers you WERE given'));
    });

    test('the evening sweep never carries a withheld list', () async {
      final repo = _FakeRepo(
        today: _sampleToday(),
        charts: {'resting_hr': _series(_steady(54, 45), 68)},
      );
      final inp = await collectBriefingInputs(repo, BriefingPeriod.evening);
      expect(inp.containsKey(kWithheldKey), isFalse);
    });
  });

  group('prompt building (pure)', () {
    test('system prompt scopes by period and forbids invention', () {
      final m = briefingSystemPrompt(BriefingPeriod.morning);
      expect(m, contains('ONLY the numbers provided'));
      expect(m.toLowerCase(), contains('sleep'));
      // The evening prompt is the sweep's, and its rules are the anti-slop
      // ones: findings only, no summary, no disclaimer, one action.
      final e = briefingSystemPrompt(BriefingPeriod.evening).toLowerCase();
      expect(e, contains('finding'));
      expect(e, contains('do not summarise the day'));
      expect(e, contains('no disclaimer'));
      expect(e, contains('never assert a cause'));
    });

    test('greeting comes from the app at read time, never baked into the '
        'model text (issue #134)', () {
      expect(partOfDay(DateTime(2026, 7, 22, 9)), 'morning');
      expect(partOfDay(DateTime(2026, 7, 22, 15)), 'afternoon');
      expect(partOfDay(DateTime(2026, 7, 22, 19)), 'evening');
      expect(partOfDay(DateTime(2026, 7, 22, 23)), 'night');
      // The morning briefing is shown until 17:00, so it can be generated at
      // 5am and read at 4pm — the model must never be told to write a
      // greeting/time-of-day reference at all, since that word gets cached
      // and can't track the actual read time. This must hold regardless of
      // which period is requested.
      for (final period in BriefingPeriod.values) {
        final sys = briefingSystemPrompt(period).toLowerCase();
        expect(sys, contains('do not open with a greeting'));
        // No "currently <time-of-day>" framing — that's the exact pattern
        // that got baked into the cached text and read stale hours later.
        expect(sys, isNot(contains('currently')));
        expect(sys, isNot(contains('good morning')));
        expect(sys, isNot(contains('good afternoon')));
        expect(sys, isNot(contains('good evening')));
      }
      // The USER prompt still carries the real read-time context for the
      // model to reason with, distinct from the system prompt's rules.
      final usr = buildBriefingUserPrompt(
          BriefingPeriod.morning, '2026-07-22', {'readiness': 74}, 'afternoon');
      expect(usr, contains('afternoon'));
      expect(usr.toLowerCase(), isNot(contains('morning')));
    });

    test('user prompt lists provided metrics and marks empty data', () {
      final p = buildBriefingUserPrompt(
          BriefingPeriod.morning, '2026-07-04', {'readiness': 74}, 'morning');
      expect(p, contains('readiness: 74'));
      final empty = buildBriefingUserPrompt(
          BriefingPeriod.evening, '2026-07-04', {}, 'evening');
      expect(empty, contains('no metrics available'));
    });

    test(
        'readinessBand is the ring\'s own band, folded to three words — a '
        'second set of cuts here is how the briefing and Home came to '
        'disagree about the same number', () {
      // Every ring boundary (26/37/61), from below and at.
      expect(readinessBand(0), 'low'); // ring: "Rest today"
      expect(readinessBand(25.9), 'low'); // ring: "Rest today"
      expect(readinessBand(26), 'low'); // ring: "Take it easy"
      expect(readinessBand(36.9), 'low'); // ring: "Take it easy"
      expect(readinessBand(37), 'moderate'); // ring: "Steady"
      expect(readinessBand(60.9), 'moderate'); // ring: "Steady"
      expect(readinessBand(61), 'good'); // ring: "Good to go"
      expect(readinessBand(100), 'good');
    });

    test('every ring tier has a briefing word', () {
      for (var v = 0; v <= 100; v++) {
        expect(readinessBand(v), isIn(const ['low', 'moderate', 'good']));
      }
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

    test('a boring evening calls nobody and says so in one line', () async {
      var called = false;
      final engine = BriefingEngine(
        config: CoachConfig(),
        repo: _FakeRepo(
          today: _sampleToday(),
          charts: {'resting_hr': _series(_steady(54, 45), 54)},
        ),
        complete: ({required system, required user}) async {
          called = true;
          return 'should never happen';
        },
      );
      final b = await engine.generate(BriefingPeriod.evening);
      expect(called, isFalse, reason: 'no finding is no question to ask');
      expect(b.oneLiner, kNothingStoodOut);
      expect(b.breakdownMd, isEmpty, reason: 'nothing may pad it out');
      expect(b.inputs, isEmpty);
      expect(b.calledModel, isFalse,
          reason: 'the "what was sent" screen reads this');
    });

    test('a finding does reach the model, and only findings do', () async {
      var seenUser = '';
      final engine = BriefingEngine(
        config: CoachConfig(),
        repo: _FakeRepo(
          today: _sampleToday(),
          charts: {'resting_hr': _series(_steady(54, 45), 68)},
        ),
        complete: ({required system, required user}) async {
          seenUser = user;
          return 'Resting heart rate ran high today.\n---\n- Get to bed early';
        },
      );
      final b = await engine.generate(BriefingPeriod.evening);
      expect(seenUser, contains('resting heart rate 68 bpm'));
      expect(seenUser, isNot(contains('strain')));
      expect(b.calledModel, isTrue);
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
