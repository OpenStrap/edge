// GHOST RUN: race a past run on the same route.
//
// The maths lives in lib/gps/ghost_math.dart (pure, unit-tested); this file
// only draws it. Colour language, used everywhere in this feature:
//   green  + up arrow    ahead of the ghost
//   orange + down arrow  behind it (orange, not red: behind is not an error)
//   blue   + equals      level (inside GPS wander)
// Every state also carries an icon and words, so colour is never the only cue.
//
// LOCAL-FIRST: the ghost's route is read from this phone's own table. Nothing
// here talks to a network; the only outward call is the band buzz callback.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gps/ghost_math.dart';
import '../../gps/route_models.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/date_text.dart';
import '../grammar.dart';
import '../screens/home_screen.dart' show unitsOf;
import '../skeleton/guide_plot.dart';
import '../theme.dart';
import 'live.dart' show say;

/// One past session that could be a ghost, summarised for the picker.
class GhostCandidate {
  final String id;
  final DateTime start;
  final int durationSec;
  final double distanceM;

  /// Why it can not be raced, or null when it can.
  final GhostRefusal? refusal;
  const GhostCandidate({
    required this.id,
    required this.start,
    required this.durationSec,
    required this.distanceM,
    this.refusal,
  });
}

/// Past sessions of one activity type that have a stored route, newest first.
typedef GhostCandidatesLoader =
    Future<List<GhostCandidate>> Function(String typeKey);

/// The stored route points of one session, or null when there are none.
typedef GhostRouteLoader = Future<List<RoutePoint>?> Function(String sessionId);

/// "12 m", or "1.2 km" past a kilometre. Whole metres: a decimal metre is
/// finer than the GPS can tell.
String ghostGapText(double meters) {
  final m = meters.abs();
  if (m >= 1000) return '${(m / 1000).toStringAsFixed(1)} km';
  return '${m.round()} m';
}

/// The {km} of a split: its number for a whole kilometre, else the stretch it
/// really covers ("0.0-0.6", "0.1-1.1"), since a partial split is not "km 1".
String ghostSplitKm(GhostSplit s) {
  final whole =
      (s.fromM % 1000 < 1 || s.fromM % 1000 > 999) &&
      (s.toM - s.fromM - 1000).abs() < 1;
  if (whole) return '${(s.fromM / 1000).round() + 1}';
  String k(double m) => (m / 1000).toStringAsFixed(1);
  return '${k(s.fromM)}-${k(s.toM)}';
}

/// "23 s", or "1:05" from a minute up.
String ghostTimeText(double seconds) {
  final s = seconds.abs().round();
  if (s < 60) return '$s s';
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _refusalText(AppLocalizations? l, GhostRefusal r) => switch (r) {
  GhostRefusal.tooFewPoints => l?.ghostRefusedFewPoints ?? 'Too few GPS points',
  GhostRefusal.tooShort => l?.ghostRefusedShort ?? 'Too short to race',
  GhostRefusal.tooBrief => l?.ghostRefusedBrief ?? 'Too brief to race',
  GhostRefusal.brokenClock =>
    l?.ghostRefusedClock ?? 'Timing in this route is unreadable',
  GhostRefusal.gappy =>
    l?.ghostRefusedGappy ?? 'Too much of it was not recorded',
};

/// The state's accent, icon and one-line words.
(Color, IconData) _look(GhostState s) => switch (s) {
  GhostState.ahead || GhostState.finished => (C.green, LucideIcons.arrowUp),
  GhostState.behind => (C.orange, LucideIcons.arrowDown),
  GhostState.level => (C.blue, LucideIcons.equal),
  GhostState.offRoute => (C.indigo, LucideIcons.mapPinOff),
  GhostState.waiting => (C.indigo, LucideIcons.locateFixed),
};

// ══════════════ LIVE ══════════════

/// Loads the ghost's route, then shows [GhostPanel]. Rebuilt by the live
/// screen every second with the latest clock and fix.
class GhostLive extends StatefulWidget {
  final String ghostId;
  final GhostRouteLoader? loadRoute;
  final int elapsedSec;
  final LatLng? fix;
  final Future<void> Function()? buzz;
  final bool buzzOn;
  final GhostKeep? keep;
  const GhostLive({
    super.key,
    required this.ghostId,
    required this.loadRoute,
    required this.elapsedSec,
    required this.fix,
    this.buzz,
    this.buzzOn = true,
    this.keep,
  });

  @override
  State<GhostLive> createState() => _GhostLiveState();
}

class _GhostLiveState extends State<GhostLive> {
  late final Future<GhostTrack?> _track = _load();

  Future<GhostTrack?> _load() async {
    final pts = await widget.loadRoute?.call(widget.ghostId);
    return pts == null ? null : GhostTrack.tryBuild(pts);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return FutureBuilder<GhostTrack?>(
      future: _track,
      builder: (c, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _note(
            p,
            LucideIcons.ghost,
            l?.ghostLoading ?? 'Loading your ghost',
          );
        }
        final t = snap.data;
        if (t == null) {
          return _note(
            p,
            LucideIcons.triangleAlert,
            l?.ghostLoadFailed ?? 'Could not load that ghost\'s route',
          );
        }
        return GhostPanel(
          track: t,
          elapsedSec: widget.elapsedSec,
          fix: widget.fix,
          buzz: widget.buzz,
          buzzOn: widget.buzzOn,
          keep: widget.keep,
        );
      },
    );
  }

  Widget _note(P p, IconData i, String s) => Surface(
    child: Row(
      children: [
        Icon(i, size: 18, color: p.ink2),
        const SizedBox(width: S.x3),
        Expanded(
          child: Text(s, style: F.body.copyWith(color: p.ink2)),
        ),
      ],
    ),
  );
}

