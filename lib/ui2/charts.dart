// The chart painters.
//
// Two rules run through this file and neither is negotiable.
//
// 1. NOTHING IN HERE INVENTS DATA. The prototype these are ported from seeded
//    a `Random` inside several painters so the design could be seen without a
//    band attached. That is exactly the failure mode the honesty contract
//    exists to prevent, so every painter now takes the series it draws. A
//    painter given an empty series draws nothing and the screen shows a
//    `StatusCard` — it never draws a plausible-looking line.
//
// 2. A CHART WITHOUT AN AXIS IS A SHAPE. Every painter that maps a value to a
//    height takes an optional [AxisSpec]. Given one it uses exactly that
//    mapping — no padding, no auto-extent — so the gridlines and tick labels
//    `ChartFrame` prints are the same scale the curve was drawn against, and
//    two charts side by side are comparable. Without one it falls back to
//    auto-scaling its own min/max, which is fine for a sparkline and a lie
//    anywhere a number is being read off the picture.
//
// 3. A GAP IS A GAP. A sample that is `null` — or non-finite — means no
//    measurement exists at that position, and every painter here breaks its
//    path there rather than drawing a segment across it. A line joining 4 Aug
//    to 11 Aug asserts a week that was never measured, which is a fabrication
//    and not a rendering choice.
//
//    The x position of a sample is its INDEX, so the caller owns the time
//    base. Hand these painters a DENSE series — one entry per day, per minute,
//    per epoch, with `null` in the holes — and x is linear in time for free,
//    which is also what lets `ChartFrame.xLabels` describe a real date range.
//    A ragged "only the days we have a row for" list is what produces the
//    fabrication, and no parameter here can rescue one.
//
// 4. EVERY PAINTER THAT CAN RECEIVE A LONG SERIES DOWNSAMPLES. A night of
//    1 Hz data is ~30 000 points on a ~350 pt wide chart. The old UI handed
//    all 30 000 to `Path`, which is ~85 segments per physical pixel: invisible
//    work, visible jank. [minMaxColumns] reduces to at most two points per
//    horizontal pixel — the column's minimum and maximum, in time order — so
//    the drawn envelope is pixel-identical to the full series and every spike
//    survives. Naive stride decimation would drop them.

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Reduce [d] to at most two points per horizontal pixel: the minimum and the
/// maximum inside each column, emitted in the order they occur so the polyline
/// never travels backwards in time.
///
/// [width] is the paint width in logical pixels. [y] maps a sample value to a
/// canvas y. Series short enough to be drawn honestly (≤ 2 samples per column)
/// come back untouched.
///
/// This is the shared implementation — anything in lib/ui2 that turns a
/// `List<double>` into a path goes through it.
List<Offset> minMaxColumns(
  List<double> d,
  double width,
  double Function(double value) y,
) {
  final n = d.length;
  if (n == 0 || width <= 0) return const [];
  if (n == 1) return [Offset(0, y(d[0]))];

  double x(int i) => i / (n - 1) * width;

  final cols = width.floor().clamp(1, n);
  if (n <= cols * 2) {
    return [for (var i = 0; i < n; i++) Offset(x(i), y(d[i]))];
  }

  final out = <Offset>[];
  for (var c = 0; c < cols; c++) {
    final lo = (c * n / cols).floor();
    final hi = ((c + 1) * n / cols).ceil().clamp(lo + 1, n);
    var loI = lo, hiI = lo;
    for (var i = lo + 1; i < hi; i++) {
      if (d[i] < d[loI]) loI = i;
      if (d[i] > d[hiI]) hiI = i;
    }
    final first = loI < hiI ? loI : hiI;
    final second = loI < hiI ? hiI : loI;
    out.add(Offset(x(first), y(d[first])));
    if (second != first) out.add(Offset(x(second), y(d[second])));
  }
  return out;
}

/// [minMaxColumns] for a series that can have holes.
///
/// Returns one run of points per unbroken stretch of real samples, in order,
/// with x measured across the WHOLE series — so the runs keep their true
/// spacing and the space between them is the gap. `null` and non-finite are
/// both holes.
///
/// A run of one is a sample with no neighbours: a polyline cannot show it, so
/// the painter draws a dot. Anything in lib/ui2 that draws a series which may
/// be missing days goes through this rather than through [minMaxColumns].
List<List<Offset>> minMaxRuns(
  List<double?> d,
  double width,
  double Function(double value) y,
) {
  final n = d.length;
  if (n == 0 || width <= 0) return const [];
  bool real(int i) {
    final v = d[i];
    return v != null && v.isFinite;
  }

  final runs = <List<Offset>>[];
  var i = 0;
  while (i < n) {
    if (!real(i)) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && real(j)) {
      j++;
    }
    final x0 = n == 1 ? 0.0 : i / (n - 1) * width;
    if (j - i == 1) {
      runs.add([Offset(x0, y(d[i]!))]);
    } else {
      // The run's own width is its share of the whole, so column x inside the
      // run and index x across the series are the same number.
      final w = (j - i - 1) / (n - 1) * width;
      final seg = [for (var k = i; k < j; k++) d[k]!];
      runs.add([
        for (final o in minMaxColumns(seg, w, y)) Offset(x0 + o.dx, o.dy),
      ]);
    }
    i = j;
  }
  return runs;
}

/// Column maxima only — for bar charts, where a column is one bar and the
/// minimum is the baseline. Same contract as [minMaxColumns].
///
/// Ceiling: this is a PEAK, which is right for a rate (heart rate, pace) and
/// wrong for anything additive. Ninety days of TRIMP reduced to thirty columns
/// shows the hardest day in each column, not the column's load. Nothing plots
/// an additive series long enough to be reduced today; add a sum mode before
/// anything does.
List<double> maxColumns(List<double> d, int cols) {
  final n = d.length;
  if (n == 0 || cols <= 0 || n <= cols) return d;
  return [
    for (var c = 0; c < cols; c++)
      d
          .sublist((c * n / cols).floor(),
              ((c + 1) * n / cols).ceil().clamp((c * n / cols).floor() + 1, n))
          .reduce(max),
  ];
}

