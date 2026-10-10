// The defining object for each activity family.
//
// A run is a route. A hike is an elevation profile. A swim is a lap ladder.
// Showing all of them the same generic "workout card" is the difference
// between a log and a training tool.
//
// Two families deliberately have NO object here, and their painters were
// deleted rather than left unused: a lift's muscle map was a lookup table
// times the weight the user typed, painted on a body, and a match's court map
// needed indoor positioning nothing in this stack has. Both drew something
// that looked measured and was not. `PowerCurve` went with them — the `power`
// archetype was removed because no power meter is paired and a wrist cannot
// infer watts.
//
// Same two rules as charts.dart: nothing here invents data (the prototype
// seeded a `Random` inside six of these painters so they could be seen with no
// band attached — every one of them now takes what it draws), and anything
// that can receive a long series goes through [minMaxColumns] first.
//
// Positional inputs are normalised 0…1 in both axes, origin top-left. Mapping
// GPS coordinates into that box is the caller's job — it is the only place
// that knows the projection, the bounding box and the aspect correction.

import 'dart:math';

import 'package:flutter/material.dart';

import 'charts.dart';
import 'theme.dart';

/// A route is not a time series, so min/max-per-column does not apply — but a
/// 90-minute ride at 1 Hz is still 5 400 points on a 350 pt canvas. Stride
/// decimation is correct here: the shape is spatial, and dropping intermediate
/// fixes moves the line by well under a pixel. Endpoints are always kept.
List<T> _stride<T>(List<T> pts, double width) {
  final cap = (width * 2).round().clamp(2, pts.length);
  if (pts.length <= cap) return pts;
  final step = pts.length / cap;
  return [
    for (var i = 0; i < cap; i++) pts[(i * step).floor()],
    pts.last,
  ];
}

/// ════════ ROUTE ── running, cycling, walking
///
/// [pts] are normalised 0…1 positions in draw order. [pace] is an optional
/// per-point 0…1 intensity used to colour each segment between [slow] and
/// [fast]; without it the route is drawn in [slow] throughout rather than in
/// an invented gradient.
class RouteMap extends CustomPainter {
  final List<Offset> pts;
  final List<double>? pace;
  final Color slow, fast, pinStart, pinEnd, pinInk;
  final bool pins;

  RouteMap(
    this.pts, {
    this.pace,
    this.slow = C.green,
    this.fast = C.orange,
    this.pinStart = C.green,
    this.pinEnd = C.red,
    this.pinInk = C.white,
    this.pins = true,
  });

  @override
  void paint(Canvas cv, Size s) {
    if (pts.length < 2) return;
    final p = _stride(pts, s.width);
    final v = pace == null ? null : _stride(pace!, s.width);
    // The caller squares the box — one span for both axes plus the cos(lat)
    // correction — so the canvas must not stretch it back. Uniform scale,
    // letterboxed: the shape drawn is the shape run.
    final k = min(s.width, s.height);
    final ox = (s.width - k) / 2, oy = (s.height - k) / 2;
    Offset at(int i) => Offset(ox + p[i].dx * k, oy + p[i].dy * k);

    for (var i = 1; i < p.length; i++) {
      final t = v == null ? 0.0 : (i < v.length ? v[i].clamp(0.0, 1.0) : 0.0);
      // A degenerate bounding box upstream normalises to NaN. Skia would drop
      // the segment silently; skip it here so the pins still land.
      if (!at(i - 1).isFinite || !at(i).isFinite || !t.isFinite) continue;
      cv.drawLine(
        at(i - 1),
        at(i),
        Paint()
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round
          ..color = Color.lerp(slow, fast, t)!,
      );
    }
    if (!pins) return;
    _pin(cv, at(0), pinStart);
    _pin(cv, at(p.length - 1), pinEnd, ring: true);
  }

  /// The finish is a ring and the start a dot, so the two ends differ by
  /// shape and not only by green against red.
  void _pin(Canvas cv, Offset o, Color c, {bool ring = false}) {
    if (!o.isFinite) return;
    cv.drawCircle(o, 7, Paint()..color = pinInk);
    cv.drawCircle(o, 5, Paint()..color = c);
    if (ring) cv.drawCircle(o, 2.5, Paint()..color = pinInk);
  }

  @override
  bool shouldRepaint(covariant RouteMap o) => o.pts != pts || o.pace != pace;
}

/// ════════ ELEVATION ── the defining object for hiking
///
/// [metres] is the altitude series in draw order. The peak marker sits on the
/// real maximum.
class Elevation extends CustomPainter {
  final List<double> metres;
  final Color color, markerInk;

