// notification_center.dart — the single emitter.
//
// Every insight, alert and nudge goes through emit(). The in-app feed is ALWAYS
// written (it's the user's own history, independent of OS permission). Whether the
// event also fires an OS notification is decided by NotificationPrefs:
//   • category must be enabled, AND
//   • either we're outside quiet hours, or the event is critical and the user
//     allowed critical-overrides-quiet.
//
// This is what fixes the old inversion where health-critical events (illness,
// anomaly, fever) went only to the feed and never reached the OS shade.

import '../data/db.dart';
import 'notification_event.dart';
import 'notification_prefs.dart';
import 'notification_service.dart';

class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter instance = NotificationCenter._();

  /// Persist to the feed and (if allowed) present to the OS. Never throws.
  Future<void> emit(NotificationEvent e) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Feed first — INSERT OR IGNORE keyed on dedupeKey, so re-runs don't dup.
    try {
      await LocalDb.putNotification(e.toFeedRow(nowMs));
    } catch (_) {/* feed write best-effort */}

    try {
      final prefs = await NotificationPrefs.load();
      final now = DateTime.now();
      final minuteOfDay = now.hour * 60 + now.minute;
      if (prefs.shouldFireOs(e, minuteOfDay)) {
        await NotificationService.instance.presentEvent(e);
      }
    } catch (_) {/* OS present best-effort */}
  }

  // Default schedule for standing reminders (user-overridable via prefs UI).
  static const int windDownHour = 21; // 21:00
  static const int windDownMinute = 0;
  static const int recapWeekday = DateTime.sunday;
  static const int recapHour = 18; // Sunday 18:00
  static const int recapMinute = 0;
  static const int journalHour = 20; // 20:00 "log your day"
  static const int journalMinute = 0;

  /// (Re)register the recurring wall-clock nudges as real OS-scheduled
  /// notifications, so they fire even when the app is closed. Idempotent: cancels
  /// then re-schedules per the current prefs. Call after pairing and whenever the
  /// user changes notification prefs.
  Future<void> scheduleStandingReminders(NotificationPrefs prefs,
      {double? bedtimeMinOfDay}) async {
    final svc = NotificationService.instance;
    await svc.cancel(NotificationService.idWindDown);
    await svc.cancel(NotificationService.idWeeklyRecap);
    await svc.cancel(NotificationService.idJournalLog);
    if (!prefs.remindersEnabled) return;

    // "Time to sleep" — at the Sleep Coach's recommended bedtime when known
    // (tracks the user's schedule + sleep need), else the fixed default.
    var bedHour = windDownHour, bedMin = windDownMinute;
    if (bedtimeMinOfDay != null && bedtimeMinOfDay >= 0) {
      final m = bedtimeMinOfDay.round() % 1440;
      bedHour = m ~/ 60;
      bedMin = m % 60;
    }
    await svc.scheduleDaily(
      id: NotificationService.idWindDown,
      category: NotifCategory.reminders,
      title: 'Time to sleep',
      body: bedtimeMinOfDay != null
          ? 'To meet your sleep need, aim to be in bed around now — a consistent '
              'bedtime steadies your recovery.'
          : 'A consistent bedtime steadies your recovery — start easing off '
              'screens and lights now.',
      hour: bedHour,
      minute: bedMin,
      route: '/sleep',
    );
    // "Log your day" — the journal nudge that powers the correlation engine.
    await svc.scheduleDaily(
      id: NotificationService.idJournalLog,
      category: NotifCategory.reminders,
      title: 'Time to log your day',
      body: 'A few taps — sleep, alcohol, stress, training — teaches OpenStrap '
          'what actually moves your recovery.',
      hour: journalHour,
      minute: journalMinute,
      route: '/today',
    );
    await svc.scheduleWeekly(
      id: NotificationService.idWeeklyRecap,
      category: NotifCategory.reminders,
      title: 'Your week in review',
      body: 'A new weekly recap is ready — see how your sleep, strain and '
          'recovery trended.',
      weekday: recapWeekday,
      hour: recapHour,
      minute: recapMinute,
      route: '/recap',
    );
  }
}
