import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import '../data/day_label.dart';

/// Reads steps in `[from, to)`. Null means the READ FAILED — see [syncDay].
typedef StepIntervalReader = Future<int?> Function(DateTime from, DateTime to);

/// OUR OWN pedometer, on our own channel: `CMPedometer` on iOS,
/// `Sensor.TYPE_STEP_COUNTER` on Android.
///
/// Implementations: `ios/Runner/AppDelegate.swift` (PedometerBridge) and
/// `android/app/src/main/kotlin/.../PhoneStepCounter.kt`.
@visibleForTesting
const MethodChannel phoneStepsChannel = MethodChannel('openstrap/phone_steps');

/// REAL step counts, read from the phone's own step sensor.
///
/// WHY THIS EXISTS
///
/// The band is worn on the WRIST, and a wrist is a bad place to count steps.
/// Two independent limits, both measured rather than assumed:
///
///   * The 24/7 historical stream is 1 Hz. Gait is 1.4-2.3 Hz, so every gait
///     fundamental is sub-Nyquist and 80/100/140/160 spm all alias to the same
///     0.333 Hz — cadence is not merely noisy there, it is unidentifiable. No
///     published step detector exists below 10 Hz.
///   * Even at full rate, wrist amplitude ranks ordinary arm work ABOVE walking
///     (stirring ~104 mg, chopping ~139 mg vs walking ~66 mg ENMO), which is
///     why wrist devices emit 22-27 false steps/min during dishes, reaching and
///     driving (O'Connell 2017) while detecting slow walking at sensitivity
///     0.05 (Straczkiewicz 2023).
///
/// The phone rides in a pocket or bag, observes trunk motion, and runs a
/// vendor pedometer that is continuously validated against exactly this
/// problem. It is simply a better sensor for this one quantity.
///
/// WHY NOT THE HEALTH STORE. This used to read `HealthDataType.STEPS`, which on
/// iOS is an `HKStatisticsQuery` cumulative sum over EVERY source in the store
/// and on Android an aggregate of `StepsRecord.COUNT_TOTAL` that any app
/// holding WRITE_STEPS contributes to. That number is the sum of an unbounded
/// set of writers, at least one of which may itself be estimating — so it could
/// not honour `_writeSteps`'s promise of "real pedometer count over measured
/// windows only". The motion coprocessor / step-counter sensor is the one
/// writer we actually want, and going direct removes every other one.
///
/// PRIVACY / LOCAL-FIRST: the sensor is on this device and its counts never
/// leave it. Nothing is written back — see [HealthExport] for why we
/// deliberately stopped writing STEPS out.
class PhonePedometer {
  /// [stepReader] exists so the hour walk is testable without a device sensor —
  /// the walk is where the DST and partial-read bugs live, so it needs coverage
  /// that does not touch a platform channel.
  PhonePedometer({StepIntervalReader? stepReader}) : _stepReader = stepReader;

  final StepIntervalReader? _stepReader;

  /// The native side returns this for an interval it holds NO RECORD of: the
  /// sensor was not counting yet (fresh install, or the stretch lost across an
  /// Android reboot), or the interval predates iOS's seven-day pedometer cache.
  ///
  /// It is neither a failure nor a zero. That hour is simply uncovered, so it
  /// banks no window and the walk carries on — which is the whole point of a
  /// per-window coverage table. `null` still means the read FAILED.
  static const int intervalNotCovered = -1;

