// CROSS-DAY PIPELINE — the cross-day analytics rollup (PURE, ISOLATE-SAFE).
//
// The per-day pipeline (onehz_pipeline.dart / deriveDayBundle) writes ONE
// derived bundle per physiological day. A whole family of tested analytics
// (illness CUSUM, multivariate anomaly, CTL/ATL/TSB load, skin-temp illness,
// the true Phillips SRI across days, social jetlag, chronotype, sleep debt,
// percentile-of-you, glass-box readiness, breathing-rate-variability) operate
// on a SERIES of days and were never wired in. This module gathers the recent
// day series and runs those families ONCE per derivation pass.
//
// PURITY: this file does NO DB/IO, no Flutter, no DateTime.now(), no Random —
// every input is supplied by the caller. The ONLY DateTime use is
// DateTime.parse(date) to read the calendar weekday for the free/work split,
// which is a deterministic function of the input string. Safe for Isolate.run
// and directly unit-testable.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;

// Pure value helper — the shared sex normalisation, so this pipeline agrees
// with day derivation about what a stored profile means.
import 'profile.dart' show workoutSex;

/// Build the cross-day analytics bundle from a time-ordered (OLDEST FIRST) list
/// of per-day records and the user profile.
///
/// Each [daysOldestFirst] element is one day shaped like:
///   {'date': 'YYYY-MM-DD', 'rhr': num?, 'rmssd': num?, 'readiness': num?,
///    'resp_rate': num?, 'skin_temp_z': num?, 'trimp': num?,
///    'onset_sec': int?, 'wake_sec': int?, 'tst_min': int?,
///    'hypnogram': [{start,end,stage}]?}
///
/// Returns a JSON-safe map of the latest/aggregate cross-day results. Every
/// absent family serializes its honest `Metric.absent` envelope (value "—",
/// confidence 0) or null — never a fabricated number.
Map<String, dynamic> buildCrossDayBundle(
  List<Map<String, dynamic>> daysOldestFirst,
  Map<String, dynamic> profile,
) {
  final days = daysOldestFirst;
  final n = days.length;

  // ── per-series arrays (preserve order, parallel to `days`) ─────────────────
  final dates = <String>[for (final d in days) (d['date'] as String?) ?? ''];
  final rhrList = <double?>[for (final d in days) _numOrNull(d['rhr'])];
  final rmssdList = <double?>[for (final d in days) _numOrNull(d['rmssd'])];
  final readyList = <double?>[for (final d in days) _numOrNull(d['readiness'])];
  final respList = <double?>[for (final d in days) _numOrNull(d['resp_rate'])];
  final tempList = <double?>[
    for (final d in days) _numOrNull(d['skin_temp_z']),
  ];

  // A day flagged `unsettled` (today, still syncing / not finalized) is a
  // truncated reading, not a physiological signal — it must not drive an
  // illness/anomaly/temperature ALERT. It stays in `days` for everything else
  // (readiness, RHR trend, load, sleep debt, `recent`), which is why this is a
  // per-input null rather than dropping the row from the list.
  final unsettled = <bool>[for (final d in days) d['unsettled'] == true];
  T? settled<T>(int i, T? v) => unsettled[i] ? null : v;

  // ── illness CUSUM (NightSignal) on nightly RHR ─────────────────────────────
  final illness = ana.illnessCusum(dates, [
    for (var i = 0; i < n; i++) settled(i, rhrList[i]),
  ]);

  // ── multivariate anomaly {RHR↑,HRV↓,temp↑,resp↑} ───────────────────────────
  // Build one AnomalyFeatures per day (same length as dates). Days with all
  // features null still occupy a slot — the detector handles the nulls
  // internally (needs ≥2 present features tonight to compute a distance).
  final feats = <ana.AnomalyFeatures>[
    for (var i = 0; i < n; i++)
      ana.AnomalyFeatures(
        rhr: settled(i, rhrList[i]),
        hrv: settled(i, rmssdList[i]),
        temp: settled(i, tempList[i]),
        resp: settled(i, respList[i]),
      ),
  ];
  final anomaly = ana.multivariateAnomaly(dates, feats);

  // ── CTL/ATL/TSB training load from the daily-TRIMP series ──────────────────
  // `ctlAtlTsb` is an EWMA that treats its input as ONE SAMPLE PER CALENDAR DAY
  // (λ = 1 − e^(−1/τ) per element) and documents "a missing day contributes a
  // 0-load impulse (rest day) — the EWMA decays". Filtering to only the days
  // that carry a TRIMP handed it a COMPRESSED calendar instead: a user who
  // trains sporadically (say 10 loaded days across 90) got 10 consecutive
  // "days" of load with no decay between them, so fitness/fatigue never fell
  // across the gaps and TSB was systematically wrong. Build a DENSE per-day
  // series over the observed date span instead — a day with no TRIMP, and a
  // calendar day with no derived row at all, are both 0-load impulses.
  final dailyTrimp = _denseDailyTrimp(dates, [
    for (final d in days) _numOrNull(d['trimp']),
  ]);
  final load = ana.ctlAtlTsb(dailyTrimp);

  // ── skin-temp illness flag (Smarr, cycle-aware) ────────────────────────────
  final tempIllness = ana.tempIllnessFlag(dates, [
    for (var i = 0; i < n; i++) settled(i, tempList[i]),
  ]);

  // ── circadian: mid-sleep, free/work split, jetlag, chronotype, sleep debt ──
  // mid-sleep epoch = (onset+wake)/2; local clock-hours in [0,24) via mod-day.
  // durationH = tst_min/60. APPROXIMATION: we lack a real work/free calendar,
  // so we split free (Sat/Sun) vs work (Mon–Fri) purely by the calendar
  // weekday of `date` (DateTime.parse(date).weekday: 6,7 => free).
  final freeMidH = <double>[];
  final workMidH = <double>[];
  final freeDurH = <double>[];
  final allDurH = <double>[];
  for (final d in days) {
    final onset = (d['onset_sec'] as num?)?.toDouble();
    final wake = (d['wake_sec'] as num?)?.toDouble();
    final tstMin = (d['tst_min'] as num?)?.toDouble();
    final dur = tstMin == null ? null : tstMin / 60.0;
    if (dur != null) allDurH.add(dur);
    if (onset == null || wake == null) continue;
    final midSec = (onset + wake) / 2.0;
    // LOCAL clock-hours [0,24). onset/wake are epoch SECONDS (UTC); `% 86400`
    // would give the UTC time-of-day, not the user's wall clock — convert via a
    // local DateTime so a UTC+5:30 user's 08:00 wake reads as 08:00, not 02:30.
    final midH = _localTodMin(midSec.round()) / 60.0;
    final free = _isFreeDay(d['date'] as String?);
    if (free) {
      freeMidH.add(midH);
      if (dur != null) freeDurH.add(dur);
    } else {
      workMidH.add(midH);
    }
  }
  final avgWeekDurH = _mean(allDurH) ?? 0.0;

  final socialJetlag = ana.socialJetlag(freeMidH, workMidH);
  final chronotype = ana.chronotype(
    freeMidH,
    freeDurH,
    avgWeekSleepDurH: avgWeekDurH,
    totalDaysObserved: allDurH.length,
  );

  // sleep debt: recent = last up-to-7 durations; free = free-day durations.
  final recentDurH = allDurH.length <= 7
      ? allDurH
      : allDurH.sublist(allDurH.length - 7);
  final sleepDebt = ana.sleepDebt(recentDurH, freeDurH);

  // ── percentile-of-you for today vs history (history = all-but-last) ────────
  final percentiles = <String, dynamic>{
    'rmssd': _pctOfYou(rmssdList),
    'rhr': _pctOfYou(rhrList),
    'readiness': _pctOfYou(readyList),
  };

  // ── glass-box readiness from today's value + history per input ─────────────
  // rmssd higher-better; rhr/resp lower-better; skin_temp_z lower-ABS better
  // (so we orient temp by its absolute deviation, lower=better).
  final gbInputs = <ana.GlassBoxInput>[];
  final gbRmssd = _glassInput('hrv', rmssdList, ana.wHrv, lowerIsBetter: false);
  if (gbRmssd != null) gbInputs.add(gbRmssd);
  final gbRhr = _glassInput('rhr', rhrList, ana.wRhr, lowerIsBetter: true);
  if (gbRhr != null) gbInputs.add(gbRhr);
  final gbResp = _glassInput('resp', respList, ana.wResp, lowerIsBetter: true);
  if (gbResp != null) gbInputs.add(gbResp);
  // temp: use absolute z so "further from your baseline" is worse.
  final gbTemp = _glassInput(
    'temp',
    _absList(tempList),
    ana.wTemp,
    lowerIsBetter: true,
  );
  if (gbTemp != null) gbInputs.add(gbTemp);
  // NOT the headline score — `readinessComposite` is, and it is computed
  // elsewhere. This call is kept only for glassBoxReadiness's percentile-of-you
  // breakdown and deterministic narrative, which readinessComposite does not
  // produce, and for back-compat with the stored "readiness_glassbox" key.
  //
  // Migrating this to readinessComposite is a deliberate open decision, not an
  // oversight: it changes user-visible numbers, so it needs a kAlgoVersion bump
  // and a release note. Suppressed rather than silently switched.
  // ignore: deprecated_member_use
  final glassBox = ana.glassBoxReadiness(gbInputs);

  // ── breathing-rate variability across the resp-rate series ─────────────────
  final brpm = <double>[for (final v in respList) ?v];
  final brv = ana.breathingRateVariability(brpm);

  // ── true Phillips SRI across days on a 1440-epoch (1-min) clock grid ───────
  final sri = _crossDaySri(days);

  // ── SLEEP COACH: need (baseline + debt + strain − naps) + performance +
  //    recommended bedtime + cycle-aligned wake (all forward-looking for tonight).
  // baseline need = the personal OSD (from sleepDebt) when known, else 8 h.
  final osdH = sleepDebt.present ? sleepDebt.value!.osdHours : null;
  // Personal optimal sleep duration, but floored/capped to a physiological band:
  // the OSD estimate is noisy with few nights and can read implausibly low
  // (e.g. 5.6 h), which would push the recommended bedtime far too late. Adults
  // need ~7–9.5 h; clamp into that range (default 8 h when no estimate).
  final baselineNeedSec = ((osdH ?? 8.0).clamp(7.0, 9.5)) * 3600.0;
  final debtSec =
      (sleepDebt.present ? (sleepDebt.value!.debtHours ?? 0.0) : 0.0) * 3600.0;
  // TODAY's strain only. `_lastNum` walked backward to the last non-null, so a
  // day whose strain compute abstained built tonight's bonus out of an EARLIER
  // day's workout — imputation (AGENTS §3.3), and invisible, since the number
  // lands inside `need_sec` with nothing surfacing it.
  //
  // Unlike the nap credit below, 0 here is NOT the cautious direction: strain is
  // ADDED (up to 45 min via sleepNeed's strainBonusSec), so abstaining removes
  // sleep from the recommendation rather than adding it. It is still right, on
  // two grounds that are not "it's safe":
  //   - Carrying yesterday forward is not a safety margin either. It inflates
  //     need only when yesterday happened to be harder than today, and deflates
  //     it when yesterday was a rest day — noise around the true value, not a
  //     conservative bound, and forbidden regardless.
  //   - Strain is a same-day ACCUMULATING quantity that starts at 0 and only
  //     rises. Before today logs anything, 0 is where it genuinely sits, not a
  //     substituted default. The bonus grows as the day's real strain arrives.
  // Because that direction is not the cautious one, the substitution is not
  // allowed to be silent: `strain_bonus_min` below reports what the bonus
  // actually added, and stays NULL (never 0) when today produced no reading —
  // which is the case where up to 45 min of need went missing.
  final todayStrainNum = _todayNum(days, 'strain');
  final todayStrain = todayStrainNum ?? 0.0;
  // TODAY's naps only, and minutes ASLEEP (the analytics detector reports TST
  // and in-bed separately now). No reading means NO credit — that leaves the
  // recommendation slightly high, which is the safe direction; reaching back a
  // day to find a number would be the unsafe one.
  final todayNapMin = _todayNum(days, 'nap_min');
  final todayNapSec = (todayNapMin ?? 0.0) * 60.0;
  final need = ana.sleepNeed(
    baselineNeedSec: baselineNeedSec,
    sleepDebtSec: debtSec < 0 ? 0.0 : debtSec,
    dayStrain: todayStrain,
    napCreditSec: todayNapSec,
  );
  // What the credit ACTUALLY changed. `sleepNeed` clamps to [6 h, 11 h] AFTER
  // subtracting, so a large credit against a low baseline is only partly
  // realized — a 3 h nap does not remove 3 h of need. Disclosing the raw nap
  // minutes would state a reduction the number above never took.
  final needNoNap = ana.sleepNeed(
    baselineNeedSec: baselineNeedSec,
    sleepDebtSec: debtSec < 0 ? 0.0 : debtSec,
    dayStrain: todayStrain,
    napCreditSec: 0.0,
  );
  final appliedNapCreditMin = (todayNapMin == null ||
          !need.present ||
          !needNoNap.present)
      ? null
      : ((needNoNap.value!.needSec - need.value!.needSec) / 60).round();
  // What the strain bonus ACTUALLY added, measured the same way `nap_credit_min`
  // measures the nap: re-run at the real operating point with the strain zeroed
  // and diff. The [6 h, 11 h] clamp applies AFTER adding, so against a high
  // baseline + debt the bonus is only partly realized — disclosing the raw
  // (strain/21)*45 would state an increase `need_sec` never took.
  //
  // Null when today produced no strain reading. That is the ONE case that
  // matters most here: a confident 0 says "you rested today", while null says
  // "we could not measure today's strain, so tonight's need is short by up to
  // 45 min". Collapsing the two would re-hide exactly what the today-scoping
  // fix above exposed.
  final needNoStrain = ana.sleepNeed(
    baselineNeedSec: baselineNeedSec,
    sleepDebtSec: debtSec < 0 ? 0.0 : debtSec,
    dayStrain: 0.0,
    napCreditSec: todayNapSec,
  );
  final appliedStrainBonusMin = (todayStrainNum == null ||
          !need.present ||
          !needNoStrain.present)
      ? null
      : ((need.value!.needSec - needNoStrain.value!.needSec) / 60).round();
  // last night's TST (sec) for performance.
  final lastTstMin = _lastNum(days, 'tst_min');
  final perf = (need.present && lastTstMin != null)
      ? ana.sleepPerformance(lastTstMin * 60.0, need.value!.needSec)
      : const ana.Metric<ana.SleepPerformance>.absent(
          tier: ana.Tier.estimate,
          inputs_used: ['tst', 'sleep_need'],
        );
  // typical wake clock-minute + efficiency from recent days (medians).
  final wakeMins = <double>[
    for (final d in days)
      if (d['wake_sec'] != null) _localTodMin((d['wake_sec'] as num).toInt()),
  ];
  final effs = <double>[for (final d in days) ?_numOrNull(d['efficiency'])];
  final typicalWakeMin = _median(wakeMins);
  final typicalEff = _median(effs) ?? 88.0;
  final bedtime = (need.present && typicalWakeMin != null)
      ? ana.recommendedBedtime(
          needSec: need.value!.needSec,
          typicalWakeMinOfDay: typicalWakeMin,
          typicalEfficiencyPct: typicalEff,
        )
      : const ana.Metric<ana.BedtimeRec>.absent(
          tier: ana.Tier.estimate,
          inputs_used: ['sleep_need', 'wake_time'],
        );
  final wakeRec = (need.present && bedtime.present)
      ? ana.recommendedWake(
          bedtimeMinOfDay: bedtime.value!.bedtimeMinOfDay,
          needSec: need.value!.needSec,
        )
      : const ana.Metric<ana.WakeRec>.absent(
          tier: ana.Tier.estimate,
          inputs_used: ['sleep_need', 'bedtime'],
        );

  // ── STRAIN COACH: recovery-gated target for today (uses today's recovery +
  //    the CTL/ATL/TSB load). Absent until we have a recovery value today.
  final recToday = readyList.isEmpty ? null : readyList.last;
  final ls = load.present ? load.value : null;
  final strainTgt = ana.strainTarget(
    recovery0to100: recToday,
    ctl: ls?.ctl,
    atl: ls?.atl,
    tsb: ls?.tsb,
  );

  // ── VO₂max + Fitness Age (physiological age). Resting VO₂max (Uth HRmax:RHR)
  //    over the baseline RHR; Fitness Age composites VO₂max + RHR + HRV + sleep +
  //    steps vs age-norms. All ESTIMATE, absent on missing inputs.
  final age = _numOrNull(profile['age']);
  final sexStr = (profile['sex'] as String?)?.toLowerCase();
  final sex = workoutSex(sexStr) == 'female' ? ana.Sex.female : ana.Sex.male;
  final maxHr = age == null ? null : 208 - 0.7 * age; // Tanaka
  final baseRhr = _median(<double>[for (final v in rhrList) ?v]);
  final baseRmssd = _median(<double>[for (final v in rmssdList) ?v]);
  final vo2 = ana.vo2maxEstimate(
    restingHr: baseRhr,
    maxHr: maxHr,
    sex: sex,
    age: age,
  );
  final medTstMin = _median(<double>[
    for (final d in days) ?_numOrNull(d['tst_min']),
  ]);
  final medSteps = _median(<double>[
    for (final d in days) ?_numOrNull(d['steps']),
  ]);
  final physAge = age == null
      ? const ana.Metric<ana.PhysioAge>.absent(
          tier: ana.Tier.estimate,
          inputs_used: ['profile'],
        )
      : ana.physiologicalAge(
          chronologicalAge: age,
          sex: sex,
          vo2max: vo2.present ? vo2.value : null,
          restingHr: baseRhr,
          rmssd: baseRmssd,
          sleepDurationH: medTstMin == null ? null : medTstMin / 60.0,
          sleepEfficiency: _median(effs),
          dailySteps: medSteps,
        );

  // ── latest per-family flags + JSON-safe assembly ───────────────────────────
  final latestIllness = illness.isEmpty ? null : illness.last;
  final latestAnomaly = anomaly.isEmpty ? null : anomaly.last;
  final latestTemp = tempIllness.isEmpty ? null : tempIllness.last;

  // per-day flags (for notifications / trends): asleep/illness/anomaly/temp,
  // plus the nightly RESTING HR the "your resting HR trend shifted" CUSUM
  // notification reads back off these rows. That consumer
  // (`DerivationEngine._runNotifications`) needed `r['rhr']` and this builder
  // never emitted it, so its series was always empty, its `length >= 10` gate
  // never passed, and the notification was dead code. The value is already
  // computed right here (`rhrList`, parallel to `dates`) — emit it rather than
  // delete a wanted feature. Null stays null (the consumer filters on `is num`).
  final recent = <Map<String, dynamic>>[];
  for (var i = 0; i < n; i++) {
    recent.add({
      'date': dates[i],
      'rhr': rhrList[i],
      'illness': i < illness.length && illness[i].state == ana.IllnessState.red,
      'anomaly': i < anomaly.length && anomaly[i].flagged,
      'temp':
          i < tempIllness.length &&
          tempIllness[i].flag == ana.TempFlag.elevated,
    });
  }

  return <String, dynamic>{
    'computed_at_marker': true,
    'n_days': n,
    'illness': latestIllness?.toJson(),
    'anomaly': latestAnomaly?.toJson(),
    'temp_illness': latestTemp?.toJson(),
    'load': load.toJson((v) => v.toJson()),
    'regularity': sri.toJson((v) => v.toJson()),
    'social_jetlag': socialJetlag.toJson((v) => v.toJson()),
    'chronotype': chronotype.toJson((v) => v.toJson()),
    'sleep_debt': sleepDebt.toJson((v) => v.toJson()),
    'readiness_glassbox': glassBox.toJson((v) => v.toJson()),
    'brv': brv.toJson((v) => v.toJson()),
    // ── Coaching + fitness (forward-looking, today) ──
    'sleep_coach': <String, dynamic>{
      'need': need.toJson((v) => v.toJson()),
      // Minutes the nap credit ACTUALLY removed from `need` — not the raw nap
      // minutes, which the clamp can partly swallow. Lets the card show the
      // adjustment instead of applying it invisibly. Null means today produced
      // no nap reading, which is different from a confident zero: the UI must
      // not render "−0m" for "we do not know".
      'nap_credit_min': appliedNapCreditMin,
      // Minutes the strain bonus ACTUALLY added to `need`, same measure-what-
      // was-applied rule as `nap_credit_min` (the clamp can swallow part of it).
      // Null means today produced no strain reading — NOT a rest day. The UI
      // must not render "+0m" for "we do not know", and the missing bonus is
      // worth up to 45 min of need.
      'strain_bonus_min': appliedStrainBonusMin,
      'performance': perf.toJson((v) => v.toJson()),
      'bedtime': bedtime.toJson((v) => v.toJson()),
      'wake': wakeRec.toJson((v) => v.toJson()),
    },
    'strain_coach': strainTgt.toJson((v) => v.toJson()),
    'vo2max': vo2.toJson(),
    'fitness_age': physAge.toJson((v) => v.toJson()),
    'percentiles': percentiles,
    'recent': recent,
  };
}

