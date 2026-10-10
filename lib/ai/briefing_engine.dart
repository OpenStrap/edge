// briefing_engine.dart — turns the local derived store into a morning/evening
// AI briefing via the user's OWN key (BYOK — CoachConfig + CoachEngine.postChat;
// no second LLM client, no second key store, no OpenStrap backend).
//
// Pipeline: collect a COMPACT inputs snapshot from the repository (read-only,
// zero compute — same store the screens read) → build a small prompt → one-shot
// completion → parse into (one-liner, markdown breakdown) → cache in
// BriefingStore keyed day+period.
//
// Honesty contract (same as everywhere else in this app): a metric that is
// absent from the store is absent from the prompt — the system prompt forbids
// the model from mentioning anything it wasn't given, and the breakdown screen
// shows exactly the inputs snapshot so the user can see what the model saw.
//
// Omission alone is NOT that contract, though, which is what [kWithheldKey]
// exists for. See its doc: silence about a refused metric leaves the model free
// to narrate the thing it measures out of whatever else it was handed, and this
// file already documents that happening (see [readinessBand]).

import '../coach/coach_config.dart';
import '../coach/coach_engine.dart';
import '../data/day_label.dart';
import '../data/local_repository.dart';
import '../models/metric.dart' show whyFromNote;
import '../models/payloads.dart' show todayHeadlineOf;
import '../ui2/screens/home_screen.dart' as ring show readinessBand;
import 'briefing.dart';
import 'nightly_sweep.dart';

/// Injectable one-shot completion (tests pass a fake; production defaults to
/// [CoachEngine.completeText] — the shared BYOK plumbing).
typedef BriefingComplete = Future<String> Function({
  required String system,
  required String user,
});

// ── input collection (repo → compact snapshot) ────────────────────────────────

num? _num(dynamic v) => v is num ? v : null;

/// Unwrap either a bare number or a `{value: …}` metric envelope.
num? _metricNum(dynamic v) {
  if (v is num) return v;
  if (v is Map) return _num(v['value']);
  return null;
}