/// How a race keeps going while its screen is minimised: the race and buzz
/// state live in [_keeps] under [key], and a one-second timer carries on
/// from [elapsedSec] (null = the session is over) and [fix].
class GhostKeep {
  final String key;
  final int? Function() elapsedSec;
  final LatLng? Function() fix;
  const GhostKeep(this.key, this.elapsedSec, this.fix);
}

class _Keep {
  final GhostRace race;
  final GhostBuzzPolicy policy = GhostBuzzPolicy();
  Timer? timer;
  _Keep(GhostTrack t) : race = GhostRace(t);
}

final Map<String, _Keep> _keeps = {};

/// The live gap, the mini route and the finish moment. Takes the race clock
/// and the latest fix; owns the race state, the trail and the buzz debounce.
/// A fake feed (elapsed + fix) is all a test needs.
class GhostPanel extends StatefulWidget {
  final GhostTrack track;
  final int elapsedSec;
  final LatLng? fix;
  final Future<void> Function()? buzz;
  final bool buzzOn;
  final GhostKeep? keep;
  const GhostPanel({
    super.key,
    required this.track,
    required this.elapsedSec,
    required this.fix,
    this.buzz,
    this.buzzOn = true,
    this.keep,
  });

  @override
  State<GhostPanel> createState() => _GhostPanelState();
}

class _GhostPanelState extends State<GhostPanel> {
  late final _Keep _k = widget.keep == null
      ? _Keep(widget.track)
      : _keeps.putIfAbsent(widget.keep!.key, () => _Keep(widget.track));
  GhostRace get _race => _k.race;
  GhostBuzzPolicy get _policy => _k.policy;
  final List<LatLng> _trail = [];
  late GhostReading _r;
  bool _wonHaptic = false;

  @override
  void initState() {
    super.initState();
    _k.timer?.cancel();
    _k.timer = null;
    _r = _step();
  }

