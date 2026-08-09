// Live workout — an interactive, HR-reactive screen that reacts to your heart in
// real time. Everything here is driven by REAL live HR (device.liveHr via BLE):
// an ember core that beats at your pulse, a zone ladder with "almost there" nudges,
// an "in the red" streak, milestone bursts, and a playful line engine. Code-drawn
// (CustomPaint), haptics-only, open-ended. Long-press to finish → breakdown.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/payloads.dart';
import '../../state/app_state.dart';
import '../../state/units_controller.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import 'workout_share_card.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import '../kit/route_map.dart';
import '../design/arc_gauge.dart';
import '../design/motion.dart';
import '../design/recap_card.dart' show MedalCard;
import '../workouts/workouts_screen.dart' show WorkoutDetailScreen;
import 'package:flutter_map/flutter_map.dart'
    show MapController, CameraFit, LatLngBounds;
import 'package:latlong2/latlong.dart' show LatLng;
import '../../gps/gps_source.dart';
import '../../gps/route_math.dart' as rmath;
import '../../gps/route_models.dart';
import '../../gps/route_tracker.dart';

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

/// Zone labels. Colours are NOT baked in here — see [_zones].
const List<(String, String)> _zoneNames = [
  ('Z0', 'Resting'),
  ('Z1', 'Warm-up'),
  ('Z2', 'Fat burn'),
  ('Z3', 'Aerobic'),
  ('Z4', 'Threshold'),
  ('Z5', 'Max effort'),
];

/// Zone metadata for the live session screen.
///
/// TWO bugs lived in the old `final List<_ZoneMeta> _zones = [...]` here:
///
///  1. It resolved `AppColors.zone(z)` from the ACTIVE palette, but this
///     screen always paints on [AppColors.night] regardless of the app theme.
///     In light mode that handed back hues tuned for a white background and
///     painted them on near-black — the low zones were effectively invisible.
///  2. Being a top-level `final`, it was initialised ONCE at first access and
///     then never re-themed, so even switching themes could not fix it.
///
/// Now it is a function over the dark ramp, evaluated per build.
_ZoneMeta _zoneAt(int z) {
  final i = z.clamp(0, 5);
  return _ZoneMeta(
      _zoneNames[i].$1, _zoneNames[i].$2, AppColors.zoneOnDark(i));
}

/// Indexable shim so existing `_zones[z]` call sites keep reading naturally.
class _ZoneTable {
  const _ZoneTable();
  _ZoneMeta operator [](int z) => _zoneAt(z);
}