/// ── THE Y AXIS ────────────────────────────────────────────────────────────
///
/// One object, shared by the painter that draws the curve and the [ChartFrame]
/// that prints the numbers beside it. Passing it to only one of the two is the
/// bug it exists to prevent.
///
/// [format] is what makes a duration axis print `7h 30m` and a heart-rate axis
/// print `56` without either of them needing a special painter — see [axisInt],
/// [axisHm] and [axisFixed] for the three that cover almost everything.
class AxisSpec {
  final double min, max;

  /// Gridline count, INCLUDING both ends. 3 → min, midpoint, max.
  final int ticks;

  final String Function(double) format;

  const AxisSpec({
    required this.min,
    required this.max,
    this.ticks = 3,
    required this.format,
  });

  /// Where [v] sits on the axis: 0 at [min], 1 at [max]. Clamped, so a sample
  /// outside the axis lands on the edge instead of off the canvas — the axis
  /// the user is reading stays the axis that was drawn.
  double t(double v) =>
      max - min <= 0 ? 0 : ((v - min) / (max - min)).clamp(0.0, 1.0);

  /// Tick values top-first, so the list is in the order the labels are stacked.
  List<double> get tickValues {
    final n = ticks < 2 ? 2 : ticks;
    return [for (var i = 0; i < n; i++) max - (max - min) * i / (n - 1)];
  }

  /// An axis over real data, rounded out to a step a human would choose —
  /// 0/25/50, not 3.7/28.4/53.1. Returns null for an empty series, which is the
  /// signal to render [ChartFrame]'s empty state rather than an empty axis.
  ///
  /// This is here so that three screens plotting the same metric cannot each
  /// invent a slightly different scale.
  static AxisSpec? of(
    Iterable<double> d, {
    int ticks = 3,
    String Function(double) format = axisInt,
    double? floor,
    double? ceil,
    double? step,
  }) {
    // Non-finite in, no axis out. A NaN silently loses every comparison below,
    // so it would leave the axis looking reasonable while the sample it came
    // from punches an invisible hole in the line; an infinity used to spin the
    // step loop forever, which is a frozen UI on the main isolate.
    final v = [for (final x in d) if (x.isFinite) x];
    if (v.isEmpty) return null;
    final n = ticks < 2 ? 2 : ticks;
    // NB: `min`/`max` are fields on this class, so dart:math's are shadowed
    // here — reduce explicitly rather than silently passing a double.
    var lo = v.reduce((a, b) => a < b ? a : b),
        hi = v.reduce((a, b) => a > b ? a : b);
    // [floor] / [ceil] EXTEND the axis to include a meaningful anchor — pass
    // `floor: 0` for anything where zero is the real baseline. They never crop
    // the data.
    if (floor != null && floor.isFinite && floor < lo) lo = floor;
    if (ceil != null && ceil.isFinite && ceil > hi) hi = ceil;
    if (hi - lo < 1e-9) {
      if (hi.abs() < 1e-9) {
        // All zero. A symmetric pad would put negative steps and negative
        // TRIMP on the gridlines; zero belongs on the floor.
        lo = 0;
        hi = 1;
      } else {
        // A flat series still needs a readable band around it, or the line
        // sits on the floor of the chart and reads as "lowest it has ever
        // been". [autoExtent] pads by the same tenth.
        final pad = hi.abs() * .1;
        lo -= pad;
        hi += pad;
      }
    }
    // [step] overrides the rounding for axes whose "nice" numbers are not
    // powers of ten: minutes want 60/120/240, not 250. The rest of the maths
    // is identical, so an override cannot produce uneven ticks.
    var s = step != null && step > 0 && step.isFinite
        ? step
        : _niceStep((hi - lo) / (n - 1));
    // A gridline has to sit on a number its own label can say. `axisInt`
    // cannot print 55.5, so a .5 step over 55…56 drew two gridlines both
    // labelled 56 with the upper one half a step off the value it claimed.
    // Climb the ladder until the step is a whole number of what the format
    // resolves; an unknown format asks for nothing and gets the raw step.
    final q = _labelStep(format);
    for (var i = 0; i < 8 && q > 0 && !_multiple(s, q); i++) {
      s = _niceStep(s * 1.0001);
    }
    final base = (lo / s).floorToDouble() * s;
    // Grow to cover the data in whole steps. Solved, not looped: with an
    // infinity upstream the loop this replaces never returned.
    var grow = ((hi - base) / s - 1e-9).ceil();
    // …and in whole TICKS, not just whole steps: 3 steps across 3 gridlines
    // puts the middle one at 1.5 steps, which is the same off-grid label
    // again (52…57 stepped by 2.5 labelled its middle line 54 at 53.75).
    final gap = n - 1;
    if (grow < gap) grow = gap;
    grow = ((grow + gap - 1) ~/ gap) * gap;
    return AxisSpec(
        min: base, max: base + grow * s, ticks: n, format: format);
  }

  static bool _multiple(double a, double b) =>
      ((a / b) - (a / b).roundToDouble()).abs() < 1e-9;

  /// The finest gap a label format can state, or 0 if we do not know. Anything
  /// finer prints a gridline the label does not name.
  static double _labelStep(String Function(double) f) =>
      f == axisInt || f == axisHm
          ? 1
          : (f == axisFixed || f == axisFixedOrInt ? .1 : 0);

