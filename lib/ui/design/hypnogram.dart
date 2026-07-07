// Sleep-stage visualizations — the clean stage language from the refs:
//
//  • [Hypnogram] — the stepped stage timeline (Awake / REM / Light / Deep as
//    rows; coloured segments at their row height joined by hairline risers).
//  • [StageBars] — the compact single-row stage distribution (one rounded
//    stacked bar + a quiet legend), for tiles that can't afford a timeline.
//
// Both read stage colours from [DomainAccent] so every sleep visual in the
// app speaks the same palette, in both themes. Honest by contract: callers
// pass real segments/minutes or nothing renders — no fabricated shapes.

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'domains.dart';

/// Canonical stage order, top row → bottom row (the refs' convention).
enum SleepStage { awake, rem, light, deep }

Color stageColor(SleepStage s) => switch (s) {
  SleepStage.awake => DomainAccent.stageAwake,
  SleepStage.rem => DomainAccent.stageRem,
  SleepStage.light => DomainAccent.stageLight,
  SleepStage.deep => DomainAccent.stageDeep,
};

String stageName(SleepStage s) => switch (s) {
  SleepStage.awake => 'Awake',
  SleepStage.rem => 'REM',
  SleepStage.light => 'Light',
  SleepStage.deep => 'Deep',
};

/// One hypnogram segment over normalized night time (0..1).
class HypnoSeg {
  final SleepStage stage;
  final double start;
  final double end;
  const HypnoSeg(this.stage, this.start, this.end);
}

/// Parse the repository's hypnogram points ([{t, stage}], stage strings like
/// 'awake'/'rem'/'light'/'deep'/'core'/'nrem') into normalized segments.
/// Unknown stages are skipped; < 2 points → empty (nothing renders).
List<HypnoSeg> hypnoSegmentsFromPoints(List<dynamic> points) {
  SleepStage? parse(Object? s) => switch ('$s'.toLowerCase()) {
    'awake' || 'wake' => SleepStage.awake,
    'rem' => SleepStage.rem,
    'light' || 'core' || 'nrem' => SleepStage.light,
    'deep' => SleepStage.deep,
    _ => null,
  };
  final pts = <(num, SleepStage)>[];
  for (final p in points) {
    if (p is! Map) continue;
    final t = p['t'] as num?;
    final st = parse(p['stage']);
    if (t == null || st == null) continue;
    pts.add((t, st));
  }
  if (pts.length < 2) return const [];
  final t0 = pts.first.$1, t1 = pts.last.$1;
  final span = (t1 - t0).toDouble();
  if (span <= 0) return const [];
  final segs = <HypnoSeg>[];
  for (var i = 0; i + 1 < pts.length; i++) {
    segs.add(
      HypnoSeg(
        pts[i].$2,
        ((pts[i].$1 - t0) / span).toDouble(),
        ((pts[i + 1].$1 - t0) / span).toDouble(),
      ),
    );
  }
  return segs;
}

/// The stepped stage timeline. Rows top→bottom: Awake / REM / Light / Deep.
class Hypnogram extends StatelessWidget {
  final List<HypnoSeg> segments;
  final double height;

  /// Show the row labels down the left edge.
  final bool labels;

  /// Optional start/end captions under the plot ('11:24 pm', '7:05 am').
  final String? startLabel;
  final String? endLabel;

