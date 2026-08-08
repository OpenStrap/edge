// SyncDot — the quietest possible "data is arriving".
//
// From TestFlight: "don't get to know if syncing is happening or not". The sync
// is deliberately invisible in this app — no progress bars, no spinners, no
// "syncing…" copy — and that is the right default, because the band syncs
// constantly and a user cannot act on any of it. But invisible and broken look
// identical, which is what the report is really about.
//
// So: a 6pt dot beside the title that breathes while records are landing, and
// is absent otherwise. No text, no layout shift (the space is held either way),
// nothing to dismiss. If you are not looking for it you will not notice it; if
// you are wondering whether the thing works, it answers you.

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class SyncDot extends StatefulWidget {
  const SyncDot({super.key, required this.active, this.size = 6});

  /// Records are landing right now (`AppState.syncingNow`).
  final bool active;
  final double size;

  @override
  State<SyncDot> createState() => _SyncDotState();
}

class _SyncDotState extends State<SyncDot>
    with SingleTickerProviderStateMixin {
  // Created in initState, NOT as a lazy `late final` initialiser. A dot that
  // never animates never touches the field, so the first read would be
  // `dispose()` — building a Ticker against an already-deactivated element,
  // which throws "Looking up a deactivated widget's ancestor is unsafe". The
  // quiet path is the common one, so the lazy version was broken for almost
  // every user of this widget.
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.active) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant SyncDot old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    // Never leave the controller running while the dot is invisible — a
    // repeating animation on an off-screen widget is a permanent 60 Hz wake-up
    // on a screen that already fights for the main isolate during a drain.
    if (widget.active) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The box is always occupied, so the title never shifts when the dot
    // appears or goes — a jumping wordmark would be far louder than the dot.
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: !widget.active
          ? const SizedBox.shrink()
          : Semantics(
              label: 'Syncing with your band',
              liveRegion: true,
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.25, end: 1).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
    );
  }
}
