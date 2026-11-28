// Ghost run maths: race a stored route as it was run, by the clock.
//
// Pure and deterministic: no DB, no I/O, no clock. Time comes in as elapsed
// milliseconds, positions as lat/lng. Everything the live card and the summary
// show is computed here, so it is all unit-testable on synthetic routes.
//
// Sign convention everywhere: POSITIVE gap = you are ahead of the ghost.
//
// What this refuses to do: invent a gap it cannot compute. No fix means no
// reading; a fix off the ghost's path means "off route", not a number.

import 'dart:math' as math;

import 'route_math.dart' show haversineMeters;
import 'route_models.dart';

/// Gaps smaller than this read as "level": consumer GPS wanders a few metres
/// between fixes, and a gap inside that wander is noise, not a lead.
const double kGhostLevelM = 5.0;

/// A fix further than this from the ghost's path is not on its route.
const double kGhostOffRouteM = 50.0;

/// Start must be within this of the ghost's start to race it.
const double kGhostStartNearM = 250.0;

/// The start-proximity check applies to fixes this early in the race.
const int kGhostStartWindowSec = 120;

/// Minimum shape of a route worth racing.
const int kGhostMinPoints = 20;
const double kGhostMinMeters = 400.0;
const int kGhostMinSeconds = 120;

/// Why a stored route can not be raced. Null from [ghostUnusableReason] = ok.
enum GhostRefusal { tooFewPoints, tooShort, tooBrief, brokenClock, gappy }

/// Plain check of a stored route's shape. Returns null when it is usable.
GhostRefusal? ghostUnusableReason(List<RoutePoint> pts) {
  if (pts.length < kGhostMinPoints) return GhostRefusal.tooFewPoints;
  for (var i = 1; i < pts.length; i++) {
    if (pts[i].tsMs <= pts[i - 1].tsMs) return GhostRefusal.brokenClock;
  }
  final dur = pts.last.tsMs - pts.first.tsMs;
  if (dur < kGhostMinSeconds * 1000) return GhostRefusal.tooBrief;
  var m = 0.0;
  var gapMs = 0;
  for (var i = 1; i < pts.length; i++) {
    m += haversineMeters(
      pts[i - 1].lat,
      pts[i - 1].lng,
      pts[i].lat,
      pts[i].lng,
    );
    final dt = pts[i].tsMs - pts[i - 1].tsMs;
    if (dt > 60000) gapMs += dt;
  }
  if (m < kGhostMinMeters) return GhostRefusal.tooShort;
  // More than a quarter of the run unrecorded: the ghost would be guessing.
  if (gapMs > dur / 4) return GhostRefusal.gappy;
  return null;
}

/// Where on a [GhostTrack] a point lands.
class GhostProjection {
  /// Metres along the track to the nearest point on it.
  final double alongM;

  /// How far the point is from the track, metres.
  final double offsetM;
  const GhostProjection(this.alongM, this.offsetM);
}

/// A stored route made ready for racing: cumulative distance per point and
/// lookups by time and by distance.
class GhostTrack {
  final List<RoutePoint> pts;
  final List<double> cum; // metres from the start, one per point
  GhostTrack._(this.pts, this.cum);

