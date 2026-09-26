// reminder_plan.dart — PURE policy: which AI-feature notifications should be
// on the OS schedule right now, and when. NotificationCenter executes this
// plan; nothing here touches the plugin, so the whole surface is unit-testable.
//
// Design constraint (iOS): BYOK network can't run reliably in the background,
// so a scheduled notification cannot carry model-written text. The nightly
// sweep works anyway, because the FINDING is computed on-device in pure Dart
// before the slot is armed: the notification body is the finding itself, and
// the model's take on it is written when the deep link is opened (or
// opportunistically on the next foreground).

import '../notify/notification_prefs.dart';
import '../notify/notification_service.dart';
import '../notify/tap_router.dart';
import 'ai_prefs.dart';

class AiReminderSlot {
  final int id;
  final String title;
  final String body;
  final String route;
  final int hour;
  final int minute;

  /// True → tonight's instance is skipped (already handled), repeats resume
  /// tomorrow. Used for the journal prompt's "done for today" flag.
  final bool skipToday;

  const AiReminderSlot({
    required this.id,
    required this.title,
    required this.body,
    required this.route,
    required this.hour,
    required this.minute,
    this.skipToday = false,
  });
}

/// The full desired schedule for the AI nudges. Briefing slots exist only when
/// a BYOK key is configured (a notification into an "add your key" wall would
/// be a nag, not a feature); the journal prompt needs no key (manual mode).
///
/// [sweepHeadline] is the nightly sweep's strongest finding for today, or null
/// when it found nothing — which is most days. Null means the evening slot is
/// not in the plan AT ALL: the sweep's whole contract is that it may say
/// nothing, and a notification that fires to announce nothing is the loudest
/// possible way to break it. When it is non-null it is also the notification's
/// BODY, so the interruption carries the finding rather than a promise of one.
List<AiReminderSlot> aiReminderPlan(
  AiPrefs prefs, {
  required bool remindersEnabled,
  required bool aiConfigured,
  double? bedtimeMinOfDay,
  required bool journalDoneToday,
  String? sweepHeadline,
  // Both OS-scheduled AI slots fire with no Dart running, same as
  // windDownSlot/checkInMinute in notification_center.dart — quiet hours
  // can't gate them at fire time, so the cap is applied here instead.
  NotificationPrefs quiet = const NotificationPrefs(),
}) {
  if (!remindersEnabled) return const [];
  final out = <AiReminderSlot>[];
  if (aiConfigured && prefs.morningEnabled) {
    final m = _capToQuietHours(quiet, prefs.morningMin % 1440);
    if (m != null) {
      out.add(AiReminderSlot(
        id: NotificationService.idMorningBrief,
        title: 'Your morning briefing is ready',
        body: 'Tap for last night\'s sleep, recovery and what it means for '
            'today.',
        route: kRouteAiMorning,
        hour: m ~/ 60,
        minute: m % 60,
      ));
    }
  }
  if (aiConfigured && prefs.eveningEnabled && sweepHeadline != null) {
    final m = _capToQuietHours(
        quiet, prefs.resolvedEveningMin(bedtimeMinOfDay: bedtimeMinOfDay));
    if (m != null) {
      out.add(AiReminderSlot(
        id: NotificationService.idEveningBrief,
        title: 'Something stood out today',
        body: sweepHeadline,
        route: kRouteAiEvening,
        hour: m ~/ 60,
        minute: m % 60,
      ));
    }
  }
  if (prefs.journalEnabled) {
    final m = prefs.resolvedJournalMin(bedtimeMinOfDay: bedtimeMinOfDay);
    out.add(AiReminderSlot(
      id: NotificationService.idJournalLog,
      title: 'About your bedtime — log your day',
      body: 'A minute of notes tonight teaches OpenStrap what actually moves '
          'your recovery.',
      route: kRouteJournalCompose,
      hour: m ~/ 60,
      minute: m % 60,
      skipToday: journalDoneToday,
    ));
  }
  return out;
}

/// Same cap-then-refuse semantics as
/// `NotificationCenter.checkInMinute`/`windDownSlot`: cap to half an hour
/// before quiet hours open, then refuse outright (null) if the slot still
/// lands inside the window.
int? _capToQuietHours(NotificationPrefs prefs, int minuteOfDay) {
  var t = minuteOfDay;
  if (prefs.quietEnabled && prefs.quietStartMin > prefs.quietEndMin) {
    final cap = prefs.quietStartMin - 30;
    if (t > cap) t = cap;
  }
  if (prefs.inQuietHours(t)) return null;
  return t;
}
