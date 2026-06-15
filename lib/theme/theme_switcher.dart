// Smooth, foolproof theme switching.
//
// Two problems this solves:
//  1) Colours are global statics (AppColors.x), so the framework has no
//     dependency edge telling it what to rebuild when the mode flips. We fix
//     that by making every route rebuild: the home stack watches the controller
//     (see app.dart), and pushed routes go through [themedRoute], whose body is
//     a [_ThemeReactive] that depends on the controller and reconstructs its
//     screen on change (State is preserved — same type at the same position).
//  2) A hard colour swap looks janky. [ThemeSwitchOverlay] snapshots the live
//     frame the instant before the swap and cross-fades it out over the freshly
//     re-coloured tree underneath — a clean dissolve, with the nav stack intact.

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import 'theme_controller.dart';
import 'tokens.dart';

/// Wrap a screen builder so the route rebuilds on every mode change.
/// Use everywhere instead of `MaterialPageRoute(builder: ...)`.
PageRoute<T> themedRoute<T>(WidgetBuilder builder, {bool fullscreenDialog = false}) =>
    MaterialPageRoute<T>(
      fullscreenDialog: fullscreenDialog,
      builder: (ctx) => _ThemeReactive(builder: builder),
    );

class _ThemeReactive extends StatelessWidget {
  final WidgetBuilder builder;
  const _ThemeReactive({required this.builder});
  @override
  Widget build(BuildContext context) {
    // Depend on the controller → this route's body rebuilds when the mode flips,
    // reconstructing the screen with fresh AppColors while keeping its State.
    context.watch<ThemeController>();
    return builder(context);
  }
}

/// Global handle so the appearance picker can trigger the cross-fade from
/// anywhere (e.g. inside a pushed Profile route).
final GlobalKey<ThemeSwitchOverlayState> themeSwitchKey =
    GlobalKey<ThemeSwitchOverlayState>();

/// Captures the current frame and cross-fades it out after a theme swap.
/// Installed once via MaterialApp.builder, above the Navigator.
class ThemeSwitchOverlay extends StatefulWidget {
  final Widget child;
  const ThemeSwitchOverlay({super.key, required this.child});
  @override
  State<ThemeSwitchOverlay> createState() => ThemeSwitchOverlayState();
}

class ThemeSwitchOverlayState extends State<ThemeSwitchOverlay>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boundaryKey = GlobalKey();
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..addListener(() => setState(() {}));
  ui.Image? _snapshot;

  @override
  void dispose() {
    _fade.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  /// Snapshot the old frame, run [applySwitch] (which swaps the palette and
  /// notifies), then dissolve the snapshot to reveal the re-coloured tree.
  void run(VoidCallback applySwitch) {
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      applySwitch();
      return;
    }
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final shot = boundary.toImageSync(pixelRatio: dpr);
      _snapshot?.dispose();
      // Paint the captured (old) frame on top in this same frame, so swapping
      // the palette underneath is never visible until the dissolve runs.
      setState(() => _snapshot = shot);
    } catch (_) {
      // toImageSync can fail mid-frame; fall back to an instant swap.
      applySwitch();
      return;
    }
    applySwitch();
    _fade
      ..value = 0
      ..forward().whenComplete(() {
        if (!mounted) return;
        final old = _snapshot;
        setState(() => _snapshot = null);
        old?.dispose();
      });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        if (_snapshot != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: (1.0 - Motion.curve.transform(_fade.value)).clamp(0.0, 1.0),
                child: RawImage(image: _snapshot, fit: BoxFit.cover),
              ),
            ),
          ),
      ],
    );
  }
}
