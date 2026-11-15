// Moving hand shared by every live guide. GuideHandMachine owns motion state;
// LiveGuideOverlay owns target geometry and invalidates it on layout/scroll.
// Hover belongs to RenderGuideUnit, never to this overlay painter.
// CLAIM(hand-cached-paths) CLAIM(hand-own-transform) [guide_r7_test].
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../skeleton/guide_plot.dart' show GuideDecoration;
import '../theme.dart' show C;

/// What the machine is doing for the step on screen.
enum GuideHandMode {
  /// One target: the hand comes in along its finger, taps, pulls back and comes in again.
  single,

  /// A row of targets: one continuous wave through them in order and back (ping-pong).
  row,

  /// The first visit to a screen with a group to open: travel to it and tap once, then wait.
  opening,

  /// A vertical list (variant B): bottom up, finger first, leaning with the wave, then an upright
  /// drift back down beside the list.
  list,
}

/// Told when the hand's press reaches its bottom (the moment a ripple leaves the fingertip).
abstract interface class GuideHandEvents {
  /// [index] is the visited target's place in the visiting set.
  void handPressed(int index);
}

/// A ripple that left the fingertip [ageMs] ago.
class GuideRipple {
  Offset at;
  double ageMs;
  GuideRipple(this.at, this.ageMs);
}

/// How long a ripple lives.
const kGuideRippleMs = 600.0;

/// The most the hand turns, in degrees per second.
const kGuideHandRateCap = 240.0;

/// The most the hand leans with its sideways speed, in degrees.
const kGuideHandLean = 12.0;

/// How far from a target (px) its highlight is fully gone; it falls as (1 - d / this)^2.
const kGuideHoverReach = 150.0;

double _ease(double p) => p < .5 ? 2 * p * p : 1 - math.pow(-2 * p + 2, 2) / 2;

/// [current] turned toward [wanted] by at most [kGuideHandRateCap] degrees per second over
/// [seconds] (a frame longer than 100 ms counts as 100 ms, as in the mock).
double capRotation(double current, double wanted, double seconds) {
  final step = kGuideHandRateCap * math.min(seconds, .1);
  return current + (wanted - current).clamp(-step, step).toDouble();
}

/// The point at [s] (0..1) of the wave from [a] to [b]: a straight line plus a half-sine
/// displacement of [k] pixels across it (positive k bends to the left of the heading).
Offset guideWavePoint(Offset a, Offset b, double s, double k) {
  final d = b - a, len = d.distance == 0 ? 1.0 : d.distance;
  final n = Offset(-d.dy / len, d.dx / len);
  return a + d * s + n * (k * math.sin(math.pi * s));
}

/// The direction (unit vector) the wave from [a] to [b] heads in at [s]: the derivative of
/// [guideWavePoint] by s, so it is a property of the PATH (the hand slows to a stop at every
/// target, but the path itself must not kink there).
Offset guideWaveTangent(Offset a, Offset b, double s, double k) {
  final d = b - a, len = d.distance == 0 ? 1.0 : d.distance;
  final n = Offset(-d.dy / len, d.dx / len);
  final t = d + n * (k * math.pi * math.cos(math.pi * s));
  final tl = t.distance == 0 ? 1.0 : t.distance;
  return t / tl;
}

/// The bend of the wave from [a] to [b]: at most [amp] pixels and 35% of the distance, signed.
double guideWaveBend(Offset a, Offset b, double sign, {double amp = 26}) =>
    math.min(amp, (b - a).distance * .35) * sign;

/// Travel shortened after the R7 CPU probe: 300 ms + 1.2 ms/px, capped at 700 ms.
double guideSweepMs(double distance) => math.min(700.0, 300 + distance * 1.2);

/// The order a row of [n] targets is visited in: out and back (0, 1, 2, 1 for three).
List<int> guidePingPong(int n) => n <= 1 ? [0] : [for (var i = 0; i < n; i++) i, for (var i = n - 2; i >= 1; i--) i];

sealed class _Phase {
  double ms;
  _Phase(this.ms);
}

final class _Hold extends _Phase {
  _Hold(super.ms);
}