  @override
  void dispose() {
    final keep = widget.keep;
    // Minimised, not finished: carry on buzzing from the session clock.
    if (keep != null && keep.elapsedSec() != null) {
      final buzz = widget.buzz, on = widget.buzzOn;
      _k.timer = Timer.periodic(Motion.tick, (t) {
        final e = keep.elapsedSec();
        if (e == null) {
          t.cancel();
          _keeps.remove(keep.key);
          return;
        }
        final f = keep.fix();
        final r = _k.race.update(e * 1000, lat: f?.latitude, lng: f?.longitude);
        if (on && _k.policy.shouldBuzz(r, e * 1000)) {
          HapticFeedback.mediumImpact();
          if (buzz != null) unawaited(buzz().catchError((_) {}));
        }
      });
    } else if (keep != null) {
      _keeps.remove(keep.key);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(GhostPanel old) {
    super.didUpdateWidget(old);
    if (old.elapsedSec == widget.elapsedSec && old.fix == widget.fix) return;
    final before = _r.state;
    _r = _step();
    final l = AppLocalizations.of(context);
    if (widget.buzzOn && _policy.shouldBuzz(_r, widget.elapsedSec * 1000)) {
      // The phone is in a pocket: the band is the cue that reaches you. Best
      // effort, never awaited, never an error.
      HapticFeedback.mediumImpact();
      final b = widget.buzz;
      if (b != null) unawaited(b().catchError((_) {}));
      say(
        context,
        _r.gapM! > 0
            ? (l?.ghostAhead(ghostGapText(_r.gapM!)) ??
                  '${ghostGapText(_r.gapM!)} ahead')
            : (l?.ghostBehind(ghostGapText(_r.gapM!)) ??
                  '${ghostGapText(_r.gapM!)} behind'),
      );
    }
    if (_r.state == GhostState.finished &&
        before != GhostState.finished &&
        !_wonHaptic) {
      _wonHaptic = true;
      if ((_r.gapSec ?? 0) > 0) HapticFeedback.heavyImpact();
    }
  }

  GhostReading _step() {
    final f = widget.fix;
    if (f != null &&
        (_trail.isEmpty ||
            const Distance().as(LengthUnit.Meter, _trail.last, f) >= 3)) {
      _trail.add(f);
      // ponytail: drop every other point past 600 (keeps the shape, bounds work)
      if (_trail.length > 600) {
        final keep = [for (var i = 0; i < _trail.length; i += 2) _trail[i]];
        _trail
          ..clear()
          ..addAll(keep);
      }
    }
    return _race.update(
      widget.elapsedSec * 1000,
      lat: f?.latitude,
      lng: f?.longitude,
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final r = _r;
    final (accent, icon) = _look(r.state);
    final gap = r.gapM;
    final sec = r.gapSec;

    final String head = switch (r.state) {
      GhostState.waiting => l?.ghostWaiting ?? 'Waiting for GPS',
      GhostState.offRoute =>
        l?.ghostOffRoute ??
            'Not on the ghost\'s route, so there is no gap to show',
      GhostState.level => l?.ghostLevel ?? 'Level with your ghost',
      GhostState.finished when (sec ?? 0) > 0 =>
        l?.ghostWon(ghostTimeText(sec!)) ??
            'You beat your ghost by ${ghostTimeText(sec!)}',
      GhostState.finished when (sec ?? 0) < 0 =>
        l?.ghostLost(ghostTimeText(sec!)) ??
            'Your ghost won by ${ghostTimeText(sec!)}',
      GhostState.finished => l?.ghostTied ?? 'Dead level with your ghost',
      GhostState.ahead =>
        l?.ghostAhead(ghostGapText(gap!)) ?? '${ghostGapText(gap!)} ahead',
      GhostState.behind =>
        l?.ghostBehind(ghostGapText(gap!)) ?? '${ghostGapText(gap!)} behind',
    };
    final bool big =
        r.state == GhostState.ahead ||
        r.state == GhostState.behind ||
        r.state == GhostState.finished;
    // Seconds ride underneath; a sub-two-second figure is noise.
    final String? sub =
        (r.state == GhostState.ahead || r.state == GhostState.behind) &&
            sec != null &&
            sec.abs() >= 2
        ? (sec > 0
              ? (l?.ghostSecAhead(ghostTimeText(sec)) ??
                    '${ghostTimeText(sec)} ahead of your ghost')
              : (l?.ghostSecBehind(ghostTimeText(sec)) ??
                    '${ghostTimeText(sec)} behind your ghost'))
        : null;

    final won = r.state == GhostState.finished && (sec ?? 0) > 0;
    return Semantics(
      container: true,
      label: sub == null ? head : '$head. $sub',
      child: ExcludeSemantics(
        child: Surface(
          key: const Key('ghost-panel'),
          color: p.wash(accent),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TweenAnimationBuilder<double>(
                    key: ValueKey(r.state),
                    tween: Tween(begin: Motion.enabled(c) ? .6 : 1, end: 1),
                    duration: motion(c, Motion.slow),
                    curve: Curves.easeOutBack,
                    builder: (_, s, child) =>
                        Transform.scale(scale: s, child: child),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: p.fill(accent),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        won ? LucideIcons.trophy : icon,
                        size: 22,
                        color: p.inkOnFill,
                      ),
                    ),
                  ),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          head,
                          key: const Key('ghost-gap'),
                          style: (big ? F.t1 : F.body).copyWith(
                            color: p.on(accent),
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (sub != null)
                          Text(
                            sub,
                            key: const Key('ghost-gap-sec'),
                            style: F.cap.copyWith(color: p.ink2),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: S.x4),
              ClipRRect(
                borderRadius: R.rMd,
                child: Container(
                  height: 128,
                  color: p.card2,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _GhostMapPainter(
                      ghost: [
                        for (final q in _thin(widget.track.pts))
                          LatLng(q.lat, q.lng),
                      ],
                      trail: List.of(_trail),
                      ghostNow: LatLng(r.ghostLat, r.ghostLng),
                      pathInk: p.ink3.withValues(alpha: .55),
                      youInk: p.on(C.blue),
                      ghostInk: p.on(C.purple),
                      haloInk: p.card,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: S.x2),
              Row(
                children: [
                  _legend(p, p.on(C.blue), true, l?.ghostYou ?? 'You'),
                  const SizedBox(width: S.x4),
                  _legend(
                    p,
                    p.on(C.purple),
                    false,
                    l?.ghostGhostLegend ?? 'Ghost',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// At most ~200 points of the ghost's path: enough to draw the shape.
  static List<RoutePoint> _thin(List<RoutePoint> pts) {
    if (pts.length <= 200) return pts;
    final step = (pts.length / 200).ceil();
    return [for (var i = 0; i < pts.length; i += step) pts[i], pts.last];
  }

  Widget _legend(P p, Color ink, bool filled, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? ink : null,
          border: filled ? null : Border.all(color: ink, width: 2),
        ),
      ),
      const SizedBox(width: S.x1),
      Text(text, style: F.over.copyWith(color: p.ink3)),
    ],
  );
}

/// The ghost's path, your trail, and the two markers: you filled, the ghost
/// hollow. Uniform scale with the cos(lat) squeeze, so the shape drawn is the
/// shape run.
class _GhostMapPainter extends CustomPainter implements GuidePlot {
  final List<LatLng> ghost, trail;
  final LatLng ghostNow;
  final Color pathInk, youInk, ghostInk, haloInk;
  _GhostMapPainter({
    required this.ghost,
    required this.trail,
    required this.ghostNow,
    required this.pathInk,
    required this.youInk,
    required this.ghostInk,
    required this.haloInk,
  });

  @override
  Color get guideLineColor => pathInk;

  @override
  void paint(Canvas cv, Size s) {
    final all = [...ghost, ...trail, ghostNow];
    var minLa = all.first.latitude, maxLa = minLa;
    var minLo = all.first.longitude, maxLo = minLo;
    for (final q in all) {
      minLa = math.min(minLa, q.latitude);
      maxLa = math.max(maxLa, q.latitude);
      minLo = math.min(minLo, q.longitude);
      maxLo = math.max(maxLo, q.longitude);
    }
    final kx = math.cos((minLa + maxLa) / 2 * math.pi / 180);
    final w = math.max((maxLo - minLo) * kx, 1e-6);
    final h = math.max(maxLa - minLa, 1e-6);
    const pad = 14.0;
    final k = math.min((s.width - 2 * pad) / w, (s.height - 2 * pad) / h);
    final ox = (s.width - w * k) / 2, oy = (s.height - h * k) / 2;
    Offset at(LatLng q) => Offset(
      ox + (q.longitude - minLo) * kx * k,
      oy + (maxLa - q.latitude) * k,
    );

    Path line(List<LatLng> pts) {
      final p = Path();
      for (var i = 0; i < pts.length; i++) {
        final o = at(pts[i]);
        i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
      }
      return p;
    }

    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    cv.drawPath(line(ghost), stroke(pathInk, 3));
    if (trail.length > 1) cv.drawPath(line(trail), stroke(youInk, 3.5));

    final g = at(ghostNow);
    cv.drawCircle(g, 8, Paint()..color = haloInk);
    cv.drawCircle(g, 7, stroke(ghostInk, 2.5));
    if (trail.isNotEmpty) {
      final y = at(trail.last);
      cv.drawCircle(y, 8, Paint()..color = haloInk);
      cv.drawCircle(y, 6, Paint()..color = youInk);
    }
  }

  @override
  bool shouldRepaint(_GhostMapPainter o) => true;
}

// ══════════════ PICKER (setup) ══════════════

/// What the picker returns: [picked] null means "no ghost". A dismissed sheet
/// returns null from [pickGhost] itself, which leaves the choice alone.
typedef GhostPick = ({GhostCandidate? picked});

String ghostCandidateLabel(BuildContext c, GhostCandidate g) {
  final dist =
      unitsOf(c)?.distance(g.distanceM) ??
      '${(g.distanceM / 1000).toStringAsFixed(2)} km';
  return '${displayDate(c, g.start)} · $dist · ${_clock(g.durationSec)}';
}

String _clock(int sec) {
  final h = sec ~/ 3600, m = (sec ~/ 60) % 60, s = sec % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Bottom sheet listing earlier runs that can be raced. Refused ones are
/// listed greyed with the plain reason, so a missing run is explained rather
/// than silently absent.
Future<GhostPick?> pickGhost(
  BuildContext context, {
  required String typeKey,
  required GhostCandidatesLoader load,
  String? selectedId,
}) {
  return showModalBottomSheet<GhostPick>(
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle(
      duration: motion(context, Motion.slow),
      reverseDuration: motion(context, Motion.base),
    ),
    builder: (_) => _GhostPicker(typeKey, load, selectedId),
  );
}

class _GhostPicker extends StatefulWidget {
  final String typeKey;
  final GhostCandidatesLoader load;
  final String? selectedId;
  const _GhostPicker(this.typeKey, this.load, this.selectedId);

  @override
  State<_GhostPicker> createState() => _GhostPickerState();
}

class _GhostPickerState extends State<_GhostPicker> {
  late Future<List<GhostCandidate>> _f = widget.load(widget.typeKey);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Container(
      color: p.bg,
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(c).height * .75,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x5, S.x4, S.x4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.ghost, size: 22, color: p.on(C.purple)),
                    const SizedBox(width: S.x3),
                    Expanded(
                      child: Text(
                        l?.ghostPickerTitle ?? 'Pick a ghost',
                        style: F.t2.copyWith(color: p.ink),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: S.x3),
                Flexible(
                  child: FutureBuilder<List<GhostCandidate>>(
                    future: _f,
                    builder: (c, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Padding(
                          padding: EdgeInsets.all(S.x8),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final list = snap.data ?? const <GhostCandidate>[];
                      return ListView(
                        shrinkWrap: true,
                        children: [
                          if (snap.hasError)
                            _tile(
                              p,
                              title:
                                  l?.ghostReadFailed ??
                                  'Could not read your saved routes. Tap to retry.',
                              icon: LucideIcons.refreshCw,
                              onTap: () => setState(() {
                                _f = widget.load(widget.typeKey);
                              }),
                            )
                          else if (list.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(S.x4),
                              child: Text(
                                l?.ghostPickerEmpty ??
                                    'No earlier session of this activity has a '
                                        'recorded route yet. Finish one with '
                                        'location on, then come back.',
                                style: F.body.copyWith(color: p.ink2),
                              ),
                            ),
                          for (final g in list) _row(c, p, l, g),
                          if (widget.selectedId != null)
                            _tile(
                              p,
                              title: l?.ghostPickerNone ?? 'No ghost',
                              icon: LucideIcons.x,
                              onTap: () => Navigator.of(
                                c,
                              ).pop<GhostPick>((picked: null)),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext c, P p, AppLocalizations? l, GhostCandidate g) {
    final r = g.refusal;
    return _tile(
      p,
      title: ghostCandidateLabel(c, g),
      sub: r == null ? null : _refusalText(l, r),
      icon: g.id == widget.selectedId
          ? LucideIcons.circleCheck
          : LucideIcons.ghost,
      enabled: r == null,
      onTap: () => Navigator.of(c).pop<GhostPick>((picked: g)),
    );
  }

  Widget _tile(
    P p, {
    required String title,
    String? sub,
    required IconData icon,
    bool enabled = true,
    required VoidCallback onTap,
  }) => Pressable(
    semanticLabel: sub == null ? title : '$title, $sub',
    onTap: enabled ? onTap : null,
    child: Container(
      constraints: const BoxConstraints(minHeight: S.tap),
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: enabled ? p.ink2 : p.ink3),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: F.body.copyWith(color: enabled ? p.ink : p.ink3),
                ),
                if (sub != null)
                  Text(sub, style: F.over.copyWith(color: p.ink3)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

// ══════════════ SUMMARY ══════════════

/// Loads both routes and draws the comparison.
class GhostSummary extends StatefulWidget {
  final String ghostId;
  final String sessionId;
  final GhostRouteLoader? loadRoute;
  final List<(int, int)> pausedMs;
  const GhostSummary({
    super.key,
    required this.ghostId,
    required this.sessionId,
    required this.loadRoute,
    this.pausedMs = const [],
  });

  @override
  State<GhostSummary> createState() => _GhostSummaryState();
}

class _GhostSummaryState extends State<GhostSummary> {
  // Survives the card being unmounted by a tab switch: the comparison is not
  // re-read and the win haptic is not replayed.
  static final Map<String, Future<GhostComparison?>> _cache = {};
  late final String _key = '${widget.sessionId}|${widget.ghostId}';
  late Future<GhostComparison?> _f = _cache.putIfAbsent(_key, _load);

  Future<GhostComparison?> _load() async {
    final load = widget.loadRoute;
    if (load == null) return null;
    final you = await load(widget.sessionId);
    final ghost = await load(widget.ghostId);
    if (you == null || ghost == null) return null;
    return compareRuns(you, ghost, pausedMs: widget.pausedMs);
  }

  @override
  Widget build(BuildContext c) => FutureBuilder<GhostComparison?>(
    future: _f,
    builder: (c, s) => s.connectionState != ConnectionState.done
        ? const SizedBox.shrink()
        : s.hasError
        ? _GhostReadFailed(onRetry: () {
            _cache.remove(_key);
            setState(() {
              _f = _cache.putIfAbsent(_key, _load);
            });
          })
        : GhostSummaryCard(s.data, hapticKey: _key),
  );
}

/// The result card. [comparison] null draws the refusal: never a time that
/// was not computed.
class GhostSummaryCard extends StatefulWidget {
  final GhostComparison? comparison;

  /// Set: the win haptic plays once per key for the life of the process.
  final String? hapticKey;
  const GhostSummaryCard(this.comparison, {super.key, this.hapticKey});

  @override
  State<GhostSummaryCard> createState() => _GhostSummaryCardState();
}

final Set<String> _hapticDone = {};

/// A route read that threw: said as such, with a retry, never as "not the
/// same route".
class _GhostReadFailed extends StatelessWidget {
  final VoidCallback onRetry;
  const _GhostReadFailed({required this.onRetry});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Pressable(
      onTap: onRetry,
      child: Surface(
        child: Row(
          children: [
            Icon(LucideIcons.refreshCw, size: 18, color: p.ink2),
            const SizedBox(width: S.x3),
            Expanded(
              child: Text(
                l?.ghostReadFailed ??
                    'Could not read your saved routes. Tap to retry.',
                style: F.body.copyWith(color: p.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GhostSummaryCardState extends State<GhostSummaryCard> {
  @override
  void initState() {
    super.initState();
    // The win moment: one firm tap, once, when the card first shows a win.
    if (widget.comparison?.won == true && widget.comparison!.finalGapSec >= 1) {
      final k = widget.hapticKey;
      if (k != null && !_hapticDone.add(k)) return;
      HapticFeedback.heavyImpact();
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final cmp = widget.comparison;
    if (cmp == null) {
      return Surface(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.ghost, size: 20, color: p.ink3),
            const SizedBox(width: S.x3),
            Expanded(
              child: Text(
                l?.ghostNoCompare ??
                    'Not compared: this was not the same route as the ghost, '
                        'or too little of it was covered.',
                style: F.body.copyWith(color: p.ink2),
              ),
            ),
          ],
        ),
      );
    }
    final gap = cmp.finalGapSec;
    final level = gap.abs() < 1;
    final accent = level ? C.blue : (gap > 0 ? C.green : C.orange);
    final head = level
        ? (l?.ghostTied ?? 'Dead level with your ghost')
        : gap > 0
        ? (l?.ghostWon(ghostTimeText(gap)) ??
              'You beat your ghost by ${ghostTimeText(gap)}')
        : (l?.ghostLost(ghostTimeText(gap)) ??
              'Your ghost won by ${ghostTimeText(gap)}');
    final maxAbs = cmp.splits.fold<double>(
      1,
      (m, s) => math.max(m, s.deltaSec.abs()),
    );

    String km(GhostSplit s) => ghostSplitKm(s);
    final best = cmp.biggestGain, worst = cmp.biggestLoss;
    return Surface(
      color: p.wash(accent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: Motion.enabled(c) ? .5 : 1, end: 1),
                duration: motion(c, Motion.slow),
                curve: Curves.easeOutBack,
                builder: (_, s, child) =>
                    Transform.scale(scale: s, child: child),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: p.fill(accent),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    level
                        ? LucideIcons.equal
                        : gap > 0
                        ? LucideIcons.trophy
                        : LucideIcons.ghost,
                    size: 24,
                    color: p.inkOnFill,
                  ),
                ),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    head,
                    key: const Key('ghost-result'),
                    style: F.t2.copyWith(color: p.on(accent)),
                  ),
                ),
              ),
            ],
          ),
          if (cmp.splits.isNotEmpty) ...[
            const SizedBox(height: S.x4),
            for (final s in cmp.splits) _splitRow(c, p, l, s, maxAbs),
          ],
          if (best != null || worst != null) ...[
            const SizedBox(height: S.x3),
            if (best != null)
              Text(
                l?.ghostBestStretch(km(best), ghostTimeText(best.deltaSec)) ??
                    'Most time gained: km ${km(best)}, '
                        '${ghostTimeText(best.deltaSec)} up',
                style: F.cap.copyWith(color: p.ink2),
              ),
            if (worst != null)
              Text(
                l?.ghostWorstStretch(
                      km(worst),
                      ghostTimeText(worst.deltaSec),
                    ) ??
                    'Most time lost: km ${km(worst)}, '
                        '${ghostTimeText(worst.deltaSec)} down',
                style: F.cap.copyWith(color: p.ink2),
              ),
          ],
          const SizedBox(height: S.x3),
          Text(
            l?.ghostEstimateNote ??
                'Gaps come from GPS fixes and are estimates. A few metres is '
                    'inside GPS drift, so it reads as level.',
            style: F.over.copyWith(color: p.ink3),
          ),
        ],
      ),
    );
  }

  /// One split: label, a bar centred on zero (right = gained, left = lost),
  /// and the signed seconds.
  Widget _splitRow(
    BuildContext c,
    P p,
    AppLocalizations? l,
    GhostSplit s,
    double maxAbs,
  ) {
    final up = s.deltaSec >= 0;
    final accent = up ? C.green : C.orange;
    final f = (s.deltaSec.abs() / maxAbs).clamp(0.0, 1.0);
    final label = l?.ghostSplitLabel(ghostSplitKm(s)) ?? 'km ${ghostSplitKm(s)}';
    final txt = '${up ? '+' : '-'}${ghostTimeText(s.deltaSec)}';
    return Semantics(
      label: '$label, $txt',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x1),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(label, style: F.cap.copyWith(color: p.ink2)),
              ),
              Expanded(
                child: SizedBox(
                  height: 14,
                  child: LayoutBuilder(
                    builder: (_, bc) {
                      final half = bc.maxWidth / 2;
                      final w = math.max(half * f, 2.0);
                      return Stack(
                        children: [
                          Positioned(
                            left: half - .5,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 1, color: p.line),
                          ),
                          Positioned(
                            left: up ? half : half - w,
                            top: 2,
                            bottom: 2,
                            child: Container(
                              width: w,
                              decoration: BoxDecoration(
                                color: p.fill(accent),
                                borderRadius: R.rSm,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  txt,
                  textAlign: TextAlign.end,
                  style: F.cap.copyWith(color: p.on(accent)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
