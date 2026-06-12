// Live workout view — heart rate, zone, calories, and strain during a session.
// Dark theme; long-press to finish.

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class LiveSessionScreen extends StatefulWidget {
  const LiveSessionScreen({super.key});

  @override
  State<LiveSessionScreen> createState() => _LiveSessionScreenState();
}

class _LiveSessionScreenState extends State<LiveSessionScreen>
    with TickerProviderStateMixin {
  late final AnimationController _beatController;
  late final AnimationController _holdController;

  @override
  void initState() {
    super.initState();
    _beatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    _holdController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void dispose() {
    _beatController.dispose();
    _holdController.dispose();
    super.dispose();
  }

  void _onFinish() {
    context.read<AppState>().stopWorkout();
    Navigator.pop(context);
    HapticFeedback.vibrate();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  ({String label, Color color}) _zone(int hr, double age) {
    final maxHr = 220.0 - age;
    final pct = hr / maxHr;
    if (pct < 0.6) return (label: 'Z1 · Warm up', color: AppColors.loadDetraining);
    if (pct < 0.7) return (label: 'Z2 · Fat burn', color: AppColors.good);
    if (pct < 0.8) return (label: 'Z3 · Aerobic', color: AppColors.warn);
    if (pct < 0.9) return (label: 'Z4 · Threshold', color: AppColors.coral);
    return (label: 'Z5 · Max effort', color: AppColors.coralDeep);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final workout = app.activeWorkout;
    if (workout == null) return const Scaffold(backgroundColor: AppColors.night);

    final hr = workout.currentHr;
    final age = (app.user?['age'] as num?)?.toDouble() ?? 30.0;
    final zone = _zone(hr, age);

    // Adjust beat duration based on HR.
    if (hr > 40) {
      _beatController.duration = Duration(milliseconds: 60000 ~/ hr);
    }

    return Theme(
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.night,
      ),
      child: Scaffold(
        body: Stack(
          children: [
            // 1. Deep "Studio" Background: primary zone glow.
            Positioned.fill(
              child: Container(
                color: AppColors.night,
                child: AnimatedContainer(
                  duration: Motion.slow,
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.2),
                      radius: 1.4,
                      colors: [
                        zone.color.withValues(alpha: 0.25),
                        AppColors.night,
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // 2. Timer Top Bar.
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Sp.x6),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Sp.x5, vertical: Sp.x2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(R.pill),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const AppIcon(Ic.clock, size: 16, color: Colors.white60),
                        const SizedBox(width: Sp.x3),
                        Text(
                          _formatDuration(workout.elapsed),
                          style: AppText.metricSm.copyWith(
                              color: Colors.white,
                              fontSize: 19,
                              letterSpacing: 0.5,
                              fontFeatures: [const FontFeature.tabularFigures()]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // 3. Immersive Core: The Ember Pulse.
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      // Target Progress Ring (Outer).
                      SizedBox(
                        width: 330,
                        height: 330,
                        child: CustomPaint(
                          painter: _GoalRingPainter(
                            progress: workout.calories / workout.targetKcal,
                            color: Colors.white.withValues(alpha: 0.05),
                            activeColor: AppColors.coral,
                          ),
                        ),
                      ),

                      // Zone Arc (Inner).
                      SizedBox(
                        width: 270,
                        height: 270,
                        child: CustomPaint(
                          painter: _ZoneArcPainter(
                            hr: hr,
                            maxHr: 220.0 - age,
                            color: zone.color,
                          ),
                        ),
                      ),

                      // THE PULSE (Layered Animation).
                      AnimatedBuilder(
                        animation: _beatController,
                        builder: (context, child) {
                          final v = _beatController.value;
                          final curve = hr > 160 ? Curves.elasticOut : Curves.easeInOut;
                          final animatedV = curve.transform(v);
                          
                          final scale = 1.0 + (0.08 * animatedV);
                          final glowOpacity = 0.4 + (0.6 * animatedV);
                          
                          return Container(
                            width: 210,
                            height: 210,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: zone.color.withValues(alpha: 0.4 * glowOpacity),
                                  blurRadius: 40 * scale,
                                  spreadRadius: 2,
                                ),
                                BoxShadow(
                                  color: zone.color.withValues(alpha: 0.15 * glowOpacity),
                                  blurRadius: 100 * scale,
                                  spreadRadius: 10,
                                ),
                              ],
                            ),
                            child: Transform.scale(
                              scale: scale,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.night,
                                  border: Border.all(
                                    color: zone.color.withValues(alpha: 0.3),
                                    width: 1.5,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: child,
                              ),
                            ),
                          );
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              hr > 0 ? hr.toString() : '—',
                              style: AppText.display.copyWith(
                                fontSize: 92,
                                color: Colors.white,
                                height: 1,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'BPM',
                              style: AppText.overline.copyWith(
                                color: Colors.white38,
                                fontSize: 11,
                                letterSpacing: 5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Sp.x10),
                  const SizedBox(height: 8),
                  
                  // Zone Indicator.
                  AnimatedDefaultTextStyle(
                    duration: Motion.med,
                    style: AppText.h2.copyWith(
                      color: zone.color,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                    ),
                    child: Text(zone.label.toUpperCase()),
                  ),
                  const SizedBox(height: Sp.x2),
                  Text(
                    hr > 0 ? 'LEVEL: ${(hr / (220 - age) * 100).round()}%' : 'READY TO WORK?',
                    style: AppText.bodySoft.copyWith(
                      color: Colors.white24,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            // 4. Floating Stat Panel.
            Positioned(
              left: Sp.x6,
              right: Sp.x6,
              bottom: Sp.x10,
              child: _ControlPanel(
                workout: workout,
                holdController: _holdController,
                onFinished: _onFinish,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  final LiveWorkoutState workout;
  final AnimationController holdController;
  final VoidCallback onFinished;

  const _ControlPanel({
    required this.workout,
    required this.holdController,
    required this.onFinished,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(R.card),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
            child: Container(
              padding: const EdgeInsets.all(Sp.x8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(R.card),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _Stat(
                    label: 'CALORIES',
                    value: workout.calories.round().toString(),
                    unit: 'kcal',
                    icon: Ic.fire,
                  ),
                  _Stat(
                    label: 'STRAIN',
                    value: workout.strain.toStringAsFixed(1),
                    unit: '',
                    icon: Ic.strain,
                  ),
                  _Stat(
                    label: 'BURN RATE',
                    value: (workout.calories /
                            math.max(1, workout.elapsed.inMinutes))
                        .toStringAsFixed(1),
                    unit: 'm',
                    icon: Ic.pulse,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: Sp.x6),

        // High-End Hold to Finish.
        GestureDetector(
          onLongPressStart: (_) {
            holdController.forward();
            HapticFeedback.lightImpact();
          },
          onLongPressEnd: (_) {
            if (holdController.value < 1.0) {
              holdController.reverse();
            } else {
              onFinished();
            }
          },
          child: AnimatedBuilder(
            animation: holdController,
            builder: (context, child) {
              final val = holdController.value;
              final scale = 1.0 - (0.05 * val);
              
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: double.infinity,
                  height: 72,
                  decoration: BoxDecoration(
                    color: val > 0 ? Colors.white.withValues(alpha: 0.1) : AppColors.nightAlt,
                    borderRadius: BorderRadius.circular(R.pill),
                    border: Border.all(
                      color: Color.lerp(Colors.white10, AppColors.coral, val)!,
                      width: 1.5,
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: val,
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.coral.withValues(alpha: 0.2 + (0.2 * val)),
                              borderRadius: BorderRadius.circular(R.pill),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AppIcon(Ic.cancel,
                              size: 20,
                              color: Color.lerp(
                                  Colors.white24, Colors.white, val)),
                          const SizedBox(width: Sp.x3),
                          Text(
                            'HOLD TO FINISH',
                            style: AppText.label.copyWith(
                              color: Color.lerp(
                                  Colors.white38, Colors.white, val),
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData icon;

  const _Stat({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppIcon(icon, size: 16, color: Colors.white38),
        const SizedBox(height: Sp.x2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: AppText.metric.copyWith(color: Colors.white, fontSize: 24)),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(unit, style: AppText.caption.copyWith(color: Colors.white38)),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(label,
            style: AppText.overline
                .copyWith(color: Colors.white30, fontSize: 9, letterSpacing: 1)),
      ],
    );
  }
}

class _GoalRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color activeColor;

  _GoalRingPainter({
    required this.progress,
    required this.color,
    required this.activeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - 20) / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawCircle(center, radius, paint);

    if (progress > 0) {
      final activePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..color = activeColor;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        math.pi * 2 * progress.clamp(0.0, 1.0),
        false,
        activePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_GoalRingPainter old) => old.progress != progress;
}

class _ZoneArcPainter extends CustomPainter {
  final int hr;
  final double maxHr;
  final Color color;

  _ZoneArcPainter({
    required this.hr,
    required this.maxHr,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - 20) / 2;
    final pct = (hr / maxHr).clamp(0.0, 1.0);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..color = Colors.white10;

    // Draw background track for zone (bottom half only).
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi * 0.7,
      math.pi * 1.6,
      false,
      paint,
    );

    final activePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi * 0.7,
      math.pi * 1.6 * pct,
      false,
      activePaint,
    );
  }

  @override
  bool shouldRepaint(_ZoneArcPainter old) => old.hr != hr || old.color != color;
}
