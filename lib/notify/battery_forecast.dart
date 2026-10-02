// battery_forecast.dart — will the band still be alive when you wake up?
//
// WHY THIS EXISTS
// A band that dies at 03:00 does not cost you a battery bar; it costs the whole
// night. Sleep is the one block this app cannot reconstruct from anything else:
// no nocturnal HRV, no sleep stages, no recovery score in the morning, and a
// hole in the rolling baselines that quietly degrades every baseline-relative
// metric for days afterwards. The band already reports battery every few
// minutes and we already persist it (`band_battery`), so the information needed
// to say "charge it now" at dinner time has been sitting on disk unused.
//
// WHAT THIS IS NOT
// It is not a fuel gauge and it does not model the pack. It answers one narrow
// question — at the rate you have ACTUALLY been discharging over the last few
// hours, where do you land at wake time? — and it abstains loudly the moment
// that question is not answerable. A wrong "you're fine" is worse than silence,
// because silence still lets the user look at the battery number themselves.
//
// ESTIMATOR
// Theil–Sen: the median of all pairwise slopes (Theil 1950; Sen 1968). Chosen
// over least squares because the input is quantised percentage points sampled
// at irregular intervals, so a single stuck or rounded reading drags an OLS fit
// noticeably; the median of slopes ignores it. It also degrades honestly — with
// too few points the median is simply not computed and we abstain.

import 'dart:math' as math;

import '../state/clock_format.dart' show formatClockOf;

/// One battery observation from `band_battery`.
class BatterySample {
  const BatterySample({
    required this.tsSec,
    required this.pct,
    required this.charging,
  });

  /// Unix seconds (the table's `ts`).
  final int tsSec;

  /// Battery percentage 0–100 (the table's `battery_pct`).
  final double pct;

  /// True while on the charger (the table's `charging`).
  final bool charging;
}

/// Why a forecast could not be made. Mirrors the analytics convention of a
/// machine-readable note rather than a silent null.
class ForecastNote {
  static const charging = 'charging';
  static const notDraining = 'not_draining';
  static const rateImplausible = 'rate_implausible';

  /// `need_history:have=H,need=N` — same shape as the analytics cold-start
  /// note, so the two read alike in logs and diagnostics.
  static String needHistory(int have, int need) => 'need_history:have=$have,need=$need';

  /// `need_span:have=Hm,need=Nm` — enough samples, but over too short a window
  /// to trust a slope through them.
  static String needSpan(Duration have, Duration need) =>
      'need_span:have=${have.inMinutes}m,need=${need.inMinutes}m';
}

/// The forecast. Every numeric field is null when unknown — never a guess.
class BatteryForecast {
  const BatteryForecast({
    required this.samplesUsed,
    required this.spanUsed,
    this.drainPctPerHour,
    this.currentPct,
    this.predictedPctAtWake,
    this.predictedEmptyAt,
    this.note,
  });

  /// Abstention with a reason and no numbers.
  const BatteryForecast.abstain(
    String reason, {
    this.samplesUsed = 0,
    this.spanUsed = Duration.zero,
  })  : drainPctPerHour = null,
        currentPct = null,
        predictedPctAtWake = null,
        predictedEmptyAt = null,
        note = reason;

  /// Points in the discharge run the estimate was built from.
  final int samplesUsed;

  /// Wall-clock covered by that run.
  final Duration spanUsed;

  /// Percentage points lost per hour. Always > 0 when present.
  final double? drainPctPerHour;

  /// Most recent observed battery percentage.
  final double? currentPct;

  /// Where the current rate lands at the wake time passed in. May be negative —
  /// that is meaningful ("it runs out well before then") and is deliberately not
  /// clamped to zero, so callers can see the size of the shortfall.
  final double? predictedPctAtWake;

  /// When the current rate reaches 0%.
  final DateTime? predictedEmptyAt;

  /// Abstention reason, or null on a usable forecast.
  final String? note;

  bool get isUsable => drainPctPerHour != null;
}

/// Pure, I/O-free battery projection. No database, no clock of its own — the
/// caller passes `now`, which is what makes every branch testable.
class BatteryForecaster {
  const BatteryForecaster({
    this.minSamples = 4,
    this.minSpan = const Duration(hours: 2),
    this.maxSampleAge = const Duration(hours: 48),
    this.maxPlausibleDrainPctPerHour = 25.0,
    this.reservePct = defaultReservePct,
  });

  /// The default [reservePct], named so [describe] can test the same number the
  /// trigger did without the two drifting.
  static const double defaultReservePct = 5.0;

  /// Fewer points than this and the median slope is not meaningful.
  final int minSamples;

  /// A slope through samples spanning less than this is dominated by the 1%
  /// quantisation of the reading itself.
  final Duration minSpan;

  /// Ignore anything older — a week-old discharge rate says nothing about
  /// tonight's, and wear patterns change.
  final Duration maxSampleAge;

  /// Above this, treat the slope as an artefact (a pack reset, a bad sample,
  /// a firmware quirk) rather than a real discharge rate.
  final double maxPlausibleDrainPctPerHour;

