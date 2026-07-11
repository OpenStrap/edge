import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'ai/briefing.dart';
import 'coach/coach_config.dart';
import 'notify/tap_router.dart';
import 'state/app_state.dart';
import 'state/prefs.dart';
import 'theme/theme.dart';
import 'theme/theme_controller.dart';
import 'theme/theme_switcher.dart';
import 'theme/tokens.dart';
import 'ui/design/nav_pill.dart';
import 'ui/kit/kit.dart';
import 'ui/onboarding/welcome_screen.dart';
import 'ui/pairing_screen.dart';
import 'ui/splash/boot_splash.dart';
import 'ui/profile_setup_screen.dart';
import 'ui/today/today_screen.dart';
import 'ui/screens/screens.dart';
import 'ui/workouts/workouts_screen.dart';
import 'ui/activity/live_session_screen.dart';
import 'ui/ai/ai_breakdown_screen.dart';
import 'ui/journal/journal_compose_screen.dart';
import 'ui/stress/calm_breathing_screen.dart';

class OpenStrapApp extends StatefulWidget {
  const OpenStrapApp({super.key});
  @override
  State<OpenStrapApp> createState() => _OpenStrapAppState();
}

class _OpenStrapAppState extends State<OpenStrapApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Hand the BYOK provider config to AppState (briefing generation + the
    // key-aware AI notification schedule live there).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().attachCoachConfig(context.read<CoachConfig>());
      
      final app = context.read<AppState>();
      if (app.isPaired) app.openSession();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // Keep the app in sync with the OS when the user is on "System".
    context.read<ThemeController>().updatePlatformBrightness(
        WidgetsBinding.instance.platformDispatcher.platformBrightness);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final app = context.read<AppState>();
    if (state == AppLifecycleState.resumed) {
      app.maybeFinishFromLiveActivity();
      unawaited(app.maybeStopBreathingFromLiveActivity());
      app.refreshAppStatus(); // re-check OTA + admin banner on every foreground
      app.runCadenceChecks(); // evening wind-down / weekly recap nudges (best-effort)
      // A Siri "start breathing" App Intent may have just foregrounded an
      // already-running process (openAppWhenRun doesn't guarantee a fresh
      // launch) — the constructor-time check alone would miss that case.
      unawaited(app.checkPendingSiriRoute());
      if (app.isPaired) app.openSession();
    } else if (state == AppLifecycleState.paused) {
      // Backgrounded: hand the band to the iOS restore path so it can wake-and-drain
      // in the background (no-op on Android, where the foreground service holds it).
      app.pauseForBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    return MaterialApp(
      title: 'OpenStrap',
      debugShowCheckedModeBanner: false,
      theme: theme.lightTheme,
      darkTheme: theme.darkTheme,
      themeMode: theme.materialThemeMode,
      builder: (context, child) =>
          ThemeSwitchOverlay(key: themeSwitchKey, child: child!),
      home: const _Gate(),
    );
  }
}

