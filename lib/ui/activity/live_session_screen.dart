// Live workout — an interactive, HR-reactive screen that reacts to your heart in
// real time. Everything here is driven by REAL live HR (device.liveHr via BLE):
// an ember core that beats at your pulse, a zone ladder with "almost there" nudges,
// an "in the red" streak, milestone bursts, and a playful line engine. Code-drawn
// (CustomPaint), haptics-only, open-ended. Long-press to finish → breakdown.

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../workouts/workouts_screen.dart' show WorkoutDetailScreen;

class LiveSessionScreen extends StatefulWidget {
  final String? workoutId; // backend session id (for the breakdown on finish)
  final String type;
  const LiveSessionScreen({super.key, this.workoutId, this.type = 'other'});

  @override
  State<LiveSessionScreen> createState() => _LiveSessionScreenState();
}

// Zone metadata (0..5) — matches app_state's %max bands.
class _ZoneMeta {
  final String label, name;
  final Color color;
  const _ZoneMeta(this.label, this.name, this.color);
}

final List<_ZoneMeta> _zones = [
  _ZoneMeta('Z0', 'Resting', AppColors.cool),
  _ZoneMeta('Z1', 'Warm-up', AppColors.loadDetraining),
  _ZoneMeta('Z2', 'Fat burn', AppColors.good),
  _ZoneMeta('Z3', 'Aerobic', AppColors.warn),
  _ZoneMeta('Z4', 'Threshold', AppColors.coral),
  _ZoneMeta('Z5', 'Max effort', AppColors.coralDeep),
];
const _zonePct = [0.0, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]; // lower bound of z0..z5 then top

// Playful + a little funny lines, by zone bucket.
const Map<int, List<String>> _lines = {
  0: ["Heart's still sipping coffee.", "Easing in — no sprinting cold.", "Loosening the engine…"],
  1: ["Warm-up mode. We build to it.", "Blood's moving. Good start.", "Gentle. The fun comes later."],
  2: ["Cruising — the fat-burn sweet spot.", "Your mitochondria say thanks.", "Zone 2: the long-game zone."],
  3: ["Engine's humming. Hold this.", "Aerobic and honest. Keep rolling.", "This is the work. Stay here."],
  4: ["Threshold — this is where fitness is built.", "Breathe and hold. You've got this.", "The good kind of uncomfortable."],
  5: ["MAX. Brief and brutal — respect.", "Full send. Your heart filed a complaint.", "Don't quit. You're almost through it."],
};
const List<String> _droppingLines = [
  "HR's easing down — recover, or pick it back up?",
  "Catching your breath. Smart.",
  "Coasting. Ready when you are.",
];

