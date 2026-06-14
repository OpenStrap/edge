import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'theme/theme.dart';
import 'theme/tokens.dart';
import 'ui/kit/kit.dart';
import 'ui/onboarding_screens.dart';
import 'ui/pairing_screen.dart';
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final app = context.read<AppState>();
    if (state == AppLifecycleState.resumed) {
      app.maybeFinishFromLiveActivity();
      if (app.isAuthenticated && app.isPaired) app.openSession();
    } else if (state == AppLifecycleState.paused) {
      // Backgrounded: hand the band to the iOS restore path so it can wake-and-drain
      // in the background (no-op on Android, where the foreground service holds it).
      app.pauseForBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenStrap',
      debugShowCheckedModeBanner: false,
      theme: buildOpenStrapTheme(),
      home: const _Gate(),
    );
  }
}

/// Onboarding gate: backend choice ("the catch") → auth → profile → pairing → app.
class _Gate extends StatelessWidget {
  const _Gate();
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.initialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: AppColors.coral)),
      );
    }
    if (!app.backendChosen) return const BackendChoiceScreen();
    if (!app.isAuthenticated) return const AuthScreen();
    if (!app.profileComplete) return const ProfileSetupScreen();
    if (!app.isPaired) return const PairingScreen();
    return const _Shell();
  }
}

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  final _controller = PageController();
  int _index = 0;

  static const _pages = [
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
        onPageChanged: (i) => setState(() => _index = i),
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
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LiveSessionScreen(workoutId: w.workoutId, type: w.type)));
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
              decoration: const BoxDecoration(color: AppColors.coral, shape: BoxShape.circle))),
            const SizedBox(width: Sp.x3),
            Text('LIVE · ${w.type.toUpperCase()}', style: AppText.overline.copyWith(color: Colors.white70)),
            const Spacer(),
            const AppIcon(Ic.heart, size: 15, color: AppColors.coral),
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