/// Instantly at [dx], [dy] from target [index]'s centre.
final class _Place extends _Phase {
  final int index;
  final double dx, dy;
  _Place(this.index, this.dx, this.dy) : super(0);
}

final class _Sweep extends _Phase {
  final int to;
  final double lean, amp;
  _Sweep(this.to, this.lean, this.amp, double ms) : super(ms);
  Offset? from;
  double k = 0;
  GuideHandPath? path;

  /// How far the targets have moved (a scroll) since [path] was sampled.
  Offset shift = Offset.zero;
}

final class _Press extends _Phase {
  final int index;
  final bool down;
  _Press(this.index, this.down) : super(down ? 150 : 170);
}

/// Single target: [d] pixels back along the finger, moving in or out.
final class _Along extends _Phase {
  final bool inward;
  _Along(this.inward) : super(320);
}

/// The upright drift back down beside the list (list variant B).
final class _Drift extends _Phase {
  final int to;
  _Drift(this.to) : super(1100);
  GuideHandPath? path;
  Offset shift = Offset.zero;
}

/// The hand's motion. Feed it the elapsed time and the current rects of the visiting set (in
/// overlay coordinates, in visiting order) and read [tip], [angle] and [press].
class GuideHandMachine {
  GuideHandMachine({this.events});

  GuideHandEvents? events;

  /// The fingertip, in overlay coordinates.
  Offset tip = Offset.zero;

  /// The hand's rotation in degrees (0 = finger up).
  double angle = 0;

  /// The press scale (1 at rest, .86 at the bottom of a press).
  double press = 1;

  final ripples = <GuideRipple>[];
  GuideHandMode _mode = GuideHandMode.single;
  GuideHandMode get mode => _mode;
  bool _placed = false;
  _Phase? _phase;
  double _t = 0;
  double _sign = 1;
  int _cursor = 0;
  double _fixedAngle = 0;
  List<Rect> _rects = const [];
  final _paths = <(Offset, Offset, double), GuideHandPath>{};
  final _drifts = <(Offset, Rect), GuideHandPath>{};
  @visibleForTesting
  int pathBuilds = 0;

  GuideHandPath _path(Offset a, Offset b, double bend) => _paths.putIfAbsent((a, b, bend), () {
    pathBuilds++;
    return GuideHandPath(a, b, bend);
  });