  const Hypnogram(
    this.segments, {
    super.key,
    this.height = 96,
    this.labels = true,
    this.startLabel,
    this.endLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (segments.isEmpty) return const SizedBox.shrink();
    final plot = RepaintBoundary(
      child: CustomPaint(
        size: Size(double.infinity, height),
        painter: _HypnogramPainter(
          segments: segments,
          colors: [for (final s in SleepStage.values) stageColor(s)],
          gridColor: AppColors.divider,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (labels)
              SizedBox(
                height: height,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final s in SleepStage.values)
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            stageName(s),
                            style: AppText.captionMuted.copyWith(fontSize: 10),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (labels) const SizedBox(width: Sp.x3),
            Expanded(child: SizedBox(height: height, child: plot)),
          ],
        ),
        if (startLabel != null || endLabel != null) ...[
          const SizedBox(height: Sp.x1),
          Padding(
            padding: EdgeInsets.only(left: labels ? 46 : 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(startLabel ?? '', style: AppText.captionMuted),
                Text(endLabel ?? '', style: AppText.captionMuted),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _HypnogramPainter extends CustomPainter {
  final List<HypnoSeg> segments;
  final List<Color> colors; // indexed by SleepStage
  final Color gridColor;
  _HypnogramPainter({
    required this.segments,
    required this.colors,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rows = SleepStage.values.length;
    final rowH = size.height / rows;

    // Faint row guides.
    final grid = Paint()
      ..strokeWidth = 1
      ..color = gridColor.withValues(alpha: 0.6);
    for (var r = 0; r < rows; r++) {
      final y = rowH * r + rowH / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // Segments at their row heights, joined by hairline risers.
    final bar = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final riser = Paint()
      ..strokeWidth = 1.2
      ..color = gridColor;
    double yFor(SleepStage s) => rowH * s.index + rowH / 2;

    Offset? prevEnd;
    for (final seg in segments) {
      final y = yFor(seg.stage);
      final x0 = (seg.start.clamp(0.0, 1.0)) * size.width;
      final x1 = (seg.end.clamp(0.0, 1.0)) * size.width;
      final w = x1 - x0;
      if (w <= 0) continue;
      if (prevEnd != null && (prevEnd.dy - y).abs() > 1) {
        canvas.drawLine(Offset(x0, prevEnd.dy), Offset(x0, y), riser);
      }
      bar.color = colors[seg.stage.index];
      if (w < 8) {
        // Brief bouts (a 1–2 min Deep dip over a whole night is sub-pixel):
        // draw a centred minimum-width dash instead of skipping or letting the
        // cap inset flip the line backwards — every real stage bout stays
        // visible.
        final mid = (x0 + x1) / 2;
        final half = w / 2 < 1.5 ? 1.5 : w / 2;
        canvas.drawLine(
          Offset((mid - half).clamp(0.0, size.width), y),
          Offset((mid + half).clamp(0.0, size.width), y),
          bar,
        );
      } else {
        // Inset the round caps so adjacent segments don't overlap.
        canvas.drawLine(Offset(x0 + 2.5, y), Offset(x1 - 2.5, y), bar);
      }
      prevEnd = Offset(x1, y);
    }
  }

  @override
  bool shouldRepaint(_HypnogramPainter old) =>
      old.segments != segments || old.colors != colors;
}

/// Compact stage distribution: one rounded stacked bar + a quiet legend.
/// Pass minutes per stage; nulls/zeros are skipped honestly.
class StageBars extends StatelessWidget {
  final int? awakeMin;
  final int? remMin;
  final int? lightMin;
  final int? deepMin;
  final double height;

  /// Show the legend row under the bar.
  final bool legend;

  const StageBars({
    super.key,
    this.awakeMin,
    this.remMin,
    this.lightMin,
    this.deepMin,
    this.height = 10,
    this.legend = true,
  });

  @override
  Widget build(BuildContext context) {
    final entries = <(SleepStage, int)>[
      if ((awakeMin ?? 0) > 0) (SleepStage.awake, awakeMin!),
      if ((remMin ?? 0) > 0) (SleepStage.rem, remMin!),
      if ((lightMin ?? 0) > 0) (SleepStage.light, lightMin!),
      if ((deepMin ?? 0) > 0) (SleepStage.deep, deepMin!),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    final total = entries.fold<int>(0, (a, e) => a + e.$2);

    String hm(int m) =>
        m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}' : '${m}m';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(R.pill),
          child: SizedBox(
            height: height,
            child: Row(
              children: [
                for (var i = 0; i < entries.length; i++)
                  Expanded(
                    flex: (entries[i].$2 * 1000 / total).round().clamp(1, 1000000),
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: i == entries.length - 1 ? 0 : 2,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: stageColor(entries[i].$1),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (legend) ...[
          const SizedBox(height: Sp.x2),
          Wrap(
            spacing: Sp.x3,
            runSpacing: Sp.x1,
            children: [
              for (final (stage, min) in entries)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: stageColor(stage),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${stageName(stage)} ${hm(min)}',
                      style: AppText.captionMuted.copyWith(fontSize: 10.5),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}