  /// Land above this and we call it survivable. Not zero: a band at 1% has
  /// effectively already failed, and the estimate has real error bars.
  final double reservePct;

  /// Project the battery forward to [wakeAt].
  ///
  /// [samples] may be in any order and may span charge cycles; only the CURRENT
  /// uninterrupted discharge run is used, because a rate measured across a
  /// charge is not a rate at all.
  BatteryForecast forecast({
    required List<BatterySample> samples,
    required DateTime now,
    required DateTime wakeAt,
  }) {
    if (samples.isEmpty) {
      return BatteryForecast.abstain(ForecastNote.needHistory(0, minSamples));
    }

    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    final oldestAllowed = nowSec - maxSampleAge.inSeconds;

    // Newest first, recent only.
    final fresh = [
      for (final s in samples)
        if (s.tsSec >= oldestAllowed && s.tsSec <= nowSec) s,
    ]..sort((a, b) => b.tsSec.compareTo(a.tsSec));

    if (fresh.isEmpty) {
      return BatteryForecast.abstain(ForecastNote.needHistory(0, minSamples));
    }

    // On the charger → the question is moot, and the slope would be positive.
    if (fresh.first.charging) {
      return BatteryForecast.abstain(ForecastNote.charging);
    }

    // Walk back through the current discharge run. It ends at the first sample
    // that was charging, or where the battery was LOWER than the one after it
    // (walking backwards, that means the level rose over time — a charge we
    // never saw the `charging` flag for, e.g. a brief top-up between polls).
    final run = <BatterySample>[fresh.first];
    for (var i = 1; i < fresh.length; i++) {
      final s = fresh[i];
      if (s.charging) break;
      // Compare against the MEDIAN of the last few accepted samples, not the
      // single previous one. Walking backwards through a discharge the level
      // should only rise, so a fall means a charge we never saw flagged — but
      // one spuriously HIGH reading would otherwise make the next perfectly
      // good sample look like that fall and truncate the run right there. The
      // median ignores a lone bad point; a real charge moves all three.
      if (s.pct < _medianOfTail(run) - _riseTolerancePct) break;
      run.add(s);
    }

    if (run.length < minSamples) {
      return BatteryForecast.abstain(
        ForecastNote.needHistory(run.length, minSamples),
        samplesUsed: run.length,
      );
    }

    final span = Duration(seconds: run.first.tsSec - run.last.tsSec);
    if (span < minSpan) {
      return BatteryForecast.abstain(
        ForecastNote.needSpan(span, minSpan),
        samplesUsed: run.length,
        spanUsed: span,
      );
    }

    final rate = _theilSenDrainPctPerHour(run);
    if (rate == null || rate <= 0) {
      return BatteryForecast.abstain(
        ForecastNote.notDraining,
        samplesUsed: run.length,
        spanUsed: span,
      );
    }
    if (rate > maxPlausibleDrainPctPerHour) {
      return BatteryForecast.abstain(
        ForecastNote.rateImplausible,
        samplesUsed: run.length,
        spanUsed: span,
      );
    }

    final currentPct = run.first.pct;
    final hoursToWake = wakeAt.difference(now).inSeconds / 3600.0;
    final predicted = currentPct - rate * hoursToWake;
    final hoursToEmpty = currentPct / rate;

    return BatteryForecast(
      samplesUsed: run.length,
      spanUsed: span,
      drainPctPerHour: rate,
      currentPct: currentPct,
      predictedPctAtWake: predicted,
      predictedEmptyAt:
          now.add(Duration(seconds: (hoursToEmpty * 3600).round())),
    );
  }

  /// True when this forecast says the band does not make it to wake with the
  /// reserve intact. False for a usable forecast that survives — and false for
  /// an abstention, because "we don't know" must never alarm.
  bool willNotSurvive(BatteryForecast f) {
    final p = f.predictedPctAtWake;
    return p != null && p <= reservePct;
  }

  /// A battery reading only moves in whole percent, so a 1-point wobble between
  /// consecutive polls is noise, not a charge event.
  static const double _riseTolerancePct = 1.0;

  /// Median of the last up-to-3 accepted samples in the run, used as the
  /// reference level for charge detection.
  static double _medianOfTail(List<BatterySample> run) {
    final tail = run.length <= 3
        ? [for (final s in run) s.pct]
        : [for (final s in run.sublist(run.length - 3)) s.pct];
    tail.sort();
    final mid = tail.length ~/ 2;
    return tail.length.isOdd ? tail[mid] : (tail[mid - 1] + tail[mid]) / 2.0;
  }

