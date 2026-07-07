// AiSummaryCard — the Today screen's AI morning-briefing SLOT.
//
// Presentation-only: the card renders whatever one-liner the AI engine hands
// it and stays graceful while there is nothing yet. Now drawn with the
// design-system [AiHero] (the refs' briefing hero) — the engine contract is
// unchanged: supply [summary] (and optionally flip [busy] while generating).
//
//   AiSummaryCard(
//     summary: null,            // null → quiet "your briefing will appear" state
//     busy: false,              // true → subtle generating affordance
//     onTap: openBreakdown,     // whole-card tap → full AI breakdown (or generate)
//   )

import 'package:flutter/material.dart';

import '../design/design.dart';

class AiSummaryCard extends StatelessWidget {
  /// The one-line AI summary. Null renders the graceful empty/"generate" state.
  final String? summary;

  /// True while the engine is generating — shows a quiet progress affordance.
  final bool busy;

  /// Whole-card tap → the full breakdown (filled) or a generate action (empty).
  final VoidCallback? onTap;

  const AiSummaryCard({
    super.key,
    required this.summary,
    this.busy = false,
    this.onTap,
  });

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final hasSummary = summary != null && summary!.trim().isNotEmpty;
    return AiHero(
      overline: _greeting,
      line: hasSummary ? summary : null,
      busy: busy,
      cta: onTap == null
          ? null
          : (hasSummary ? 'Tap for the breakdown' : 'Tap to generate'),
      onTap: onTap,
    );
  }
}
