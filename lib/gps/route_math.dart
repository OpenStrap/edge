// Pure route analytics — distance, splits, and HR-zone segmentation.
//
// Everything here is a pure function of its inputs (no DB, no I/O, no clock),
// so it is directly unit-testable and shared by the repository (splits) and the
// UI (zone-coloured polylines). Distances use the haversine great-circle
// formula on WGS84 mean radius; good to well under a metre at running scale.

import 'dart:math' as math;

import 'route_models.dart';

const double kEarthRadiusM = 6371008.8; // WGS84 mean radius
const double kMetersPerKm = 1000.0;
const double kMetersPerMile = 1609.344;

/// Fastest plausible sustained ground speed for any route-eligible activity
/// (run / walk / cycle) — ~90 km/h covers a hard cycling descent with margin.
const double kMaxPlausibleSpeedMps = 25.0;

/// Floor for the per-segment jump allowance: a 1 s GPS jitter spike is still
/// rejected even though 1 s × max speed would only allow 25 m.
const double kMinJumpAllowanceM = 200.0;

/// True when a segment of [meters] covered in [dtMs] is a GPS artifact rather
/// than plausible travel: the allowance scales with the TIME between the fixes
/// (gap seconds × plausible max speed, floored at [minJumpM]) — so a genuine
/// 5-minute signal gap allows the kilometres the athlete could really have
/// covered, while a 1 s teleport is still rejected.
bool isImplausibleSegment(
  double meters,
  int dtMs, {
  double minJumpM = kMinJumpAllowanceM,
  double maxSpeedMps = kMaxPlausibleSpeedMps,
}) {
  final gapSec = dtMs <= 0 ? 1.0 : dtMs / 1000.0;
  final allowed = math.max(minJumpM, gapSec * maxSpeedMps);
  return meters > allowed;
}

/// Exponential moving average for instantaneous speed. Raw GPS speed (even
/// the platform's Doppler-derived value) jitters fix-to-fix; a live "current
/// pace" readout built straight off it visibly flickers. [alpha] is the
/// weight given to the new sample — lower = smoother but slower to react to a
/// genuine pace change. 0.15 settles a step change in ~6-7 fixes while
/// damping single-fix Doppler/multipath noise harder than 0.25 did — a real
/// user report of transient implausible live-pace readings (e.g. "1:45/km"
/// for a jog) showed 0.25 still let a single noisy fix swing the displayed
/// pace too far for one fix's worth of real signal.
double emaSpeed(double? prevSmoothed, double raw, {double alpha = 0.15}) {
  if (prevSmoothed == null) return raw;
  return prevSmoothed + alpha * (raw - prevSmoothed);
}

/// Instantaneous speed (m/s) derived from two consecutive fixes, for when the
/// platform doesn't report `Position.speed` (some Android devices, or the
/// first fix). Less accurate than a real Doppler speed — position-fix jitter
/// is amplified by dividing a short distance by a short time — so callers
/// should prefer [GpsSample.speed] when present and only fall back to this.
double? fallbackSpeedMps(RoutePoint? prev, RoutePoint cur) {
  if (prev == null) return null;
  final dtSec = (cur.tsMs - prev.tsMs) / 1000.0;
  if (dtSec <= 0) return null;
  final m = haversineMeters(prev.lat, prev.lng, cur.lat, cur.lng);
  return m / dtSec;
}

/// Great-circle distance in metres between two lat/lng points.
double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const deg2rad = math.pi / 180.0;
  final dLat = (lat2 - lat1) * deg2rad;
  final dLng = (lng2 - lng1) * deg2rad;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * deg2rad) *
          math.cos(lat2 * deg2rad) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return kEarthRadiusM * c;
}

/// Total path length in metres over an ordered list of route points.
/// Implausible segments (a teleport across a recording gap — see
/// [isImplausibleSegment]) are treated as SEGMENT BREAKS and contribute no
/// distance, so a signal gap can't inflate the total.
double totalDistanceMeters(List<RoutePoint> pts) {
  var sum = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final m = haversineMeters(
        pts[i - 1].lat, pts[i - 1].lng, pts[i].lat, pts[i].lng);
    if (isImplausibleSegment(m, pts[i].tsMs - pts[i - 1].tsMs)) continue;
    sum += m;
  }
  return sum;
}

/// Moving time in seconds: the sum of inter-fix intervals, EXCLUDING gaps
/// longer than [maxGapSec] (paused at a light, screen off, signal lost — the
/// distance filter means standing still produces no fixes, so long gaps are
/// non-moving time and must not dilute the pace).
int movingSeconds(List<RoutePoint> pts, {int maxGapSec = 60}) {
  if (pts.length < 2) return 0;
  var ms = 0;
  for (var i = 1; i < pts.length; i++) {
    final dt = pts[i].tsMs - pts[i - 1].tsMs;
    if (dt <= 0 || dt > maxGapSec * 1000) continue;
    ms += dt;
  }
  return (ms / 1000).round();
}

