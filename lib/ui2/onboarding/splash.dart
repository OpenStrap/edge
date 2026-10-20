// The cold-start cover.
//
// AppState's init (SQLite open, migrations, first derive check) is the slow
// part of a launch and it happens before anything can be drawn honestly. This
// covers exactly that window and cross-fades out the instant the gate leaves
// `loading`. Shown once per launch; it latches itself off afterwards so a later
// rebuild never re-covers a running app.
//
// The cover is a glyph and a word on the page background — nothing to decode,
// nothing to buffer, no frame the launch waits on. It used to be a bundled
// video, which put an asset load and a codec on the critical path of the one
// moment the app is already slowest.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui2.dart';

class BootSplash extends StatefulWidget {
  /// True once the app behind the cover is ready to be looked at.
  final bool ready;
  final Widget child;

  const BootSplash({super.key, required this.ready, required this.child});

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash> {
  /// Latched once the cover has faded. A splash that can come back is a splash
  /// that will come back at the worst possible moment.
  bool _gone = false;

  @override
  Widget build(BuildContext c) {
    if (_gone) return widget.child;
    // Reduced motion has no fade to hide behind, so the cover simply stops
    // existing the moment the app is ready — and latches here, because the
    // AnimatedOpacity's onEnd is not on this path. Without the latch a retry
    // after a failed init (route back to `loading`) re-covered the screen and
    // hid the spinner it had just started. No setState: the widget returned
    // is the same one either way.
    if (widget.ready && !Motion.enabled(c)) {
      _gone = true;
      return widget.child;
    }
    return Stack(children: [
      widget.child,
      Positioned.fill(
        // `IgnorePointer` blocks touch and NOT semantics, so while the user saw
        // only the splash a screen reader was walking the whole live app
        // underneath it. `BlockSemantics` is the half that was missing.
        child: BlockSemantics(
          child: IgnorePointer(
            ignoring: widget.ready,
            child: AnimatedOpacity(
              opacity: widget.ready ? 0 : 1,
              duration: motion(c, Motion.slow),
              onEnd: () {
                if (widget.ready && mounted) setState(() => _gone = true);
              },
              child: const _Cover(),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _Cover extends StatelessWidget {
  const _Cover();

  // Char in both themes, like the onboarding it opens onto (§6, D4).
  @override
  Widget build(BuildContext c) =>
      AlwaysChar(child: Builder(builder: _build));

  Widget _build(BuildContext c) {
    final p = P.of(c);
    // Material, not ColoredBox: the cover sits at MaterialApp.home, above every
    // route, so its own text has no Material ancestor to inherit from and debug
    // builds painted the missing-Material underline right across the wordmark.
    return Material(
      color: p.bg,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.activity, size: I.hero, color: p.on(C.green)),
          const SizedBox(height: S.x4),
          Text('Locus', style: F.t2.copyWith(color: p.ink)),
        ]),
      ),
    );
  }
}