  /// Takes the visiting set's rects of this frame. Segments are sampled when a sweep begins and
  /// reused while the geometry holds. A scroll moves every rect by the same amount: the hand moves
  /// with them (its loop keeps its phase) instead of finishing the sweep at the old place.
  void _targets(List<Rect> rects) {
    if (identical(rects, _rects) || listEquals(rects, _rects)) return;
    final old = _rects;
    _rects = rects;
    _paths.clear();
    _drifts.clear();
    if (old.length != rects.length || old.isEmpty) return;
    final d = rects.first.topLeft - old.first.topLeft;
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].size != old[i].size || (rects[i].topLeft - old[i].topLeft - d).distance > .01) return;
    }
    tip += d;
    final phase = _phase;
    if (phase is _Sweep) { phase.shift += d; } else if (phase is _Drift) { phase.shift += d; }
    for (final r in ripples) { r.at += d; }
  }


  /// Where the single-target hand points: this many degrees off vertical (as in the mock).
  static const singleAngle = 14.0;

  /// How far back along its finger the single-target hand starts, in pixels.
  static const singleBack = 26.0;
  static final _backVector = Offset(-math.sin(singleAngle * math.pi / 180), math.cos(singleAngle * math.pi / 180)) * singleBack;

  /// Switches to [mode]. A mode the machine is already in is left running.
  void setMode(GuideHandMode mode) {
    if (mode == _mode && _phase != null) return;
    _mode = mode;
    _phase = null;
    _t = 0;
    _cursor = 0;
    _placed = false;
    _fixedAngle = 0;
    _queue.clear();
  }

  /// How many times the loop was restarted (for tests: a scroll must not restart it).
  @visibleForTesting
  int restartCount = 0;

  /// Restarts from the beginning of the current mode.
  void restart() {
    restartCount++;
    ripples.clear();
    _queue.clear();
    _phase = null;
    _t = 0;
    _cursor = 0;
    _placed = false;
  }

  Offset _center(int i) => _rects[i.clamp(0, _rects.length - 1)].center;

  List<_Phase> _loop() {
    final n = _rects.length;
    switch (_mode) {
      case GuideHandMode.single:
        final c = _cursor++;
        return c == 0
            ? [_Place(0, 0, 0), _Along(true)]
            : [_Press(0, true), _Press(0, false), _Hold(300), _Along(false), _Hold(250), _Along(true)];
      case GuideHandMode.row:
        final order = guidePingPong(n);
        final c = _cursor++;
        if (c == 0) return [_Place(0, -34, 26), _Sweep(0, kGuideHandLean, 14, 0)];
        final i = (c - 1) % order.length, next = order[(i + 1) % order.length];
        return [_Press(order[i], true), _Press(order[i], false), _Hold(140), _Sweep(next, kGuideHandLean, 26, 0)];
      case GuideHandMode.opening:
        final c = _cursor++;
        if (c == 0) return [_Place(0, 40, 70), _Hold(400), _Sweep(0, kGuideHandLean, 26, 0), _Press(0, true), _Press(0, false)];
        return [_Hold(100)]; // waits for setMode(list): the screen is opening
      case GuideHandMode.list:
        final last = n - 1;
        final c = _cursor++;
        if (c == 0) return [_Sweep(last, 0, 10, 0)];
        // One pass bottom up: tap, wait, sweep to the next one up; then drift back down.
        final pass = <_Phase>[];
        for (var j = last; j >= 0; j--) {
          pass..add(_Press(j, true))..add(_Press(j, false))..add(_Hold(140));
          if (j > 0) pass.add(_Sweep(j - 1, 16, 24, 0));
        }
        pass.add(_Drift(last));
        return pass;
    }
  }

  final _queue = <_Phase>[];

  /// Moves the hand by [dtMs] milliseconds over [rects] (the visiting set's rects now).
  void advance(double dtMs, List<Rect> rects) {
    if (rects.isEmpty || dtMs <= 0) return;
    _targets(rects);
    final before = tip;
    var left = dtMs;
    var guard = 0;
    while (left > 0 && guard++ < 64) {
      if (_phase == null) {
        if (_queue.isEmpty) _queue.addAll(_loop());
        _phase = _queue.removeAt(0);
        _t = 0;
        _begin(_phase!);
      }
      final phase = _phase!;
      final room = phase.ms - _t;
      final use = phase.ms == 0 ? 0.0 : math.min(left, room);
      _t += use;
      left -= use;
      _eval(phase, phase.ms == 0 ? 1 : _t / phase.ms);
      if (_t >= phase.ms) {
        _end(phase);
        _phase = null;
      }
    }
    for (final r in ripples) {
      r.ageMs += dtMs;
    }
    ripples.removeWhere((r) => r.ageMs > kGuideRippleMs);
    // Lean with the sideways speed, rate-capped.
    final v = tip - before;
    double wanted = _fixedAngle;
    final lean = _leanNow;
    if (_mode != GuideHandMode.single && lean != null) {
      wanted = v.distance > .05 ? (v.dx / v.distance * lean).clamp(-lean, lean).toDouble() : angle;
    }
    angle = _placed ? capRotation(angle, wanted, dtMs / 1000) : wanted;
    _placed = true;
  }

  double? _leanNow;

  void _begin(_Phase p) {
    switch (p) {
      case _Sweep():
        p.from = tip;
        final b = _center(p.to);
        p.ms = guideSweepMs((b - tip).distance);
        p.k = guideWaveBend(tip, b, _sign, amp: p.amp);
        _sign = -_sign;
        p.path = _path(tip, b, p.k);
        _leanNow = p.lean;
      case _Drift():
        final last = _rects[p.to];
        p.path = _drifts.putIfAbsent((tip, last), () {
          pathBuilds++;
          return GuideHandPath.drift(tip, last);
        });
        _leanNow = 0;
      case _Along():
        _leanNow = null;
        _fixedAngle = singleAngle;
      case _Place() || _Hold() || _Press():
        break;
    }
  }

  void _eval(_Phase p, double s) {
    switch (p) {
      case _Hold():
        break;
      case _Place():
        final c = _center(p.index);
        tip = c + Offset(p.dx, p.dy);
        press = 1;
      case _Sweep():
        tip = p.path!.at(_ease(s)) + p.shift;
      case _Press():
        press = p.down ? 1 - .14 * s : .86 + .14 * s;
        if (p.down && s >= 1) {
          ripples.add(GuideRipple(tip, 0));
          events?.handPressed(p.index);
        }
      case _Along():
        tip = _center(0) + _backVector * (p.inward ? 1 - _ease(s) : _ease(s));
      case _Drift():
        tip = p.path!.at(_ease(s)) + p.shift;
    }
  }

  void _end(_Phase p) {
    if (p is _Press && !p.down) press = 1;
    // Land exactly on the centre: the next sweep's cache key then matches its neighbours'.
    if (p is _Sweep) tip = _center(p.to);
  }

  /// Phases still queued (for tests).
  @visibleForTesting
  int get queued => _queue.length;
}