  /// 1 · 2 · 2.5 · 5 · 10 × a power of ten — the steps that produce labels
  /// people read without thinking.
  static double _niceStep(double raw) {
    if (raw <= 0 || !raw.isFinite) return 1;
    final mag = pow(10, (log(raw) / ln10).floor()).toDouble();
    for (final m in const [1.0, 2.0, 2.5, 5.0]) {
      if (raw <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  @override
  bool operator ==(Object other) =>
      other is AxisSpec &&
      other.min == min &&
      other.max == max &&
      other.ticks == ticks &&
      other.format == format;

  @override
  int get hashCode => Object.hash(min, max, ticks, format);
}

/// `56`, `-3`. The default.
String axisInt(double v) => v.round().toString();

/// `7h 30m`, `45m`, `8h` — for an axis measured in MINUTES.
String axisHm(double minutes) {
  final t = minutes.round(), h = t ~/ 60, m = t % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// One decimal — skin temperature, kilograms, pace.
String axisFixed(double v) => v.toStringAsFixed(1);

/// [axisInt] when the number is whole enough to be read that way, [axisFixed]
/// otherwise. For prose rather than for a gridline: a spoken summary has no
/// caller-chosen format to borrow when the chart was drawn without an axis,
/// and "zero point three degrees" must not become "zero".
String axisFixedOrInt(double v) =>
    (v - v.roundToDouble()).abs() < .05 ? axisInt(v) : axisFixed(v);

/// Smoothing is only honest below this many points. Above it the polyline is
/// already sub-pixel and a cubic through min/max pairs invents overshoot that
/// is not in the data.
const _kSmoothMax = 120;

/// The axis-less fallback, shared by every painter that has one so there is
/// exactly one of it. Null when nothing finite is in the series.
///
/// It agrees with [AxisSpec.of] on the two cases that used to differ: a flat
/// series gets a band AROUND it — a stable week is stable, not "lowest ever
/// recorded" pinned to the floor of the card — and a flat ZERO series keeps
/// zero on the floor, where it belongs.
({double min, double range})? autoExtent(List<double?> d) {
  double? mn, mx;
  for (final v in d) {
    if (v == null || !v.isFinite) continue;
    if (mn == null || v < mn) mn = v;
    if (mx == null || v > mx) mx = v;
  }
  if (mn == null) return null;
  if ((mx! - mn).abs() >= 1e-6) return (min: mn, range: mx - mn);
  if (mn.abs() < 1e-9) return (min: 0.0, range: 1.0);
  final pad = mn.abs() * .1;
  return (min: mn - pad, range: pad * 2);
}

/// One polyline through [pts]. Smoothing is only honest below [_kSmoothMax] —
/// above it a cubic through min/max pairs invents overshoot.
Path _polyline(List<Offset> pts, {required bool smooth}) {
  final p = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    if (smooth) {
      final m = (a.dx + b.dx) / 2;
      p.cubicTo(m, a.dy, m, b.dy, b.dx, b.dy);
    } else {
      p.lineTo(b.dx, b.dy);
    }
  }
  return p;
}

/// The trend line. Sparkline in a row, hero curve in a card.
///
/// [d] is DENSE and index-ordered: one entry per position on the time base,
/// `null` where nothing was measured. Gaps break the line — see rule 3 at the
/// top of the file.
///
/// [t] is a 0…1 draw-in progress — pass `animate(context, t)` so reduced
/// motion lands on a fully drawn chart instead of a partial one.
class LineChart extends CustomPainter {
  final List<double?> d;
  final Color color;
  final bool dots;
  final double t;

  /// A filled area reads as a quantity measured from a baseline, so it is only
  /// drawn when there is an [axis] to say what that baseline is. Asked for
  /// without one it is dropped: the fallback anchors to the series minimum,
  /// which turns a 58→60 bpm week into a full-card mountain — the banned
  /// truncated-axis form with the truncation hidden.
  final bool fill;

  /// [dotInk] is the knockout at the centre of the head dot; pass the surface
  /// the chart sits on. Defaults to nothing, which draws a solid dot.
  final Color? dotInk;

  /// The shared scale. Given one, the curve is drawn edge to edge against
  /// exactly the axis the frame labels — no 14% breathing room, because a
  /// gridline that says 60 has to be where 60 is. Without one the chart
  /// auto-scales, which is correct for a sparkline and nothing else.
  final AxisSpec? axis;

  /// The selected slot as a 0…1 position across the chart. Null means the
  /// chart is not selected and no cursor is drawn.
  final double? selectedX;

  LineChart(this.d, this.color,
      {bool fill = true,
      this.dots = false,
      this.t = 1,
      this.dotInk,
      this.axis,
      this.selectedX})
      : fill = fill && axis != null;

  @override
  void paint(Canvas cv, Size s) {
    if (d.length < 2 || s.width <= 0) return;
    final a = axis;
    final e = a == null ? autoExtent(d) : null;
    if (a == null && e == null) return; // nothing finite to draw
    final pad = s.height * .14;
    double y(double v) => a != null
        ? s.height - a.t(v) * s.height
        : s.height - pad - (v - e!.min) / e.range * (s.height - pad * 2);

    final runs = minMaxRuns(d, s.width, y);
    var left = runs.fold<int>(0, (n, r) => n + r.length);
    left = (left * t.clamp(0, 1)).round();
    final smooth = d.length <= _kSmoothMax;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    Offset? head;
    for (final run in runs) {
      if (left <= 0) break;
      final pts = run.length <= left ? run : run.sublist(0, left);
      left -= pts.length;
      head = pts.last;
      if (pts.length == 1) {
        // A measurement with gaps on both sides. A polyline cannot show it and
        // dropping it would make an every-other-day series draw nothing.
        cv.drawCircle(pts.first, 1.8, Paint()..color = color);
        continue;
      }
      final path = _polyline(pts, smooth: smooth);
      if (fill) {
        final f = Path.from(path)
          ..lineTo(pts.last.dx, s.height)
          ..lineTo(pts.first.dx, s.height)
          ..close();
        cv.drawPath(
          f,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: .24),
                color.withValues(alpha: 0)
              ],
            ).createShader(Offset.zero & s),
        );
      }
      cv.drawPath(path, stroke);
    }

    final x = selectedX?.clamp(0.0, 1.0);
    if (x != null) {
      cv.drawLine(
        Offset(s.width * x, 0),
        Offset(s.width * x, s.height),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: .72),
      );
    }

