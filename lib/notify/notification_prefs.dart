// notification_prefs.dart — user control over what reaches the OS shade.
//
// Persisted in shared_preferences. The in-app feed is ALWAYS written (it's the
// user's own history); these prefs only gate whether an event also fires an OS
// notification, and whether it may break through the quiet-hours window.
//
// Decision (user-chosen): health-critical alerts override quiet hours by default;
// recovery + reminders stay silent during the quiet window.

import 'package:shared_preferences/shared_preferences.dart';

import 'notification_event.dart';
import 'tap_router.dart';

class NotificationPrefs {
  /// The day's aggregated health exception (illness, unusual physiology,
  /// elevated temperature, an irregular-rhythm screen, low readiness, a shifted
  /// resting-HR trend — one notification, not six).
  final bool healthEnabled;

  /// Retained for storage compatibility. Nothing on the `recovery` channel is
  /// one of the three sanctioned classes any more — see [classOf].
  final bool recoveryEnabled;

  /// The weekly lookback.
  final bool remindersEnabled;

  /// The band's own failures: flat battery, on the charger, gone quiet. This
  /// used to be hard-coded enabled with no switch anywhere.
  final bool deviceEnabled;

  /// Quiet window as minutes-from-midnight. Wraps midnight when start > end
  /// (e.g. 22:00–07:00 → start=1320, end=420).
  final int quietStartMin;
  final int quietEndMin;
  final bool quietEnabled;

  /// When true, NotifPriority.critical events fire even inside quiet hours.
  final bool criticalOverridesQuiet;

  /// Water reminder: a recurring strap buzz across the waking window, every
  /// [waterIntervalMin] minutes. It is a nudge to LOG a drink and nothing more
  /// — the app measures no hydration and claims none. Opt-in, off by default.
  final bool waterEnabled;

  /// How often the water buzz fires, in minutes. Clamped to
  /// [waterIntervalMinAllowed]..[waterIntervalMaxAllowed] when scheduling.
  final int waterIntervalMin;

  /// Allowed bounds for the water interval (30 min .. 6 h).
  static const int waterIntervalMinAllowed = 30;
  static const int waterIntervalMaxAllowed = 360;

  /// Whether the auto-detected-workout surfaces are on: the "did you work out?"
  /// notification and the review cards the detector feeds. Asked for twice
  /// (issues #102, #149) and never built — the detector has never had an off
  /// switch of any kind.
  ///
  /// WHAT IT DOES NOT DO: stop the detection itself. The bouts are computed
  /// inside the day derivation and written to `workout_suggestions` there; this
  /// switch silences every surface that shows them, which is the part the user
  /// experiences. The rows stay, unread, and turning it back on shows them
  /// again rather than losing a week of them.
  final bool autoDetectEnabled;

  /// The "time to move" nudge: a one-shot OS notification two hours after the
  /// last movement the band's live IMU saw, re-armed on every movement so it
  /// only ever fires on a genuinely uninterrupted still stretch.
  ///
  /// Opt-in, off by default, and it is what earns the nudge its place on
  /// [NotificationService.schedulableIds] — the rule that list enforces is that
  /// a scheduled slot must be one the user asked for by name. Without a switch
  /// it was refused, which is why it has never fired for anyone (issue #123).
  final bool movementEnabled;

  /// The medication reminder: one notification per scheduled dose the user
  /// entered themselves, and ONLY for a dose that is still upcoming — a slot
  /// already marked taken or deliberately skipped is not armed at all.
  ///
  /// This is the one prompt in the app whose time is not a guess: it is the
  /// schedule in `med_def.schedule_json`, which the user typed. Opt-in and off
  /// by default like every other outbound path, because someone who wants a
  /// water reminder has not thereby asked to be told about their pills.
  final bool medsEnabled;

  /// The daily check-in: one prompt, once, to write the day's self-report
  /// (mood, energy, stress, soreness, sleep quality — the whole journal, not
  /// one field at a time).
  ///
  /// Suppressed for the day the moment any rating is written, so it can never
  /// ask for something already answered. It is NOT armed for a day that was
  /// missed — there is no catching up on a self-report, and a prompt that
  /// fires because yesterday is blank is a streak wearing a different hat.
  final bool checkInEnabled;

