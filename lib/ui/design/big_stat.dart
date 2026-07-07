// BigStat — the huge-tabular-number identity of the redesign (the refs put a
// display-weight figure with a tiny superscript unit over a whispered label;
// the number IS the interface). Tone-aware: inside a [BentoTile] it reads its
// colours from [ToneScope], so the same widget is ink-on-paper, paper-on-ink
// or white-on-accent without any wiring.
//
//   BigStat(value: '52', unit: 'bpm', label: 'RESTING HR')
//   BigStat.dash(label: 'SKIN TEMP')          // honest em-dash
//
// No glow, no decoration — presence comes from weight and space.

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/os_icons.dart';
import 'bento.dart';

enum BigStatSize { xl, lg, md }

class BigStat extends StatelessWidget {
  /// Formatted value ('52', '7:42', '8 412'). Null renders the honest em-dash.
  final String? value;

  /// Small unit set beside the number's cap height ('bpm', 'ms', '/MI').
  final String? unit;

  /// Whispered overline label above the number.
  final String? label;

  /// Quiet line under the number (a status word, 'of 10 000'…).
  final String? caption;

  final BigStatSize size;

  /// Override the number colour (defaults to the tone's fg).
  final Color? color;

  /// Colour [caption] with the tone's accent instead of muted ink — the refs'
  /// status word ('Superior', 'Overtraining').
  final bool captionAccent;

  const BigStat({
    super.key,
    required this.value,
    this.unit,
    this.label,
    this.caption,
    this.size = BigStatSize.lg,
    this.color,
    this.captionAccent = false,
  });

  const BigStat.dash({
    super.key,
    this.label,
    this.caption,
    this.size = BigStatSize.lg,
    this.color,
  }) : value = null,
       unit = null,
       captionAccent = false;

  TextStyle _valueStyle(ToneColors tone) {
    final base = switch (size) {
      BigStatSize.xl => AppText.hero.copyWith(fontSize: 52, letterSpacing: -2),
      BigStatSize.lg => AppText.display.copyWith(fontSize: 36),
      BigStatSize.md => AppText.metric.copyWith(fontSize: 27),
    };
    return base.copyWith(color: color ?? tone.fg);
  }

  @override
  Widget build(BuildContext context) {
    final tone = ToneScope.of(context);
    final vs = _valueStyle(tone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(
            label!.toUpperCase(),
            style: AppText.overline.copyWith(color: tone.fgFaint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: size == BigStatSize.xl ? Sp.x2 : Sp.x1 + 2),
        ],
        // The number must ALWAYS be fully visible: value+unit lay out at their
        // intrinsic width and scale down together when the tile is narrower
        // (never ellipsize a figure — '7h 4…' is worse than a smaller '7h 42m').
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value ?? '—',
                style: value == null
                    ? vs.copyWith(color: tone.fgFaint)
                    : vs,
                maxLines: 1,
              ),
              if (unit != null && value != null) ...[
                const SizedBox(width: Sp.x1),
                Text(
                  unit!,
                  style: AppText.caption.copyWith(
                    color: tone.fgMuted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: Sp.x1),
          Text(
            caption!,
            style: AppText.caption.copyWith(
              color: captionAccent ? tone.accent : tone.fgMuted,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// A whispered overline + optional trailing widget row for tile headers —
/// keeps bento tiles aligned without every caller re-building the same Row.
class TileHeader extends StatelessWidget {
  final String label;
  final OsIcon? icon;
  final Widget? trailing;
  const TileHeader(this.label, {super.key, this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    final tone = ToneScope.of(context);
    return Row(
      children: [
        if (icon != null) ...[
          OsAppIcon(icon!, size: 36),
          const SizedBox(width: Sp.x2),
        ],
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: AppText.overline.copyWith(color: tone.fgFaint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ?trailing,
      ],
    );
  }
}