class _LiveSessionScreenState extends State<LiveSessionScreen>
    with TickerProviderStateMixin {
  late final AnimationController _beat;   // HR pulse
  late final AnimationController _hold;   // hold-to-finish
  late final AnimationController _fx;     // ember field (continuous)
  late final AnimationController _burst;  // celebration confetti (one-shot)

  AppState? _app;
  int _lastZone = -1;
  DateTime? _redStart;                    // start of continuous time in zone ≥3
  Duration _redStreak = Duration.zero;
  final Set<String> _milestones = {};
  String _line = '';
  int _lineSeed = 0;
  String? _callout;                       // ephemeral big banner ("ZONE 4")
  String? _calloutSub;
  DateTime _calloutUntil = DateTime.fromMillisecondsSinceEpoch(0);
  final List<_Particle> _confetti = [];
  final _rand = math.Random();
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
    _hold = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _fx = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
    _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _app = context.read<AppState>();
      _app!.addListener(_onTick);
      _onTick();
    });
  }

  @override
  void dispose() {
    _app?.removeListener(_onTick);
    _beat.dispose();
    _hold.dispose();
    _fx.dispose();
    _burst.dispose();
    super.dispose();
  }

  double get _maxHr {
    final age = (_app?.user?['age'] as num?)?.toDouble() ?? 30.0;
    return 220.0 - age;
  }

  int _zoneFor(int hr) {
    if (hr <= 0) return 0;
    final pct = hr / _maxHr;
    for (int z = 5; z >= 1; z--) {
      if (pct >= _zonePct[z]) return z;
    }
    return 0;
  }

  // Per-second tick from AppState.notifyListeners — all side effects live here.
  void _onTick() {
    final w = _app?.activeWorkout;
    if (w == null || !mounted) return;
    final hr = w.currentHr;
    final zone = _zoneFor(hr);

    // Beat at the real heart rate.
    if (hr > 40) _beat.duration = Duration(milliseconds: (60000 / hr).round());

    // In-the-red streak (continuous time in zone ≥3).
    if (zone >= 3) {
      _redStart ??= DateTime.now();
      _redStreak = DateTime.now().difference(_redStart!);
    } else {
      _redStart = null;
      _redStreak = Duration.zero;
    }

    // Zone-up moment → callout + heavy haptic + confetti.
    if (_lastZone >= 0 && zone > _lastZone && zone >= 1) {
      _fireCallout(_zones[zone].label, _zones[zone].name.toUpperCase());
      HapticFeedback.heavyImpact();
      if (zone >= 4) _fireConfetti(_zones[zone].color);
    } else if (_lastZone >= 0 && zone < _lastZone && zone <= 2 && _lastZone >= 3) {
      HapticFeedback.selectionClick();
    }

    // Milestones — time / calories / new max HR.
    final mins = w.elapsed.inMinutes;
    if (mins > 0 && mins % 5 == 0) _milestone('t$mins', '$mins MINUTES', "Locked in. Keep going.", AppColors.good);
    final kcalStep = (w.calories ~/ 100) * 100;
    if (kcalStep >= 100) _milestone('k$kcalStep', '$kcalStep KCAL', "Burning clean.", AppColors.coral);
    if (w.elapsed.inSeconds > 90 && hr > 0 && hr == w.maxHrSeen && hr >= (_maxHr * 0.8)) {
      _milestone('mhr$hr', 'NEW MAX · $hr', "Highest your heart's gone today.", AppColors.coralDeep);
    }

    // Rotate the playful line ~every 11s (or on zone change).
    final seed = w.elapsed.inSeconds ~/ 11;
    if (seed != _lineSeed || zone != _lastZone) {
      _lineSeed = seed;
      final bucket = (zone < _lastZone && zone <= 2) ? _droppingLines : (_lines[zone] ?? _lines[0]!);
      _line = bucket[(seed + zone) % bucket.length];
    }

    _lastZone = zone;
    setState(() {});
  }

  void _fireCallout(String big, String sub) {
    _callout = big;
    _calloutSub = sub;
    _calloutUntil = DateTime.now().add(const Duration(seconds: 3));
  }

  void _milestone(String key, String big, String sub, Color c) {
    if (_milestones.contains(key)) return;
    _milestones.add(key);
    _fireCallout(big, sub);
    _fireConfetti(c);
    HapticFeedback.mediumImpact();
  }

  void _fireConfetti(Color c) {
    _confetti
      ..clear()
      ..addAll(List.generate(26, (_) {
        final ang = -math.pi / 2 + (_rand.nextDouble() - 0.5) * 1.6;
        final spd = 220 + _rand.nextDouble() * 320;
        return _Particle(
          vx: math.cos(ang) * spd, vy: math.sin(ang) * spd,
          color: [c, Colors.white, AppColors.coralSoft][_rand.nextInt(3)],
          size: 4 + _rand.nextDouble() * 5,
          spin: (_rand.nextDouble() - 0.5) * 12,
        );
      }));
    _burst.forward(from: 0);
  }

  Future<void> _finish() async {
    if (_ending) return;
    setState(() => _ending = true);
    HapticFeedback.heavyImpact();
    final app = context.read<AppState>();
    final id = widget.workoutId ?? app.activeWorkout?.workoutId;
    app.stopWorkout(); // clears local + ends iOS Live Activity
    try { if (id != null) await app.repo?.endWorkout(id); } catch (_) {}
    if (!mounted) return;
    if (id != null) {
      Navigator.of(context).pushReplacement(themedRoute((_) => WorkoutDetailScreen(id: id)));
    } else {
      Navigator.of(context).pop();
    }
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final w = app.activeWorkout;
    if (w == null) return const Scaffold(backgroundColor: AppColors.night);
    final hr = w.currentHr;
    final zone = _zoneFor(hr);
    final z = _zones[zone];
    final hrrPct = hr <= 0 ? 0.0 : ((hr / _maxHr).clamp(0.0, 1.0));
    final gapBpm = zone < 5 ? (_zonePct[zone + 1] * _maxHr).ceil() - hr : 0;
    final almost = zone < 5 && hr > 0 && gapBpm > 0 && gapBpm <= 5;
    final calloutOn = _callout != null && DateTime.now().isBefore(_calloutUntil);

    return Theme(
      data: ThemeData.dark().copyWith(scaffoldBackgroundColor: AppColors.night),
      child: Scaffold(
        body: Stack(children: [
          // 1. Zone-tinted studio background, intensity climbs with effort.
          Positioned.fill(child: AnimatedContainer(
            duration: Motion.slow,
            decoration: BoxDecoration(gradient: RadialGradient(
              center: const Alignment(0, -0.15), radius: 1.4,
              colors: [z.color.withValues(alpha: 0.12 + 0.30 * hrrPct), AppColors.night],
            )),
          )),

          // 2. Ember field rising behind the core (count/heat ∝ effort).
          Positioned.fill(child: AnimatedBuilder(
            animation: _fx,
            builder: (context, _) => CustomPaint(painter: _EmberPainter(t: _fx.value, intensity: hrrPct, color: z.color)),
          )),

          // 3. Top: timer + in-the-red streak.
          SafeArea(child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.x5),
            child: Column(children: [
              _pill(AppIcon(Ic.clock, size: 15, color: Colors.white60), _fmt(w.elapsed)),
              if (_redStreak.inSeconds >= 5) ...[
                const SizedBox(height: Sp.x2),
                _pill(AppIcon(Ic.fire, size: 14, color: AppColors.coral),
                    '${_fmt(_redStreak)} in the red', tint: AppColors.coral),
              ],
            ]),
          )),

          // 4. The ember core (beats at your HR).
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Stack(alignment: Alignment.center, children: [
              SizedBox(width: 270, height: 270, child: CustomPaint(
                painter: _ZoneArcPainter(pct: hrrPct, color: z.color))),
              AnimatedBuilder(
                animation: _beat,
                builder: (context, child) {
                  final v = (hr > 160 ? Curves.elasticOut : Curves.easeInOut).transform(_beat.value);
                  final scale = 1.0 + 0.08 * v;
                  final glow = 0.4 + 0.6 * v;
                  return Container(
                    width: 210, height: 210,
                    decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
                      BoxShadow(color: z.color.withValues(alpha: 0.4 * glow), blurRadius: 40 * scale, spreadRadius: 2),
                      BoxShadow(color: z.color.withValues(alpha: 0.15 * glow), blurRadius: 100 * scale, spreadRadius: 10),
                    ]),
                    child: Transform.scale(scale: scale, child: Container(
                      decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.night,
                          border: Border.all(color: z.color.withValues(alpha: 0.35), width: 1.5)),
                      alignment: Alignment.center, child: child,
                    )),
                  );
                },
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(hr > 0 ? '$hr' : '—', style: AppText.display.copyWith(
                      fontSize: 88, color: Colors.white, height: 1, fontWeight: FontWeight.w900)),
                  Text('BPM', style: AppText.overline.copyWith(
                      color: Colors.white38, fontSize: 11, letterSpacing: 5, fontWeight: FontWeight.w800)),
                ]),
              ),
            ]),
            const SizedBox(height: Sp.x8),
            AnimatedDefaultTextStyle(
              duration: Motion.med,
              style: AppText.h2.copyWith(color: z.color, letterSpacing: 3, fontWeight: FontWeight.w900, fontSize: 22),
              child: Text('${z.label} · ${z.name}'.toUpperCase()),
            ),
            const SizedBox(height: Sp.x2),
            // "Almost there" nudge or the playful line.
            SizedBox(height: 22, child: AnimatedSwitcher(
              duration: Motion.med,
              child: almost
                  ? Text('$gapBpm bpm to ${_zones[zone + 1].label} — push',
                      key: ValueKey('almost$gapBpm'),
                      style: AppText.bodySoft.copyWith(color: _zones[zone + 1].color, fontWeight: FontWeight.w700))
                  : Text(_line, key: ValueKey(_line),
                      style: AppText.bodySoft.copyWith(color: Colors.white38)),
            )),
          ])),

          // 5. Zone ladder (right edge).
          Positioned(right: Sp.x4, top: 0, bottom: 0, child: Center(child: _zoneLadder(zone))),

          // 6. Stat panel + hold-to-finish.
          Positioned(left: Sp.x6, right: Sp.x6, bottom: Sp.x8,
              child: _ControlPanel(workout: w, holdController: _hold, ending: _ending, onFinished: _finish)),

          // 7. Celebration confetti (one-shot).
          Positioned.fill(child: IgnorePointer(child: AnimatedBuilder(
            animation: _burst,
            builder: (context, _) => _burst.isAnimating
                ? CustomPaint(painter: _ConfettiPainter(t: _burst.value, particles: _confetti))
                : const SizedBox.shrink(),
          ))),

          // 8. Big ephemeral callout (zone-up / milestone).
          if (calloutOn) Positioned.fill(child: IgnorePointer(child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Spacer(flex: 2),
              Text(_callout!, style: AppText.display.copyWith(
                  fontSize: 46, color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 2)),
              if (_calloutSub != null)
                Text(_calloutSub!, style: AppText.label.copyWith(color: z.color, letterSpacing: 3)),
              const Spacer(flex: 3),
            ]),
          ))),
        ]),
      ),
    );
  }

  Widget _pill(Widget icon, String text, {Color? tint}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: (tint ?? Colors.white).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(color: (tint ?? Colors.white).withValues(alpha: 0.18)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          icon, const SizedBox(width: Sp.x2),
          Text(text, style: AppText.metricSm.copyWith(
              color: tint ?? Colors.white, fontSize: 15, letterSpacing: 0.5,
              fontFeatures: [const FontFeature.tabularFigures()])),
        ]),
      );

  Widget _zoneLadder(int zone) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (int z = 5; z >= 1; z--) ...[
          AnimatedContainer(
            duration: Motion.med,
            width: z == zone ? 16 : 10,
            height: 30,
            decoration: BoxDecoration(
              color: z <= zone ? _zones[z].color.withValues(alpha: z == zone ? 1 : 0.5) : Colors.white12,
              borderRadius: BorderRadius.circular(6),
              boxShadow: z == zone ? [BoxShadow(color: _zones[z].color.withValues(alpha: 0.6), blurRadius: 12)] : null,
            ),
          ),
          if (z > 1) const SizedBox(height: 6),
        ],
      ]);
}