  /// Median of all pairwise slopes, in percentage points lost per hour.
  /// Positive means discharging. Null when no pair is far enough apart in time
  /// to give a finite slope.
  static double? _theilSenDrainPctPerHour(List<BatterySample> run) {
    final slopes = <double>[];
    for (var i = 0; i < run.length; i++) {
      for (var j = i + 1; j < run.length; j++) {
        final dtHours = (run[i].tsSec - run[j].tsSec) / 3600.0;
        if (dtHours.abs() < _minPairHours) continue;
        // run[i] is newer than run[j]; discharging ⇒ pct fell ⇒ positive rate.
        slopes.add((run[j].pct - run[i].pct) / dtHours);
      }
    }
    if (slopes.isEmpty) return null;
    slopes.sort();
    final mid = slopes.length ~/ 2;
    return slopes.length.isOdd
        ? slopes[mid]
        : (slopes[mid - 1] + slopes[mid]) / 2.0;
  }

  /// Pairs closer together than this produce a slope dominated by quantisation
  /// (1% over 30 s reads as 120%/h), so they are excluded from the median.
  static const double _minPairHours = 0.25;

  /// The next occurrence of the user's wake time (quiet-hours end), as a local
  /// DateTime. Minutes-from-midnight in, absolute instant out — kept here so
  /// the wrap-past-midnight arithmetic is unit-tested rather than inlined at
  /// the call site.
  ///
  /// Rolls to tomorrow via the DateTime CONSTRUCTOR, never `add(Duration(days:
  /// 1))`. A Duration is absolute elapsed time, so across a DST boundary
  /// "+24 h" lands an hour either side of the wall-clock time the user actually
  /// set — which would then skew hours-to-wake and the projection built on it.
  /// The constructor normalises a day overflow (day 32 → the 1st) while keeping
  /// the wall-clock hour fixed, which is the property that matters here.
  static DateTime nextWakeTime(DateTime now, int wakeMinuteOfDay) {
    final h = wakeMinuteOfDay ~/ 60;
    final m = wakeMinuteOfDay % 60;
    final today = DateTime(now.year, now.month, now.day, h, m);
    if (today.isAfter(now)) return today;
    return DateTime(now.year, now.month, now.day + 1, h, m);
  }

  /// True when [nowMinuteOfDay] sits in the run-up to bedtime.
  ///
  /// The warning is only worth firing while it is still ACTIONABLE — you are
  /// awake, near a charger, and have time to act. Telling someone at 02:00 that
  /// their band died an hour ago is a notification that wakes them for nothing;
  /// telling them at 09:00 that tonight might be tight is noise they will have
  /// forgotten by evening. Both ends of the window matter, and the arithmetic
  /// wraps midnight (a 01:00 bedtime means a 21:00–01:00 window), which is
  /// exactly the kind of thing worth a test rather than an inline expression.
  static bool inEveningWindow(
    int nowMinuteOfDay,
    int bedtimeMinuteOfDay, {
    int leadMinutes = 240,
  }) {
    const day = 1440;
    final start = (bedtimeMinuteOfDay - leadMinutes) % day;
    final end = bedtimeMinuteOfDay % day;
    if (start == end) return true; // a full-day lead — degenerate but defined
    return start < end
        ? (nowMinuteOfDay >= start && nowMinuteOfDay < end)
        : (nowMinuteOfDay >= start || nowMinuteOfDay < end);
  }

  /// Human-readable one-liner for the notification body. Kept next to the model
  /// so the numbers and the words can never drift apart.
  /// The "before you wake" clause is CONDITIONAL on the forecast actually
  /// saying so, rather than assumed. Today the only caller gates on
  /// [willNotSurvive] first, so the claim happens to hold — but a function
  /// whose text asserts an invariant it never checks is one refactor away from
  /// lying, and a UI surface showing a survivable forecast is the obvious next
  /// caller. Check it here instead of relying on where it is called from.
  ///
  /// Middle branch: the trigger is [willNotSurvive], i.e. the level at wake vs
  /// [reservePct] — but the text only tested the 0% instant, so every alert
  /// landing in (0, reserve] read "it runs out around 08:30, after your usual
  /// wake time" under the title "Charge your strap before bed". The user read
  /// the body, didn't charge, and lost the night. The body now tests the same
  /// thing the trigger did.
  static String describe(
    BatteryForecast f, {
    required DateTime wakeAt,
    double reservePct = defaultReservePct,
  }) {
    final rate = f.drainPctPerHour;
    final pct = f.currentPct;
    final empty = f.predictedEmptyAt;
    if (rate == null || pct == null || empty == null) return '';
    final head = 'At ${rate.toStringAsFixed(1)}%/h it runs out around '
        '${formatClockOf(empty)}';
    if (empty.isBefore(wakeAt)) {
      return '$head — before you wake. Charge it now to keep tonight\'s sleep.';
    }
    final atWake = f.predictedPctAtWake;
    if (atWake != null && atWake <= reservePct) {
      return '$head, just after your usual wake time — about '
          '${atWake.round()}% left when you get up. Charge it now to keep '
          'tonight\'s sleep.';
    }
    return '$head, after your usual wake time.';
  }

  /// Whole hours remaining at the current rate, for compact UI. Null when the
  /// forecast abstained.
  static int? hoursRemaining(BatteryForecast f, DateTime now) {
    final empty = f.predictedEmptyAt;
    if (empty == null) return null;
    return math.max(0, empty.difference(now).inMinutes) ~/ 60;
  }
}
