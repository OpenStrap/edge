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

class NotificationPrefs {
  final bool healthEnabled;
  final bool recoveryEnabled;
  final bool remindersEnabled;

  /// Quiet window as minutes-from-midnight. Wraps midnight when start > end
  /// (e.g. 22:00–07:00 → start=1320, end=420).
  final int quietStartMin;
  final int quietEndMin;
  final bool quietEnabled;

  /// When true, NotifPriority.critical events fire even inside quiet hours.
  final bool criticalOverridesQuiet;

  /// Hydration reminder: a recurring "drink water" nudge fired every
  /// [waterIntervalMin] minutes across the user's waking window (i.e. outside
  /// quiet hours). Opt-in; lives under the Reminders category, so it also obeys
  /// the master reminders toggle.
  final bool waterEnabled;

  /// How often the water reminder fires, in minutes. User-modifiable; clamped to
  /// [waterIntervalMinAllowed]..[waterIntervalMaxAllowed] when scheduling.
  final int waterIntervalMin;

  /// Allowed bounds for the hydration interval (30 min .. 6 h).
  static const int waterIntervalMinAllowed = 30;
  static const int waterIntervalMaxAllowed = 360;

  const NotificationPrefs({
    this.healthEnabled = true,
    this.recoveryEnabled = true,
    this.remindersEnabled = true,
    this.quietEnabled = true,
    this.quietStartMin = 22 * 60, // 22:00
    this.quietEndMin = 7 * 60, // 07:00
    this.criticalOverridesQuiet = true,
    this.waterEnabled = false,
    this.waterIntervalMin = 120, // every 2 hours
  });

  static const _kHealth = 'notif_health';
  static const _kRecovery = 'notif_recovery';
  static const _kReminders = 'notif_reminders';
  static const _kQuietEnabled = 'notif_quiet_enabled';
  static const _kQuietStart = 'notif_quiet_start';
  static const _kQuietEnd = 'notif_quiet_end';
  static const _kCriticalOverride = 'notif_critical_override';
  static const _kWater = 'notif_water';
  static const _kWaterInterval = 'notif_water_interval';

  static Future<NotificationPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    return NotificationPrefs(
      healthEnabled: p.getBool(_kHealth) ?? true,
      recoveryEnabled: p.getBool(_kRecovery) ?? true,
      remindersEnabled: p.getBool(_kReminders) ?? true,
      quietEnabled: p.getBool(_kQuietEnabled) ?? true,
      quietStartMin: p.getInt(_kQuietStart) ?? 22 * 60,
      quietEndMin: p.getInt(_kQuietEnd) ?? 7 * 60,
      criticalOverridesQuiet: p.getBool(_kCriticalOverride) ?? true,
      waterEnabled: p.getBool(_kWater) ?? false,
      waterIntervalMin: p.getInt(_kWaterInterval) ?? 120,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kHealth, healthEnabled);
    await p.setBool(_kRecovery, recoveryEnabled);
    await p.setBool(_kReminders, remindersEnabled);
    await p.setBool(_kQuietEnabled, quietEnabled);
    await p.setInt(_kQuietStart, quietStartMin);
    await p.setInt(_kQuietEnd, quietEndMin);
    await p.setBool(_kCriticalOverride, criticalOverridesQuiet);
    await p.setBool(_kWater, waterEnabled);
    await p.setInt(_kWaterInterval, waterIntervalMin);
  }

  NotificationPrefs copyWith({
    bool? healthEnabled,
    bool? recoveryEnabled,
    bool? remindersEnabled,
    bool? quietEnabled,
    int? quietStartMin,
    int? quietEndMin,
    bool? criticalOverridesQuiet,
    bool? waterEnabled,
    int? waterIntervalMin,
  }) =>
      NotificationPrefs(
        healthEnabled: healthEnabled ?? this.healthEnabled,
        recoveryEnabled: recoveryEnabled ?? this.recoveryEnabled,
        remindersEnabled: remindersEnabled ?? this.remindersEnabled,
        quietEnabled: quietEnabled ?? this.quietEnabled,
        quietStartMin: quietStartMin ?? this.quietStartMin,
        quietEndMin: quietEndMin ?? this.quietEndMin,
        criticalOverridesQuiet:
            criticalOverridesQuiet ?? this.criticalOverridesQuiet,
        waterEnabled: waterEnabled ?? this.waterEnabled,
        waterIntervalMin: waterIntervalMin ?? this.waterIntervalMin,
      );

  bool categoryEnabled(NotifCategory c) => switch (c) {
        NotifCategory.health => healthEnabled,
        NotifCategory.recovery => recoveryEnabled,
        NotifCategory.reminders => remindersEnabled,
        NotifCategory.device => true, // device alerts aren't user-gated here
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
  bool shouldFireOs(NotifEvent event, int minuteOfDay) {
    if (!categoryEnabled(event.category)) return false;
    if (inQuietHours(minuteOfDay)) {
      return event.priority == NotifPriority.critical && criticalOverridesQuiet;
    }
    return true;
  }
}

// Alias kept short for the gate signature above.
typedef NotifEvent = NotificationEvent;
