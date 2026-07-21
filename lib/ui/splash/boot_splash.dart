// Cold-start splash video.
//
// Shown ONCE per app launch, layered over whatever the route gate resolves to,
// while `AppState.route == AppRoute.loading` (i.e. AppState is still doing its
// boot/background init). The instant the route leaves `loading` the overlay
// cross-fades out (~250 ms) — a fast phone barely sees the video, a slow phone
// stays covered. If the ~10 s video finishes before the app is ready it freezes
// on its last frame (no loop, never black). A hard safety cap dismisses the
// overlay after [maxHold] even if the ready signal never fires, so the splash
// can never hang the app.
//
// Failure honesty: if the controller can't initialize (asset missing, codec /
// platform unsupported, reduced-motion), a static brand mark on the themed
// background is shown instead — never a crash, never a black screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/tokens.dart';

class BootSplash extends StatefulWidget {
  /// True once the route gate has resolved (route left `AppRoute.loading`).
  final bool ready;

  /// Whatever the gate wants to show — rendered underneath the splash so the
  /// cross-fade reveals the already-built screen (no flash of nothing).
  final Widget child;

  /// Hard safety cap: dismiss even if [ready] never flips.
  final Duration maxHold;

  /// Cross-fade duration on dismissal.
  final Duration fade;

  /// Test seam — inject a fake/failing controller. Defaults to the bundled
  /// asset video. A factory that throws lands on the static fallback.
  final VideoPlayerController Function()? controllerFactory;

  const BootSplash({
    super.key,
    required this.ready,
    required this.child,
    this.maxHold = const Duration(seconds: 12),
    this.fade = const Duration(milliseconds: 250),
    this.controllerFactory,
  });

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash> {
  VideoPlayerController? _video;
  bool _videoUp = false; // controller initialized + playing

  bool _fadingOut = false; // cross-fade running
  // Latched: once true the overlay is gone for the rest of this launch —
  // cold-start once, never re-shown on later route changes. If the app is
  // already ready at first build (hot restart, tests) there is no splash.
  late bool _gone = widget.ready;

  Timer? _cap;
  Timer? _fadeDone;
  bool _bootstrapped = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bootstrapped) return;
    _bootstrapped = true;
    if (_gone) return;
    _cap = Timer(widget.maxHold, _dismiss);
    // Respect reduced motion: skip the video, keep the static brand surface.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!reduceMotion) _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final c = (widget.controllerFactory ??
          () => VideoPlayerController.asset(
                'assets/splash/splashscreen.mp4',
                // Don't grab audio focus for the (muted) splash video — a bare
                // controller pauses whatever the user is already playing on a
                // cold start. mixWithOthers lets their audio keep going.
                videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
              ))();
      _video = c;
      await c.initialize();
      await c.setVolume(0); // always muted
      await c.setLooping(false); // ended early → freeze on last frame
      await c.play();
      if (!mounted || _gone) return;
      setState(() => _videoUp = true);
    } catch (_) {
      // Asset/codec/platform failure — the static fallback is already what's
      // rendered; just make sure we never claim the video is up.
      if (mounted && !_gone && _videoUp) setState(() => _videoUp = false);
    }
  }

  @override
  void didUpdateWidget(BootSplash old) {
    super.didUpdateWidget(old);
    if (widget.ready && !old.ready) _dismiss();
  }

  void _dismiss() {
    if (_fadingOut || _gone || !mounted) return;
    _cap?.cancel();
    setState(() => _fadingOut = true);
    _fadeDone = Timer(widget.fade + const Duration(milliseconds: 30), () {
      if (!mounted) return;
      setState(() => _gone = true);
      // Dispose AFTER the frame that removed the VideoPlayer from the tree.
      final v = _video;
      _video = null;
      if (v != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => v.dispose());
      }
    });
  }

  @override
  void dispose() {
    _cap?.cancel();
    _fadeDone?.cancel();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        // IgnorePointer: taps during the brief fade land on the real screen.
        IgnorePointer(
          child: AnimatedOpacity(
            key: const Key('boot-splash'),
            opacity: _fadingOut ? 0.0 : 1.0,
            duration: widget.fade,
            child: _surface(),
          ),
        ),
      ],
    );
  }

  Widget _surface() {
    final v = _video;
    final Widget content;
    if (_videoUp && v != null && v.value.isInitialized) {
      final size = v.value.size;
      content = FittedBox(
        key: const Key('boot-splash-video'),
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width > 0 ? size.width : 720,
          height: size.height > 0 ? size.height : 1280,
          child: VideoPlayer(v),
        ),
      );
    } else {
      // Static brand fallback (also the pre-first-frame surface) — the app
      // icon on the themed background; errorBuilder so even a missing icon
      // degrades to the plain warm surface, never an exception.
      content = Center(
        key: const Key('boot-splash-fallback'),
        child: Image.asset(
          'assets/images/icon.png',
          width: 96,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    }
    // Warm paper (light) / deep char (dark) letterbox via the active palette.
    return ColoredBox(color: AppColors.bg, child: content);
  }
}