// ── helpers (all pure) ───────────────────────────────────────────────────────

double? _numOrNull(Object? v) => v is num ? v.toDouble() : null;

/// Local wall-clock minute-of-day [0,1440) for an epoch SECOND. Uses a local
/// DateTime (the isolate inherits the device timezone) so clock times match what
/// the user sees — NOT the UTC `% 86400` time-of-day. Deterministic given the
/// system zone (same property the file's existing DateTime.parse(date) relies on).
double _localTodMin(int epochSec) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
  return t.hour * 60.0 + t.minute + t.second / 60.0;
}

double? _mean(List<double> xs) {
  if (xs.isEmpty) return null;
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

/// Median of present values (null when empty). Pure.
double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
}

/// The value of [key] on the MOST RECENT day only, or null if that day did not
/// produce one.
///
/// Unlike [_lastNum] this never reaches back to an earlier day. For a
/// TODAY-scoped quantity that is the difference between "we have no reading"
/// and a fabricated one: `_lastNum(days, 'nap_min')` would credit YESTERDAY's
/// naps against tonight's sleep need whenever today's nap detection abstained,
/// which is imputation (AGENTS §3.3) and always errs toward recommending less
/// sleep than the user needs.
/// Requires the last record to be explicitly stamped `is_today` (see
/// `_refreshCrossDayInputArtifact`). Taking `days.last` positionally is not
/// enough: on a day with no derived row yet, the most recent record IS
/// yesterday, so a positional read reproduces the very imputation this replaces.
double? _todayNum(List<Map<String, dynamic>> days, String key) {
  if (days.isEmpty) return null;
  final last = days.last;
  if (last['is_today'] != true) return null;
  return _numOrNull(last[key]);
}