  /// Null unless [pts] is usable (see [ghostUnusableReason]).
  static GhostTrack? tryBuild(List<RoutePoint> pts) {
    if (ghostUnusableReason(pts) != null) return null;
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(
        cum.last +
            haversineMeters(
              pts[i - 1].lat,
              pts[i - 1].lng,
              pts[i].lat,
              pts[i].lng,
            ),
      );
    }
    return GhostTrack._(pts, cum);
  }

  double get totalM => cum.last;
  int get durationMs => pts.last.tsMs - pts.first.tsMs;
  RoutePoint get start => pts.first;

  /// Index i such that t lies in [pts[i], pts[i+1]]; t is ms since start.
  int _segByTime(int tMs) {
    var lo = 0, hi = pts.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (pts[mid].tsMs - pts.first.tsMs <= tMs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The ghost at [elapsedMs] after it started: position and distance covered,
  /// linearly interpolated between the stored fixes. Clamped to the finish.
  ({double lat, double lng, double distM}) at(int elapsedMs) {
    if (elapsedMs <= 0) {
      return (lat: pts.first.lat, lng: pts.first.lng, distM: 0);
    }
    if (elapsedMs >= durationMs) {
      return (lat: pts.last.lat, lng: pts.last.lng, distM: totalM);
    }
    final i = _segByTime(elapsedMs);
    final a = pts[i], b = pts[i + 1];
    final span = (b.tsMs - a.tsMs).toDouble();
    final f = (elapsedMs - (a.tsMs - pts.first.tsMs)) / span;
    return (
      lat: a.lat + (b.lat - a.lat) * f,
      lng: a.lng + (b.lng - a.lng) * f,
      distM: cum[i] + (cum[i + 1] - cum[i]) * f,
    );
  }

  /// Milliseconds after its start that the ghost was [distM] along. Clamped
  /// to [0, durationMs]. Where the ghost stood still the EARLIEST time at
  /// that distance is returned (you were "there" when it first arrived).
  int timeAtDistM(double distM) {
    if (distM <= 0) return 0;
    if (distM >= totalM) return durationMs;
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] < distM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    // cum[lo] < distM <= cum[hi]
    final span = cum[hi] - cum[lo];
    final f = span <= 0 ? 0.0 : (distM - cum[lo]) / span;
    final ta = pts[lo].tsMs - pts.first.tsMs;
    final tb = pts[hi].tsMs - pts.first.tsMs;
    return (ta + (tb - ta) * f).round();
  }

  /// Nearest point on the track to ([lat], [lng]).
  ///
  /// With [nearM] the search is limited to a window around that distance
  /// (so a loop that revisits a spot does not teleport you a lap ahead),
  /// falling back to the whole track when nothing in the window is close.
  GhostProjection project(
    double lat,
    double lng, {
    double? nearM,
    double backM = 150,
    double aheadM = 600,
  }) {
    if (nearM != null) {
      final w = _search(lat, lng, nearM - backM, nearM + aheadM);
      if (w.offsetM <= kGhostOffRouteM) return w;
    }
    return _search(lat, lng, double.negativeInfinity, double.infinity);
  }

  GhostProjection _search(double lat, double lng, double fromM, double toM) {
    final mLat = 111320.0;
    final mLng = 111320.0 * math.cos(lat * math.pi / 180);
    var bestOff = double.infinity, bestAlong = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      if (cum[i + 1] < fromM || cum[i] > toM) continue;
      final ax = (pts[i].lng - lng) * mLng, ay = (pts[i].lat - lat) * mLat;
      final bx = (pts[i + 1].lng - lng) * mLng,
          by = (pts[i + 1].lat - lat) * mLat;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0
          ? 0.0
          : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0).toDouble();
      final px = ax + dx * t, py = ay + dy * t;
      final off = math.sqrt(px * px + py * py);
      if (off < bestOff) {
        bestOff = off;
        bestAlong = cum[i] + (cum[i + 1] - cum[i]) * t;
      }
    }
    return GhostProjection(bestAlong, bestOff);
  }
}

/// What the live card shows.
enum GhostState {
  /// No fix yet: nothing to compare.
  waiting,

  /// You are not where the ghost's route is (too far from its start, or off
  /// its path). No gap is reported.
  offRoute,
  level,
  ahead,
  behind,

  /// The ghost has finished and you have too (or passed its finish).
  finished,
}

class GhostReading {
  final GhostState state;

  /// Metres ahead (+) or behind (-). Null when not computable.
  final double? gapM;

  /// Seconds ahead (+) or behind (-): how much earlier (+) or later (-) the
  /// ghost was at the spot you are at now. Null when not computable.
  final double? gapSec;

  /// The ghost's current position (always known once the race clock runs).
  final double ghostLat, ghostLng;

  /// Your distance along the ghost's route and the ghost's, metres.
  final double? userAlongM;
  final double ghostAlongM;
  final double offsetM;
  const GhostReading(
    this.state, {
    this.gapM,
    this.gapSec,
    required this.ghostLat,
    required this.ghostLng,
    this.userAlongM,
    required this.ghostAlongM,
    this.offsetM = 0,
  });
}

/// One race against a [GhostTrack]. Feed it the race clock and your latest fix.
class GhostRace {
  final GhostTrack track;
  double? _lastAlong;
  GhostRace(this.track);

