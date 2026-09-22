// WHOOP MG ECG — the drawn parts of the capture and detail screens. Original
// vector art (no WHOOP assets), driven by a caller-owned phase so reduced
// motion can freeze it, and two waveform painters that draw ONLY the samples
// they are handed: the live ring (a bounded preview, never persisted) and the
// saved accepted window (breaks at placeholders, never bridged).
//
// Nothing here claims a lead or a polarity: the axis is microvolts as the
// band sends them.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ecg/ecg_models.dart';
import '../ecg/ecg_waveform_buffer.dart';
import 'grammar.dart';
import 'theme.dart';

/// The band on the selected wrist, both electrode indents, and the opposite
/// hand's thumb and index finger touching them, with soft contact rings.
/// [t] is the pulse phase in [0, 1) — the SCREEN owns the clock; a frozen
/// [t] is a still illustration under reduced motion. The pinch stays in place;
/// [contact] settles the electrode halos once the band detects both fingers.
class EcgTouchIllustration extends StatelessWidget {
  final EcgWrist wrist;
  final double t;
  final bool contact;
  final String semanticLabel;

  const EcgTouchIllustration({
    super.key,
    required this.wrist,
    required this.t,
    required this.contact,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Semantics(
      label: semanticLabel,
      image: true,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _TouchPainter(
            wrist: wrist,
            t: t,
            contact: contact,
            ink: p.ink,
            ink2: p.ink3,
            band: p.ink,
            accent: C.domHealth,
            skin: p.card2,
          ),
          size: const Size(double.infinity, 200),
        ),
      ),
    );
  }
}

class _TouchPainter extends CustomPainter {
  final EcgWrist wrist;
  final double t;
  final bool contact;
  final Color ink, ink2, band, accent, skin;

  _TouchPainter({
    required this.wrist,
    required this.t,
    required this.contact,
    required this.ink,
    required this.ink2,
    required this.band,
    required this.accent,
    required this.skin,
  });

