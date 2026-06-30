import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as base;
export 'package:openstrap_analytics/onehz.dart';

class SleepWindowSpan {
  final int start;
  final int end;
  const SleepWindowSpan(this.start, this.end);
}

class NapWindow {
  final int startSec;
  final int endSec;
  final int durationSec;
  final double confidence;
  const NapWindow({
    required this.startSec,
    required this.endSec,
    required this.durationSec,
    required this.confidence,
  });
}

base.Metric<List<NapWindow>> detectNaps(
  List<base.AccelSample> accel,
  List<double> hr, {
  SleepWindowSpan? mainSleep,
}) {
  return const base.Metric<List<NapWindow>>(
    value: <NapWindow>[],
    confidence: 0,
    tier: base.Tier.estimate,
    inputs_used: ['accel_1hz', 'hr_1hz'],
    note: 'nap bridge unavailable in package surface; returning no naps',
  );
}

class SleepNeed {
  final double needSec;
  const SleepNeed(this.needSec);
  Map<String, dynamic> toJson() => {'need_sec': needSec};
}

base.Metric<SleepNeed> sleepNeed({
  required double baselineNeedSec,
  required double sleepDebtSec,
  required double dayStrain,
  required double napCreditSec,
}) {
  final strainBonusSec = (dayStrain.clamp(0.0, 21.0) / 21.0) * 45.0 * 60.0;
  final adjusted =
      (baselineNeedSec + sleepDebtSec + strainBonusSec - napCreditSec).clamp(
        6 * 3600.0,
        11 * 3600.0,
      );
  return base.Metric<SleepNeed>(
    value: SleepNeed(adjusted),
    confidence: 0.6,
    tier: base.Tier.estimate,
    inputs_used: const ['sleep_debt', 'strain', 'naps'],
    note: 'app bridge: baseline need ± debt/strain/nap adjustment',
  );
}

class SleepPerformance {
  final double pct;
  const SleepPerformance(this.pct);
  Map<String, dynamic> toJson() => {'pct': pct};
}

base.Metric<SleepPerformance> sleepPerformance(
  double sleepSec,
  double needSec,
) {
  if (needSec <= 0) {
    return const base.Metric<SleepPerformance>.absent(
      tier: base.Tier.estimate,
      inputs_used: ['sleep_sec', 'need_sec'],
    );
  }
  final pct = ((sleepSec / needSec) * 100.0).clamp(0.0, 100.0);
  return base.Metric<SleepPerformance>(
    value: SleepPerformance(pct),
    confidence: 0.7,
    tier: base.Tier.estimate,
    inputs_used: const ['sleep_sec', 'need_sec'],
  );
}

class BedtimeRec {
  final double bedtimeMinOfDay;
  const BedtimeRec(this.bedtimeMinOfDay);
  Map<String, dynamic> toJson() => {'bedtime_min_of_day': bedtimeMinOfDay};
}

base.Metric<BedtimeRec> recommendedBedtime({
  required double needSec,
  required double typicalWakeMinOfDay,
  required double typicalEfficiencyPct,
}) {
  final eff = (typicalEfficiencyPct / 100.0).clamp(0.75, 0.99);
  final inBedSec = needSec / eff;
  final bedMin = (typicalWakeMinOfDay - inBedSec / 60.0) % 1440.0;
  return base.Metric<BedtimeRec>(
    value: BedtimeRec(bedMin < 0 ? bedMin + 1440.0 : bedMin),
    confidence: 0.6,
    tier: base.Tier.estimate,
    inputs_used: const ['sleep_need', 'wake_time', 'efficiency'],
  );
}

class WakeRec {
  final double wakeMinOfDay;
  const WakeRec(this.wakeMinOfDay);
  Map<String, dynamic> toJson() => {'wake_min_of_day': wakeMinOfDay};
}