/// HR → zone 0..5 as a fraction of max HR. Mirrors the app's live zone bands
/// (50/60/70/80/90 % thresholds) so the map colours match the rest of the UI.
int zoneForHr(int hr, int maxHr) {
  if (hr <= 0 || maxHr <= 0) return 0;
  final pct = hr / maxHr * 100;
  if (pct >= 90) return 5;
  if (pct >= 80) return 4;
  if (pct >= 70) return 3;
  if (pct >= 60) return 2;
  if (pct >= 50) return 1;
  return 0;
}

/// Find the HR (bpm) nearest in time to [tsMs], or null if [hr] is empty or the
/// nearest sample is further than [maxGapMs] away. `hr` must be sorted by tsMs.
int? nearestHr(List<HrSample> hr, int tsMs, {int maxGapMs = 15000}) {
  if (hr.isEmpty) return null;
  // Binary search for the insertion point.
  var lo = 0, hi = hr.length - 1;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (hr[mid].tsMs < tsMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  // Compare the candidate at `lo` and its predecessor.
  var best = hr[lo];
  var bestGap = (hr[lo].tsMs - tsMs).abs();
  if (lo > 0) {
    final prevGap = (hr[lo - 1].tsMs - tsMs).abs();
    if (prevGap < bestGap) {
      best = hr[lo - 1];
      bestGap = prevGap;
    }
  }
  if (bestGap > maxGapMs) return null;
  return best.hr;
}

/// Build map vertices, colouring each by the HR zone nearest it in time.
/// `hr` must be sorted ascending by tsMs. A vertex that follows an implausible
/// segment (recording gap) is flagged `gapBefore` so the map breaks the
/// polyline instead of drawing a straight line across the gap.
List<RouteVertex> buildVertices(
    List<RoutePoint> pts, List<HrSample> hr, int maxHr) {
  return [
    for (var i = 0; i < pts.length; i++)
      RouteVertex(
        pts[i].latLng,
        () {
          final bpm = nearestHr(hr, pts[i].tsMs);
          return bpm == null ? null : zoneForHr(bpm, maxHr);
        }(),
        gapBefore: i > 0 &&
            isImplausibleSegment(
              haversineMeters(pts[i - 1].lat, pts[i - 1].lng, pts[i].lat,
                  pts[i].lng),
              pts[i].tsMs - pts[i - 1].tsMs,
            ),
      ),
  ];
}

/// Partition the path into fixed-length splits ([unitMeters] each; the final
/// split is whatever distance remains). Each split reports its covered
/// distance, elapsed time, and the average of the HR samples that fall inside
/// its time window. `hr` must be sorted ascending by tsMs.
List<Split> computeSplits(
  List<RoutePoint> pts,
  List<HrSample> hr, {
  required double unitMeters,
}) {
  if (pts.length < 2 || unitMeters <= 0) return const [];

  final splits = <Split>[];
  var splitStartTsMs = pts.first.tsMs;
  var accum = 0.0; // metres accumulated in the current split
  var splitIndex = 1;

  void emit(int endTsMs, double meters) {
    final avg = _avgHrInWindow(hr, splitStartTsMs, endTsMs);
    splits.add(Split(
      index: splitIndex,
      meters: meters,
      durationSec: ((endTsMs - splitStartTsMs) / 1000).round(),
      avgHr: avg,
    ));
    splitIndex++;
  }

  for (var i = 1; i < pts.length; i++) {
    final prev = pts[i - 1];
    final cur = pts[i];
    var segLen =
        haversineMeters(prev.lat, prev.lng, cur.lat, cur.lng);
    final segStartTs = prev.tsMs;
    final segEndTs = cur.tsMs;

    // A single segment may cross one or more split boundaries. Walk the
    // boundaries, interpolating the crossing time linearly along the segment.
    var segConsumed = 0.0;
    while (accum + (segLen - segConsumed) >= unitMeters) {
      final need = unitMeters - accum; // metres to complete this split
      segConsumed += need;
      final frac = segLen <= 0 ? 1.0 : segConsumed / segLen;
      final crossTs =
          (segStartTs + (segEndTs - segStartTs) * frac).round();
      emit(crossTs, unitMeters);
      splitStartTsMs = crossTs;
      accum = 0.0;
    }
    accum += segLen - segConsumed;
  }

  // Trailing partial split.
  if (accum > 0.5) {
    emit(pts.last.tsMs, accum);
  }
  return splits;
}

double? _avgHrInWindow(List<HrSample> hr, int fromMs, int toMs) {
  if (hr.isEmpty || toMs <= fromMs) return null;
  var sum = 0;
  var n = 0;
  for (final s in hr) {
    if (s.tsMs < fromMs) continue;
    if (s.tsMs > toMs) break;
    if (s.hr <= 0) continue;
    sum += s.hr;
    n++;
  }
  return n == 0 ? null : sum / n;
}
