// Pressable — THE tactile press primitive of the design system. Every
// interactive card/tile/pill wraps this once instead of re-implementing
// scale-on-press + haptics + ripple.
//
//  • Scale dips to [pressedScale] on pointer-down (Listener-based, so the
//    child's own InkWell ripple still fires).
//  • A selection-click haptic on tap (opt out with `haptic: false`).
//  • Optional ink ripple clipped to [borderRadius].

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';

class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed. 0.98 for large cards, ~0.94 for small chips.
  final double pressedScale;

  /// Fire a selection-click haptic on tap.
  final bool haptic;

  /// When set, an ink ripple is drawn clipped to this radius.
  final BorderRadius? borderRadius;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.98,
    this.haptic = true,
    this.borderRadius,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  bool get _interactive => widget.onTap != null || widget.onLongPress != null;

  void _handleTap() {
    if (widget.haptic) HapticFeedback.selectionClick();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_interactive) return widget.child;

    Widget result = widget.child;
    if (widget.borderRadius != null) {
      result = Material(
        color: Colors.transparent,
        borderRadius: widget.borderRadius,
        child: InkWell(
          borderRadius: widget.borderRadius,
          onTap: _handleTap,
          onLongPress: widget.onLongPress,
          child: result,
        ),
      );
    } else {
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        onLongPress: widget.onLongPress,
        child: result,
      );
    }

    return Listener(
      onPointerDown: (_) { if (mounted) setState(() => _down = true); },
      onPointerUp: (_) { if (mounted) setState(() => _down = false); },
      onPointerCancel: (_) { if (mounted) setState(() => _down = false); },
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        duration: Motion.fast,
        curve: Motion.curve,
        child: result,
      ),
    );
  }
}
