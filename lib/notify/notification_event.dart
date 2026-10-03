// notification_event.dart — the single currency of the notification system.
//
// Everything that wants to reach the user (illness onset, recovery ready, a
// wind-down nudge, a step goal) is expressed as ONE NotificationEvent and handed
// to NotificationCenter.emit(), which decides whether it fires an OS
// notification based on the category + the user's NotificationPrefs. (There
// used to also be an in-app notifications feed/screen — removed; OS
// notifications are the only surface now.)
//
// Categories map 1:1 onto OS notification channels (see notification_service)
// so Android users can mute each kind independently. Priority drives the
// quiet-hours decision: `critical` can break through; everything else respects
// the user's quiet window.

import 'tap_router.dart';

enum NotifCategory { health, recovery, reminders, device }

enum NotifPriority { critical, normal, low }

/// The four — and only four — things this app may EMIT into the notification
/// shade. Everything else is an in-app card.
///
/// This governs the present path only. A standing schedule (the weekly
/// lookback, the hydration slots, the nightly sweep) is fired by the OS with no
/// Dart running, never reaches [classOf], and is allow-listed separately — see
/// NotificationService.schedulableIds.
///
/// The app used to be able to emit ~22 distinct kinds across four channels:
/// hydration slots, step goals, posture nudges, "your recovery is ready", AI
/// briefings, an unconditional weekly recap. Sixteen of them were nudges, none
/// aggregated, and a wrist band that buzzes twenty times a day is a band people
/// take off. The rule is now one class per REASON to interrupt:
enum NotifClass {
  /// The band alarm the user armed. It fires on the strap's own RTC, so the
  /// phone notification is a report, not the alarm itself.
  alarm,

  /// Something is wrong right now and the user can do something about it —
  /// the day's aggregated health exception, and the band's own failures (flat
  /// battery, gone quiet). One notification, not one per finding.
  exception,

  /// The weekly lookback, and ONLY when the week actually contained something.
  lookback,

  /// Something happened that only the user can confirm, and the app cannot
  /// record it for them: an auto-detected workout. Not a nudge — a nudge asks
  /// you to go and do something, this reports a thing that already happened and
  /// asks whether to keep it. One per detected bout, never a reminder series.
  ///
  /// It gates exactly like [exception] today (category switch + quiet hours),
  /// which is deliberate rather than redundant: this enum is the ledger of what
  /// may interrupt, and filing "did you work out?" under `exception` would make
  /// the one honest list in the notification system lie.
  prompt,
}