  /// [elapsedMs] is your session clock; [lat]/[lng] your latest fix, or null
  /// when there is none (then the state is [GhostState.waiting]).
  GhostReading update(int elapsedMs, {double? lat, double? lng}) {
    final g = track.at(elapsedMs);
    GhostReading r(
      GhostState s, {
      double? gapM,
      double? gapSec,
      double? along,
      double off = 0,
    }) => GhostReading(
      s,
      gapM: gapM,
      gapSec: gapSec,
      ghostLat: g.lat,
      ghostLng: g.lng,
      userAlongM: along,
      ghostAlongM: g.distM,
      offsetM: off,
    );
    if (lat == null || lng == null) return r(GhostState.waiting);
    // Before any progress is known you must be at the start; this is the
    // "different place" refusal, in metres, not a guess.
    // Only at the start of the race: a late first fix or a resumed session
    // legitimately begins mid-route.
    if (_lastAlong == null && elapsedMs <= kGhostStartWindowSec * 1000) {
      final d = haversineMeters(lat, lng, track.start.lat, track.start.lng);
      if (d > kGhostStartNearM) {
        return r(GhostState.offRoute, off: d);
      }
    }
    final p = track.project(lat, lng, nearM: _lastAlong);
    if (p.offsetM > kGhostOffRouteM) {
      return r(GhostState.offRoute, off: p.offsetM);
    }
    _lastAlong = p.alongM;
    final gapM = p.alongM - g.distM;
    // Seconds: the ghost stood where you stand at time tg; you are here at
    // `elapsed`. Arriving sooner is ahead, so the gap is tg - elapsed.
    final tg = track.timeAtDistM(p.alongM);
    final gapSec = (tg - elapsedMs) / 1000.0;
    if (p.alongM >= track.totalM - kGhostLevelM) {
      return r(
        GhostState.finished,
        gapM: gapM,
        gapSec: gapSec,
        along: p.alongM,
        off: p.offsetM,
      );
    }
    final s = gapM.abs() < kGhostLevelM
        ? GhostState.level
        : (gapM > 0 ? GhostState.ahead : GhostState.behind);
    return r(s, gapM: gapM, gapSec: gapSec, along: p.alongM, off: p.offsetM);
  }
}

/// Buzz decision for the ghost race. Mirrors the zone-alert debounce: it
/// fires only when the lead CHANGES side by more than [thresholdM], and never
/// more than once per [cooldownMs], so a gap hovering on the threshold can not
/// spam the band.
class GhostBuzzPolicy {
  final double thresholdM;
  final int cooldownMs;
  GhostBuzzPolicy({this.thresholdM = 20, this.cooldownMs = 45000});

  // +1 ahead, -1 behind, 0 not yet decided (inside the dead band).
  int _side = 0;
  int? _lastBuzzMs;

  /// True when the band should buzz now. [nowMs] is the race clock.
  bool shouldBuzz(GhostReading r, int nowMs) {
    final gap = r.gapM;
    if (r.state == GhostState.offRoute ||
        r.state == GhostState.waiting ||
        gap == null) {
      return false;
    }
    final side = gap >= thresholdM ? 1 : (gap <= -thresholdM ? -1 : 0);
    if (side == 0 || side == _side) return false;
    final first = _side == 0; // first side taken: remember, do not buzz
    _side = side;
    if (first) return false;
    final last = _lastBuzzMs;
    if (last != null && nowMs - last < cooldownMs) return false;
    _lastBuzzMs = nowMs;
    return true;
  }
}

/// Resample [pts] to roughly every [stepM] metres of path (always including
/// the first point), for cheap shape comparison.
List<RoutePoint> _everyM(List<RoutePoint> pts, double stepM) {
  if (pts.isEmpty) return const [];
  final out = [pts.first];
  var acc = 0.0;
  for (var i = 1; i < pts.length; i++) {
    acc += haversineMeters(
      pts[i - 1].lat,
      pts[i - 1].lng,
      pts[i].lat,
      pts[i].lng,
    );
    if (acc >= stepM) {
      out.add(pts[i]);
      acc = 0;
    }
  }
  return out;
}

/// How much two routes follow the same path, 0..1: the share of one route's
/// points that lie within [toleranceM] of the other, taking the WORSE of the
/// two directions (so a short loop inside a long route does not pass).
/// Null when either route is unusable as a track.
double? routeSimilarity(
  List<RoutePoint> a,
  List<RoutePoint> b, {
  double toleranceM = 40,
  double stepM = 30,
}) {
  final ta = GhostTrack.tryBuild(a), tb = GhostTrack.tryBuild(b);
  if (ta == null || tb == null) return null;
  double share(List<RoutePoint> from, GhostTrack onto) {
    final s = _everyM(from, stepM);
    var near = 0;
    for (final p in s) {
      if (onto.project(p.lat, p.lng).offsetM <= toleranceM) near++;
    }
    return near / s.length;
  }

  return math.min(share(a, tb), share(b, ta));
}

