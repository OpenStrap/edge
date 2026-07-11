// Live workout — an interactive, HR-reactive screen that reacts to your heart in
// real time. Everything here is driven by REAL live HR (device.liveHr via BLE):
// an ember core that beats at your pulse, a zone ladder with "almost there" nudges,
// an "in the red" streak, milestone bursts, and a playful line engine. Code-drawn
// (CustomPaint), haptics-only, open-ended. Long-press to finish → breakdown.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/payloads.dart';
import '../../state/app_state.dart';
import '../../state/units_controller.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
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

final List<_ZoneMeta> _zones = [
  _ZoneMeta('Z0', 'Resting', AppColors.zone(0)),
  _ZoneMeta('Z1', 'Warm-up', AppColors.zone(1)),
  _ZoneMeta('Z2', 'Fat burn', AppColors.zone(2)),
  _ZoneMeta('Z3', 'Aerobic', AppColors.zone(3)),
  _ZoneMeta('Z4', 'Threshold', AppColors.zone(4)),
  _ZoneMeta('Z5', 'Max effort', AppColors.zone(5)),
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
    if (hasRoute != _showMap) setState(() => _showMap = hasRoute);
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
    // Snapshot the live totals BEFORE stopWorkout() clears them — the finish
    // card counts up from these, then enriches from getWorkout(id).
    final w = app.activeWorkout;
    final snap = WorkoutFinishSnapshot(
      type: w?.type ?? widget.type,
      duration: w?.elapsed ?? Duration.zero,
      peakHr: w?.maxHrSeen ?? 0,
      calories: w?.calories ?? 0,
      strain: w?.strain ?? 0,
      steps: app.workoutSteps,
    );
    // AWAIT: stopWorkout flushes the GPS route tail; navigating before it
    // completes raced the finish screen's route load (missing tail / no map).
    await app.stopWorkout(); // clears local + ends iOS Live Activity
    try { if (id != null) await app.repo?.endWorkout(id); } catch (_) {}
    if (!mounted) return;
    if (id != null) {
      Navigator.of(context).pushReplacement(
        themedRoute((_) => WorkoutFinishScreen(id: id, snapshot: snap)),
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

    // GPS map mode is now a dedicated layout, not a small box floating over
    // the ember/HR-reactive core: that layering (separate zone ladder, big
    // timer, and HR circle all still rendering underneath a boxed map) is
    // exactly what read as badly composed. When a route exists, the map IS
    // the screen — BPM/zone/duration move into its own unified stat bar
    // (GpsLiveMapView) instead of competing with a second UI system. The
    // ember core stays untouched for non-GPS workouts, where it's the right
    // default.
    final mapOn = _showMap && app.routeTracker != null;

    return Theme(
      data: ThemeData.dark().copyWith(scaffoldBackgroundColor: AppColors.night),
      child: Scaffold(
        body: Stack(children: [
          // 1. Zone-tinted studio background, intensity climbs with effort.
          if (!mapOn)
            Positioned.fill(child: AnimatedContainer(
              duration: Motion.slow,
              decoration: BoxDecoration(gradient: RadialGradient(
                center: const Alignment(0, -0.15), radius: 1.4,
                colors: [z.color.withValues(alpha: 0.12 + 0.30 * hrrPct), AppColors.night],
              )),
            )),

          // 2. Ember field rising behind the core (count/heat ∝ effort).
          if (!mapOn)
            Positioned.fill(child: AnimatedBuilder(
              animation: _fx,
              builder: (context, _) => CustomPaint(painter: _EmberPainter(t: _fx.value, intensity: hrrPct, color: z.color)),
            )),

          // 3. Top: the big tabular timer (the refs' huge session clock) +
          // in-the-red streak. Weight and space, no chrome. (Map mode shows
          // duration in its own unified stat bar instead — see 5b.)
          if (!mapOn)
            SafeArea(child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.x4),
              child: Column(children: [
                Text(
                  _fmt(w.elapsed),
                  style: AppText.hero.copyWith(
                    fontSize: 40,
                    color: Colors.white,
                    letterSpacing: 0,
                  ),
                ),
                Text(
                  'DURATION',
                  style: AppText.overline.copyWith(
                    color: Colors.white30,
                    fontSize: 9,
                    letterSpacing: 3,
                  ),
                ),
                if (_redStreak.inSeconds >= 5) ...[
                  const SizedBox(height: Sp.x2),
                  _pill(AppIcon(OsIcon.calories, size: 14, color: AppColors.coral),
                      '${_fmt(_redStreak)} in the red', tint: AppColors.coral),
                ],
              ]),
            )),

          // 4. The ember core (beats at your HR). Map mode shows BPM + zone
          // in its own unified stat bar instead — see 5b.
          if (!mapOn)
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

          // 5. Zone ladder (right edge). Redundant with map mode's own
          // BPM/zone stat — suppressed there.
          if (!mapOn)
            Positioned(right: Sp.x4, top: 0, bottom: 0, child: Center(child: _zoneLadder(zone))),

          // 5b. Live route map — for a GPS workout (run/ride/walk) this IS
          // the screen now, full-bleed, not a small box over the ember core.
          // showStatBar: false — the merged _GpsControlPanel below shows
          // these same live stats in ONE glass card instead of a second,
          // competing bar stacked on the map.
          if (mapOn)
            Positioned.fill(
              child: _LiveRouteMap(
                tracker: app.routeTracker!,
                elapsed: w.elapsed,
                hr: hr,
                zoneIndex: zone,
                showStatBar: false,
              ),
            ),

          // 6. Stat panel + hold-to-finish. ONE glass card either way now —
          // in map mode it also carries the live distance/duration/pace/BPM
          // readout (via _GpsControlPanel), instead of a second stat bar
          // floating separately on the map.
          Positioned(left: Sp.x6, right: Sp.x6, bottom: Sp.x8,
              child: mapOn
                  ? _GpsControlPanel(
                      tracker: app.routeTracker!,
                      elapsed: w.elapsed,
                      hr: hr,
                      zoneIndex: zone,
                      workout: w,
                      holdController: _hold,
                      ending: _ending,
                      onFinished: _finish,
                    )
                  : _ControlPanel(workout: w, holdController: _hold, ending: _ending, onFinished: _finish)),

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

          // 9b. Location denied/off for a route-eligible workout → say so and
          // offer the fix, instead of silently running without a map.
          if (app.routeTracker == null && app.routeLocationIssue != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 64,
              left: Sp.x5,
              right: Sp.x5,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  final issue = app.routeLocationIssue!;
                  if (issue == GpsPermissionStatus.denied) {
                    // Re-prompt is still possible — retry in place.
                    await app.retryRouteTracking();
                  } else {
                    await GpsSource.openSettingsFor(issue);
                  }
                },
                child: Center(
                  child: _pill(
                    const Icon(Icons.location_off_outlined,
                        size: 15, color: Colors.white60),
                    app.routeLocationIssue == GpsPermissionStatus.serviceOff
                        ? 'Location off — turn it on to map your route'
                        : 'Location off — allow it to map your route',
                    tint: AppColors.warn,
                  ),
                ),
              ),
            ),

          // 9. Map-mode toggle (run/ride/walk with a live route only).
          if (app.routeTracker != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + Sp.x5,
              right: Sp.x5,
              child: GestureDetector(
                onTap: () => setState(() {
                  _showMap = !_showMap;
                  _userToggledMap = true; // respect the explicit choice now
                }),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _showMap
                        ? AppColors.coral.withValues(alpha: 0.9)
                        : Colors.white.withValues(alpha: 0.10),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Icon(
                    _showMap ? Icons.favorite : Icons.map_outlined,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
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
  // GPS-mode live stats — ONE glass card with the map's live readout on top
  // and the existing calories/strain/steps below, instead of two separate
  // floating panels stacked on the map (that's what read as "bolted on").
  // Null (via [gpsDistance]) when this isn't a GPS-tagged workout.
  final String? gpsDistance;
  final String? gpsDuration;
  final String? gpsPace;
  final int? gpsHr;
  final Color? gpsZoneColor;
  final String? gpsZoneLabel;
  const _ControlPanel({
    required this.workout,
    required this.holdController,
    required this.ending,
    required this.onFinished,
    this.gpsDistance,
    this.gpsDuration,
    this.gpsPace,
    this.gpsHr,
    this.gpsZoneColor,
    this.gpsZoneLabel,
  });

  bool get _hasGpsStats => gpsDistance != null;

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
            child: Column(children: [
              if (_hasGpsStats) ...[
                // 2x2 grid, not 4-across — four full stats (icon+value+unit+
                // label each) in one row left ~70px per stat on a real phone
                // width, which crowded/crammed together. Two rows of two
                // gives each stat roughly double the room.
                Row(children: [
                  Expanded(child: _Stat(icon: OsIcon.activity, label: 'DISTANCE', value: gpsDistance!, unit: '')),
                  const SizedBox(width: Sp.x4),
                  Expanded(child: _Stat(icon: OsIcon.activity, label: 'DURATION', value: gpsDuration!, unit: '')),
                ]),
                const SizedBox(height: Sp.x4),
                Row(children: [
                  Expanded(child: _Stat(icon: OsIcon.activity, label: 'PACE', value: gpsPace!, unit: '')),
                  const SizedBox(width: Sp.x4),
                  // BPM stays white like the other three stats — zone colour
                  // on the number itself read as a bug ("why is heart rate
                  // blue?"), not a signal. The zone name in the label below
                  // it already conveys the zone.
                  Expanded(child: _Stat(
                    icon: OsIcon.heartRate,
                    label: gpsZoneLabel ?? '',
                    value: (gpsHr ?? 0) > 0 ? '$gpsHr' : '—',
                    unit: '',
                  )),
                ]),
                const SizedBox(height: Sp.x4),
                const Divider(color: Colors.white10, height: 1),
                const SizedBox(height: Sp.x4),
              ],
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              _Stat(icon: OsIcon.activity, label: 'CALORIES', value: workout.calories.round().toString(), unit: 'kcal'),
              _Stat(icon: OsIcon.activity, label: 'STRAIN', value: workout.strain.toStringAsFixed(1), unit: ''),
              // Real steps counted on the live 100 Hz stream, scoped to THIS
              // workout (resets at start, not at connection).
              _Stat(icon: OsIcon.activity, label: 'STEPS',
                  value: context.watch<AppState>().workoutSteps.toString(),
                  unit: ''),
              ]),
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
                    AppIcon(OsIcon.cancel, size: 20, color: Color.lerp(Colors.white24, Colors.white, val)),
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

/// Feeds the RouteTracker's live distance/speed into [_ControlPanel]'s merged
/// GPS stat row — so it updates live without wrapping the whole ember-core
/// Stack (confetti, callouts, etc.) in ValueListenableBuilders it doesn't
/// need.
class _GpsControlPanel extends StatelessWidget {
  final RouteTracker tracker;
  final Duration elapsed;
  final int hr;
  final int zoneIndex;
  final LiveWorkoutState workout;
  final AnimationController holdController;
  final bool ending;
  final VoidCallback onFinished;
  const _GpsControlPanel({
    required this.tracker,
    required this.elapsed,
    required this.hr,
    required this.zoneIndex,
    required this.workout,
    required this.holdController,
    required this.ending,
    required this.onFinished,
  });

  static const _zoneLabels = ['Rest', 'Warm', 'Fat', 'Aero', 'Thr', 'Max'];

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final units = context.watch<UnitsController>();
    final zone = zoneIndex.clamp(0, 5);
    return ValueListenableBuilder<double>(
      valueListenable: tracker.distanceMeters,
      builder: (context, meters, _) => ValueListenableBuilder<double?>(
        valueListenable: tracker.currentSpeedMps,
        builder: (context, speedMps, _) {
          final movingSec = tracker.movingSeconds;
          final avgPace = units.pace(
            meters,
            movingSec > 0 ? movingSec : elapsed.inSeconds,
          );
          final livePace = units.paceFromSpeed(speedMps);
          return _ControlPanel(
            workout: workout,
            holdController: holdController,
            ending: ending,
            onFinished: onFinished,
            gpsDistance: units.distance(meters),
            gpsDuration: _fmtDuration(elapsed),
            gpsPace: livePace == '—' ? avgPace : livePace,
            gpsHr: hr,
            gpsZoneColor: AppColors.zone(zone),
            gpsZoneLabel: _zoneLabels[zone],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value, unit;
  final OsIcon icon;
  final Color? valueColor;
  const _Stat({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    this.valueColor,
  });
  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      AppIcon(icon, size: 16, color: valueColor?.withValues(alpha: 0.7) ?? Colors.white38),
      const SizedBox(height: Sp.x2),
      // mainAxisSize.min + explicit centering: when this _Stat sits inside
      // an Expanded (the merged GPS stat row), a bare default Row here
      // fills the WIDER Expanded box and left-aligns within it — the icon
      // and label above/below stay centered (plain leaf widgets), so the
      // value+unit alone reads as shifted left relative to them. Shrink-
      // wrapping fixes that mismatch.
      Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(value, style: AppText.metric.copyWith(color: valueColor ?? Colors.white, fontSize: 24)),
          if (unit.isNotEmpty) ...[const SizedBox(width: 4), Text(unit, style: AppText.caption.copyWith(color: Colors.white38))],
        ],
      ),
      const SizedBox(height: 4),
      Text(
        label,
        style: AppText.overline.copyWith(color: Colors.white30, fontSize: 9, letterSpacing: 1),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    ]);
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
  final double calories;
  final double strain;
  final int steps;
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
  final GlobalKey _cardKey = GlobalKey();

  Map<String, dynamic>? _detail;
  List<RouteVertex>? _routeVertices;
  WorkoutRoute? _route; // full route (distance/pace/splits) for the hero map
  int _maxHr = 190; // overwritten from AppState/previewMaxHr once known
  bool _prWorkout = false;
  bool _prSteps = false;
  bool _confettiFired = false;
  bool _sharing = false;

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
          _prWorkout =
              tw != null && strain > 0 && (strain - tw.value).abs() < 0.15;
          final ms = recs.record('most_steps');
          _prSteps = ms != null &&
              s.steps > 0 &&
              (s.steps - ms.value).abs() < 1.5;
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
    final kcal = (d?['calories'] as num?)?.toInt() ?? s.calories.round();
    final steps = (d?['steps'] as num?)?.toInt() ?? s.steps;
    final bands = (d?['zone_bands'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    final curve = (d?['recovery_curve'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    // GPS-tagged workout (run/ride/walk) with a real recorded route → the map
    // is the hero, Strava-style, right under the header — not a small
    // thumbnail buried at the end among the strain/zone/PR cards.
    final hasRoute = _route != null && _route!.hasPath;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            child: AnimatedBuilder(
              animation: _reveal,
              builder: (context, _) => ListView(
                padding: const EdgeInsets.fromLTRB(
                    Sp.screen, Sp.x6, Sp.screen, Sp.x10),
                children: [
                  // Opaque background so the shared PNG never captures
                  // transparency.
                  RepaintBoundary(
                    key: _cardKey,
                    child: Container(
                      color: AppColors.background,
                      padding: const EdgeInsets.symmetric(vertical: Sp.x2),
                      child: Column(
                        children: [
                          _header(s),
                          if (hasRoute) ...[
                            const SizedBox(height: Sp.x5),
                            _heroRoute(),
                          ],
                          const SizedBox(height: Sp.x6),
                          _strainGauge(strain),
                          const SizedBox(height: Sp.x7),
                          _heroStats(peak, avg, kcal, steps),
                          const SizedBox(height: Sp.x7),
                          _zoneCard(bands),
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
    return Opacity(
      opacity: _seg(0.0, 0.3),
      child: Column(
        children: [
          Text('$label complete', style: AppText.h1),
          const SizedBox(height: Sp.x1),
          Text(_dur(s.duration), style: AppText.bodySoft),
        ],
      ),
    );
  }

  Widget _strainGauge(double strain) {
    final p = _seg(0.0, 0.5);
    return Center(
      child: ArcGauge(
        value: (strain / 21).clamp(0.0, 1.0),
        color: AppColors.accent,
        size: 176,
        stroke: 15,
        sweepFraction: 0.75,
        endDot: true,
        center: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text((strain * p).toStringAsFixed(1), style: AppText.display),
            Text('STRAIN', style: AppText.overline),
          ],
        ),
      ),
    );
  }

  Widget _heroStats(int peak, int? avg, int kcal, int steps) {
    final p = _seg(0.15, 0.6);
    Widget stat(String v, String label) => Expanded(
          child: Column(
            children: [
              Text(v, style: AppText.metric.copyWith(fontSize: 24)),
              const SizedBox(height: 2),
              Text(label, style: AppText.overline.copyWith(fontSize: 9)),
            ],
          ),
        );
    return Opacity(
      opacity: p,
      child: Transform.translate(
        offset: Offset(0, 14 * (1 - p)),
        child: Row(
          children: [
            stat(peak > 0 ? '${(peak * p).round()}' : '—', 'PEAK BPM'),
            stat(avg != null ? '${(avg * p).round()}' : '—', 'AVG BPM'),
            stat('${(kcal * p).round()}', 'KCAL'),
            if (steps > 0) stat('${(steps * p).round()}', 'STEPS'),
          ],
        ),
      ),
    );
  }

  Widget _zoneCard(List<Map> bands) {
    final vals = [for (final b in bands) (b['min'] as num?)?.toDouble() ?? 0];
    final colors = [for (int i = 0; i < bands.length; i++) AppColors.zone(i)];
    final wipe = _seg(0.4, 0.7);
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

  Widget _hrrCard(List<Map> curve) {
    final p = _seg(0.55, 0.85);
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
          opacity: _seg(0.75, 0.9),
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
  Widget _prBadges() {
    final pop = Curves.easeOutBack.transform(_seg(0.75, 1.0).clamp(0.0, 1.0));
    return Transform.scale(
      scale: pop.clamp(0.0, 1.0),
      child: Column(
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
      ),
    );
  }

  /// Strava-style hero: the real recorded route as the FIRST thing shown
  /// after the header, not a small thumbnail buried at the end. Reuses
  /// [RouteCard] (map + distance/pace stats) — same widget the workout
  /// detail screen already uses, so this stays visually consistent rather
  /// than reinventing the stat formatting.
  Widget _heroRoute() {
    return Opacity(
      opacity: _seg(0.05, 0.4),
      child: RouteCard(route: _route!, maxHr: _maxHr),
    );
  }

  Widget _mapSlot() {
    final verts = _routeVertices;
    if (verts != null && verts.length >= 2) {
      // Real route recorded → static HR-zone-coloured thumbnail.
      return Opacity(
        opacity: _seg(0.6, 0.9),
        child: RouteMapView(vertices: verts, height: 140),
      );
    }
    // No route (indoor / permission denied / non-GPS type) → graceful empty.
    return Opacity(
      opacity: _seg(0.6, 0.9),
      child: Container(
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
    return Opacity(
      opacity: _seg(0.85, 1.0),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _sharing ? null : _share,
              icon: _sharing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accent))
                  : const Icon(Icons.ios_share_rounded, size: 18),
              label: Text(_sharing ? 'Preparing…' : 'Share'),
            ),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: FilledButton(
              onPressed: () => Navigator.of(context).pushReplacement(
                themedRoute((_) => WorkoutDetailScreen(id: widget.id)),
              ),
              child: const Text('Full breakdown'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin = (box != null && box.hasSize)
          ? (box.localToGlobal(Offset.zero) & box.size)
          : null;
      final boundary =
          _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('Card not ready');
      final ui.Image image = await boundary.toImage(pixelRatio: 3);
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Failed to encode image');
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/openstrap_workout_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'My OpenStrap workout',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't share: $e")));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}

/// Self-drawing HR-recovery polyline — draws up to [progress] of its length.
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
  // False in the real live session — the merged _ControlPanel/_GpsControlPanel
  // shows these same live stats in ONE glass card instead. True (the
  // default) for the Design Gallery's standalone preview, which has no
  // control panel of its own.
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
    final zoneColor = AppColors.zone(zone);
    final movingSec = widget.movingSeconds;
    final avgPace = units.pace(
      widget.distanceMeters,
      movingSec > 0 ? movingSec : widget.elapsed.inSeconds,
    );
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
          if (path.isNotEmpty && (widget.stalled || widget.error != null))
            Positioned(
              top: MediaQuery.of(context).padding.top + Sp.x3,
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
          // iOS v1 is while-in-use location only — fixes stop when the screen
          // locks. Say so instead of silently producing a gappy route.
          // Mutually exclusive with the stall/error banner above — they used
          // to share the exact same top position unconditionally, so on iOS
          // whenever BOTH applied (a stall, which is common while genuinely
          // stationary/idle) they rendered directly on top of each other,
          // unreadable.
          if (Platform.isIOS && !(path.isNotEmpty && (widget.stalled || widget.error != null)))
            Positioned(
              top: MediaQuery.of(context).padding.top + Sp.x3,
              left: Sp.x3,
              right: Sp.x3,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Sp.x3, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child: Text('Keep the screen on to map your route',
                      style: AppText.captionMuted
                          .copyWith(color: Colors.white70)),
                ),
              ),
            ),
          // Re-centre button (appears once the user pans away).
          if (_userPanned)
            Positioned(
              right: Sp.x3,
              bottom: 96,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _userPanned = false;
                    _followedCount = 0; // force a re-fit on the next build
                  });
                  _follow(path);
                },
                child: Container(
                  padding: const EdgeInsets.all(Sp.x2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.my_location,
                      size: 18, color: Colors.white),
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
                child: Row(
                  children: [
                    Expanded(
                      child: _RouteLiveStat(
                        value: units.distance(widget.distanceMeters),
                        label: 'distance',
                      ),
                    ),
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
                    Expanded(
                      child: _RouteLiveStat(
                        value: widget.hr > 0 ? '${widget.hr}' : '—',
                        label: _zoneLabels[zone],
                        valueColor: zoneColor,
                      ),
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
  const _RouteLiveStat({
    required this.value,
    required this.label,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: AppText.metric.copyWith(
            color: valueColor ?? Colors.white,
            fontSize: 20,
            fontFeatures: [const FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: AppText.overline
              .copyWith(color: Colors.white38, fontSize: 9, letterSpacing: 1),
        ),
      ],
    );
  }
}