Map<String, dynamic>? _map(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : null;

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

void _put(Map<String, dynamic> out, String key, num? v, {int? round}) {
  if (v == null || !v.isFinite) return;
  out[key] = round == null
      ? v
      : num.parse(v.toStringAsFixed(round)); // keep ints as ints
}

/// Reserved key in the inputs snapshot: the metrics this briefing ASKED FOR and
/// did not get, each with the reason the store gave, where it gave one.
///
/// WHY THIS IS NOT JUST OMISSION. Every refused metric is already dropped from
/// the payload — `Metric.value` arrives as null (or the store's `'—'`
/// placeholder), `_metricNum` returns null and `_put` skips the key. That much
/// was always right and is unchanged. What omission cannot do is stop the model
/// narrating the refused thing anyway out of what it WAS given: [readinessBand]
/// below exists because a model handed HRV and RHR free-associates a recovery
/// verdict from them, and when readiness is refused there is no score left to
/// contradict it. A silence is the one input shape the model will fill in.
///
/// So the refusal is stated, not hidden. The notes are machine-readable
/// precisely so this is possible — [whyFromNote] is the same parser the metric
/// cards use, and it returns null rather than inventing a cause for a token
/// nobody has written a sentence for, which is why an entry here may be a bare
/// key name.
///
/// MORNING ONLY. The evening pass is the nightly sweep, which ships findings and
/// nothing else; a list of what was refused is the day read back, which is the
/// exact failure `sweepInputs` exists to prevent, and a non-empty map there
/// would call a model on nights that should call none.
const String kWithheldKey = 'withheld';

/// Read-only snapshot of what the store knows for [period]. Only fields that
/// exist end up in the map — the prompt builder and the "based on" UI both walk
/// this map, so what the model saw and what the user sees are the same thing.
Future<Map<String, dynamic>> collectBriefingInputs(
  LocalRepository repo,
  BriefingPeriod period, {
  DateTime? now,
}) async {
  final t = await repo.getToday();
  final daily = _map(t['daily']) ?? const {};
  final out = <String, dynamic>{};
  final withheld = <String>[];

  /// Take the metric's value, or record the refusal. [env] is either a metric
  /// envelope (`{value, note, …}`) or a bare number; only an envelope can say
  /// why, and a bare absence is named without one rather than given a guess.
  void take(String key, dynamic env, {int? round}) {
    final v = _metricNum(env);
    if (v != null && v.isFinite) {
      _put(out, key, v, round: round);
      return;
    }
    final why = whyFromNote(_map(env)?['note'] as String?);
    withheld.add(why == null ? key : '$key ($why)');
  }

  if (period == BriefingPeriod.morning) {
    // The same headline Home shows: no number until today's night is final,
    // never a held-over or still-draining one presented as this morning's.
    take(
        'readiness',
        todayHeadlineOf(t)['recovery_state'] == 'final'
            ? daily['readiness']
            : null,
        round: 0);
    take('resting_hr', daily['resting_hr'], round: 0);
    final hrv = _map(t['hrv']);
    take('hrv_rmssd', hrv?['rmssd'], round: 1);

    // The overnight bundle Today is showing (may be yesterday's sleep if this
    // day hasn't derived yet) — same source of truth as the Sleep screen.
    final status = _map(t['status']);
    final sleepDay =
        (status?['overnight_day'] as String?) ?? todayLabel(now);
    Map<String, dynamic>? ds;
    try {
      final read = await repo.getDaySleep(sleepDay);
      if (read['has_sleep'] == true || _num(read['duration_min']) != null) {
        ds = read;
      }
    } catch (_) {/* sleep detail absent → morning runs on the daily scalars */}
    if (ds == null) {
      // One refusal for the whole night, not five for its parts: there is no
      // night, so no per-field gate ever ran and none of them has a reason.
      withheld.add('sleep (no scored night)');
    } else {
      take('sleep_min', ds['duration_min'], round: 0);
      final eff = _num(ds['efficiency']);
      take('sleep_efficiency_pct',
          eff == null ? null : (eff <= 1 ? eff * 100 : eff), round: 0);
      take('sleep_debt_min', ds['debt_min'], round: 0);
      take('deep_min', ds['deep_min'], round: 0);
      take('rem_min', ds['rem_min'], round: 0);
      take('awake_min', ds['awake_min'], round: 0);
      final onset = _num(ds['onset_ts'])?.toInt();
      final wake = _num(ds['wake_ts'])?.toInt();
      // Named when absent, like every other field — [take] cannot do these two
      // because they are clock strings rather than numbers, and that is the
      // whole of the difference. A scored night with no onset used to hand over
      // six sleep numbers and no refusal rule for the seventh, which is exactly
      // the hole `withheld` exists to close. Bare, with no reason: these are
      // raw columns, not metric envelopes, so there is no note to read one from.
      if (onset != null && onset > 0) {
        out['bedtime'] = _hhmm(
            DateTime.fromMillisecondsSinceEpoch(onset * 1000));
      } else {
        withheld.add('bedtime');
      }
      if (wake != null && wake > 0) {
        out['wake_time'] =
            _hhmm(DateTime.fromMillisecondsSinceEpoch(wake * 1000));
      } else {
        withheld.add('wake_time');
      }
    }
    if (withheld.isNotEmpty) out[kWithheldKey] = withheld;
  } else {
    // The evening pass is the nightly SWEEP, not a recap. It used to hand over
    // strain, steps, calories, stress and the day's workouts, which produced
    // exactly what you would expect: the day's numbers read back to someone who
    // had just looked at them. Nothing but findings goes now — see
    // nightly_sweep.dart for the bar one has to clear, and note that an empty
    // map here is the normal, correct answer on most days.
    return sweepInputs(
      sweepFindings(await collectSweepSeries(repo, now ?? DateTime.now())),
      recommendedBedtime: await _recommendedBedtime(repo),
    );
  }
  return out;
}

/// The metrics the sweep looks at, keyed by the name [LocalRepository.getChart]
/// speaks (it maps those onto series keys itself). Deliberately short: every
/// one of these is a number the user already has a screen for, so a finding
/// about it can be checked.
const Map<String, ({String key, String label, String unit, int dp})>
    kSweepMetrics = {
  'recovery': (key: 'readiness', label: 'recovery', unit: '', dp: 0),
  'resting_hr': (key: 'rhr', label: 'resting heart rate', unit: 'bpm', dp: 0),
  'hrv': (key: 'rmssd', label: 'HRV', unit: 'ms', dp: 0),
  'strain': (key: 'strain', label: 'strain', unit: '', dp: 1),
  'steps': (key: 'steps', label: 'steps', unit: '', dp: 0),
  'sleep': (key: 'tst_min', label: 'time asleep', unit: 'min', dp: 0),
  'efficiency': (
    key: 'efficiency',
    label: 'sleep efficiency',
    unit: '%',
    dp: 0
  ),
};

/// Today's value plus its own trailing history, per metric, read from the same
/// derived store the trend screens draw. A metric with no value TODAY is left
/// out entirely — there is nothing to have a finding about.
///
/// The window stops at the most recent algo-version break. Values either side
/// of one are not comparable, and a version bump reported as "the lowest in 60
/// days" would be a finding about us, not about the user.
Future<List<SweepSeries>> collectSweepSeries(
  LocalRepository repo,
  DateTime now,
) async {
  final today = todayLabel(now);
  final out = <SweepSeries>[];
  for (final e in kSweepMetrics.entries) {
    try {
      final chart = await repo.getChart(e.key);
      final points = chart['points'];
      if (points is! List) continue;
      var cutoff = 0;
      final breaks = chart['algo_breaks'];
      if (breaks is List) {
        for (final b in breaks) {
          final t = b is Map ? _num(b['t'])?.toInt() : null;
          if (t == null || t <= cutoff) continue;
          // Only breaks up to the day being read. A past day swept against a
          // LATER bump had a cutoff after its whole history: 0 days, always.
          final day =
              todayLabel(DateTime.fromMillisecondsSinceEpoch(t * 1000));
          if (day.compareTo(today) <= 0) cutoff = t;
        }
      }
      double? todayValue;
      final history = <double>[];
      for (final p in points) {
        if (p is! Map) continue;
        final t = _num(p['t'])?.toInt();
        final v = _num(p['v'])?.toDouble();
        if (t == null || v == null || !v.isFinite) continue;
        final day = todayLabel(DateTime.fromMillisecondsSinceEpoch(t * 1000));
        if (day == today) {
          todayValue = v;
        } else if (day.compareTo(today) < 0 && t >= cutoff) {
          history.add(v);
        }
      }
      if (todayValue == null) continue;
      final m = e.value;
      out.add(SweepSeries(
        key: m.key,
        label: m.label,
        unit: m.unit,
        decimals: m.dp,
        today: todayValue,
        history: history,
      ));
    } catch (_) {/* a series we cannot read is a series with no finding */}
  }
  return out;
}

/// The sleep coach's recommended bedtime as `HH:MM`, or null when it has not
/// earned one yet (it needs free-day nights before it says anything).
Future<String?> _recommendedBedtime(LocalRepository repo) async {
  try {
    final coach = _map((await repo.getInsights())['sleep_coach']);
    final v = _map(_map(coach?['bedtime'])?['value']);
    final min = _num(v?['bedtime_min_of_day'])?.round();
    if (min == null || min < 0) return null;
    final m = min % 1440;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  } catch (_) {
    return null;
  }
}

// ── prompt building (PURE — unit-tested on sample data) ───────────────────────

/// The reader's local time of day at GENERATION time — passed into the prompt
/// as context only (the model is told not to write a greeting off it; the app
/// renders its own greeting fresh at read time, since a cached briefing can be
/// read hours after it was generated). Deliberately distinct from
/// [BriefingPeriod]: the morning briefing (last night's sleep + recovery) is
/// shown right up to 17:00.
String partOfDay(DateTime now) {
  final h = now.hour;
  if (h < 12) return 'morning';
  if (h < 17) return 'afternoon';
  if (h < 21) return 'evening';
  return 'night';
}

/// Coarse readiness band injected alongside the raw score in the prompt —
/// without it the model free-associates tone from the sub-metrics (HRV/RHR)
/// and can contradict the score itself (a 16/100 read as "strong overnight
/// recovery"). The band is declared authoritative in the system prompt.
///
/// DERIVED FROM THE RING, never re-declared. It used to carry its own 40/66
/// cuts with a comment insisting they match the ring's — and then #250 moved
/// the ring to the score's own quantiles (26/37/61) and left these behind. A
/// 61 was "Good to go" on Home and "moderate" in the briefing on the same
/// morning: the tone-vs-score contradiction this function exists to prevent,
/// arrived from the one direction the comment could not police.
///
/// So there is one classifier ([readinessBand] in home_screen.dart) and this
/// is a PRESENTATION of it: four tiers folded to the three words the prompt
/// speaks, with both warning tiers reading "low".
String readinessBand(num v) => switch (ring.readinessBand(v).tier) {
      3 => 'good',
      2 => 'moderate',
      _ => 'low',
    };

/// The nightly sweep's rules.
///
/// Written against the failure it exists to prevent: a note that restates the
/// day back, wrapped in hedges, ending in nothing to do. The model is given
/// ONLY findings — every number in the payload is already unusual for this
/// user — so there is no ordinary number for it to pad with, and these rules
/// close the remaining ways to say nothing at length.
String _sweepSystemPrompt() =>
    'You write one short note at the end of the day for a local-first fitness '
        'band app.\n'
        'You are given only FINDINGS: things measured as unusual for THIS '
        'user, against their own history. You were not given the ordinary '
        'numbers of their day, and there is nothing wrong with that.\n'
        'HARD RULES:\n'
        '- Do not summarise the day. Do not restate a number as news. Every '
        'number you write must be one you were given.\n'
        '- No diagnosis, no severity, no "consult a professional", and no '
        'disclaimer of any kind. A hedge is filler; it is not caution.\n'
        '- No praise, no encouragement, no streaks, no score, no grade.\n'
        '- Never assert a cause. Two findings on the same day are two '
        'findings; say they coincided, never that one caused the other.\n'
        '- Give ONE concrete thing to do tomorrow, and attach the finding it '
        'follows from. If the findings do not support an action, say what '
        'stood out and stop — that is a complete note.\n'
        '- Do not open with a greeting or any reference to the time of day — '
        'this text can be read hours after it was written. Direct, second '
        'person, plain. No emojis, no headers.\n'
        'OUTPUT FORMAT (exactly):\n'
        'Line 1: one plain-text sentence, max 140 characters — the finding '
        'that matters most. No markdown.\n'
        'Line 2: ---\n'
        'Then 2-3 markdown bullet points (each starting with "- "), max 14 '
        'words each. One fact or one action per bullet, nothing else.';

String briefingSystemPrompt(BriefingPeriod period) {
  if (period == BriefingPeriod.evening) return _sweepSystemPrompt();
  const scope =
      'last night\'s sleep and recovery, and what they mean for the day ahead';
  return 'You write a health briefing for a local-first fitness band app. '
      'Summarize $scope.\n'
      'HARD RULES:\n'
      '- Do NOT open with a greeting or any reference to the time of day — '
      'the app shows its own greeting separately, computed at the moment the '
      'reader actually opens it, and this text may be read hours after it was '
      'written. Start straight with the substance.\n'
      '- Use ONLY the numbers provided. Never invent, estimate or mention a '
      'metric that is not in the data. No medical advice or diagnosis.\n'
      '- Anything under "withheld" was REFUSED by the measurement layer, not '
      'merely forgotten. You may say it is unavailable and give the reason '
      'shown, and nothing else: never a value, never a range, never a '
      'direction, never a quality word for what it measures — and never '
      'reasoned out of the numbers you WERE given. Calling recovery strong '
      'while readiness is withheld IS stating the withheld number.\n'
      '- If a "readiness" value is given, its parenthesized band label '
      '(low / moderate / good) is AUTHORITATIVE for tone: a low or moderate '
      'band must never be described as strong, solid or good recovery, even '
      'if individual sub-metrics (HRV, RHR) look fine in isolation.\n'
      '- The app calls the readiness score "recovery". Write "recovery", '
      'never "readiness"; say "HRV", never RMSSD; "your usual", never '
      '"baseline".\n'
      '- Warm, direct, second person. No emojis. No headers.\n'
      'OUTPUT FORMAT (exactly):\n'
      'Line 1: one plain-text sentence, max 140 characters — the whole story '
      'at a glance. No markdown.\n'
      'Line 2: ---\n'
      'Then 3-5 markdown bullet points (each starting with "- "), max 14 words '
      'each, one glanceable fact or gentle nudge per bullet, grounded in the '
      'numbers. No filler openers ("It\'s worth noting", "Additionally").';
}

String buildBriefingUserPrompt(
  BriefingPeriod period,
  String day,
  Map<String, dynamic> inputs,
  String timeOfDay,
) {
  final b = StringBuffer()
    ..writeln(period == BriefingPeriod.morning
        ? 'Overnight briefing for $day (reader\'s local time: $timeOfDay). '
            'Overnight data:'
        : 'Nightly sweep for $day (reader\'s local time: $timeOfDay). What '
            'came back as unusual for this person, and nothing else:');
  // A payload of nothing but refusals is still a payload of no measurements,
  // so the "nothing yet" line is keyed off the MEASURED entries, not the map.
  //
  // The null/`'—'` filter is the structural half of the withheld rule, and it
  // is HERE rather than in the collector because every prompt routes through
  // this function while collectors can be added. `'$v'` renders an absent
  // metric as the word "null" or as the store's em-dash placeholder
  // (`local_repository_impl._scalarMetric` writes `value: v ?? '—'`), and
  // either one is a refused metric arriving in the prompt looking like data.
  final measured = inputs.keys.where((k) =>
      k != kWithheldKey && inputs[k] != null && inputs[k] != '—');
  if (measured.isEmpty) {
    b.writeln('(no metrics available yet)');
  } else {
    for (final k in measured) {
      final v = inputs[k];
      if (k == 'readiness' && v is num) {
        // Inject the band label the model must treat as authoritative (see
        // the system prompt) — a bare "readiness: 16" otherwise reads as
        // just another number and gets free-associated a positive tone.
        b.writeln('$k: $v (${readinessBand(v)})');
      } else {
        b.writeln(v is List ? '$k: ${v.join(', ')}' : '$k: $v');
      }
    }
  }
  // Last, under its own header, so the rule in the system prompt has something
  // to name and a refusal can never be read as just another line of data.
  final w = inputs[kWithheldKey];
  if (w is List && w.isNotEmpty) {
    b.writeln('withheld (refused — see the withheld rule):');
    for (final e in w) {
      b.writeln('- $e');
    }
  }
  return b.toString().trimRight();
}

/// Split the model's reply into (one-liner, markdown breakdown). Lenient: the
/// contract is line-1 + `---` + bullets, but a model that skips the separator
/// still parses (first non-empty line becomes the one-liner).
({String oneLiner, String breakdownMd}) parseBriefingResponse(String raw) {
  var text = raw.trim();
  // Strip a wrapping code fence if the model added one.
  if (text.startsWith('```')) {
    final firstNl = text.indexOf('\n');
    if (firstNl > 0) text = text.substring(firstNl + 1);
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
    text = text.trim();
  }
  final lines = text.split('\n');
  final sepIdx = lines.indexWhere((l) => RegExp(r'^\s*-{3,}\s*$').hasMatch(l));

  String one;
  String rest;
  if (sepIdx > 0) {
    one = lines.take(sepIdx).join(' ');
    rest = lines.skip(sepIdx + 1).join('\n');
  } else {
    final firstIdx = lines.indexWhere((l) => l.trim().isNotEmpty);
    one = firstIdx < 0 ? '' : lines[firstIdx];
    rest = firstIdx < 0 ? '' : lines.skip(firstIdx + 1).join('\n');
  }
  // One-liner is plain text: drop bullet/heading markers, clamp length.
  one = one.replaceFirst(RegExp(r'^\s*[-*#>]+\s*'), '').trim();
  if (one.length > 200) one = '${one.substring(0, 199)}…';
  rest = rest.trim();
  // A model that returns a single line (no bullets) has no distinct breakdown.
  // Leave it EMPTY rather than echoing the one-liner back as a lone bullet —
  // the breakdown card would then render the same sentence a second time
  // (the "duplicates on the briefing page" bug). The UI hides an empty
  // breakdown, so the one-liner shows exactly once.
  return (oneLiner: one, breakdownMd: rest);
}

// ── the engine ────────────────────────────────────────────────────────────────

class BriefingEngine {
  final CoachConfig config;
  final LocalRepository repo;

  /// Test seam — production uses the shared CoachEngine BYOK call.
  final BriefingComplete? complete;

  BriefingEngine({required this.config, required this.repo, this.complete});

  bool get configured => complete != null || config.configured;

  /// Generate (or re-generate) the briefing for [period] today, cache it, and
  /// return it. Throws [CoachException] on provider errors / missing key.
  Future<Briefing> generate(BriefingPeriod period, {DateTime? now}) async {
    if (!configured) {
      throw CoachException('Add your AI key to enable briefings.');
    }
    // One effective timestamp for the whole generation, so the day snapshot,
    // greeting and generatedAt can't straddle midnight / a greeting boundary.
    final effectiveNow = now ?? DateTime.now();
    final day = todayLabel(effectiveNow);
    final tod = partOfDay(effectiveNow);
    final inputs = await collectBriefingInputs(repo, period, now: effectiveNow);
    // NOTHING TO SAY IS AN ANSWER. The evening sweep hands back an empty map on
    // any day where nothing was unusual for this user, which is most days. No
    // model is called — there is no question to ask — so nothing leaves the
    // device, and the "what was sent" screen has an empty payload to show
    // because the payload really was empty.
    if (period == BriefingPeriod.evening && inputs.isEmpty) {
      final b = Briefing(
        day: day,
        period: period,
        oneLiner: kNothingStoodOut,
        breakdownMd: '',
        generatedAtMs: effectiveNow.millisecondsSinceEpoch,
        inputs: const {},
      );
      BriefingStore.write(b);
      return b;
    }
    final raw = await (complete ??
        (({required String system, required String user}) =>
            CoachEngine.completeText(
                config: config, system: system, user: user)))(
      system: briefingSystemPrompt(period),
      user: buildBriefingUserPrompt(period, day, inputs, tod),
    );
    if (raw.trim().isEmpty) {
      throw CoachException('Empty response from provider.');
    }
    final parsed = parseBriefingResponse(raw);
    final b = Briefing(
      day: day,
      period: period,
      oneLiner: parsed.oneLiner,
      breakdownMd: parsed.breakdownMd,
      generatedAtMs: effectiveNow.millisecondsSinceEpoch,
      inputs: inputs,
    );
    BriefingStore.write(b);
    return b;
  }
}