  /// The shared scale — pass the same one `ChartFrame` labels and "800 m" on
  /// the axis is where 800 m actually is. Without it the profile auto-scales
  /// and a 40 m undulation looks like an alpine col.
  final AxisSpec? axis;

  Elevation(this.metres, this.color, {this.markerInk = C.white, this.axis});

  @override
  void paint(Canvas cv, Size s) {
    if (metres.length < 2 || s.width <= 0) return;
    final a = axis;
    final e = a == null ? autoExtent(metres) : null;
    if (a == null && e == null) return;
    // Leave a tenth of the canvas as headroom so the peak marker is not
    // clipped. With an axis the caller owns the headroom, because the labels
    // have to line up with the line.
    double y(double v) => a != null
        ? s.height - a.t(v) * s.height
        : s.height - (v - e!.min) / e.range * s.height * .9;

    Offset? peak;
    for (final pts in minMaxRuns(metres, s.width, y)) {
      for (final o in pts) {
        if (peak == null || o.dy < peak.dy) peak = o;
      }
      if (pts.length == 1) continue; // a fix with dropouts either side
      final area = Path()..moveTo(pts.first.dx, s.height);
      for (final o in pts) {
        area.lineTo(o.dx, o.dy);
      }
      area
        ..lineTo(pts.last.dx, s.height)
        ..close();
      cv.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: .55),
              color.withValues(alpha: .06)
            ],
          ).createShader(Offset.zero & s),
      );

      final line = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        line.lineTo(pts[i].dx, pts[i].dy);
      }
      cv.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
    }

    if (peak == null) return;
    cv.drawCircle(peak, 5, Paint()..color = markerInk);
    cv.drawCircle(peak, 3.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant Elevation o) =>
      o.metres != metres || o.axis != axis;
}

/// ════════ BREATH RING ── the defining object for yoga / meditation
///
/// [t] is the 0…1 breath phase and is owned by the CALLER. That is deliberate:
/// this painter never runs its own ticker, so the screen's single
/// reduced-motion gate stops the animation instead of it looping forever
/// inside a widget nobody can reach.
class BreathRing extends CustomPainter {
  final double t;
  final Color color;

  BreathRing(this.t, this.color);

  @override
  void paint(Canvas cv, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final base = min(s.width, s.height) / 2 - 8;
    if (base <= 0) return;
    cv.drawCircle(
      c,
      base,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: .25),
    );
    final r = base * (.55 + .45 * t.clamp(0, 1));
    cv.drawCircle(c, r, Paint()..color = color.withValues(alpha: .14));
    cv.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant BreathRing o) => o.t != t;
}

/// ════════ INTERVAL LADDER ── the defining object for HIIT
///
/// One entry per round: the work and rest fractions of the round's peak, both
/// 0…1.
class IntervalLadder extends CustomPainter {
  final List<({double work, double rest})> rounds;
  final Color work, rest;

  IntervalLadder(this.rounds, this.work, this.rest);

  /// Two bars per round in two colours — which is which is not guessable.
  List<(String, Color)> get legend => [('Work', work), ('Rest', rest)];

  @override
  void paint(Canvas cv, Size s) {
    if (rounds.isEmpty) return;
    final bw = s.width / rounds.length;
    for (var i = 0; i < rounds.length; i++) {
      final wh = rounds[i].work.clamp(0, 1) * s.height;
      final rh = rounds[i].rest.clamp(0, 1) * s.height;
      // Every round logged as zero makes the caller's own normalisation 0/0.
      // A NaN bar draws nothing and fires no empty state, so skip it visibly.
      if (!wh.isFinite || !rh.isFinite) continue;
      cv.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(i * bw + bw * .12, s.height - wh, bw * .34, wh),
            const Radius.circular(3)),
        Paint()..color = work,
      );
      cv.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(i * bw + bw * .54, s.height - rh, bw * .34, rh),
            const Radius.circular(3)),
        Paint()..color = rest,
      );
    }
  }

  @override
  bool shouldRepaint(covariant IntervalLadder o) => o.rounds != rounds;
}

/// Split / lap pace bar used in tables.
class PaceBar extends StatelessWidget {
  final double frac;
  final Color color;
  const PaceBar(this.frac, this.color, {super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return ClipRRect(
      borderRadius: R.rPill,
      child: LinearProgressIndicator(
        value: frac.clamp(0, 1),
        minHeight: 6,
        backgroundColor: p.track,
        valueColor: AlwaysStoppedAnimation(p.on(color)),
      ),
    );
  }
}