base.Metric<WakeRec> recommendedWake({
  required double bedtimeMinOfDay,
  required double needSec,
}) {
  final sleepMin = needSec / 60.0;
  final cycles = math.max(1, (sleepMin / 90.0).round());
  final wake = (bedtimeMinOfDay + cycles * 90.0) % 1440.0;
  return base.Metric<WakeRec>(
    value: WakeRec(wake),
    confidence: 0.55,
    tier: base.Tier.estimate,
    inputs_used: const ['sleep_need', 'bedtime'],
    note: 'app bridge: 90-minute cycle-aligned wake estimate',
  );
}

class StrainTarget {
  final double targetMin;
  final double targetMax;
  final String band;
  final String rationale;
  const StrainTarget({
    required this.targetMin,
    required this.targetMax,
    required this.band,
    required this.rationale,
  });
  Map<String, dynamic> toJson() => {
    'target_min': targetMin,
    'target_max': targetMax,
    'band': band,
    'rationale': rationale,
  };
}

base.Metric<StrainTarget> strainTarget({
  required double? recovery0to100,
  required double? ctl,
  required double? atl,
  required double? tsb,
}) {
  if (recovery0to100 == null) {
    return const base.Metric<StrainTarget>.absent(
      tier: base.Tier.estimate,
      inputs_used: ['recovery'],
    );
  }
  final rec = recovery0to100.clamp(0.0, 100.0);
  double lo;
  double hi;
  String band;
  if (rec < 40) {
    lo = 4;
    hi = 8;
    band = 'recover';
  } else if (rec < 60) {
    lo = 7;
    hi = 11;
    band = 'ease';
  } else if (rec < 80) {
    lo = 10;
    hi = 15;
    band = 'maintain';
  } else {
    lo = 14;
    hi = 18;
    band = 'push';
  }
  final fatigue = (atl != null && ctl != null) ? (atl - ctl) : null;
  if (fatigue != null && fatigue > 10) {
    lo -= 1;
    hi -= 2;
  } else if (tsb != null && tsb > 5) {
    hi += 1;
  }
  lo = lo.clamp(0.0, 21.0);
  hi = hi.clamp(lo + 1, 21.0);
  return base.Metric<StrainTarget>(
    value: StrainTarget(
      targetMin: lo,
      targetMax: hi,
      band: band,
      rationale: 'Target shaped by recovery and recent load.',
    ),
    confidence: 0.6,
    tier: base.Tier.estimate,
    inputs_used: const ['recovery', 'load'],
  );
}

base.Metric<double> vo2maxEstimate({
  required double? restingHr,
  required double? maxHr,
  required base.Sex sex,
  required double? age,
}) {
  if (restingHr == null || maxHr == null || maxHr <= restingHr) {
    return const base.Metric<double>.absent(
      tier: base.Tier.estimate,
      inputs_used: ['resting_hr', 'max_hr'],
    );
  }
  final vo2 = 15.3 * (maxHr / restingHr);
  return base.Metric<double>(
    value: vo2,
    confidence: 0.45,
    tier: base.Tier.estimate,
    inputs_used: const ['resting_hr', 'max_hr'],
    note: 'Uth-style resting VO2max estimate from HRmax:RHR',
  );
}

class PhysioAge {
  final double physioAge;
  final double deltaYears;
  const PhysioAge({required this.physioAge, required this.deltaYears});
  Map<String, dynamic> toJson() => {
    'physio_age': physioAge,
    'delta_years': deltaYears,
  };
}