/// The last non-null value of [key] across the (oldest-first) day records.
double? _lastNum(List<Map<String, dynamic>> days, String key) {
  for (var i = days.length - 1; i >= 0; i--) {
    final v = _numOrNull(days[i][key]);
    if (v != null) return v;
  }
  return null;
}

/// Sat/Sun => free day. We lack a real work/free calendar; the weekday split is
/// an explicit approximation (DateTime.parse is a pure function of the string).
bool _isFreeDay(String? date) {
  if (date == null || date.isEmpty) return false;
  final dt = DateTime.tryParse(date);
  if (dt == null) return false;
  return dt.weekday == DateTime.saturday || dt.weekday == DateTime.sunday;
}

/// Guard on how far [_denseDailyTrimp] will densify. Past this the input is not
/// a plausible recent-history window (a corrupt/absurd date), so we fall back to
/// the raw per-row series rather than allocating an unbounded list.
const int _maxDenseTrimpDays = 400;

/// A DENSE per-calendar-day TRIMP series (oldest→newest) over the span covered
/// by [dates], with every unloaded or unobserved day contributing a 0 impulse.
///
/// [dates] and [trimps] are parallel (one entry per derived day, oldest first);
/// [dates] may skip calendar days entirely (an underived day has no row).
/// PURE: `DateTime.parse` / `DateTime(y, m, d + 1)` are deterministic functions
/// of the input strings, and the day-step normalizes DST-length days correctly.
List<double> _denseDailyTrimp(List<String> dates, List<double?> trimps) {
  // NO observed load at all is not "a run of zero-load days" — it is no load
  // history. Densifying it would hand the EWMA a synthetic all-zero series and
  // turn "we have never seen a workout" into a confident CTL/ATL/TSB of 0,
  // which is the fabrication this whole pass exists to remove. Abstain by
  // handing back an empty series and let the load model decline.
  if (!trimps.any((t) => t != null)) return const <double>[];
  final byDate = <String, double>{};
  String? first, last;
  for (var i = 0; i < dates.length && i < trimps.length; i++) {
    final date = dates[i];
    if (date.isEmpty || DateTime.tryParse(date) == null) continue;
    byDate[date] = trimps[i] ?? 0.0;
    first ??= date;
    if (last == null || date.compareTo(last) > 0) last = date;
    if (date.compareTo(first) < 0) first = date;
  }
  if (first == null || last == null) return const <double>[];
  final start = DateTime.parse(first);
  final end = DateTime.parse(last);
  final out = <double>[];
  var cursor = DateTime(start.year, start.month, start.day);
  final stop = DateTime(end.year, end.month, end.day);
  while (!cursor.isAfter(stop)) {
    if (out.length >= _maxDenseTrimpDays) {
      // Implausible span — don't densify; the honest per-row series is better
      // than an arbitrarily long zero-padded one.
      return [for (final v in trimps) v ?? 0.0];
    }
    out.add(byDate[_dateKey(cursor)] ?? 0.0);
    cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
  }
  return out;
}