    if (dots && head != null) {
      cv.drawCircle(head, 4.5, Paint()..color = color);
      // The prototype knocked this out in hard white, which is a hole in a
      // dark card. It knocks out the surface it is drawn on.
      if (dotInk != null) cv.drawCircle(head, 2, Paint()..color = dotInk!);
    }
  }

  @override
  bool shouldRepaint(covariant LineChart o) =>
      o.d != d || o.t != t || o.color != color || o.axis != axis ||
      o.fill != fill || o.selectedX != selectedX;
}

/// Discrete buckets — days of a week, minutes in a zone.
///
/// [d] is dense like [LineChart.d]: a `null` bucket was never measured and no
/// bar is drawn for it, which is a hole in the row rather than a zero.
class Bars extends CustomPainter {
  final List<double?> d;
  final Color color;
  final int highlight;
  final double t;

  /// The shared scale, measured from [AxisSpec.min] as the baseline. Without
  /// it every bar chart normalises to its OWN tallest bar, so a 40-minute week
  /// and a 400-minute week draw the identical picture.
  final AxisSpec? axis;

  // No track colour: nothing is drawn behind a bar. A missing bucket is a gap
  // in the row and a real zero gets the 2 pt floor below, which is the whole
  // absence channel.
  Bars(this.d, this.color, {this.highlight = -1, this.t = 1, this.axis});

  /// [maxColumns] over a series with holes: a column of nothing stays nothing.
  static List<double?> _columns(List<double?> d, int cols) {
    final n = d.length;
    if (cols <= 0 || n <= cols) return d;
    return [
      for (var c = 0; c < cols; c++)
        () {
          final lo = (c * n / cols).floor();
          final hi = ((c + 1) * n / cols).ceil().clamp(lo + 1, n);
          double? m;
          for (var i = lo; i < hi; i++) {
            final v = d[i];
            if (v == null || !v.isFinite) continue;
            if (m == null || v > m) m = v;
          }
          return m;
        }(),
    ];
  }

  @override
  void paint(Canvas cv, Size s) {
    if (d.isEmpty || s.width <= 0) return;
    // A bar narrower than ~2pt is not a bar. Aggregate to what fits.
    final v = _columns(d, (s.width / 3).floor().clamp(1, d.length));
    final a = axis;
    // A bar is drawn from the canvas floor, so its baseline is already zero —
    // the auto-scale only needs the tallest bar, and [autoExtent]'s centred
    // band would be the wrong shape here.
    var mx = 0.0;
    if (a == null) {
      for (final x in v) {
        if (x != null && x.isFinite && x > mx) mx = x;
      }
      if (mx <= 0) return;
    }
    final bw = s.width / v.length;
    // An aggregated axis can no longer address the caller's index, so the
    // highlight is dropped rather than pointed at the wrong bar.
    final hl = v.length == d.length ? highlight : -1;
    for (var i = 0; i < v.length; i++) {
      final value = v[i];
      if (value == null || !value.isFinite) continue;
      final h = (a == null ? value / mx : a.t(value)) * s.height * t.clamp(0, 1);
      if (!h.isFinite) continue;
      // A 2pt floor so a near-zero bar is still visible — grown DOWN from its
      // own top, or the bar hangs below the canvas floor and a zero and a
      // tiny value draw identically.
      final bh = max(h, 2.0);
      cv.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * bw + bw * .2, s.height - bh, bw * .6, bh),
          const Radius.circular(3),
        ),
        Paint()
          ..color =
              (hl < 0 || i == hl) ? color : color.withValues(alpha: .35),
      );
    }
  }

  @override
  bool shouldRepaint(covariant Bars o) =>
      o.d != d || o.t != t || o.highlight != highlight || o.axis != axis;
}

/// The score dial. One value, one arc.
class Ring extends CustomPainter {
  final double v;
  final Color color, track;
  final double stroke, t;

  /// SOLID draws the arc in one flat colour. The fade is deliberately kept for
  /// the states that are not a finished measurement: a ring that is still
  /// filling reads as filling partly BECAUSE its arc is softer than a measured
  /// one. Brightening everything would collapse "this is real", "this is still
  /// calibrating" and "this is missing" into one look.
  final bool solid;

  Ring(this.v, this.color, this.track,
      {this.stroke = 10, this.t = 1, this.solid = false});

  @override
  void paint(Canvas cv, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final r = min(s.width, s.height) / 2 - stroke / 2;
    if (r <= 0) return;
    cv.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    final sweep = 2 * pi * v.clamp(0, 1) * t.clamp(0, 1);
    if (sweep <= 0) return;
    cv.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = solid ? color : const Color(0x00000000)
        ..shader = solid
            ? null
            : SweepGradient(
                startAngle: -pi / 2,
                endAngle: 3 * pi / 2,
                colors: [color.withValues(alpha: .55), color],
                transform: const GradientRotation(-pi / 2),
              ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
  }

  @override
  bool shouldRepaint(covariant Ring o) =>
      o.v != v || o.t != t || o.solid != solid || o.color != color;
}

/// A ring made of discrete dashes rather than a continuous arc — for a value
/// that is still filling (a baseline calibrating night by night), so "not
/// solid yet" is literally true of the shape, not just a softer tint of the
/// same arc [Ring] draws for a finished measurement.
class DashedRing extends CustomPainter {
  final double v;
  final Color color, track;
  final double stroke;
  final int segments;