/// Which class [e] belongs to, or null for anything that is not one of the
/// four — which [NotificationPrefs.shouldFireOs] then drops.
///
/// Classified from the category, because that is already the axis the emit
/// sites express: health/device signals are exceptions; a `reminders` event at
/// `critical` is the alarm (nothing else is allowed to claim that pair); the
/// `recovery` channel carried "your recovery is ready" and "did you work out?",
/// both nudges, and its genuine findings (low readiness, a shifted resting-HR
/// trend) are folded into the day's health exception at the point they are
/// computed rather than fired one at a time.
///
/// The ONE exception to classifying on the category alone is the detected
/// workout, which is keyed on its route. It is a reminders-channel prompt at
/// normal priority, and that pair has to keep meaning "no" for everything else
/// — it is the pair every one of the nineteen deleted nudges would arrive on.
/// So the route names the single event allowed to claim it, rather than the
/// gate opening for a whole category. `shouldFireOs` already reads the route
/// for the same reason (the auto-detect off switch).
NotifClass? classOf(NotificationEvent e) => switch (e.category) {
      NotifCategory.health || NotifCategory.device => NotifClass.exception,
      NotifCategory.reminders
          when e.priority == NotifPriority.critical =>
        NotifClass.alarm,
      // Priority as well as route. The doc above says "reminders at NORMAL
      // priority", and without the second half a low-priority event carrying
      // this route walks through the OS gate on the strength of its route
      // alone — which is the whole thing this case was narrowed to prevent.
      NotifCategory.reminders
          when e.priority == NotifPriority.normal &&
              (routePath(e.route ?? '') == kRouteWorkoutSuggestion ||
               routePath(e.route ?? '') == kRouteDetectedActivities) =>
        NotifClass.prompt,
      // Same mechanism, second route: the movement/sedentary prompt. It is a
      // report about something measured (a still stretch, a desk posture held
      // for 90+ minutes) asking the user to act — not a nudge about a day the
      // data can't support — so it rides [NotifClass.prompt] like the detected
      // workout does. Route-keyed for the same reason: reminders-at-normal is
      // exactly the pair the deleted nudges would arrive on, and opening that
      // pair wholesale would resurrect all of them at once. Its off switch is
      // NotificationPrefs.movementEnabled (see shouldFireOs).
      NotifCategory.reminders
          when e.priority == NotifPriority.normal &&
              routePath(e.route ?? '') == kRouteMovement =>
        NotifClass.prompt,
      // Same mechanism, two more route-keyed sanctions. The recovery-ready
      // morning note (its channel was where deleted nudges went, so the ROUTE
      // — not the category — is what re-opens) and the step-goal achievement.
      // Both are reports about something that already happened and measured,
      // gated by their own switches (recoveryEnabled / stepGoalEnabled).
      NotifCategory.recovery
          when e.priority == NotifPriority.normal &&
              routePath(e.route ?? '') == kRouteRecovery =>
        NotifClass.prompt,
      NotifCategory.reminders
          when e.priority == NotifPriority.normal &&
              routePath(e.route ?? '') == kRouteSteps =>
        NotifClass.prompt,
      // Same mechanism, one more route-keyed sanction: the forgotten-workout
      // nudge ("Still working out?" — WorkoutIdleWatch). A report about
      // something measured — an open session whose trailing 20 minutes were
      // all rest or absence — asking the user to act on a state only they can
      // resolve, so it is a prompt exactly like the detected workout. At most
      // once per session, enforced by its dedupeKey. No switch of its own: it
      // reports on a session the user started, so the reminders category
      // toggle is its off switch, the way recovery-ready rides
      // recoveryEnabled.
      NotifCategory.reminders
          when e.priority == NotifPriority.normal &&
              routePath(e.route ?? '') == kRouteWorkoutIdle =>
        NotifClass.prompt,
      NotifCategory.reminders || NotifCategory.recovery => null,
    };

class NotificationEvent {
  /// Idempotency key — used for the feed row id AND to derive a stable OS id, so
  /// the same logical event (e.g. "2026-06-27:illness") never duplicates and a
  /// re-fire replaces in place. Convention: `"$date:$kind"`.
  final String dedupeKey;
  final NotifCategory category;
  final NotifPriority priority;
  final String title;
  final String body;

  /// Deep-link route to open on tap (e.g. '/heart', '/today', '/recap').
  final String? route;

  /// Calendar day this event belongs to (yyyy-m-d), stored on the feed row.
  final String date;

  /// A FIXED OS id this event must be posted on, instead of the allocated one.
  /// Only for a caller that also CANCELS the card later by id — the band
  /// battery/charging alerts, whose "on the charger" card has to disappear when
  /// the puck comes off. Everything else leaves this null and lets
  /// [NotificationIds] allocate.
  final int? osId;

  const NotificationEvent({
    required this.dedupeKey,
    required this.category,
    required this.title,
    required this.body,
    required this.date,
    this.priority = NotifPriority.normal,
    this.route,
    this.osId,
  });

  // The OS notification id is NOT derived here any more. It used to be
  // `categoryBase + dedupeKey.hashCode.abs() % 100000` — a hash modulo, so two
  // distinct dedupeKeys in the same category could map onto the same id, and
  // `_plugin.show` REPLACES rather than stacks: one notification silently
  // vanished. Ids are now allocated collision-free per dedupeKey — see
  // notification_ids.dart (NotificationIds.idFor).
}
