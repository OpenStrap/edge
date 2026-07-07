// reminder_plan.dart — PURE policy: which AI-feature notifications should be
// on the OS schedule right now, and when. NotificationCenter executes this
// plan; nothing here touches the plugin, so the whole surface is unit-testable.
//
// Design constraint (iOS): BYOK network can't run reliably in the background,
// so the scheduled briefing notifications are LIGHT prompts ("ready — tap to
// view") that deep-link into the breakdown screen, which generates-or-shows-
// cached on open. Generation also happens opportunistically on foreground.

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
List<AiReminderSlot> aiReminderPlan(
  AiPrefs prefs, {
  required bool remindersEnabled,
  required bool aiConfigured,
  double? bedtimeMinOfDay,
  required bool journalDoneToday,
}) {
  if (!remindersEnabled) return const [];
  final out = <AiReminderSlot>[];
  if (aiConfigured && prefs.morningEnabled) {
    final m = prefs.morningMin % 1440;
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
  if (aiConfigured && prefs.eveningEnabled) {
    final m = prefs.eveningMin % 1440;
    out.add(AiReminderSlot(
      id: NotificationService.idEveningBrief,
      title: 'Your evening recap is ready',
      body: 'Tap for today\'s strain, movement and how the day landed.',
      route: kRouteAiEvening,
      hour: m ~/ 60,
      minute: m % 60,
    ));
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