/// The hover highlight's opacity for a target whose centre is [distance] from the fingertip.
double guideHoverOpacity(double distance) {
  final o = (1 - distance / kGuideHoverReach).clamp(0.0, 1.0);
  return o * o;
}

/// A target as the painter needs it.
class GuideHandTarget {
  final Rect rect;
  final double radius;
  const GuideHandTarget(this.rect, this.radius);
}

/// Shared motion read by the cursor transform and the ripple painter.
abstract interface class GuideHandSource {
  List<GuideHandTarget> get handTargets;
  GuideHandMachine get handMachine;
  Color get handColor;
}

/// Ripple paint has its own boundary. The cursor below moves by transform.
class GuideHandPainter extends CustomPainter implements GuideDecoration {
  final GuideHandSource source;
  GuideHandPainter(this.source, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final m = source.handMachine, c = source.handColor;
    for (final r in m.ripples) {
      final p = (r.ageMs / kGuideRippleMs).clamp(0.0, 1.0);
      canvas.drawCircle(r.at, 6 + 11 * Curves.easeOut.transform(p),
          Paint()..color = c.withValues(alpha: 1 - p)..style = PaintingStyle.stroke..strokeWidth = 2);
    }

  }

  @override
  bool shouldRepaint(GuideHandPainter old) => !identical(old.source, source);
}

// The cursor: index finger, three folded fingers, thumb and palm as rounded rectangles in a
// 22 x 27 box (the mock's drawing), outlined dark, filled with the step colour.
const _kHandShapes = <(double, double, double, double, double)>[
  (6.6, 0.8, 4.6, 15, 2.3),
  (10.6, 8.2, 4, 8.6, 2),
  (14.2, 9.4, 3.8, 7.8, 1.9),
  (17.6, 11, 3.4, 7, 1.7),
  (1.4, 12.6, 4.4, 8.6, 2.2),
  (5, 12.4, 16, 13.4, 5.4),
];

/// Where the fingertip is inside the hand's 24 x 28 px box.
const kGuideHandTip = Offset(8.9 * 24 / 22, 0.8 * 28 / 27);

