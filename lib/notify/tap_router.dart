// tap_router.dart — PURE mapping from a notification's deep-link route string
// to what the app should do with it: which shell tab to land on, and (new)
// which sub-screen to push on top. AppState feeds taps through here; the shell
// consumes both requests. Unknown routes fall back to Today (never crash on a
// stale payload from an old build).

/// Sub-screen deep links (notification payloads). The 5 tab routes
/// (/today /sleep /heart /body /workouts) stay as they were.
const String kRouteAiMorning = '/ai/morning';
const String kRouteAiEvening = '/ai/evening';
const String kRouteJournalCompose = '/journal/compose';
const String kRouteBreathing = '/breathing';

/// The hydration reminder. It lands on the one-tap water log rather than the
/// Nutrition tab: the notification asks you to log a glass, and a destination
/// that still needs a scroll to find the control is a different promise.
const String kRouteWater = '/water';

/// "Did you work out?" auto-detect notification. Lands on the Workouts tab and
/// pushes a focused review of the detected activity (log or adjust) — the plain
/// `/workouts` route only selected the tab, leaving the suggestion buried in the
/// history list (issue #113).
///
/// Carries the bout it is about as `?id=<workout_suggestions.id>` — see
/// [workoutSuggestionRoute]. The bare path still resolves (older payloads, and
/// anything that just wants the review screen).
const String kRouteWorkoutSuggestion = '/workouts/suggestion';

/// The sedentary/movement nudges ("time to move", the desk-posture check).
///
/// A DEDICATED PATH, not the plain `/today`, and that is load-bearing: the
/// notification gate classifies on category + priority + route, and
/// reminders-at-low was deliberately the pair every deleted nudge used to
/// arrive on. Keying the movement prompt to this route is what lets it (and
/// only it) through while every other reminders event stays dropped — the same
/// mechanism `kRouteWorkoutSuggestion` uses.
///
/// Lands on Home (Today) and pushes nothing: there is no move screen to push,
/// and Today is where the rings/steps a nudge points at already live.
const String kRouteMovement = '/today/movement';

/// "Your recovery is ready" — the morning recovery note. DEDICATED PATH for
/// the same reason [kRouteMovement] is: the recovery channel was where dead
/// nudges went (`classOf` dropped all of it), so re-opening the CHANNEL would
/// resurrect them; keying on this route sanctions exactly one event. Its off
/// switch is NotificationPrefs.recoveryEnabled (the retained pref for that
/// channel). Lands on Home/Today, where the recovery ring lives.
const String kRouteRecovery = '/today/recovery';

/// "Step goal reached" — same mechanism again: reminders-at-low was a dropped
/// pair, so the achievement rides its own route at prompt class. Off switch:
/// NotificationPrefs.stepGoalEnabled.
const String kRouteSteps = '/today/steps';

/// The deep link for ONE detected bout. The id is the `workout_suggestions`
/// row's, so the screen can open on that bout rather than a list the user has
/// to find it in.
String workoutSuggestionRoute(String id) =>
    Uri(path: kRouteWorkoutSuggestion, queryParameters: {'id': id}).toString();

/// The forgotten-workout nudge ("Still working out?" — see
/// `WorkoutIdleWatch`). Lands on the Workouts tab: the live session bar and
/// its finish control are what the notification is about. A dedicated path
/// rather than the bare `/workouts` tab route, because `classOf`'s sanction
/// for it is route-keyed and the tab route must not open the
/// reminders-at-normal pair for everything that names it.
const String kRouteWorkoutIdle = '/workouts/idle';

/// A deep link's path, without the `?id=` a route may carry.
///
/// EVERY route comparison goes through this. The tables below, `classOf`,
/// `shouldFireOs`'s auto-detect switch and app.dart's two switches all match on
/// route EQUALITY, so an id-carrying payload silently misses all of them —
/// which for the gate means the off switch stops working.
String routePath(String route) => Uri.tryParse(route)?.path ?? route;

/// The bout/record id a deep link carries, or null when it carries none.
String? routeId(String route) => Uri.tryParse(route)?.queryParameters['id'];