  @override
  void paint(Canvas cv, Size s) {
    // A fixed drawing space preserves the hand's proportions on narrow phones.
    final scale = math.min(s.width / 360, s.height / 200);
    cv.save();
    cv.clipRect(Offset.zero & s);
    // Mirror the entire composition, including the opposite hand.
    if (wrist == EcgWrist.left) {
      cv.translate(s.width, 0);
      cv.scale(-1, 1);
    }
    cv.translate((s.width - 360 * scale) / 2, (s.height - 200 * scale) / 2);
    cv.scale(scale);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = ink2;
    final fill = Paint()..color = skin;
    final crease = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = ink2.withValues(alpha: .65);

    // Resting arm: tapered wrist, then the heel and softly curled fingers of
    // the wearing hand. These contours remain behind the pinching hand.
    final arm = Path()
      ..moveTo(-12, 98)
      ..cubicTo(44, 98, 94, 108, 129, 108)
      ..cubicTo(156, 108, 172, 99, 187, 101)
      ..cubicTo(205, 102, 217, 113, 227, 122)
      ..cubicTo(237, 130, 247, 133, 247, 142)
      ..cubicTo(247, 149, 240, 152, 232, 150)
      ..cubicTo(236, 163, 225, 170, 213, 165)
      ..cubicTo(193, 160, 175, 150, 151, 150)
      ..cubicTo(110, 149, 49, 172, -12, 171)
      ..close();
    cv.drawPath(arm, fill);
    cv.drawPath(arm, outline);
    cv.drawPath(
      Path()
        ..moveTo(179, 116)
        ..quadraticBezierTo(192, 113, 202, 123)
        ..lineTo(224, 144)
        ..quadraticBezierTo(230, 150, 236, 150)
        ..moveTo(196, 143)
        ..quadraticBezierTo(204, 155, 218, 157),
      crease,
    );

    // Wide fabric wrap with a raised, screenless capsule. Short cross-lines
    // suggest the woven strap; the two inset metal pads sit on opposing edges.
    cv.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(118, 99, 60, 64),
        const Radius.circular(11),
      ),
      Paint()..color = band,
    );
    final weave = Paint()
      ..color = skin.withValues(alpha: .35)
      ..strokeWidth = 1;
    for (var y = 104.0; y <= 156; y += 5) {
      cv.drawLine(Offset(122, y), Offset(174, y), weave);
    }
    final capsule = RRect.fromRectAndRadius(
      const Rect.fromLTWH(126, 94, 45, 64),
      const Radius.circular(12),
    );
    cv.drawRRect(capsule, Paint()..color = band);
    cv.drawPath(
      Path()
        ..moveTo(137, 103)
        ..quadraticBezierTo(132, 104, 132, 111)
        ..lineTo(132, 141)
        ..moveTo(165, 111)
        ..lineTo(165, 141)
        ..quadraticBezierTo(165, 148, 160, 149),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = skin.withValues(alpha: .5),
    );
    final metal = Paint()..color = Color.lerp(skin, ink2, .35)!;
    for (final y in [91.0, 153.0]) {
      cv.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(138, y, 21, 8),
          const Radius.circular(4),
        ),
        metal,
      );
    }

    // One continuous opposite-hand silhouette: bent index above, palm and
    // wrist at the right, and a shorter, broader thumb below. The open web
    // between index and thumb exposes the band and the resting wrist.
    final hand = Path()
      ..moveTo(372, 68)
      ..lineTo(306, 68)
      ..cubicTo(289, 68, 278, 52, 260, 44)
      ..cubicTo(237, 33, 207, 30, 185, 38)
      ..cubicTo(164, 45, 145, 61, 139, 79)
      ..cubicTo(135, 89, 140, 94, 148, 94)
      ..cubicTo(155, 94, 159, 89, 163, 82)
      ..cubicTo(172, 68, 190, 60, 207, 60)
      ..cubicTo(225, 60, 241, 71, 250, 88)
      ..cubicTo(259, 104, 260, 120, 249, 134)
      ..cubicTo(238, 148, 216, 158, 194, 159)
      ..cubicTo(177, 160, 166, 151, 153, 156)
      ..cubicTo(144, 159, 144, 168, 151, 173)
      ..cubicTo(165, 184, 189, 187, 211, 183)
      ..cubicTo(238, 179, 262, 169, 283, 156)
      ..quadraticBezierTo(299, 147, 317, 149)
      ..lineTo(372, 159)
      ..close();
    cv.drawPath(hand, fill);
    cv.drawPath(hand, outline);

    // Nails at the two tips, finger-joint folds and the thumb's thenar crease
    // give the pinch anatomical cues without competing with the contact pads.
    cv.drawPath(
      Path()
        ..moveTo(143, 80)
        ..quadraticBezierTo(144, 73, 150, 69)
        ..quadraticBezierTo(156, 70, 158, 75)
        ..lineTo(152, 85)
        ..quadraticBezierTo(146, 87, 143, 80)
        ..moveTo(153, 164)
        ..quadraticBezierTo(160, 159, 170, 164)
        ..lineTo(174, 172)
        ..quadraticBezierTo(162, 175, 155, 170)
        ..moveTo(181, 44)
        ..quadraticBezierTo(187, 48, 189, 54)
        ..moveTo(226, 43)
        ..quadraticBezierTo(224, 48, 225, 52)
        ..moveTo(200, 166)
        ..quadraticBezierTo(202, 171, 201, 176)
        ..moveTo(271, 114)
        ..cubicTo(280, 133, 263, 151, 245, 158)
        ..moveTo(308, 81)
        ..quadraticBezierTo(300, 91, 303, 103),
      crease,
    );

    // Always-visible targets teach the same pose at every frozen phase. A
    // seamless, gentle breath draws attention before contact; then it settles.
    final pulse = .5 - .5 * math.cos(t * 2 * math.pi);
    final radius = contact ? 8.0 : 10.0 + 4 * pulse;
    final halo = Paint()
      ..color = accent.withValues(alpha: contact ? .12 : .10 + .06 * pulse);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = contact ? 1.5 : 1.8
      ..color = accent.withValues(alpha: contact ? .55 : .45 + .25 * pulse);
    for (final point in [const Offset(148, 95), const Offset(148, 157)]) {
      cv.drawCircle(point, radius, halo);
      cv.drawCircle(point, radius, ring);
      cv.drawCircle(point, 4, Paint()..color = ink);
      cv.drawCircle(point, 2.6, Paint()..color = accent);
    }
    cv.restore();
  }

  @override
  bool shouldRepaint(_TouchPainter o) =>
      o.t != t ||
      o.contact != contact ||
      o.wrist != wrist ||
      o.ink != ink ||
      o.ink2 != ink2 ||
      o.band != band ||
      o.accent != accent ||
      o.skin != skin;
}

/// The live preview: the newest few seconds of real samples, a stable
/// symmetric range, one repaint per scheduler tick. Labelled as a preview —
/// it is not the reading and not an analysis.
class EcgLivePreview extends StatelessWidget {
  final EcgWaveformBuffer buffer;
  final EcgPreviewScheduler scheduler;
  final String label;
  final String unit;