/// Paints the hand with its fingertip at [tip], turned [angleDeg] and scaled [scale] about it.
void paintGuideHand(Canvas canvas, Offset tip, double angleDeg, double scale, Color fill) {
  canvas
    ..save()
    ..translate(tip.dx, tip.dy)
    ..rotate(angleDeg * math.pi / 180)
    ..scale(scale)
    ..translate(-kGuideHandTip.dx, -kGuideHandTip.dy)
    ..scale(24 / 22, 28 / 27);
  final dark = Paint()..color = C.n900..style = PaintingStyle.stroke..strokeWidth = 2.4..strokeJoin = StrokeJoin.round;
  final darkFill = Paint()..color = C.n900;
  final paint = Paint()..color = fill;
  for (var i = 0; i < _kHandShapes.length; i++) {
    final (x, y, w, h, r) = _kHandShapes[i];
    final rr = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r));
    canvas.save();
    if (i == 4) {
      canvas
        ..translate(3.6, 16.9)
        ..rotate(-40 * math.pi / 180)
        ..translate(-3.6, -16.9);
    }
    canvas
      ..drawRRect(rr, dark)
      ..drawRRect(rr, darkFill)
      ..drawRRect(rr, paint);
    canvas.restore();
  }
  final fold = Paint()..color = C.n900.withValues(alpha: .55)..style = PaintingStyle.stroke..strokeWidth = .9..strokeCap = StrokeCap.round;
  canvas
    ..drawLine(const Offset(10.8, 12.6), const Offset(10.8, 16), fold)
    ..drawLine(const Offset(14.4, 13.2), const Offset(14.4, 16.6), fold)
    ..drawLine(const Offset(17.8, 14.2), const Offset(17.8, 17.2), fold)
    ..restore();
}

/// A sampled half-wave; animation frames only interpolate cached points.
class GuideHandPath {
  final List<Offset> _points;
  GuideHandPath(Offset a, Offset b, double bend) : _points = [
    for (var i = 0; i <= 64; i++) guideWavePoint(a, b, i / 64, bend),
  ];
  GuideHandPath.drift(Offset a, Rect last) : _points = [
    for (var i = 0; i <= 64; i++) _driftPoint(a, last, i / 64),
  ];
  static Offset _driftPoint(Offset a, Rect last, double q) {
    final b = last.center, c = Offset(last.right - 18, (a.dy + last.center.dy) / 2), m = 1 - q;
    return a * (m * m) + c * (2 * m * q) + b * (q * q);
  }
  Offset at(double progress) {
    final p = progress.clamp(0.0, 1.0) * 64;
    final i = p.floor();
    return i == 64 ? _points.last : Offset.lerp(_points[i], _points[i + 1], p - i)!;
  }
}

/// Only the render transform listens to motion. Its child is a cached cursor picture.
class GuideHandCursor extends StatelessWidget {
  final GuideHandSource source;
  final Listenable clock;
  const GuideHandCursor({super.key, required this.source, required this.clock});
  @override
  Widget build(BuildContext context) => _HandTransform(source: source, clock: clock,
    child: RepaintBoundary(child: CustomPaint(size: const Size(40, 40), painter: _CursorPainter(source.handColor))));
}

class _HandTransform extends SingleChildRenderObjectWidget {
  final GuideHandSource source;
  final Listenable clock;
  const _HandTransform({required this.source, required this.clock, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHandTransform(source, clock);
  @override
  void updateRenderObject(BuildContext context, _RenderHandTransform renderObject) {
    renderObject.update(source, clock);
  }
}

class _RenderHandTransform extends RenderTransform {
  GuideHandSource source;
  Listenable clock;
  _RenderHandTransform(this.source, this.clock) : super(transform: Matrix4.identity()) { _tick(); }
  void update(GuideHandSource nextSource, Listenable nextClock) {
    if (!identical(clock, nextClock)) {
      if (attached) clock.removeListener(_tick);
      clock = nextClock;
      if (attached) clock.addListener(_tick);
    }
    source = nextSource;
    _tick();
  }
  @override
  void attach(PipelineOwner owner) { super.attach(owner); clock.addListener(_tick); }
  @override
  void detach() { clock.removeListener(_tick); super.detach(); }
  void _tick() {
    final hand = source.handMachine;
    transform = Matrix4.identity()
      ..translateByDouble(hand.tip.dx, hand.tip.dy, 0, 1)
      ..rotateZ(hand.angle * math.pi / 180)
      ..scaleByDouble(hand.press, hand.press, 1, 1)
      ..translateByDouble(-kGuideHandTip.dx, -kGuideHandTip.dy, 0, 1);
  }
}

class _CursorPainter extends CustomPainter implements GuideDecoration {
  final Color color;
  const _CursorPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) => paintGuideHand(canvas, kGuideHandTip, 0, 1, color);
  @override
  bool shouldRepaint(_CursorPainter old) => color != old.color;
}