  /// The low-battery alert threshold, in percent. DeviceAlerts used to
  /// hard-code 15%; this is the same alert with the number in the user's
  /// hands. Read back by DeviceAlerts through its own persisted store (same
  /// key), so a headless BLE state update picks up a change without a full
  /// NotificationPrefs load. Clamped to [batteryPctAllowed] when scheduling.
  final int batteryAlertPct;

  /// The step-goal achievement: one note on the day the step ESTIMATE first
  /// crosses the user's goal. On by default — it fires at most once a day and
  /// only when the goal is actually reached — with this as its off switch.
  final bool stepGoalEnabled;

  /// The nightly wind-down nudge: one heads-up before the bedtime the Sleep
  /// Coach LEARNED from this user's own nights. Opt-in and off by default like
  /// every other outbound scheduled nudge; it also stays silent until a
  /// bedtime has actually been learned — see NotificationCenter.windDownSlot.
  final bool windDownEnabled;

  /// The alarm safety notifications (weekly-schedule feature). Both default
  /// ON, unlike every other reminder above: they exist to catch a wake alarm
  /// that silently isn't going to fire, which is the one failure mode where
  /// starting silent defeats the point.
  ///
  /// Latch-failure: the strap never confirmed (event 56) an arm this app
  /// wrote, after the retry AlarmConfirmation's grace window already allows.
  final bool alarmLatchFailedEnabled;

  /// The 7pm "no alarm set for tonight" check-in: silent whenever an alarm IS
  /// armed for tonight, so it only ever speaks up about an actual gap.
  final bool alarmNightCheckEnabled;

  /// Allowed bounds for [batteryAlertPct]. Below 5% a band is dying, not low;
  /// above 40% the alert would fire constantly and be muted forever.
  static const int batteryPctMin = 5;
  static const int batteryPctMax = 40;

  /// The shipped default threshold — what an unset store degrades to (also
  /// DeviceAlerts' fallback, so the number is spelled exactly once).
  static const int batteryPctDefault = 15;

  const NotificationPrefs({
    this.healthEnabled = true,
    this.recoveryEnabled = true,
    this.remindersEnabled = true,
    this.deviceEnabled = true,
    this.quietEnabled = true,
    this.quietStartMin = 22 * 60, // 22:00
    this.quietEndMin = 7 * 60, // 07:00
    this.criticalOverridesQuiet = true,
    this.waterEnabled = false,
    this.waterIntervalMin = 120, // every 2 hours
    this.autoDetectEnabled = true,
    this.movementEnabled = false,
    this.medsEnabled = false,
    this.checkInEnabled = false,
    this.batteryAlertPct = batteryPctDefault,
    this.stepGoalEnabled = true,
    this.windDownEnabled = false,
    this.alarmLatchFailedEnabled = true,
    this.alarmNightCheckEnabled = true,
  });

  static const _kHealth = 'notif_health';
  static const _kRecovery = 'notif_recovery';
  static const _kReminders = 'notif_reminders';
  static const _kDevice = 'notif_device';
  static const _kQuietEnabled = 'notif_quiet_enabled';
  static const _kQuietStart = 'notif_quiet_start';
  static const _kQuietEnd = 'notif_quiet_end';
  static const _kCriticalOverride = 'notif_critical_override';
  static const _kWater = 'notif_water';
  static const _kWaterInterval = 'notif_water_interval';
  static const _kAutoDetect = 'notif_auto_detect';
  static const _kMovement = 'notif_movement';
  static const _kMeds = 'notif_meds';
  static const _kCheckIn = 'notif_checkin';

  /// The low-battery alert threshold's persisted key. PUBLIC because
  /// DeviceAlerts reads it back through its own store seam on headless BLE
  /// state updates, without loading a full [NotificationPrefs]. Both sides of
  /// that coupling must spell it once.
  static const String batteryPctPrefKey = 'notif_battery_pct';
  static const _kBatteryPct = batteryPctPrefKey;
  static const _kStepGoal = 'notif_stepgoal';
  static const _kWindDown = 'notif_winddown';
  static const _kAlarmLatchFailed = 'notif_alarm_latch_failed';
  static const _kAlarmNightCheck = 'notif_alarm_night_check';

