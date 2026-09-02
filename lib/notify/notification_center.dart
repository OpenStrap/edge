// notification_center.dart — the single emitter.
//
// Every insight and alert goes through emit(). OS-level notifications are the
// ONLY surface now — the in-app notifications feed/screen was removed (it
// duplicated the OS notification with no independent value).
//
// emit() is the PRESENT path. The standing schedules further down
// (scheduleStandingReminders, scheduleAiReminders) are the SCHEDULE path, which
// never passes through emit at all: the OS fires those with no Dart running.
// They are gated by NotificationService.schedulableIds instead.
//
// Whether an emitted event fires an OS notification is decided by
// NotificationPrefs:
//   • it must be one of the four sanctioned NotifClasses (see classOf), AND
//   • its category must be enabled, AND
//   • either we're outside quiet hours, or the event is critical and the user
//     allowed critical-overrides-quiet.
// The alarm is exempt from the last two: the user armed it for a time that is
// usually inside their own quiet window.
//
// Emit sites that are no longer one of the three (recovery-ready, step goal,
// posture, "did you work out?") still call emit() and are dropped HERE rather
// than at each site — one gate is how the rule stays true when the next emit
// site is added.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_prefs.dart';
import '../ai/reminder_plan.dart';
import '../data/day_label.dart';
import '../data/journal_fields.dart';
import '../data/med_store.dart';
import 'fired_keys.dart';
import 'notification_event.dart';
import 'notification_prefs.dart';
import 'notification_service.dart';
import 'tap_router.dart';

