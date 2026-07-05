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
};

const Set<String> _screenRoutes = {
  kRouteAiMorning,
  kRouteAiEvening,
  kRouteJournalCompose,
};

TapTarget resolveTapRoute(String route) {
  final tab = _tabRoutes[route];
  if (tab != null) return TapTarget(tab);
  if (_screenRoutes.contains(route)) return TapTarget(0, route);
  return const TapTarget(0); // unknown (e.g. /recap) → Today
}