// ── Ember particle field ──────────────────────────────────────────────────────
class _EmberPainter extends CustomPainter {
  final double t;        // 0..1 loop
  final double intensity; // 0..1 (HR reserve)
  final Color color;
  _EmberPainter({required this.t, required this.intensity, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0.02) return;
    final n = (10 + intensity * 46).round();
    final cx = size.width / 2;
    final paint = Paint();
    for (int i = 0; i < n; i++) {
      final phase = ((t + i / n) % 1.0);
      final spread = size.width * (0.16 + 0.20 * intensity);
      final x = cx + math.sin(i * 2.3 + phase * math.pi * 2) * spread * (0.4 + i % 3 * 0.3);
      final y = size.height * 0.78 - phase * size.height * 0.66;
      final op = (1 - phase) * (0.25 + 0.55 * intensity);
      final r = (1.0 + (i % 4)) * (0.8 + intensity);
      paint.color = color.withValues(alpha: op.clamp(0.0, 0.85));
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(_EmberPainter o) => o.t != t || o.intensity != intensity || o.color != color;
}

// ── Zone arc (HR as % of max) ────────────────────────────────────────────────
class _ZoneArcPainter extends CustomPainter {
  final double pct;
  final Color color;
  _ZoneArcPainter({required this.pct, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - 20) / 2;
    final track = Paint()..style = PaintingStyle.stroke..strokeWidth = 6..strokeCap = StrokeCap.round..color = Colors.white10;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), math.pi * 0.7, math.pi * 1.6, false, track);
    final active = Paint()..style = PaintingStyle.stroke..strokeWidth = 9..strokeCap = StrokeCap.round..color = color;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), math.pi * 0.7, math.pi * 1.6 * pct.clamp(0.0, 1.0), false, active);
  }
  @override
  bool shouldRepaint(_ZoneArcPainter o) => o.pct != pct || o.color != color;
}

