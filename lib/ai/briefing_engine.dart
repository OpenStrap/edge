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

import '../coach/coach_config.dart';
import '../coach/coach_engine.dart';
import '../data/day_label.dart';
import '../data/local_repository.dart';
import 'briefing.dart';

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

  if (period == BriefingPeriod.morning) {
    _put(out, 'readiness', _metricNum(daily['readiness']), round: 0);
    _put(out, 'resting_hr', _metricNum(daily['resting_hr']), round: 0);
    final hrv = _map(t['hrv']);
    _put(out, 'hrv_rmssd', _num(hrv?['rmssd']), round: 1);

    // The overnight bundle Today is showing (may be yesterday's sleep if this
    // day hasn't derived yet) — same source of truth as the Sleep screen.
    final status = _map(t['status']);
    final sleepDay =
        (status?['overnight_day'] as String?) ?? todayLabel(now);
    try {
      final ds = await repo.getDaySleep(sleepDay);
      if (ds['has_sleep'] == true || _num(ds['duration_min']) != null) {
        _put(out, 'sleep_min', _num(ds['duration_min']), round: 0);
        final eff = _num(ds['efficiency']);
        _put(out, 'sleep_efficiency_pct',
            eff == null ? null : (eff <= 1 ? eff * 100 : eff),
            round: 0);
        _put(out, 'sleep_debt_min', _num(ds['debt_min']), round: 0);
        _put(out, 'deep_min', _num(ds['deep_min']), round: 0);
        _put(out, 'rem_min', _num(ds['rem_min']), round: 0);
        _put(out, 'awake_min', _num(ds['awake_min']), round: 0);
        final onset = _num(ds['onset_ts'])?.toInt();
        final wake = _num(ds['wake_ts'])?.toInt();
        if (onset != null && onset > 0) {
          out['bedtime'] = _hhmm(
              DateTime.fromMillisecondsSinceEpoch(onset * 1000));
        }
        if (wake != null && wake > 0) {
          out['wake_time'] =
              _hhmm(DateTime.fromMillisecondsSinceEpoch(wake * 1000));
        }
      }
    } catch (_) {/* sleep detail absent → morning runs on the daily scalars */}
  } else {
    _put(out, 'strain_0_21', _metricNum(daily['strain']), round: 1);
    _put(out, 'steps', _metricNum(daily['steps']), round: 0);
    _put(out, 'step_goal', _num(t['step_goal']), round: 0);
    _put(out, 'calories_total_kcal', _metricNum(daily['calories_total']),
        round: 0);
    _put(out, 'wear_min', _metricNum(daily['wear_min']), round: 0);
    final stress = _map(t['stress']);
    _put(out, 'stress_0_100', _metricNum(stress?['score'] ?? stress?['value']),
        round: 0);

    // Today's workouts (manual + auto-detected, manual wins) — compact lines.
    try {
      final dayStart = now ?? DateTime.now();
      final startSec = DateTime(dayStart.year, dayStart.month, dayStart.day)
              .millisecondsSinceEpoch ~/
          1000;
      final sessions = await repo.getSessions(from: startSec);
      final w = <String>[];
      for (final s in sessions) {
        final st = _num(s['start_ts'])?.toInt();
        if (st == null || st < startSec) continue;
        final en = _num(s['end_ts'])?.toInt();
        final durMin = _num(s['duration_min'])?.round() ??
            (en != null ? ((en - st) / 60).round() : null);
        final type = (s['type'] ?? s['sport'] ?? s['label'] ?? 'workout')
            .toString();
        w.add(durMin == null ? type : '$type ${durMin}min');
        if (w.length >= 5) break;
      }
      if (w.isNotEmpty) out['workouts'] = w;
    } catch (_) {/* sessions unavailable → recap runs on the daily scalars */}
  }
  return out;
}

// ── prompt building (PURE — unit-tested on sample data) ───────────────────────

String briefingSystemPrompt(BriefingPeriod period) {
  final scope = period == BriefingPeriod.morning
      ? 'last night\'s sleep and this morning\'s recovery, and what they mean '
          'for the day ahead'
      : 'today\'s activity, strain and stress, and how the day landed';
  return 'You write the ${period.id} health briefing for a local-first fitness '
      'band app. Summarize $scope.\n'
      'HARD RULES:\n'
      '- Use ONLY the numbers provided. Never invent, estimate or mention a '
      'metric that is not in the data. No medical advice or diagnosis.\n'
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
) {
  final b = StringBuffer()
    ..writeln(period == BriefingPeriod.morning
        ? 'Morning briefing for $day. Overnight data:'
        : 'Evening recap for $day. Today\'s data so far:');
  if (inputs.isEmpty) {
    b.writeln('(no metrics available yet)');
  } else {
    inputs.forEach((k, v) {
      b.writeln(v is List ? '$k: ${v.join(', ')}' : '$k: $v');
    });
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
  if (rest.isEmpty) rest = '- $one';
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
    final day = todayLabel(now);
    final inputs = await collectBriefingInputs(repo, period, now: now);
    final raw = await (complete ??
        (({required String system, required String user}) =>
            CoachEngine.completeText(
                config: config, system: system, user: user)))(
      system: briefingSystemPrompt(period),
      user: buildBriefingUserPrompt(period, day, inputs),
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
      generatedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      inputs: inputs,
    );
    BriefingStore.write(b);
    return b;
  }
}
