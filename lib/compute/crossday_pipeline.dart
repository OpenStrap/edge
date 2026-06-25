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

import 'package:openstrap_analytics/onehz.dart' as ana;

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
  final tempList = <double?>[for (final d in days) _numOrNull(d['skin_temp_z'])];

  // ── illness CUSUM (NightSignal) on nightly RHR ─────────────────────────────
  final illness = ana.illnessCusum(dates, rhrList);

  // ── multivariate anomaly {RHR↑,HRV↓,temp↑,resp↑} ───────────────────────────
  // Build one AnomalyFeatures per day (same length as dates). Days with all
  // features null still occupy a slot — the detector handles the nulls
  // internally (needs ≥2 present features tonight to compute a distance).
  final feats = <ana.AnomalyFeatures>[
    for (final d in days)
      ana.AnomalyFeatures(
        rhr: _numOrNull(d['rhr']),
        hrv: _numOrNull(d['rmssd']),
        temp: _numOrNull(d['skin_temp_z']),
        resp: _numOrNull(d['resp_rate']),
      )
  ];
  final anomaly = ana.multivariateAnomaly(dates, feats);

  // ── CTL/ATL/TSB training load from the daily-TRIMP series ──────────────────
  // Only days that actually carry a TRIMP (time-ordered) contribute; a missing
  // TRIMP is NOT a 0-load impulse here — we simply omit it (the user may not
  // have worn / trained that day, and the EWMA in the package treats the gaps
  // it does see as decay over the series it receives).
  final dailyTrimp = <double>[
    for (final d in days)
      if (d['trimp'] != null) (_numOrNull(d['trimp']) ?? 0.0)
  ];
  final load = ana.ctlAtlTsb(dailyTrimp);

  // ── skin-temp illness flag (Smarr, cycle-aware) ────────────────────────────
  final tempIllness = ana.tempIllnessFlag(dates, tempList);

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
    final midH = (midSec % 86400.0) / 3600.0; // local clock-hours [0,24)
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
  final gbTemp = _glassInput('temp', _absList(tempList), ana.wTemp,
      lowerIsBetter: true);
  if (gbTemp != null) gbInputs.add(gbTemp);
  final glassBox = ana.glassBoxReadiness(gbInputs);

  // ── breathing-rate variability across the resp-rate series ─────────────────
  final brpm = <double>[for (final v in respList) ?v];
  final brv = ana.breathingRateVariability(brpm);

  // ── true Phillips SRI across days on a 1440-epoch (1-min) clock grid ───────
  final sri = _crossDaySri(days);

  // ── latest per-family flags + JSON-safe assembly ───────────────────────────
  final latestIllness = illness.isEmpty ? null : illness.last;
  final latestAnomaly = anomaly.isEmpty ? null : anomaly.last;
  final latestTemp = tempIllness.isEmpty ? null : tempIllness.last;

  // per-day flags (for notifications / trends): asleep/illness/anomaly/temp.
  final recent = <Map<String, dynamic>>[];
  for (var i = 0; i < n; i++) {
    recent.add({
      'date': dates[i],
      'illness': i < illness.length &&
          illness[i].state == ana.IllnessState.red,
      'anomaly': i < anomaly.length && anomaly[i].flagged,
      'temp': i < tempIllness.length &&
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
    'percentiles': percentiles,
    'recent': recent,
  };
}

// ── helpers (all pure) ───────────────────────────────────────────────────────

double? _numOrNull(Object? v) => v is num ? v.toDouble() : null;

double? _mean(List<double> xs) {
  if (xs.isEmpty) return null;
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

/// Sat/Sun => free day. We lack a real work/free calendar; the weekday split is
/// an explicit approximation (DateTime.parse is a pure function of the string).
bool _isFreeDay(String? date) {
  if (date == null || date.isEmpty) return false;
  final dt = DateTime.tryParse(date);
  if (dt == null) return false;
  return dt.weekday == DateTime.saturday || dt.weekday == DateTime.sunday;
}

/// Absolute value of each present element (used to orient skin-temp by |z|).
List<double?> _absList(List<double?> xs) =>
    [for (final v in xs) v?.abs()];

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
      if (series[i] != null) series[i]!
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
      if (series[i] != null) series[i]!
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
        final startMin = ((start % 86400.0) / 60.0).floor();
        // end is exclusive of the segment's trailing edge; cover [start,end).
        final endMin = ((end % 86400.0) / 60.0).ceil();
        final asleepSeg = stage != null && stage != 'wake';
        for (var m = startMin; m < endMin; m++) {
          // Guard wrap: a segment that crosses midnight just clamps into grid.
          if (m < 0 || m >= epochsPerDay) continue;
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