String _dateKey(DateTime d) {
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// Absolute value of each present element (used to orient skin-temp by |z|).
List<double?> _absList(List<double?> xs) => [for (final v in xs) v?.abs()];

/// percentile-of-you JSON for the LAST value vs the all-but-last history.
/// Returns the honest absent envelope when there is no last value / no history.
Map<String, dynamic> _pctOfYou(List<double?> series) {
  if (series.isEmpty || series.last == null) {
    // No value tonight -> absent envelope (the package's own shape).
    return ana
        .percentileOfYou(double.nan, const <double>[])
        .toJson((v) => v.toJson());
  }
  final value = series.last!;
  final history = <double>[
    for (var i = 0; i < series.length - 1; i++)
      if (series[i] != null) series[i]!,
  ];
  return ana.percentileOfYou(value, history).toJson((v) => v.toJson());
}

/// Build a GlassBoxInput for the LAST value vs the all-but-last history. Returns
/// null when there is no value tonight (so the input is simply absent — the
/// package reweights over the inputs that ARE present, never zero-filling).
ana.GlassBoxInput? _glassInput(
  String label,
  List<double?> series,
  double weight, {
  required bool lowerIsBetter,
}) {
  if (series.isEmpty || series.last == null) return null;
  final history = <double>[
    for (var i = 0; i < series.length - 1; i++)
      if (series[i] != null) series[i]!,
  ];
  return ana.GlassBoxInput(
    label: label,
    value: series.last!,
    history: history,
    weight: weight,
    lowerIsBetter: lowerIsBetter,
  );
}

/// Reconstruct a per-minute asleep series for each day on a 1440-epoch grid from
/// the day's hypnogram (stage != 'wake' within [onset,wake] => asleep; minutes
/// with no hypnogram coverage => valid=false), concatenate across days, then run
/// the true Phillips SRI. If too few covered days, the package returns absent.
ana.Metric<ana.SriResult> _crossDaySri(List<Map<String, dynamic>> days) {
  const epochsPerDay = 1440; // 1-minute epochs over 24 h
  final sleepWake = <bool>[];
  final valid = <bool>[];

  for (final d in days) {
    // Fresh blank day grid (all wake, all invalid until covered).
    final asleep = List<bool>.filled(epochsPerDay, false);
    final cov = List<bool>.filled(epochsPerDay, false);

    final hyp = d['hypnogram'];
    if (hyp is List) {
      for (final seg in hyp) {
        if (seg is! Map) continue;
        final start = (seg['start'] as num?)?.toDouble();
        final end = (seg['end'] as num?)?.toDouble();
        final stage = seg['stage'] as String?;
        if (start == null || end == null) continue;
        // Segment bounds are epoch SECONDS; map to clock-minute-of-day [0,1440).
        // this was using `start % 86400` directly, which is the UTC
        // time-of-day, not the user's wall clock - the exact mistake
        // _localTodMin (right here in this same file, used correctly at
        // line ~100) already exists to avoid.
        final startMin = _localTodMin(start.round()).floor();
        // end is exclusive of the segment's trailing edge; cover [start,end).
        final endMinRaw = _localTodMin(end.round()).ceil();
        // WRAP, don't clamp. Both bounds are clock-minutes-of-day in [0,1440),
        // so a segment crossing local midnight reads e.g. start=1430,
        // end=20 — and the old `for (m = startMin; m < endMin; m++)` simply
        // never executed, silently DROPPING that segment (the comment claimed
        // it "clamps into grid"; it didn't). Every night has exactly one such
        // segment, so sleep-regularity was always computed with a hole at the
        // boundary. Unwrap the end past 1440 and write back modulo the grid.
        // `endMinRaw == startMin` stays a genuinely empty (sub-minute) segment.
        final endMin =
            endMinRaw < startMin ? endMinRaw + epochsPerDay : endMinRaw;
        final span = math.min(endMin - startMin, epochsPerDay);
        final asleepSeg = stage != null && stage != 'wake';
        for (var k = 0; k < span; k++) {
          final m = (startMin + k) % epochsPerDay;
          cov[m] = true;
          if (asleepSeg) asleep[m] = true;
        }
      }
    }
    sleepWake.addAll(asleep);
    valid.addAll(cov);
  }

  return ana.phillipsSri(sleepWake, epochsPerDay, valid: valid);
}