  DashedRing(this.v, this.color, this.track,
      {this.stroke = 10, this.segments = 24});

  @override
  void paint(Canvas cv, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final r = min(s.width, s.height) / 2 - stroke / 2;
    if (r <= 0) return;
    final filled = (segments * v.clamp(0, 1)).round();
    final gap = 2 * pi / segments;
    // Wide gaps between dashes so this reads as discrete beads, not a
    // dashed-but-still-continuous arc.
    final dashSweep = gap * 0.3;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < segments; i++) {
      cv.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -pi / 2 + gap * i,
        dashSweep,
        false,
        paint..color = i < filled ? color : track,
      );
    }
  }

  @override
  bool shouldRepaint(covariant DashedRing o) =>
      o.v != v ||
      o.color != color ||
      o.track != track ||
      o.segments != segments ||
      o.stroke != stroke;
}

/// The small flat ring used in macro/nutrient clusters.
class MacroRing extends CustomPainter {
  final double v;
  final Color color, track;

  MacroRing(this.v, this.color, this.track);

  @override
  void paint(Canvas cv, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final r = min(s.width, s.height) / 2 - 4;
    if (r <= 0) return;
    cv.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = track,
    );
    final sweep = 2 * pi * v.clamp(0, 1);
    if (sweep <= 0) return;
    cv.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant MacroRing o) => o.v != v;
}

/// The four sleep lanes, top to bottom: awake, REM, light, deep.
enum SleepStage { awake, rem, light, deep }

extension SleepStageX on SleepStage {
  /// The name that goes in the legend. Four lanes of four colours with nothing
  /// naming them is the single least readable chart in the app.
  String get label => const ['Awake', 'REM', 'Light', 'Deep'][index];
}

/// Hypnogram — conventional lanes, minimum 2pt wide so a 30 s arousal in an
/// eight-hour night is still a visible mark rather than a rounding error.
///
/// [stages] is one entry per epoch, in order. It comes from the stager; this
/// painter has no opinion about what a night looks like.
class Hypnogram extends CustomPainter {
  final List<SleepStage> stages;
  final double t;

  /// The surface's palette. A painter is the one place in this library that
  /// used to spend RAW pigment: `C.sky` measures **1.67:1** on a white card, so
  /// the Light lane — the lane most of a night is spent in — was very nearly
  /// invisible in the light theme. A lane's colour IS the information, so it
  /// goes through the same solver every label does.
  final P p;

  Hypnogram(this.stages, this.p, {this.t = 1});

  static const pigment = <SleepStage, Color>{
    SleepStage.awake: C.orange,
    SleepStage.rem: C.teal,
    SleepStage.light: C.sky,
    SleepStage.deep: C.blue,
  };

  /// The lane colours as drawn. Four lanes at four different heights, so hue is
  /// never the only channel here — y position already carries the stage.
  static Map<SleepStage, Color> cols(P p) =>
      {for (final e in pigment.entries) e.key: p.on(e.value)};

  /// Hand straight to `ChartFrame.legend`. Derived from [cols] rather than
  /// retyped, so a lane can never be recoloured without its key following, and
  /// the swatch is the mark's real colour rather than the pigment behind it.
  static List<(String, Color)> legend(P p) =>
      [for (final s in SleepStage.values) (s.label, p.on(pigment[s]!))];

  /// One column per drawable slot, with a STATED precedence: awake wins.
  ///
  /// An 8 h night at 1 Hz is 28 800 epochs on a ~350 pt chart. Drawn one rect
  /// per epoch they overlap and the last one drawn wins, so which stage a
  /// pixel shows is an accident of draw order — a 30 s arousal can erase the
  /// deep block beside it, or the deep block can erase the arousal. Awake is
  /// the shortest thing in the record and the one worth keeping, so it takes
  /// the column; otherwise the column shows the stage that occupied most of
  /// it.
  static List<SleepStage> columns(List<SleepStage> st, int cols) {
    final n = st.length;
    if (cols <= 0 || n <= cols) return st;
    return [
      for (var c = 0; c < cols; c++)
        _dominant(st, (c * n / cols).floor(),
            ((c + 1) * n / cols).ceil().clamp((c * n / cols).floor() + 1, n)),
    ];
  }

  static SleepStage _dominant(List<SleepStage> st, int lo, int hi) {
    final seen = List<int>.filled(SleepStage.values.length, 0);
    for (var i = lo; i < hi; i++) {
      if (st[i] == SleepStage.awake) return SleepStage.awake;
      seen[st[i].index]++;
    }
    var best = 0;
    for (var i = 1; i < seen.length; i++) {
      if (seen[i] > seen[best]) best = i;
    }
    return SleepStage.values[best];
  }