base.Metric<PhysioAge> physiologicalAge({
  required double chronologicalAge,
  required base.Sex sex,
  required double? vo2max,
  required double? restingHr,
  required double? rmssd,
  required double? sleepDurationH,
  required double? sleepEfficiency,
  required double? dailySteps,
}) {
  var score = chronologicalAge;
  if (vo2max != null) {
    score -= ((vo2max - 35.0) / 5.0).clamp(-8.0, 8.0);
  }
  if (restingHr != null) {
    score += ((restingHr - 60.0) / 6.0).clamp(-5.0, 8.0);
  }
  if (rmssd != null) {
    score -= ((rmssd - 35.0) / 12.0).clamp(-4.0, 6.0);
  }
  if (sleepDurationH != null) {
    score += (7.5 - sleepDurationH).clamp(-2.0, 3.0);
  }
  if (sleepEfficiency != null) {
    score += ((88.0 - sleepEfficiency) / 6.0).clamp(-2.0, 3.0);
  }
  if (dailySteps != null) {
    score -= ((dailySteps - 7000.0) / 3000.0).clamp(-3.0, 3.0);
  }
  score = score.clamp(18.0, 95.0);
  return base.Metric<PhysioAge>(
    value: PhysioAge(physioAge: score, deltaYears: score - chronologicalAge),
    confidence: 0.35,
    tier: base.Tier.estimate,
    inputs_used: const [
      'profile',
      'vo2max',
      'resting_hr',
      'rmssd',
      'sleep',
      'steps',
    ],
    note: 'app bridge: directional physiological-age estimate',
  );
}

class JournalDay {
  final String date;
  final Set<String> tags;
  const JournalDay(this.date, this.tags);
}

class JournalEffect {
  final String outcome;
  final double delta;
  final double? pctChange;
  final String higherSide;
  final int nTagged;
  final int nUntagged;
  final bool insufficient;
  final bool meaningful;
  const JournalEffect({
    required this.outcome,
    required this.delta,
    required this.pctChange,
    required this.higherSide,
    required this.nTagged,
    required this.nUntagged,
    required this.insufficient,
    required this.meaningful,
  });
}

class JournalTagCorrelation {
  final String tag;
  final List<JournalEffect> effects;
  const JournalTagCorrelation(this.tag, this.effects);
}

List<JournalTagCorrelation> journalCorrelations({
  required List<JournalDay> journal,
  required List<String> dates,
  required Map<String, List<double?>> outcomes,
}) {
  final allTags = <String>{for (final j in journal) ...j.tags};
  final tagByDate = {for (final j in journal) j.date: j.tags};
  final out = <JournalTagCorrelation>[];
  for (final tag in allTags) {
    final effects = <JournalEffect>[];
    for (final entry in outcomes.entries) {
      final tagged = <double>[];
      final untagged = <double>[];
      for (var i = 0; i < dates.length; i++) {
        final v = entry.value[i];
        if (v == null) continue;
        final hasTag = tagByDate[dates[i]]?.contains(tag) == true;
        (hasTag ? tagged : untagged).add(v);
      }
      final insufficient = tagged.length < 2 || untagged.length < 2;
      if (insufficient) {
        effects.add(
          JournalEffect(
            outcome: entry.key,
            delta: 0,
            pctChange: null,
            higherSide: 'neither',
            nTagged: tagged.length,
            nUntagged: untagged.length,
            insufficient: true,
            meaningful: false,
          ),
        );
        continue;
      }
      final taggedMean = tagged.reduce((a, b) => a + b) / tagged.length;
      final untaggedMean = untagged.reduce((a, b) => a + b) / untagged.length;
      final delta = taggedMean - untaggedMean;
      final pct = untaggedMean.abs() < 1e-9
          ? null
          : (delta / untaggedMean.abs()) * 100.0;
      effects.add(
        JournalEffect(
          outcome: entry.key,
          delta: delta,
          pctChange: pct,
          higherSide: delta >= 0 ? 'tagged' : 'untagged',
          nTagged: tagged.length,
          nUntagged: untagged.length,
          insufficient: false,
          meaningful: pct != null && pct.abs() >= 3.0,
        ),
      );
    }
    out.add(JournalTagCorrelation(tag, effects));
  }
  out.sort((a, b) => a.tag.compareTo(b.tag));
  return out;
}