// ── Confetti ──────────────────────────────────────────────────────────────────
class _Particle {
  final double vx, vy, size, spin;
  final Color color;
  _Particle({required this.vx, required this.vy, required this.color, required this.size, required this.spin});
}

class _ConfettiPainter extends CustomPainter {
  final double t; // 0..1
  final List<_Particle> particles;
  _ConfettiPainter({required this.t, required this.particles});
  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(size.width / 2, size.height * 0.38);
    final paint = Paint();
    for (final p in particles) {
      final x = origin.dx + p.vx * t;
      final y = origin.dy + p.vy * t + 360 * t * t; // gravity
      paint.color = p.color.withValues(alpha: (1 - t).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * t);
      canvas.drawRRect(RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.6), const Radius.circular(1)), paint);
      canvas.restore();
    }
  }
  @override
  bool shouldRepaint(_ConfettiPainter o) => o.t != t;
}

// ── Stat panel + hold-to-finish (kept from the original, lightly adapted) ─────
class _ControlPanel extends StatelessWidget {
  final LiveWorkoutState workout;
  final AnimationController holdController;
  final bool ending;
  final VoidCallback onFinished;
  const _ControlPanel({required this.workout, required this.holdController, required this.ending, required this.onFinished});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(R.card),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
          child: Container(
            padding: const EdgeInsets.all(Sp.x6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(R.card),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              _Stat(label: 'CALORIES', value: workout.calories.round().toString(), unit: 'kcal', icon: Ic.fire),
              _Stat(label: 'STRAIN', value: workout.strain.toStringAsFixed(1), unit: '', icon: Ic.strain),
              // Real steps counted on the live 100 Hz stream, scoped to THIS
              // workout (resets at start, not at connection).
              _Stat(label: 'STEPS',
                  value: context.watch<AppState>().workoutSteps.toString(),
                  unit: '', icon: Ic.run),
            ]),
          ),
        ),
      ),
      const SizedBox(height: Sp.x5),
      GestureDetector(
        onLongPressStart: (_) { holdController.forward(); HapticFeedback.lightImpact(); },
        onLongPressEnd: (_) {
          if (holdController.value >= 1.0) { onFinished(); } else { holdController.reverse(); }
        },
        child: AnimatedBuilder(
          animation: holdController,
          builder: (context, child) {
            final val = holdController.value;
            return Transform.scale(
              scale: 1.0 - 0.05 * val,
              child: Container(
                width: double.infinity, height: 72,
                decoration: BoxDecoration(
                  color: val > 0 ? Colors.white.withValues(alpha: 0.1) : AppColors.nightAlt,
                  borderRadius: BorderRadius.circular(R.pill),
                  border: Border.all(color: Color.lerp(Colors.white10, AppColors.coral, val)!, width: 1.5),
                ),
                child: Stack(alignment: Alignment.center, children: [
                  Positioned.fill(child: FractionallySizedBox(
                    alignment: Alignment.centerLeft, widthFactor: val,
                    child: Container(decoration: BoxDecoration(
                        color: AppColors.coral.withValues(alpha: 0.2 + 0.2 * val),
                        borderRadius: BorderRadius.circular(R.pill))),
                  )),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    AppIcon(Ic.cancel, size: 20, color: Color.lerp(Colors.white24, Colors.white, val)),
                    const SizedBox(width: Sp.x3),
                    Text(ending ? 'FINISHING…' : 'HOLD TO FINISH', style: AppText.label.copyWith(
                        color: Color.lerp(Colors.white38, Colors.white, val),
                        fontWeight: FontWeight.w900, letterSpacing: 3, fontSize: 13)),
                  ]),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class _Stat extends StatelessWidget {
  final String label, value, unit;
  final IconData icon;
  const _Stat({required this.label, required this.value, required this.unit, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      AppIcon(icon, size: 16, color: Colors.white38),
      const SizedBox(height: Sp.x2),
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(value, style: AppText.metric.copyWith(color: Colors.white, fontSize: 24)),
        if (unit.isNotEmpty) ...[const SizedBox(width: 4), Text(unit, style: AppText.caption.copyWith(color: Colors.white38))],
      ]),
      const SizedBox(height: 4),
      Text(label, style: AppText.overline.copyWith(color: Colors.white30, fontSize: 9, letterSpacing: 1)),
    ]);
  }
}