  @override
  void paint(Canvas cv, Size s) {
    if (stages.isEmpty || s.width <= 0) return;
    // Two per column would overlap at the 2pt visibility floor below.
    final v = columns(stages, (s.width / 2).floor());
    final lane = s.height / 4, w = s.width / v.length;
    final n = (v.length * t.clamp(0, 1)).round().clamp(1, v.length);
    final ink = cols(p);

    // Drawn as RUNS, not columns. One rect per column left a 0.8 pt gap between
    // every pair of neighbours, so a solid two-hour stretch of light sleep came
    // out as a picket fence and a continuous night read as fragmented data.
    // A run is one rect however long it is, and a step joins it to the next —
    // which is what a hypnogram is: a line that moves between four levels, not
    // a scatter of blocks.
    final step = Paint()
      ..color = p.line
      ..strokeWidth = 1;
    var i = 0;
    while (i < n) {
      final st = v[i];
      var j = i;
      while (j + 1 < n && v[j + 1] == st) {
        j++;
      }
      final x0 = i * w, x1 = (j + 1) * w;
      final y = st.index * lane + 2, h = lane - 5;
      cv.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x0, y, max(x1 - x0 - .8, 2), h),
          const Radius.circular(2),
        ),
        Paint()..color = ink[st]!,
      );
      // The riser to the next level. Faint on purpose: it carries continuity,
      // and the lanes already carry the stage.
      if (j + 1 < n) {
        final next = v[j + 1];
        final a = y + h / 2, b = next.index * lane + 2 + h / 2;
        cv.drawLine(Offset(x1, min(a, b)), Offset(x1, max(a, b)), step);
      }
      i = j + 1;
    }
  }

  @override
  bool shouldRepaint(covariant Hypnogram o) =>
      o.t != t || o.stages != stages || o.p.dark != p.dark;
}

/// Time-in-zone as one stacked bar. [z] is five fractions summing to ≤ 1.
class ZoneBar extends CustomPainter {
  final List<double> z;
  final P p;

  ZoneBar(this.z, this.p);

  static const pigment = [C.blueSoft, C.blue, C.green, C.orange, C.red];

  /// The bands as drawn — solved against the surface, like every other mark.
  /// `blueSoft` measured 1.80:1 on a white card, so zone 1 was a pale smear.
  static List<Color> cols(P p) => [for (final c in pigment) p.on(c)];

  /// Five bands of colour mean nothing without their numbers. Derived from
  /// [cols] for the same reason [Hypnogram.legend] is.
  static List<(String, Color)> legend(P p) =>
      [for (var i = 0; i < pigment.length; i++) ('Zone ${i + 1}', p.on(pigment[i]))];

  /// How short zone 1 is drawn relative to zone 5.
  ///
  /// Solving each band against the CARD does nothing for zone 4 against zone 5:
  /// those measure 1.34:1 against EACH OTHER, and unlike [Hypnogram] a stacked
  /// bar has no lane position to separate them with. So the ordinal gets a
  /// second channel — the bands step up in height toward the hard end, which is
  /// the thing the colour was trying to say anyway.
  static const _floor = .6;

  @override
  void paint(Canvas cv, Size s) {
    var x = 0.0;
    final ink = cols(p);
    final n = pigment.length;
    for (var i = 0; i < z.length && i < n; i++) {
      final w = z[i] * s.width;
      if (!w.isFinite) continue;
      // Advance first: skipping the draw must not also skip the band's width,
      // or every later band shifts left by it.
      x += w;
      if (w <= .5) continue;
      final h = s.height * (_floor + (1 - _floor) * i / (n - 1));
      cv.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - w, s.height - h, max(w - 2, 1), h),
          const Radius.circular(3),
        ),
        Paint()..color = ink[i],
      );
    }
  }

  @override
  bool shouldRepaint(covariant ZoneBar o) => o.z != z || o.p.dark != p.dark;
}

/// Actogram — hour of day (rows) × date (columns). The circadian view.
///
/// [days] is one entry per day, each a 24-slot list of 0…1 intensity, or null
/// where nothing was recorded. A null day paints nothing — a gap in the record
/// reads as a gap, not as a night of no sleep.
///
/// Slot 0 is the BOTTOM row: `ChartFrame` stacks its tick labels top-first
/// from `AxisSpec.max`, so hour has to increase upwards or the labels are the
/// mirror image of the rows. It used to read correctly only because the
/// noon-anchored formatter the one caller passes is symmetric at three ticks —
/// at five it printed 6 AM against the 6 PM row.
class Actogram extends CustomPainter {
  final List<List<double>?> days;
  final Color color;

  Actogram(this.days, this.color);

