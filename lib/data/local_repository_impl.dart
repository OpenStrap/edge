// LocalRepositoryImpl — serves the UI from the PRECOMPUTED derived store.
//
// ZERO heavy compute on read: every method reads day_result / metric_series
// rows (written by the DerivationEngine) and shapes them into the exact Map/List
// blobs the existing screens expect (the shapes the old cloud ApiClient returned,
// parsed by lib/models/payloads.dart + metric.dart).
//
// Metric envelopes: the onehz `Metric.toJson()` already emits
//   {value, confidence, tier, inputs_used, [note, drivers]}
// which Metric.parse (Case A) reads directly. Where a screen wants a bare scalar
// + a `flags` blob (Case B), we project the same fields into a flags entry.
//
// Honesty: a metric whose value is absent stays absent ("—"); we never fabricate.
// Profile-gated metrics are null when the profile field is missing.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import '../compute/derivation_engine.dart';
import '../compute/hr_max.dart';
import '../compute/manual_session.dart';
import '../compute/onehz_pipeline.dart' show kUnknownAbsenceNote, needInputNote;
import '../compute/profile.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:openstrap_analytics/onehz.dart' as ana;

import 'day_label.dart';
import 'db.dart';
import '../health/health_export.dart';
import 'journal_fields.dart';
import 'local_repository.dart';
import 'series_codec.dart';
import '../gps/route_models.dart';
import '../gps/route_math.dart' as rmath;

class LocalRepositoryImpl extends LocalRepository {
  LocalRepositoryImpl({required this.getProfileMap, this.saveProfileFields});

  /// Reads the live AppState profile map (age/weight/height/sex/step_goal…).
  final Map<String, dynamic>? Function() getProfileMap;

  /// Merges a patch into the stored profile and returns the new map — i.e.
  /// `AppState.updateProfile`, which is the only writer of that map.
  ///
  /// NULL in a process that has no AppState (the iOS background task), and a
  /// write there FAILS rather than returning a map nobody stored. That is the
  /// whole P2 bug: [setStepGoal] used to build the merged map, return it, and
  /// persist nothing — so the coach's `set_step_goal` reported success to the
  /// user on every call and the goal never moved off 8 000.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  saveProfileFields;

  // ── helpers ────────────────────────────────────────────────────────────────

  /// Decode a day_result row's payload bundle (latest algo_version), or null.
  Future<Map<String, dynamic>?> _bundle(String date) async {
    final row = await LocalDb.dayResult(date);
    if (row == null) return null;
    return _decode(row['payload_json']);
  }

  /// The most-recent COMPLETE derived day to show on Today. With the calendar-day
  /// model "today" starts empty at midnight and only gains sleep/recovery once
  /// tonight's sleep is recorded — so a partial today must NOT blank the screen.
  /// We walk newest→oldest and PREFER the latest day that actually has SLEEP (the
  /// recovery/sleep headline), i.e. "show me last night's sleep + latest
  /// recovery". Fallbacks, in order: latest day with sleep → latest day with any
  /// scalars → newest decodable → null. This is what makes Today show yesterday's
  /// data when today hasn't filled yet (and the day-detail seams inherit it).
  Future<Map<String, dynamic>?> _latestBundle() async {
    final rows = await LocalDb.recentDayResults(14);
    Map<String, dynamic>? newest, withScalars;
    for (final row in rows) {
      final b = _decode(row['payload_json']);
      if (b == null) continue;
      newest ??= b;
      if (b['skipped'] == true) continue;
      final scalars = b['scalars'];
      if (scalars is Map && scalars.isNotEmpty) withScalars ??= b;
      if (_bundleHasSleep(b)) return b; // latest COMPLETE day wins
    }
    return withScalars ?? newest;
  }

  /// True when a bundle carries a real sleep (single-source accounting present).
  bool _bundleHasSleep(Map<String, dynamic> b) {
    final acc = ((b['sleep'] as Map?)?['accounting'] as Map?)?['value'];
    return acc is Map && acc['tst_sec'] != null;
  }

  /// The cross-day analytics rollup bundle (from the `crossday` baseline), or
  /// null when none has been computed yet OR when the stored one is no longer
  /// safe to show ([crossDayStaleReason]).
  ///
  /// The gate lives HERE and not in `getInsights`, because five other seams on
  /// this class read the same artifact (`getDayHeart`, the sleep-debt block,
  /// the load block …). Gating one caller would have left the other five
  /// serving the numbers the gate exists to withhold.
  Future<Map<String, dynamic>?> _crossDay() async {
    final a = await _crossDayArtifact();
    if (a == null) return null;
    return crossDayStaleReason(a, _todayLocalLabel()) == null ? a : null;
  }

  /// The stored artifact, UNGATED — only `_crossDay` and `getInsights` may
  /// read this, and only so `getInsights` can report why it withheld it.
  Future<Map<String, dynamic>?> _crossDayArtifact() async {
    final r = await LocalDb.baseline('crossday');
    return _decode(r?['payload_json']);
  }

  Future<Map<String, dynamic>?> _freshness(String key) async {
    final row = await LocalDb.computeFreshness(key);
    return _decode(row?['payload_json']);
  }

  Future<Map<String, dynamic>?> _wakeFeatures(String dayId) async {
    final row = await LocalDb.wakeDayFeatures(dayId, kAlgoVersion);
    return _decode(row?['payload_json']);
  }

  String _todayLocalLabel() => LocalDb.localDayLabelNow();

  /// True when [date] is today's LOCAL day label (the key the day model files
  /// everything under) — the only case where a missing derived row should fall
  /// back to the latest complete day. The screens pass `todayLabel()` for the
  /// Today tab; historical drill-downs pass an exact past date, which must
  /// NEVER fall back (else every empty day renders the latest day's data — the
  /// "stage minutes show the latest night" bug).
  bool _isTodayLabel(String date) => date == todayLabel();

  /// The bundle for a requested date: the exact day's row, or — only for the
  /// Today request — the latest complete day. A historical date with no row
  /// returns null (→ the caller's honest empty shape), not the latest.
  Future<Map<String, dynamic>?> _bundleForDate(String date) async =>
      await _bundle(date) ??
      (_isTodayLabel(date) ? await _latestBundle() : null);

  /// THE read seam for the compact curve format: every bundle this class serves
  /// comes through here, so downstream readers keep seeing plain [{t,v}] lists
  /// and none of them has to know the wire format exists.
  ///
  /// Safe on the non-day_result payloads that also use it (baselines,
  /// freshness, wake features): SeriesCodec only rewrites keys already in
  /// grid/offset shape, which nothing but `putDayResult` ever writes.
  static Map<String, dynamic>? _decode(Object? json) =>
      SeriesCodec.decodePayloadJson(json);

  /// Pull a sub-map by dotted path (e.g. 'clinical.hrv_time').
  Map<String, dynamic>? _sub(Map<String, dynamic>? b, String path) {
    var cur = b;
    for (final part in path.split('.')) {
      final next = cur?[part];
      cur = next is Map ? next.cast<String, dynamic>() : null;
      if (cur == null) return null;
    }
    return cur;
  }

  num? _scalar(Map<String, dynamic>? b, String key) {
    final s = _sub(b, 'scalars');
    final v = s?[key];
    return v is num ? v : null;
  }

  /// Round a display value to 2dp without upgrading an int to a double —
  /// used where a raw analytics metric (e.g. round6()'d lf_hf) would
  /// otherwise render with far more precision than its sibling scalars.
  num? _round2(num? v) => v == null ? null : num.parse(v.toStringAsFixed(2));

  /// A bare metric from a scalar (used where a screen reads a number directly).
  /// An optional [note] (e.g. a `need_baseline:…` string) is carried through so
  /// the UI can render "Need N more nights" for baseline-gated abstentions.
  /// [note] is attached ONLY when there is no value — a note on a number that
  /// arrived is an explanation of an absence that did not happen, and callers
  /// that pass one unconditionally would otherwise ship it.
  Map<String, dynamic> _scalarMetric(
    num? v,
    String tier, {
    String? unit,
    String? note,
  }) => {
    'value': v ?? '—',
    'confidence': v == null ? 0 : 0.8,
    'tier': tier,
    'inputs_used': const [],
    'unit': ?unit,
    if (v == null) 'note': ?note,
  };

  /// The `note` string of a metric envelope at [path] (e.g.
  /// 'clinical.readiness_composite'), or null. Used to surface the
  /// `need_baseline:have=H,need=N` convention to the UI.
  String? _needNote(Map<String, dynamic>? b, String path) {
    final env = _sub(b, path);
    final note = env?['note'];
    return note is String ? note : null;
  }

  /// WHY the bare-valued figure [key] is absent on this bundle, from the
  /// pipeline's `absent_notes` block (onehz_pipeline.dart / the engine's
  /// `_applyWakeDayFeatures`). Null when that figure is present.
  ///
  /// `strain`, `calories`, `calories_total`, `zones` and `max_hr_used` are
  /// stored as bare values, so there is no envelope on them to carry a tier and
  /// a note. The reason was computed correctly at the gate and then thrown away
  /// before it reached anyone: the only place `unknown_device_family:id=none`
  /// was written was onto `daytime_hrv` and `hr_ceiling`, which no screen that
  /// renders these reads. The screens guessed instead, and the guesses were
  /// wrong. This is the route back.
  String? _absentNote(Map<String, dynamic>? b, String key) {
    final n = _sub(b, 'absent_notes')?[key];
    if (n is String && n.isNotEmpty) return n;
    // An IMPORTED day carries only what the export file carried, and no gate in
    // this app ever ran on it — there is no raw to re-derive from, so this is
    // not a wait-and-it-fills absence. The payload says so itself
    // (`LocalDb.isMeasuredDayRow` reads the same flag), so this is a fact about
    // the row, not a plausible reason invented for it. Measured: 284 of
    // whoop-5's 287 days are this, and every activity slot on all of them went
    // absent with nothing to say.
    if (b?['imported'] == true) return needInputNote('imported_day');
    return null;
  }

  /// An ABSENT metric envelope carrying only its tier and the reason it is
  /// absent — for a payload whose value key is a bare scalar the UI already
  /// reads. `Metric.parse` reads this shape directly, so a screen gets
  /// `isEmpty == true` plus a `note` it can render instead of guessing.
  Map<String, dynamic>? _absentMetric(String? note, String tier) =>
      note == null ? null : _scalarMetric(null, tier, note: note);

  // ── profile ─────────────────────────────────────────────────────────────────
  // The profile lives in AppState (shared_preferences); AppState.updateProfile
  // is the writer. Here we just surface it / accept patches via the same map.