/// Onboarding gate: pairing → app. CLOUD EXCISED — the old backend / auth /
/// profile gate states are gone; once a band is paired we go straight to the shell.
class _Gate extends StatelessWidget {
  const _Gate();
  @override
  Widget build(BuildContext context) {
    // SELECT, not watch: rebuild only when the ROUTE actually changes (rare) — not
    // on every ~1 Hz AppState tick (live HR, log lines). Watching the whole AppState
    // here used to repaint the entire home stack every second, which starved the
    // background BLE connection on long idle stretches (lost overnight data).
    final route = context.select<AppState, AppRoute>((a) => a.route);
    // Depend on the theme too → the whole home stack (onboarding screens, the
    // shell + its tabs) rebuilds with fresh colours the instant the mode flips.
    context.watch<ThemeController>();
    // Not const: these must be fresh instances so a theme flip re-runs their build
    // (State is preserved — same type at the same position). Cheap now: only built
    // on a route change or a theme flip, never on the per-second AppState ticks.
    final Widget resolved = switch (route) {
      // Underlay while the boot splash covers the loading phase — and what the
      // user lands on if the splash's safety cap fires before init completes.
      AppRoute.loading => Scaffold(
          body: Center(child: CircularProgressIndicator(color: AppColors.coral)),
        ),
      AppRoute.welcome => const WelcomeScreen(),
      AppRoute.pairing => PairingScreen(),
      AppRoute.profile => const ProfileSetupScreen(),
      AppRoute.shell => _Shell(),
    };
    // Cold-start splash video: covers the whole loading phase, cross-fades out
    // the instant AppState finishes initializing (route leaves `loading`), even
    // mid-play. Shown once per launch; BootSplash latches itself off after.
    return BootSplash(ready: route != AppRoute.loading, child: resolved);
  }
}

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  // Restore the last-selected tab so a relaunch lands where the user left off.
  late int _index =
      Prefs.getInt(Prefs.shellTab, 0).clamp(0, _nav.length - 1);
  late final _controller = PageController(initialPage: _index);

  AppState? _app;

  @override
  void initState() {
    super.initState();
    // A tapped notification asks for a tab via AppState.navRequest. Jump there,
    // then clear the request so it isn't replayed on rebuild.
    _app = context.read<AppState>();
    _app!.navRequest.addListener(_onNavRequest);
    _app!.screenRequest.addListener(_onScreenRequest);
    // Cold launch from a tapped notification: the route may already be set before
    // this shell mounted (so the listener never fired). Consume it once attached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onNavRequest();
      _onScreenRequest();
    });
  }

  void _onNavRequest() {
    final i = _app?.navRequest.value ?? -1;
    if (i < 0 || i >= _nav.length) return;
    _app!.navRequest.value = -1;
    if (!mounted) return;
    _go(i);
  }

  /// A tapped notification's deep link may target a sub-screen (AI briefing
  /// breakdown, journal compose). Consume the request and push it on top.
  void _onScreenRequest() {
    final s = _app?.screenRequest.value;
    if (s == null || s.isEmpty) return;
    _app!.screenRequest.value = null;
    if (!mounted) return;
    final Widget? screen = switch (s) {
      kRouteAiMorning =>
        const AiBreakdownScreen(period: BriefingPeriod.morning),
      kRouteAiEvening =>
        const AiBreakdownScreen(period: BriefingPeriod.evening),
      kRouteJournalCompose => const JournalComposeScreen(),
      // Siri/Shortcuts "start breathing" App Intent — see StartBreathingIntent
      // in OpenStrapIntents.swift, which writes this route into the App Group
      // for WidgetService.consumePendingRoute() to pick up on launch/resume.
      kRouteBreathing => const CalmBreathingScreen(autoStart: true),
      _ => null,
    };
    if (screen == null) return;
    Navigator.of(context).push(themedRoute((_) => screen));
  }

  // Built fresh on every build (not const) so a theme flip re-colours every tab,
  // even the kept-alive ones the user isn't currently looking at.
  // ignore: prefer_const_constructors — must be fresh instances so the
  // kept-alive tabs re-colour on a theme flip (const would canonicalize them).
  List<Widget> get _pages => [
        TodayScreen(),
        SleepScreen(),
        HeartScreen(),
        BodyScreen(),
        WorkoutsScreen(),
      ];

  // Illustrated tab icons (theme-aware art from openstrap_icons).
  static const _nav = [
    NavPillItem(OsIcon.today, 'Today'),
    NavPillItem(OsIcon.sleep, 'Sleep'),
    NavPillItem(OsIcon.heart, 'Heart'),
    NavPillItem(OsIcon.bodyStrain, 'Body'),
    NavPillItem(OsIcon.workouts, 'Workouts'),
  ];

  @override
  void dispose() {
    _app?.navRequest.removeListener(_onNavRequest);
    _app?.screenRequest.removeListener(_onScreenRequest);
    _controller.dispose();
    super.dispose();
  }

  // No haptic here: FloatingNavPill fires the selection click on user taps,
  // and programmatic jumps (notification deep links) shouldn't buzz.
  void _go(int i) {
    if (i == _index) return;
    _controller.animateToPage(i, duration: Motion.med, curve: Motion.curve);
  }

  @override
  Widget build(BuildContext context) {
    return ShellScaffold(
      controller: _controller,
      index: _index,
      items: _nav,
      pages: _pages,
      onSelect: _go,
      onPageChanged: (i) {
        setState(() => _index = i);
        Prefs.setInt(Prefs.shellTab, i);
      },
      // No center action: starting a workout lives on the Workouts screen.
      banner: const _LiveBanner(),
    );
  }
}