  const EcgLivePreview({
    super.key,
    required this.buffer,
    required this.scheduler,
    required this.label,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Semantics(
      label: label,
      child: Surface(
        pad: const EdgeInsets.all(S.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label, style: F.cap.copyWith(color: p.ink3)),
                ),
                Text(unit, style: F.cap.copyWith(color: p.ink3)),
              ],
            ),
            const SizedBox(height: S.x2),
            SizedBox(
              height: 96,
              child: RepaintBoundary(
                child: _SchedulerRepaint(
                  scheduler: scheduler,
                  builder: (_) => CustomPaint(
                    painter: EcgLivePainter(
                      buffer: buffer,
                      version: buffer.version,
                      color: C.domHealth,
                      grid: p.line,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rebuilds its child when the scheduler ticks (and only then).
class _SchedulerRepaint extends StatefulWidget {
  final EcgPreviewScheduler scheduler;
  final WidgetBuilder builder;
  const _SchedulerRepaint({required this.scheduler, required this.builder});

  @override
  State<_SchedulerRepaint> createState() => _SchedulerRepaintState();
}

class _SchedulerRepaintState extends State<_SchedulerRepaint> {
  @override
  void initState() {
    super.initState();
    widget.scheduler.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.scheduler.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// Symmetric ±range in µV for a window whose largest magnitude is [maxAbs]:
/// stepped so it does not jitter packet to packet, never below the floor.
int ecgPreviewRange(int maxAbs, {int step = 250, int floor = 500}) {
  final stepped = ((maxAbs + step - 1) ~/ step) * step;
  return math.max(floor, stepped);
}

class EcgLivePainter extends CustomPainter {
  final EcgWaveformBuffer buffer;
  final int version;
  final Color color;
  final Color grid;

  EcgLivePainter({
    required this.buffer,
    required this.version,
    required this.color,
    required this.grid,
  });

  @override
  void paint(Canvas cv, Size s) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    cv.drawLine(
      Offset(0, s.height / 2),
      Offset(s.width, s.height / 2),
      gridPaint,
    );
    final n = buffer.length;
    if (n < 2 || s.width <= 0) return;
    final range = ecgPreviewRange(buffer.maxAbs()).toDouble();
    final cap = buffer.capacity;
    // The window is the ring's capacity; a partly-filled ring draws from the
    // right so the trace scrolls in rather than stretching.
    final dx = s.width / (cap - 1);
    final x0 = s.width - (n - 1) * dx;
    final path = Path();
    for (var i = 0; i < n; i++) {
      final v = buffer[i].clamp(-range, range);
      final y = s.height / 2 - v / range * (s.height / 2 - 2);
      final x = x0 + i * dx;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    cv.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(EcgLivePainter o) =>
      o.version != version || o.buffer != buffer || o.color != color;
}

/// The complete accepted window of a saved reading. A placeholder packet is
/// a visible break — a one-second hole in the trace, never a line across it.
/// Horizontal scale is [pxPerSecond]; the caller wraps it in a horizontal
/// scroll view at the width [widthFor] reports.
class EcgWaveformPainter extends CustomPainter {
  final List<EcgAcceptedPacket> packets;
  final double pxPerSecond;
  final Color color;
  final Color grid;
  final Color gap;

  EcgWaveformPainter({
    required this.packets,
    required this.pxPerSecond,
    required this.color,
    required this.grid,
    required this.gap,
  });

  /// One second per packet (100 samples at 100 Hz), placeholders included.
  static double widthFor(List<EcgAcceptedPacket> packets, double pxPerSecond) =>
      math.max(1, packets.length) * pxPerSecond;

  static int rangeFor(List<EcgAcceptedPacket> packets) {
    var m = 0;
    for (final p in packets) {
      for (final v in p.samples) {
        if (v.abs() > m) m = v.abs();
      }
    }
    return ecgPreviewRange(m);
  }

  @override
  void paint(Canvas cv, Size s) {
    if (packets.isEmpty) return;
    final range = rangeFor(packets).toDouble();
    final mid = s.height / 2;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    // One-second grid.
    for (var i = 0; i <= packets.length; i++) {
      final x = i * pxPerSecond;
      cv.drawLine(Offset(x, 0), Offset(x, s.height), gridPaint);
    }
    cv.drawLine(Offset(0, mid), Offset(s.width, mid), gridPaint);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final gapPaint = Paint()..color = gap;
    var x = 0.0;
    Path? path;
    for (final p in packets) {
      if (p.placeholder || p.samples.isEmpty) {
        // Break the trace and wash the missing second.
        if (path != null) cv.drawPath(path, stroke);
        path = null;
        cv.drawRect(Rect.fromLTWH(x, 0, pxPerSecond, s.height), gapPaint);
        x += pxPerSecond;
        continue;
      }
      final n = p.samples.length;
      final dx = pxPerSecond / kEcgSampleRateHz;
      for (var i = 0; i < n; i++) {
        final v = p.samples[i].clamp(-range, range);
        final y = mid - v / range * (mid - 2);
        final px = x + i * dx;
        if (path == null) {
          path = Path()..moveTo(px, y);
        } else {
          path.lineTo(px, y);
        }
      }
      x += pxPerSecond;
    }
    if (path != null) cv.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(EcgWaveformPainter o) =>
      o.packets != packets || o.pxPerSecond != pxPerSecond || o.color != color;
}
