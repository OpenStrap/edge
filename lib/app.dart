import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'state/prefs.dart';
import 'theme/theme.dart';
import 'theme/theme_controller.dart';
import 'theme/theme_switcher.dart';
import 'theme/tokens.dart';
import 'ui/kit/kit.dart';
import 'ui/onboarding/welcome_screen.dart';
import 'ui/pairing_screen.dart';
import 'ui/profile_setup_screen.dart';
import 'ui/today/today_screen.dart';
import 'ui/screens/screens.dart';
import 'ui/workouts/workouts_screen.dart';
import 'ui/activity/live_session_screen.dart';

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
      app.refreshAppStatus(); // re-check OTA + admin banner on every foreground
      app.runCadenceChecks(); // evening wind-down / weekly recap nudges (best-effort)
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
    switch (route) {
      case AppRoute.loading:
        return Scaffold(
          body: Center(child: CircularProgressIndicator(color: AppColors.coral)),
        );
      case AppRoute.welcome:
        return const WelcomeScreen();
      case AppRoute.pairing:
        return PairingScreen();
      case AppRoute.profile:
        return const ProfileSetupScreen();
      case AppRoute.shell:
        return _Shell();
    }
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
    // Cold launch from a tapped notification: the route may already be set before
    // this shell mounted (so the listener never fired). Consume it once attached.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNavRequest());
  }

  void _onNavRequest() {
    final i = _app?.navRequest.value ?? -1;
    if (i < 0 || i >= _nav.length) return;
    _app!.navRequest.value = -1;
    if (!mounted) return;
    _go(i);
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

  static const _nav = [
    (Ic.home, 'Today'),
    (Ic.sleep, 'Sleep'),
    (Ic.heart, 'Heart'),
    (Ic.strain, 'Body'),
    (Ic.run, 'Workouts'),
  ];

  @override
  void dispose() {
    _app?.navRequest.removeListener(_onNavRequest);
    _controller.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (i == _index) return;
    HapticFeedback.selectionClick();
    _controller.animateToPage(i, duration: Motion.med, curve: Motion.curve);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: PageView(
        controller: _controller,
        onPageChanged: (i) {
          setState(() => _index = i);
          Prefs.setInt(Prefs.shellTab, i);
        },
        children: [for (final p in _pages) _KeepAlive(child: p)],
      ),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        const _LiveBanner(),
        _ScrubNav(items: _nav, controller: _controller, index: _index, onSelect: _go),
      ]),
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
            AppIcon(Ic.heart, size: 15, color: AppColors.coral),
            const SizedBox(width: 4),
            Text(w.currentHr > 0 ? '${w.currentHr}' : '—',
                style: AppText.metricSm.copyWith(color: Colors.white, fontSize: 16)),
            const SizedBox(width: Sp.x4),
            Text(_fmt(w.elapsed), style: AppText.metricSm.copyWith(
                color: Colors.white60, fontSize: 15, fontFeatures: [const FontFeature.tabularFigures()])),
            const SizedBox(width: Sp.x2),
            const AppIcon(Ic.arrowRight, size: 16, color: Colors.white38),
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

/// Floating nav: a coral pill that FOLLOWS the page position in real time
/// (juicy, never overshoots), CLIPPED to the bar so it can't escape, and you
/// can scrub a finger across it to flip pages. Equal slots → never overflows.
class _ScrubNav extends StatelessWidget {
  final List<(IconData, String)> items;
  final PageController controller;
  final int index;
  final ValueChanged<int> onSelect;
  const _ScrubNav({
    required this.items,
    required this.controller,
    required this.index,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    const inset = 5.0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.x6, 0, Sp.x6, Sp.x3),
        child: LayoutBuilder(builder: (context, c) {
          final slot = c.maxWidth / items.length;
          void handle(double dx) =>
              onSelect((dx / slot).floor().clamp(0, items.length - 1));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => handle(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => handle(d.localPosition.dx),
            child: Container(
              height: 66,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(R.pill),
                boxShadow: Shadows.lift,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(R.pill),
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) {
                    final page =
                        controller.hasClients && controller.page != null
                            ? controller.page!
                            : index.toDouble();
                    final frac =
                        page.clamp(0.0, (items.length - 1).toDouble());
                    return Stack(
                      children: [
                        Positioned(
                          top: inset,
                          bottom: inset,
                          left: frac * slot + inset,
                          width: slot - inset * 2,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.coral,
                              borderRadius: BorderRadius.circular(R.pill),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            for (int i = 0; i < items.length; i++)
                              Expanded(
                                child: _NavItem(
                                  icon: items[i].$1,
                                  label: items[i].$2,
                                  t: (1 - (frac - i).abs()).clamp(0.0, 1.0),
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final double t; // 0 = inactive, 1 = pill fully over this slot
  const _NavItem(
      {required this.icon, required this.label, required this.t});
  @override
  Widget build(BuildContext context) {
    final color = Color.lerp(AppColors.inkMuted, Colors.white, t)!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: 22, color: color),
          if (t > 0.55) ...[
            const SizedBox(height: 2),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: AppText.overline.copyWith(
                    color: Colors.white, fontSize: 9.5, letterSpacing: 0.2)),
          ],
        ],
      ),
    );
  }
}