  @override
  Future<Map<String, dynamic>> getProfile() async {
    final p = getProfileMap() ?? const {};
    return {
      ...p,
      'step_goal': (p['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal,
    };
  }

  /// Persist the daily step goal.
  ///
  /// [goal] arrives from a caller that may be an LLM (the coach's
  /// `set_step_goal`), so it is bounded here rather than trusted: a step goal
  /// is a target a person walks to, and a four-digit typo would sit on Home
  /// forever with no screen to correct it. The steps detail screen's
  /// `_StepGoalGauge` (metric_detail.dart) writes the same field directly
  /// through `AppState.updateProfile` with the same bound, rather than
  /// through this method.
  @override
  Future<Map<String, dynamic>> setStepGoal(int goal) async {
    if (goal < 500 || goal > 100000) {
      throw RepositoryException(400, 'A step goal of $goal is not a real one.');
    }
    final save = saveProfileFields;
    if (save == null) {
      throw RepositoryException(500, 'This process cannot change the profile.');
    }
    return save({'step_goal': goal});
  }

  // ── today ─────────────────────────────────────────────────────────────────
  // Shape per lib/models/payloads.dart TodayData: {daily:{…}, sleep:{…},
  // nocturnal:{…}, resp:{…}, hrv:{…}, skin_temp:{…}, step_goal}.

  @override
  Future<Map<String, dynamic>> getToday() async {
    // Refresh when the row is missing OR when its `today_day` is no longer the
    // real local day. The row is stamped by the last derive, so an app left
    // running over midnight (band on the charger, or an imported-only user)
    // kept serving yesterday's finished bundle as today: yesterday's steps,
    // kcal and strain on Home, yesterday's date in the greeting, and the
    // frozen headline matching so the readiness went un-flagged too.
    var todayFresh = await _freshness('today');
    if (todayFresh == null ||
        todayFresh['today_day']?.toString() != _todayLocalLabel()) {
      await LocalDb.refreshComputeFreshness();
      todayFresh = await _freshness('today');
    }
    final todayDay = todayFresh?['today_day']?.toString() ?? _todayLocalLabel();
    final todayBundle = await _bundle(todayDay);
    final overnightBundle = await _latestBundle();
    final overnightState =
        todayFresh?['overnight_state']?.toString() ?? 'missing';
    final activityState =
        todayFresh?['activity_state']?.toString() ?? 'missing';
    final showingPriorOvernight =
        todayFresh?['showing_prior_overnight'] == true;
    final showOvernight = overnightState == 'ready' || showingPriorOvernight;
    final sleepBundle = showOvernight ? overnightBundle : null;
    final activityBundle = activityState == 'ready' ? todayBundle : null;
    final wakeFeatures = activityState == 'ready'
        ? null
        : await _wakeFeatures(todayDay);
    final b = sleepBundle ?? activityBundle;
    if (b == null && wakeFeatures == null) {
      return {
        'daily': const {},
        'sleep': const {},
        'status': {
          'today_day': todayDay,
          'overnight_state': overnightState,
          'activity_state': activityState,
        },
        'step_goal': await _stepGoal(),
      };
    }
    final clinical = sleepBundle == null
        ? const <String, dynamic>{}
        : (_sub(sleepBundle, 'clinical') ?? const <String, dynamic>{});
    final cd = await _crossDay();

    final hrvTime = clinical['hrv_time'] is Map
        ? (clinical['hrv_time'] as Map).cast<String, dynamic>()
        : null;
    final rhrEnv = clinical['resting_hr'] is Map
        ? (clinical['resting_hr'] as Map).cast<String, dynamic>()
        : null;

    final rmssd = showOvernight ? _scalar(sleepBundle, 'rmssd') : null;
    // Readiness/recovery: when the composite abstains for lack of baseline, the
    // envelope carries a `need_baseline:have=H,need=N` note. Pass that note
    // through so the hero can render "Need N more nights" instead of a number.
    var readinessScalar = showOvernight
        ? _scalar(sleepBundle, 'readiness')
        : null;
    // FROZEN MORNING HEADLINE (#128): once today's overnight first settled on a
    // genuinely complete night, the derive pinned that readiness. Surface the
    // pin so the hero + once-a-morning recovery story stop drifting as the day's
    // re-derives (more daytime data, a shifting baseline) move the live scalar.
    // ONLY the headline is pinned — every other metric below still reflects the
    // latest re-derive. Gated to today's OWN overnight (`ready`, matching day)
    // so a prior-night fallback or a stale yesterday pin can never leak in.
    if (overnightState == 'ready') {
      final pin = await LocalDb.frozenHeadline();
      if (pin != null && pin.day == todayDay) {
        readinessScalar = pin.value.toDouble();
      }
    }
    // Everything on the overnight side of Home is absent for ONE reason when
    // there is no night to read: there is no scored night. Said once here so
    // readiness and resting HR stop going absent with nothing at all — measured
    // on whoop-5, where they are two of the eight dashes on a Home built over
    // 287 days of history.
    final overnightNote = showOvernight ? null : needInputNote('scored_night');
    final readinessNote = readinessScalar == null && showOvernight
        ? _needNote(sleepBundle, 'clinical.readiness_composite') ??
              kUnknownAbsenceNote
        : overnightNote;
    final readinessMetric = _scalarMetric(
      readinessScalar,
      'HIGH',
      note: readinessNote,
    );
    // WHY an absent activity figure is absent, from whichever source Home is
    // reading it from. The derived day and the interim wake features both carry
    // the same `absent_notes` map (the engine writes one and persists the
    // other), so Home does not have to know which one answered.
    //
    // When NEITHER exists there is no gate to name — the day simply has no
    // activity yet — and that is its own cause, not an unknown one. Home used
    // to render five bare dashes there (strain, calories, calories_total,
    // steps, wear) with no tier and no note at all.
    // `_scalarMetric` drops the note when a value arrived, so this can answer
    // unconditionally. The floor is "we do not know", never a plausible guess:
    // `steps` and `wear_min` have no gate that names itself, so an absent one
    // says exactly that rather than borrowing the strain gate's reason.
    String activityNote(String key) {
      if (activityBundle == null && wakeFeatures == null) {
        return needInputNote('today_activity');
      }
      if (activityBundle != null) {
        return _absentNote(activityBundle, key) ?? kUnknownAbsenceNote;
      }
      final n = (wakeFeatures?['absent_notes'] as Map?)?[key];
      return n is String && n.isNotEmpty ? n : kUnknownAbsenceNote;
    }

    final daily = <String, dynamic>{
      'readiness': readinessMetric,
      'recovery': readinessMetric,
      'resting_hr': _scalarMetric(
        showOvernight ? _scalar(sleepBundle, 'rhr')?.round() : null,
        'HIGH',
        unit: 'bpm',
        // There IS a night bundle and still no resting HR — the pipeline says
        // why (no scored sleep, or no clean 30-min window inside one), so read
        // its reason instead of shipping `unknown_cause` beside a card that
        // just lost a number it used to show.
        note: overnightNote ??
            _needNote(sleepBundle, 'clinical.resting_hr') ??
            kUnknownAbsenceNote,
      ),
      // Headline 0–21 strain (the strain gauge already expects a 0–21 scale).
      'strain': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['strain'] as num?)?.toDouble()
            : _scalar(activityBundle, 'strain'),
        'ESTIMATE',
        note: activityNote('strain'),
      ),
      'wear_min': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['wear_min'] as num?)?.toDouble()
            : _wearMin(activityBundle),
        'HIGH',
        unit: 'min',
        note: activityNote('wear_min'),
      ),
      // Active calories (Keytel HR→kcal over the wake span) + total daily energy
      // (TDEE: Mifflin BMR floor + active surplus).
      'calories': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['calories'] as num?)?.round()
            : _scalar(activityBundle, 'calories')?.round(),
        'ESTIMATE',
        unit: 'kcal',
        note: activityNote('calories'),
      ),
      'calories_total': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['calories_total'] as num?)?.round()
            : _scalar(activityBundle, 'calories_total')?.round(),
        'ESTIMATE',
        unit: 'kcal',
        note: activityNote('calories_total'),
      ),
      // STEPS — real 100 Hz count (streamed time) + 1 Hz walking estimate for the
      // rest; the derivation combines them and avoids double-counting.
      'steps': _scalarMetric(
        activityBundle == null
            ? (wakeFeatures?['steps'] as num?)?.round()
            : _scalar(activityBundle, 'steps')?.round(),
        'ESTIMATE',
        unit: 'steps',
        note: activityNote('steps'),
      ),
    };

    final hrv = rmssd == null
        ? null
        : {
            'rmssd': rmssd,
            'sdnn': _scalar(b, 'sdnn'),
            // Same baseline getDayHeart emits. Without it TodayData.hrv.baseline
            // was always null, WidgetService pushed -1, and the HRV ring on the
            // widget and the Watch could never fill on any day.
            'baseline': (await _seriesMean('rmssd'))?.round(),
            'confidence': (hrvTime?['confidence'] as num?) ?? 0.5,
          };

    return {
      'daily': daily,
      'sleep': sleepBundle == null
          ? const {}
          : _sleepSummary(sleepBundle, needMin: _sleepNeedMin(cd)),
      if (sleepBundle != null && rhrEnv != null)
        'nocturnal': _nocturnal(
          sleepBundle,
          baselineRhr: await _seriesMean('rhr'),
        ),
      // No `resp['rsa'] is Map` gate. `getDayLungs` never had one, so Health →
      // Overview could say "no respiratory rate" on a day whose Vitals tab
      // printed 14.2 br/min from the same bundle through the same function.
      // The rsa sub-block only supplies a confidence — `_respObj` already
      // returns null when there is no `resp_rate` scalar, which is the real
      // condition, and it falls back to 0.5 when rsa is missing.
      if (sleepBundle != null) 'resp': ?_respObj(sleepBundle),
      'hrv': hrv,
      'skin_temp': sleepBundle != null
          ? await _skinTempBlock(sleepBundle)
          : const {'value': null},
      // Stress (Baevsky SI → 0–100 score block) + relative SpO₂ (desat index),
      // both emitted by the pipeline. The Today tiles + stress screen read these.
      // No imputation: stressSummaryForToday returns the SI block verbatim (null
      // when absent), so the Today tile shows "—" whenever the real SI abstained.
      // The old `100 - readiness` fallback that fabricated a number was removed.
      if (sleepBundle != null)
        'stress': ?stressSummaryForToday(
          sleepBundle,
          _scalar(sleepBundle, 'readiness'),
        ),
      if (sleepBundle != null && sleepBundle['spo2'] is Map)
        'spo2': sleepBundle['spo2'],
      if (activityBundle != null && activityBundle['activity'] is Map)
        'activity': activityBundle['activity'],
      if (activityBundle == null && wakeFeatures?['activity'] is Map)
        'activity': (wakeFeatures!['activity'] as Map).cast<String, dynamic>(),
      // Cross-day rollup surfaced on Today (present only when computed).
      'illness': cd?['illness'],
      'anomaly': cd?['anomaly'],
      // Today's strain target, in the shape CoachData reads. Absent until
      // `strainTarget` has a recovery value, which the surfaces already handle.
      'coach': coachToday(cd),
      'load': cd?['load'],
      'readiness_breakdown': cd?['readiness_glassbox'],
      'regularity': cd?['regularity'],
      'status': {
        'today_day': todayDay,
        'activity_state': activityState,
        'activity_day': todayFresh?['activity_day'],
        'activity_computed_at': todayFresh?['activity_computed_at'],
        'overnight_state': overnightState,
        'overnight_day': todayFresh?['overnight_day'],
        'overnight_computed_at': todayFresh?['overnight_computed_at'],
        'showing_prior_overnight':
            todayFresh?['showing_prior_overnight'] == true,
      },
      'step_goal': await _stepGoal(),
    };
  }

  /// How long a stored `crossday` rollup may outlive the day it was built for.
  ///
  /// The cross-day families are multi-day by construction — chronotype, social
  /// jetlag, CTL/ATL/TSB — so yesterday's rollup is still the honest answer at
  /// 07:00 before today's first derive pass. What is NOT honest is a rollup
  /// from a fortnight ago: its own "today" row is a fortnight old, and Home's
  /// readiness drivers would be describing a night the user has forgotten.
  static const int crossDayMaxAgeDays = 7;

  /// Why a stored `crossday` artifact must not be shown, or null when it may.
  ///
  /// Pure, so it is testable without a database — the seam that consumes it
  /// ([getInsights]) cannot be.
  ///
  /// `getInsights` used to return `LocalDb.baseline('crossday')` VERBATIM. No
  /// screen prints the artifact's date, so a rollup written weeks ago under an
  /// older algo version rendered every readiness driver, the whole breakdown,
  /// tonight's need/bedtime/debt, chronotype, jetlag, regularity and
  /// CTL/ATL/TSB with nothing on screen to say so. `_wakeFeatures`, twenty
  /// lines below, has always keyed its read on `kAlgoVersion`; this is that
  /// gate, for the artifact behind four screens.
  ///
  /// A version bump that CHANGES THE BUNDLE SHAPE is the sharp case: the
  /// pre-bump artifact would be served for the rest of the day, so the new
  /// family silently sees nothing on the very pass the bump existed to
  /// trigger. That has already been a live bug on the input side — see
  /// `DerivationEngine.crossDayArtifactUsableToday`.
  ///
  /// An UNSTAMPED artifact cannot be SHOWN to be fresh, so it is refused
  /// rather than assumed fresh. That is the same call the input side makes,
  /// and it costs one derive pass to heal.
  static Map<String, dynamic>? crossDayStaleReason(
    Map<String, dynamic> artifact,
    String today,
  ) {
    final v = (artifact['algo_version'] as num?)?.toInt();
    if (v != kAlgoVersion) {
      return {'kind': 'algo_version', 'algo_version': ?v};
    }
    final built = artifact['built_for_day'];
    final age = built is String ? _dayGap(built, today) : null;
    if (built is! String || built.isEmpty || age == null) {
      return const {'kind': 'unstamped'};
    }
    // `age.abs()`: a NEGATIVE gap means the artifact claims a day in the
    // future, which is a clock that moved backwards, not freshness.
    if (age.abs() > crossDayMaxAgeDays) {
      return {'kind': 'stale', 'built_for_day': built, 'age_days': age};
    }
    return null;
  }

  /// Whole calendar days from [from] to [to], both 'YYYY-MM-DD'. Normalised to
  /// UTC midnight first: a local-midnight subtraction across a DST boundary is
  /// 23 or 25 hours, and `inDays` truncates the short one to zero.
  static int? _dayGap(String from, String to) {
    final a = DateTime.tryParse(from), b = DateTime.tryParse(to);
    if (a == null || b == null) return null;
    return DateTime.utc(
      b.year,
      b.month,
      b.day,
    ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
  }

  @override
  Future<Map<String, dynamic>> getInsights() async {
    final cd = await _crossDayArtifact();
    if (cd == null) return const {};
    final stale = crossDayStaleReason(cd, _todayLocalLabel());
    // FAIL CLOSED. Returning the reason INSTEAD of the artifact means every
    // `insights['readiness_glassbox']` read comes back absent — the state the
    // screens already render honestly — while `stale` carries why, in the
    // spirit of `need_baseline:have=H,need=N`. Serving the old numbers with no
    // marker was the bug.
    return stale == null ? cd : {'stale': stale};
  }

  Future<int> _stepGoal() async =>
      (getProfileMap()?['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal;

  num? _wearMin(Map<String, dynamic> b) {
    // Wear = RECORD presence (the band logs 1 Hz to flash ONLY while worn), NOT
    // hr_valid/60. HR only locks when still (mostly sleep), so hr_valid collapsed
    // wear to ~half a day — the "wore it all day, shows half" bug, on BOTH
    // platforms. Prefer the engine wear block's record-presence worn_min; fall
    // back to the TOTAL record count (hr_samples, not hr_valid); never hr_valid.
    // Mirrors getDayWear so the summary tile and the wear detail agree.
    final w = b['wear'] is Map
        ? (b['wear'] as Map).cast<String, dynamic>()
        : null;
    final fromBlock = (w?['worn_min'] as num?);
    if (fromBlock != null) return fromBlock;
    // The scalar step getDayWear has. Without it an imported day (scalars.worn_min,
    // no wear/coverage block) showed a wear figure on Vitals and nothing at all in
    // today.daily.wear_min — same stored number, two answers.
    final scalar = (_sub(b, 'scalars')?['worn_min'] as num?);
    if (scalar != null) return scalar;
    final cov = _sub(b, 'coverage');
    final total = (cov?['hr_samples'] as num?)?.toInt();
    return total == null ? null : (total / 60).round();
  }

  /// Tonight's LEARNED sleep need, in minutes, or null.
  ///
  /// `sleep_coach.need` is the only sleep need this app has: `crossday_pipeline`
  /// estimates it from the user's own undisturbed nights and emits an ABSENT
  /// metric until enough of them exist — there is no 8 h default anywhere on
  /// the compute side, deliberately. The 480 that used to stand in for it here
  /// reached the home widget, the Watch and the Sleep screen as a denominator.
  int? _sleepNeedMin(Map<String, dynamic>? crossDay) {
    final sec = _sub(crossDay, 'sleep_coach.need.value')?['need_sec'] as num?;
    return sec == null ? null : (sec / 60).round();
  }

  Map<String, dynamic> _sleepSummary(Map<String, dynamic> b, {int? needMin}) {
    // sleep.accounting is a Metric envelope {value:{tst_sec,…}, confidence,…} —
    // read the inner `.value`, not the envelope (the fields live one level down).
    final acct = _sub(b, 'sleep.accounting.value');
    final tst = (acct?['tst_sec'] as num?);
    final eff = (acct?['efficiency_pct'] as num?);
    if (tst == null) return const {};
    return {
      'duration_min': _scalarMetric(
        (tst / 60).round(),
        'ESTIMATE',
        unit: 'min',
      ),
      // Sleep need, ONLY when it was learned (see [_sleepNeedMin]). Absent means
      // the key is not written at all, so `TodayData.sleepNeed` is empty and
      // `WidgetService.push` writes the -1 sentinel every native reader gates
      // its sleep ring on (`needMin > 0` in OpenStrapWidget.swift,
      // WatchMetrics.swift and OpenStrapWidgetProvider.kt). A hard 480 here put
      // a fabricated 8 h denominator on the lock screen and the wrist, where
      // the phone's own screens refuse to show one.
      if (needMin != null)
        'need_min': _scalarMetric(needMin, 'ESTIMATE', unit: 'min'),
      'efficiency': _scalarMetric(eff, 'ESTIMATE', unit: '%'),
    };
  }

  Map<String, dynamic> _nocturnal(Map<String, dynamic> b, {num? baselineRhr}) {
    final rhr = _scalar(b, 'rhr'); // sleeping-HR avg (low30 mean)
    final dip = _scalar(b, 'dip_pct');
    final nadir = _scalar(b, 'sleeping_hr_nadir'); // lowest sleeping HR
    final waking = _scalar(b, 'waking_hr'); // waking-span mean HR
    // vs baseline: tonight's sleeping HR minus the personal rhr baseline. Null
    // (→ "Need N nights") until a baseline exists; never fabricated.
    final vsBase = (rhr != null && baselineRhr != null)
        ? (rhr - baselineRhr)
        : null;
    // Elevated sleeping HR = ≥ baseline + 4 bpm (calcNocturnalHeart rule); false
    // until a baseline exists.
    final elevated =
        (rhr != null && baselineRhr != null) && rhr >= baselineRhr + 4;
    // KEY NAMES must match what the screens read: sleep_detail + detail_cards
    // use sleeping_hr_min / day_hr_avg / vs_baseline_bpm / nadir_ts / elevated.
    return {
      'sleeping_hr_avg': rhr?.round(),
      'sleeping_hr_min': nadir?.round(),
      'day_hr_avg': waking?.round(),
      'vs_baseline_bpm': vsBase == null
          ? null
          : double.parse(vsBase.toStringAsFixed(1)),
      'dip_pct': dip == null ? null : dip / 100.0,
      'nadir_ts': _scalar(b, 'sleeping_hr_nadir_ts')?.toInt(),
      'elevated': elevated,
    };
  }

  /// The respiratory-rate envelope, INCLUDING the analytics note when the
  /// estimator abstained.
  ///
  /// `respiration.rsa` is a full envelope and it already says exactly why there
  /// is no number — "too few beats for an RSA spectral estimate (need ≥20)",
  /// "artifact fraction 0.31 > gate 0.15", "no stable HF respiratory peak
  /// resolved", "HF peak unstable across spectral resolutions". This used to
  /// read that envelope for its confidence and throw the note away, returning
  /// a bare null, so the screen fell back to a written-in-the-UI guess about
  /// noisy beat timing — which is one of four possible reasons and was picked
  /// by a human writing copy, not by the estimator.
  ///
  /// Carrying the note through costs nothing and is the difference between
  /// telling someone why their night produced no number and guessing at it.
  Map<String, dynamic>? _respObj(Map<String, dynamic> b) {
    final rr = _scalar(b, 'resp_rate');
    final env = _sub(b, 'respiration.rsa');
    if (rr == null) {
      final note = env?['note']?.toString();
      return note == null || note.isEmpty
          ? null
          : {'value': null, 'note': note};
    }
    // Round to 1 dp — the raw double (16.0121312…) was overflowing the card.
    return {
      'value': double.parse(rr.toStringAsFixed(1)),
      'confidence': (env?['confidence'] as num?) ?? 0.5,
    };
  }

  /// Relative skin-temp deviation block. Present once a value exists; otherwise
  /// a `need_baseline:have=H,need=3` note so the card shows "Need N more nights"
  /// instead of a bare "—" (skin-temp z needs ≥3 nights of ADC baseline).
  Future<Map<String, dynamic>> _skinTempBlock(Map<String, dynamic> b) async {
    final z = _scalar(b, 'skin_temp_z');
    if (z != null) {
      // The ENVELOPE, not a bare `{'value': z}`. `Metric.isEmpty` is
      // `value == null || confidence <= 0`, so a block with no confidence read
      // as ABSENT on every consumer: the Vitals row printed a real deviation
      // and dotted it "Not measured", and `MetricDetail('skin_temp')` was
      // permanently empty. The pipeline already carries the right envelope —
      // tier RELATIVE, and the note that says why there is no °C figure.
      final env = _sub(b, 'wellness.skin_temp');
      return {
        'value': z,
        'confidence': (env?['confidence'] as num?) ?? 0.5,
        'tier': (env?['tier'] as String?) ?? ana.Tier.relative,
        'inputs_used': env?['inputs_used'] ?? const ['skin_temp_raw'],
        'note': ?env?['note'],
      };
    }
    final have = (await LocalDb.metricSeries('skin_temp_adc')).length;
    return {'value': null, 'note': 'need_baseline:have=$have,need=3'};
  }

  // ── day drill-downs ─────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final hrCurve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];
    final rmssd = _scalar(b, 'rmssd');
    final cd = await _crossDay();
    return {
      'hr': hrCurve, // [{t, v}] — detail_cards reads e['v']
      'resting_hr': _scalar(b, 'rhr')?.round(),
      'recovery': _scalar(b, 'readiness'),
      'avg_hr': _avgHr(hrCurve),
      'max_hr': _maxHr(hrCurve),
      'hrv': {
        if (rmssd != null) 'rmssd': rmssd.round(),
        'sdnn': _scalar(b, 'sdnn')?.round(),
        'baseline': (await _seriesMean('rmssd'))?.round(),
        // HRV stability (CV %) + LF/HF — both now computed.
        'cv': _sub(b, 'clinical')?['cv'],
        // Rounded to 2dp for display — the raw clinical metric is round6()'d
        // in analytics, which read as a raw-looking "0.354402" next to the
        // whole-number RMSSD/SDNN beside it. Only consumer is this HRV group
        // (detail_cards.dart HeartDayContent), so rounding at the source here
        // is safe.
        'lf_hf': _round2(_sub(b, 'clinical.hrv_freq.value')?['lf_hf'] as num?),
      },
      // Poincaré irregular-beat screen (sd1/sd2/flag/confidence).
      'irregular': _sub(b, 'clinical')?['irregular'],
      // 24/7 irregular-rhythm SCREEN over whole-day RR (the headline screen).
      'irregular_24h': _sub(b, 'clinical')?['irregular_24h'],
      // Breathing-rate variability (within-user trend).
      'brv': _sub(b, 'clinical')?['brv'],
      // Mean heart-rate recovery across the day's detected/saved bouts (bpm/60s).
      'hrr': _scalar(b, 'hrr_bpm'),
      // Winsorized-EWMA personal baselines (rhr/hrv/resp/skin_temp) — robust
      // center + spread + z + cold-start status for each.
      'baselines': b['baselines'],
      // Waking ultradian HRV timeline (RMSSD over the day, outside sleep).
      'daytime_hrv': b['daytime_hrv'],
      'nocturnal': _nocturnal(b, baselineRhr: await _seriesMean('rhr')),
      'resp': _respObj(b),
      // 'spo2' (oxygen dips) moved to _daySleep()/getDaySleep — it's an
      // overnight signal, grouped with the Sleep tab's nocturnal numbers now,
      // not shown on the Heart tab anymore.
      // Illness watch (CUSUM/NightSignal) — carries `note` (need_baseline) while
      // baseline is short, so the card can say "Need N more nights".
      'illness': cd?['illness'],
      'skin_temp': await _skinTempBlock(b),
    };
  }

  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    return {
      'timeline': (_sub(b, 'series')?['hrv_timeline'] as List?) ?? const [],
      'rmssd': _scalar(b, 'rmssd'),
      'sdnn': _scalar(b, 'sdnn'),
      'ln_rmssd': _scalar(b, 'ln_rmssd'),
      'baseline': await _seriesMean('rmssd'),
      'hrv_time': _sub(b, 'clinical.hrv_time'),
      'hrv_freq': _sub(b, 'clinical.hrv_freq'),
      'prsa_dc': _sub(b, 'clinical.prsa_dc'),
      'prsa_ac': _sub(b, 'clinical.prsa_ac'),
      // The SLEEP-window Poincaré screen — sd1/sd2/flag over the same beats
      // `getNightBeats` returns, which is what makes it legal to print these
      // two numbers beside that scatter. (`clinical.irregular_24h`, served by
      // `getDayHeart`, is the WHOLE-DAY screen and a different set of beats;
      // the two must never be mixed on one picture.)
      'irregular': _sub(b, 'clinical.irregular'),
      // Beats read, beats that survived correction, and the surviving fraction
      // — the denominator for everything above. Pure re-exposure of a block
      // already on the bundle in hand.
      'coverage': _sub(b, 'coverage'),
      // WHICH STRAP measured it. gen4 and gen5/MG do not read the same RMSSD
      // on the same person, so a screen that trends this across a band swap
      // has to be able to say so.
      'device_family': b['device_family'],
      // CV-06 — per-bin RMSSD across the night, plus `origin_ms`, the wall
      // clock its bin offsets are counted from. The pipeline has emitted this
      // envelope since v70 and nothing read it; pure re-exposure, no new
      // computation and no extra decode (it is on the bundle already in hand).
      'night_shape': b['hrv_night_shape'],
    };
  }

  /// The night's beats, corrected. See [LocalRepository.getNightBeats].
  ///
  /// Reads `window_json` — the small sibling column — rather than decoding the
  /// payload: the sleep window is the only thing needed to bound the query, and
  /// this is the one method on this class that goes back to the raw decoded
  /// store at all. `[onset_ms, offset_ms]` is exactly the span the pipeline
  /// sliced `sleepRrMs` from, so the count this returns matches the bundle's
  /// own `coverage.rr_beats` on a day whose raw survives.
  ///
  /// THE EXACT DAY, never the Today fallback: a scatter borrowed from another
  /// night and drawn under this night's date is the worst failure this screen
  /// has available to it.
  @override
  Future<({List<double> nn, int rawBeats, double cleanFraction})> getNightBeats(
      String date) async {
    const none = (nn: <double>[], rawBeats: 0, cleanFraction: 0.0);
    final row = await LocalDb.dayResult(date);
    final w = row == null ? null : jsonDecode(row['window_json'] as String? ?? '{}');
    if (w is! Map) return none;
    final on = w['onset_ms'] as num?, off = w['offset_ms'] as num?;
    if (on == null || off == null || off <= on) return none;
    // rr_ts_ms == rec_ts * 1000, so `rec_ts >= ceil(on/1000)` and
    // `rec_ts <= floor(off/1000)` is the same set of beats as bounding on
    // rr_ts_ms directly — no beat either side of the window sneaks in.
    final rows = await LocalDb.decodedRrByRecTsRange(
      fromRecTs: (on / 1000).ceil(),
      toRecTs: (off / 1000).floor(),
    );
    final ts = <double>[], rr = <double>[];
    for (final r in rows) {
      final t = r['rr_ts_ms'] as num?, v = r['rr_ms'] as num?;
      if (t == null || v == null) continue;
      ts.add(t.toDouble());
      rr.add(v.toDouble());
    }
    if (rr.length < 2) return none;
    final c = ana.correctRr(rr, rrTsMs: ts);
    return (nn: c.nn, rawBeats: rr.length, cleanFraction: c.cleanFraction);
  }

  @override
  Future<List<String>> availableDays() => LocalDb.availableDayIds();

  @override
  Future<Map<String, dynamic>> getDaySleep(String date) => _daySleep(date);

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) => _daySleep(date);

  Future<Map<String, dynamic>> _daySleep(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    // Each is a Metric envelope — read the inner `.value` where the fields live.
    final acct = _sub(b, 'sleep.accounting.value');
    final win = _sub(b, 'sleep.window.value');
    final tst = (acct?['tst_sec'] as num?);
    // Provenance of this day's sleep window: auto / auto_fallback / manual /
    // confirmed / none — drives the Sleep screen's confirm prompt + edit affordance.
    final sleepSource = (b['sleep_source'] as String?) ?? 'auto';
    if (tst == null) {
      // NO NIGHT SLEEP — but that is not the same as no sleep at all.
      //
      // A nap-only or night-shift day still has detected daytime periods, and
      // this early return used to drop them on the floor: the screen showed
      // "No sleep recorded for this night" while the very same nap was stored,
      // credited against sleep need, and drawn as a band on the Timeline.
      // Three surfaces, two answers.
      //
      // `has_sleep` stays FALSE — it means what it says, that there is no
      // NIGHT to render a hypnogram, stages or efficiency for, and inventing
      // one from a nap would be exactly the conflation this file avoids
      // elsewhere. The periods ride along so the screen can show what it does
      // know instead of claiming nothing happened.
      final napPeriods = _periodsWithMainStages(b, const {});
      if (napPeriods.isEmpty) {
        return {'has_sleep': false, 'sleep_source': sleepSource};
      }
      return {
        'has_sleep': false,
        'sleep_source': sleepSource,
        'periods': napPeriods,
        'total_asleep_min': _totalAsleepMin(b, napPeriods),
      };
    }
    final spt = (win?['spt_sec'] as num?);
    final waso = (acct?['waso_sec'] as num?);
    final effPct = (acct?['efficiency_pct'] as num?);
    num? sec(String k) =>
        (win?[k] as num?) == null ? null : ((win![k] as num) / 1000).round();
    // 4-class stage minutes straight from the single-source segmentation seconds
    // (Light + Deep == NREM). Deep is the LOW-CONFIDENCE HR-depth overlay.
    int? min(String k) {
      final v = acct?[k] as num?;
      return v == null ? null : (v / 60).round();
    }

    final needMin = _sleepNeedMin(await _crossDay());
    final sleepConf = _sub(b, 'sleep.accounting')?['confidence'] as num?;
    // Sleep periods (main + naps) for the periods screen. The main period is
    // enriched HERE with the hypnogram + stage minutes: derivation builds the
    // periods in a second isolate that never receives `series.hypnogram`, so
    // this is the first point where the whole bundle is in hand. Naps carry
    // neither by design — no stage claim is made for them.
    //
    // Naps carry their own confidence and the screen draws a ConfDot for any
    // period that has one, so omitting the main period's left the main card as
    // the ONLY one with no dot — reading as "unknown" for the best-evidenced
    // period on the screen. Stays null when accounting had no confidence,
    // which correctly draws nothing.
    final periods = _periodsWithMainStages(b, {
      'light_min': min('light_sec'),
      'deep_min': min('deep_sec'),
      'rem_min': min('rem_sec'),
      'nrem_min': min('nrem_sec'),
    }, mainConfidence: sleepConf);
    final night = <String, dynamic>{
      // Shape matches sleep_detail_screen's contract exactly.
      'has_sleep': true,
      'sleep_source': sleepSource,
      'duration_min': (tst / 60).round(),
      'in_bed_min': spt == null ? null : (spt / 60).round(),
      'awake_min': waso == null ? null : (waso / 60).round(),
      'efficiency': effPct == null ? null : effPct / 100.0, // screen wants 0..1
      'onset_ts': sec('onset_ms'),
      'wake_ts': sec('offset_ms'),
      // 4-class stage minutes: Awake / Light / Deep / REM. Light+Deep is the
      // legacy combined "Core" (nrem_min) kept for any reader that wants it.
      'light_min': min('light_sec'),
      'deep_min': min('deep_sec'),
      'rem_min': min('rem_sec'),
      'nrem_min': min('nrem_sec'),
      'stages_beta': true,
      // The 4-class stager is a low-confidence wrist ESTIMATE; Deep especially is
      // an unvalidated overlay. The screen badges the whole stage block honestly.
      'stages_confidence': sleepConf,
      'hypnogram': _hypnoPoints(b), // [{t, stage}] points the screen merges
      // The movement ribbon that goes UNDER the hypnogram, on the hypnogram's
      // own axis. 5-min mean-ENMO buckets over the same sleep window
      // (`derivation_engine._computeDayBlocks`, "Feature 6"), so a caller can
      // draw both against one x without resampling either: measured spans agree
      // to the bucket (1786480200→1786498200 against 1786480446→1786498206 on a
      // real night). `density` is 0..1, a RELATIVE amplitude index — it is not
      // a fraction of anything and never becomes a percentage.
      //
      // Absent, not empty, when the night produced none: buckets with no
      // present accel second are omitted by the producer (absent accel would
      // score ENMO 1.0 — maximal restlessness out of no data), and a day that
      // produced no map at all must not arrive as a flat calm night.
      'restlessness_map': ?b['restlessness_map'],
      // Charging inside this sleep window — {present:false}, or present with
      // minutes/spans/note. A battery-pack swap leaves the strap on the wrist,
      // so `wear` correctly reads "worn" through it and nothing else on this
      // screen can say so. The night is published normally and the caveat rides
      // with it; see `sleepChargingBlock` for why it has no confidence penalty.
      'charging': b['sleep_charging'],
      'nocturnal': _nocturnal(b, baselineRhr: await _seriesMean('rhr')),
      'resp': _respObj(b),
      // Oxygen dips (SpO2/ODI) — moved here from getDayHeart's payload: an
      // overnight signal belongs with the rest of this night's numbers, not
      // a general daytime heart metric. Pure re-exposure of the same bundle
      // field getDayHeart already read; no new computation.
      'spo2': b['spo2'],
      // Sleep need, and the debt against it — both only when the need was
      // actually learned (`sleep_coach.need`, see [_sleepNeedMin]; it is the
      // current personal estimate, and the artifact behind it is refused once
      // it is more than a week old). There is no 8 h default: it made the gauge
      // "always read", which is the point, since what it read was a population
      // figure presented as this user's own. Absent keys leave the gauge in its
      // honest empty state.
      'need_min': ?needMin,
      if (needMin != null)
        'debt_min': ((needMin - (tst / 60)).clamp(0, needMin)).round(),
      'regularity':
          null, // needs ≥several nights (honest null → "Need N nights")
      // Sleep periods (main + naps) for the periods screen. The main period is
      // enriched HERE with the hypnogram + stage minutes: derivation builds the
      // periods in a second isolate that never receives `series.hypnogram`, so
      // this is the first point where the whole bundle is in hand. Naps carry
      // neither by design — no stage claim is made for them.
      'periods': periods,
      // The hero total must equal the sum of the cards under it — a user can
      // add them up. `_boundedPeriod` can CORRECT a period on read (clamping a
      // duration to its own window, dropping a degenerate one), which makes the
      // stored total stale, so it is recomputed from what is actually
      // rendered. See [_totalAsleepMin] for why an absent stored total stays
      // absent rather than being recomputed into a confident number.
      'total_asleep_min': _totalAsleepMin(b, periods),
      // Sleep cycles — Rosenblum 2024 "fractal cycles" (HRV-adapted): peak-to-
      // peak of the smoothed per-minute RMSSD series (REM peaks / NREM troughs).
      'cycles': _sub(b, 'sleep')?['cycles'] ?? const [],
      'cycle_count': (_sub(b, 'sleep')?['cycle_count'] as num?)?.toInt() ?? 0,
      'cycles_mean_min': _cyclesMeanMin(b),
      // The graph plots the continuous z-RMSSD wave [{t,z}] — NOT the cycle spans.
      'cycle_series': _sub(b, 'sleep')?['cycle_series'] ?? const [],
      // Parallel 4-class AASM read (Cole–Kripke/DoG stager): SOL / REM-latency /
      // disturbances + stage minutes + hypnogram. ESTIMATE; the headline stages
      // above stay the single source. {present:false} when none qualifies.
      'advanced': b['advanced_sleep'],
      // Low-confidence WRIST orientation (gravity-tilt) during sleep — a body-
      // position PROXY, NOT supine/side/prone body position.
      'wrist_orientation': b['wrist_orientation'],
    };
    // NOTE: this used to re-map the periods here through
    // `sleepPeriodsForScreen` and overwrite `night['periods']`. That translator
    // read `start`/`end`/`asleep_min` -- the vocabulary the producer emitted
    // when this branch was written. Since #204 the producer emits
    // `onset_ts`/`wake_ts`/`duration_min` directly, and `_periodsWithMainStages`
    // (above) already attaches the hypnogram, stage minutes and the main
    // period's confidence, translating any legacy payload on read.
    //
    // Keeping the overwrite after that rebase would have read every period
    // under keys that no longer exist, produced an EMPTY list, and blanked the
    // whole screen -- main sleep included -- while the hero still showed a
    // total. One source per concern: the writer-side seam owns this now.
    return night;
  }

  /// The persisted sleep periods with the MAIN period's hypnogram and stage
  /// minutes attached.
  ///
  /// Naps are returned untouched: they have no stages, and inventing an empty
  /// stage map would make the card draw a stage bar for sleep we never
  /// classified. Absent stage minutes are dropped rather than zeroed for the
  /// same reason — `StageBars` renders 0 as an invisible gap, which reads as
  /// "no deep sleep" instead of "not measured".
  List<Map<String, dynamic>> _periodsWithMainStages(
    Map<String, dynamic> b,
    Map<String, int?> stageMin, {
    num? mainConfidence,
  }) {
    final raw = (b['sleep_periods'] as Map?)?['periods'];
    if (raw is! List) return const [];
    final hypno = _hypnoPoints(b);
    final stages = <String, dynamic>{
      for (final e in stageMin.entries)
        if (e.value != null) e.key: e.value,
    };
    return [
      for (final p in raw.whereType<Map>())
        if (_boundedPeriod(_canonicalPeriod(p)) case final bp?)
          if (bp['is_main'] != true)
            bp
          else
            {
              ...bp,
              if (hypno.isNotEmpty) 'hypnogram': hypno,
              if (stages.isNotEmpty) 'stages': stages,
              'confidence': ?mainConfidence,
            },
    ];
  }

  /// Reads a persisted period under EITHER key vocabulary.
  ///
  /// The producer emits `onset_ts`/`wake_ts`/`duration_min`, but day results
  /// written before that change hold `start`/`end`/`asleep_min` and are never
  /// rewritten: a day finalizes ~48 h behind the data edge and raw is pruned
  /// after `rawRetentionDays`, so once its substrate is gone a kAlgoVersion
  /// bump cannot re-derive it — the old payload is what that day will serve
  /// forever. Without this the Sleep-periods cards for every such day render
  /// "—" for onset, wake AND duration, underneath a hero total that is still
  /// confident, which reads as data loss rather than an old schema.
  ///
  /// Translating on READ (rather than migrating on write) also means this and
  /// the parallel fix at the other end of the seam are order-independent.
  Map<String, dynamic> _canonicalPeriod(Map p) {
    final m = p.cast<String, dynamic>();
    // Fill only keys that are genuinely ABSENT — `containsKey`, never a null
    // check. A current-schema key present with an explicit null is an honest
    // "we did not measure this", and a null test cannot tell that apart from a
    // missing key. On a mixed payload (`duration_min: null` sitting alongside a
    // stale `asleep_min: 40`) a null test promotes an unknown into a
    // measurement — the precise dishonesty this seam exists to remove.
    //
    // A period already speaking the current vocabulary passes through
    // byte-for-byte either way.
    return {
      ...m,
      if (!m.containsKey('onset_ts') && m['start'] != null)
        'onset_ts': m['start'],
      if (!m.containsKey('wake_ts') && m['end'] != null) 'wake_ts': m['end'],
      if (!m.containsKey('duration_min') && m['asleep_min'] != null)
        'duration_min': m['asleep_min'],
    };
  }

  /// A period's reported asleep minutes can never exceed its own window.
  ///
  /// Ported from #205, which added it at the (now-removed) screen-side
  /// translator. It is a real invariant and belongs here, at the one seam the
  /// screen reads: `duration_min` and the window come from different producers
  /// (staging TST vs the detected bounds), so nothing else stops a card
  /// claiming more sleep than the period it sits in. Clamped, not dropped —
  /// the window is the trustworthy half.
  ///
  /// Returns null for a period with no usable window at all, so the caller can
  /// drop it rather than render a zero-length card.
  Map<String, dynamic>? _boundedPeriod(Map<String, dynamic> m) {
    final onset = (m['onset_ts'] as num?)?.toInt();
    final wake = (m['wake_ts'] as num?)?.toInt();
    if (onset == null || wake == null || wake <= onset) {
      // Keep it only if it carries no window claim at all; a period whose
      // window is present but degenerate is junk.
      return (onset == null && wake == null) ? m : null;
    }
    final windowMin = ((wake - onset) / 60).round();
    final dur = (m['duration_min'] as num?)?.toInt();
    if (dur == null || (dur >= 0 && dur <= windowMin)) return m;
    // NEGATIVE is not "too small", it is CORRUPT — there is no such thing as
    // minus fifty minutes of sleep. It is dropped to unknown rather than
    // clamped to either end: clamping UP to the window would invent a full
    // night out of garbage, and clamping DOWN to 0 would state "you did not
    // sleep", which is a measurement we do not have. Unknown then propagates
    // through `_totalAsleepMin`, so the hero reads "—" instead of a total
    // built on a value we know is nonsense.
    if (dur < 0) return {...m, 'duration_min': null};
    return {...m, 'duration_min': windowMin};
  }

  /// The day's total asleep minutes, consistent with the cards on screen.
  ///
  /// ABSENT STAYS ABSENT. A null stored total means the producer could not
  /// state one — most often because nap detection abstained, so the day holds
  /// an unknown NUMBER of unmeasured naps (see `_sleepPeriods`). Recomputing a
  /// sum from the periods we happen to have would turn that honest "—" into a
  /// confident figure that silently omits them, which is the exact claim the
  /// producer refused to make.
  ///
  /// Otherwise the total is recomputed from the RENDERED periods rather than
  /// trusted verbatim, because `_boundedPeriod` may have corrected one on read
  /// and the stored sum would then be stale — leaving the hero disagreeing with
  /// the cards a user can add up. A period whose own duration is unknown makes
  /// the sum unknown again, for the same reason it does at the writer.
  num? _totalAsleepMin(
    Map<String, dynamic> b,
    List<Map<String, dynamic>> periods,
  ) {
    final stored = (b['sleep_periods'] as Map?)?['total_asleep_min'];
    if (stored == null) return null;
    var sum = 0;
    for (final p in periods) {
      final d = (p['duration_min'] as num?)?.toInt();
      if (d == null) return null;
      sum += d;
    }
    return sum;
  }

  /// Mean completed-cycle length (min), or null when no cycles.
  num? _cyclesMeanMin(Map<String, dynamic> b) {
    final cyc = _sub(b, 'sleep')?['cycles'];
    if (cyc is! List || cyc.isEmpty) return null;
    var sum = 0.0;
    for (final c in cyc) {
      sum += ((c as Map)['len_min'] as num?)?.toDouble() ?? 0;
    }
    return (sum / cyc.length).round();
  }

  /// The bundle stores the hypnogram as segments {start,end,stage} (epoch sec);
  /// the detail screen wants per-point {t,stage} and re-merges them. Emit one
  /// point per segment boundary plus a closing point so the last stage has width.
  List<Map<String, dynamic>> _hypnoPoints(Map<String, dynamic> b) {
    final segs = (_sub(b, 'series')?['hypnogram'] as List?) ?? const [];
    final out = <Map<String, dynamic>>[];
    for (final s in segs) {
      if (s is Map && s['start'] != null && s['stage'] != null) {
        out.add({'t': s['start'], 'stage': s['stage']});
      }
    }
    final last = segs.isNotEmpty ? segs.last : null;
    if (last is Map && last['end'] != null && last['stage'] != null) {
      out.add({'t': last['end'], 'stage': last['stage']});
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>> getDayLungs(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final sleepWin = _sub(b, 'sleep.window.value');
    return {
      'resp': _respObj(b),
      'cvhr': _sub(b, 'respiration.cvhr_apnea'),
      'spo2': b['spo2'], // relative desaturation screen; never an absolute %
      'sleep_window': {
        'start': (sleepWin?['onset_ms'] as num?) == null
            ? null
            : ((sleepWin!['onset_ms'] as num) / 1000).round(),
        'end': (sleepWin?['offset_ms'] as num?) == null
            ? null
            : ((sleepWin!['offset_ms'] as num) / 1000).round(),
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final cov = _sub(b, 'coverage');
    final hrSamples = (cov?['hr_samples'] as num?)?.toInt();
    // Wear block (on/off segments, first/last on, longest off) computed in the
    // engine; fall back to the coverage counts when absent.
    final w = b['wear'] is Map
        ? (b['wear'] as Map).cast<String, dynamic>()
        : null;
    // MISSING IS NOT ZERO. This used to collapse "we never measured wear" into
    // `worn_min: 0` via `hr_samples ?? 0`, which an imported day (no `wear`
    // block, no `coverage` block) hits every time — making it byte-identical to
    // a day the strap genuinely sat in a drawer, so the screen asserted "Not
    // worn on this day — no wrist contact was recorded" about data it simply
    // never had. Resolution order is now: engine wear block, then the day's
    // own `worn_min` scalar, then the coverage record count, then absent.
    final scalarWornMin = (_sub(b, 'scalars')?['worn_min'] as num?)?.toInt();
    final wornMin =
        (w?['worn_min'] as num?)?.toInt() ??
        scalarWornMin ??
        (hrSamples == null ? null : (hrSamples / 60).round());
    return {
      // Wear = RECORD presence, not valid HR (HR drops out during daytime
      // motion). Fall back to the total record count, never hr_valid.
      'worn_min': wornMin,
      // MISSING IS NOT 100% either. This used to read `hrSamples > 0 ? 100 : 0`,
      // so one HR sample claimed the band was worn for the whole day and the
      // row printed "Wear time 20m · 100% of the day". The engine wear block is
      // the only thing that measures coverage; without it we say nothing.
      'coverage_pct': (w?['coverage_pct'] as num?)?.toInt(),
      // AND MISSING IS NOT "NEVER OFF". Same rule as the two fields above, and
      // the same day hits it: an imported day has no `wear` block, and an empty
      // segment list there is not "we looked and the band was never off" — it
      // is "we never looked". A renderer cannot tell those apart from `[]`, so
      // the key is absent instead.
      //
      // The segments themselves are `{on, start, end, len_min}` over the
      // OBSERVABLE day (local midnight → now, or → next midnight once the day
      // is done), which is what makes them renderable as "your band was off
      // your wrist 11:20 PM – 2:14 AM": the leading and trailing holes are on
      // the list now, so a day whose records start at 9am shows the 00:00-09:00
      // gap instead of opening the timeline at the first record and implying
      // the night before it never existed. `sum(on) / observable` is exactly
      // `coverage_pct`, so the ribbon and the percentage cannot disagree.
      'segments': ?w?['segments'],
      'first_on': w?['first_on'],
      'last_on': w?['last_on'],
      'longest_off_min': w?['longest_off_min'],
      'hourly': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async {
    // THE EXACT DAY, never the latest-complete fallback: this list is editable,
    // and offering "not a nap" against another day's naps would write an edit
    // onto a day the user was not looking at.
    final b = await _bundle(date);
    final block = _sub(b, 'naps');
    if (block == null) return const {};
    final v = block['value'];
    return {
      // ABSENT ≠ NONE. `value: null` is "this day could not be judged" — too
      // little 1 Hz data, or detection failed — and it carries its own note.
      // An empty list is the measured "no qualifying naps", which is a real
      // answer and reads as one.
      if (v is List)
        'naps': [
          for (final n in v)
            if (n is Map && n['start'] is num && n['end'] is num)
              {
                'start': (n['start'] as num).toInt(),
                'end': (n['end'] as num).toInt(),
                'duration_min': (n['duration_min'] as num?)?.round(),
                // 'manual' on a nap the user logged; absent on a detected one.
                if (n['source'] != null) 'source': n['source'].toString(),
              },
        ],
      'nap_min': (_sub(b, 'scalars')?['nap_min'] as num?)?.round(),
      'note': block['note']?.toString(),
    };
  }

  @override
  Future<Map<String, dynamic>> getDaySteps(String date) async {
    final r = await LocalDb.resolvedStepsForDay(date);
    // Only for naming: a span that sits inside a session gets that session's
    // name. Cheap — one indexed read over one day.
    final sessions = r.spans.isEmpty
        ? const <Map<String, dynamic>>[]
        : await LocalDb.sessionsInRange(
            _localMidnightSec(date),
            _localDayEndSec(date),
          );
    // THE EXACT DAY, never `_bundleForDate`'s latest-complete fallback: the
    // spans come from this date's coverage rows, and pairing them with another
    // day's published total is the one mismatch this screen must not show.
    final st = _sub(await _bundle(date), 'steps');
    return {
      'total': r.total,
      'strap': r.strap,
      'phone': r.phone,
      'day_total': (st?['value'] as num?)?.toInt(),
      'day_source': st?['source'] as String?,
      'note': st?['note'] as String?,
      'spans': [
        for (final s in r.spans)
          {
            'start_ts': s.startTs,
            'end_ts': s.endTs,
            'steps': s.steps,
            'source': s.fromBand
                ? LocalDb.kStepSourceBand
                : LocalDb.kStepSourcePhone,
            'activity': _sessionOver(sessions, s.startTs, s.endTs),
          },
      ],
    };
  }

  /// The session a step span sits inside, by type — or null.
  ///
  /// HALF THE SPAN OR MORE has to fall inside the session. Naming one is a
  /// claim about where those steps came from, and a walk that merely touches
  /// the end of a workout did not happen during it.
  String? _sessionOver(
    List<Map<String, dynamic>> sessions,
    int startTs,
    int endTs,
  ) {
    final dur = endTs - startTs;
    if (dur <= 0) return null;
    String? best;
    var bestOv = 0;
    for (final s in sessions) {
      final a = (s['start_ts'] as num?)?.toInt();
      final b = (s['end_ts'] as num?)?.toInt();
      final type = s['type'] as String?;
      if (a == null || b == null || type == null || type.isEmpty) continue;
      final ov = math.min<int>(endTs, b) - math.max<int>(startTs, a);
      if (ov > bestOv) {
        bestOv = ov;
        best = type;
      }
    }
    return bestOv * 2 >= dur ? best : null;
  }

  @override
  Future<Map<String, dynamic>> getDayStress(String date) async {
    // Stress = the pipeline's Baevsky Stress Index block (resting autonomic
    // tension; transparent RR-histogram metric → 0–100 score). No fallback: the
    // score stays null when the SI is absent, so the screen renders "—" (the old
    // `100 - readiness` imputation was removed). Nocturnal arousal isn't computed,
    // so `sleep_stress` is intentionally absent (the screen handles it).
    final b = await _bundleForDate(date);
    if (b == null) return const {};

    final stressBlk = b['stress'] is Map
        ? (b['stress'] as Map).cast<String, dynamic>()
        : null;
    num? score = (stressBlk?['score'] as num?);
    String? level = stressBlk?['level'] as String?;
    final si = (stressBlk?['si'] as num?);
    // NO fallback here. `100 - readiness` used to backfill a "stress" number
    // whenever the real Baevsky SI was absent — fabricating a score from an
    // unrelated metric, which violates the "absent input -> null, never
    // imputed" rule and is exactly why a user with no overnight SI could see
    // a confident-looking stress score anyway. `hasStress` downstream (see
    // stress_screen.dart) already gates the hero UI on `score is num`, so
    // leaving score/level null here correctly renders as "-".

    final lfHf =
        (stressBlk?['lf_hf'] as num?) ??
        (_sub(b, 'clinical.hrv_freq.value')?['lf_hf'] as num?);
    final rmssd = (stressBlk?['rmssd'] as num?) ?? _scalar(b, 'rmssd');
    final hrCurve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];

    // Drivers from the cross-day glass-box readiness, when present.
    final drivers = <Map<String, dynamic>>[];
    final cd = await _crossDay();
    final gb = cd?['readiness_glassbox'];
    final gbDrivers = gb is Map ? (gb['drivers'] as List?) : null;
    if (gbDrivers != null) {
      for (final d in gbDrivers) {
        if (d is Map) {
          final label = (d['label'] ?? '').toString();
          if (label.isEmpty) continue;
          drivers.add({
            'label': label,
            'detail': (d['detail'] ?? '').toString(),
          });
        }
      }
    }

    return {
      'stress': {
        'score': score,
        'si': si,
        'lf_hf': lfHf,
        'rmssd': rmssd,
        'level': level,
      },
      'hr': hrCurve,
      'drivers': drivers,
      // Nocturnal restlessness (movement fragmentation) + waking ultradian HRV,
      // both computed in the engine from accel / day-RR.
      'restlessness': b['restlessness'],
      'daytime_hrv': b['daytime_hrv'],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final zones = _sub(b, 'zones');
    final hrStats = _sub(b, 'hr_stats');
    final series = _sub(b, 'series');
    final curve = (series?['strain_curve'] as List?) ?? const [];
    final zoneTimeline = (series?['zone_timeline'] as List?) ?? const [];
    // EWMA-ACWR training load lives in the cross-day rollup (acute/chronic over a
    // history window); the strain detail's "Training load (ACWR)" row reads it.
    final cd = await _crossDay();
    // STEPS is a live-accumulating count, not a "show last settled day" metric —
    // unlike strain/zones/HR/curve above (where falling back to yesterday's
    // finished bundle via _bundleForDate is the correct "still settling" UX),
    // showing yesterday's step count as "today's steps" is actively wrong, not
    // just stale. When today's own row hasn't been derived yet, use today's
    // interim wake_day_features estimate instead of whatever _bundleForDate
    // fell back to (same source getToday() uses for the Today screen). This is
    // the settled BASE only — a caller showing live steps folds AppState.liveSteps
    // on top, the way Today composes base+live.
    num? stepsBase;
    if (_isTodayLabel(date) && await _bundle(date) == null) {
      final wf = await _wakeFeatures(date);
      stepsBase = wf?['steps'] as num?;
    } else {
      stepsBase = _scalar(b, 'steps');
    }
    // The five bare-valued figures, resolved once so the reason block below can
    // key off what this payload IS ABOUT TO SAY rather than re-deriving it.
    final strain = _scalar(b, 'strain');
    final trimp = _scalar(b, 'trimp');
    final calories = _scalar(b, 'calories')?.round();
    final caloriesTotal = _scalar(b, 'calories_total')?.round();
    final maxHrUsed = b['max_hr_used'] is num
        ? b['max_hr_used'] as num
        : _scalar(b, 'max_hr_used');
    final zoneMin = <String, int?>{
      for (var i = 1; i <= 5; i++) 'z$i': (zones?['z$i'] as num?)?.toInt(),
    };
    return {
      // Headline 0–21 strain (the detail screen clamps to 0..21). Raw Banister
      // TRIMP is kept as the secondary "training load" figure.
      'strain': strain,
      'training_load': trimp,
      'load': cd?['load'], // {acwr, acute, chronic, band} when ≥ history exists
      // HR-zone minutes (Z1–Z5 by %HRmax) — the zone bars. `?? 0` on all five
      // turned a day with no zone block into five confident 0-minute bars; a
      // day we never measured reads null so the caller can say nothing.
      'zones': zoneMin,
      'curve': [
        for (final p in curve.whereType<Map>()) {'t': p['t'], 'v': p['v']},
      ],
      'zone_timeline': [
        for (final p in zoneTimeline.whereType<Map>())
          {'t': p['t'], 'z': p['z']},
      ],
      'calories': calories,
      // Total daily energy (TDEE) + 24/7 step ESTIMATE (live pedometer tunes it).
      'calories_total': caloriesTotal,
      'steps': stepsBase?.round(),
      'hr': {
        'max': (hrStats?['max'] as num?)?.toInt(),
        'avg': (hrStats?['avg'] as num?)?.toInt(),
        'min': (hrStats?['min'] as num?)?.toInt(),
      },
      'max_hr_used': maxHrUsed,
      // TS-04 — which two numbers THIS day's zone bars were binned on:
      // 'karvonen' (observed ceiling + measured resting HR), 'observed'
      // (measured ceiling, resting-HR history still too short) or 'tanaka'
      // (the age estimate). Stored with the bins by the pipeline, so the bar's
      // footnote states what the bar IS rather than what it usually is.
      'zone_source': b['zone_source'],
      'zone_max_hr': (b['zone_max_hr'] as num?)?.round(),
      // The HEADLINE absence's reason, promoted to the top level because the
      // screen's primary content when there is no strain is a single card
      // explaining why. Same string as `absent.strain`.
      'note': strain == null ? _absentNote(b, 'strain') : null,
      // WHY each absent figure above is absent, keyed by that figure's OWN
      // name — never by a sibling's. Every entry is an absent Metric envelope
      // ({value:'—', confidence:0, tier, note}), so a screen can
      // `Metric.parse(strain['absent']?['calories'])` and render the real
      // reason. Entries exist ONLY for figures that are actually absent.
      //
      // This is the fix for a first-law violation: `strain`, `calories`,
      // `calories_total`, `zones` and `max_hr_used` went absent with no tier
      // and no note while the gate that killed them wrote its reason onto
      // `heart.daytime_hrv` and `hr_ceiling`, which this screen never reads. So
      // the screen guessed — "it needs a resting heart rate from a scored
      // night" on a day with a scored night, "add your age in Profile" on a
      // profile with an age. An honest-looking absence with a false cause and
      // an unactionable fix is worse than a bare dash.
      'absent': <String, Map<String, dynamic>>{
        // Keyed the way the VALUE above is keyed — `training_load` is what this
        // payload calls `trimp` — or the caller has to know both names.
        for (final e in <String, (bool, String)>{
          'strain': (strain == null, 'strain'),
          'training_load': (trimp == null, 'trimp'),
          'calories': (calories == null, 'calories'),
          'calories_total': (caloriesTotal == null, 'calories_total'),
          'zones': (zoneMin.values.every((v) => v == null), 'zones'),
          'max_hr_used': (maxHrUsed == null, 'max_hr_used'),
        }.entries)
          if (e.value.$1)
            e.key: ?_absentMetric(_absentNote(b, e.value.$2), 'ESTIMATE'),
      },
      'flags': const {},
    };
  }

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async {
    final b = await _bundleForDate(date);
    if (b == null) return const {};
    final hrCurve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];

    // Peak / lowest HR + their instants, from the day HR curve (seam-side; the
    // curve is what's stored, good enough for a daily overview + gives @time).
    num? peakV, lowV;
    int? peakT, lowT;
    for (final e in hrCurve) {
      if (e is! Map) continue;
      final v = e['v'] as num?;
      final t = (e['t'] as num?)?.toInt();
      if (v == null || t == null || v <= 0) continue;
      if (peakV == null || v > peakV) {
        peakV = v;
        peakT = t;
      }
      if (lowV == null || v < lowV) {
        lowV = v;
        lowT = t;
      }
    }

    // Day window from the BUNDLE's date (not the requested date) so hr/sleep/
    // segments stay consistent when a partial "today" falls back to the latest
    // complete day.
    final bundleDate = (b['date'] as String?) ?? date;
    final dayStart = _localMidnightSec(bundleDate);
    final dayEnd = _localDayEndSec(bundleDate);

    // Sleep span (onset/wake) for the context band + sleep symbol.
    final sw = _sub(b, 'sleep.window.value');
    final sleep = <Map<String, dynamic>>[];
    final onMs = sw?['onset_ms'] as num?;
    final offMs = sw?['offset_ms'] as num?;
    if (onMs != null && offMs != null) {
      sleep.add({
        'onset_ts': (onMs / 1000).round(),
        'wake_ts': (offMs / 1000).round(),
      });
    }

    // Workouts + device events for that calendar day.
    final sess = await LocalDb.sessionsInRange(dayStart, dayEnd);
    // Bounded BY THE DAY, in SQL. This used to pull `unuploadedEvents(limit:
    // 2000)` — `ORDER BY ts ASC LIMIT 2000`, i.e. the OLDEST 2000 rows — and
    // then filter that page down to this day. Once `events` held more than 2000
    // rows the page could no longer reach recent days at all, so their markers
    // silently vanished from the timeline (the same oldest-N-vs-trailing-N
    // shape as the metricSeries(limit:) outage).
    final dayEvents = await LocalDb.eventsInRange(dayStart, dayEnd);
    final events = <Map<String, dynamic>>[
      for (final e in dayEvents)
        {
          'event_id': (e['event_id'] as num?)?.toInt(),
          'ts': (e['ts'] as num?)?.toInt(),
        },
    ];

    // Daytime naps (principled detectNaps) as their own bands on the timeline.
    final napsVal = _sub(b, 'naps')?['value'];
    final naps = <Map<String, dynamic>>[
      if (napsVal is List)
        for (final nMap in napsVal)
          if (nMap is Map && nMap['start'] != null && nMap['end'] != null)
            {
              'start': (nMap['start'] as num).toInt(),
              'end': (nMap['end'] as num).toInt(),
              'duration_min': (nMap['duration_min'] as num?)?.toInt(),
            },
    ];

    // HRV line. Prefer the ALL-DAY series (`series.hrv_day`, 24/7); fall back to
    // the sleep-only `hrv_timeline`. BOTH are epoch seconds now — the sleep one
    // used to be seconds-from-window-start and was rebased here by adding the
    // sleep onset, which since `_hrvTimeline` started stamping `originMs + t`
    // would add the onset twice and throw the line hours off the axis.
    final series = _sub(b, 'series');
    final dayHrv = (series?['hrv_day'] as List?) ?? const [];
    final rawHrv = dayHrv.isNotEmpty
        ? dayHrv
        : ((series?['hrv_timeline'] as List?) ?? const []);
    var hrvLine = <Map<String, dynamic>>[
      for (final e in rawHrv)
        if (e is Map && e['t'] is num && e['v'] is num)
          {'t': (e['t'] as num).toInt(), 'v': e['v']},
    ];
    // Plausibility clip: RMSSD physiologically sits ~5–220 ms; values above are
    // ectopic/missed-beat artifacts (the 400+ ms spikes). Drop them so one bad
    // window can't flatten the whole line. Covers old data + the sleep fallback.
    hrvLine = [
      for (final e in hrvLine)
        if ((e['v'] as num) >= 5 && (e['v'] as num) <= 220) e,
    ];

    // Day HR average (from the curve) for the overview stats.
    num avgHr = 0;
    var nHr = 0;
    for (final e in hrCurve) {
      if (e is Map && e['v'] is num && (e['v'] as num) > 0) {
        avgHr += e['v'] as num;
        nHr++;
      }
    }

    // Respiratory rate (br/min) + relative skin-temp trend — all-day lines.
    final respLine = (series?['resp_day'] as List?) ?? const [];
    final tempLine = (series?['skin_temp_day'] as List?) ?? const [];

    return {
      'hr': hrCurve,
      'hrv': hrvLine,
      'resp': respLine,
      'skin_temp': tempLine,
      'activity': b['activity_curve'] ?? const [],
      // The DISPLAYED day (bundle date) — when a partial "today" fell back to
      // the latest complete day this differs from the requested date, and the
      // screen must window/axis by THIS date, not "now".
      'date': bundleDate,
      'day_start': dayStart,
      'highs': {
        if (peakV != null) 'peak_hr': {'v': peakV, 't': peakT},
        if (lowV != null) 'low_hr': {'v': lowV, 't': lowT},
        if (nHr > 0) 'avg_hr': {'v': (avgHr / nHr).round()},
      },
      'sleep': sleep,
      'naps': naps,
      'sessions': [for (final r in sess) _workoutOf(r)],
      'events': events,
    };
  }

  /// Local midnight (epoch sec) of a 'YYYY-MM-DD' date string.
  int _localMidnightSec(String ymd) => localDayStartSec(ymd) ?? 0;

  /// End of that local day (epoch sec) — the NEXT local midnight.
  ///
  /// NOT `_localMidnightSec(ymd) + 86400`: a spring-forward day is 23 h local
  /// and a fall-back day is 25 h, so the flat +86400 window pulled in an hour
  /// of the next day (or dropped the last hour) on exactly those two days a
  /// year. See day_label.dart.
  int _localDayEndSec(String ymd) => localDayEndSec(ymd) ?? 0;

  // ── lists / summaries ─────────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60}) async {
    final rows = await LocalDb.sleepWindowRows(days);
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final date = r['day_id'] as String?;
      if (date == null || date.isEmpty) continue;
      // `window_json` comes in TWO shapes and always has. The derivation
      // engine writes `SleepWindow.toJson()` — a BARE {onset_ms, offset_ms,
      // spt_sec} — and so do both importers; only this reader ever expected a
      // Metric envelope, so onset_ts/wake_ts were null for every night ever
      // stored and Sleep's "earlier/later than usual" row never appeared for
      // anyone. Take the envelope's `value` when there is one, else the map
      // itself. (`value` is the string '—' on a night with no sleep, so it
      // only counts when it is a Map.)
      Map<String, dynamic>? env;
      try {
        final decoded = jsonDecode((r['window_json'] as String?) ?? '{}');
        if (decoded is Map) env = decoded.cast<String, dynamic>();
      } catch (_) {
        env = null;
      }
      final v = env?['value'];
      final val = v is Map
          ? v.cast<String, dynamic>()
          : (env?['onset_ms'] != null || env?['offset_ms'] != null
                ? env
                : null);
      final onsetMs = (val?['onset_ms'] as num?)?.toDouble();
      final offsetMs = (val?['offset_ms'] as num?)?.toDouble();
      out.add({
        'date': date,
        'onset_ts': onsetMs == null ? null : (onsetMs / 1000).round(),
        'wake_ts': offsetMs == null ? null : (offsetMs / 1000).round(),
        'confidence': (env?['confidence'] as num?)?.toDouble(),
        'tier': env?['tier'] as String?,
      });
    }
    return out;
  }

  @override
  Future<List<Map<String, dynamic>>> getSessions({
    int? from,
    int? to,
    bool includeDetected = true,
  }) async {
    // The manual/live sessions table, newest first.
    final now = DateTime.now();
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    final fromSec =
        from ??
        now.subtract(const Duration(days: 31)).millisecondsSinceEpoch ~/ 1000;
    final toSec = to ?? nowSec;

    final manualRows = await LocalDb.sessionsInRange(fromSec, toSec);
    final manual = [for (final r in manualRows) _workoutOf(r)];

    // Manual/live sessions are ALL there is now. There used to be a second
    // half here: `detected_workouts` from each of the last 60 day bundles,
    // deduped against the saved spans. That key was a permanently-empty stub
    // and the derivation has since stopped writing it altogether (analytics
    // deleted `workout_detect.dart`), so the merge read every recent bundle —
    // SELECT r.*, the whole hr_curve/hypnogram/HRV payload through jsonDecode —
    // to append nothing. Auto-detected bouts reach the UI through
    // `workout_suggestions`, not through this list.
    //
    // [includeDetected] is kept because it is part of the repository interface
    // and callers pass it; there is simply no detected half left to exclude.
    manual.sort(
      (a, b) => ((b['start_ts'] as num?) ?? 0).compareTo(
        (a['start_ts'] as num?) ?? 0,
      ),
    );
    return manual;
  }

  // ── trends + records + charts ──────────────────────────────────────────────

  String _trendKey(String metric) {
    switch (metric) {
      case 'hrv':
        return 'rmssd';
      case 'recovery':
        return 'readiness';
      case 'resting_hr': // series key is `rhr`
        return 'rhr';
      case 'skin_temp': // series key is the relative z-score
        return 'skin_temp_z';
      case 'wear': // worn-minutes trend
        return 'worn_min';
      case 'efficiency': // sleep-efficiency % trend
        return 'efficiency';
      case 'steps': // measured band steps (the ambulatory-min × cadence
        // estimator this comment used to describe was deleted in v57)
        return 'steps';
      case 'light':
        return 'light_min';
      case 'deep':
        return 'deep_min';
      case 'rem':
        return 'rem_min';
      case 'tst':
      case 'sleep': // the Sleep screen's trend metric → time-asleep series
        return 'tst_min';
      case 'dip':
        return 'dip_pct';
      case 'hrr':
        return 'hrr_bpm';
      case 'brv':
        return 'brv_cv';
      // lf_hf, hrv_cv map to themselves (series keys match).
      default:
        return metric;
    }
  }

  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
  }) async {
    if (metric == 'hr') {
      // "Today's heart rate" card: the curve must be TODAY's. _latestBundle
      // falls back to the latest COMPLETE day, so its curve could be
      // yesterday's — drawn on a midnight→now axis it rendered a previous
      // day's line on today's timeline. Prefer today's own (partial) bundle,
      // then clip whatever we got to today's local-day window; an empty result
      // is the card's honest "No heart-rate data yet today" state.
      final today = _todayLocalLabel();
      final b = await _bundleForDate(today);
      final curve = (_sub(b, 'series')?['hr_curve'] as List?) ?? const [];
      final dayStart = _localMidnightSec(today);
      final dayEnd = _localDayEndSec(today);
      return {
        'points': [
          for (final e in curve)
            if (e is Map &&
                e['t'] is num &&
                (e['t'] as num) >= dayStart &&
                (e['t'] as num) < dayEnd)
              e,
        ],
      };
    }
    final key = _trendKey(metric);
    final rows = await LocalDb.metricSeries(key);
    // THE PIN WINS. getToday serves the frozen morning headline for readiness,
    // but metric_series is rewritten by every later re-derive of the same day —
    // which is the pin's whole reason for existing — so Readiness detail drew
    // 74 in the ring and 69 as today's point in the chart underneath it. One
    // day, one readiness number.
    final pin = key == 'readiness' ? await LocalDb.frozenHeadline() : null;
    return {
      'points': [
        for (final r in rows)
          {
            't': _dateToEpoch(r['date'] as String),
            'v': r['date'] == pin?.day ? pin!.value : r['value'],
          },
      ],
      // L4 — THE DENOMINATOR. Worn minutes for the same days, so a long trend
      // can be read against how much of it was actually measured instead of
      // being an attendance chart wearing a physiology label. Deliberately
      // unflattering: a month with four nights of wear should look like a month
      // with four nights of wear, not like a flat line.
      //
      // `worn_min` is a live metric_series key present every day, so this is the
      // same scan again, not a new store. Wear OLDER than the 3-day substrate
      // window is knowable ONLY through this derived key — nothing here
      // reconstructs it, and a day with no `worn_min` row is simply absent.
      'wear': [
        for (final r in await LocalDb.metricSeries('worn_min'))
          {'t': _dateToEpoch(r['date'] as String), 'v': r['value']},
      ],
      // L13 — WHERE THE MATHS CHANGED. The dates at which the algo version
      // behind these values differs from the day before it. This does NOT make
      // the values on either side comparable; nothing can (days lock ~48 h
      // after wake, and the substrate to re-derive them is gone at 3 days). It
      // makes the seam visible, so a change-point search refuses to run across
      // one instead of reporting the day of a version bump as a finding about
      // the user.
      'algo_breaks': await _algoBreaks(),
    };
  }

  /// Dates where `metric_series`'s algo version changes, with the versions on
  /// either side: `[{t, from, to}]`. The FIRST stamped day is not a break —
  /// there is nothing before it to be incomparable with.
  Future<List<Map<String, dynamic>>> _algoBreaks() async {
    final rows = await LocalDb.metricSeriesVersions();
    final out = <Map<String, dynamic>>[];
    int? prev;
    for (final r in rows) {
      final v = (r['algo_version'] as num?)?.toInt();
      if (v == null) continue;
      if (prev != null && v != prev) {
        out.add({
          't': _dateToEpoch(r['date'] as String),
          'from': prev,
          'to': v,
        });
      }
      prev = v;
    }
    return out;
  }

  int _dateToEpoch(String date) =>
      (DateTime.tryParse('$date 12:00:00')?.millisecondsSinceEpoch ?? 0) ~/
      1000;

  @override
  Future<Map<String, dynamic>> getRecords() async {
    // ONE INTEGER. The only caller is workout_screen's `_loadWorkoutData`,
    // which reads `['workouts_tracked']` and nothing else — and it awaits this
    // serially while the Workouts tab is opening.
    //
    // What used to be computed here and thrown away: `dayResultDayIdsDesc()`,
    // `daysWithSleepTst()` (json_valid + json_extract over every stored day
    // bundle), seven `metricSeries` scans for personal records, a
    // `recentDayResults(14)` bundle decode to check the resting-HR baseline's
    // trust status, two streak walks and the resting-HR drift. The screens that
    // displayed records and streaks are gone (see profile.dart), so every one
    // of those keys had zero consumers — and streaks are banned by this app's
    // own grammar anyway.
    //
    // The count itself is now done in SQL. It used to pull EVERY session row an
    // install had ever written — full payloads, sorted by start_ts — across the
    // platform channel to add up one integer, while the tab was opening.
    return {'workouts_tracked': await LocalDb.finishedSessionCount()};
  }

  // ── workouts (manual / live / auto) — local sessions store ──────────────────

  /// Shape one sessions-table row into the workout map the screens parse.
  /// start_ts/end_ts are epoch SECONDS; zone_min decodes the JSON list.
  Map<String, dynamic> _workoutOf(Map<String, dynamic> r) {
    final zoneMin = _decodeList(r['zone_min_json']);
    final type = (r['type'] as String?) ?? 'other';
    return {
      'id': r['id'],
      'start_ts': (r['start_ts'] as num?)?.toInt(),
      'end_ts': (r['end_ts'] as num?)?.toInt(),
      'status': r['status'],
      'type': type,
      'title': type,
      'strain': (r['strain'] as num?)?.toDouble(),
      'calories': (r['calories'] as num?)?.round(),
      'duration_min': (r['duration_min'] as num?)?.toInt(),
      'steps': (r['steps'] as num?)?.toInt(),
      'max_hr': (r['max_hr'] as num?)?.toInt(),
      // Mean HR over the whole session window, banked at score time so it
      // outlives the 3-day raw retention. `getWorkouts`/`getWorkout` still
      // recompute from the substrate while it exists and overwrite this; every
      // other caller (getSessions, getDayTimeline) now gets a REAL average
      // instead of nothing.
      'avg_hr': (r['avg_hr'] as num?)?.toInt(),
      // Heart-rate recovery (bpm drop in 60 s) backfilled during derivation.
      'hrr60': (r['hrr_bpm'] as num?)?.round(),
      'zone_min': zoneMin,
      // manual / auto — the detail screen shows the AUTO tag + correct-type CTA.
      'source': r['source'],
      // "Keep this one off the shared surfaces." NOT NULL DEFAULT 0 in the
      // schema, so a row that predates the column reads false, which is what it
      // has always meant.
      'private': (r['private'] as num?)?.toInt() == 1,
    };
  }

  List<dynamic> _decodeList(Object? json) {
    if (json is! String || json.isEmpty) return const [];
    try {
      final d = jsonDecode(json);
      return d is List ? d : const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async {
    final now = DateTime.now();
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    final fromTs = _rangeFromSec(range, now);
    final rows = await LocalDb.sessionsInRange(fromTs, nowSec);
    final workouts = [for (final r in rows) _workoutOf(r)];

    // Per-session HR aggregates from the 1 Hz substrate (one indexed join).
    // Sessions have no avg_hr column — without this every workout looked like
    // "no data" (avg_hr == 0) even when the window is full of worn HR.
    try {
      final age = _profileAge();
      final stats = await LocalDb.sessionHrStats(
        fromTs,
        nowSec,
        maxHrCeiling: hrCeilingForAge(age),
        minHrFloor: kHrFloorBpm,
      );
      // Spike-suppressed max/min per session (issue #127): smooth the raw 1 Hz
      // over one batched join so the list agrees with getWorkout's on-read
      // recompute.
      final rawBySession = await LocalDb.sessionHrSamplesBySession(
        fromTs,
        nowSec,
      );
      for (final w in workouts) {
        final s = stats[w['id']];
        final raw = rawBySession[w['id']];
        if (s != null && (s['n'] ?? 0) != 0) {
          w['avg_hr'] = (s['avg_hr'] as num).round();
        }
        // Peak: smoothed-from-raw (authoritative, matches the detail screen);
        // else stored column, else the ceiling-bounded SQL max.
        final smax = raw == null ? null : smoothedMaxHr(raw, age: age);
        if (smax != null) {
          w['max_hr'] = smax;
        } else if (s != null && (s['n'] ?? 0) != 0) {
          w['max_hr'] ??= (s['max_hr'] as num).toInt();
        }
        // Trough: same treatment. Raw pruned → the floor-bounded SQL min.
        final smin = raw == null ? null : smoothedMinHr(raw, age: age);
        if (smin != null) {
          w['min_hr'] = smin;
        } else if (s != null && (s['n'] ?? 0) != 0) {
          w['min_hr'] = (s['min_hr'] as num).toInt();
        }
      }
    } catch (_) {
      /* stats are an enrichment — the list still renders without them */
    }

    // Summary excludes live sessions (no final stats yet).
    final done = workouts.where((w) => w['status'] != 'live');
    var count = 0, totalMin = 0, totalCal = 0;
    final zoneSum = <num>[];
    for (final w in done) {
      count++;
      totalMin += (w['duration_min'] as int?) ?? 0;
      totalCal += (w['calories'] as int?) ?? 0;
      final zm = (w['zone_min'] as List?) ?? const [];
      for (var i = 0; i < zm.length; i++) {
        final v = (zm[i] as num?) ?? 0;
        if (i < zoneSum.length) {
          zoneSum[i] += v;
        } else {
          zoneSum.add(v);
        }
      }
    }
    return {
      'workouts': workouts,
      'summary': {
        'count': count,
        'total_min': totalMin,
        'total_calories': totalCal,
        'zone_min': zoneSum,
      },
    };
  }

  /// Epoch SECONDS lower bound for a range label. 'all' → 0.
  int _rangeFromSec(String range, DateTime now) {
    switch (range) {
      case 'all':
        return 0;
      case 'week':
        return now.subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/
            1000;
      case 'quarter':
      case '3m':
        return now.subtract(const Duration(days: 90)).millisecondsSinceEpoch ~/
            1000;
      case 'month':
      default:
        return now.subtract(const Duration(days: 31)).millisecondsSinceEpoch ~/
            1000;
    }
  }

  @override
  Future<Map<String, dynamic>> getWorkout(String id) async {
    final stored = await LocalDb.session(id);
    if (stored == null) return const {};
    // Reconcile the live tallies against the substrate BEFORE projecting the
    // row (issue #206) — a session the app slept through stores a strain built
    // from the few minutes it was awake for. Persists on improvement, so the
    // list and the share card see the corrected value too.
    final rescored = await _rescoreSessionFromSubstrate(stored);
    final w = _workoutOf(rescored.row);
    // TS-04 — whether `zone_min` below and the `zone_bands` added further down
    // describe the SAME zone set. They are recomputed from the current anchors
    // while the minutes can be a kept live split binned against an older
    // ceiling, and the detail card names the bands' ceiling under the minutes'
    // bars. False means it must not.
    w['zone_min_rebinned'] = rescored.zoneMinutesRebinned;
    final startTs = w['start_ts'] as int?;
    if (startTs == null) return w;
    final endTs =
        (w['end_ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (endTs <= startTs) return w;

    // Enrich from the 1 Hz substrate over the session window — the exact
    // approach getWorkoutRoute already uses. The detail/finish screens read
    // hr / avg_hr / min_hr / zone_bands / recovery_curve / hr_drift_pct /
    // time_to_peak_min; without a producer they were blank everywhere.
    try {
      // Reuse the rows the rescore above already read for this exact window
      // rather than scanning it a second time on every detail open.
      final hrRows =
          rescored.hrRows ?? await LocalDb.hrSamplesInRange(startTs, endTs);
      if (hrRows.isNotEmpty) {
        final ts = [for (final e in hrRows) (e['rec_ts'] as num).toInt()];
        final hr = [for (final e in hrRows) (e['hr'] as num).toInt()];
        w.addAll(_sessionTrace(ts, hr, startTs, endTs,
            rescored.row['device_family'] as String?, await _zoneAnchors()));
        final avg = hr.reduce((a, b) => a + b) / hr.length;
        w['avg_hr'] = avg.round();
        if (w['status'] == 'done') {
          final curve = await _recoveryCurve(endTs);
          if (curve.isNotEmpty) w['recovery_curve'] = curve;
        }
      } else {
        // THE SUBSTRATE IS GONE (pruned at `rawRetentionDays`), so serve the
        // trace frozen at score time. Without this, every session's chart half
        // — curve, zones, drift, time-to-peak, recovery — went blank on its
        // fourth day and stayed blank forever, while the summary scalars in
        // their own columns kept rendering. Nothing new is claimed here: these
        // are the numbers the app showed for the same session when it was two
        // days old.
        w.addAll(_frozenTrace(rescored.row));
      }
    } catch (_) {
      /* enrichment is best-effort — the summary scalars still render */
    }
    return w;
  }

  /// Everything the detail screen draws from a session's 1 Hz HR window, in one
  /// map — so [getWorkout] and the trace that outlives the substrate are
  /// produced by the SAME code and cannot drift apart.
  ///
  /// `trace_samples` / `trace_coverage_pct` ride along on both paths: 1 Hz means
  /// one sample per second, so the count against the window length is the
  /// honest coverage of these numbers. A session the band only partly handed
  /// over must read as partial rather than draw a confident thin line across a
  /// sync gap.
  Map<String, dynamic> _sessionTrace(
    List<int> ts,
    List<int> hr,
    int startTs,
    int endTs,
    String? deviceFamily,
    _ZoneAnchors anchors,
  ) {
    final w = <String, dynamic>{};
    w['hr'] = _minuteHrCurve(ts, hr);
    // Spike-suppressed trough (issue #127): a lone low PPG dropout must not
    // define the min, symmetric to the max recompute below.
    w['min_hr'] = smoothedMinHr(hr, age: _profileAge()) ?? hr.reduce(math.min);
    // Spike-suppressed peak (issue #127). RECOMPUTE from the smoothed raw —
    // do NOT floor against the stored column: the live path may already have
    // written a spiked max there, and math.max() would preserve it.
    final peakAt = smoothedMaxHrAt(hr, age: _profileAge());
    if (peakAt != null) {
      w['max_hr'] = peakAt.$1;
      w['time_to_peak_min'] = ((ts[peakAt.$2] - startTs) / 60).round();
    }
    w['zone_bands'] = _zoneBands(hr, deviceFamily, anchors);
    final drift = _hrDriftPct(ts, hr, startTs, endTs);
    if (drift != null) w['hr_drift_pct'] = drift;
    w['trace_samples'] = hr.length;
    final windowSec = endTs - startTs;
    if (windowSec > 0) {
      w['trace_coverage_pct'] = math.min(
        100,
        (hr.length / windowSec * 100).round(),
      );
    }
    return w;
  }

  /// The stored trace for a session whose substrate has aged out, decoded back
  /// into the same keys [_sessionTrace] produces. Empty when there is none —
  /// a session scored before this column existed has no trace and never will
  /// (those seconds are gone; nothing here backfills or guesses one).
  Map<String, dynamic> _frozenTrace(Map<String, dynamic> row) {
    final json = row['trace_json'];
    if (json is! String || json.isEmpty) return const {};
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return const {};
      final out = decoded.cast<String, dynamic>();
      // `hr` and `recovery_curve` are stored through SeriesCodec (the same
      // compact form day_result uses); everything else is a plain scalar.
      out['hr'] = SeriesCodec.decodeCurve(out['hr']) ?? const [];
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Freeze one session's trace for storage. Mirror of [_frozenTrace].
  String _encodeTrace(Map<String, dynamic> trace) =>
      jsonEncode({...trace, 'hr': SeriesCodec.encodeCurve(trace['hr'])});

  /// Minute-mean HR curve [{t, v}] (epoch sec at each minute start) from raw
  /// 1 Hz samples — the shape the detail chart parses.
  List<Map<String, num>> _minuteHrCurve(List<int> ts, List<int> hr) {
    final out = <Map<String, num>>[];
    var bucket = -1;
    var sum = 0;
    var n = 0;
    void emit() {
      if (n > 0) out.add({'t': bucket * 60, 'v': (sum / n).round()});
    }

    for (var i = 0; i < ts.length; i++) {
      final b = ts[i] ~/ 60;
      if (b != bucket) {
        emit();
        bucket = b;
        sum = 0;
        n = 0;
      }
      sum += hr[i];
      n++;
    }
    emit();
    return out;
  }

  /// Zone names. "Fat burn" was a substrate-utilisation claim on a band that
  /// measures heart rate. Z2 is an INTENSITY label; which fuel is being
  /// oxidised there needs respiratory exchange, which no wrist sensor produces
  /// (TS-04a). Never "aerobic threshold" either — a %HRR band is a convention,
  /// not a measurement of anyone's threshold.
  static const zoneNames = ['Warm-up', 'Easy', 'Aerobic', 'Threshold', 'Max effort'];

  /// Time-in-zone bands Z1..Z5 over the session's 1 Hz HR — the shape the zones
  /// card + summary bar parse.
  ///
  /// Banded on [trainingZones], the SAME set the day pipeline bins its own
  /// `zones` block with, so a session's bands and the day's bars can never come
  /// off different ceilings again (TS-03a) or different anchors (TS-04).
  List<Map<String, dynamic>> _zoneBands(
    List<int> hr,
    String? deviceFamily,
    _ZoneAnchors anchors,
  ) {
    final set = _zoneSetFor(deviceFamily, anchors);
    // No age, or a strap with no calibrated ceiling ⇒ no bands.
    if (set == null) return const [];
    final secs = List<int>.filled(5, 0);
    for (final v in hr) {
      final z = set.zoneNumber(v.toDouble());
      if (z >= 1) secs[z - 1]++;
    }
    final total = hr.length;
    return [
      for (var z = 0; z < 5; z++)
        {
          'zone': z + 1,
          'name': zoneNames[z],
          'lo': set.zones[z].lower.round(),
          'hi': set.zones[z].upper.round(),
          'min': double.parse((secs[z] / 60).toStringAsFixed(1)),
          'pct': total == 0 ? 0 : (secs[z] / total * 100).round(),
          'source': set.source,
        },
    ];
  }

  /// THE zone set for a window measured by [deviceFamily] — one call so every
  /// producer of a zone split in this file bands identically.
  ana.HeartRateZoneSet? _zoneSetFor(String? deviceFamily, _ZoneAnchors a) =>
      trainingZones(
        age: _profileAge(),
        deviceFamily: deviceFamily,
        observedCeilingBpm: a.observedCeilingBpm,
        restingHrHistory: a.restingHrHistory,
      );

  /// The two anchors [trainingZones] needs, read once per call chain.
  ///
  /// Both are cross-day reads, so a per-session recompute must not do them
  /// again for every row it touches.
  Future<_ZoneAnchors> _zoneAnchors() async {
    try {
      return _ZoneAnchors(
        observedCeilingBpm: (await _observedCeiling())?.bpm,
        restingHrHistory: await LocalDb.trailingSeriesValues('rhr', 28),
      );
    } catch (_) {
      return const _ZoneAnchors();
    }
  }

  /// TS-03 — the highest heart rate the band has ever OBSERVED on this user:
  /// the max of the per-day `hr_ceiling_bpm` series, with the day it happened
  /// and the session it came from.
  ///
  /// NOT a physiological HRmax. Every value in that series already passed the
  /// hold + corroborating-motion guard in `observed_max_hr.dart`; nothing here
  /// may take a max over un-guarded numbers (a raw `sessions.max_hr` max would
  /// be one PPG artifact away from dragging every zone boundary up forever).
  ///
  /// All-time, not a trailing window: this is "highest we've seen", and the
  /// date is rendered beside it so an old one is visible rather than anonymous.
  Future<_ObservedCeiling?> _observedCeiling() async {
    final top = await LocalDb.observedHrCeiling();
    if (top == null) return null;
    // The session + hold behind it live in that day's own bundle envelope —
    // one extra day read, only on the day that actually set the ceiling.
    String? sessionType;
    int? heldSeconds;
    try {
      final env = (await _bundleForDate(top.date))?['hr_ceiling'];
      if (env is Map) {
        sessionType = env['session_type'] as String?;
        final v = env['value'];
        if (v is Map) heldSeconds = (v['held_seconds'] as num?)?.toInt();
      }
    } catch (_) {
      /* the number and its date still stand */
    }
    return _ObservedCeiling(
      bpm: top.bpm,
      date: top.date,
      sessionType: sessionType,
      heldSeconds: heldSeconds,
    );
  }

  /// Cardiac drift: mean HR of the 2nd half vs the 1st half, %; sessions under
  /// 10 min (or with a sparse half) yield null rather than a noisy number.
  double? _hrDriftPct(List<int> ts, List<int> hr, int startTs, int endTs) {
    if (endTs - startTs < 600) return null;
    final mid = startTs + (endTs - startTs) ~/ 2;
    var s1 = 0, n1 = 0, s2 = 0, n2 = 0;
    for (var i = 0; i < ts.length; i++) {
      if (ts[i] < mid) {
        s1 += hr[i];
        n1++;
      } else {
        s2 += hr[i];
        n2++;
      }
    }
    if (n1 < 60 || n2 < 60) return null;
    final a = s1 / n1, b = s2 / n2;
    if (a <= 0) return null;
    return double.parse(((b / a - 1) * 100).toStringAsFixed(1));
  }

  /// Post-end HR recovery curve [{sec, drop}] at 60/120/180 s: the drop from
  /// the end-of-effort HR (median of the last 15 s) to the HR around each mark.
  Future<List<Map<String, num>>> _recoveryCurve(int endTs) async {
    final rows = await LocalDb.hrSamplesInRange(endTs - 15, endTs + 190);
    if (rows.isEmpty) return const [];
    final endWindow = <int>[];
    final post = <int, int>{}; // ts → hr
    for (final e in rows) {
      final t = (e['rec_ts'] as num).toInt();
      final v = (e['hr'] as num).toInt();
      if (t <= endTs) {
        endWindow.add(v);
      } else {
        post[t] = v;
      }
    }
    if (endWindow.length < 5) return const [];
    endWindow.sort();
    final endHr = endWindow[endWindow.length ~/ 2];
    final out = <Map<String, num>>[];
    for (final sec in const [60, 120, 180]) {
      // Median of a ±7 s window around the mark; skip marks with no data.
      final win = <int>[
        for (final e in post.entries)
          if ((e.key - (endTs + sec)).abs() <= 7) e.value,
      ]..sort();
      if (win.isEmpty) continue;
      final drop = endHr - win[win.length ~/ 2];
      if (drop <= 0) continue; // HR not recovering (or still working) — omit
      out.add({'sec': sec, 'drop': drop});
    }
    return out;
  }

  /// The HRmax this session's zones are banded on, or null.
  ///
  /// [deviceFamily] is `sessions.device_family` — WHICH STRAP measured the
  /// window. It was `220 − age` here and Tanaka `208 − 0.7·age` in the analytics
  /// anchors, so one session's persisted `zone_min` and the `zone_bands` its own
  /// detail screen recomputes were banded off ceilings 3 bpm apart at 30 and 6
  /// apart at 60. Both are gone: [estimatedMaxHr] is the single definition
  /// (TS-03a).
  ///
  /// Null on no age AND on an unknown/unstamped strap — every pre-schema-41
  /// session, every import and every raw replay carries no family, and a strap
  /// we have not calibrated a ceiling for is not gen4 with a different badge.
  /// No ceiling, no zones; nothing is substituted.
  int? _profileMaxHr(String? deviceFamily) => estimatedMaxHr(
        (getProfileMap()?['age'] as num?),
        deviceFamily,
      )?.round();

  /// Which strap measured [startTs, endTs] — the `device_family` the ingest
  /// stamped on the 1 Hz rows themselves, which is the same stamp the day
  /// pipeline dispatches on. Null when the window is unstamped: every
  /// pre-schema-41 row, every import and every raw replay carries NULL, and
  /// unknown provenance is its own case, never gen4.
  ///
  /// Only a manual/retimed WRITE needs this — every other seam reads the stamp
  /// off `sessions.device_family`, which this write is what banks.
  Future<String?> _windowDeviceFamily(int startTs, int endTs) async {
    // ponytail: one row, the first second of the window, over the derive path's
    // existing range query rather than a new `SELECT DISTINCT` in db.dart. A
    // window whose FIRST second is unstamped reads as unknown even if later
    // seconds are stamped, which refuses rather than over-claims. If a window
    // can ever span two straps, this needs the distinct-set read that
    // `SubstratePages.deviceFamily` already does over the pages it holds.
    try {
      final rows = await LocalDb.decodedOneHzBatchByRecTsRange(
        limit: 1,
        fromRecTs: startTs,
        toRecTs: endTs,
      );
      if (rows.isEmpty) return null;
      final f = rows.first['device_family'] as String?;
      return (f == null || f.isEmpty) ? null : f;
    } catch (_) {
      return null; // unknown provenance, same as an unstamped window
    }
  }

  /// Profile age in years, or null when unset — the input to the physiological
  /// HR ceiling in the spike-suppressed max ([hrCeilingForAge]).
  int? _profileAge() => (getProfileMap()?['age'] as num?)?.round();

  @override
  Future<void> deleteWorkout(String id) async => LocalDb.deleteSession(id);

  @override
  Future<void> setWorkoutPrivate(String id, bool private) async =>
      LocalDb.setSessionPrivate(id, private);

  @override
  Future<Map<String, dynamic>> startWorkout(
    String type, {
    String? title,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final id = 'w$nowMs';
    await LocalDb.putSession({
      'id': id,
      'start_ts': nowMs ~/ 1000,
      'end_ts': null,
      'type': type,
      'status': 'live',
      'source': 'manual',
      'created_at': nowMs,
    });
    return {'workout_id': id, 'type': type};
  }

  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) async {
    // Mark done + stamp end_ts; final stats (calories/strain/etc) are written by
    // app_state.stopWorkout from the LiveWorkoutState (it has the live tallies).
    final r = await LocalDb.session(workoutId);
    if (r != null) {
      await LocalDb.putSession({
        ...r,
        'status': 'done',
        'end_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      // This is the choke point the AI coach's `end_workout` tool reaches
      // directly (bypassing AppState.stopWorkout, the only other place this
      // used to happen) — without it a coach-ended workout never reached
      // Apple Health / Health Connect (edge#277). Idempotent + best-effort;
      // exportWorkoutId re-reads the row and no-ops if sync is off.
      unawaited(HealthExporter.exportWorkoutId(workoutId));
    }
    return {'workout_id': workoutId};
  }

  @override
  Future<List<SessionSpan>> savedSessionSpans() async {
    // Everything ever logged — the overlap check has to see a session from any
    // date the athlete might be back-filling into, not just a recent window.
    final rows = await LocalDb.sessionsInRange(0, 1 << 40);
    return [
      for (final r in rows)
        if (r['id'] is String && r['start_ts'] is num && r['end_ts'] is num)
          SessionSpan(
            r['id'] as String,
            (r['start_ts'] as num).toInt(),
            (r['end_ts'] as num).toInt(),
          ),
    ];
  }

  @override
  Future<Map<String, dynamic>> logManualWorkout({
    required int startTs,
    required int endTs,
    required String type,
  }) => _writeManualSession(
    startTs: startTs,
    endTs: endTs,
    type: type,
    // A manual row's id is derived from its start second, so re-logging the
    // same window is an UPDATE of that row, not a collision with it. Pass
    // the id we are about to write as the one to skip in the overlap check.
    validateAgainstId: manualSessionId(startTs),
  );

  @override
  Future<Map<String, dynamic>> setWorkoutWindow(
    String id, {
    required int startTs,
    required int endTs,
  }) async {
    final existing = await LocalDb.session(id);
    if (existing == null) {
      throw StateError('setWorkoutWindow: no session $id');
    }
    // A running session has no end to correct yet, and buildManualSessionRow
    // always writes status 'done' — retiming one here would silently end it.
    // The detail screen already passes onEditTimes:null for a live row, but
    // the window is re-validated at this seam precisely because the form is
    // not the only caller; the status deserves the same treatment.
    if (existing['status'] == 'live') {
      throw StateError('setWorkoutWindow: session $id is still live');
    }
    // Clear the OLD Health window before the retimed row overwrites it — the
    // caller's subsequent exportWorkoutId only deletes inside the NEW window,
    // so a narrowed/moved retime would otherwise leave the previous sample
    // stranded outside it.
    final oldStart = (existing['start_ts'] as num?)?.toInt();
    final oldEnd = (existing['end_ts'] as num?)?.toInt();
    if (oldStart != null && oldEnd != null) {
      await HealthExporter.deleteWorkoutWindow(oldStart, oldEnd);
    }
    // A retimed session keeps its id, so the OLD row is replaced rather than
    // orphaned — including its GPS route, which still belongs to it.
    return _writeManualSession(
      startTs: startTs,
      endTs: endTs,
      type: (existing['type'] as String?) ?? 'other',
      existing: existing,
      validateAgainstId: id,
    );
  }

  /// Shared writer for both user-timed paths: score the window from the 1 Hz
  /// substrate, persist, and retire any auto-detect suggestion it covers.
  ///
  /// Deliberately does NOT force a day re-derive. Sessions do not feed
  /// `day_result` — the derivation engine reads them only as `savedSpans`
  /// (auto-detect exclusion) and to back-fill `hrr_bpm`, while day strain and
  /// calories come from the whole-day substrate independently. So there is no
  /// analytics output to invalidate here and no `kAlgoVersion` bump to make;
  /// the next ordinary derive picks up the exclusion on its own.
  Future<Map<String, dynamic>> _writeManualSession({
    required int startTs,
    required int endTs,
    required String type,
    required String validateAgainstId,
    Map<String, dynamic>? existing,
    String? sessionId,
    String source = 'manual',
  }) async {
    // Re-check at the write seam. The form validates live, but its snapshot of
    // saved spans can be stale by the time save is tapped (a background derive
    // can log an auto-detected session mid-edit), and the form is not the only
    // possible caller. Throwing beats silently writing an overlapping row.
    final invalid = validateManualWindow(
      startSec: startTs,
      endSec: endTs,
      nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      existing: await savedSessionSpans(),
      editingId: validateAgainstId,
    );
    if (invalid != null) throw ManualWindowException(invalid);

    final hrRows = await LocalDb.hrSamplesInRange(startTs, endTs);
    final hrTs = [for (final e in hrRows) (e['rec_ts'] as num).toInt()];
    final hrBpm = [for (final e in hrRows) (e['hr'] as num).toInt()];

    final profile = Profile.fromMap(getProfileMap());
    // Prefer the measured nightly RHR; fall back to the user-supplied one.
    // Both are real inputs — absent both, strain stays null rather than
    // leaning on a 60 bpm stand-in.
    final restingHr =
        await _recentRestingHr() ?? profile.restingHrManual?.toDouble();

    // WHICH STRAP measured this window. An edit keeps the stamp the row already
    // carries; a hand-entered window has none of its own, so it is read off the
    // substrate it is scored from. Null — an unstamped window (every pre-v41
    // row, every import, every raw replay) — is a refusal, not gen4 by default.
    final deviceFamily = (existing?['device_family'] as String?) ??
        await _windowDeviceFamily(startTs, endTs);

    final stats = computeManualSessionStats(
      hrTs: hrTs,
      hrBpm: hrBpm,
      profile: profile,
      hrMax: _profileMaxHr(deviceFamily)?.toDouble(),
      restingHr: restingHr,
      // TS-04 — the persisted `zone_min` is binned with the SAME set the detail
      // screen's `zone_bands` recomputes. `hrMax` above stays the strain and
      // calorie anchor; the two are named separately because they can now be
      // different ceilings.
      zoneSet: _zoneSetFor(deviceFamily, await _zoneAnchors()),
    );

    final row = buildManualSessionRow(
      startSec: startTs,
      endSec: endTs,
      type: type,
      stats: stats,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      existing: existing,
      sessionId: sessionId,
      source: source,
    );
    // Banked on the row so the on-read re-score, the zone bands and the frozen
    // trace all band on the SAME ceiling this write did — `putSession` is
    // INSERT-OR-REPLACE, so omitting it would blank an edit's existing stamp.
    row['device_family'] = deviceFamily;
    await LocalDb.putSession(row);

    // Retire the fragment(s) this window supersedes, so the athlete isn't
    // asked "did you work out?" about the session they just logged.
    try {
      final sug = await LocalDb.activeWorkoutSuggestions();
      for (final id in supersededSuggestionIds(
        sug,
        startSec: startTs,
        endSec: endTs,
      )) {
        await LocalDb.dismissWorkoutSuggestion(id);
      }
    } catch (_) {
      /* suggestion cleanup is best-effort — the session is already saved */
    }

    return {
      'workout_id': row['id'],
      'unscored': stats.isUnscored,
      'hr_samples': stats.hrSampleCount,
    };
  }

  /// Re-score a finished session's strain/calories/max-HR/zone-minutes from the
  /// 1 Hz substrate and persist the result when the substrate improves on what
  /// the live accumulator managed to see (issue #206).
  ///
  /// The live tallies only cover the minutes the foreground app was awake for;
  /// an app suspended or killed mid-workout stores a strain covering a fraction
  /// of the window — often a few sub-resting minutes, which score a confident
  /// `0.0`. Once the band offloads that window, the substrate holds the whole
  /// thing. [reconcileSessionScore] documents why merging the two by `max` is
  /// the correct rule; the short version is that both are lower bounds over
  /// subsets of the same window's minutes.
  ///
  /// Self-healing by construction: it re-runs whenever the row is read or a
  /// drain lands, and the merge is monotone, so a partially-drained window
  /// improves on each pass and converges. Returns the row with the reconciled
  /// values applied (never null-out a stored value), writing back only on a
  /// real change. Best-effort — never throws into a read path.
  /// [zoneMinutesRebinned] answers ONE question for the caller: were the zone
  /// minutes on the returned row binned by THIS pass, i.e. by the same zone set
  /// [_zoneBands] is about to band the detail card's bars with? False when the
  /// reconcile kept the LIVE split — a session the band only partly handed over
  /// keeps whichever side saw more minutes, and that side was binned against
  /// whatever ceiling was current when it was written. True on every path that
  /// did not run the reconcile at all (no substrate, unfinished, row moved):
  /// those serve the FROZEN trace, whose bands were banked beside the same
  /// minutes, so there is nothing for the caller to correct for.
  Future<
    ({
      Map<String, dynamic> row,
      List<Map<String, dynamic>>? hrRows,
      bool zoneMinutesRebinned,
    })
  >
  _rescoreSessionFromSubstrate(Map<String, dynamic> row) async {
    final id = row['id'];
    final startTs = (row['start_ts'] as num?)?.toInt();
    final endTs = (row['end_ts'] as num?)?.toInt();
    // A live row is still accumulating; scoring it here would race the tally.
    if (id is! String ||
        startTs == null ||
        endTs == null ||
        endTs <= startTs ||
        (row['status']?.toString() ?? '') != 'done') {
      return (row: row, hrRows: null, zoneMinutesRebinned: true);
    }
    try {
      // Returned to the caller: `getWorkout` enriches from the SAME 1 Hz window
      // straight after this, and a two-hour session is ~7200 rows to scan twice.
      final hrRows = await LocalDb.hrSamplesInRange(startTs, endTs);
      if (hrRows.isEmpty) {
        return (row: row, hrRows: hrRows, zoneMinutesRebinned: true);
      }

      final profile = Profile.fromMap(getProfileMap());
      final hrBpm = [for (final e in hrRows) (e['hr'] as num).toInt()];
      final stats = computeManualSessionStats(
        hrTs: [for (final e in hrRows) (e['rec_ts'] as num).toInt()],
        hrBpm: hrBpm,
        profile: profile,
        hrMax: _profileMaxHr(row['device_family'] as String?)?.toDouble(),
        restingHr:
            await _recentRestingHr() ?? profile.restingHrManual?.toDouble(),
        zoneSet: _zoneSetFor(
            row['device_family'] as String?, await _zoneAnchors()),
      );
      // The peak is smoothed inside `computeManualSessionStats` now — one
      // definition for the manual save, this re-score and the workout list
      // (#127), instead of the raw peak being re-smoothed here and banked raw
      // everywhere else. Nothing to re-wrap.

      // "Complete" = the band has handed over essentially the whole window.
      // 1 Hz means one sample per second, so sample count vs window seconds is
      // the coverage ratio; 90% absorbs the usual handful of dropped seconds.
      final windowSec = endTs - startTs;
      final complete =
          windowSec > 0 && stats.hrSampleCount >= (windowSec * 0.9).floor();

      final merged = reconcileSessionScore(
        substrateIsComplete: complete,
        liveStrain: (row['strain'] as num?)?.toDouble(),
        liveCalories: (row['calories'] as num?)?.toDouble(),
        liveMaxHr: (row['max_hr'] as num?)?.toInt(),
        liveZoneMinutes: [
          for (final v in _decodeList(row['zone_min_json']))
            if (v is num) v.toDouble(),
        ],
        substrate: stats,
      );
      // `avg_hr` is new, so every session scored before it existed has a NULL
      // column and a live substrate that can still fill it. Bailing purely on
      // "the scores did not change" would leave those rows permanently blank
      // once their raw ages out — the exact loss the column was added to stop.
      final needsAvgBackfill =
          stats.avgHr != null && (row['avg_hr'] as num?) == null;
      // Same argument for the frozen trace, and this path is the right one to
      // write it from: it already re-read the exact window and already knows
      // when coverage IMPROVED. Rewrite only when this pass saw MORE seconds
      // than the stored trace was built from — a later pass with a thinner
      // window (a partial re-drain) must never overwrite a fuller trace.
      final storedSamples = (row['trace_samples'] as num?)?.toInt();
      final needsTrace =
          storedSamples == null || stats.hrSampleCount > storedSamples;
      // `identical`, not `==`: `reconcileSessionScore` returns one of the two
      // vectors it was handed, so identity IS the answer to which side won —
      // the same test its own `changed` flag is built on.
      final rebinned = identical(merged.zoneMinutes, stats.zoneMinutes);
      if (!merged.changed && !needsAvgBackfill && !needsTrace) {
        return (row: row, hrRows: hrRows, zoneMinutesRebinned: rebinned);
      }

      // `putSession` is INSERT-OR-REPLACE on the whole row, and everything
      // above this point awaited (two substrate reads). A retime or a
      // `stopWorkout` finalize landing in that window would be silently
      // reverted — old start/end/status written back over the new ones. Re-read
      // and bail if the row moved under us; the next sweep (or the next open)
      // scores the new window.
      final current = await LocalDb.session(id);
      if (current == null ||
          (current['start_ts'] as num?)?.toInt() != startTs ||
          (current['end_ts'] as num?)?.toInt() != endTs ||
          current['status']?.toString() != row['status']?.toString()) {
        // The row moved under us. Return the fresh row but NOT the rows we
        // read — they describe the old window, and `getWorkout` would enrich
        // the new one with them (a negative time-to-peak, zones over the wrong
        // span). The next pass scores the new window.
        return (row: current ?? row, hrRows: null, zoneMinutesRebinned: true);
      }

      final zoneJson = jsonEncode(
        merged.zoneMinutes.any((v) => v > 0)
            ? merged.zoneMinutes
            : const <num>[],
      );
      // Score columns ONLY, via a targeted UPDATE. `putSession` is
      // INSERT-OR-REPLACE over the whole row, so it also rewrites columns this
      // code never looked at — `hrr_bpm` (backfilled by the derive) and `type`
      // (the user's own correction) are both written by narrow UPDATEs that
      // the re-read above cannot detect.
      String? traceJson;
      if (needsTrace) {
        final trace = _sessionTrace(
          [for (final e in hrRows) (e['rec_ts'] as num).toInt()],
          hrBpm,
          startTs,
          endTs,
          row['device_family'] as String?,
          await _zoneAnchors(),
        );
        // The post-end recovery window is outside the session and outside the
        // rows read above, so it costs one more bounded (~205 s) read — only on
        // a pass that is already writing.
        final curve = await _recoveryCurve(endTs);
        if (curve.isNotEmpty) trace['recovery_curve'] = curve;
        traceJson = _encodeTrace(trace);
      }
      await LocalDb.setSessionScores(
        id,
        strain: merged.strain,
        calories: merged.calories,
        maxHr: merged.maxHr,
        zoneMinJson: zoneJson,
        avgHr: stats.avgHr,
        traceJson: traceJson,
        traceSamples: needsTrace ? stats.hrSampleCount : null,
      );
      // CV-01 / TS-07 — freeze the per-km splits on the SAME improvement pass
      // as the trace, and for the same reason: `avg_hr` per split is a join
      // against `decoded_onehz`, which is gone at ~3 days, so a split not
      // written inside that window can never be written at all. Forward-only.
      if (needsTrace) await _persistKmSplits(id, hrRows);
      final updated = {
        ...current,
        'strain': merged.strain,
        'calories': merged.calories,
        'max_hr': merged.maxHr,
        'zone_min_json': zoneJson,
        if (stats.avgHr != null) 'avg_hr': stats.avgHr,
        'trace_json': ?traceJson,
        if (traceJson != null) 'trace_samples': stats.hrSampleCount,
      };
      return (row: updated, hrRows: hrRows, zoneMinutesRebinned: rebinned);
    } catch (_) {
      // best-effort: the stored row renders
      return (row: row, hrRows: null, zoneMinutesRebinned: true);
    }
  }

  /// Sessions this process has already scored as FINISHED, keyed by id and the
  /// window they had at the time (`id@endTs`).
  ///
  /// The skip cannot key on the window alone: a session that was still `live`
  /// during an earlier sweep is skipped by [_rescoreSessionFromSubstrate] (its
  /// tally is still accumulating), and once the frontier moved past its end a
  /// window-only rule would skip it forever after it finished — leaving the
  /// list showing the stale live-tally strain until someone opened it. Keying
  /// on the window too means a retimed session is rescored rather than assumed
  /// settled.
  final Set<String> _rescoredSessions = <String>{};

  /// Re-score recent finished sessions against the substrate now in the DB.
  /// Called after a drain lands, so a workout whose window arrived late is
  /// corrected on the LIST too, not only when its detail screen is opened.
  /// Returns how many rows changed.
  ///
  /// Runs on the DB-owning (main) isolate by necessity — the sqflite handle is
  /// not portable to another isolate — so it is bounded rather than offloaded:
  /// the window is the raw-retention horizon (older windows are pruned and can
  /// never improve) and anything already covered by a previous pass is skipped
  /// outright, which leaves an ordinary drain doing no substrate reads at all.

  @override
  Future<int> rescoreRecentSessions({int sinceDays = 3}) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var changed = 0;
    try {
      // Local-midnight bound, not `now - n * 86400`: a DST day is 23 or 25
      // hours, so a flat day-length silently moves the window by an hour.
      final fromTs =
          localDayStartSec(
            dayLabelOf(DateTime.now().subtract(Duration(days: sinceDays))),
          ) ??
          (nowSec - sinceDays * 86400);
      final rows = await LocalDb.sessionsInRange(fromTs, nowSec);
      // Where the durable record frontier stands NOW. A finished session whose
      // window sits behind it has all the substrate it is ever going to get.
      // Falls back to the newest decoded row so an import-only install (no
      // band, so no `rec_ts_hw` cursor) still gets the skip rather than
      // re-scanning every session's window on every pass.
      final frontier =
          await LocalDb.getCursorInt('rec_ts_hw') ??
          await LocalDb.lastDecodedRecTs() ??
          0;
      final seen = <String>{};
      for (final r in rows) {
        final id = r['id']?.toString();
        final endTs = (r['end_ts'] as num?)?.toInt();
        final key = (id == null || endTs == null) ? null : '$id@$endTs';
        if (key != null) seen.add(key);
        // Settled: finished, fully covered, and already scored in that state.
        if (key != null &&
            endTs! <= frontier &&
            _rescoredSessions.contains(key)) {
          continue;
        }
        final after = await _rescoreSessionFromSubstrate(r);
        // Count only what THIS pass wrote (the bail path returns a re-read row
        // whose values may differ for reasons we had nothing to do with), and
        // count ALL the scored columns — a pass that fixes calories or the zone
        // split without moving strain still changed what the list shows.
        const scored = ['strain', 'calories', 'max_hr', 'zone_min_json'];
        if (after.hrRows != null &&
            scored.any((k) => '${after.row[k]}' != '${r[k]}')) {
          changed++;
        }
        // Record it only once it is genuinely finished AND actually scored: a
        // live row is skipped by the helper and must be revisited after it
        // ends, and a row whose read threw (null rows) would otherwise be
        // written off for the rest of the process on a transient DB error.
        // The insertion condition MUST match the skip condition, `endTs <=
        // frontier` included. Without it, a workout scored while the band had
        // only handed over part of its window got stamped as settled, and the
        // next drain — the one carrying the REST of that window — skipped it.
        // The partial score then stood on the list until someone opened the
        // detail screen, which is exactly the case the sweep exists for.
        if (key != null &&
            endTs! <= frontier &&
            after.hrRows != null &&
            (r['status']?.toString() ?? '') == 'done') {
          _rescoredSessions.add(key);
        }
      }
      // Drop anything that aged out of the window so the set can't grow
      // without bound across a long-lived process.
      _rescoredSessions.retainWhere(seen.contains);
    } catch (_) {
      /* best-effort */
    }
    return changed;
  }

  /// Most recent nightly resting HR from `metric_series`, or null. Bounded to
  /// the last week so a stale figure from a long gap can't anchor TRIMP.
  Future<double?> _recentRestingHr() async {
    try {
      // 'rhr' is the `metric_series` key the derivation engine writes nightly
      // resting HR under (see _BaselineHistoryCache.keys).
      final vals = await LocalDb.trailingSeriesValues('rhr', 7);
      if (vals.isEmpty) return null;
      return vals.last;
    } catch (_) {
      return null;
    }
  }

  /// Freeze this session's per-KILOMETRE splits (CV-01 / TS-07).
  ///
  /// THE WHOLE FEATURE IS THIS WRITE. A split's `avg_hr` is a join against
  /// `decoded_onehz`, which the retention window prunes at ~3 days, so there is
  /// no retroactive index and never can be: this is forward-only and produces
  /// its first honest "same pace, fewer beats?" chart 8-12 weeks after it
  /// ships. Nothing reads `workout_split` yet, and that is expected.
  ///
  /// [hrRows] is the session's 1 Hz HR the caller has already read — reused
  /// rather than re-queried, and the reason this hangs off the re-score pass.
  Future<void> _persistKmSplits(
    String id,
    List<Map<String, dynamic>> hrRows,
  ) async {
    try {
      if (!await LocalDb.sessionHasRoute(id)) return;
      final rows = await LocalDb.routePoints(id);
      if (rows.length < 2) return;
      final points = [for (final r in rows) RoutePoint.fromRow(r)];
      final hr = [
        for (final r in hrRows)
          HrSample(
            tsMs: (r['rec_ts'] as num).toInt() * 1000,
            hr: (r['hr'] as num).toInt(),
          ),
      ];
      final splits = rmath.computeSplits(
        points,
        hr,
        unitMeters: rmath.kMetersPerKm,
      );
      if (splits.isEmpty) return;
      // Splits are CONTIGUOUS in time by construction (each one starts where
      // the last crossed), so walking the durations reproduces their exact
      // boundaries without `computeSplits` having to return them.
      var edgeMs = points.first.tsMs;
      final out = <Map<String, Object?>>[];
      for (final s in splits) {
        final startMs = edgeMs;
        edgeMs += s.durationSec * 1000;
        out.add({
          'km': s.index,
          'meters': s.meters,
          'duration_sec': s.durationSec,
          'avg_hr': s.avgHr,
          'net_elev_m': _netElevation(points, startMs, edgeMs),
        });
      }
      await LocalDb.putWorkoutSplits(id, out);
    } catch (_) {
      /* best-effort: a missing route or a malformed row costs the splits only */
    }
  }

  /// Elevation change across [fromMs, toMs] — LAST altitude minus FIRST, over
  /// the whole kilometre.
  ///
  /// NOT a summed ascent with a deadband. GPS altitude error is tens of metres
  /// pointwise and there is no barometer anywhere in this stack, so a
  /// point-to-point sum is mostly integrated noise; the net over a km is the
  /// only elevation figure the fix actually supports. Null — never 0 — when
  /// either end carried no altitude, because 0 reads as "flat".
  static double? _netElevation(
    List<RoutePoint> points,
    int fromMs,
    int toMs,
  ) {
    double? first, last;
    for (final p in points) {
      if (p.tsMs < fromMs) continue;
      if (p.tsMs > toMs) break;
      final a = p.alt;
      if (a == null) continue;
      first ??= a;
      last = a;
    }
    return (first == null || last == null) ? null : last - first;
  }

  /// Tolerance when clipping route points to their session's window. GPS
  /// timestamps are millisecond-stamped while the session window is whole
  /// seconds, so the very first and last fix can land a hair outside it.
  static const int _routeClipPadSec = 5;

  @override
  Future<WorkoutRoute?> getWorkoutRoute(String id) async {
    final rows = await LocalDb.routePoints(id);
    if (rows.length < 2) return null;
    var points = [for (final r in rows) RoutePoint.fromRow(r)];

    // Clip to the session's CURRENT window. A route point outside its
    // session's window is not part of that session — which only became
    // reachable once workouts could be retimed: narrowing a live run that was
    // stopped late (say 90 min down to the 60 you actually ran) otherwise left
    // the map, distance, moving time and splits describing the full original
    // 90 minutes while the hero above them read "1h 00m". Two contradictory
    // accounts of the same session on one card.
    //
    // Widening cannot conjure GPS that was never recorded, so the route simply
    // stays as long as it is — correct, and honest about it.
    final session = await LocalDb.session(id);
    final startTs = (session?['start_ts'] as num?)?.toInt();
    final endTs = (session?['end_ts'] as num?)?.toInt();
    if (startTs != null && endTs != null && endTs > startTs) {
      final lo = (startTs - _routeClipPadSec) * 1000;
      final hi = (endTs + _routeClipPadSec) * 1000;
      final clipped = [
        for (final p in points)
          if (p.tsMs >= lo && p.tsMs <= hi) p,
      ];
      // Fewer than two points is not a route — better no map than a single
      // orphaned pin and a zero-length "distance".
      if (clipped.length < 2) return null;
      points = clipped;
    }

    // 1 Hz HR over the route's own time window (± a small pad), for zone
    // colouring and per-split average HR.
    final fromTs = (points.first.tsMs ~/ 1000) - 5;
    final toTs = (points.last.tsMs ~/ 1000) + 5;
    final hrRows = await LocalDb.hrSamplesInRange(fromTs, toTs);
    final hr = [
      for (final r in hrRows)
        HrSample(
          tsMs: (r['rec_ts'] as num).toInt() * 1000,
          hr: (r['hr'] as num).toInt(),
        ),
    ];

    return WorkoutRoute(
      sessionId: id,
      points: points,
      hr: hr,
      distanceMeters: rmath.totalDistanceMeters(points),
      movingSec: rmath.movingSeconds(points),
      splitsKm: rmath.computeSplits(points, hr, unitMeters: rmath.kMetersPerKm),
      splitsMi: rmath.computeSplits(
        points,
        hr,
        unitMeters: rmath.kMetersPerMile,
      ),
    );
  }

  // ── journal — local store + tag-vs-metric correlation insights ──────────────

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async {
    final since = _rangeSinceLabel(range);
    final rows = await LocalDb.journalRows(sinceDaysEpoch: since);
    return [
      for (final r in rows)
        {
          'date': r['date'],
          'tags': _decodeStrList(r['tags_json']),
          'note': (r['note'] as String?) ?? '',
        },
    ];
  }

  @override
  Future<void> postJournal(String date, List<String> tags, String note) async {
    await LocalDb.putJournal(date, jsonEncode(tags), note);
  }

  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) =>
      LocalDb.journalMetricsForDay(date);

  @override
  Future<void> postJournalMetrics(
    String date,
    Map<String, JournalMetricValue> fields,
  ) async {
    // Clamp on the way in rather than trusting the editor. A value past the
    // field's ceiling is almost always a mis-tap, and a single 40-coffee day
    // would dominate every correlation that field appears in for months.
    final specs = await getJournalFields();
    final clamped = <String, JournalMetricValue>{};
    for (final e in fields.entries) {
      final spec = journalFieldSpec(
        e.key,
        custom: specs.where((s) => s.custom).toList(),
      );
      final v = spec == null
          ? e.value.value
          : e.value.value.clamp(0.0, spec.max).toDouble();
      // A zero is a real answer ("no caffeine today") and is stored as one.
      // Absence is expressed by leaving the field out of the map entirely.
      clamped[e.key] = JournalMetricValue(
        v,
        atMinuteOfDay: e.value.atMinuteOfDay,
      );
    }
    await LocalDb.putJournalMetrics(date, clamped);
  }

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => [
    ...kJournalFields,
    ...await LocalDb.journalFieldDefs(),
  ];

  @override
  Future<void> postCustomJournalField(JournalFieldSpec spec) =>
      LocalDb.putJournalFieldDef(spec);

  @override
  Future<void> deleteCustomJournalField(String key) =>
      LocalDb.deleteJournalFieldDef(key);

  /// For each distinct tag in the window, compare mean readiness on tagged days
  /// vs the window mean and emit a metric-delta card (only when n_with >= 2).
  @override
  Future<Map<String, dynamic>> getJournalInsights({
    String range = '90d',
  }) async {
    final since = _rangeSinceLabel(range);
    final journal = await LocalDb.journalRows(sinceDaysEpoch: since);
    final metricsByDay = await LocalDb.journalMetricsByDay(
      sinceDaysEpoch: since,
    );
    // Read independently of each other: a day can carry numbers with no tags,
    // and returning early on an empty tag set would silently hide every
    // numeric finding.
    if (journal.isEmpty && metricsByDay.isEmpty) {
      return const {'insights': [], 'numeric_insights': []};
    }

    // Outcome series we correlate behaviours against. Each is read from
    // metric_series and indexed by date. Direction (does HIGHER help?) is encoded
    // per outcome so the UI can phrase "+/− your recovery".
    const outcomeDefs = <Map<String, dynamic>>[
      {
        'key': 'readiness',
        'label': 'Recovery',
        'higherBetter': true,
        'unit': '',
      },
      {'key': 'rmssd', 'label': 'HRV', 'higherBetter': true, 'unit': 'ms'},
      {
        'key': 'rhr',
        'label': 'Resting HR',
        'higherBetter': false,
        'unit': 'bpm',
      },
      {
        'key': 'efficiency',
        'label': 'Sleep efficiency',
        'higherBetter': true,
        'unit': '%',
      },
    ];

    // MEASURED DAYS ONLY. This is a comparison of the user against
    // themselves; an imported day is another vendor's derived score on a
    // different scale, and it lands in the window mean every tagged day is
    // priced against (see LocalDb.importedDates). The chart underneath still
    // shows those days — a picture may be spliced, a statistic may not.
    //
    // TAKEN ONCE AND FILTERED IN DART, which is what the mask is a Set for.
    // `measuredOnly: true` inlines it as a subquery, and the half of it that
    // matters is a LIKE over `day_result.payload_json` — whole day bundles,
    // tens of kilobytes each, re-scanned per series. Four outcomes made that
    // four full passes over the user's entire history to build four maps off
    // one answer that cannot change between them.
    final imported = await LocalDb.importedDates();
    // date → value maps for each outcome.
    final maps = <String, Map<String, double>>{};
    for (final od in outcomeDefs) {
      final key = od['key'] as String;
      final m = <String, double>{};
      for (final r in await LocalDb.metricSeries(key)) {
        final d = r['date'];
        final v = (r['value'] as num?)?.toDouble();
        if (v != null && d is String && !imported.contains(d)) m[d] = v;
      }
      maps[key] = m;
    }

    // The union of journal dates (the days we can attribute behaviours on),
    // sorted oldest-first — the shared index for journal + outcome arrays.
    final dates = <String>{
      for (final j in journal)
        if (j['date'] is String) j['date'] as String,
    }.toList()..sort();

    final numericInsights = await _numericJournalInsights(
      metricsByDay: metricsByDay,
      outcomeDefs: outcomeDefs,
      maps: maps,
    );

    // The tag pass needs four tagged days before it says anything. The numeric
    // pass has its own, stricter floor and is already computed, so an early
    // return here must not take it down with it.
    if (dates.length < 4) {
      return {'insights': const [], 'numeric_insights': numericInsights};
    }

    final tagsByDate = <String, Set<String>>{};
    for (final j in journal) {
      final d = j['date'] as String?;
      if (d == null) continue;
      (tagsByDate[d] ??= <String>{}).addAll(_decodeStrList(j['tags_json']));
    }
    final jdays = <ana.JournalDay>[
      for (final d in dates) ana.JournalDay(d, tagsByDate[d] ?? const {}),
    ];
    final outcomes = <String, List<double?>>{
      for (final od in outcomeDefs)
        (od['key'] as String): [for (final d in dates) maps[od['key']]![d]],
    };

    final corr = ana.journalCorrelations(
      journal: jdays,
      dates: dates,
      outcomes: outcomes,
    );

    // Flatten to UI rows: one row per (tag, outcome) that is meaningful, phrased
    // by the outcome's direction. Sorted by absolute effect, strongest first.
    final unitOf = {
      for (final od in outcomeDefs) od['key'] as String: od['unit'],
    };
    final betterOf = {
      for (final od in outcomeDefs)
        od['key'] as String: od['higherBetter'] as bool,
    };
    final labelOf = {
      for (final od in outcomeDefs) od['key'] as String: od['label'] as String,
    };
    final insights = <Map<String, dynamic>>[];
    for (final tc in corr) {
      for (final e in tc.effects) {
        if (e.insufficient || !e.meaningful || e.pctChange == null) continue;
        final higherOnTag = e.higherSide == 'tagged';
        final betterWhenHigher = betterOf[e.outcome] ?? true;
        // "helped" = the change moved the outcome in the good direction.
        final helped = higherOnTag == betterWhenHigher;
        insights.add({
          'tag': tc.tag,
          'outcome': e.outcome,
          'outcome_label': labelOf[e.outcome],
          'delta': e.delta,
          'delta_pct': e.pctChange,
          'unit': unitOf[e.outcome],
          'helped': helped,
          'n_with': e.nTagged,
          'n_without': e.nUntagged,
        });
      }
    }
    insights.sort(
      (a, b) => (b['delta_pct'] as double).abs().compareTo(
        (a['delta_pct'] as double).abs(),
      ),
    );
    return {'insights': insights, 'numeric_insights': numericInsights};
  }

  /// Rank correlations between the numeric journal fields and each outcome.
  ///
  /// Deliberately a SEPARATE pass from the tag correlations rather than more
  /// rows in the same list. A tag answers "were those days different"; a dose
  /// answers "does more of this go with worse recovery", and they carry
  /// different evidence (a difference of means with a Cohen's d, versus a rank
  /// correlation with a confidence interval). Flattening them into one list
  /// would force one phrasing onto both and lose the distinction.
  ///
  /// Its date axis is the days a NUMBER was recorded, which is not the same
  /// set as the days a tag was — using the tag axis would drop every day the
  /// user logged only numbers.
  Future<List<Map<String, dynamic>>> _numericJournalInsights({
    required Map<String, Map<String, JournalMetricValue>> metricsByDay,
    required List<Map<String, dynamic>> outcomeDefs,
    required Map<String, Map<String, double>> maps,
  }) async {
    if (metricsByDay.isEmpty) return const [];

    final dates = metricsByDay.keys.toList()..sort();
    final days = <ana.JournalNumericDay>[
      for (final d in dates)
        ana.JournalNumericDay(d, {
          for (final e in metricsByDay[d]!.entries) e.key: e.value.value,
          // MT-06 — the last cup, as a clock time, alongside the day's total.
          //
          // `at_min` has been stored, round-tripped, CSV-exported and rendered
          // for ages, and it died three lines above the analysis: the input was
          // built as `{key: value}` and the timing was dropped. The sleep-
          // relevant fact about caffeine is WHEN the last one landed, not how
          // much — 200 mg at 08:00 and 200 mg at 20:00 are the same dose and a
          // different night.
          //
          // Two things this cannot see, both of which the screen has to say:
          // `at_min` is the LAST occurrence only, so two coffees and five are
          // indistinguishable in timing and "later" quietly means "more" for
          // anyone who logs a second cup; and a late, stressful, socially busy
          // day produces both the late coffee and the wrecked sleep.
          ...?_lastCaffeineMin(metricsByDay[d]!),
        }),
    ];
    final outcomes = <String, List<double?>>{
      for (final od in outcomeDefs)
        (od['key'] as String): [for (final d in dates) maps[od['key']]![d]],
    };

    final corr = ana.journalNumericCorrelations(
      journal: days,
      dates: dates,
      outcomes: outcomes,
    );

    // Custom field definitions so a user-invented field reads by its own name
    // and unit rather than its storage key.
    final customs = (await getJournalFields()).where((f) => f.custom).toList();
    final betterOf = {
      for (final od in outcomeDefs)
        od['key'] as String: od['higherBetter'] as bool,
    };
    final labelOf = {
      for (final od in outcomeDefs) od['key'] as String: od['label'] as String,
    };
    final unitOf = {
      for (final od in outcomeDefs) od['key'] as String: od['unit'],
    };

    final out = <Map<String, dynamic>>[];
    for (final f in corr) {
      final spec = journalFieldSpec(f.field, custom: customs);
      for (final e in f.effects) {
        if (e.insufficient || !e.meaningful) continue;
        // MIND-04 — a 0/1 field is a HABIT, and analytics routed it to a
        // difference of means. It has no rho by construction, and the old
        // `e.rho == null` guard silently dropped every one of them: the whole
        // habit half of this analysis was computed and thrown away.
        if (e.rho == null && e.delta == null) continue;
        final higherBetter = betterOf[e.outcome] ?? true;
        final direction = e.binary ? e.delta! > 0 : e.rho! > 0;
        out.add({
          'field': f.field,
          'field_label': spec?.label ?? _kSynthLabels[f.field] ?? f.field,
          'field_unit': spec?.unit ?? _kSynthUnits[f.field] ?? '',
          'outcome': e.outcome,
          'outcome_label': labelOf[e.outcome],
          'unit': unitOf[e.outcome],
          // The two paths carry different evidence and the UI phrases them
          // differently: a dose gets rho + interval + slope, a tick box gets a
          // group difference with the days on each side.
          'binary': e.binary,
          'rho': e.rho,
          // Outcome units per one unit of the field — the interpretable half.
          // Null when Theil-Sen could not fit, in which case the UI shows the
          // direction without a magnitude rather than inventing one.
          'slope_per_unit': e.slopePerUnit,
          'rho_low': e.rhoLow,
          'rho_high': e.rhoHigh,
          'delta': e.delta,
          'cohens_d': e.cohensD,
          'n_with': e.nWith,
          'n_without': e.nWithout,
          'n': e.n,
          'q': e.q,
          // More of it moved the outcome the good way.
          'helped': direction == higherBetter,
        });
      }
    }
    // Strongest relationship first. Cohen's d and rho are not the same scale,
    // so the two paths are ordered within themselves by their own effect size
    // — never mixed into one ranking that would read as a league table.
    out.sort((a, b) => _effectSize(b).compareTo(_effectSize(a)));
    return out;
  }

  /// MIND-12 — which day of the week costs you, on one outcome.
  ///
  /// The whole series, not a window: the analytics floor is eight weeks with at
  /// least five of every weekday in it, and clipping to 90 days would refuse
  /// installs that have the history. It runs in an isolate because the
  /// permutation loop is ~1000 reshuffles and this is called from a build.
  ///
  /// Absent is the normal answer and the screen has to be able to say so — a
  /// gate that never refuses is not a gate.
  @override
  Future<Map<String, dynamic>> getWeekdayEffect({
    String key = 'readiness',
  }) async {
    // MEASURED DAYS ONLY — a permutation test over a series spliced from two
    // different algorithms reports the splice, not the weekday (same reasoning
    // as the journal outcomes above).
    final rows = await LocalDb.metricSeries(key, measuredOnly: true);
    if (rows.isEmpty) return const {};
    final dates = <String>[];
    final values = <double?>[];
    for (final r in rows) {
      final d = r['date'];
      if (d is! String) continue;
      dates.add(d);
      values.add((r['value'] as num?)?.toDouble());
    }
    final m = await Isolate.run(() => ana.weekdayEffect(dates, values));
    return {
      'present': m.present,
      'note': m.note,
      if (m.value != null) ...m.value!.toJson(),
    };
  }

  /// The day's LAST caffeine, as minutes past midnight, or nothing when the
  /// field is absent or was logged without a time.
  Map<String, double>? _lastCaffeineMin(Map<String, JournalMetricValue> day) {
    final at = day['caffeine_mg']?.atMinuteOfDay;
    return at == null ? null : {'caffeine_last_min': at.toDouble()};
  }

  double _effectSize(Map<String, dynamic> r) =>
      ((r['rho'] ?? r['cohens_d']) as num?)?.abs().toDouble() ?? 0;

  List<String> _decodeStrList(Object? json) => [
    for (final e in _decodeList(json)) e.toString(),
  ];

  /// A YYYY-MM-DD lower-bound label for a '30d'/'90d'/'7d'-style range, or null
  /// (no bound) for 'all'.
  String? _rangeSinceLabel(String range) {
    if (range == 'all') return null;
    final m = RegExp(r'(\d+)').firstMatch(range);
    final days = m == null ? 30 : int.parse(m.group(1)!);
    return dayLabelOf(DateTime.now().subtract(Duration(days: days)));
  }

  // ── menstrual cycle — local log + honest phase/prediction ───────────────────

  @override
  Future<Map<String, dynamic>> getCycle() async {
    final profile = getProfileMap();
    final enabled = profile?['track_cycle'] == true;
    // WH-07 — DECLARED reproductive state. The app never guesses it, and unset
    // is not "assume she cycles": it is the conservative reading, which means
    // no phase. A phase needs an ovulation to count from and we do not measure
    // one — under hormonal contraception there isn't one at all. What survives
    // every state is arithmetic over her own logged dates and the biometric
    // overlay, because neither assumes anything about what her body is doing.
    //
    // This is a feature that makes the app say LESS. It is never pregnancy
    // support and never contraception support.
    final repro = profile?['repro_state'] as String?;
    final phaseOk = repro == 'cycling';
    // 'none' covers pregnant / postpartum / not currently cycling: there is no
    // next period to predict, so we do not print a date for one.
    final predictOk = repro != 'none';
    if (!enabled) {
      return {
        'enabled': false,
        'note': 'Enable cycle tracking in your profile.',
      };
    }
    final rows = await LocalDb.cycleLogs(); // oldest first
    final logs = [
      for (final r in rows) {'date': r['date'], 'kind': r['kind']},
    ];
    final startDates = [
      for (final r in rows)
        if (r['kind'] == 'start') r['date'] as String,
    ];

    // WH-09 — MEDIAN gap, and the spread around it.
    //
    // The mean rounded to one date was a precision we never had: one mis-tapped
    // start drags it, and printing a single day hides how wide her own gaps
    // actually are. Median is the robust centre; the UNSCALED MAD is the half
    // width of the band half her gaps fell inside, which is a claim the data
    // supports and a claim we can print. It is embarrassingly wide for an
    // irregular cycler, and that width IS the answer.
    //
    // One gap has no spread — MAD of a single number is 0, which would print
    // the same false single date wearing a range's clothes. So the band needs
    // two gaps (three logged starts); below that the screen says a point and
    // says why it can't say a width.
    double? medianLength, gapSpread;
    var gapCount = 0;
    if (startDates.length >= 2) {
      final gaps = <double>[];
      for (var i = 1; i < startDates.length; i++) {
        final a = DateTime.tryParse(startDates[i - 1]);
        final b = DateTime.tryParse(startDates[i]);
        if (a != null && b != null) {
          gaps.add(b.difference(a).inDays.toDouble());
        }
      }
      if (gaps.isNotEmpty) {
        gapCount = gaps.length;
        medianLength = ana.median(gaps);
        if (gaps.length >= 2) gapSpread = ana.mad(gaps, scaled: false);
      }
    }

    final lastStartStr = startDates.isEmpty ? null : startDates.last;
    final lastStart = lastStartStr == null
        ? null
        : DateTime.tryParse(lastStartStr);
    final today = DateTime.now();
    int? cycleDay;
    if (lastStart != null) {
      final d0 = DateTime(lastStart.year, lastStart.month, lastStart.day);
      final t0 = DateTime(today.year, today.month, today.day);
      cycleDay = t0.difference(d0).inDays + 1; // day 1 = start day
    }

    String? predictedNext, predictedFrom, predictedTo;
    num? daysUntilNext;
    if (predictOk && lastStart != null && medianLength != null) {
      final next = lastStart.add(Duration(days: medianLength.round()));
      predictedNext = dayLabelOf(next);
      final t0 = DateTime(today.year, today.month, today.day);
      daysUntilNext = DateTime(
        next.year,
        next.month,
        next.day,
      ).difference(t0).inDays;
      if (gapSpread != null) {
        final w = gapSpread.round();
        predictedFrom = dayLabelOf(next.subtract(Duration(days: w)));
        predictedTo = dayLabelOf(next.add(Duration(days: w)));
      }
    }

    // Phase — only when the median length is known (else honest unknown).
    //
    // WH-09: THERE IS NO FERTILE WINDOW HERE ANY MORE. It was `ovDay ± 2` where
    // `ovDay = median − 14`, i.e. a textbook population constant printed as her
    // own dates with "Not contraception." underneath. We do not measure
    // ovulation, so we do not date it. Do not put it back.
    //
    // A cycle shorter than the 10-day ovulation floor makes the clamp bounds
    // cross — `clamp(10, 8)` THROWS ArgumentError (lowerLimit > upperLimit),
    // and it threw straight out of getCycle() so the entire cycle screen
    // errored instead of degrading. Two logged `start` markers 8 days apart is
    // enough: a mis-tap the user then corrected, or a genuinely short cycle.
    // Below the floor there is no defensible day to split on, so be honest —
    // leave `phase: 'unknown'` (prediction / cycleDay / the biometric overlay
    // still render).
    String phase = 'unknown';
    final ovDay = (medianLength == null || medianLength.round() < 10)
        ? null
        : (medianLength - 14).round().clamp(10, medianLength.round());
    if (phaseOk && ovDay != null && cycleDay != null && lastStart != null) {
      if (cycleDay <= 5) {
        phase = 'menstrual';
      } else if (cycleDay < ovDay) {
        phase = 'follicular';
      } else if (cycleDay <= ovDay + 1) {
        phase = 'ovulation';
      } else {
        phase = 'luteal';
      }
    }

    // NO ovulation estimate. `menstrualCoverline` is unit-agnostic and cannot
    // check what it is handed; this called it with skin-temp Z-SCORES while
    // leaving `threshold` at its 1.0 default, which is the classic 3-over-6
    // rule's ~0.2 °F reinterpreted as a full standard deviation above the max
    // of the prior six nights. The dates it produced were not wrong by a
    // little, and nothing rendered them anyway.
    //
    // Restoring it needs a threshold defensible in z, on this sensor, with a
    // stated basis — not a number chosen to make events appear. Until then the
    // key does not exist, because absent-forever is deleted, not explained.
    // See docs/internal/UI_ROADMAP.md.
    // Biometric overlay across the cycle — how resting HR / HRV / skin-temp shift
    // (descriptive context; the prediction is from logged periods, not these).
    //
    // WH-02 — EVERY logged start, not just the last one. `cycle_day` used to be
    // counted from `lastStart` for every row in the window, so a day that fell
    // inside an older cycle came back numbered past that cycle's own length
    // ("cycle day 97") and only the newest cycle could ever be drawn. Each day
    // is now placed against the start that actually preceded it, and carries
    // the INDEX of that start, so "the same day of a different cycle" is a
    // thing the caller can express at all. Days before the first logged start
    // carry neither key — there is no cycle to number them in, and a day 0 or a
    // negative day is a fabricated position, not an absent one.
    final cycleStarts = <DateTime>[
      for (final s in startDates)
        if (DateTime.tryParse(s) case final d?) DateTime(d.year, d.month, d.day),
    ]..sort();
    final overlay = <Map<String, dynamic>>[];
    final derived = await LocalDb.recentDayResults(120);
    if (derived.isNotEmpty) {
      // recentDerivedDays is newest-first; coverline wants oldest-first.
      final ordered = derived.reversed.toList();
      final dates = <String>[];
      final temps = <double?>[];
      for (final r in ordered) {
        final b = _decode(r['payload_json']);
        final dt = r['date'] as String;
        dates.add(dt);
        final z = _scalar(b, 'skin_temp_z')?.toDouble();
        temps.add(z);
        // (cycle index, cycle day) for this row — see WH-02 above.
        int? cd, ci;
        final d = DateTime.tryParse(dt);
        if (d != null) {
          final day = DateTime(d.year, d.month, d.day);
          final i = cycleStarts.lastIndexWhere((s) => !s.isAfter(day));
          if (i >= 0) {
            ci = i;
            cd = day.difference(cycleStarts[i]).inDays + 1;
          }
        }
        overlay.add({
          'date': dt,
          'cycle_day': ?cd,
          'cycle_index': ?ci,
          'resting_hr': _scalar(b, 'rhr')?.toDouble(),
          'hrv_rmssd': _scalar(b, 'rmssd')?.toDouble(),
          'skin_temp_idx': z,
        });
      }
    }

    final confidence = (startDates.length / 3.0).clamp(0.0, 1.0);

    return {
      'enabled': true,
      // Null = never declared. Stays out of every export: it lives in the
      // profile prefs, and `kCsvExportExclusions` keeps the whole profile out.
      'repro_state': repro,
      'phase': phase,
      'cycle_day': cycleDay,
      'days_until_next': daysUntilNext,
      'predicted_next': predictedNext,
      // The band half her gaps fell inside. Null until two gaps exist.
      'predicted_from': predictedFrom,
      'predicted_to': predictedTo,
      'gap_n': gapCount,
      'median_length': medianLength,
      'note': null,
      'confidence': confidence,
      'logs': logs,
      'overlay': overlay,
    };
  }

  @override
  Future<void> postCycleLog(
    String date, {
    String kind = 'start',
    String? note,
  }) async {
    await LocalDb.putCycleLog(date, kind, note: note);
  }

  @override
  Future<void> deleteCycleLog(String date) async =>
      LocalDb.deleteCycleLog(date);

  @override
  Future<void> postCycleSymptoms(
    String date,
    List<String> symptoms, {
    String? note,
  }) async => LocalDb.putCycleSymptoms(date, symptoms, note: note);

  @override
  Future<Map<String, List<String>>> getCycleSymptoms() async {
    final rows = await LocalDb.cycleSymptoms();
    final out = <String, List<String>>{};
    for (final r in rows) {
      final d = r['date'] as String?;
      if (d == null) continue;
      out[d] = _decodeStrList(r['symptoms_json']);
    }
    return out;
  }

  // ── live HRV spot-check (on-device decode + HRV) ────────────────────────────

  @override
  Future<Map<String, dynamic>> spotCheck(List<String> records) async {
    // Decode + HRV run OFF the UI isolate. The spot-check buffer grows over the
    // multi-minute measurement, so decoding every frame + RR correction + HRV on
    // the main isolate was real per-tick work that hung the UI on slower phones.
    return Isolate.run(() => _spotCheckCompute(records));
  }

  @override
  Future<Map<String, dynamic>> breathingCoherence(
    List<String> records, {
    double? pacedHz,
  }) async {
    // Offloaded: cardiac coherence is a 400-point Lomb-Scargle PSD recomputed
    // over the FULL (growing) session buffer every 20 s — pure sin/cos work that
    // was running on the UI isolate and is a confirmed foreground-hang source.
    return Isolate.run(() => _breathingCoherenceCompute(records, pacedHz));
  }

  // ── small series helpers ─────────────────────────────────────────────────────

  Future<double?> _seriesMean(String key) async {
    final vs = await LocalDb.trailingSeriesValues(key, 28);
    if (vs.isEmpty) return null;
    return vs.reduce((a, b) => a + b) / vs.length;
  }

  num? _avgHr(List hrCurve) {
    final vs = [
      for (final e in hrCurve)
        if (e is Map && e['v'] is num && (e['v'] as num) > 0) (e['v'] as num),
    ];
    if (vs.isEmpty) return null;
    return (vs.reduce((a, b) => a + b) / vs.length).round();
  }

  num? _maxHr(List hrCurve) {
    num mx = 0;
    for (final e in hrCurve) {
      if (e is Map && e['v'] is num && (e['v'] as num) > mx) mx = e['v'] as num;
    }
    return mx == 0 ? null : mx;
  }

  // ── TS-03 / TS-04 / TS-05 — the zones screen ───────────────────────────────

  /// Everything the zones screen draws: the observed ceiling and where it came
  /// from, the zone edges and WHICH TWO NUMBERS they were anchored on, and —
  /// only when both of those were measured — the 28-day intensity distribution.
  @override
  Future<Map<String, dynamic>> getZones() async {
    final ceiling = await _observedCeiling();
    final rhrHistory = await LocalDb.trailingSeriesValues('rhr', 28);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // One read, two jobs: which strap these edges belong to, and the 28-day
    // distribution below.
    final recent = await LocalDb.sessionsInRange(nowSec - 28 * 86400, nowSec);
    // The strap these edges belong to — from the most recent session that
    // carries one, then from the day's own 1 Hz rows while they still exist.
    // Sessions outlive the 3-day raw retention, so this still answers for a
    // user who has not synced in a week.
    // The strap these edges belong to. Sessions outlive the ~3-day raw
    // retention and derived days outlive everything, so this still answers for
    // a user who has not synced in a week. Unknown stays unknown — it is never
    // filled in with gen4.
    final todayBundle = await _bundleForDate(todayLabel());
    final family = _familyOfSessions(recent) ??
        await LocalDb.latestSessionDeviceFamily() ??
        todayBundle?['device_family'] as String?;
    // WHY there is no measured ceiling — but ONLY the reason that holds across
    // the whole history, because that is what an all-time max is taken over.
    // An unknown family is exactly that: `observedCeilingBpm` has no motion
    // gate for one, so it refuses on every day and no future session can change
    // it. Any other day's note is one day's reason and would be a guess here.
    //
    // The card stated a cause of its own — "the band has not yet HELD a high
    // enough heart rate" — and offered "wear the band for your normal hard
    // sessions". Measured on all three real databases, both are false: every
    // row is unstamped (`unknown_device_family:id=none` on `hr_ceiling`).
    final ceilingNote = ceiling == null &&
            ana.calibrationFor(ana.hrCeilingMotionGateG, family) == null
        ? ana.unknownFamilyNote(family)
        : null;
    final set = trainingZones(
      age: _profileAge(),
      deviceFamily: family,
      observedCeilingBpm: ceiling?.bpm,
      restingHrHistory: rhrHistory,
    );
    final measured = zonesAreMeasured(set?.source);
    // WHY there are no edges. This screen printed "Without your age or a strap
    // we have calibrated a ceiling for, there is no ceiling" and offered "Add
    // your age in Profile" — on a profile whose age IS set, because the only
    // thing actually missing was the strap stamp. Name the one that is missing.
    final age = _profileAge();
    final zonesNote = set != null
        ? null
        : age == null
        ? needInputNote('age')
        : ana.unknownFamilyNote(family);
    // TS-05 — the 28-day distribution is ABSENT, not captioned, until BOTH zone
    // anchors were measured on this user; a three-bar "you live in the grey
    // middle" read off `208 − 0.7·age` bands is manufactured and no footnote
    // repairs it. So it has three distinct causes and they are not the same
    // fix: no edges at all, edges off the age estimate, or edges off a measured
    // ceiling whose reserve anchor is still short. Name the one that applies.
    final distribution = measured ? _intensity28d(set!, recent) : null;
    final distributionNote = distribution != null
        ? null
        : zonesNote ??
              (set!.source == 'tanaka'
                  // The ceiling's OWN reason outranks "no hard session yet" —
                  // on all three real databases it refused for an unstamped
                  // strap, which a hard session cannot fix.
                  ? ceilingNote ??
                        // A ceiling that EXISTS and was rejected as an anchor
                        // ([kCeilingCredibleGapBpm]) is not a missing one, and
                        // this card shows it two rows up with its date. Asking
                        // for the number already on screen is the false reason
                        // the note grammar exists to prevent.
                        needInputNote(
                          ceiling != null ? 'maximal_effort' : 'observed_ceiling',
                        )
                  : !measured
                  ? needInputNote(
                      'resting_hr_days',
                      have: rhrHistory.length,
                      need: ana.HeartRateZones.reserveMinDays,
                    )
                  : needInputNote(
                      'sessions',
                      have: recent.length,
                      need: _minDistributionSessions,
                    ));
    return {
      'ceiling': ?ceiling?.toJson(),
      // Why there is no ceiling, when there is none. Never set alongside one.
      'ceiling_note': ceilingNote,
      'age': age,
      'device_family': family,
      'source': set?.source,
      'max_hr': set?.maxHr.round(),
      // The reserve anchor, and how many nights it is a median of — printed,
      // because "your easy zone got wider" is only answerable if the two
      // numbers it was built from are on the screen.
      'resting_hr': measured ? _median(rhrHistory)?.round() : null,
      // Why there are no edges, at the top level: with no zones the screen IS
      // this one card. Same string as `absent.zones`.
      'note': zonesNote,
      'resting_days': rhrHistory.length,
      'resting_min_days': ana.HeartRateZones.reserveMinDays,
      'zones': set == null
          ? const []
          : [
              for (var i = 0; i < 5; i++)
                {
                  'zone': i + 1,
                  'name': zoneNames[i],
                  'lo': set.zones[i].lower.round(),
                  'hi': set.zones[i].upper.round(),
                  'lo_pct': (set.zones[i].lowerPct * 100).round(),
                  'hi_pct': (set.zones[i].upperPct * 100).round(),
                },
            ],
      // TS-05 — ABSENT, not captioned, while the ceiling is the age formula.
      // A three-bar "you live in the grey middle" read off 220−age bands is
      // manufactured, and no footnote repairs it, so the gate is the absence.
      'distribution': distribution,
      // Per-figure reasons, same shape and same contract as `getDayStrain`'s.
      // Present only for what is actually absent.
      'absent': <String, Map<String, dynamic>>{
        'zones': ?_absentMetric(zonesNote, 'ESTIMATE'),
        'max_hr': ?_absentMetric(zonesNote, 'ESTIMATE'),
        'distribution': ?_absentMetric(distributionNote, 'ESTIMATE'),
      },
    };
  }

  /// The family stamped on the most recent of [rows] that carries one (they
  /// arrive `start_ts DESC`) — the free answer when the caller has already
  /// read the window. Falls through to [LocalDb.latestSessionDeviceFamily] at
  /// the call site when the window holds none.
  static String? _familyOfSessions(List<Map<String, dynamic>> rows) {
    for (final r in rows) {
      final f = r['device_family'] as String?;
      if (f != null && f.isNotEmpty) return f;
    }
    return null;
  }

  /// Sessions in the last 28 days that are worth calling a training pattern.
  /// Below this it is a handful of workouts, not a distribution.
  static const _minDistributionSessions = 8;

  /// TS-05 — where the last 28 days of SESSION minutes actually went.
  ///
  /// SESSIONS, never whole days. The pipeline's day `zones` block bins the
  /// whole waking day, so Z1 there is mostly sitting down; a pyramidal /
  /// polarised read off that would be a description of having a job.
  ///
  /// Every session is re-binned HERE, with ONE current zone set, off its frozen
  /// per-minute HR trace — the stored `zone_min_json` was binned with whatever
  /// anchors were current when that session was scored, and summing bins from
  /// different anchors is the same defect TS-03a removed one layer down.
  ///
  /// Null (not a partial chart) when there are too few sessions or none of them
  /// carries a trace — a session scored before the trace column existed has no
  /// per-minute HR and never will.
  Map<String, dynamic>? _intensity28d(
    ana.HeartRateZoneSet set,
    List<Map<String, dynamic>> rows,
  ) {
    final minutes = List<double>.filled(5, 0);
    var sessions = 0, withoutTrace = 0;
    for (final r in rows) {
      if (r['status'] == 'live') continue;
      final hr = _frozenTrace(r)['hr'];
      if (hr is! List || hr.isEmpty) {
        withoutTrace++;
        continue;
      }
      var counted = false;
      for (final e in hr) {
        if (e is! Map || e['v'] is! num) continue;
        final z = set.zoneNumber((e['v'] as num).toDouble());
        if (z >= 1) minutes[z - 1] += 1; // the trace is one point per MINUTE
        counted = true;
      }
      if (counted) sessions++;
    }
    if (sessions < _minDistributionSessions) return null;
    final total = minutes.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return null;
    final easy = minutes[0] + minutes[1];
    final moderate = minutes[2];
    final hard = minutes[3] + minutes[4];
    return {
      'minutes': [for (final m in minutes) m.round()],
      'sessions': sessions,
      'sessions_without_trace': withoutTrace,
      'days': 28,
      'easy_min': easy.round(),
      'moderate_min': moderate.round(),
      'hard_min': hard.round(),
      // A DESCRIPTION of the shape and nothing else. There is no target here:
      // the 80/20 literature is trained endurance athletes against lab-defined
      // thresholds, and these are %HRR bands off a wrist-measured ceiling.
      'shape': intensityShape(easy, moderate, hard),
    };
  }

  /// Names the SHAPE of an easy/moderate/hard split. Pure, so the naming is
  /// testable without a database. Null when nothing has a clear largest share.
  static String? intensityShape(double easy, double moderate, double hard) {
    final total = easy + moderate + hard;
    if (total <= 0) return null;
    if (easy < moderate || easy < hard) return 'middle-heavy';
    if (moderate >= hard) return 'pyramidal';
    return 'polarised';
  }

  static double? _median(List<double> xs) {
    if (xs.isEmpty) return null;
    final v = [...xs]..sort();
    return v.length.isOdd
        ? v[v.length ~/ 2]
        : (v[v.length ~/ 2 - 1] + v[v.length ~/ 2]) / 2.0;
  }
}

/// The two anchors every zone set in the app is built from — read once, passed
/// down, so a per-session recompute does not re-query them per row.
class _ZoneAnchors {
  final double? observedCeilingBpm;
  final List<double> restingHrHistory;
  const _ZoneAnchors({
    this.observedCeilingBpm,
    this.restingHrHistory = const [],
  });
}

/// TS-03 — the highest heart rate the band has OBSERVED, and where.
///
/// An observed maximum, never a physiological one. The date and the session
/// travel WITH the number because that is what makes a wrong one attributable:
/// a walk that cadence-locked at 180 bpm for twenty seconds passes the hold and
/// the motion gate, and the only defence against it is that the user can see
/// which session it came from.
class _ObservedCeiling {
  final double bpm;
  final String date; // 'YYYY-MM-DD', the local day it was held on
  final String? sessionType;
  final int? heldSeconds;
  const _ObservedCeiling({
    required this.bpm,
    required this.date,
    this.sessionType,
    this.heldSeconds,
  });

  Map<String, dynamic> toJson() => {
        'bpm': bpm.round(),
        'date': date,
        'session_type': ?sessionType,
        'held_seconds': ?heldSeconds,
      };
}

/// The /today `coach` block, bridging the cross-day strain target onto the
/// shape [CoachData] reads. Pure + public so the seam is unit-testable.
///
/// There were TWO strain targets and only one producer. `crossDayPipeline`
/// emits `strain_coach` as a Metric ({value: {target_min, target_max, band,
/// rationale}}), which the Insights card reads. [CoachData] — behind Today's
/// plan row, the Coach screen's target tile and the home-screen widget — reads
/// `coach.strain_target` ({value, low, high, rationale}), and NOTHING wrote a
/// `coach` key anywhere in the app, so those three surfaces silently rendered
/// nothing while a test fixture "covered" the shape production never emitted.
///
/// `value` is the CENTRE of the aim band (what the Today chip shows). Returns
/// null when the target abstains — `strainTarget` has no recovery value yet,
/// and an absent target must not surface as a 0–0 aim band.
Map<String, dynamic>? coachToday(Map<String, dynamic>? crossDay) {
  final metric = crossDay?['strain_coach'];
  if (metric is! Map) return null;
  final v = metric['value'];
  if (v is! Map) return null;
  final lo = (v['target_min'] as num?)?.toDouble();
  final hi = (v['target_max'] as num?)?.toDouble();
  if (lo == null || hi == null) return null;
  return {
    'strain_target': {
      'value': (lo + hi) / 2,
      'low': lo,
      'high': hi,
      'rationale': (v['rationale'] ?? '').toString(),
    },
  };
}

/// The /today `stress` block from a day bundle — the pipeline's Baevsky block,
/// verbatim, with NO fallback substitute when SI couldn't compute a score.
/// (Previously mirrored getDayStress's `100 - readiness` fallback; removed for
/// the same reason — it fabricated a stress-looking number out of an unrelated
/// metric, violating the never-impute rule.) Pure + public so the Today seam
/// is unit-testable. Returns null when there is neither a stress block nor any
/// score (the tile then renders the honest "—"); [readiness] is now unused but
/// kept as a parameter for call-site compatibility.
Map<String, dynamic>? stressSummaryForToday(
  Map<String, dynamic> bundle,
  num? readiness,
) {
  final blk = bundle['stress'] is Map
      ? (bundle['stress'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  return blk.isEmpty ? null : blk;
}

// ── Live spot-check / breathing compute (run under Isolate.run, off the UI) ────
// Top-level (no `this` capture) + only file-scoped `proto`/`ana` top-level
// functions + a List<String> of hex frames in, a plain Map out — all sendable.

/// Decode RR beats from the live RR-bearing frames (0x28 / R10), shared by
/// [_spotCheckCompute] and [_breathingCoherenceCompute] (CodeRabbit noted the
/// duplication on edge#308). rrTsMs carries each beat's packet timestamp
/// (ms) alongside it — same seam getNightBeats uses (line ~867) — so
/// correctRr can re-anchor at a dropout and hrvTime's/coherence's seam
/// detection can refuse to diff across it (edge#286: a flat rrMs-only list
/// let a real packet gap read as two successive beats). rr.ts is whole
/// SECONDS, and a live 0x2B packet can legitimately land more than once in
/// the same second — only an out-of-order (strictly older) timestamp can't
/// prove adjacency to what came before it, so only that gets dropped; an
/// equal timestamp is accepted like normal (sourcery flagged the earlier
/// strict `>` as silently losing real beats on any multi-packet-per-second
/// burst).
({List<double> rrMs, List<double> rrTsMs}) _decodeLiveRr(
  List<String> records,
) {
  final rrMs = <double>[];
  final rrTsMs = <double>[];
  int? lastPacketTs;
  for (final hex in records) {
    final rr = proto.realtimeRr(hex);
    if (rr == null || (lastPacketTs != null && rr.ts < lastPacketTs)) {
      continue;
    }
    lastPacketTs = rr.ts;
    final ts = rr.ts.toDouble() * 1000;
    for (final v in rr.rrMs) {
      if (v > 0) {
        rrMs.add(v.toDouble());
        rrTsMs.add(ts);
      }
    }
  }
  return (rrMs: rrMs, rrTsMs: rrTsMs);
}

Map<String, dynamic> _spotCheckCompute(List<String> records) {
  final decoded = _decodeLiveRr(records);
  final rrMs = decoded.rrMs;
  final rrTsMs = decoded.rrTsMs;
  final hrs = <double>[];
  for (final hex in records) {
    try {
      final s = proto.decodeRecord(hex);
      if (s != null && s.hr > 0) hrs.add(s.hr.toDouble());
    } catch (_) {}
  }
  if (rrMs.length < 20) {
    return {'ok': false, 'n_beats': rrMs.length};
  }
  final cleaned = ana.correctRr(rrMs, rrTsMs: rrTsMs);
  final hrv = ana.hrvTime(cleaned.nn, nnTimesMs: cleaned.nnTimesMs);
  if (!hrv.present) return {'ok': false, 'n_beats': cleaned.nn.length};
  final meanHr = hrs.isEmpty ? null : hrs.reduce((a, b) => a + b) / hrs.length;
  return {
    'ok': true,
    'rmssd': hrv.value!.rmssd?.round(),
    'sdnn': hrv.value!.sdnn?.round(),
    'mean_hr': meanHr?.round(),
    'n_beats': cleaned.nn.length,
    'confidence': hrv.confidence,
  };
}

Map<String, dynamic> _breathingCoherenceCompute(
  List<String> records,
  double? pacedHz,
) {
  // Decode RR from the live RR-bearing frames (0x28 / R10) via the shared
  // _decodeLiveRr helper (same seam spotCheck uses), then run McCraty &
  // Zayas 2014 cardiac coherence. rrTsMs lets correctRr re-anchor at a real
  // packet gap so the coherence time axis is the real wall clock, not a
  // gap-free cumsum (edge#286).
  final decoded = _decodeLiveRr(records);
  final rrMs = decoded.rrMs;
  final rrTsMs = decoded.rrTsMs;
  if (rrMs.length < 20) {
    return {'ok': false, 'n_beats': rrMs.length};
  }
  final cleaned = ana.correctRr(rrMs, rrTsMs: rrTsMs);
  final m = ana.cardiacCoherence(
    cleaned.nn,
    cleaned.nnTimesMs,
    pacedHz: pacedHz,
  );
  if (!m.present) {
    return {'ok': false, 'n_beats': cleaned.nn.length, 'note': m.note};
  }
  return {
    'ok': true,
    'ratio': m.value!.ratio,
    'score': m.value!.score.round(),
    'peak_hz': m.value!.peakHz,
    'n_beats': cleaned.nn.length,
    'confidence': m.confidence,
    'tier': m.tier,
    'note': m.note,
  };
}

/// Fields the repository SYNTHESISES for the journal analysis — they have no
/// [JournalFieldSpec] because the user never enters them directly.
const _kSynthLabels = <String, String>{
  'caffeine_last_min': 'Last caffeine, clock time',
};

const _kSynthUnits = <String, String>{'caffeine_last_min': 'min past midnight'};