  Future<int?> _readSteps(DateTime from, DateTime to) async {
    final reader = _stepReader;
    if (reader != null) return reader(from, to);
    try {
      return await phoneStepsChannel.invokeMethod<int>('stepsInInterval', {
        'fromMs': from.millisecondsSinceEpoch,
        'toMs': to.millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('[phone_pedometer] read: $e');
      return null; // read FAILED — the day is abandoned, not zeroed
    }
  }

  /// Ask for access to the phone's step sensor. Safe to call repeatedly.
  ///
  /// THIS IS THE ONLY THING THAT MAKES THE PERMISSION EXIST. On iOS a
  /// permission the app never asks for is not listed in Settings at all —
  /// CoreMotion has no explicit request API, so the native side raises the
  /// prompt by issuing a one-minute query. On Android this is the runtime
  /// ACTIVITY_RECOGNITION request and it also arms the sensor listener. If this
  /// method stops being reached, the feature looks broken with nothing for the
  /// user to fix; `arming reaches the platform` in the tests pins that.
  Future<bool> requestPermission() async {
    try {
      return await phoneStepsChannel.invokeMethod<bool>('requestPermission') ??
          false;
    } catch (e) {
      debugPrint('[phone_pedometer] permission: $e');
      return false;
    }
  }

  /// Whether the sensor is readable right now.
  ///
  /// Unlike the health plugin's `hasPermissions` — which returns null/false
  /// even after a grant, and which this class used to deliberately ignore for
  /// that reason — our own channel answers honestly: iOS reports a real
  /// `CMAuthorizationStatus` and Android a real permission check. `notDetermined`
  /// counts as yes, because the first read is what raises the prompt.
  Future<bool> hasPermission() async {
    try {
      return await phoneStepsChannel.invokeMethod<bool>('authorized') ?? false;
    } catch (e) {
      debugPrint('[phone_pedometer] hasPermission: $e');
      return false; // no channel, no sensor — 48 doomed round trips help nobody
    }
  }

  /// Stop counting and forget what was counted.
  ///
  /// Dropping the `live_coverage` rows is not enough on Android: the sensor
  /// listener keeps accumulating into its own on-device store, so a user who
  /// switched the feature off would still have this app counting their steps.
  /// Nothing here can revoke the platform permission — that is the user's to do
  /// in Settings — but we can stop reading and discard what we read. iOS keeps
  /// no store of its own (CMPedometer is query-only), so there it is a no-op.
  Future<void> stop() async {
    try {
      await phoneStepsChannel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('[phone_pedometer] stop: $e');
    }
  }

  /// One-time drop of the rows the OLD health-store read banked.
  ///
  /// Those rows are labelled `phone`, exactly like the ones our own sensor
  /// writes now, but they are health-store AGGREGATES — the sum of every app
  /// that writes steps on that device. Leaving them means every historical day
  /// keeps serving a number whose source we cannot name, under a label that
  /// says we can. The days the sensor can still cover refill on the sync that
  /// immediately follows; older days go ABSENT rather than keep a number of
  /// unknown provenance, which is the same law every other input obeys.
  static const String _kImportedPurged = 'phone_steps_healthstore_purged';

  Future<void> _purgeImportedHealthStoreRows() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kImportedPurged) == true) return;
      final n = await LocalDb.clearPhoneCoverage();
      await prefs.setBool(_kImportedPurged, true);
      debugPrint('[phone_pedometer] dropped $n health-store step rows');
    } catch (e) {
      debugPrint('[phone_pedometer] purge: $e');
    }
  }

  /// Read [day]'s steps in hourly buckets and replace that day's phone rows.
  ///
  /// Hourly rather than one daily total so the derivation keeps a usable notion
  /// of WHEN the steps happened, and so a partially-elapsed today still banks
  /// what has happened so far.
  ///
  /// This is a SINGLE-SOURCE count — the iPhone's motion coprocessor, or the
  /// Android step-counter sensor. It is deliberately not the health store's
  /// multi-writer aggregate (see the class doc), so an Apple Watch worn while
  /// the phone sits on a desk contributes nothing to these hours.
  ///
  /// Returns the day's total, or null if the read failed or was not permitted
  /// (null means "unknown", NOT zero — the caller must not persist a zero).
  ///
  /// A null from ANY hour aborts the whole day. Our native contract is exact
  /// about which is which:
  ///
  ///   * a count (0 included) — that interval is covered and that is the answer;
  ///   * [intervalNotCovered] — no record of that interval, so no window is
  ///     banked and the walk carries on;
  ///   * `null` — the sensor is unavailable, denied, or the query itself failed.
  ///
  /// So a null read is a real failure, and it must not be persisted:
  /// [LocalDb.replacePhoneCoverageForDay] is delete-then-insert, so banking a
  /// short read would LOWER a previously complete day. And because
  /// [LocalDb.liveStepsForDay] prefers phone rows outright, the truncated total
  /// would also keep suppressing the band fallback.
  Future<int?> syncDay(DateTime dayStartLocal) async {
    final dayId = dayLabelOf(dayStartLocal);
    try {
      final windows = <({int startTs, int endTs, int steps})>[];
      var total = 0;
      var anyRead = false;

      // CALENDAR-AWARE hour walk. `Duration` arithmetic on a local DateTime is
      // ABSOLUTE, so `dayStartLocal.add(Duration(hours: h))` over a fixed 24
      // iterations spans 25 wall-clock hours on a fall-back day (the last
      // bucket crosses into the next local day and its steps get counted
      // twice) and 23 on a spring-forward day (one real hour never queried).
      // Constructing each boundary from calendar fields lets the runtime place
      // the instant correctly, and the next-midnight bound ends the day exactly.
      final nextMidnight = DateTime(
        dayStartLocal.year,
        dayStartLocal.month,
        dayStartLocal.day + 1,
      );
      for (var h = 0; h < 25; h++) {
        // RE-READ THE CLOCK EACH ITERATION. Each bucket is an async platform
        // query, so a whole day's walk can straddle an hour boundary. Captured
        // once up front, `now` went stale mid-loop and the current hour was
        // capped short — under-reporting today's most recent steps until some
        // later sync happened to re-read the day.
        final now = DateTime.now();
        final from = DateTime(dayStartLocal.year, dayStartLocal.month,
            dayStartLocal.day, h);
        if (!from.isBefore(nextMidnight)) break; // spring-forward short day
        if (from.isAfter(now)) break; // future hours of today
        var to = DateTime(dayStartLocal.year, dayStartLocal.month,
            dayStartLocal.day, h + 1);
        if (to.isAfter(nextMidnight)) to = nextMidnight;
        final capped = to.isAfter(now) ? now : to;
        // SKIP a zero-length bucket, never END the walk on one. On a
        // spring-forward day the missing local hour makes `DateTime(y,m,d,2)`
        // and `DateTime(y,m,d,3)` resolve to the SAME instant, so `h = 2` is
        // zero-width. Breaking here left every remaining hour of that day
        // unqueried while `anyRead` was already true from the earlier hours, so
        // the day was REPLACED with ~3 hours of windows — and since phone rows
        // win over band rows, that truncated total stuck permanently once the
        // day aged out of the `syncRecent` window.
        //
        // The "reached now" case does not need a break here: the next
        // iteration's `from` is after `now` and the guard above ends the walk.
        if (!capped.isAfter(from)) continue;

        final n = await _readSteps(from, capped);
        // Read failure (see the doc above) — abandon the day rather than
        // persist a partial one over a good previous sync.
        if (n == null) return null;
        // UNCOVERED, not failed and not zero: the sensor holds no record of
        // this hour. It banks nothing and it does not count as read, so a day
        // that is entirely uncovered still comes back "unknown" below.
        if (n == intervalNotCovered) continue;
        anyRead = true;
        if (n < 0) continue;
        // A CONFIRMED ZERO is banked too, not just a nonzero count: it is the
        // one piece of evidence that can veto a wrist false-positive over the
        // same hour (see resolveDaySteps's confirmed-still check) — a real
        // trunk pedometer that saw nothing is stronger counter-evidence than
        // the band's own gait-density guess. Dropping it here (as before)
        // left the ladder with nothing to compete against a WHOOP 4's
        // passive-wear arm motion — issue #366's whole-day-plus-phone total.
        windows.add((
          startTs: from.millisecondsSinceEpoch ~/ 1000,
          endTs: capped.millisecondsSinceEpoch ~/ 1000,
          steps: n,
        ));
        total += n;
      }

      // No hour was ever polled (a day entirely in the future, or a walk that
      // produced no buckets at all). Nothing was read, so nothing is known.
      if (!anyRead) return null;

      // AN ALL-ZERO DAY MUST NOT ERASE A DAY WE ALREADY BANKED WITH REAL
      // COUNTS. Every hour returning 0 is indistinguishable at this layer from
      // a genuinely sedentary day, and the one that matters is the failure the
      // rest of this file already documents: on iOS `requestAuthorization`
      // reports success even when the user denied READ, so reads come back
      // *empty rather than null* forever after. Because
      // `replacePhoneCoverageForDay` is delete-then-insert and phone rows win
      // outright in `liveStepsForDay`, one such sync would wipe a real
      // multi-thousand-step day and leave nothing — not even the band fallback
      // that day had before phone steps were enabled.
      //
      // A day that legitimately went to zero after being non-zero is not a real
      // trajectory (step counts only accumulate within a day), so keeping the
      // banked value costs nothing. Returning null rather than 0 is the honest
      // report: this day was NOT confirmed, so it must not count toward
      // `daysRead` in the diagnostic the Profile screen shows.
      if (total == 0 && await LocalDb.phoneStepsForDay(dayId) > 0) {
        debugPrint('[phone_pedometer] $dayId read all-zero over a day that '
            'already holds phone steps — keeping the banked day');
        return null;
      }

      await LocalDb.replacePhoneCoverageForDay(dayId, windows);
      return total;
    } catch (e) {
      debugPrint('[phone_pedometer] syncDay $dayId: $e');
      return null;
    }
  }

  /// Days pulled on a routine (launch / post-export) sync.
  ///
  /// One platform round trip PER HOUR PER DAY, so the window is the whole cost:
  /// the original 7-day default was up to 168 sequential platform calls, fired
  /// on every launch and again after every health export. Only today can still
  /// change, and yesterday only if the app did not run then, so two days covers
  /// the routine case at ~48 calls.
  static const int routineSyncDays = 2;

  /// Days pulled on an EXPLICIT sync (the user enabling the toggle, or a manual
  /// health sync) — the backfill window, worth its cost because the user asked.
  ///
  /// SIX, NOT SEVEN, and the difference is not cosmetic. Apple: "Only the past
  /// seven days worth of data is stored... Specifying a start date that is more
  /// than seven days in the past returns only the available data." The walk
  /// below starts at LOCAL MIDNIGHT `days - 1` days back, which for 7 is up to
  /// 168 h old — right on (or past) that edge. The native side refuses an
  /// out-of-cache range outright, so nothing wrong is ever banked; six simply
  /// stops us manufacturing a day that is permanently half-covered because its
  /// early hours fell off the back of the cache the moment we asked.
  static const int fullSyncDays = 6;

  /// Sync the last [days] days (including today).
  ///
  /// Returns how many days were read successfully and the steps they held. The
  /// caller surfaces this: "permission granted but no data ever arrives" is
  /// otherwise a silent dead end on iOS, where `requestAuthorization` reports
  /// success even when the user denied READ.
  Future<({int daysRead, int totalSteps})> syncRecent({
    int days = routineSyncDays,
  }) async {
    if (_stepReader == null) {
      await _purgeImportedHealthStoreRows();
      if (!await hasPermission()) return (daysRead: 0, totalSteps: 0);
    }
    final now = DateTime.now();
    var ok = 0;
    var total = 0;
    for (var d = 0; d < days; d++) {
      // Calendar subtraction, NOT `Duration(days: d)` — the latter lands on
      // 23:00 or 01:00 across a DST transition rather than local midnight,
      // which would mislabel the day and start its hour walk at the wrong
      // offset. DateTime normalises an out-of-range day field for us.
      final day = DateTime(now.year, now.month, now.day - d);
      final n = await syncDay(day);
      if (n != null) {
        ok++;
        total += n;
      }
    }
    return (daysRead: ok, totalSteps: total);
  }
}
