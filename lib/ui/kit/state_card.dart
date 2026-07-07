// StateCard — the one empty / error / "nothing yet" card, extracted from the
// half-dozen copy-pasted `_stateCard(icon, title, message)` helpers across the
// app. A coral-soft circle icon that gently breathes, a title, a message, and an
// optional action button. Same visual as before, one home now.

import 'package:flutter/material.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'kit.dart';

class StateCard extends StatefulWidget {
  final OsIcon icon;
  final String title;
  final String message;

  /// Optional action button (e.g. "Try again"). Both must be set to show it.
  final String? actionLabel;
  final VoidCallback? onAction;

  const StateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<StateCard> createState() => _StateCardState();
}

class _StateCardState extends State<StateCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);
  late final Animation<double> _scale = Tween<double>(
    begin: 0.96,
    end: 1.05,
  ).animate(CurvedAnimation(parent: _breathe, curve: Curves.easeInOut));

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showAction = widget.actionLabel != null && widget.onAction != null;
    return ProCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Column(
        children: [
          ScaleTransition(
            scale: _scale,
            child: Container(
              // Glyph: 16 + 30 + 16; art: 11 + 40 + 11 — same 62px circle.
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: AppColors.coralSoft,
                shape: BoxShape.circle,
              ),
              child: OsAppIcon(widget.icon, size: 40),
            ),
          ),
          const SizedBox(height: Sp.x4),
          Text(widget.title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(
            widget.message,
            style: AppText.bodySoft,
            textAlign: TextAlign.center,
          ),
          if (showAction) ...[
            const SizedBox(height: Sp.x5),
            OutlinedButton(
              onPressed: widget.onAction,
              child: Text(widget.actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
