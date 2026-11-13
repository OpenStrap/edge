import 'dart:math';

import 'package:flutter/material.dart';

const double kSpiralSeparator = 1.5;

/// Width of the lap separator: a LINE centred on the upper lap's outer edge,
/// 1.5 px at stroke 20 and up, scaled down with the stroke, and none below
/// 0.5 px. A tiny ring has no room to spend on a separator: the laps overlap
/// by a quarter stroke and an erased gap would leave empty rings.
double spiralSeparatorWidth(double stroke) {
  final w = kSpiralSeparator * min(1.0, stroke / 20);
  return w < .5 ? 0 : w;
}

class SpiralPiece {
  final int seg, lap;
  final double from, to;
  final bool capEnd, capStart;
  const SpiralPiece(this.seg, this.lap, this.from, this.to,
      {this.capEnd = false, this.capStart = false});
}

class SpiralGeometry {
  final double stroke, ramp, insetPerStroke;
  const SpiralGeometry(this.stroke, {this.ramp = .3, this.insetPerStroke = .75});

  double inset(double s) {
    if (!s.isFinite || s <= 1 || ramp <= 0) return 0;
    final lap = s.floor();
    final x = ((s - lap) / ramp).clamp(0.0, 1.0);
    if (x < .002) return insetPerStroke * stroke * (lap - 1).clamp(0, 1000000);
    if (1 - x < .002) return insetPerStroke * stroke * lap;
    return insetPerStroke * stroke * ((lap - 1) + (1 - cos(pi * x)) / 2);
  }

  /// Centre-line radius at [s]. Floored at 1.5 x stroke so a small ring at a
  /// high ratio (a 20 px ring at 500%) keeps its laps on the dial instead of
  /// running through the centre; beyond that laps overlap at the innermost
  /// radius and the value label carries the number.
  double radiusAt(double s, double r0) =>
      max(r0 - inset(s), min(r0, 1.5 * stroke));
  /// Laps after which a further lap would be drawn exactly on the previous
  /// one: the first lap whose held radius is at the floor, plus lap 0.
  ///
  /// DECISION (saturation): on a small ring at a high ratio the laps run out
  /// of room, so the picture stops growing here and the value label carries
  /// the true number. It also bounds the work per paint: a 200-lap input
  /// builds the same few paths as the saturation point. [Ring.pieces] still
  /// reports the full value.
  int saturationLaps(double r0) {
    final floor = min(r0, 1.5 * stroke);
    final step = insetPerStroke * stroke;
    if (r0 <= floor || step <= 0) return 1;
    return (r0 - floor) ~/ step + ((r0 - floor) % step > 1e-9 ? 1 : 0) + 1;
  }

  static int lapsFor(double fraction) =>
      !fraction.isFinite || fraction <= 0 ? 0 : fraction.ceil();

  List<SpiralPiece> pieces(List<double> fractions) {
    final valid = <(int, double)>[];
    for (var i = 0; i < fractions.length; i++) {
      final f = fractions[i];
      if (f.isFinite && f > 0) valid.add((i, f));
    }
    final total = valid.fold<double>(0, (a, b) => a + b.$2);
    if (!total.isFinite || total <= 0) return const [];
    final result = <SpiralPiece>[];
    var at = 0.0;
    final starts = <double>[];
    for (final e in valid) {
      starts.add(at);
      at += e.$2;
    }
    for (var lap = 0; lap < lapsFor(total); lap++) {
      final pieces = <SpiralPiece>[];
      for (var i = 0; i < valid.length; i++) {
        final start = starts[i], end = start + valid[i].$2;
        final from = max(start, lap.toDouble()), to = min(end, min(total, lap + 1.0));
        if (to <= from) continue;
        final trueStart = from == start, trueEnd = to == end;
        pieces.add(SpiralPiece(valid[i].$1, lap, from, to,
          capStart: trueStart && start == 0 && total < 1,
          capEnd: trueEnd));
      }
      result.addAll(pieces.reversed);
    }
    if (valid.length == 1 && total < 1 && result.isNotEmpty) {
      final p = result.single;
      result[0] = SpiralPiece(p.seg, p.lap, p.from, p.to, capStart: true, capEnd: true);
    }
    return result;
  }

  double? separatorFrom(int lap) {
    if (lap <= 0) return null;
    if (lap > 1) return lap.toDouble();
    final target = .5 / (insetPerStroke * stroke);
    return 1 + ramp * acos(1 - 2 * target.clamp(0.0, 1.0)) / pi;
  }
  static double gradientAt(double s, double total) =>
      total <= 0 || !total.isFinite ? 0 : (s / total).clamp(0.0, 1.0);
}