  static Future<NotificationPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    return NotificationPrefs(
      healthEnabled: p.getBool(_kHealth) ?? true,
      recoveryEnabled: p.getBool(_kRecovery) ?? true,
      remindersEnabled: p.getBool(_kReminders) ?? true,
      deviceEnabled: p.getBool(_kDevice) ?? true,
      quietEnabled: p.getBool(_kQuietEnabled) ?? true,
      quietStartMin: p.getInt(_kQuietStart) ?? 22 * 60,
      quietEndMin: p.getInt(_kQuietEnd) ?? 7 * 60,
      criticalOverridesQuiet: p.getBool(_kCriticalOverride) ?? true,
      waterEnabled: p.getBool(_kWater) ?? false,
      waterIntervalMin: p.getInt(_kWaterInterval) ?? 120,
      autoDetectEnabled: p.getBool(_kAutoDetect) ?? true,
      movementEnabled: p.getBool(_kMovement) ?? false,
      medsEnabled: p.getBool(_kMeds) ?? false,
      checkInEnabled: p.getBool(_kCheckIn) ?? false,
      batteryAlertPct: ((p.getInt(_kBatteryPct) ?? batteryPctDefault)
              .clamp(batteryPctMin, batteryPctMax))
          .toInt(),
      stepGoalEnabled: p.getBool(_kStepGoal) ?? true,
      windDownEnabled: p.getBool(_kWindDown) ?? false,
      alarmLatchFailedEnabled: p.getBool(_kAlarmLatchFailed) ?? true,
      alarmNightCheckEnabled: p.getBool(_kAlarmNightCheck) ?? true,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kHealth, healthEnabled);
    await p.setBool(_kRecovery, recoveryEnabled);
    await p.setBool(_kReminders, remindersEnabled);
    await p.setBool(_kDevice, deviceEnabled);
    await p.setBool(_kQuietEnabled, quietEnabled);
    await p.setInt(_kQuietStart, quietStartMin);
    await p.setInt(_kQuietEnd, quietEndMin);
    await p.setBool(_kCriticalOverride, criticalOverridesQuiet);
    await p.setBool(_kWater, waterEnabled);
    await p.setInt(_kWaterInterval, waterIntervalMin);
    await p.setBool(_kAutoDetect, autoDetectEnabled);
    await p.setBool(_kMovement, movementEnabled);
    await p.setBool(_kMeds, medsEnabled);
    await p.setBool(_kCheckIn, checkInEnabled);
    await p.setInt(
        _kBatteryPct, batteryAlertPct.clamp(batteryPctMin, batteryPctMax).toInt());
    await p.setBool(_kStepGoal, stepGoalEnabled);
    await p.setBool(_kWindDown, windDownEnabled);
    await p.setBool(_kAlarmLatchFailed, alarmLatchFailedEnabled);
    await p.setBool(_kAlarmNightCheck, alarmNightCheckEnabled);
  }

  NotificationPrefs copyWith({
    bool? healthEnabled,
    bool? recoveryEnabled,
    bool? remindersEnabled,
    bool? deviceEnabled,
    bool? quietEnabled,
    int? quietStartMin,
    int? quietEndMin,
    bool? criticalOverridesQuiet,
    bool? waterEnabled,
    int? waterIntervalMin,
    bool? autoDetectEnabled,
    bool? movementEnabled,
    bool? medsEnabled,
    bool? checkInEnabled,
    int? batteryAlertPct,
    bool? stepGoalEnabled,
    bool? windDownEnabled,
    bool? alarmLatchFailedEnabled,
    bool? alarmNightCheckEnabled,
  }) =>
      NotificationPrefs(
        healthEnabled: healthEnabled ?? this.healthEnabled,
        recoveryEnabled: recoveryEnabled ?? this.recoveryEnabled,
        remindersEnabled: remindersEnabled ?? this.remindersEnabled,
        deviceEnabled: deviceEnabled ?? this.deviceEnabled,
        quietEnabled: quietEnabled ?? this.quietEnabled,
        quietStartMin: quietStartMin ?? this.quietStartMin,
        quietEndMin: quietEndMin ?? this.quietEndMin,
        criticalOverridesQuiet:
            criticalOverridesQuiet ?? this.criticalOverridesQuiet,
        waterEnabled: waterEnabled ?? this.waterEnabled,
        waterIntervalMin: waterIntervalMin ?? this.waterIntervalMin,
        autoDetectEnabled: autoDetectEnabled ?? this.autoDetectEnabled,
        movementEnabled: movementEnabled ?? this.movementEnabled,
        medsEnabled: medsEnabled ?? this.medsEnabled,
        checkInEnabled: checkInEnabled ?? this.checkInEnabled,
        batteryAlertPct: batteryAlertPct ?? this.batteryAlertPct,
        stepGoalEnabled: stepGoalEnabled ?? this.stepGoalEnabled,
        windDownEnabled: windDownEnabled ?? this.windDownEnabled,
        alarmLatchFailedEnabled:
            alarmLatchFailedEnabled ?? this.alarmLatchFailedEnabled,
        alarmNightCheckEnabled:
            alarmNightCheckEnabled ?? this.alarmNightCheckEnabled,
      );

  bool categoryEnabled(NotifCategory c) => switch (c) {
        NotifCategory.health => healthEnabled,
        NotifCategory.recovery => recoveryEnabled,
        NotifCategory.reminders => remindersEnabled,
        NotifCategory.device => deviceEnabled,
      };

  /// True if [minuteOfDay] falls inside the quiet window (inclusive start,
  /// exclusive end), handling the midnight-wrap case.
  bool inQuietHours(int minuteOfDay) {
    if (!quietEnabled) return false;
    if (quietStartMin == quietEndMin) return false; // empty window
    if (quietStartMin < quietEndMin) {
      return minuteOfDay >= quietStartMin && minuteOfDay < quietEndMin;
    }
    // Wraps midnight: e.g. [22:00, 24:00) ∪ [00:00, 07:00)
    return minuteOfDay >= quietStartMin || minuteOfDay < quietEndMin;
  }

  /// The central gate: should this event be presented to the OS right now?
  ///
  /// This is also where the three-class rule is enforced — one gate rather than
  /// a check at each of the emit sites, which is how twenty-two kinds accreted
  /// in the first place.
  bool shouldFireOs(NotifEvent event, int minuteOfDay) {
    // The auto-detect off switch, applied before anything else: it is the one
    // gate the user set for THIS notification, and route is what identifies it
    // (the category it is emitted on is shared with everything else on the
    // recovery channel).
    // (On the PATH: the payload carries the bout as `?id=…`, and an equality
    // check against the bare route would miss every real one.)
    if (!autoDetectEnabled &&
        routePath(event.route ?? '') == kRouteWorkoutSuggestion) {
      return false;
    }
    // The movement nudge's off switch, same shape and same reason as the
    // auto-detect one above: the route identifies the event the user set THIS
    // switch for. Covers both sedentary surfaces — the OS-scheduled
    // two-hour-still one-shot (which never passes through here; it is gated at
    // NotificationService.schedulableIds) and this foreground desk-posture
    // check, which does.
    if (!movementEnabled &&
        routePath(event.route ?? '') == kRouteMovement) {
      return false;
    }
    // The step-goal achievement's off switch — same route-keyed shape. (The
    // recovery-ready note needs no extra branch here: it rides the recovery
    // category, and categoryEnabled below already reads recoveryEnabled.)
    if (!stepGoalEnabled &&
        routePath(event.route ?? '') == kRouteSteps) {
      return false;
    }
    final klass = classOf(event);
    if (klass == null) return false; // not one of the three — never fires
    // The alarm is the one thing quiet hours must not silence: the user armed
    // it FOR a time, usually inside the quiet window, and its off switch is
    // cancelling the alarm rather than a preference buried in settings.
    if (klass == NotifClass.alarm) return true;
    if (!categoryEnabled(event.category)) return false;
    if (inQuietHours(minuteOfDay)) {
      return event.priority == NotifPriority.critical && criticalOverridesQuiet;
    }
    return true;
  }
}

// Alias kept short for the gate signature above.
typedef NotifEvent = NotificationEvent;