class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter instance = NotificationCenter._();

  /// The persistent "already fired this dedupeKey" guard. See [FiredKeyStore].
  final FiredKeyStore _fired = const FiredKeyStore();

  /// Tail of a chained-Future lock that serialises the claim-present-release
  /// critical section in [emit]. It keeps two overlapping emits in THIS isolate
  /// from interleaving their presents — more likely now the UI-thread stress
  /// alert can race the background derive loop.
  ///
  /// It is not what enforces fire-once. This lock can only order emits WITHIN
  /// this isolate; derivation also runs in the WorkManager isolate, which it
  /// cannot see. Fire-once across both is enforced by the atomic
  /// [FiredKeyStore.claim] below — one SQLite INSERT OR IGNORE, one winner.
  Future<void> _lock = Future<void>.value();

  /// Run [action] after any in-flight critical section completes, exclusively.
  Future<void> _synchronized(Future<void> Function() action) async {
    final prev = _lock;
    final done = Completer<void>();
    _lock = done.future; // installed synchronously — orders concurrent callers
    await prev;
    try {
      await action();
    } finally {
      done.complete();
    }
  }

  /// The OS presentation sink. Returns true when the event was actually shown
  /// (permission granted, no error). Overridable in tests to assert call counts
  /// without a device; defaults to the real service.
  @visibleForTesting
  Future<bool> Function(NotificationEvent e, {bool allowPermissionPrompt})
      presentSink = NotificationService.instance.presentEvent;

  /// Present to the OS (if allowed). Never throws.
  ///
  /// [allowPermissionPrompt]: Apple's notification docs document that
  /// authorization must be requested IN CONTEXT, from an active foreground
  /// scene — never from a background execution context (a headless
  /// BGTaskScheduler run or Dart background isolate has none to present
  /// from). Callers that know they're running headless (see
  /// background_sync.dart's checkSyncStaleness) MUST pass `false`, so a
  /// not-yet-decided permission is checked, not requested, and never gets
  /// permanently mis-cached as "denied" by a background attempt.
  ///
  /// Returns TRUE only when the event actually reached the OS. Callers that
  /// keep their own "already fired today" guard (see [emitOncePerDay]) MUST key
  /// it off this, never off the mere fact that emit was called: the event is
  /// dropped outright when [NotificationPrefs.shouldFireOs] says no (quiet
  /// hours, category muted) or when the OS present fails.
  Future<bool> emit(
    NotificationEvent e, {
    bool allowPermissionPrompt = true,
  }) async {
    var presented = false;
    try {
      final prefs = await NotificationPrefs.load();
      final now = DateTime.now();
      final minuteOfDay = now.hour * 60 + now.minute;
      if (!prefs.shouldFireOs(e, minuteOfDay)) return false;
      // Enforce the dedupeKey's "fires at most once" contract (issue #136).
      // The OS id only REPLACES a prior post of the same key — it still
      // re-alerts — and derivation re-runs on every BLE sync, so an insight
      // whose condition holds all day would otherwise buzz over and over. The
      // guard resets itself per new day via the date-prefixed keys.
      //
      // CLAIM, don't check. A check-then-record pair is not atomic: the two
      // derivation isolates can both read "not fired" before either records and
      // both alert. [FiredKeyStore.claim] decides ownership in ONE atomic
      // operation, so exactly one caller — in either isolate — ever proceeds.
      //
      // A claim we don't spend is given straight back: a permission-denied
      // no-op or a throwing present must NOT consume the key, or that insight
      // stays silent for the rest of the day. Release on every non-present path
      // (hence the finally), which restores the pre-existing
      // "record only after a real present" semantics.
      await _synchronized(() async {
        if (!await _fired.claim(e.dedupeKey)) return;
        var shown = false;
        try {
          shown = await presentSink(
            e,
            allowPermissionPrompt: allowPermissionPrompt,
          );
        } finally {
          if (!shown) await _fired.release(e.dedupeKey);
        }
        presented = shown;
      });
    } catch (_) {/* OS present best-effort */}
    return presented;
  }

  /// Fire [e] at most once per [dayId], with the persisted day-guard at
  /// [prefsKey] consumed ONLY when the notification was actually presented.
  /// Returns true iff it fired.
  ///
  /// The callers of this (recovery-ready, step-goal) used to write the guard
  /// FIRST and then emit. [emit] drops the event outright when
  /// [NotificationPrefs.shouldFireOs] is false, so a band that syncs at 06:40 —
  /// inside the DEFAULT 22:00–07:00 quiet window — computed the new day's
  /// recovery, burned the guard, got suppressed, and then had every retry that
  /// day blocked by the guard it never earned: "Your recovery is ready" simply
  /// never fired. Claiming the guard only on a real present makes the retry
  /// (the next derive pass, after 07:00) work.
  ///
  /// That fix left the other half open: [dayId] is the day the DATA is from,
  /// and a suppressed event deliberately leaves the guard unspent, so the
  /// caller re-reads the SAME last row on every later foreground open. Deny
  /// notifications, walk 12k steps, leave the band in a drawer for a week, then
  /// turn notifications back on: "step goal reached" fired about a day the user
  /// wore nothing. Yesterday's news is not news — a past day never fires, and
  /// that gate belongs here, not in each caller.
  Future<bool> emitOncePerDay({
    required String prefsKey,
    required String dayId,
    required NotificationEvent e,
    bool allowPermissionPrompt = true,
  }) async {
    if (dayId.compareTo(todayLabel()) < 0) return false;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null; // no store — [emit]'s own FiredKeyStore still dedupes
    }
    if (prefs != null && prefs.getString(prefsKey) == dayId) return false;
    final shown = await emit(e, allowPermissionPrompt: allowPermissionPrompt);
    if (shown && prefs != null) {
      try {
        await prefs.setString(prefsKey, dayId);
      } catch (_) {/* guard is an optimisation; FiredKeyStore is the truth */}
    }
    return shown;
  }

  static const int recapWeekday = DateTime.sunday;
  static const int recapHour = 18; // Sunday 18:00
  static const int recapMinute = 0;

  /// Bring the OS scheduler in line with the user's prefs.
  ///
  /// This used to arm a wind-down nudge and an UNCONDITIONAL weekly recap on
  /// every foreground resume. What is armed now is only what the user asked for
  /// by name: the weekly lookback for a week that actually contained something
  /// ([weeklyFinding] is the whole condition — null means it isn't armed), and
  /// the hydration slots while the water reminder is on.
  ///
  /// The cancels are not conditional and must stay that way: they are what
  /// clears whatever an older build — or the user's own switch, a moment ago —
  /// left standing. They also run BEFORE the permission check, deliberately —
  /// see the note in [_armWeeklyLookback] for why the check moved down there.
  ///
  /// [bedtimeMinOfDay] is no longer read: it timed the wind-down nudge. Kept so
  /// the existing caller compiles unchanged; drop both together.
  /// [checkInDoneToday] — whether the day's self-report is already written
  /// (see [checkInDone]). The prompt is not armed for a day that is already
  /// answered, which is the whole reason the caller reads it. NULL means the
  /// caller could not tell, and the check-in is then left exactly as it is.
  ///
  /// [medDefs] / [medDosesToday] come straight from `MedDb` and are only read
  /// when `prefs.medsEnabled` is on. NULL means the caller did not read the
  /// schedule at all — the notifications screen re-asserting after an
  /// unrelated toggle, or a read that threw — and the armed doses are then
  /// left exactly as they are. An EMPTY list is an answer: there are no
  /// medications, and the old slots go. They stay parameters rather than a query
  /// in here for the same reason [weeklyFinding] does: this method is the
  /// policy, and a policy that opens the database cannot be tested without
  /// one.
  ///
  /// [armedTonight]: whether the REAL armed alarm (AppState.alarmEpoch, not
  /// merely an enabled schedule row) falls on today's calendar date — see
  /// [alarmNightCheckSlot]. Always a real answer (never null): unlike
  /// `checkInDoneToday`/`medDefs`, it costs no extra read (AppState already
  /// holds the armed epoch), so there is no "caller doesn't know" case to
  /// preserve through.
  /// Public entry point — serialized through [_synchronized] so two
  /// overlapping callers (e.g. a foreground resume racing a sync-completion
  /// callback) can't interleave their cancel/re-arm passes and have a stale
  /// call clobber a newer one's result.
  Future<void> scheduleStandingReminders(
    NotificationPrefs prefs, {
    double? bedtimeMinOfDay,
    String? weeklyFinding,
    bool? checkInDoneToday,
    List<MedDef>? medDefs,
    Map<String, Map<int, Map<String, Object?>>> medDosesToday = const {},
    bool armedTonight = false,
  }) =>
      _synchronized(() => _scheduleStandingReminders(
            prefs,
            bedtimeMinOfDay: bedtimeMinOfDay,
            weeklyFinding: weeklyFinding,
            checkInDoneToday: checkInDoneToday,
            medDefs: medDefs,
            medDosesToday: medDosesToday,
            armedTonight: armedTonight,
          ));

  Future<void> _scheduleStandingReminders(
    NotificationPrefs prefs, {
    double? bedtimeMinOfDay,
    String? weeklyFinding,
    bool? checkInDoneToday,
    List<MedDef>? medDefs,
    Map<String, Map<int, Map<String, Object?>>> medDosesToday = const {},
    bool armedTonight = false,
  }) async {
    final svc = NotificationService.instance;
    await svc.cancel(NotificationService.idWeeklyRecap);
    // The night-check is decided fresh on every call (armedTonight is always a
    // real answer, unlike checkInDoneToday) — cancel unconditionally, then
    // re-arm below exactly like the weekly recap just above.
    await svc.cancel(NotificationService.idAlarmNightCheck);
    // Wind-down follows the standing rule — cancel what this call cannot put
    // back, and only that. A null slot (switch off, or no LEARNED bedtime yet)
    // cancels; a real slot is armed below.
    final windDownMin = windDownSlot(prefs, bedtimeMinOfDay);
    if (windDownMin == null) {
      await svc.cancel(NotificationService.idWindDown);
    }
    // The check-in and the medication band follow the same rule as the
    // movement nudge below: cancel what the user just switched off, and
    // otherwise only what THIS call can put back.
    //
    // `checkInDoneToday` null means the caller does not know whether today is
    // already written — the notifications screen re-asserting after an
    // unrelated toggle. Cancelling then would drop tonight's prompt, and
    // re-arming would risk asking for a day already answered, so neither
    // happens and the next foreground pass (which does know) decides.
    if (!prefs.checkInEnabled || checkInDoneToday != null) {
      await svc.cancel(NotificationService.idCheckIn);
    }
    // The medication band is cancelled when the switch is OFF — that is where
    // a reminder the user just turned off actually goes away — or when we were
    // handed the schedule and can therefore re-arm from it a few lines down.
    //
    // NOT unconditionally. This method also runs from the notifications screen
    // after any unrelated toggle, with no schedule passed, and an unconditional
    // cancel there would bin every armed dose for a user who came in to change
    // their quiet hours. Cancel only what this call can put back.
    //
    // NULL, NOT EMPTY, is what "no schedule passed" means — and that is the
    // whole distinction. "There are no medications" and "the medication table
    // could not be read" are different facts with opposite correct answers:
    // an EMPTY schedule must cancel, or a user who deleted their last
    // medication keeps getting reminded to take it, forever, because nothing
    // else ever cancels these. An UNAVAILABLE one must preserve, because
    // re-arming is impossible and cancelling would silently disarm doses that
    // are still real. Collapsing both into `const []` chose preserve for both,
    // so the deleted-medication case never got its cancel.
    if (!prefs.medsEnabled || medDefs != null) {
      for (var i = 0; i < NotificationService.maxMedSlots; i++) {
        await svc.cancel(NotificationService.idMedsBase + i);
      }
    }
    // idStillness is NOT a standing schedule and must not be cancelled with
    // them. It is a one-shot armed by live movement
    // (`AppState._rescheduleStillnessNudge`), nothing in this method re-arms
    // it, and this method runs on EVERY foreground resume — so the fix for
    // issue #123 was cancelling itself: open the app and the nudge was binned.
    // The re-arm needs a connected band streaming foreground IMU AND is
    // throttled to once per ten minutes, so it is not a gap that closes on its
    // own; with the band off the wrist it never closes at all.
    //
    // The one cancel that IS correct here is the user's own switch: this is
    // where a movement nudge that was just turned off actually goes away.
    if (!prefs.movementEnabled) {
      await svc.cancel(NotificationService.idStillness);
    }
    for (var i = 0; i < NotificationService.maxWaterSlots; i++) {
      await svc.cancel(NotificationService.idWaterBase + i);
    }
    final water = waterSlotMinutes(prefs);
    final wantWeekly = prefs.remindersEnabled && weeklyFinding != null;
    final now = DateTime.now();
    final checkIn = checkInDoneToday == null
        ? null
        : checkInSlot(prefs, bedtimeMinOfDay,
            doneToday: checkInDoneToday, nowMin: now.hour * 60 + now.minute);
    final meds =
        medPromptSlots(prefs, medDefs ?? const [], medDosesToday, now: now);
    final nightCheck = alarmNightCheckSlot(prefs,
        armedTonight: armedTonight, nowMin: now.hour * 60 + now.minute);
    if (water.isEmpty &&
        !wantWeekly &&
        windDownMin == null &&
        checkIn == null &&
        meds.isEmpty &&
        nightCheck == null) {
      return;
    }
    // Re-resolve the zone first: this runs on every foreground resume, and the
    // instants below are wall-clock. A phone that flew somewhere would otherwise
    // keep arming Sunday 18:00 in the zone the app first launched in.
    await svc.ensureTimezone();
    await _armWaterSlots(svc, water);
    if (wantWeekly) await _armWeeklyLookback(svc, weeklyFinding);
    if (windDownMin != null) await _armWindDown(svc, windDownMin);
    if (checkIn != null) await _armCheckIn(svc, checkIn);
    await _armMedSlots(svc, meds);
    // Recomputed fresh right before arming, not reused from the `now` this
    // call started with — the awaits above (zone resolve + every slot ahead
    // of this one) are real wall-clock time, and this is the one slot whose
    // hour boundary (19:00) a stale `nowMin` could cross mid-call.
    final freshNow = DateTime.now();
    final freshNightCheck = alarmNightCheckSlot(prefs,
        armedTonight: armedTonight, nowMin: freshNow.hour * 60 + freshNow.minute);
    if (freshNightCheck != null) {
      await _armAlarmNightCheck(svc, freshNightCheck);
    }
  }

  /// The hour the 7pm no-alarm-tonight check-in fires at, when armed.
  static const int alarmNightCheckHour = 19;

  /// The check-in's wall-clock minute, or null when it must not be armed: the
  /// toggle is off, an alarm IS armed for tonight (the honest gate — the whole
  /// point is to catch the GAP, not to nag someone who already has one set),
  /// or 19:00 has already passed today (a one-shot rolled to tomorrow would
  /// warn about TONIGHT a day late). No quiet-hours cap like windDown/checkIn:
  /// 19:00 is fixed and outside the default quiet window, and moving it to
  /// dodge a user-configured quiet window would just make the warning late.
  static int? alarmNightCheckSlot(
    NotificationPrefs prefs, {
    required bool armedTonight,
    required int nowMin,
  }) {
    if (!prefs.alarmNightCheckEnabled || armedTonight) return null;
    final t = alarmNightCheckHour * 60;
    if (nowMin >= t) return null;
    return t;
  }

  /// The 7pm one-shot itself. ONE-SHOT, not a daily repeat, for the same
  /// reason the check-in and med slots are: "armed for tonight" is a fact
  /// about today specifically, and a repeat would go on warning about a night
  /// that, by the next evening, may well have a real alarm set.
  Future<void> _armAlarmNightCheck(NotificationService svc, int minuteOfDay) async {
    await svc.scheduleOnce(
      id: NotificationService.idAlarmNightCheck,
      category: NotifCategory.reminders,
      title: 'No alarm set for tonight',
      body: 'You have no wake alarm armed for tonight.',
      at: svc.nextDailyInstant(minuteOfDay ~/ 60, minuteOfDay % 60),
      route: kRouteAlarm,
    );
  }

  /// One notification per dose still due — never one per day, never a summary.
  ///
  /// ONE-SHOT per slot, at the minute the user entered. A daily repeat cannot
  /// know whether today's dose was already taken, and a reminder for a pill
  /// already swallowed is exactly the notification people turn everything off
  /// over. The cost of the one-shot is that cover only reaches as far as
  /// [medPromptSlots]' horizon from the last foreground pass; the reminder
  /// re-arms on every resume, which for anyone who opens the app daily is
  /// always ahead of the doses.
  ///
  /// Quiet hours are deliberately NOT applied: this is the user's own entered
  /// time, the same reasoning that exempts the alarm. Someone who takes a pill
  /// at 23:00 typed 23:00.
  Future<void> _armMedSlots(NotificationService svc, List<MedSlot> slots) async {
    for (var i = 0; i < slots.length; i++) {
      final s = slots[i];
      final at = medSlotInstant(s);
      if (at == null) continue;
      await svc.scheduleOnce(
        id: NotificationService.idMedsBase + i,
        category: NotifCategory.reminders,
        // NO MEDICATION NAME, deliberately. This lands on a lock screen, in
        // front of whoever is in the room, and "which drug" is the most
        // sensitive fact in the app. The checklist behind the tap says which —
        // one unlock away, which is where that belongs. It is also why the
        // body is not a dose or a count.
        title: 'Medication',
        // Not an adherence score, not a streak, and nothing about a dose that
        // was missed: this is the reminder, not the report.
        body: 'A dose is due.',
        at: at,
        route: kRouteMeds,
      );
    }
  }

  /// The daily check-in, as a ONE-SHOT at the next [minuteOfDay].
  ///
  /// One-shot for the same reason the meds slots are: whether the day is
  /// already written changes daily, and a repeat would go on asking after the
  /// journal was filled in. Re-armed on every foreground pass, and the caller
  /// suppresses it outright once the day has any rating in it.
  Future<void> _armCheckIn(NotificationService svc, int minuteOfDay) async {
    await svc.scheduleOnce(
      id: NotificationService.idCheckIn,
      category: NotifCategory.reminders,
      title: 'How was today?',
      // No guilt, no count, no reference to a day that was missed.
      body: 'Mood, energy, stress — a minute of it.',
      at: svc.nextDailyInstant(minuteOfDay ~/ 60, minuteOfDay % 60),
      route: kRouteJournalCompose,
    );
  }

  /// One daily-repeating notification per hydration slot.
  ///
  /// The strap buzz (WaterBuzzer) fires off the SAME [slots] list, so the two
  /// land at the same wall-clock minute — but the buzz needs a live BLE link
  /// and a live isolate, and a reminder that only arrives when the app happens
  /// to be running is not a reminder. Both fire. There is deliberately no
  /// "only notify if the strap didn't buzz" preference: nobody has felt the
  /// double yet.
  ///
  /// Copy rule: this may nudge you to LOG a drink and nothing more. The app
  /// measures no hydration, scores none, and this text may never imply either.
  Future<void> _armWaterSlots(NotificationService svc, List<int> slots) async {
    for (var i = 0; i < slots.length; i++) {
      await svc.scheduleDaily(
        id: NotificationService.idWaterBase + i,
        category: NotifCategory.reminders,
        title: 'Water',
        body: 'Tap to log a glass.',
        hour: slots[i] ~/ 60,
        minute: slots[i] % 60,
        route: kRouteWater,
      );
    }
  }

  /// The daily wind-down nudge, as a repeating slot before the learned bedtime.
  ///
  /// A daily REPEAT is right here (unlike the weekly lookback's one-shot):
  /// the body names a TIME, not one week's facts, so it stays true every day.
  /// No skip-today: a user who opts in mid-evening should get TONIGHT's
  /// reminder if the slot is still ahead — `nextInstanceOf` already resolves
  /// to the next occurrence strictly after now, and same-id re-scheduling
  /// replaces rather than stacks.
  Future<void> _armWindDown(NotificationService svc, int minuteOfDay) async {
    await svc.scheduleDaily(
      id: NotificationService.idWindDown,
      category: NotifCategory.reminders,
      title: 'Wind down',
      body: 'Your bedtime is around ${_hhmm(minuteOfDay + windDownBeforeBedMin)}. '
          'Start slowing down.',
      hour: minuteOfDay ~/ 60,
      minute: minuteOfDay % 60,
      route: kRouteBreathing,
    );
  }

  /// How long before the learned bedtime the wind-down lands.
  static const int windDownBeforeBedMin = 45;

  /// How far inside the quiet window's edge the slot must stay clear of.
  static const int _windDownQuietMarginMin = 30;

  /// The wind-down's wall-clock minute, or null when it must not be armed.
  ///
  /// Requires BOTH the switch and a LEARNED bedtime ([bedtimeMinOfDay] from
  /// the Sleep Coach). A population fallback here would be a made-up time
  /// pretending to know this user's sleep — if the coach hasn't learned a
  /// bedtime yet, the nudge waits. (The check-in may fall back to a stated
  /// fixed time because its copy says "evening"; this one's whole content IS
  /// the time, so there is nothing honest to fall back to.)
  ///
  /// The offset wraps across midnight: a learned bedtime of 00:20 wants its
  /// wind-down at 23:35 the SAME evening, which `scheduleDaily`'s
  /// next-occurrence arithmetic delivers from a 23:35 minutes-of-day value.
  ///
  /// OS-scheduled notifications fire with no Dart running, so
  /// [NotificationPrefs.shouldFireOs] never sees one — quiet hours must be
  /// applied HERE. Same shape as the check-in: cap to half an hour before
  /// quiet opens, and refuse outright if the slot would still land inside
  /// the protected window.
  static int? windDownSlot(NotificationPrefs prefs, double? bedtimeMinOfDay) {
    if (!prefs.windDownEnabled || bedtimeMinOfDay == null) return null;
    // Wrap across midnight, staying non-negative (Dart % can go negative for
    // negative operands only when the modulus is... it cannot here — but the
    // +1440 makes the intent explicit and survives sign changes).
    var t = ((bedtimeMinOfDay.round() - windDownBeforeBedMin) % 1440 + 1440) %
        1440;
    if (prefs.quietEnabled && prefs.quietStartMin > prefs.quietEndMin) {
      final cap = prefs.quietStartMin - _windDownQuietMarginMin;
      if (t > cap) t = cap;
    }
    if (prefs.inQuietHours(t)) return null;
    return t;
  }

  /// Two-digit HH:MM from minutes-past-midnight (notification bodies).
  static String _hhmm(int minuteOfDay) {
    final m = minuteOfDay % 1440;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  // ── the weekly lookback finding ─────────────────────────────────────────

  /// What Sunday's lookback says, or null when the week was quiet enough that
  /// NOTHING should interrupt the user. PURE over the crossday rollup's
  /// `recent[]` rows ({date, rhr, unsettled, illness, anomaly, temp}).
  ///
  /// The bar is deliberately high: most weeks must produce null. A weekly
  /// notification that fires every Sunday is the recap problem all over again
  /// — the reason the slot sat unwired for so long was that nothing honest
  /// could fill it. Priority: medical flags first (they are the sanctioned
  /// detections), then a plainly-stated resting-HR drift, then silence.
  static String? weeklyLookbackFinding(
      List<Map<String, dynamic>> recentDays) {
    final days = recentDays
        .where((d) => d['unsettled'] != true)
        .toList(growable: false);
    if (days.isEmpty) return null;

    // Medical flags, counted per kind. These reuse the same detectors the
    // daily health exception fires on — the weekly note only SUMMARIZES them.
    final illness = days.where((d) => d['illness'] == true).length;
    final anomaly = days.where((d) => d['anomaly'] == true).length;
    final temp = days.where((d) => d['temp'] == true).length;
    final parts = <String>[];
    if (illness > 0) parts.add('possible illness onset ×$illness');
    if (anomaly > 0) parts.add('unusual physiology ×$anomaly');
    if (temp > 0) parts.add('elevated skin temperature ×$temp');
    if (parts.isNotEmpty) {
      return 'This week flagged: ${parts.join(', ')}. Details live on Health.';
    }

    // Resting-HR drift across the week: mean of the last three nights vs the
    // first three. Plain arithmetic on stored nightly values, stated as such
    // — no trend test dressed up as science. Needs ≥5 settled nights with an
    // RHR on both ends, which is also what keeps this silent most weeks.
    final rhrs = [
      for (final d in days)
        if (d['rhr'] is num) (d['rhr'] as num).toDouble(),
    ];
    if (rhrs.length >= 5) {
      double mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
      final early = mean(rhrs.sublist(0, 3));
      final late = mean(rhrs.sublist(rhrs.length - 3));
      final delta = late - early;
      if (delta >= 3) {
        return 'Resting heart rate ran about ${delta.round()} bpm higher '
            'late in the week than early.';
      }
      if (delta <= -3) {
        return 'Resting heart rate ran about ${(-delta).round()} bpm lower '
            'late in the week than early.';
      }
    }
    return null;
  }

  Future<void> _armWeeklyLookback(
      NotificationService svc, String finding) async {
    await svc.scheduleOnce(
      id: NotificationService.idWeeklyRecap,
      category: NotifCategory.reminders,
      title: 'Your week in review',
      body: finding,
      at: svc.nextWeeklyInstant(recapWeekday, recapHour, recapMinute),
      // A week of sleep, strain and recovery lives on Health.
      route: kRouteRecap,
    );
  }

  // Default waking window when quiet hours are off (so we never buzz at 3am).
  static const int _waterDayStartMin = 8 * 60; // 08:00
  static const int _waterDayEndMin = 22 * 60; // 22:00

  /// The wall-clock fire times (minutes-from-midnight, ascending) for the water
  /// reminder — one per slot across the waking window, spaced by the (clamped)
  /// interval, capped at [NotificationService.maxWaterSlots]. Empty when the
  /// reminder is off. PURE, and the ONE source both consumers read: the
  /// strap-buzz timer in AppState and [_armWaterSlots] above. That is the whole
  /// reason the buzz and the notification cannot drift apart.
  ///
  /// Gated on `waterEnabled` alone, not on `remindersEnabled` — that switch is
  /// the weekly lookback's off switch, and hanging the buzz off it is how this
  /// shipped once already with no reachable way to turn it on.
  static List<int> waterSlotMinutes(NotificationPrefs prefs) {
    if (!prefs.waterEnabled) return const [];

    final interval = prefs.waterIntervalMin.clamp(
        NotificationPrefs.waterIntervalMinAllowed,
        NotificationPrefs.waterIntervalMaxAllowed);

    // Waking window = outside quiet hours when enabled, else the daytime default.
    // quietEnd is wake-up; quietStart is bedtime. Fall back to 08:00–22:00 if the
    // window is degenerate (start <= end, or quiet hours disabled).
    var startMin = _waterDayStartMin, endMin = _waterDayEndMin;
    if (prefs.quietEnabled && prefs.quietStartMin > prefs.quietEndMin) {
      startMin = prefs.quietEndMin; // wake
      endMin = prefs.quietStartMin; // bed
    }
    if (endMin - startMin < interval) {
      // Window too short for even one spaced slot — fire once mid-window.
      startMin = (startMin + endMin) ~/ 2;
      endMin = startMin + 1;
    }

    final slots = <int>[];
    for (var t = startMin;
        t < endMin && slots.length < NotificationService.maxWaterSlots;
        t += interval) {
      slots.add(t);
    }
    return slots;
  }

  // ── the daily check-in ──────────────────────────────────────────────────
  //
  // ONE prompt for the whole self-report, not one per field. Mood, energy,
  // stress, soreness and sleep quality are all written on the same screen, so
  // five prompts would be five interruptions for one minute of typing.

  /// Fixed fallback time when nothing has learned a bedtime yet: 20:30. Late
  /// enough that the day is over, early enough to be well clear of the default
  /// quiet window.
  static const int checkInFallbackMin = 20 * 60 + 30;

  /// How long before the recommended bedtime the check-in lands.
  static const int checkInBeforeBedMin = 60;

  /// Never before this — a "how was today?" at teatime is asking about a day
  /// that has not happened.
  static const int checkInEarliestMin = 17 * 60;

  /// Whether the day's self-report is already written, from
  /// `journal_metric` for that day.
  ///
  /// RATINGS only. Water and caffeine are logged as they happen and say
  /// nothing about whether the day has been reflected on; mood, energy, stress,
  /// soreness and sleep quality are the answer the prompt is asking for. A
  /// single one of them is enough — the screen is one screen, and someone who
  /// filled in mood and stopped has been asked.
  static bool checkInDone(Map<String, JournalMetricValue> todayMetrics) {
    for (final f in kJournalFields) {
      if (f.isRating && todayMetrics.containsKey(f.key)) return true;
    }
    return false;
  }

  /// The check-in's wall-clock minute, or null when it must not be armed.
  ///
  /// TIMED OFF THE PERSON where the data supports it: an hour before the
  /// bedtime the Sleep Coach learned from their own nights, so a late
  /// chronotype is not asked about their day at what is, for them, mid-evening.
  /// [bedtimeMinOfDay] null (no recommendation yet) falls back to a fixed
  /// [checkInFallbackMin], stated rather than pretended.
  ///
  /// The window is then bounded on both sides. Quiet hours do not gate an OS
  /// schedule — the OS fires it with no Dart running — so the ceiling is
  /// applied HERE instead: half an hour before the quiet window opens, and
  /// never after it. A 01:00 bedtime must not produce a midnight prompt.
  static int? checkInMinute(NotificationPrefs prefs, double? bedtimeMinOfDay) {
    if (!prefs.checkInEnabled) return null;
    var t = bedtimeMinOfDay == null
        ? checkInFallbackMin
        : bedtimeMinOfDay.round() - checkInBeforeBedMin;
    if (prefs.quietEnabled && prefs.quietStartMin > prefs.quietEndMin) {
      final cap = prefs.quietStartMin - 30;
      if (t > cap) t = cap;
    }
    if (t < checkInEarliestMin) t = checkInEarliestMin;
    // A degenerate quiet window (one that swallows the whole evening) leaves
    // nowhere honest to put this. Nothing is armed rather than something at
    // a time the user has already said not to interrupt.
    if (prefs.inQuietHours(t) || t >= 24 * 60) return null;
    return t;
  }

  /// [checkInMinute], with the "already answered" rule applied.
  ///
  /// Suppressed only when the slot would land TODAY and today is already
  /// written. A day that is done at 21:00 still arms tomorrow's — the prompt
  /// is re-armed on every foreground pass, but a user who does not open the
  /// app tomorrow would otherwise never be asked again.
  static int? checkInSlot(
    NotificationPrefs prefs,
    double? bedtimeMinOfDay, {
    required bool doneToday,
    required int nowMin,
  }) {
    final t = checkInMinute(prefs, bedtimeMinOfDay);
    if (t == null) return null;
    if (doneToday && t > nowMin) return null; // would land today, already asked
    return t;
  }

  // ── medication ──────────────────────────────────────────────────────────

  /// How far ahead doses are armed. Three days rather than one because these
  /// are one-shots: nothing re-arms them while the app is closed, and a
  /// weekend without opening the app should not silently drop a prescription.
  /// Not more, because a slot armed days out cannot know it was taken early.
  static const int medHorizonDays = 3;

  /// The doses to arm: every slot still UPCOMING across [medHorizonDays],
  /// soonest first, capped at [NotificationService.maxMedSlots].
  ///
  /// `DoseState.upcoming` is the whole rule-4 answer and it is already
  /// computed by [slotsForDay]: a dose marked taken, a dose deliberately
  /// skipped, and a slot that has already passed are all something other than
  /// upcoming, and none of them is armed. [dosesToday] only covers today
  /// because that is the only day a dose can already have been recorded for.
  static List<MedSlot> medPromptSlots(
    NotificationPrefs prefs,
    List<MedDef> defs,
    Map<String, Map<int, Map<String, Object?>>> dosesToday, {
    DateTime? now,
  }) {
    if (!prefs.medsEnabled || defs.isEmpty) return const [];
    final at = now ?? DateTime.now();
    final out = <MedSlot>[];
    for (var d = 0; d < medHorizonDays; d++) {
      final day = dayLabelOf(DateTime(at.year, at.month, at.day + d));
      for (final s in slotsForDay(defs, day, d == 0 ? dosesToday : const {},
          now: at)) {
        if (s.state != DoseState.upcoming) continue;
        // Two pills at 08:00 are ONE interruption. The list is in time order,
        // so an instant equal to the last kept one is the same moment — and
        // the notification names nothing anyway, so a second copy of it would
        // carry no extra information and burn an id from the band.
        if (out.isNotEmpty &&
            out.last.date == s.date &&
            out.last.slotMin == s.slotMin) {
          continue;
        }
        out.add(s);
        if (out.length >= NotificationService.maxMedSlots) return out;
      }
    }
    return out;
  }

  /// The absolute instant [s] is due, or null when its day cannot be resolved.
  static DateTime? medSlotInstant(MedSlot s) {
    final start = localDayStartSec(s.date);
    if (start == null) return null;
    return DateTime.fromMillisecondsSinceEpoch((start + s.slotMin * 60) * 1000);
  }

  /// Re-assert the three AI slots (morning briefing, nightly sweep, pre-sleep
  /// journal prompt).
  ///
  /// Only the nightly sweep is armed. It earns the interruption the same way
  /// the weekly lookback does — [sweepHeadline] is a finding that already
  /// exists, computed on-device before this is called, and it IS the
  /// notification's body. The morning briefing and the journal prompt are
  /// still nudges with no finding behind them; [aiReminderPlan] still describes
  /// them (it is the plan, not the policy) and
  /// [NotificationService.maySchedule] still refuses them, quietly, right here.
  ///
  /// The cancels stay unconditional: they are what clears yesterday's slot when
  /// today has nothing to say, and what clears whatever an older build left.
  Future<void> scheduleAiReminders(
    NotificationPrefs prefs,
    AiPrefs ai, {
    required bool aiConfigured,
    double? bedtimeMinOfDay,
    required bool journalDoneToday,
    String? sweepHeadline,
  }) async {
    final svc = NotificationService.instance;
    await svc.cancel(NotificationService.idMorningBrief);
    await svc.cancel(NotificationService.idEveningBrief);
    await svc.cancel(NotificationService.idJournalLog);
    final plan = aiReminderPlan(
      ai,
      remindersEnabled: prefs.remindersEnabled,
      aiConfigured: aiConfigured,
      bedtimeMinOfDay: bedtimeMinOfDay,
      journalDoneToday: journalDoneToday,
      sweepHeadline: sweepHeadline,
    ).where((s) => NotificationService.maySchedule(s.id)).toList();
    if (plan.isEmpty) return;
    await svc.ensureTimezone();
    final nowMin = DateTime.now().hour * 60 + DateTime.now().minute;
    for (final s in plan) {
      // ONE-SHOT, and only when the slot is still ahead TODAY.
      //
      // Both halves matter and both are the same bug the weekly lookback
      // already carries a comment about. A daily REPEAT would re-announce
      // tonight's finding every night for the life of the install, because the
      // body is a fact about one specific day. And a one-shot that rolled over
      // to tomorrow would announce today's finding about a day it did not
      // happen on. Nothing is armed instead — this re-runs on the next
      // foreground pass, which is where the finding is recomputed anyway.
      if (s.hour * 60 + s.minute <= nowMin) continue;
      await svc.scheduleOnce(
        id: s.id,
        category: NotifCategory.reminders,
        title: s.title,
        body: s.body,
        at: svc.nextDailyInstant(s.hour, s.minute),
        route: s.route,
      );
    }
  }
}
