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

import '../coach/coach_config.dart';
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

/// Whether the briefing slots may be armed for [config]. This is the same test
/// the briefings themselves use, not "a key is stored": a model on this device
/// or the local network (Ollama, LM Studio, a tailnet host) needs no key, and
/// gating on the key alone left those users with briefings that generated but
/// never announced themselves.
bool aiRemindersConfigured(CoachConfig? config) => config?.configured ?? false;

/// How long after the typical wake the morning briefing waits, when the sleep
/// coach has a measured wake time. The user's own [morningMin] stays the floor:
/// an early riser still gets the briefing at their configured time, a late
/// riser gets it after they actually wake instead of while still asleep.
const int kMorningBriefAfterWakeMin = 30;

/// The morning briefing's minute-of-day: [morningMin] (the user's floor),
/// pushed out to wake + [kMorningBriefAfterWakeMin] when the typical wake is
/// known and later. Null wake (no sleep history yet) is exactly the old fixed
/// time — never an invented one.
int morningBriefSlotMin(int morningMin, double? typicalWakeMinOfDay) {
  final floor = morningMin % 1440;
  if (typicalWakeMinOfDay == null || !typicalWakeMinOfDay.isFinite) {
    return floor;
  }
  final raw = typicalWakeMinOfDay.round() + kMorningBriefAfterWakeMin;
  final afterWake = raw % 1440;
  // A wake+30 that wraps past midnight lands after the wake BY DEFINITION, so
  // the wrapped minute-of-day wins — comparing only the wrapped value against
  // the floor would pick the floor (e.g. 08:00) even though it fires HOURS
  // BEFORE a 23:50 wake.
  if (raw >= 1440) return afterWake;
  return afterWake > floor ? afterWake : floor;
}

/// The full desired schedule for the AI nudges. Briefing slots exist only when
/// the coach is configured (a notification into an "add your key" wall would
/// be a nag, not a feature); the journal prompt needs no key (manual mode).
///
/// The morning briefing additionally requires [lastNightDataReady]: the slot
/// is only armed when data for the night that just ended has actually arrived
/// (a synced sample from today, or a derived day for today). A notification
/// that says "your briefing is ready" while the band has not synced yet is a
/// promise the deep link cannot keep — the same contract as the evening slot
/// below, which is armed only when the sweep found something. The check runs
/// at ARM time, never at fire time: an OS-scheduled notification fires with no
/// Dart running, so this plan is the only place the gate can live. The caller
/// re-runs it on every sync completion, so a late sync re-arms the slot the
/// moment the data lands.
///
/// [typicalWakeMinOfDay] (the sleep coach's median wake, or null) moves the
/// morning slot to wake + [kMorningBriefAfterWakeMin] when that is later than
/// the user's configured [AiPrefs.morningMin], so a user still asleep at 08:00
/// is not buzzed — see [morningBriefSlotMin].
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
  required bool lastNightDataReady,
  double? bedtimeMinOfDay,
  double? typicalWakeMinOfDay,
  required bool journalDoneToday,
  String? sweepHeadline,
  // Both OS-scheduled AI slots fire with no Dart running, same as
  // windDownSlot/checkInMinute in notification_center.dart — quiet hours
  // can't gate them at fire time, so the cap is applied here instead.
  NotificationPrefs quiet = const NotificationPrefs(),
}) {
  if (!remindersEnabled) return const [];
  final out = <AiReminderSlot>[];
  if (aiConfigured && prefs.morningEnabled && lastNightDataReady) {
    final floor = prefs.morningMin % 1440;
    final slot = morningBriefSlotMin(prefs.morningMin, typicalWakeMinOfDay);
    var m = _capToQuietHours(quiet, slot);
    // The quiet-hours cap can pull the slot EARLIER than the wake-derived
    // minimum (wake 21:30 → slot 22:00, quiet from 22:00 → capped to 21:30,
    // i.e. exactly at wake). A briefing at wake time is not "after wake": when
    // the cap moves a wake-derived slot below its own minimum, quiet hours
    // have prevented a valid slot — omit it rather than fire early. A plain
    // configured time keeps the shared cap-then-refuse semantics.
    if (m != null && slot > floor && m < slot) m = null;
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