/// The medication reminder. Lands on Wellness, where the Medication tab's
/// checklist is the thing that records the dose.
///
/// CEILING, and it is a real one: `WellnessScreen` holds its sub-tab in
/// private state with no constructor argument, so this lands on Wellness with
/// Medication one tap away in the sub-tab row rather than on the checklist
/// itself. Adding `initialTab` to that screen is the whole fix — see the note
/// on `screenForRoute` in app.dart.
const String kRouteMeds = '/meds';

/// Emitted by the battery forecast and the device alerts. Profile is reached
/// from the Home avatar rather than a tab of its own, so the base is Home and
/// `screenForRoute` pushes the profile on top of it.
const String kRouteProfile = '/profile';

/// Emitted by the weekly recap. It used to resolve to the Health domain and
/// push nothing, because there was no recap screen to push — `screenForRoute`
/// returned null for it deliberately. There is one now (`WhatChangedScreen`),
/// so the notification finally lands on the findings it is about.
///
/// It still has to be listed here, because a route absent from this table
/// produces no screen request at all and the shell then falls back to the tab
/// index, which is Home. That is how both of these used to land on Home while
/// `domainForRoute` claimed otherwise.
const String kRouteRecap = '/recap';

/// Emitted by the two alarm safety notifications (latch-failure, the 7pm
/// no-alarm-tonight check-in). Lands on the Alarm screen itself, the one place
/// either can actually be fixed — see `screenForRoute` in app.dart.
const String kRouteAlarm = '/alarm';

class TapTarget {
  /// Shell tab index to land on (always valid; unknown → 0 = Today).
  final int tab;

  /// When non-null, a sub-screen route the shell should push on top of the tab
  /// (one of the kRoute* consts above).
  final String? screen;

  const TapTarget(this.tab, [this.screen]);
}

const Map<String, int> _tabRoutes = {
  '/today': 0,
  '/sleep': 1,
  '/heart': 2,
  '/body': 3,
  '/workouts': 4,
  // The forgotten-workout nudge. The Workouts tab IS its destination — the
  // live session bar with the finish control is pinned to the shell there and
  // `screenForRoute` has nothing to push — so it belongs in the tab table,
  // not `_screenRoutes`. (It keeps its own path because `classOf`'s sanction
  // is route-keyed — see kRouteWorkoutIdle above.)
  kRouteWorkoutIdle: 4,
};

// Sub-screen routes → the shell tab they sit on top of. Most briefing/journal
// deep links live over Today (0); the detected-workout review sits over the
// Workouts tab (4) so the tab underneath is the natural place to land on close.
//
// /profile and /recap were BOTH being emitted with neither table knowing them,
// so resolveTapRoute fell through to Today and every band-battery alert landed
// on the home screen — three taps from the battery it was about. The
// destinations exist in app.dart; this is the half that was missing.
const Map<String, int> _screenRoutes = {
  kRouteAiMorning: 0,
  kRouteAiEvening: 0,
  kRouteJournalCompose: 0,
  kRouteBreathing: 0,
  kRouteWater: 0,
  // Wellness has no index in the old five-tab vocabulary, so the base is Today
  // and `domainForRoute` is what actually decides where it lands. The entry
  // still has to exist: a route absent from this table produces no screen
  // request at all, and the shell then falls back to the tab index.
  kRouteMeds: 0,
  kRouteWorkoutSuggestion: 4,
  kRouteProfile: 0,
  kRouteRecap: 1, // 1|2|3 all fold into Health — see domainForTab
  kRouteAlarm: 0,
};

TapTarget resolveTapRoute(String route) {
  // Match on the PATH; hand the full route (id and all) back as the screen
  // request, so whatever the shell pushes still knows which bout it is about.
  final path = routePath(route);
  final tab = _tabRoutes[path];
  if (tab != null) return TapTarget(tab);
  final base = _screenRoutes[path];
  if (base != null) return TapTarget(base, route);
  return const TapTarget(0); // unknown payload from an older build → Today
}