/// Same route if at least this share of points line up.
const double kSameRouteShare = 0.8;

// ── the comparison, after the fact ────────────────────────────────────────

class GhostSplit {
  final int index; // 1-based
  final double fromM, toM;

  /// Seconds you / the ghost took for this stretch.
  final double youSec, ghostSec;

  /// Seconds gained (+) or lost (-) over the stretch.
  double get deltaSec => ghostSec - youSec;
  const GhostSplit(
    this.index,
    this.fromM,
    this.toM,
    this.youSec,
    this.ghostSec,
  );
}

class GhostComparison {
  /// Final gap: seconds ahead (+) / behind (-) at the end of the shorter of
  /// the two runs, measured over the SAME distance.
  final double finalGapSec;

  /// The distance both runs covered along the ghost's route, metres.
  final double sharedM;
  final List<GhostSplit> splits;
  final GhostSplit? biggestGain, biggestLoss;
  bool get won => finalGapSec > 0;
  const GhostComparison(
    this.finalGapSec,
    this.sharedM,
    this.splits,
    this.biggestGain,
    this.biggestLoss,
  );
}

/// Compare a finished run against a ghost, split by [splitM]. Returns null
/// when the two are not the same route, or the run covered too little of it
/// to compare: never a fabricated time.
GhostComparison? compareRuns(
  List<RoutePoint> you,
  List<RoutePoint> ghost, {
  double splitM = 1000,
}) {
  final g = GhostTrack.tryBuild(ghost);
  final u = GhostTrack.tryBuild(you);
  if (g == null || u == null) return null;
  final sim = routeSimilarity(you, ghost);
  if (sim == null || sim < kSameRouteShare) return null;

  // Your elapsed time (ms) at each ghost-route distance, from your own fixes:
  // (alongM, tMs) pairs, forced monotonic so a drift wobble can not run time
  // or distance backwards.
  final marks = <(double, int)>[];
  double? near;
  var best = -1.0;
  for (final p in you) {
    final pr = g.project(p.lat, p.lng, nearM: near);
    if (pr.offsetM > kGhostOffRouteM) continue;
    near = pr.alongM;
    if (pr.alongM <= best) continue;
    best = pr.alongM;
    marks.add((best, p.tsMs - you.first.tsMs));
  }
  if (marks.length < 2) return null;
  final shared = marks.last.$1;
  if (shared < math.min(splitM, kGhostMinMeters)) return null;

  int? youAt(double d) {
    if (d < marks.first.$1 || d > marks.last.$1) return null;
    for (var i = 1; i < marks.length; i++) {
      if (marks[i].$1 >= d) {
        final (d0, t0) = marks[i - 1];
        final (d1, t1) = marks[i];
        final f = d1 == d0 ? 0.0 : (d - d0) / (d1 - d0);
        return (t0 + (t1 - t0) * f).round();
      }
    }
    return null;
  }

  final splits = <GhostSplit>[];
  var from = 0.0;
  var i = 1;
  while (from < shared - 1) {
    final to = math.min(from + splitM, shared);
    // A trailing sliver is not a split: it would show a noisy ±seconds.
    if (to - from < splitM * 0.25 && splits.isNotEmpty) break;
    final y0 = youAt(from);
    final y1 = youAt(to);
    if (y0 != null && y1 != null) {
      splits.add(
        GhostSplit(
          i,
          from,
          to,
          (y1 - y0) / 1000.0,
          (g.timeAtDistM(to) - g.timeAtDistM(from)) / 1000.0,
        ),
      );
    }
    from = to;
    i++;
  }
  final endYou = youAt(shared)!;
  final gap = (g.timeAtDistM(shared) - endYou) / 1000.0;
  GhostSplit? gain, loss;
  for (final s in splits) {
    if (s.deltaSec > 0 && (gain == null || s.deltaSec > gain.deltaSec)) {
      gain = s;
    }
    if (s.deltaSec < 0 && (loss == null || s.deltaSec < loss.deltaSec)) {
      loss = s;
    }
  }
  return GhostComparison(gap, shared, splits, gain, loss);
}