const _zones = _ZoneTable();
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
  String _line = '';
  int _lineSeed = 0;
  String? _callout;                       // ephemeral big banner ("ZONE 4")
  String? _calloutSub;
  DateTime _calloutUntil = DateTime.fromMillisecondsSinceEpoch(0);
  final List<_Particle> _confetti = [];
  final _rand = math.Random();
  bool _ending = false;
  // Map is the PRIMARY view once a route is discovered (the first GPS fix
  // lands) — no toggle-hunting required. `_showMap` still exists as the
  // user's explicit override once they've tapped the toggle at least once;
  // until then the effective visibility just follows whether a route exists
  // (see `_mapVisible`).
  bool _showMap = false;
  bool _userToggledMap = false;
  RouteTracker? _observedTracker;

  /// Attach a one-time listener to whichever [RouteTracker] instance is
  /// currently live, so the map can auto-switch to primary the moment a
  /// route is discovered (first GPS fix) without the user having to find and
  /// tap a toggle. Cheap identity check — a no-op after the first attach for
  /// a given tracker instance.
  void _attachRouteObserverIfNeeded(RouteTracker? tracker) {
    if (tracker == null || tracker == _observedTracker) return;
    _observedTracker = tracker;
    tracker.path.addListener(_onRoutePathTick);
  }

  void _onRoutePathTick() {
    if (_userToggledMap || !mounted) return;
    final hasRoute = _observedTracker?.path.value.isNotEmpty ?? false;
    if (hasRoute != _showMap) {
      setState(() => _showMap = hasRoute);
      _syncDecorativeAnimations();
    }
  }

  /// Park the purely decorative animations while the map is the primary view.
  ///
  /// `_beat` (HR pulse) and `_fx` (ember field) are `repeat()`-forever
  /// controllers. Their painters are already gated behind `if (!mapOn)`, but a
  /// running Ticker keeps requesting frames regardless — so a 90-minute ride
  /// spent entirely on the map view still drove a 60 fps vsync loop the whole
  /// time, burning battery and generating heat for pixels nobody was drawing.
  /// Stopping the controllers stops the frame requests; they resume the moment
  /// the athlete flips back to the ring view.
  void _syncDecorativeAnimations() {
    final onMap = _showMap;
    if (onMap) {
      if (_beat.isAnimating) _beat.stop();
      if (_fx.isAnimating) _fx.stop();
    } else {
      if (!_beat.isAnimating) _beat.repeat(reverse: true);
      if (!_fx.isAnimating) _fx.repeat();
    }
  }

  @override
  void initState() {
    super.initState();
    _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
    _hold = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _fx = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
    _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _app = context.read<AppState>();
      _app!.addListener(_onTick);
      _onTick();
    });
  }

  @override
  void dispose() {
    _app?.removeListener(_onTick);
    _observedTracker?.path.removeListener(_onRoutePathTick);
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
    // No kcal milestones for an unanchored profile — celebrating a number
    // we refuse to display would be the fabrication back by another door.
    final kcal = w.caloriesOrNull;
    if (kcal != null) {
      final kcalStep = (kcal ~/ 100) * 100;
      if (kcalStep >= 100) _milestone('k$kcalStep', '$kcalStep KCAL', "Burning clean.", AppColors.coral);
    }
    // Announce on a new SMOOTHED peak (not raw instantaneous hr), so a transient
    // spike can't fire a spurious "NEW MAX"; the dedup key gates one per value.
    if (w.elapsed.inSeconds > 90 && w.maxHrSeen > 0 && w.maxHrSeen >= (_maxHr * 0.8)) {
      _milestone('mhr${w.maxHrSeen}', 'NEW MAX · ${w.maxHrSeen}',
          "Highest your heart's gone today.", AppColors.coralDeep);
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

  /// Announce a milestone ONCE per session.
  ///
  /// The dedup set lives on the workout, not on this State: leaving the screen
  /// and coming back disposes and rebuilds this widget, which used to reset a
  /// screen-local set and re-fire "5 MINUTES" (banner + haptic + confetti)
  /// every single time the athlete returned to the live screen.
  void _milestone(String key, String big, String sub, Color c) {
    final fired = _app?.activeWorkout?.firedMilestones;
    if (fired == null || !fired.add(key)) return;
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
    // Snapshot the live totals BEFORE stopWorkout() clears them — the finish
    // card counts up from these, then enriches from getWorkout(id).
    final w = app.activeWorkout;
    final snap = WorkoutFinishSnapshot(
      type: w?.type ?? widget.type,
      duration: w?.elapsed ?? Duration.zero,
      peakHr: w?.maxHrSeen ?? 0,
      calories: w?.caloriesOrNull,
      strain: w?.strain,
      steps: app.workoutStepsMeasured,
    );
    // AWAIT: stopWorkout flushes the GPS route tail; navigating before it
    // completes raced the finish screen's route load (missing tail / no map).
    await app.stopWorkout(); // clears local + ends iOS Live Activity
    try { if (id != null) await app.repo?.endWorkout(id); } catch (_) {}
    if (!mounted) return;
    if (id != null) {
      Navigator.of(context).pushReplacement(
        themedRoute((_) => WorkoutFinishScreen(id: id, snapshot: snap),
            name: 'WorkoutFinishScreen'),
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  /// H:MM:SS once past the hour, MM:SS before it — the big-clock format of
  /// the reference live screens.
  String _fmt(Duration d) {
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final w = app.activeWorkout;
    if (w == null) return const Scaffold(backgroundColor: AppColors.night);
    _attachRouteObserverIfNeeded(app.routeTracker);
    final hr = w.currentHr;
    final zone = _zoneFor(hr);
    final z = _zones[zone];
    final hrrPct = hr <= 0 ? 0.0 : ((hr / _maxHr).clamp(0.0, 1.0));
    final gapBpm = zone < 5 ? (_zonePct[zone + 1] * _maxHr).ceil() - hr : 0;
    final almost = zone < 5 && hr > 0 && gapBpm > 0 && gapBpm <= 5;
    final calloutOn = _callout != null && DateTime.now().isBefore(_calloutUntil);
    final mapOn = _showMap && app.routeTracker != null;

    // The map/heart view switch lives in the SHEET, next to the stats — not
    // floating over the map. On the map it sat in the top-right corner, which
    // is both the least reachable part of a phone one-handed mid-run and prime
    // map real estate. Down here it reads as what it is: a control for what
    // the panel above is showing.
    final viewToggle = app.routeTracker == null
        ? null
        : _ViewToggle(
            showingMap: _showMap,
            onChanged: (wantMap) {
              if (wantMap == _showMap) return;
              setState(() {
                _showMap = wantMap;
                _userToggledMap = true;
              });
              _syncDecorativeAnimations();
            },
          );

    // ── LAYOUT CONTRACT ──────────────────────────────────────────────────
    // Two regions in a Column: a bounded HERO (map or heart-rate core) and a
    // METRIC SHEET. They are siblings, so the sheet can never sit on top of
    // the hero and the hero can never grow under the sheet.
    //
    // This screen used to be one flat Stack of absolutely-positioned layers
    // with no layout relationship between them, and they collided on real
    // devices: the map's re-centre button was pinned `bottom: 96` while the
    // control panel is far taller than that, so it rendered UNDERNEATH the
    // panel; the centred recording pill ran under the 44 px map toggle; and
    // in ring mode the fixed 270 px core had nothing stopping it colliding
    // with the timer above and the panel below on a shorter phone.
    //
    // Anything that genuinely floats (re-centre, callout, confetti) is now
    // Positioned INSIDE the hero's own Stack, so it is clipped to the hero
    // and anchored to the hero's edges — never the screen's.
    return Theme(
      data: ThemeData.dark().copyWith(scaffoldBackgroundColor: AppColors.night),
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  if (mapOn)
                    Positioned.fill(
                      child: _LiveRouteMap(
                        tracker: app.routeTracker!,
                        elapsed: w.elapsed,
                        hr: hr,
                        zoneIndex: zone,
                        showStatBar: false,
                      ),
                    )
                  else
                    Positioned.fill(
                      child: _HeroCore(
                        hr: hr,
                        zone: zone,
                        hrrPct: hrrPct,
                        elapsed: w.elapsed,
                        redStreak: _redStreak,
                        line: _line,
                        almostText: almost
                            ? '$gapBpm bpm to ${_zones[zone + 1].label} — push'
                            : null,
                        almostColor:
                            zone < 5 ? _zones[zone + 1].color : z.color,
                        beat: _beat,
                        fx: _fx,
                        fmt: _fmt,
                      ),
                    ),

                  // Top rail — ONE row, space-between. The state chip and the
                  // map toggle are laid out against each other, so no amount
                  // of text can push one under the other (the chip is
                  // Flexible and ellipsizes instead).
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                            Sp.x5, Sp.x3, Sp.x5, 0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Flexible(
                              child: _SessionStateChip(
                                locationIssue: app.routeTracker == null
                                    ? app.routeLocationIssue
                                    : null,
                                onFixLocation: () async {
                                  final issue = app.routeLocationIssue;
                                  if (issue == null) return;
                                  if (issue == GpsPermissionStatus.denied) {
                                    await app.retryRouteTracking();
                                  } else {
                                    await GpsSource.openSettingsFor(issue);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Ephemeral zone-up / milestone callout.
                  if (calloutOn)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _callout!,
                                textAlign: TextAlign.center,
                                style: AppText.display.copyWith(
                                  fontSize: 46,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 2,
                                ),
                              ),
                              if (_calloutSub != null)
                                Text(
                                  _calloutSub!,
                                  textAlign: TextAlign.center,
                                  style: AppText.label.copyWith(
                                      color: z.color, letterSpacing: 3),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Confetti stays clipped to the hero.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _burst,
                        builder: (context, _) => _burst.isAnimating
                            ? CustomPaint(
                                painter: _ConfettiPainter(
                                    t: _burst.value, particles: _confetti))
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // The metric sheet. Owns the bottom safe area itself.
            mapOn
                ? _GpsControlPanel(
                    tracker: app.routeTracker!,
                    elapsed: w.elapsed,
                    hr: hr,
                    zoneIndex: zone,
                    workout: w,
                    holdController: _hold,
                    ending: _ending,
                    onFinished: _finish,
                    viewToggle: viewToggle,
                  )
                : _SessionSheet(
                    workout: w,
                    holdController: _hold,
                    ending: _ending,
                    onFinished: _finish,
                    hr: hr,
                    zoneIndex: zone,
                    elapsed: w.elapsed,
                    viewToggle: viewToggle,
                  ),
          ],
        ),
      ),
    );
  }

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
/// Feeds the RouteTracker's live distance/speed into [_SessionSheet] without
/// wrapping the whole hero (map, callouts, confetti) in ValueListenableBuilders
/// it does not need.
class _GpsControlPanel extends StatelessWidget {
  final RouteTracker tracker;
  final Duration elapsed;
  final int hr;
  final int zoneIndex;
  final LiveWorkoutState workout;
  final AnimationController holdController;
  final bool ending;
  final VoidCallback onFinished;
  final Widget? viewToggle;
  const _GpsControlPanel({
    required this.tracker,
    required this.elapsed,
    required this.hr,
    required this.zoneIndex,
    required this.workout,
    required this.holdController,
    required this.ending,
    required this.onFinished,
    this.viewToggle,
  });

  @override
  Widget build(BuildContext context) {
    final units = context.watch<UnitsController>();
    return ValueListenableBuilder<double>(
      valueListenable: tracker.distanceMeters,
      builder: (context, meters, _) => ValueListenableBuilder<double?>(
        valueListenable: tracker.currentSpeedMps,
        builder: (context, speedMps, _) {
          final movingSec = tracker.movingSeconds;
          // MOVING pace, never elapsed pace.
          //
          // This used to fall back to `elapsed` whenever movingSec was 0, which
          // produced the "40:32 /km even though I barely moved" reading: a
          // couple of hundred metres divided by every second the athlete had
          // also spent standing still is not a pace, it is an average of
          // walking and waiting. Every serious run/ride app reports pace over
          // moving time for exactly this reason. With no moving time yet,
          // `units.pace` returns "—", which is the honest answer.
          final avgPace = units.pace(meters, movingSec);
          final livePace = units.paceFromSpeed(speedMps);
          // `units.distance` returns e.g. "2.41 km" — split it so the sheet can
          // set the figure and its unit at different weights.
          final distanceText = units.distance(meters);
          final parts = distanceText.split(' ');
          return _SessionSheet(
            workout: workout,
            holdController: holdController,
            ending: ending,
            onFinished: onFinished,
            hr: hr,
            zoneIndex: zoneIndex,
            elapsed: elapsed,
            distance: parts.first,
            distanceUnit: parts.length > 1 ? parts.sublist(1).join(' ') : '',
            pace: livePace == '—' ? avgPace : livePace,
            viewToggle: viewToggle,
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// F2 — cinematic post-workout finish card, on the design system.
//
// Theme-native (Ember on Paper by day, Ember on Char by night). A staggered,
// celebratory reveal: strain count-up → hero stats → zone wipe → HRR self-draw
// → PR pops (PrBadge + confetti + haptic). Shares as a PNG (reusing the recap
// capture pattern) and offers the full breakdown (WorkoutDetailScreen).
// ═══════════════════════════════════════════════════════════════════════════

/// Live totals captured the instant the session ended (before state is cleared).
class WorkoutFinishSnapshot {
  final String type;
  final Duration duration;
  final int peakHr;

  /// Null when the profile lacks the anchors Keytel needs — same contract as
  /// [strain] and [steps] below, so the finish card omits the stat instead of
  /// printing a kcal figure computed for a stand-in body.
  final int? calories;

  /// Null when the profile lacked an anchor the Banister score needs. Kept
  /// nullable all the way to the finish card: a `?? 0` here would print a
  /// confident "0.0" for a session that was simply never scored.
  final double? strain;
  /// Null when nothing gait-capable was measured for the workout — the finish
  /// card omits the stat rather than showing a zero.
  final int? steps;
  const WorkoutFinishSnapshot({
    required this.type,
    required this.duration,
    required this.peakHr,
    required this.calories,
    required this.strain,
    required this.steps,
  });
}

class WorkoutFinishScreen extends StatefulWidget {
  final String id;
  final WorkoutFinishSnapshot snapshot;

  /// Preview-only: inject a route directly, bypassing the normal
  /// AppState/repo fetch in `_load()`. Lets the Design Gallery (and tests)
  /// render the real hero-map layout with static fake data, no live workout
  /// or repo required. `previewMaxHr` is used for the route's HR-zone
  /// colouring when injected this way (falls back to 190 if omitted).
  final WorkoutRoute? previewRoute;
  final int? previewMaxHr;

  const WorkoutFinishScreen({
    super.key,
    required this.id,
    required this.snapshot,
    this.previewRoute,
    this.previewMaxHr,
  });

  @override
  State<WorkoutFinishScreen> createState() => _WorkoutFinishScreenState();
}

class _WorkoutFinishScreenState extends State<WorkoutFinishScreen>
    with TickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _confetti = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  final _rand = math.Random();
  final List<_Particle> _particles = [];

  Map<String, dynamic>? _detail;
  List<RouteVertex>? _routeVertices;
  WorkoutRoute? _route; // full route (distance/pace/splits) for the hero map
  int _maxHr = 190; // overwritten from AppState/previewMaxHr once known
  bool _prWorkout = false;
  bool _prSteps = false;
  bool _confettiFired = false;

  @override
  void initState() {
    super.initState();
    _reveal.addListener(_maybeCelebrate);
    _reveal.forward();
    if (widget.previewRoute != null) {
      // Preview path (Design Gallery / tests): skip the AppState/repo fetch
      // entirely for route data — everything else in _load() still no-ops
      // gracefully without an AppState above, same as it always has.
      _maxHr = widget.previewMaxHr ?? _maxHr;
      _route = widget.previewRoute;
      _routeVertices = rmath.buildVertices(
        widget.previewRoute!.points,
        widget.previewRoute!.hr,
        _maxHr,
      );
    }
    _load();
  }

  @override
  void dispose() {
    _reveal.removeListener(_maybeCelebrate);
    _reveal.dispose();
    _confetti.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Graceful without an AppState above (pure snapshot render, e.g. tests):
    // the card still shows the live totals it was handed.
    AppState? app;
    try {
      app = context.read<AppState>();
    } catch (_) {
      return;
    }
    final api = app.repo;
    if (api == null) return;
    try {
      final d = await api.getWorkout(widget.id);
      RecordsData? recs;
      try {
        recs = RecordsData.fromJson(await api.getRecords());
      } catch (_) {}
      // Load the recorded GPS route (run/ride/walk); null when none. Skipped
      // when a preview route was injected (Design Gallery / tests) — that
      // path already set _route/_routeVertices/_maxHr in initState().
      List<RouteVertex>? verts;
      WorkoutRoute? fetchedRoute;
      int? fetchedMaxHr;
      if (widget.previewRoute == null) {
        try {
          final route = await api.getWorkoutRoute(widget.id);
          if (route != null && route.hasPath && mounted) {
            fetchedMaxHr = context.read<AppState>().maxHr;
            fetchedRoute = route;
            verts = rmath.buildVertices(route.points, route.hr, fetchedMaxHr);
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _detail = d;
        if (widget.previewRoute == null) {
          _routeVertices = verts;
          _route = fetchedRoute;
          if (fetchedMaxHr != null) _maxHr = fetchedMaxHr;
        }
        if (recs != null) {
          final s = widget.snapshot;
          final strain = (d['strain'] as num?)?.toDouble() ?? s.strain;
          final tw = recs.record('top_workout');
          _prWorkout = tw != null &&
              strain != null &&
              strain > 0 &&
              (strain - tw.value).abs() < 0.15;
          final ms = recs.record('most_steps');
          // Prefer the PERSISTED count, like the build path does — the snapshot
          // can be empty for a workout whose row already carries real steps.
          final steps = (d['steps'] as num?)?.toInt() ?? s.steps;
          // An unmeasured workout can't set a step record.
          _prSteps = ms != null &&
              steps != null &&
              steps > 0 &&
              (steps - ms.value).abs() < 1.5;
        }
      });
    } catch (_) {}
  }

  void _maybeCelebrate() {
    if (_confettiFired || _reveal.value < 0.78) return;
    if (!(_prWorkout || _prSteps)) return;
    _confettiFired = true;
    HapticFeedback.mediumImpact();
    _spawnConfetti();
    _confetti.forward(from: 0);
  }

  void _spawnConfetti() {
    _particles
      ..clear()
      ..addAll(List.generate(46, (_) {
        final ang = _rand.nextDouble() * math.pi * 2;
        final spd = 120 + _rand.nextDouble() * 260;
        return _Particle(
          vx: math.cos(ang) * spd,
          vy: math.sin(ang) * spd,
          // Theme-visible confetti: ember + deep ember + gold read on both
          // paper and char (pure white vanished on the light background).
          color: [AppColors.glow1, AppColors.coralDeep, AppColors.warn][
              _rand.nextInt(3)],
          size: 4 + _rand.nextDouble() * 5,
          spin: (_rand.nextDouble() - 0.5) * 12,
        );
      }));
  }

  double _seg(double a, double b) =>
      Interval(a, b, curve: Curves.easeOutCubic).transform(_reveal.value);

  /// Stage a section into the reveal: fades and lifts [child] over the
  /// [from]..[to] slice of the timeline. The child is built ONCE and handed to
  /// AnimatedBuilder as its `child`, so per-frame work is a single Opacity +
  /// Transform — never a subtree rebuild. Anything whose CONTENT counts up with
  /// the animation (the hero numbers) uses its own builder instead.
  Widget _reveals(double from, double to, Widget child) => AnimatedBuilder(
        animation: _reveal,
        child: child,
        builder: (context, built) {
          final p = _seg(from, to);
          return Opacity(
            opacity: p,
            child: Transform.translate(
              offset: Offset(0, 14 * (1 - p)),
              child: built,
            ),
          );
        },
      );

  String _dur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final d = _detail;
    final strain = (d?['strain'] as num?)?.toDouble() ?? s.strain;
    final peak = (d?['max_hr'] as num?)?.toInt() ?? s.peakHr;
    final avg = (d?['avg_hr'] as num?)?.toInt();
    final kcal = (d?['calories'] as num?)?.toInt() ?? s.calories;
    final steps = (d?['steps'] as num?)?.toInt() ?? s.steps;
    final bands = (d?['zone_bands'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    final curve = (d?['recovery_curve'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    // GPS-tagged workout (run/ride/walk) with a real recorded route → the map
    // is the hero, Strava-style, right under the header — not a small
    // thumbnail buried at the end among the strain/zone/PR cards.
    final hasRoute = _route != null && _route!.hasPath;

    // PERFORMANCE: the ListView is deliberately NOT wrapped in one big
    // AnimatedBuilder any more. It used to be — which meant every frame of the
    // 2.6 s reveal rebuilt the entire screen, including the FlutterMap and (via
    // RouteCard) a full O(N) re-derivation of the route geometry. On an hour-long
    // ride that was hundreds of thousands of trig ops and allocations per second,
    // and it is the single reason this screen felt broken.
    //
    // Now each section owns a small [_Reveal] that animates only opacity and
    // offset around an already-built `child`, so the expensive subtrees are
    // constructed exactly once.
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  Sp.screen, Sp.x6, Sp.screen, Sp.x10),
              children: [
                // Kept as a RepaintBoundary purely to isolate this subtree's
                // repaints — it is no longer a capture target. Sharing now
                // composes its own image (workout_share_card.dart) instead of
                // rasterising this screen.
                RepaintBoundary(
                  child: Container(
                    color: AppColors.background,
                    padding: const EdgeInsets.symmetric(vertical: Sp.x2),
                    child: Column(
                      children: [
                        _header(s),
                        if (hasRoute) ...[
                          const SizedBox(height: Sp.x5),
                          _heroRoute(),
                          const SizedBox(height: Sp.x5),
                          _routeStatRow(),
                        ],
                        const SizedBox(height: Sp.x6),
                        _strainGauge(strain),
                        const SizedBox(height: Sp.x7),
                        _heroStats(peak, avg, kcal, steps),
                        const SizedBox(height: Sp.x7),
                        _zoneCard(bands),
                        if (hasRoute) ...[
                          const SizedBox(height: Sp.x5),
                          _splitsCard(),
                        ],
                        if (curve.isNotEmpty) ...[
                          const SizedBox(height: Sp.x5),
                          _hrrCard(curve),
                        ],
                        if (_prWorkout || _prSteps) ...[
                          const SizedBox(height: Sp.x5),
                          _prBadges(),
                        ],
                        // The old small map thumbnail only shows for
                        // non-GPS workouts / no route (its own graceful
                        // empty state) — a real route is already the hero
                        // above, not duplicated down here.
                        if (!hasRoute) ...[
                          const SizedBox(height: Sp.x5),
                          _mapSlot(),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Sp.x7),
                _actions(),
              ],
            ),
          ),
          // Confetti — only after a PR pops.
          if (_confetti.isAnimating || _confetti.value > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _confetti,
                  builder: (context, _) => CustomPaint(
                    painter: _ConfettiPainter(
                      t: _confetti.value,
                      particles: _particles,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(WorkoutFinishSnapshot s) {
    final label = s.type.isEmpty
        ? 'Workout'
        : s.type[0].toUpperCase() + s.type.substring(1);
    return _reveals(
      0.0,
      0.3,
      Column(
        children: [
          Text('$label complete', style: AppText.h1),
          const SizedBox(height: Sp.x1),
          Text(_dur(s.duration), style: AppText.bodySoft),
        ],
      ),
    );
  }

  /// The 0–21 strain dial. [strain] is null for a session the profile could
  /// not anchor — the arc sits empty and the readout is a dash, rather than a
  /// full-looking gauge over a fabricated number.
  Widget _strainGauge(double? strain) => Center(
        child: ArcGauge(
          value: strain == null ? 0.0 : (strain / 21).clamp(0.0, 1.0),
          color: AppColors.accent,
          size: 176,
          stroke: 15,
          sweepFraction: 0.75,
          endDot: true,
          // Only the counting number rebuilds — not the gauge around it.
          center: AnimatedBuilder(
            animation: _reveal,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    strain == null
                        ? '—'
                        : (strain * _seg(0.0, 0.5)).toStringAsFixed(1),
                    style: AppText.display),
                Text('STRAIN', style: AppText.overline),
              ],
            ),
          ),
        ),
      );

  /// These figures COUNT UP with the reveal, so unlike the other sections they
  /// legitimately rebuild per frame — but it is a handful of Text widgets, not
  /// a map or a route re-derivation.
  Widget _heroStats(int peak, int? avg, int? kcal, int? steps) {
    Widget stat(String v, String label) =>
        Expanded(child: _FinishStat(v, label));
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, _) {
        final p = _seg(0.15, 0.6);
        return Opacity(
          opacity: p,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - p)),
            child: Row(
              children: [
                stat(peak > 0 ? '${(peak * p).round()}' : '—', 'PEAK BPM'),
                stat(avg != null ? '${(avg * p).round()}' : '—', 'AVG BPM'),
                stat(kcal != null ? '${(kcal * p).round()}' : '—', 'KCAL'),
                if (steps != null && steps > 0)
                  stat('${(steps * p).round()}', 'STEPS'),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _zoneCard(List<Map> bands) => AnimatedBuilder(
        animation: _reveal,
        builder: (context, _) => _zoneCardBody(bands, _seg(0.4, 0.7)),
      );

  Widget _zoneCardBody(List<Map> bands, double wipe) {
    final vals = [for (final b in bands) (b['min'] as num?)?.toDouble() ?? 0];
    final colors = [for (int i = 0; i < bands.length; i++) AppColors.zone(i)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('TIME IN ZONES', style: AppText.overline),
        const SizedBox(height: Sp.x3),
        ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: wipe.clamp(0.001, 1.0),
            child: vals.any((v) => v > 0)
                ? SegmentBar(vals, colors, height: 16)
                : Container(
                    height: 16,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(R.pill),
                    ),
                  ),
          ),
        ),
        if (bands.isNotEmpty && wipe > 0.9) ...[
          const SizedBox(height: Sp.x3),
          Wrap(
            spacing: Sp.x4,
            runSpacing: Sp.x2,
            children: [
              for (int i = 0; i < bands.length; i++)
                if ((bands[i]['min'] as num? ?? 0) > 0)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: AppColors.zone(i),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('Z${bands[i]['zone']} ${bands[i]['pct'] ?? 0}%',
                          style: AppText.caption
                              .copyWith(color: AppColors.inkSoft)),
                    ],
                  ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _hrrCard(List<Map> curve) => AnimatedBuilder(
        animation: _reveal,
        builder: (context, _) => _hrrCardBody(curve, _seg(0.55, 0.85)),
      );

  Widget _hrrCardBody(List<Map> curve, double p) {
    // Build normalized points: x by sec, y by drop (more drop → higher).
    final pts = <Offset>[const Offset(0, 0)];
    var maxSec = 1.0, maxDrop = 1.0;
    for (final c in curve) {
      final sec = (c['sec'] as num?)?.toDouble() ?? 0;
      final drop = (c['drop'] as num?)?.toDouble() ?? 0;
      maxSec = math.max(maxSec, sec);
      maxDrop = math.max(maxDrop, drop);
      pts.add(Offset(sec, drop));
    }
    final norm = [
      for (final o in pts) Offset(o.dx / maxSec, 1 - (o.dy / maxDrop)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HEART-RATE RECOVERY', style: AppText.overline),
        const SizedBox(height: Sp.x3),
        SizedBox(
          height: 70,
          width: double.infinity,
          child: CustomPaint(
            painter: _HrrCurvePainter(
              points: norm,
              progress: p,
              color: AppColors.good,
            ),
          ),
        ),
        const SizedBox(height: Sp.x2),
        Opacity(
          // Same timeline slice, read from the p already threaded in.
          opacity: Interval(0.75, 0.9, curve: Curves.easeOutCubic)
              .transform(_reveal.value),
          child: Row(
            children: [
              for (final c in curve)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('−${(c['drop'] as num?)?.round() ?? 0}',
                          style: AppText.metricSm.copyWith(fontSize: 18)),
                      Text('${((c['sec'] as num?)?.toInt() ?? 0) ~/ 60} min',
                          style: AppText.captionMuted),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// PRs land as the refs' engraved medal cards (restrained metal on ink),
  /// with one slow celebrate pass — the confetti burst stays the only fanfare.
  Widget _prBadges() => AnimatedBuilder(
        animation: _reveal,
        child: _prBadgesBody(),
        builder: (context, built) {
          final pop =
              Curves.easeOutBack.transform(_seg(0.75, 1.0).clamp(0.0, 1.0));
          return Transform.scale(scale: pop.clamp(0.0, 1.0), child: built);
        },
      );

  Widget _prBadgesBody() {
    return Column(
      children: [
        if (_prWorkout)
          const MedalCard(
            medal: 'PR',
            overline: 'Personal record',
            title: 'Hardest workout yet',
            subtitle: 'Your highest strain on record',
          ).dsCelebrate(),
        if (_prWorkout && _prSteps) const SizedBox(height: Sp.x3),
        if (_prSteps)
          const MedalCard(
            medal: 'PR',
            overline: 'Personal record',
            title: 'Most steps in a workout',
            subtitle: 'Your biggest step count on record',
          ).dsCelebrate(),
      ],
    );
  }

  /// Strava-style hero: the real recorded route as the FIRST thing shown
  /// after the header, not a small thumbnail buried at the end. Reuses
  /// [RouteCard] (map + distance/pace stats) — same widget the workout
  /// detail screen already uses, so this stays visually consistent rather
  /// than reinventing the stat formatting.
  Widget _heroRoute() =>
      _reveals(0.05, 0.4, RouteCard(route: _route!, maxHr: _maxHr));

  /// The three numbers a runner or rider looks for FIRST, given the same
  /// weight as the strain ring rather than buried in RouteCard's footer:
  /// distance, moving time, and pace (runs/walks) or average speed (rides).
  /// Garmin/Strava lead with exactly this row; we had it nowhere on the finish
  /// screen at all.
  Widget _routeStatRow() {
    final route = _route!;
    final units = context.watch<UnitsController>();
    final isRide = _isRideType(widget.snapshot.type);
    final moving = Duration(seconds: route.movingSec);
    final paceText = units.pace(route.distanceMeters, route.movingSec);
    final speeds = [
      for (final p in route.points)
        if (p.speed != null && p.speed! >= 0) p.speed!,
    ];
    final avgSpeed = speeds.isEmpty
        ? null
        : speeds.reduce((a, b) => a + b) / speeds.length;
    final third = isRide && avgSpeed != null
        ? (units.speed(avgSpeed), 'AVG SPEED')
        : (paceText, 'AVG PACE');
    return _reveals(
      0.1,
      0.45,
      Row(
        children: [
          Expanded(
            child: _FinishStat(units.distance(route.distanceMeters), 'DISTANCE'),
          ),
          Expanded(child: _FinishStat(_dur(moving), 'MOVING')),
          Expanded(child: _FinishStat(third.$1, third.$2)),
        ],
      ),
    );
  }

  static bool _isRideType(String t) =>
      t == 'cycling' || t == 'ride' || t == 'bike' || t == 'biking';

  /// Per-km/mi splits — the thing every serious run/ride app shows on the
  /// summary and this screen simply did not have. [SplitsTable] already
  /// existed and was only reachable from the workout detail screen.
  Widget _splitsCard() =>
      _reveals(0.55, 0.85, SplitsTable(route: _route!, maxHr: _maxHr));

  Widget _mapSlot() {
    final verts = _routeVertices;
    if (verts != null && verts.length >= 2) {
      // Real route recorded → static HR-zone-coloured thumbnail.
      return _reveals(0.6, 0.9, RouteMapView(vertices: verts, height: 140));
    }
    // No route (indoor / permission denied / non-GPS type) → graceful empty.
    return _reveals(
      0.6,
      0.9,
      Container(
        height: 96,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(R.cardSm),
          border: Border.all(color: AppColors.divider),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(OsIcon.activity, size: 22, color: AppColors.inkMuted),
              const SizedBox(height: Sp.x2),
              Text('No route recorded', style: AppText.captionMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actions() {
    return _reveals(
      0.85,
      1.0,
      // Share is the PRIMARY action here, not the secondary one it used to be.
      // Finishing a workout you're proud of and wanting to post it is the most
      // common thing to do from this screen; "full breakdown" is the
      // considered, later action and reads fine as a quiet link.
      Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.icon(
              onPressed: _share,
              icon: const Icon(Icons.ios_share_rounded, size: 19),
              label: const Text('Share workout'),
            ),
          ),
          const SizedBox(height: Sp.x3),
          TextButton(
            onPressed: () => Navigator.of(context).pushReplacement(
              themedRoute((_) => WorkoutDetailScreen(id: widget.id),
                  name: 'WorkoutDetailScreen'),
            ),
            child: const Text('Full breakdown'),
          ),
        ],
      ),
    );
  }

  /// Build the share composition and open the preview.
  ///
  /// This used to rasterise `_cardKey` — the entire finish card, header through
  /// PR badges — and hand the PNG straight to the OS sheet. Two problems: it
  /// was a screenshot of a dashboard rather than something worth posting, and
  /// the athlete never saw it before it landed in the composer. Now the image
  /// is composed for sharing (see workout_share_card.dart) and previewed first.
  /// Compose the share image and open the preview.
  ///
  /// This used to rasterise `_cardKey` — the entire finish card, header through
  /// PR badges — and hand the PNG straight to the OS sheet. Two problems: it
  /// was a screenshot of a dashboard rather than something worth posting, and
  /// the athlete never saw it before it landed in the composer.
  ///
  /// The composition itself lives in [buildWorkoutShareData] so this screen and
  /// the workout DETAIL screen produce byte-identical cards for the same
  /// workout — sharing the same run from two places must not give two results.
  Future<void> _share() async {
    final s = widget.snapshot;
    final d = _detail;
    final data = buildWorkoutShareData(
      units: context.read<UnitsController>(),
      type: s.type,
      duration: s.duration,
      when: DateTime.now(),
      maxHr: _maxHr,
      strain: (d?['strain'] as num?)?.toDouble() ?? s.strain,
      calories: (d?['calories'] as num?)?.toInt() ?? s.calories,
      route: _route,
      avgHr: (d?['avg_hr'] as num?)?.toInt(),
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      themedRoute((_) => WorkoutSharePreviewScreen(data: data),
          name: 'WorkoutSharePreviewScreen'),
    );
  }

}

/// Self-drawing HR-recovery polyline — draws up to [progress] of its length.
/// One headline figure on the finish summary: the number in tabular metric
/// type, the label whispered underneath. Same rhythm as the design system's
/// [BigStat]/overline pairing, sized for a three-across row.
class _FinishStat extends StatelessWidget {
  final String value;
  final String label;
  const _FinishStat(this.value, this.label);

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.metric.copyWith(fontSize: 22),
          ),
          const SizedBox(height: 3),
          Text(label, style: AppText.overline.copyWith(fontSize: 9)),
        ],
      );
}

class _HrrCurvePainter extends CustomPainter {
  final List<Offset> points; // normalized 0..1 (y already screen-oriented)
  final double progress; // 0..1
  final Color color;
  _HrrCurvePainter({
    required this.points,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path();
    for (int i = 0; i < points.length; i++) {
      final o = Offset(points[i].dx * size.width, points[i].dy * size.height);
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final m = metrics.first;
    final drawn = m.extractPath(0, m.length * progress.clamp(0.0, 1.0));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawPath(drawn, stroke);
    // A dot at the drawn tip.
    final tip = m.getTangentForOffset(m.length * progress.clamp(0.0, 1.0));
    if (tip != null) {
      canvas.drawCircle(
          tip.position, 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_HrrCurvePainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.points != points;
}

/// The live route map shown when map mode is on: subscribes to the
/// RouteTracker's ValueNotifiers and feeds their latest values into
/// [GpsLiveMapView] (the actual pure rendering, shared with the Design
/// Gallery preview). `hr`/`zoneIndex` come from the parent screen's own HR
/// state, not from the tracker.
class _LiveRouteMap extends StatelessWidget {
  final RouteTracker tracker;
  final Duration elapsed;
  final int hr;
  final int zoneIndex;
  // False in the real live session — the metric sheet below the map shows
  // these same live stats, so a second bar on the map would duplicate them.
  // True (the default) for the Design Gallery's standalone preview, which has
  // no sheet of its own; it also switches on the map's own recording pill and
  // shifts the re-centre button up to clear the bar.
  final bool showStatBar;
  const _LiveRouteMap({
    required this.tracker,
    required this.elapsed,
    required this.hr,
    required this.zoneIndex,
    this.showStatBar = true,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<RouteVertex>>(
      valueListenable: tracker.path,
      builder: (context, path, _) => ValueListenableBuilder<LatLng?>(
        valueListenable: tracker.current,
        builder: (context, cur, _) => ValueListenableBuilder<double>(
          valueListenable: tracker.distanceMeters,
          builder: (context, meters, _) => ValueListenableBuilder<double?>(
            valueListenable: tracker.currentSpeedMps,
            builder: (context, speedMps, _) => ValueListenableBuilder<bool>(
              valueListenable: tracker.stalled,
              builder: (context, stalled, _) =>
                  ValueListenableBuilder<String?>(
                valueListenable: tracker.error,
                builder: (context, err, _) => GpsLiveMapView(
                  vertices: path,
                  current: cur,
                  distanceMeters: meters,
                  currentSpeedMps: speedMps,
                  movingSeconds: tracker.movingSeconds,
                  elapsed: elapsed,
                  hr: hr,
                  zoneIndex: zoneIndex,
                  stalled: stalled,
                  error: err,
                  showStatBar: showStatBar,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pure, previewable GPS live-map view — full-bleed HR-zone-coloured route
/// map with a pulsing current-position marker, plus ONE unified Strava-style
/// bottom stat bar: distance, duration, pace, and BPM (zone-coloured). Takes
/// plain values, not a live RouteTracker, so it can be exercised directly in
/// the Design Gallery with static fake data — see [DesignGalleryScreen]'s
/// "Workout preview" section.
///
/// Replaces the old design where this map was a small boxed overlay floating
/// on top of the ember/HR-reactive "core" screen (separate zone ladder, big
/// timer, HR circle all still rendered underneath) — that layering is why it
/// read as badly composed. For a GPS workout this map IS the screen now; the
/// ember core stays for non-GPS workouts, where it's actually the better fit.
class GpsLiveMapView extends StatefulWidget {
  final List<RouteVertex> vertices;
  final LatLng? current;
  final double distanceMeters;
  final double? currentSpeedMps;
  final int movingSeconds;
  final Duration elapsed;
  final int hr;
  final int zoneIndex; // 0..5
  final bool stalled;
  final String? error;
  /// Show the bottom distance/duration/pace/BPM bar. Default true (Design
  /// Gallery standalone preview); the real live session passes false since
  /// _ControlPanel shows the same live stats in one merged glass card.
  final bool showStatBar;

  const GpsLiveMapView({
    super.key,
    required this.vertices,
    this.current,
    required this.distanceMeters,
    this.currentSpeedMps,
    required this.movingSeconds,
    required this.elapsed,
    required this.hr,
    required this.zoneIndex,
    this.stalled = false,
    this.error,
    this.showStatBar = true,
  });

  @override
  State<GpsLiveMapView> createState() => _GpsLiveMapViewState();
}

class _GpsLiveMapViewState extends State<GpsLiveMapView> {
  final MapController _map = MapController();
  bool _userPanned = false; // manual pan pauses auto-follow until re-centred
  int _followedCount = 0; // last path length the camera followed to

  static const _zoneLabels = ['Rest', 'Warm', 'Fat', 'Aero', 'Thr', 'Max'];

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  /// Keep the camera on the route as it grows: fit the whole path (small
  /// routes) then track bounds as they expand. Skipped once the user pans;
  /// the re-centre button resumes following. Guarded — the controller isn't
  /// usable until the map has laid out at least once.
  void _follow(List<RouteVertex> path) {
    if (_userPanned || path.length < 2 || path.length == _followedCount) {
      return;
    }
    _followedCount = path.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _userPanned) return;
      // Guard against a zero-sized viewport: fitCamera() computes zoom as a
      // ratio against the map's current rendered pixel size, and flutter_map
      // only clamps NEGATIVE size, not exactly-zero. If this runs before the
      // FlutterMap widget has actually laid out (a real race even inside a
      // postFrameCallback, e.g. right as this screen appears), that division
      // can produce a NaN/Infinite zoom that fitCamera() happily ASSIGNS
      // without throwing — the crash only surfaces a frame later, async, when
      // the tile layer next reacts to the camera and tries to use that zoom.
      // The try/catch below can't catch that; this check prevents it instead.
      final size = _map.camera.nonRotatedSize;
      if (size.x <= 0 || size.y <= 0) return; // next fix retries
      try {
        _map.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(
                [for (final v in path) v.pos]),
            padding: const EdgeInsets.all(36),
            // Same cap as RouteMapView's initial fit — without it, a tight
            // early-workout/short-route bounding box zooms in to near-max
            // (rooftop level) instead of a sane street-scale view.
            maxZoom: kRouteMapMaxAutoZoom,
          ),
        );
      } catch (_) {
        /* map not laid out yet — the next fix retries */
      }
    });
  }

  /// Waiting for the first fix / actively stalled / an explicit stream error
  /// — three distinct states, not just "waiting vs error", because a stalled
  /// (silently dead) stream and an errored one need different next steps from
  /// the athlete (wait vs check Settings) and looked IDENTICAL before ("Hit
  /// or miss, never worked" — a stall with no error just sat on "Waiting for
  /// GPS…" forever with zero explanation).
  String _statusText(bool empty, bool stalled, String? err) {
    if (err != null) return 'GPS signal lost — check that location is on';
    if (stalled) {
      return empty
          ? 'Still waiting for a GPS fix — move to open sky if indoors'
          : 'GPS signal weak — your route may show a gap here';
    }
    return 'Waiting for GPS…';
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final units = context.watch<UnitsController>();
    final path = widget.vertices;
    if (path.isNotEmpty) _follow(path);
    final zone = widget.zoneIndex.clamp(0, 5);
    final zoneColor = AppColors.zoneOnDark(zone);
    // Moving pace, not elapsed pace — see the note in _GpsControlPanel.
    final avgPace = units.pace(widget.distanceMeters, widget.movingSeconds);
    final livePace = units.paceFromSpeed(widget.currentSpeedMps);

    return ClipRRect(
      borderRadius: BorderRadius.circular(R.card),
      child: Stack(
        children: [
          Positioned.fill(
            child: path.isEmpty
                ? Container(
                    color: AppColors.night,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: Sp.x6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white38,
                          ),
                        ),
                        const SizedBox(height: Sp.x3),
                        Text(
                          _statusText(true, widget.stalled, widget.error),
                          textAlign: TextAlign.center,
                          style:
                              AppText.bodySoft.copyWith(color: Colors.white54),
                        ),
                      ],
                    ),
                  )
                : RouteMapView(
                    vertices: path,
                    current: widget.current,
                    interactive: true,
                    controller: _map,
                    onUserPan: () {
                      if (!_userPanned) setState(() => _userPanned = true);
                    },
                    borderRadius: BorderRadius.zero,
                  ),
          ),
          // A signal stall/error AFTER the route is already underway — a thin
          // top banner, not a full takeover, so the map (and stats) stay
          // visible. This map is a raw Positioned.fill (no SafeArea, by
          // design — it's a full-bleed background), so its OWN overlays
          // must add the safe-area top inset themselves or they render
          // under/behind the status bar / notch, unreadable.
          // Sits BELOW the session screen's top rail (state chip + map
          // toggle), which occupies roughly the first 56 px of safe area.
          // At the rail's own offset these overlapped.
          if (path.isNotEmpty && (widget.stalled || widget.error != null))
            Positioned(
              top: MediaQuery.of(context).padding.top + 64,
              left: Sp.x3,
              right: Sp.x3,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Sp.x3, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.warn.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child: Text(
                    _statusText(false, widget.stalled, widget.error),
                    textAlign: TextAlign.center,
                    style: AppText.captionMuted.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          // Recording state. This slot used to carry "Keep the screen on to
          // map your route" — an instruction that only existed because iOS
          // suspended us the moment the screen locked. That is fixed (the
          // `location` background mode + a session-scoped wake flag), so the
          // banner would now be actively FALSE. It is replaced by a plain
          // statement of what is happening, which is what the athlete
          // actually wants to know at a glance.
          // Mutually exclusive with the stall/error banner above — they used
          // to share the exact same top position unconditionally, so whenever
          // BOTH applied (a stall is common while genuinely stationary) they
          // rendered directly on top of each other, unreadable.
          // Re-centre button (appears once the user pans away).
          if (_userPanned)
            Positioned(
              right: Sp.x3,
              // The map is bounded by the hero region now and the metric sheet
              // is a SIBLING beneath it, not an overlay — so this only has to
              // clear the map's own bottom edge. It used to be pinned at
              // `bottom: 96` against the whole screen while the control panel
              // was far taller than that, which put this button underneath it.
              bottom: widget.showStatBar ? 96 : Sp.x4,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _userPanned = false;
                    _followedCount = 0; // force a re-fit on the next build
                  });
                  _follow(path);
                },
                child: Container(
                  padding: const EdgeInsets.all(Sp.x3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(Icons.my_location_rounded,
                      size: 20, color: Colors.white),
                ),
              ),
            ),
          // ONE unified Strava-style stat bar — distance, duration, pace, and
          // BPM (zone-coloured). Shown only when there's no _ControlPanel
          // already covering the same ground (see [showStatBar]) — otherwise
          // this would be a SECOND competing stat readout stacked on the
          // first _ControlPanel, the exact "bolted on" bug this was meant to
          // fix in the first place.
          if (widget.showStatBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x3, Sp.x4, Sp.x3),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0),
                      Colors.black.withValues(alpha: 0.72),
                    ],
                  ),
                ),
                // HIERARCHY: distance is the primary figure and is set two
                // steps larger than the rest. Four equal-weight numbers (the
                // old layout) give the eye nothing to land on at a glance —
                // and a glance, mid-stride or on a bar mount, is all this
                // screen ever gets. Heart rate is a zone-tinted pill rather
                // than a fourth column, so the zone reads as colour before
                // the number is even parsed.
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: _RouteLiveStat(
                            value: units.distance(widget.distanceMeters),
                            label: 'distance',
                            primary: true,
                          ),
                        ),
                        _LiveHrPill(hr: widget.hr, zoneColor: zoneColor,
                            zoneLabel: _zoneLabels[zone]),
                      ],
                    ),
                    const SizedBox(height: Sp.x3),
                    Row(
                      children: [
                        Expanded(
                          child: _RouteLiveStat(
                            value: _fmtDuration(widget.elapsed),
                            label: 'duration',
                          ),
                        ),
                        Expanded(
                          child: _RouteLiveStat(
                            // Live (instantaneous) pace when we have a fresh
                            // speed reading; falls back to the run's average
                            // pace so the field is never blank.
                            value: livePace == '—' ? avgPace : livePace,
                            label: 'pace',
                            valueColor: AppColors.coral,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One stat in the live map's bottom bar — big tabular value + small overline
/// label, matching [_Stat]'s vocabulary elsewhere on this screen.
class _RouteLiveStat extends StatelessWidget {
  final String value;
  final String label;
  final Color? valueColor;

  /// The one figure that carries the glance (distance) — set larger so the
  /// bar has a clear first read instead of four equal numbers.
  final bool primary;

  const _RouteLiveStat({
    required this.value,
    required this.label,
    this.valueColor,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.metric.copyWith(
            color: valueColor ?? Colors.white,
            fontSize: primary ? 34 : 20,
            height: primary ? 1.05 : null,
            fontFeatures: [const FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: AppText.overline.copyWith(
              color: AppColors.onNightMuted, fontSize: 9, letterSpacing: 1),
        ),
      ],
    );
  }
}

/// Live heart rate as a zone-tinted pill on the map's stat bar.
///
/// The zone is carried by COLOUR first — on a bar mount at speed the tint
/// registers before any digit does, which is the whole point of the app's
/// zone language. Sits beside the primary distance figure rather than as a
/// fourth equal column.
class _LiveHrPill extends StatelessWidget {
  final int hr;
  final Color zoneColor;
  final String zoneLabel;
  const _LiveHrPill({
    required this.hr,
    required this.zoneColor,
    required this.zoneLabel,
  });

  @override
  Widget build(BuildContext context) {
    final has = hr > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 6),
      decoration: BoxDecoration(
        color: zoneColor.withValues(alpha: has ? 0.22 : 0.10),
        borderRadius: BorderRadius.circular(R.pill),
        border: Border.all(
          color: zoneColor.withValues(alpha: has ? 0.75 : 0.30),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            has ? '$hr' : '—',
            style: AppText.metric.copyWith(
              color: has ? zoneColor : AppColors.onNightSoft,
              fontSize: 22,
              height: 1.05,
              fontFeatures: [const FontFeature.tabularFigures()],
            ),
          ),
          Text(
            has ? zoneLabel.toUpperCase() : 'NO BPM',
            style: AppText.overline.copyWith(
              color: has ? zoneColor : AppColors.onNightMuted,
              fontSize: 8,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Live-session chrome ──────────────────────────────────────────────────────
//
// These four pieces replace what used to be a flat pile of absolutely-
// positioned Stack layers on the session screen. Each one now owns a defined
// slot in a real layout, which is what makes overlap impossible rather than
// merely unlikely.

/// The heart-rate hero for non-GPS sessions: session clock, the beating core,
/// the zone name, and the zone ladder — composed as a COLUMN inside the
/// bounded hero area, and scaled to whatever room it actually has.
///
/// The core used to be a fixed 270 px circle in a `Center` inside the screen's
/// root Stack, with the clock absolutely positioned above it and the control
/// panel absolutely positioned below. On a shorter phone all three collided.
/// Here the ring takes its size from a LayoutBuilder, so it shrinks instead.
class _HeroCore extends StatelessWidget {
  final int hr;
  final int zone;
  final double hrrPct;
  final Duration elapsed;
  final Duration redStreak;
  final String line;
  final String? almostText;
  final Color almostColor;
  final AnimationController beat;
  final AnimationController fx;
  final String Function(Duration) fmt;

  const _HeroCore({
    required this.hr,
    required this.zone,
    required this.hrrPct,
    required this.elapsed,
    required this.redStreak,
    required this.line,
    required this.almostText,
    required this.almostColor,
    required this.beat,
    required this.fx,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final z = _zones[zone];
    return LayoutBuilder(
      builder: (context, box) {
        // The ring is whatever the hero can spare, never a fixed 270.
        final ring = math.min(box.maxWidth * 0.62, box.maxHeight * 0.46)
            .clamp(150.0, 260.0);
        final bpmSize = ring * 0.34;
        return Stack(
          children: [
            // Zone-tinted studio wash, intensity climbing with effort.
            Positioned.fill(
              child: AnimatedContainer(
                duration: Motion.slow,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.15),
                    radius: 1.4,
                    colors: [
                      z.color.withValues(alpha: 0.12 + 0.30 * hrrPct),
                      AppColors.night,
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: fx,
                  builder: (context, _) => CustomPaint(
                    painter: _EmberPainter(
                        t: fx.value, intensity: hrrPct, color: z.color),
                  ),
                ),
              ),
            ),
            // The zone ladder gets its own reserved gutter on the right, so it
            // can no longer sit on top of the ring on a narrow screen.
            Positioned(
              right: Sp.x4,
              top: 0,
              bottom: 0,
              child: Center(child: _zoneLadder(zone)),
            ),
            Positioned.fill(
              child: Padding(
                // Left inset mirrors the ladder gutter so the ring stays
                // optically centred between them.
                padding: const EdgeInsets.fromLTRB(Sp.x8, Sp.x10, Sp.x8, Sp.x4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      fmt(elapsed),
                      style: AppText.hero.copyWith(
                        fontSize: 40,
                        color: Colors.white,
                        letterSpacing: 0,
                        fontFeatures: [const FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      'DURATION',
                      style: AppText.overline.copyWith(
                        color: AppColors.onNightMuted,
                        fontSize: 9,
                        letterSpacing: 3,
                      ),
                    ),
                    if (redStreak.inSeconds >= 5) ...[
                      const SizedBox(height: Sp.x2),
                      _LivePill(
                        icon: AppIcon(OsIcon.calories,
                            size: 14, color: AppColors.coral),
                        text: '${fmt(redStreak)} in the red',
                        tint: AppColors.coral,
                      ),
                    ],
                    const Spacer(),
                    SizedBox(
                      width: ring,
                      height: ring,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter:
                                  _ZoneArcPainter(pct: hrrPct, color: z.color),
                            ),
                          ),
                          AnimatedBuilder(
                            animation: beat,
                            builder: (context, child) {
                              final v = (hr > 160
                                      ? Curves.elasticOut
                                      : Curves.easeInOut)
                                  .transform(beat.value);
                              final scale = 1.0 + 0.08 * v;
                              final glow = 0.4 + 0.6 * v;
                              return Container(
                                width: ring * 0.78,
                                height: ring * 0.78,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: z.color
                                          .withValues(alpha: 0.4 * glow),
                                      blurRadius: 40 * scale,
                                      spreadRadius: 2,
                                    ),
                                    BoxShadow(
                                      color: z.color
                                          .withValues(alpha: 0.15 * glow),
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
                                        color: z.color
                                            .withValues(alpha: 0.35),
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
                                  hr > 0 ? '$hr' : '—',
                                  style: AppText.display.copyWith(
                                    fontSize: bpmSize,
                                    color: Colors.white,
                                    height: 1,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                Text(
                                  'BPM',
                                  style: AppText.overline.copyWith(
                                    color: AppColors.onNightMuted,
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
                    ),
                    const Spacer(),
                    AnimatedDefaultTextStyle(
                      duration: Motion.med,
                      style: AppText.h2.copyWith(
                        color: z.color,
                        letterSpacing: 3,
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                      ),
                      child: Text('${z.label} · ${z.name}'.toUpperCase()),
                    ),
                    const SizedBox(height: Sp.x2),
                    SizedBox(
                      height: 22,
                      child: AnimatedSwitcher(
                        duration: Motion.med,
                        child: almostText != null
                            ? Text(
                                almostText!,
                                key: ValueKey(almostText),
                                textAlign: TextAlign.center,
                                style: AppText.bodySoft.copyWith(
                                    color: almostColor,
                                    fontWeight: FontWeight.w700),
                              )
                            : Text(
                                line,
                                key: ValueKey(line),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.bodySoft
                                    .copyWith(color: AppColors.onNightSoft),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

Widget _zoneLadder(int zone) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int z = 5; z >= 1; z--) ...[
          AnimatedContainer(
            duration: Motion.med,
            width: z == zone ? 16 : 10,
            height: 26,
            decoration: BoxDecoration(
              color: z <= zone
                  ? _zones[z].color.withValues(alpha: z == zone ? 1 : 0.5)
                  : Colors.white12,
              borderRadius: BorderRadius.circular(6),
              boxShadow: z == zone
                  ? [
                      BoxShadow(
                          color: _zones[z].color.withValues(alpha: 0.6),
                          blurRadius: 12)
                    ]
                  : null,
            ),
          ),
          if (z > 1) const SizedBox(height: 6),
        ],
      ],
    );

/// Small translucent pill used for in-hero status text.
class _LivePill extends StatelessWidget {
  final Widget icon;
  final String text;
  final Color? tint;
  const _LivePill({required this.icon, required this.text, this.tint});

  @override
  Widget build(BuildContext context) {
    final c = tint ?? Colors.white;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(R.pill),
        border: Border.all(color: c.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: Sp.x2),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.metricSm.copyWith(
                color: c,
                fontSize: 15,
                letterSpacing: 0.5,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The top rail's only occupant: a tappable warning when location is denied
/// or off for a route-eligible workout.
///
/// There used to be a "Recording" pill here in the healthy case. It was
/// removed — it stated something the athlete already knows (they started the
/// workout, the timer is running) and cost a permanent breathing animation
/// plus a chunk of the map's most valuable screen area to say it.
class _SessionStateChip extends StatelessWidget {
  final GpsPermissionStatus? locationIssue;
  final Future<void> Function() onFixLocation;
  const _SessionStateChip({
    required this.locationIssue,
    required this.onFixLocation,
  });

  @override
  Widget build(BuildContext context) {
    if (locationIssue == null) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onFixLocation,
      child: _LivePill(
        icon: const Icon(Icons.location_off_outlined,
            size: 15, color: Colors.white60),
        text: locationIssue == GpsPermissionStatus.serviceOff
            ? 'Location off — turn it on'
            : 'Location off — allow it',
        tint: AppColors.warn,
      ),
    );
  }
}

/// Switch between the map and the heart-rate core, centred in the metric sheet.
///
/// A two-up segmented control rather than a single circular icon button
/// floating on the map: a segmented pair states BOTH available views and which
/// one you are on, where a lone icon button only hinted at the other one.
///
/// Icons only. The words "Heart" and "Map" beside a heart and a map glyph were
/// pure redundancy — the icons already say it, and dropping the labels keeps
/// the control compact enough to centre without dominating the row above it.
/// The accessible names live in [Semantics] instead, where screen readers need
/// them and sighted users don't.
class _ViewToggle extends StatelessWidget {
  final bool showingMap;
  final ValueChanged<bool> onChanged;
  const _ViewToggle({required this.showingMap, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _seg(
              icon: Icons.favorite_rounded,
              label: 'Heart',
              selected: !showingMap,
              onTap: () => onChanged(false),
            ),
            _seg(
              icon: Icons.map_rounded,
              label: 'Map',
              selected: showingMap,
              onTap: () => onChanged(true),
            ),
          ],
        ),
      );

  Widget _seg({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: Motion.fast,
            curve: Motion.curve,
            padding: const EdgeInsets.symmetric(
                horizontal: Sp.x5, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(R.pill),
            ),
            child: Icon(
              icon,
              size: 18,
              color: selected ? AppColors.onNight : AppColors.onNightSoft,
            ),
          ),
        ),
      );
}

/// The metric sheet — the bottom half of the session screen.
///
/// Production run/ride apps all converge on the same hierarchy, and this now
/// follows it: ONE primary figure large enough to read at a glance mid-stride,
/// a zone-tinted heart-rate pill beside it, then a row of secondary stats, then
/// the finish control. The previous panel gave six stats identical weight in a
/// 2×2-plus-3 grid, every one of them tagged with the SAME generic pulse icon,
/// so nothing read first and the icons carried no information.
///
/// It is a sibling of the hero in a Column, so it cannot overlap anything.
class _SessionSheet extends StatelessWidget {
  final LiveWorkoutState workout;
  final AnimationController holdController;
  final bool ending;
  final VoidCallback onFinished;
  final int hr;
  final int zoneIndex;
  final Duration elapsed;

  /// GPS sessions lead with distance and show pace; non-GPS lead with the
  /// clock. Null distance ⇒ not a route workout.
  final String? distance;
  final String? distanceUnit;
  final String? pace;

  /// The map/heart switch, rendered in the sheet's footer beside the stats.
  /// Null for a workout with no route to switch to.
  final Widget? viewToggle;

  const _SessionSheet({
    required this.workout,
    required this.holdController,
    required this.ending,
    required this.onFinished,
    required this.hr,
    required this.zoneIndex,
    required this.elapsed,
    this.distance,
    this.distanceUnit,
    this.pace,
    this.viewToggle,
  });

  static String _fmtClock(Duration d) {
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final zone = zoneIndex.clamp(0, 5);
    final zoneColor = AppColors.zoneOnDark(zone);
    final isRoute = distance != null;
    // Nullable: the band's 100 Hz accel stream is routinely absent during a
    // perfectly good workout (standard-HR fallback, background downgrade), and
    // printing a confident "0 STEPS" next to a real distance and a real HR is a
    // fabricated measurement — issue #183 screenshotted exactly that.
    final steps = context.select<AppState, int?>((a) => a.workoutStepsMeasured);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.nightAlt,
        border: Border(top: BorderSide(color: Colors.white10)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(R.card)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x5, Sp.x6, Sp.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The primary figure and the heart-rate pill appear ONLY on the
              // map, where the hero is a map and carries neither. In heart
              // mode the hero already shows the session clock at 40 px and the
              // BPM at ring scale with its zone name — repeating both down
              // here was the same number printed twice on one screen.
              if (isRoute) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _PrimaryMetric(
                        value: distance!,
                        unit: distanceUnit ?? '',
                      ),
                    ),
                    _LiveHrPill(
                      hr: hr,
                      zoneColor: zoneColor,
                      zoneLabel: _zones[zone].label,
                    ),
                  ],
                ),
                const SizedBox(height: Sp.x5),
                const Divider(color: Colors.white10, height: 1),
                const SizedBox(height: Sp.x4),
              ],
              // Secondary stats — three across, evenly weighted and centred.
              Row(
                children: [
                  Expanded(
                    child: _SheetStat(
                      isRoute
                          ? _fmtClock(elapsed)
                          // A dash, never a 0 — same contract as strain below.
                          : (workout.caloriesOrNull?.toString() ?? '—'),
                      isRoute ? 'TIME' : 'KCAL',
                    ),
                  ),
                  Expanded(
                    child: _SheetStat(
                      isRoute
                          ? (pace ?? '—')
                          // Null until the profile carries the anchors
                          // Banister needs — a dash, never a 0.0.
                          : (workout.strain?.toStringAsFixed(1) ?? '—'),
                      isRoute ? 'PACE' : 'STRAIN',
                    ),
                  ),
                  Expanded(
                    child: _SheetStat(
                      isRoute
                          ? (workout.caloriesOrNull?.toString() ?? '—')
                          : (steps?.toString() ?? '—'),
                      isRoute ? 'KCAL' : 'STEPS',
                    ),
                  ),
                ],
              ),
              if (viewToggle != null) ...[
                const SizedBox(height: Sp.x4),
                Center(child: viewToggle!),
              ],
              const SizedBox(height: Sp.x5),
              _HoldToFinish(
                holdController: holdController,
                ending: ending,
                onFinished: onFinished,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one figure the athlete reads at a glance. Sized so it survives being
/// looked at from a bar mount at speed.
class _PrimaryMetric extends StatelessWidget {
  final String value;
  final String unit;
  const _PrimaryMetric({required this.value, required this.unit});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: AppText.display.copyWith(
                fontSize: 52,
                height: 1.0,
                color: AppColors.onNight,
                fontWeight: FontWeight.w900,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            unit.toUpperCase(),
            style: AppText.overline.copyWith(
              color: AppColors.onNightMuted,
              fontSize: 9,
              letterSpacing: 3,
            ),
          ),
        ],
      );
}

/// One secondary stat in the sheet. No icon — six stats all carrying the same
/// generic pulse glyph was noise, not information.
class _SheetStat extends StatelessWidget {
  final String value;
  final String label;
  const _SheetStat(this.value, this.label);

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.metric.copyWith(
              color: AppColors.onNight,
              fontSize: 22,
              fontFeatures: [const FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: AppText.overline.copyWith(
              color: AppColors.onNightMuted,
              fontSize: 9,
              letterSpacing: 2,
            ),
          ),
        ],
      );
}

/// Hold-to-finish. Deliberately kept as a HOLD rather than a tap: ending a
/// session is destructive and a mis-tap mid-run costs the workout.
class _HoldToFinish extends StatelessWidget {
  final AnimationController holdController;
  final bool ending;
  final VoidCallback onFinished;
  const _HoldToFinish({
    required this.holdController,
    required this.ending,
    required this.onFinished,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Hold to finish workout',
        child: GestureDetector(
          onLongPressStart: (_) {
            holdController.forward();
            HapticFeedback.lightImpact();
          },
          onLongPressEnd: (_) {
            if (holdController.value >= 1.0) {
              onFinished();
            } else {
              holdController.reverse();
            }
          },
          child: AnimatedBuilder(
            animation: holdController,
            builder: (context, child) {
              final val = holdController.value;
              return Transform.scale(
                scale: 1.0 - 0.05 * val,
                child: Container(
                  width: double.infinity,
                  height: 64,
                  decoration: BoxDecoration(
                    color: val > 0
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.white.withValues(alpha: 0.04),
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
                              color: AppColors.coral
                                  .withValues(alpha: 0.2 + 0.2 * val),
                              borderRadius: BorderRadius.circular(R.pill),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AppIcon(OsIcon.cancel,
                              size: 20,
                              color: Color.lerp(AppColors.onNightSoft,
                                  AppColors.onNight, val)),
                          const SizedBox(width: Sp.x3),
                          Text(
                            ending ? 'FINISHING…' : 'HOLD TO FINISH',
                            style: AppText.label.copyWith(
                              color: Color.lerp(
                                  AppColors.onNightSoft, AppColors.onNight, val),
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
      );
}