/// Shared rendering path for score and stage rings.
///
/// Every piece is a FILLED band whose radius follows [SpiralGeometry.radiusAt]
/// along its whole sweep, so the eased inset is drawn, not sampled once per
/// piece. Caps are separate discs: ends and starts are decided independently
/// by [SpiralPiece.capEnd] / [SpiralPiece.capStart]. [background] is the
/// surface under the ring (the lap separator); it falls back to [track].
void paintSpiral(Canvas canvas, Size size,
    {required double stroke,
    required Color track,
    required List<Color> colors,
    required List<double> fractions,
    required double t,
    bool solid = true,
    Color? background}) {
  final center = Offset(size.width / 2, size.height / 2);
  final r0 = min(size.width, size.height) / 2 - stroke / 2;
  if (r0 <= 0) return;
  final half = stroke / 2;
  canvas.drawCircle(
      center,
      r0,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track);
  final progress = t.clamp(0.0, 1.0);
  final geometry = SpiralGeometry(stroke);
  // Saturation: laps past the one that reaches the floor would repaint it.
  var room = geometry.saturationLaps(r0).toDouble();
  final scaled = <double>[];
  for (final f in fractions) {
    final v = f.isFinite && f > 0 ? f * progress : 0.0;
    final take = min(v, room);
    scaled.add(take);
    room -= take;
  }
  final total = scaled.fold<double>(0, (a, b) => a + b);
  final pieces = geometry.pieces(scaled);
  if (pieces.isEmpty) return;

  Offset pt(double s, double radius) {
    final a = -pi / 2 + 2 * pi * s;
    return center + Offset(cos(a), sin(a)) * radius;
  }

  // A closed band from lap position [a] to [b], [grow] px wider each side.
  Path band(double a, double b, double grow) {
    final n = max(2, ((b - a) * 360).ceil());
    final path = Path();
    for (var i = 0; i <= n; i++) {
      final s = a + (b - a) * i / n;
      final o = pt(s, geometry.radiusAt(s, r0) + half + grow);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    for (var i = n; i >= 0; i--) {
      final s = a + (b - a) * i / n;
      final o = pt(s, geometry.radiusAt(s, r0) - half - grow);
      path.lineTo(o.dx, o.dy);
    }
    return path..close();
  }

  // A gradient ring fades from 55% to full colour along the bar. That fade is
  // PRE-BLENDED against [background] and everything is drawn fully opaque, so
  // bands and cap discs overlap without compositing twice (a double-alpha
  // patch) and without any subtraction (which cracked the join and removed the
  // 100% end cap). With no [background] the translucent colour is used as is;
  // everything is drawn into one layer with BlendMode.src, so an overlap
  // replaces what is under it instead of compositing a second time (callers
  // that pass no background keep their look, with no denser patch at the caps).
  Color colourAt(SpiralPiece p, double s) {
    final c = colors[p.seg];
    if (solid) return c;
    final a = .55 + .45 * SpiralGeometry.gradientAt(s, total);
    final faded = c.withValues(alpha: c.a * a);
    return background == null ? faded : Color.alphaBlend(faded, background);
  }

  final sepColour = background ?? track;
  final once = background == null;
  final outer = Rect.fromCircle(center: center, radius: r0 + half);
  canvas.save();
  // The outer edge never leaves the lap-0 circle.
  canvas.clipPath(Path()..addOval(outer));
  if (once) canvas.saveLayer(outer.inflate(1), Paint());

  final laps = <int, List<SpiralPiece>>{};
  for (final p in pieces) {
    (laps[p.lap] ??= []).add(p);
  }
  // A cap on a segment end that lands exactly on a lap boundary rounds over
  // the NEXT lap's first band, so it is drawn with that lap.
  final lateDiscs = <int, List<SpiralPiece>>{};
  for (final p in pieces) {
    if (p.capEnd && p.to == p.lap + 1 && laps.containsKey(p.lap + 1)) {
      (lateDiscs[p.lap + 1] ??= []).add(p);
    }
  }
  void disc(SpiralPiece p, double s) => canvas.drawCircle(
      pt(s, geometry.radiusAt(s, r0)),
      half,
      Paint()
        ..color = colourAt(p, s)
        ..blendMode = once ? BlendMode.src : BlendMode.srcOver);

  for (final lap in laps.keys.toList()..sort()) {
    final group = laps[lap]!; // already last segment first
    final bandsFrom = group.map((p) => p.from).reduce(min);
    final bandsTo = group.map((p) => p.to).reduce(max);
    for (final p in group) {
      // A lap cut overlaps the next lap's start slightly: no hairline seam.
      final to = p.capEnd ? p.to : p.to + .003;
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..blendMode = once ? BlendMode.src : BlendMode.srcOver;
      final ua = p.from - p.lap, ub = p.to - p.lap;
      if (solid || ub - ua < 1e-6) {
        paint.color = colourAt(p, (p.from + p.to) / 2);
      } else {
        paint.shader = SweepGradient(
          startAngle: 0,
          endAngle: 2 * pi,
          colors: [colourAt(p, p.from), colourAt(p, p.to)],
          stops: [ua, ub],
          transform: const GradientRotation(-pi / 2),
        ).createShader(Rect.fromCircle(center: center, radius: r0));
      }
      canvas.drawPath(band(p.from, to, 0), paint);
    }
    // One thin line along the upper lap's outer edge, laid after the lap's own
    // bands (so stage joins stay contiguous) and before its caps. It starts
    // where the lap leaves the one below.
    final sepW = spiralSeparatorWidth(stroke);
    if (lap >= 1 && sepW > 0) {
      final from = max(bandsFrom, geometry.separatorFrom(lap)!);
      if (from < bandsTo) {
        final n = max(2, ((bandsTo - from) * 360).ceil());
        final line = Path();
        for (var i = 0; i <= n; i++) {
          final s = from + (bandsTo - from) * i / n;
          final o = pt(s, geometry.radiusAt(s, r0) + half);
          i == 0 ? line.moveTo(o.dx, o.dy) : line.lineTo(o.dx, o.dy);
        }
        canvas.drawPath(
            line,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = sepW
              ..color = sepColour);
      }
    }
    // Caps after every band of the lap, so each segment's round end sits over
    // its clockwise neighbour (and the last one over the first at the seam).
    for (final p in [...?lateDiscs[lap], ...group]) {
      final late = lateDiscs[lap]?.contains(p) ?? false;
      if (p.capEnd && (late || !(lateDiscs[lap + 1]?.contains(p) ?? false))) {
        disc(p, p.to);
      }
      if (p.capStart && !late) disc(p, p.from);
    }
  }
  if (once) canvas.restore();
  canvas.restore();
}