/// The shell chrome — swipeable PageView tabs behind a [FloatingNavPill],
/// plus an optional banner (the live-workout mini-player) stacked above the
/// pill. Public and AppState-free so the navigation behavior (tab select →
/// page switch, pushed sub-screens still pop/swipe back over it) stays
/// unit-testable.
class ShellScaffold extends StatelessWidget {
  final PageController controller;
  final int index;
  final List<NavPillItem> items;
  final List<Widget> pages;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onPageChanged;

  /// Rendered above the nav pill (e.g. the live-workout mini-player).
  final Widget? banner;

  const ShellScaffold({
    super.key,
    required this.controller,
    required this.index,
    required this.items,
    required this.pages,
    required this.onSelect,
    required this.onPageChanged,
    this.banner,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: PageView(
        controller: controller,
        onPageChanged: onPageChanged,
        children: [for (final p in pages) _KeepAlive(child: p)],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?banner,
            FloatingNavPill(
              items: items,
              index: index,
              onSelect: onSelect,
            ),
          ],
        ),
      ),
    );
  }
}

/// Persistent "workout in progress" mini-player — shows whenever a live workout is
/// running and you've navigated away from the live screen. Tap to jump back in.
class _LiveBanner extends StatefulWidget {
  const _LiveBanner();
  @override
  State<_LiveBanner> createState() => _LiveBannerState();
}

class _LiveBannerState extends State<_LiveBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  @override
  void dispose() { _pulse.dispose(); super.dispose(); }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final w = context.watch<AppState>().activeWorkout;
    if (w == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x6, 0, Sp.x6, Sp.x2),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).push(themedRoute(
            (_) => LiveSessionScreen(workoutId: w.workoutId, type: w.type)));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
          decoration: BoxDecoration(
            color: AppColors.night,
            borderRadius: BorderRadius.circular(R.pill),
            boxShadow: Shadows.lift,
          ),
          child: Row(children: [
            FadeTransition(opacity: _pulse, child: Container(
              width: 10, height: 10,
              decoration: BoxDecoration(color: AppColors.coral, shape: BoxShape.circle))),
            const SizedBox(width: Sp.x3),
            Text('LIVE · ${w.type.toUpperCase()}', style: AppText.overline.copyWith(color: Colors.white70)),
            const Spacer(),
            AppIcon(OsIcon.heart, size: 15, color: AppColors.coral),
            const SizedBox(width: 4),
            Text(w.currentHr > 0 ? '${w.currentHr}' : '—',
                style: AppText.metricSm.copyWith(color: Colors.white, fontSize: 16)),
            const SizedBox(width: Sp.x4),
            Text(_fmt(w.elapsed), style: AppText.metricSm.copyWith(
                color: Colors.white60, fontSize: 15, fontFeatures: [const FontFeature.tabularFigures()])),
            const SizedBox(width: Sp.x2),
            const AppIcon(OsIcon.arrowRight, size: 16, color: Colors.white38),
          ]),
        ),
      ),
    );
  }
}

/// Keeps a PageView child mounted so each screen's loader + 90s timer persist
/// (mirrors the old IndexedStack behavior).
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

