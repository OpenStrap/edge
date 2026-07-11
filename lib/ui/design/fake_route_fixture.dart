// Fake GPS-route fixture — for the Design Gallery's "Workout preview"
// section ONLY. Generates a believable (not real) run route so the map +
// live-session + finish-screen layouts can be visually reviewed without a
// live device/GPS/BLE connection.
//
// Deterministic (fixed Random seed) so gallery screenshots are reproducible.
// Distance/moving-time/splits are all DERIVED from the generated points via
// the same pure functions the real app uses (route_math.dart) — never
// hand-typed — so the fixture can never drift out of sync with itself.

import 'dart:math' as math;

import '../../gps/route_math.dart' as rmath;
import '../../gps/route_models.dart';

const double _kMPerDegLat = 111320.0;

/// A believable ~3.2 km loop run, ~20 minutes, starting near a real-feeling
/// coordinate (not the user's actual location — just realistic-looking
/// decimals, not degenerate zeros). Organic loop shape (base ellipse + a
/// couple of harmonics, slightly egg-shaped) so it doesn't read as an obvious
/// synthetic circle/rectangle, plus small per-point GPS jitter.
List<RoutePoint> fakeRunRoutePoints({
  int nPoints = 140,
  double centerLat = 37.7699,
  double centerLng = -122.4661,
  double baseRadiusM = 500,
  Duration duration = const Duration(minutes: 20),
}) {
  final rand = math.Random(42);
  final points = <RoutePoint>[];
  final intervalMs = duration.inMilliseconds ~/ (nPoints - 1);
  final latRad = centerLat * math.pi / 180;
  for (var i = 0; i < nPoints; i++) {
    final t = i / (nPoints - 1);
    final theta = t * 2 * math.pi;
    final radius = baseRadiusM *
        (1.0 +
            0.28 * math.sin(theta * 2 + 0.6) +
            0.14 * math.sin(theta * 5 - 1.1) +
            0.06 * math.sin(theta * 9 + 2.0));
    const squash = 0.82; // slightly egg-shaped, not a perfect circle
    final dLatM = radius * math.cos(theta);
    final dLngM = radius * squash * math.sin(theta);
    // ~1-2 m of ordinary consumer-GPS jitter per fix.
    final jitterLatM = (rand.nextDouble() - 0.5) * 3.0;
    final jitterLngM = (rand.nextDouble() - 0.5) * 3.0;
    points.add(RoutePoint(
      seq: i,
      tsMs: i * intervalMs,
      lat: centerLat + (dLatM + jitterLatM) / _kMPerDegLat,
      lng: centerLng +
          (dLngM + jitterLngM) / (_kMPerDegLat * math.cos(latRad)),
      accuracy: 6 + rand.nextDouble() * 5,
    ));
  }
  return points;
}

/// HR samples over the same window: a believable warm-up → hard-middle →
/// cool-down bell profile (not flat, not random noise), plus small jitter.
List<HrSample> fakeRunHrSamples(List<RoutePoint> points) {
  if (points.isEmpty) return const [];
  final rand = math.Random(7);
  final n = points.length;
  return [
    for (final p in points)
      HrSample(
        tsMs: p.tsMs,
        hr: () {
          final t = n <= 1 ? 0.0 : p.seq / (n - 1);
          final profile = 118 + 45 * math.sin(t * math.pi).clamp(0.0, 1.0);
          return (profile + (rand.nextDouble() - 0.5) * 6).round();
        }(),
      ),
  ];
}

/// The full [WorkoutRoute] — distance/moving-time/splits all derived from
/// the generated points, never hand-typed.
WorkoutRoute fakeRunRoute() {
  final points = fakeRunRoutePoints();
  final hr = fakeRunHrSamples(points);
  return WorkoutRoute(
    sessionId: 'preview-run',
    points: points,
    hr: hr,
    distanceMeters: rmath.totalDistanceMeters(points),
    movingSec: rmath.movingSeconds(points),
    splitsKm: rmath.computeSplits(points, hr, unitMeters: rmath.kMetersPerKm),
    splitsMi:
        rmath.computeSplits(points, hr, unitMeters: rmath.kMetersPerMile),
  );
}