  @override
  void paint(Canvas cv, Size s) {
    if (days.isEmpty) return;
    final cw = s.width / days.length, ch = s.height / 24;
    for (var d = 0; d < days.length; d++) {
      final day = days[d];
      if (day == null) continue;
      for (var h = 0; h < 24 && h < day.length; h++) {
        final v = day[h].clamp(0.0, 1.0);
        if (!(v > 0)) continue; // NaN fails this too, which is the point
        cv.drawRect(
          Rect.fromLTWH(d * cw, s.height - (h + 1) * ch, cw + .4, ch),
          Paint()..color = color.withValues(alpha: .22 + v * .68),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant Actogram o) => o.days != days;
}

/// Column-major grid. [weeks] is one list per COLUMN — seven days of a
/// calendar week for the rhythm strip, one value per domain for the month
/// grid; null = no data, which paints the empty track rather than a low value.
///
/// The row count is the longest column rather than a fixed seven. It was
/// seven, which is the only thing that stopped this painter from being the
/// three-row month grid as well: same cells, same absence rule, same file. A
/// column of seven lays out exactly as it always did.
class HeatMap extends CustomPainter {
  final List<List<double?>> weeks;
  final Color color, track;

  HeatMap(this.weeks, this.color, this.track);

  @override
  void paint(Canvas cv, Size s) {
    if (weeks.isEmpty) return;
    var rows = 0;
    for (final w in weeks) {
      if (w.length > rows) rows = w.length;
    }
    if (rows == 0) return;
    final cw = s.width / weeks.length, ch = s.height / rows;
    for (var w = 0; w < weeks.length; w++) {
      for (var d = 0; d < weeks[w].length; d++) {
        final v = weeks[w][d];
        // Absence is an OUTLINE, not a fainter fill. Drawn as a filled track
        // the two measured 1.00:1 against the faintest real value — a day that
        // was measured and a day that was not were literally the same colour,
        // which is an honesty bug wearing a contrast bug's clothes. A shape
        // difference survives any palette and any colour vision.
        final empty = v == null;
        cv.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * cw + 1, d * ch + 1, cw - 2.5, ch - 2.5),
            const Radius.circular(2),
          ),
          empty
              ? (Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1
                ..color = track)
              : (Paint()
                ..color =
                    color.withValues(alpha: .3 + v.clamp(0.0, 1.0) * .62)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant HeatMap o) => o.weeks != weeks;
}

/// Power spectral density — the LF/HF plot behind HRV. [psd] is the computed
/// spectrum; [split] is the fraction of the x-axis where LF becomes HF.
class Spectrum extends CustomPainter {
  final List<double> psd;
  final double split;
  final Color lf, hf;

  Spectrum(this.psd, {this.split = .28, this.lf = C.blue, this.hf = C.purple});

  /// Two colours that mean two different bands of a frequency axis — the one
  /// chart in here nobody reads correctly without a key.
  List<(String, Color)> get legend => [('LF power', lf), ('HF power', hf)];

  @override
  void paint(Canvas cv, Size s) {
    if (psd.isEmpty) return;
    final v = maxColumns(psd, (s.width / 3).floor().clamp(1, psd.length));
    final mx = v.reduce(max);
    if (mx <= 0) return;
    final bw = s.width / v.length;
    for (var i = 0; i < v.length; i++) {
      final f = i / v.length;
      final h = v[i] / mx * s.height;
      cv.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * bw, s.height - h, max(bw - .8, 1), h),
          const Radius.circular(1),
        ),
        Paint()..color = (f < split ? lf : hf).withValues(alpha: .85),
      );
    }
  }

  @override
  bool shouldRepaint(covariant Spectrum o) => o.psd != psd;
}

/// Poincaré — every beat interval plotted against the one before it.
///
/// THE ONLY SCATTER IN THIS LIBRARY, and the only reason a new painter was
/// added: nothing here maps two values of the SAME unit onto two axes, and
/// every existing painter puts index on x. SD1 and SD2 are the two axes of
/// this cloud, and the app computed both and printed them as two integers.
///
/// [nn] is the cleaned NN series in ms, in beat order — point i is
/// `(nn[i], nn[i+1])`. A gap in the beats is NOT representable here (a scatter
/// has no path to break), so the caller must hand over a series that was
/// artifact-corrected as one window and say how much of it survived.
///
/// SQUARE, ALWAYS. The whole grammar of this plot is the 45° identity line —
/// distance across it is beat-to-beat change, distance along it is drift — so
/// x and y take the SAME [axis] and the plot is the largest square that fits,
/// centred. Stretching it to a wide box would tilt the identity line and every
/// visual reading off it would be wrong. It draws its own gridlines at the
/// axis ticks for the same reason: `ChartFrame` rules the full width, and the
/// square is narrower than that.
class Poincare extends CustomPainter {
  final List<double> nn;
  final Color color;

  /// Shared by both axes. `ChartFrame`'s tick labels down the left therefore
  /// read across the bottom too, which is what the caller's footnote says.
  final AxisSpec axis;

  /// The gridline / identity-line ink — pass `p.line`.
  final Color grid;

  Poincare(this.nn, this.color, {required this.axis, required this.grid});

  @override
  void paint(Canvas cv, Size s) {
    if (nn.length < 2) return;
    final side = min(s.width, s.height);
    if (side <= 0) return;
    final ox = (s.width - side) / 2, oy = (s.height - side) / 2;

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = grid;
    for (final v in axis.tickValues) {
      final t = axis.t(v);
      final y = oy + side - t * side, x = ox + t * side;
      cv.drawLine(Offset(ox, y), Offset(ox + side, y), line);
      cv.drawLine(Offset(x, oy), Offset(x, oy + side), line);
    }
    // The identity line. Every reading of this plot is taken relative to it.
    cv.drawLine(Offset(ox, oy + side), Offset(ox + side, oy), line);

    // One draw call for the whole cloud. Thirty thousand `drawCircle`s is a
    // dropped frame; `drawRawPoints` is a single vertex buffer.
    final pts = Float32List((nn.length - 1) * 2);
    var n = 0;
    for (var i = 0; i + 1 < nn.length; i++) {
      final a = nn[i], b = nn[i + 1];
      if (!a.isFinite || !b.isFinite) continue;
      pts[n++] = ox + axis.t(a) * side;
      pts[n++] = oy + side - axis.t(b) * side;
    }
    if (n == 0) return;
    cv.drawRawPoints(
      PointMode.points,
      n == pts.length ? pts : Float32List.sublistView(pts, 0, n),
      Paint()
        // Semi-transparent so DENSITY is visible: the core of a night's cloud
        // is thousands of overlapping points, and drawn opaque it is a flat
        // blob with no interior. The caller passes an already-solved ink.
        //
        // ponytail: fixed alpha and point size, tuned for a night (17k–30k
        // intervals on the owner's real records). A whole-DAY window would
        // saturate the core further; bin to a density grid before drawing one,
        // rather than tapering the alpha and calling it a fix.
        ..color = color.withValues(alpha: .28)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant Poincare o) =>
      o.nn != nn || o.color != color || o.axis != axis || o.grid != grid;
}

/// Several signals stacked over one shared night timeline — HR, movement,
/// SpO₂ relative, whatever the screen has. Each lane is independently scaled,
/// because they are different units and a shared axis would be a lie.
///
/// ONE TIME BASE, and the painter enforces it: every lane must be the same
/// length, index i being the same instant in all of them, `null` where a lane
/// has nothing there. A lane of a different length is not drawn.
///
/// That is the whole premise of stacking — a vertical slice is one moment.
/// Spreading each lane across the full width by its own sample count instead
/// put a 3 a.m. HRV dip under a 2:20 a.m. HR spike, silently, whenever the
/// lanes had different rates or different coverage. Resample every lane onto
/// the night's grid before handing it over; nothing here can recover the
/// mapping afterwards.
class NightStack extends CustomPainter {
  final List<List<double?>> series;
  final List<Color> colors;

