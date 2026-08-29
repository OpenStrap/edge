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

import '../data/day_label.dart';

// Pure string helper only (the `need_input:name=…` note grammar) — no DB, no
// IO, no Flutter binding, so importing it does not compromise this file's
// isolate safety. One grammar for "a required input was missing" across both
// pipelines rather than a second one here.
import 'onehz_pipeline.dart' show needInputNote;

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
/// [cycleStartDates] are the user's own logged cycle-start days (`YYYY-MM-DD`,
/// any order). They are a CALENDAR log, never a detection: everything derived
/// from them says "the second half of your logged cycle", never "your luteal
/// phase". Empty ⇒ every cycle-aware family behaves exactly as it did before.
///
/// [sessionTypesByDate] maps a day label to every SAVED session that started
/// that day (TS-11). A day with more than one is dropped by the analytics, not
/// split — it belongs to no single type. Empty ⇒ `session_cost` is absent,
/// which is also its state for the first ten sessions of any type.
Map<String, dynamic> buildCrossDayBundle(
  List<Map<String, dynamic>> daysOldestFirst,
  Map<String, dynamic> profile, {
  List<String> cycleStartDates = const [],
  Map<String, List<String>> sessionTypesByDate = const {},
}) {
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
  // WH-01 — the `luteal` argument was written, typed and never passed, so the
  // `lutealConfound` branch has never once executed and the flag has been
  // crying "elevated" for the two weeks a month when a sustained rise is the
  // most ordinary thing in the world. It ANNOTATES, never silences: the day
  // exception still fires, with the confound named. Suppressing a real illness
  // is worse than the false alarm.
  final luteal = _lutealFlags(dates, cycleStartDates);
  final tempIllness = ana.tempIllnessFlag(dates, [
    for (var i = 0; i < n; i++) settled(i, tempList[i]),
  ], luteal: luteal);

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
  // rhr is LOWER-is-better — the same orientation `_glassInput` ten lines below
  // has always passed for this exact list. Unoriented, a night with the user's
  // lowest resting HR in a month came back labelled "among your worst".
  final percentiles = <String, dynamic>{
    'rmssd': _pctOfYou(rmssdList, ana.Better.higher),
    'rhr': _pctOfYou(rhrList, ana.Better.lower),
    'readiness': _pctOfYou(readyList, ana.Better.higher),
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
  // SLP-08 — which two nights. `SriPair.dayIndex` indexes THIS day list and
  // nothing else (the analytics never sees a date), so here is the only place
  // it can be resolved into the two nights it compared. Pairs the mask left too
  // thin were already dropped upstream, so a half-unobserved weekend cannot top
  // the list for having no data.
  //
  // It is arithmetic, not a verdict: a decomposition of a number already on
  // screen. It does not license telling anyone their weekend is harming them.
  final sriJson = sri.toJson((v) => v.toJson());
  final sriValue = sriJson['value'];
  if (sriValue is Map) {
    for (final p in ((sriValue['pairs'] as List?) ?? const []).whereType<Map>()) {
      final d = (p['day_index'] as num?)?.toInt();
      if (d == null || d <= 0 || d >= dates.length) continue;
      p['prev_date'] = dates[d - 1];
      p['date'] = dates[d];
    }
  }

  // ── TS-12 — overreaching as TWO FACTS, not a score ────────────────────────
  // A coincidence detector over two outputs that already run every day. The
  // recent nights and the baseline they are judged against must not overlap, or
  // the elevation is compared against itself — hence the split below.
  //
  // IN-APP FEED ONLY. No new notification class: `_runNotifications` reads
  // `illness`/`anomaly`/`temp_illness` and this key is deliberately not one of
  // them. Illness, travel, altitude, alcohol and a run of poor sleep all
  // produce the identical pair, and the copy has to name them.
  const recentNights = 5;
  final recentFrom = math.max(0, n - recentNights);
  final overreaching = ana.overreachingConjunction(
    load: load,
    rhrRecent: [
      for (var i = recentFrom; i < n; i++) settled(i, rhrList[i]),
    ],
    rhrBaselineWindow: [
      for (var i = math.max(0, recentFrom - 28); i < recentFrom; i++)
        ?rhrList[i],
    ],
  );

  // ── TS-11 — what each session type cost you the next morning ──────────────
  // Reuses the daily series and the robust baseline; nothing new is measured.
  // The refusals ARE the feature (multi-session days dropped, thin nights
  // dropped, under 10 mornings refused outright), because the confounding is
  // total: hard sessions cluster with late nights, alcohol, stress and travel.
  // Association only, with n printed beside every row.
  final sleepCoverage = <double?>[
    for (final d in days) _numOrNull(d['sleep_coverage']),
  ];
  Map<String, dynamic> morningEffects(String metric, List<double?> series) =>
      ana
          .sessionMorningEffects(
            dates: dates,
            values: series,
            metric: metric,
            sessionTypesByDate: sessionTypesByDate,
            coverage: sleepCoverage,
          )
          .toJson((v) => [for (final e in v) e.toJson()]);

  // ── circadian rhythm: nonparametric battery + 24 h cosinor ────────────────
  final circadian = _crossDayCircadian(days);

  // ── SLEEP COACH: need (baseline + debt + strain − naps) + performance +
  //    recommended bedtime + cycle-aligned wake (all forward-looking for tonight).
  // baseline need = the personal OSD (from sleepDebt) when known, else 8 h.
  final osdH = sleepDebt.present ? sleepDebt.value!.osdHours : null;
  // Personal optimal sleep duration, floored/capped to a physiological band:
  // the OSD estimate is noisy with few nights and can read implausibly low
  // (e.g. 5.6 h), which would push the recommended bedtime far too late. Adults
  // need ~7-9.5 h, so clamp into that range.
  //
  // NO 8 h DEFAULT. It used to substitute the population mean when there was no
  // personal estimate, and every number built on it — tonight's need, the
  // recommended bedtime, the cycle-aligned wake time and sleep performance —
  // was then a population figure presented as the user's own, with nothing on
  // screen saying so. Absent input yields an absent metric; the coach fills in
  // once enough nights exist to estimate an OSD.
  final double? baselineNeedSec =
      osdH == null ? null : (osdH.clamp(7.0, 9.5)) * 3600.0;
  final debtSec =
      (sleepDebt.present ? (sleepDebt.value!.debtHours ?? 0.0) : 0.0) * 3600.0;
  const noOsd = ana.Metric<ana.SleepNeed>.absent(
    tier: ana.Tier.estimate,
    inputs_used: ['osd_hours'],
    note: 'need_baseline:have=0,need=1',
  );
  ana.Metric<ana.SleepNeed> needAt({
    required double dayStrain,
    required double napCreditSec,
  }) =>
      baselineNeedSec == null
          ? noOsd
          : ana.sleepNeed(
              baselineNeedSec: baselineNeedSec,
              sleepDebtSec: debtSec < 0 ? 0.0 : debtSec,
              dayStrain: dayStrain,
              napCreditSec: napCreditSec,
            );
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
  final need = needAt(dayStrain: todayStrain, napCreditSec: todayNapSec);
  // What the credit ACTUALLY changed. `sleepNeed` clamps to [6 h, 11 h] AFTER
  // subtracting, so a large credit against a low baseline is only partly
  // realized — a 3 h nap does not remove 3 h of need. Disclosing the raw nap
  // minutes would state a reduction the number above never took.
  final needNoNap = needAt(dayStrain: todayStrain, napCreditSec: 0.0);
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
  final needNoStrain = needAt(dayStrain: 0.0, napCreditSec: todayNapSec);
  final appliedStrainBonusMin = (todayStrainNum == null ||
          !need.present ||
          !needNoStrain.present)
      ? null
      : ((need.value!.needSec - needNoStrain.value!.needSec) / 60).round();
  // last night's TST (sec) for performance.
  final lastTstMin = _lastNum(days, 'tst_min');
  final perf = (need.present && lastTstMin != null)
      ? ana.sleepPerformance(lastTstMin * 60.0, need.value!.needSec)
      : ana.Metric<ana.SleepPerformance>.absent(
          tier: ana.Tier.estimate,
          inputs_used: const ['tst', 'sleep_need'],
          // Name the input that is actually missing. When it is the need
          // itself, carry the need's own reason forward rather than restating
          // it as "no sleep need" — that would name a sibling metric, which is
          // the failure this whole convention exists to stop.
          note: need.present ? needInputNote('tst_min') : need.note,
        );
  // typical wake clock-minute + efficiency from recent days (medians).
  final wakeMins = <double>[
    for (final d in days)
      if (d['wake_sec'] != null) _localTodMin((d['wake_sec'] as num).toInt()),
  ];
  final effs = <double>[for (final d in days) ?_numOrNull(d['efficiency'])];
  final typicalWakeMin = _median(wakeMins);
  // NO INVENTED 88 %. Bedtime is "wake − need ÷ efficiency", so a substituted
  // efficiency moves the recommendation by real minutes (at a need of 8 h, 88 %
  // vs a true 95 % is 36 min of bedtime the user did not need to give up). A
  // user with no measured efficiency yet gets no recommendation — the same rule
  // that already makes `need` itself absent without a personal OSD.
  final typicalEff = _median(effs);
  final bedtime = (need.present && typicalWakeMin != null && typicalEff != null)
      ? ana.recommendedBedtime(
          needSec: need.value!.needSec,
          typicalWakeMinOfDay: typicalWakeMin,
          typicalEfficiencyPct: typicalEff,
        )
      : ana.Metric<ana.BedtimeRec>.absent(
          tier: ana.Tier.estimate,
          inputs_used: const ['sleep_need', 'wake_time', 'efficiency'],
          note: !need.present
              ? need.note
              : typicalWakeMin == null
              ? needInputNote('wake_time')
              : needInputNote('efficiency'),
        );
  // Same efficiency as the bedtime above, by construction — the two ends of one
  // night must be backed off the same time-in-bed. `bedtime.present` already
  // implies `typicalEff != null`; the check is here so the compiler agrees.
  final wakeRec = (need.present && bedtime.present && typicalEff != null)
      ? ana.recommendedWake(
          bedtimeMinOfDay: bedtime.value!.bedtimeMinOfDay,
          needSec: need.value!.needSec,
          typicalEfficiencyPct: typicalEff,
        )
      : ana.Metric<ana.WakeRec>.absent(
          tier: ana.Tier.estimate,
          inputs_used: const ['sleep_need', 'bedtime', 'efficiency'],
          note: !need.present
              ? need.note
              : !bedtime.present
              ? bedtime.note
              : needInputNote('efficiency'),
        );

  // ── STRAIN COACH: recovery-gated target for today (uses today's recovery +
  //    the CTL/ATL/TSB load). Absent until we have a recovery value today.
  // `readyList.last` is POSITIONAL, and `days` only contains rows that exist —
  // so on a day whose derive has not run yet the "today" it read was
  // yesterday's readiness, and the target below was built from it. `_todayNum`
  // is the stamped read this comment already promised; when today has no row,
  // recovery is null and `strainTarget` returns absent, which is the honest
  // outcome and the one the screens already render.
  final recToday = _todayNum(days, 'readiness');
  final ls = load.present ? load.value : null;
  final strainTgt = ana.strainTarget(
    recovery0to100: recToday,
    ctl: ls?.ctl,
    atl: ls?.atl,
    tsb: ls?.tsb,
  );

  // VO₂max and Fitness Age used to be computed here. Both are DELETED, not
  // disabled. `maxHr` was a constant per user and `vo2maxEstimate` returned
  // 15.3·maxHr/restingHr, so the app's VO₂max was exactly k/RHR — the RHR chart
  // with a different unit on the axis. `physiologicalAge` then subtracted
  // (vo2max−35)/5 AND added (rhr−60)/6: the same variable, the same direction,
  // counted twice, with divisors chosen by nobody. There is no honest version
  // as a number — not in years, not in mL/kg/min, and not as a trend — and a
  // submaximal estimate is 13-15 % MAPE, i.e. the same class of thing.

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
  //
  // The rhr here is deliberately RAW (not `settled`) — the trend wants today's
  // partial value. The flag travels with it so the one consumer that fires an
  // ALERT off the latest value can stand down on a half-drained night instead
  // of announcing a trend shift that corrects an hour later.
  final recent = <Map<String, dynamic>>[];
  for (var i = 0; i < n; i++) {
    recent.add({
      'date': dates[i],
      'rhr': rhrList[i],
      'unsettled': unsettled[i],
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
    // `value.pairs[]` carries the two night labels (SLP-08) alongside the
    // headline SRI — same arithmetic, decomposed.
    'regularity': sriJson,
    'overreaching': overreaching.toJson((v) => v.toJson()),
    'session_cost': {
      'rhr': morningEffects('rhr', rhrList),
      'rmssd': morningEffects('rmssd', rmssdList),
    },
    'social_jetlag': socialJetlag.toJson((v) => v.toJson()),
    'chronotype': chronotype.toJson((v) => v.toJson()),
    // IS / IV / RA / L5 / M10 (van Someren 1999) and the single-component
    // 24 h cosinor (Halberg/Nelson 1979). Both are ordinary Metric envelopes,
    // absent with a `need_baseline:` note until enough COMPLETE days exist.
    'circadian_rhythm': circadian.np,
    'circadian_cosinor': circadian.cosinor,
    // How the two above were fed: the run of consecutive fully-covered days
    // that was admitted, and the phase reference. Lets the UI say "5 of 7
    // nights" without re-deriving it from the note.
    'circadian_coverage': circadian.coverage,
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
    'percentiles': percentiles,
    'recent': recent,
  };
}

// ── helpers (all pure) ───────────────────────────────────────────────────────

double? _numOrNull(Object? v) => v is num ? v.toDouble() : null;

/// Make [value] safe to hand to `jsonEncode`, dropping only the leaves that are
/// not.
///
/// ONE bad leaf used to destroy the WHOLE cross-day artifact. `jsonEncode`
/// throws `JsonUnsupportedObjectError` on a NaN or an Infinity, and the only
/// caller wrapped the encode in a catch that logged and returned — so a single
/// non-finite double took illness, anomaly, CTL/ATL/TSB, chronotype, the sleep
/// coach, VO₂max and every percentile down with it, silently, for as long as
/// the field stayed non-finite. That is not a hypothetical: an input with too
/// little history emitted `double.nan` as its percentile, which is every user's
/// first week.
///
/// The artifact is a bag of independent metrics, so it must degrade one field
/// at a time. A non-finite number, or anything else JSON cannot represent,
/// becomes `null` — which every reader here already means as ABSENT — and its
/// dotted path is appended to [droppedPaths] so the loss is recorded rather
/// than inferred.
Object? sanitizeForJson(
  Object? value,
  List<String> droppedPaths, {
  String path = '',
}) {
  if (value == null || value is bool || value is String) return value;
  if (value is num) {
    if (value is int) return value;
    if (value.isFinite) return value;
    droppedPaths.add(path.isEmpty ? '<root>' : path);
    return null;
  }
  if (value is Map) {
    final out = <String, dynamic>{};
    for (final e in value.entries) {
      final k = e.key;
      // A non-String key cannot be a JSON object key at all; keeping the value
      // under a stringified key would invent a field name, so drop the pair.
      if (k is! String) {
        droppedPaths.add(path.isEmpty ? '<key:$k>' : '$path.<key:$k>');
        continue;
      }
      out[k] = sanitizeForJson(
        e.value,
        droppedPaths,
        path: path.isEmpty ? k : '$path.$k',
      );
    }
    return out;
  }
  if (value is List) {
    return [
      for (var i = 0; i < value.length; i++)
        sanitizeForJson(value[i], droppedPaths, path: '$path[$i]'),
    ];
  }
  // Anything else (a DateTime, an un-`toJson`ed model, …) has no JSON form.
  droppedPaths.add(path.isEmpty ? '<root>' : path);
  return null;
}

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

/// Per-night "is this date in the SECOND HALF of the cycle it belongs to",
/// parallel to [dates]. All-false when there is nothing to count from.
///
/// Each date walks back to its NEAREST PRECEDING logged start — NOT through
/// `getCycle`, which counts from the LAST start only and therefore produces
/// nonsense for every historical day. The cycle's length is the gap to the NEXT
/// logged start; the still-open cycle uses the median of her own completed
/// gaps, and with fewer than two completed cycles there is no length to use, so
/// the open cycle contributes nothing rather than a guess.
///
/// A date more than 1.5 cycles past its start is a lapse in logging, not a
/// four-week luteal phase — it stops counting.
List<bool> _lutealFlags(List<String> dates, List<String> cycleStartDates) {
  final out = List<bool>.filled(dates.length, false);
  final starts = <DateTime>[
    for (final s in cycleStartDates) ?DateTime.tryParse(s),
  ]..sort();
  if (starts.isEmpty) return out;

  final gaps = <double>[
    for (var i = 1; i < starts.length; i++)
      starts[i].difference(starts[i - 1]).inDays.toDouble(),
  ].where((g) => g >= 15 && g <= 60).toList();
  final medianGap = _median(gaps);

  for (var i = 0; i < dates.length; i++) {
    final d = DateTime.tryParse(dates[i]);
    if (d == null) continue;
    // Nearest PRECEDING start (inclusive: the start day is cycle day 1).
    var si = -1;
    for (var k = 0; k < starts.length; k++) {
      if (starts[k].isAfter(d)) break;
      si = k;
    }
    if (si < 0) continue; // before she ever logged — nothing to count from
    final elapsed = d.difference(starts[si]).inDays;
    // Closed cycle → its own measured length. Open cycle → her median, if she
    // has one.
    final len = si + 1 < starts.length
        ? starts[si + 1].difference(starts[si]).inDays.toDouble()
        : medianGap;
    if (len == null || len < 15) continue;
    if (elapsed > 1.5 * len) continue; // stale log, not a long luteal phase
    if (elapsed >= len / 2) out[i] = true;
  }
  return out;
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
    out.add(byDate[dayLabelOf(cursor)] ?? 0.0);
    cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
  }
  return out;
}

/// Absolute value of each present element (used to orient skin-temp by |z|).
List<double?> _absList(List<double?> xs) => [for (final v in xs) v?.abs()];

/// percentile-of-you JSON for the LAST value vs the all-but-last history.
/// Returns the honest absent envelope when there is no last value / no history.
///
/// [better] is which end of the scale is the GOOD end — it decides the label
/// ("among your best" vs "among your worst"), not the percentile. Getting it
/// wrong inverts the sentence the user reads: a resting HR in the 95th
/// percentile is the user's WORST night, not their best.
Map<String, dynamic> _pctOfYou(List<double?> series, ana.Better better) {
  if (series.isEmpty || series.last == null) {
    // No value tonight -> absent envelope (the package's own shape).
    return ana
        .percentileOfYou(double.nan, const <double>[], better: better)
        .toJson((v) => v.toJson());
  }
  final value = series.last!;
  final history = <double>[
    for (var i = 0; i < series.length - 1; i++)
      if (series[i] != null) series[i]!,
  ];
  return ana
      .percentileOfYou(value, history, better: better)
      .toJson((v) => v.toJson());
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

/// Minimum consecutive fully-covered days for the nonparametric battery.
///
/// IS is a between-day statistic: it asks how reproducible your 24 h profile is
/// from one day to the next, and it cannot answer that from two days. Seven is
/// the standard actigraphy recording protocol behind the published IS/IV/RA
/// reference ranges (van Someren 1999), so anything shorter would be scored
/// against norms it does not belong to.
const int kCircadianNpMinDays = 7;

/// Minimum consecutive fully-covered days for the 24 h cosinor.
///
/// A single day fits three parameters through 24 points and will always return
/// SOME amplitude and acrophase — including from noise. Three days is the point
/// at which a stable phase estimate is a claim about the person rather than
/// about one day's shape. (`cosinor` separately enforces ≥8 points and reports
/// the ADJUSTED R², so overfitting is already penalised in the fit itself.)
const int kCircadianCosinorMinDays = 3;

/// The circadian block: two envelopes plus what fed them.
typedef _Circadian = ({
  Map<String, dynamic> np,
  Map<String, dynamic> cosinor,
  Map<String, dynamic> coverage,
});

/// Nonparametric circadian metrics + a 24 h cosinor over the HOURLY HR profile.
///
/// INPUT HONESTY. The textbook input is continuous accelerometry (ENMO), and we
/// cannot use it: the 1 Hz substrate is pruned after 3 days, so no multi-day
/// accel series exists to analyse. What survives is `day_result`, which is never
/// pruned, and the per-day hourly HR profile stored on it. `circadianNonparametric`
/// names an HR series as an accepted input alongside activity, and HR carries the
/// same circadian rhythm the battery measures — but M10/L5 are then the most- and
/// least-ACTIVE-HR windows, not step counts, and RA is an HR amplitude ratio. The
/// note on each envelope says so. Skin temperature is deliberately NOT used: the
/// only stored temperature channel is `skin_temp_raw`, which is not a temperature.
///
/// DAY ADMISSION. A day enters only when all 24 local-hour bins are covered
/// (≥5 real minutes each, enforced upstream in `_hourlyHrProfile`). Missing hours
/// are never filled — an imputed hour is exactly the kind of smooth, regular
/// signal IS is designed to reward, so imputation would manufacture rhythm
/// strength out of missing data. Only the LONGEST RUN of calendar-consecutive
/// admitted days is used (ties go to the more recent one), because IV differences
/// successive epochs and a jump across a multi-day gap is not a real hour-to-hour
/// transition. `first_day`/`last_day` in the coverage block date that run.
///
/// (A spring-forward day has 23 local hours, so one bin can never be covered and
/// the day is excluded. That is the honest outcome; it costs one day, twice a year.)
_Circadian _crossDayCircadian(List<Map<String, dynamic>> days) {
  const inputs = ['hourly_hr_epochs'];
  const epochsPerDay = 24;

  // LONGEST run of calendar-consecutive days with a complete 24 h profile —
  // not the trailing one.
  //
  // This used to keep only the run alive when the loop ended, and TODAY IS
  // ALWAYS INCOMPLETE: `days` carries today flagged `unsettled` rather than
  // dropped, and today cannot have 24 covered local hours until midnight. So the
  // final day always cleared the run and `have` was 0 every day, forever — IS/IV
  // and the cosinor were absent permanently while the note claimed `have=0`
  // about a corpus with 88–97 % daily coverage. That note was a false statement
  // about the user's own data. Measured on the real gen4 export: 08-08..08-12 is
  // a 5-day run, 08-13 fails (22/24 bins), 08-14 passes, 08-15 fails — shipped
  // have=0, correct have=5.
  final run = <List<double>>[];
  final best = <List<double>>[];
  String? runFirstDate;
  String? bestFirstDate;
  String? bestLastDate;
  String? prevDate;
  void keepBest() {
    // `>=` so that on a tie the MORE RECENT run wins — a circadian profile is
    // about how the user lives now.
    if (run.isNotEmpty && run.length >= best.length) {
      best
        ..clear()
        ..addAll(run);
      bestFirstDate = runFirstDate;
      bestLastDate = prevDate;
    }
  }

  for (final d in days) {
    final date = d['date'] as String?;
    final profile = _completeHourlyProfile(d['hourly_hr']);
    if (date == null || profile == null) {
      keepBest();
      run.clear();
      runFirstDate = null;
      prevDate = null;
      continue;
    }
    if (prevDate != null && !_isNextDay(prevDate, date)) {
      keepBest();
      run.clear();
      runFirstDate = null;
    }
    if (run.isEmpty) runFirstDate = date;
    run.add(profile);
    prevDate = date;
  }
  keepBest();

  final have = best.length;
  final x = <double>[for (final day in best) ...day];

  final np = have >= kCircadianNpMinDays
      ? ana.circadianNonparametric(x, epochsPerDay)
      : ana.Metric<ana.CircadianNp>.absent(
          tier: ana.Tier.high,
          inputs_used: inputs,
          note: ana.needBaselineNote(have: have, need: kCircadianNpMinDays),
        );

  // Cosinor time base: the run is consecutive by construction, so element i is
  // exactly i hours after the run's first midnight — and hour-of-day is `i % 24`,
  // which is what makes the acrophase readable as a clock time.
  final cos = have >= kCircadianCosinorMinDays
      ? ana.cosinor([for (var i = 0; i < x.length; i++) i.toDouble()], x)
      : ana.Metric<ana.CosinorFit>.absent(
          tier: ana.Tier.high,
          inputs_used: inputs,
          note: ana.needBaselineNote(
            have: have,
            need: kCircadianCosinorMinDays,
          ),
        );

  return (
    np: _withInputNote(np.toJson((v) => v.toJson())),
    cosinor: _withInputNote(cos.toJson((v) => v.toJson())),
    coverage: <String, dynamic>{
      'days_used': have,
      'days_need_np': kCircadianNpMinDays,
      'days_need_cosinor': kCircadianCosinorMinDays,
      'first_day': bestFirstDate,
      'last_day': bestLastDate,
      'signal': 'hourly_hr',
    },
  );
}

/// Append the substrate caveat to an envelope's note, so the claim never leaves
/// this file without saying what it was computed FROM.
Map<String, dynamic> _withInputNote(Map<String, dynamic> envelope) {
  const caveat = 'computed on hourly HEART-RATE means, not accelerometry '
      '(no multi-day accel survives raw pruning): M10/L5 are the highest- and '
      'lowest-HR windows and RA is an HR amplitude ratio';
  final existing = envelope['note'];
  // Never overwrite a `need_baseline:` note — the edge parses it verbatim.
  if (existing is String && existing.startsWith('need_baseline:')) {
    return envelope;
  }
  envelope['note'] = existing is String && existing.isNotEmpty
      ? '$existing; $caveat'
      : caveat;
  return envelope;
}

/// The day's 24 hourly means, or null if ANY hour is uncovered. No imputation.
List<double>? _completeHourlyProfile(Object? hourly) {
  if (hourly is! List || hourly.length != 24) return null;
  final out = <double>[];
  for (final v in hourly) {
    if (v is! num) return null; // null hour ⇒ day not admitted
    out.add(v.toDouble());
  }
  return out;
}

/// Is [b] the calendar day immediately after [a] ('YYYY-MM-DD')?
///
/// Parsed as UTC on purpose: these are date LABELS, and local parsing makes a
/// DST day 23 or 25 hours long, which rounds `inDays` to 0 or 2 and would break
/// a run that is genuinely consecutive.
bool _isNextDay(String a, String b) {
  final da = DateTime.tryParse('${a}T00:00:00Z');
  final db = DateTime.tryParse('${b}T00:00:00Z');
  if (da == null || db == null) return false;
  return db.difference(da).inDays == 1;
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

  // SLP-08's per-pair floor. The analytics default is half a clock day (720
  // minutes), which is right for a grid built from continuous actigraphy and
  // UNREACHABLE on this one: `cov` is only set inside a hypnogram segment, so
  // an ordinary 8 h night marks 480 minutes and a pair — which needs the minute
  // observed on BOTH days — tops out around that. Left at the default the pairs
  // list is empty for every user forever, which reads as "no irregular nights"
  // rather than as a floor nobody can clear.
  //
  // 240 is four hours of clock-aligned overlap on both nights. It still throws
  // out the half-unobserved weekend the floor exists for, and it does NOT move
  // the published SRI: every accepted epoch counts toward the total whether or
  // not its pair is emitted.
  return ana.phillipsSri(sleepWake, epochsPerDay,
      valid: valid, minPairCases: 240);
}
