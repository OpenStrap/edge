// OrbitScore — the whole-health hero: one radial score with the health
// domains orbiting it as tappable satellite chips (the image-4 pattern).
// The center carries the big number + status word; faint concentric orbit
// rings give structure; each satellite sits on the outer orbit and routes to
// its domain screen. Restrained by design: hairline rings, no glow, no
// particles — presence comes from scale and composition.
//
//   OrbitScore(
//     score: 82,                        // null → honest baseline/empty center
//     word: 'Primed',
//     color: AppColors.scoreColor(0.82),
//     satellites: [
//       OrbitSatellite(icon: OsIcon.sleep, label: 'Sleep', onTap: …),
//       …up to 4, rendered at staggered orbit anchors…
//     ],
//   )

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show OsAppIcon, OsIcon;
import 'arc_gauge.dart';
import 'motion.dart';
import 'pressable.dart';

class OrbitSatellite {
  final OsIcon icon;

  /// Optional illustrated icon — replaces the tinted [icon] glyph when the
  /// domain has full-colour art (rendered as-is, never tinted).
  final String label;

  /// Optional tiny value shown after the label ('48 ms').
  final String? value;
  final Color? color;
  final VoidCallback? onTap;
  const OrbitSatellite({
    required this.icon,
    required this.label,
    this.value,
    this.color,
    this.onTap,
  });
}

class OrbitScore extends StatelessWidget {
  /// 0–100 score. Null renders [center] (the honest building/empty state).
  final int? score;

  /// Status word under the number ('Primed', 'Steady', 'Run easy').
  final String? word;

  /// Whispered overline above the number ('READINESS').
  final String? label;

  final Color? color;

  /// Ring confidence (dashed < 0.4, fades when low) — same contract as
  /// [ArcGauge].
  final double confidence;

  /// Replaces the score center when [score] is null (e.g. a nights-to-go
  /// baseline gauge).
  final Widget? center;

  /// Ring fill override for the null-score state — e.g. baseline progress
  /// (2 of 5 nights = 0.4) while the honest center explains it.
  final double? ringFill;

  /// Up to four satellites, anchored NE / SE / SW / NW around the orbit.
  final List<OrbitSatellite> satellites;

  /// Tap on the score core itself.
  final VoidCallback? onTap;

  final double height;

  const OrbitScore({
    super.key,
    required this.score,
    this.word,
    this.label,
    this.color,
    this.confidence = 1.0,
    this.center,
    this.ringFill,
    this.satellites = const [],
    this.onTap,
    this.height = 280,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.accent;

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final side = math.min(w, height);
          // Core gauge ≈ half the shorter side; orbits fill the rest.
          final coreSize = (side * 0.52).clamp(120.0, 168.0);
          final orbitR = coreSize / 2 + side * 0.16;

          final coreCenter = Offset(w / 2, height / 2);

          Widget core = ArcGauge(
            value: score == null
                ? (ringFill ?? double.nan)
                : (score! / 100).clamp(0.0, 1.0),
            color: c,
            size: coreSize,
            stroke: 10,
            sweepFraction: 0.78,
            confidence: confidence,
            center:
                center ??
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (label != null)
                      Text(
                        label!.toUpperCase(),
                        style: AppText.overline.copyWith(
                          fontSize: (coreSize * 0.062).clamp(8.0, 11.0),
                        ),
                      ),
                    Text(
                      score == null ? '—' : '$score',
                      style: AppText.display.copyWith(
                        fontSize: coreSize * 0.32,
                        color: score == null ? AppColors.inkMuted : null,
                      ),
                    ),
                    if (word != null)
                      Text(
                        word!,
                        style: AppText.caption.copyWith(
                          color: c,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                  ],
                ),
          );
          if (onTap != null) {
            core = Pressable(pressedScale: 0.96, onTap: onTap, child: core);
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Faint concentric orbits (hairline; structure, not decoration).
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _OrbitRingsPainter(
                      center: coreCenter,
                      radii: [orbitR * 0.82, orbitR],
                      color: AppColors.inkMuted.withValues(
                        alpha: AppColors.isDark ? 0.22 : 0.28,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: coreCenter.dx - coreSize / 2,
                top: coreCenter.dy - coreSize / 2,
                child: core.dsEnter(),
              ),
              ..._placeSatellites(w, coreCenter, orbitR),
            ],
          );
        },
      ),
    );
  }

  /// Anchor the (up to 4) satellites at staggered angles on the outer orbit,
  /// clamped into the box so chips never overflow the screen edge.
  List<Widget> _placeSatellites(double w, Offset c, double r) {
    // NE, SW, SE, NW — alternating sides reads balanced with any count.
    const angles = [-0.30 * math.pi, 0.72 * math.pi, 0.28 * math.pi, -0.72 * math.pi];
    final out = <Widget>[];
    for (var i = 0; i < satellites.length && i < 4; i++) {
      final s = satellites[i];
      final ang = angles[i];
      final p = c + Offset(math.cos(ang), math.sin(ang)) * r;
      out.add(
        Positioned(
          left: p.dx < w / 2 ? math.max(0, p.dx - 76) : null,
          right: p.dx >= w / 2 ? math.max(0, w - p.dx - 76) : null,
          // Half the chip height (6+6 padding + 34 icon = 46) keeps the pill
          // vertically centred on its orbit anchor.
          top: p.dy - 23,
          child: _SatelliteChip(s).dsEnter(index: i + 2),
        ),
      );
    }
    return out;
  }
}

class _SatelliteChip extends StatelessWidget {
  final OrbitSatellite s;
  const _SatelliteChip(this.s);

  @override
  Widget build(BuildContext context) {
    return Pressable(
      pressedScale: 0.92,
      onTap: s.onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 152),
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 6),
        decoration: BoxDecoration(
          color: Elevation.surfaceAt(2),
          borderRadius: BorderRadius.circular(R.pill),
          border: Elevation.border(2),
          boxShadow: Elevation.shadows(1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The illustrations carry built-in transparent padding, so they
            // need a larger canvas (34) than the 28px glyph disc to read at
            // the same visual weight inside the pill.
            OsAppIcon(s.icon, size: 34),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                s.label,
                style: AppText.caption.copyWith(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (s.value != null) ...[
              const SizedBox(width: Sp.x1 + 2),
              Text(
                s.value!,
                style: AppText.caption.copyWith(color: AppColors.inkSoft),
                maxLines: 1,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OrbitRingsPainter extends CustomPainter {
  final Offset center;
  final List<double> radii;
  final Color color;
  _OrbitRingsPainter({
    required this.center,
    required this.radii,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    for (final r in radii) {
      canvas.drawCircle(center, r, p);
    }
    // Four quiet anchor ticks on the outer orbit (N/E/S/W) — a compass, not
    // decoration; they make the orbit read as a measured instrument.
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = color;
    final r = radii.last;
    for (var k = 0; k < 4; k++) {
      final a = k * math.pi / 2;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        center + dir * (r - 3),
        center + dir * (r + 3),
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(_OrbitRingsPainter old) =>
      old.center != center || old.color != color || old.radii != radii;
}