  /// One axis per lane, in the same order as [series]; a null entry (or a
  /// short list) leaves that lane auto-scaled. Different units genuinely need
  /// different axes — what they must not do is each invent a new one every
  /// time the data shifts, which is what makes a lane look dramatic on a quiet
  /// night. Pin the ones the screen labels.
  final List<AxisSpec?>? axes;

  NightStack(this.series, this.colors, {this.axes});

  @override
  void paint(Canvas cv, Size s) {
    if (series.isEmpty || s.width <= 0) return;
    // The grid is the longest lane. Anything else is on a different clock.
    final span = series.fold<int>(0, (n, l) => l.length > n ? l.length : n);
    final h = s.height / series.length;
    for (var k = 0; k < series.length; k++) {
      final d = series[k];
      if (d.length != span || d.length < 2) continue;
      final a = (axes != null && k < axes!.length) ? axes![k] : null;
      final e = a == null ? autoExtent(d) : null;
      if (a == null && e == null) continue;
      double y(double v) => a != null
          ? k * h + h - 6 - a.t(v) * (h - 14)
          : k * h + h - 6 - (v - e!.min) / e.range * (h - 14);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..color = colors[k % colors.length];
      for (final run in minMaxRuns(d, s.width, y)) {
        if (run.length == 1) {
          cv.drawCircle(run.first, 1.2, Paint()..color = paint.color);
          continue;
        }
        cv.drawPath(_polyline(run, smooth: false), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant NightStack o) =>
      o.series != series || o.axes != axes;
}

/// The context behind a day's curve: when you were asleep, when you worked
/// out, when you were moving, and when nothing was recorded at all.
///
/// Every position here is a FRACTION of the plot's x range, so this shares
/// whatever time base the curve drawn over it uses and cannot drift from it —
/// which is the whole point of a day view. Nothing it draws is measured
/// against the y axis: the rest bands are full height, the workout blocks sit
/// on the top edge and the movement strip has its own fixed floor at the
/// bottom. The axis the frame labels stays the curve's alone.
///
/// A GAP AND A ZERO ARE NOT THE SAME MARK. A stretch with no measurement in it
/// changes the GROUND — it is a different surface, not a low value — and a
/// minute that was watched and was still keeps the hairline at the foot of the
/// movement strip. Without that line an hour sitting at a desk and an hour
/// with the band on the charger drew identically.
class DayLanes extends CustomPainter {
  /// Stretches with nothing recorded in them, as (from, to) fractions.
  final List<(double, double)> gaps;

  /// Asleep, and naps. A full-height tint, behind everything.
  final List<(double, double, Color)> rest;

  /// Workouts, as a block on the top edge — parallel to the clock and out of
  /// the curve's way.
  final List<(double, double, Color)> work;

  /// One entry per slot of the same time base the caller drew the curve on:
  /// 0…1 for the share of that slot spent moving, `null` where nothing was
  /// recorded. A FIXED scale, so a full-height bar always means the same
  /// thing and a quiet day cannot rescale itself into a dramatic one.
  final List<double?> movement;

  /// The surface's palette — the ground colour and the solved inks.
  final P p;

  DayLanes({
    required this.p,
    this.gaps = const [],
    this.rest = const [],
    this.work = const [],
    this.movement = const [],
  });

  /// Height of the movement strip, and of the workout blocks.
  static const _strip = 16.0, _block = 5.0;

  @override
  void paint(Canvas cv, Size s) {
    if (s.width <= 0 || s.height <= 0) return;
    double x(double f) => f.clamp(0.0, 1.0) * s.width;

    for (final (a, b) in gaps) {
      final l = x(a), r = x(b);
      if (r - l < .5) continue;
      cv.drawRect(Rect.fromLTRB(l, 0, r, s.height), Paint()..color = p.card2);
    }
    for (final (a, b, col) in rest) {
      final l = x(a), r = x(b);
      if (r - l < .5) continue;
      cv.drawRect(
        Rect.fromLTRB(l, 0, r, s.height),
        Paint()..color = col.withValues(alpha: p.dark ? .20 : .13),
      );
    }

    if (movement.isNotEmpty) {
      // Same aggregation the bar chart uses: a column of nothing stays
      // nothing, and a column of zeroes stays a zero.
      final v = Bars._columns(
          movement, (s.width / 2.5).floor().clamp(1, movement.length));
      final cw = s.width / v.length;
      final ink = p.on(C.domMove);
      final watched = Paint()..color = ink.withValues(alpha: .40);
      for (var i = 0; i < v.length; i++) {
        final m = v[i];
        if (m == null || !m.isFinite) continue;
        cv.drawRect(
            Rect.fromLTWH(i * cw, s.height - 1, cw + .5, 1), watched);
        final h = m.clamp(0.0, 1.0) * _strip;
        if (h <= 0) continue;
        cv.drawRect(
          Rect.fromLTWH(i * cw, s.height - h, max(cw - .5, 1), h),
          Paint()..color = ink,
        );
      }
    }

    for (final (a, b, col) in work) {
      final l = x(a), r = x(b);
      cv.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(l, 0, max(r - l, 2), _block),
          const Radius.circular(2),
        ),
        Paint()..color = col,
      );
    }
  }

  @override
  bool shouldRepaint(covariant DayLanes o) =>
      o.gaps != gaps ||
      o.rest != rest ||
      o.work != work ||
      o.movement != movement ||
      o.p.dark != p.dark;
}
