// Tests for the pure GPS route analytics: distance, per-unit splits, and the
// HR → zone colouring join. No DB / no geolocator — pure functions only.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gps/route_math.dart';
import 'package:openstrap_edge/gps/route_models.dart';

// ~metres per degree of longitude at the equator (haversine, lat 0).
const double _mPerDegLngAtEq = 111319.49;

/// A straight eastbound route at the equator: `count` points spaced
/// [stepMeters] apart, [stepSec] seconds between fixes, HR constant [hr].
List<RoutePoint> _line({
  int count = 26,
  double stepMeters = 100,
  int stepSec = 30,
  int startMs = 0,
}) {
  final dLng = stepMeters / _mPerDegLngAtEq;
  return [
    for (var i = 0; i < count; i++)
      RoutePoint(
        seq: i,
        tsMs: startMs + i * stepSec * 1000,
        lat: 0,
        lng: i * dLng,
      ),
  ];
}

void main() {
  group('haversineMeters', () {
    test('east step at equator matches the longitude scale', () {
      final d = haversineMeters(0, 0, 0, 100 / _mPerDegLngAtEq);
      expect(d, closeTo(100, 0.5));
    });

    test('zero distance for identical points', () {
      expect(haversineMeters(51.5, -0.12, 51.5, -0.12), closeTo(0, 1e-6));
    });
  });

  group('totalDistanceMeters', () {
    test('sums the segments', () {
      final pts = _line(count: 11, stepMeters: 100); // 10 segments
      expect(totalDistanceMeters(pts), closeTo(1000, 5));
    });

    test('empty / single point → 0', () {
      expect(totalDistanceMeters(const []), 0);
      expect(totalDistanceMeters([_line(count: 1).first]), 0);
    });

    test('a teleport across a recording gap adds no distance', () {
      // 100 m, then a 5 km jump in 1 s (implausible), then 100 m.
      final pts = [
        const RoutePoint(seq: 0, tsMs: 0, lat: 0, lng: 0),
        RoutePoint(seq: 1, tsMs: 1000, lat: 0, lng: 100 / _mPerDegLngAtEq),
        RoutePoint(
            seq: 2, tsMs: 2000, lat: 0, lng: (5000 + 100) / _mPerDegLngAtEq),
        RoutePoint(
            seq: 3, tsMs: 3000, lat: 0, lng: (5000 + 200) / _mPerDegLngAtEq),
      ];
      expect(totalDistanceMeters(pts), closeTo(200, 5));
    });

    test('far travel over a long gap IS plausible and counted', () {
      // 1 km apart but 5 minutes between fixes (3.3 m/s — a slow run).
      final pts = [
        const RoutePoint(seq: 0, tsMs: 0, lat: 0, lng: 0),
        RoutePoint(seq: 1, tsMs: 300000, lat: 0, lng: 1000 / _mPerDegLngAtEq),
      ];
      expect(totalDistanceMeters(pts), closeTo(1000, 5));
    });
  });

  group('movingSeconds', () {
    test('sums inter-fix intervals, excluding >60s pauses', () {
      final pts = [
        const RoutePoint(seq: 0, tsMs: 0, lat: 0, lng: 0),
        RoutePoint(seq: 1, tsMs: 10000, lat: 0, lng: 20 / _mPerDegLngAtEq),
        // 10-minute pause at a junction — must not dilute the pace.
        RoutePoint(seq: 2, tsMs: 610000, lat: 0, lng: 40 / _mPerDegLngAtEq),
        RoutePoint(seq: 3, tsMs: 620000, lat: 0, lng: 60 / _mPerDegLngAtEq),
      ];
      expect(movingSeconds(pts), 20); // 10 + (gap skipped) + 10
    });

    test('fewer than 2 points → 0', () {
      expect(movingSeconds(const []), 0);
      expect(movingSeconds([_line(count: 1).first]), 0);
    });
  });

  group('isImplausibleSegment', () {
    test('short-interval spike rejected, long-gap travel allowed', () {
      expect(isImplausibleSegment(5000, 1000), isTrue); // 5 km in 1 s
      expect(isImplausibleSegment(150, 1000), isFalse); // under the 200 m floor
      expect(isImplausibleSegment(5000, 300000), isFalse); // 5 km in 5 min
    });
  });

  group('buildVertices gap flags', () {
    test('marks the vertex after an implausible segment', () {
      final pts = [
        const RoutePoint(seq: 0, tsMs: 0, lat: 0, lng: 0),
        RoutePoint(seq: 1, tsMs: 1000, lat: 0, lng: 20 / _mPerDegLngAtEq),
        RoutePoint(
            seq: 2, tsMs: 2000, lat: 0, lng: (5000 + 20) / _mPerDegLngAtEq),
      ];
      final v = buildVertices(pts, const [], 190);
      expect(v[0].gapBefore, isFalse);
      expect(v[1].gapBefore, isFalse);
      expect(v[2].gapBefore, isTrue);
    });
  });

  group('zoneForHr', () {
    test('maps the 50/60/70/80/90% bands', () {
      const maxHr = 200;
      expect(zoneForHr(80, maxHr), 0); // 40%
      expect(zoneForHr(100, maxHr), 1); // 50%
      expect(zoneForHr(120, maxHr), 2); // 60%
      expect(zoneForHr(140, maxHr), 3); // 70%
      expect(zoneForHr(160, maxHr), 4); // 80%
      expect(zoneForHr(180, maxHr), 5); // 90%
    });

    test('degenerate inputs → zone 0', () {
      expect(zoneForHr(0, 200), 0);
      expect(zoneForHr(150, 0), 0);
    });
  });

  group('nearestHr', () {
    final hr = [
      const HrSample(tsMs: 0, hr: 100),
      const HrSample(tsMs: 10000, hr: 150),
      const HrSample(tsMs: 20000, hr: 120),
    ];

    test('picks the closest sample in time', () {
      expect(nearestHr(hr, 9000), 150);
      expect(nearestHr(hr, 1000), 100);
      expect(nearestHr(hr, 21000), 120);
    });

    test('returns null when the nearest sample is beyond the gap', () {
      expect(nearestHr(hr, 60000, maxGapMs: 15000), isNull);
      expect(nearestHr(const [], 0), isNull);
    });
  });

  group('buildVertices (HR-zone colouring join)', () {
    test('colours each vertex by the HR zone nearest in time', () {
      final pts = _line(count: 3, stepMeters: 100, stepSec: 10); // ts 0,10s,20s
      final hr = [
        const HrSample(tsMs: 0, hr: 100), // 50% → z1
        const HrSample(tsMs: 10000, hr: 160), // 80% → z4
        const HrSample(tsMs: 20000, hr: 180), // 90% → z5
      ];
      final v = buildVertices(pts, hr, 200);
      expect(v.length, 3);
      expect(v[0].zone, 1);
      expect(v[1].zone, 4);
      expect(v[2].zone, 5);
      expect(v[0].pos.latitude, 0);
    });

    test('vertex with no nearby HR sample gets a null zone', () {
      // Point 1 is 60 s after the only HR sample — beyond the 15 s join gap.
      final pts = _line(count: 2, stepMeters: 100, stepSec: 60);
      final hr = [const HrSample(tsMs: 0, hr: 120)];
      final v = buildVertices(pts, hr, 200);
      expect(v[0].zone, 2); // 120/200 = 60%
      expect(v[1].zone, isNull); // 60 s away → no colour
    });
  });

  group('computeSplits', () {
    test('partitions a constant-pace route into per-km splits', () {
      // 26 pts × 100 m = 2500 m, 30 s each ⇒ 300 s/km (5:00/km), HR 150.
      final pts = _line(count: 26, stepMeters: 100, stepSec: 30);
      final hr = [
        for (var i = 0; i < 26; i++)
          HrSample(tsMs: i * 30000, hr: 150),
      ];
      final splits = computeSplits(pts, hr, unitMeters: 1000);
      expect(splits.length, 3); // 1 km, 1 km, 0.5 km
      expect(splits[0].meters, closeTo(1000, 15));
      expect(splits[1].meters, closeTo(1000, 15));
      expect(splits[2].meters, closeTo(500, 15));
      // Full splits ≈ 300 s each.
      expect(splits[0].durationSec, closeTo(300, 5));
      expect(splits[0].avgHr, closeTo(150, 0.01));
      // Pace of a full split ≈ 300 s/km.
      expect(splits[0].paceSecPerUnit(1000), closeTo(300, 5));
    });

    test('per-mile splits are longer than per-km splits', () {
      final pts = _line(count: 26, stepMeters: 100, stepSec: 30);
      final km = computeSplits(pts, const [], unitMeters: 1000);
      final mi = computeSplits(pts, const [], unitMeters: 1609.344);
      expect(mi.length, lessThan(km.length));
      expect(mi.first.meters, closeTo(1609.344, 20));
    });

    test('avgHr is null when no HR samples fall in a split', () {
      final pts = _line(count: 11, stepMeters: 100, stepSec: 30);
      final splits = computeSplits(pts, const [], unitMeters: 1000);
      expect(splits.single.avgHr, isNull);
    });

    test('too few points → no splits', () {
      expect(computeSplits(const [], const [], unitMeters: 1000), isEmpty);
      expect(
        computeSplits([_line(count: 1).first], const [], unitMeters: 1000),
        isEmpty,
      );
    });
  });

  group('emaSpeed', () {
    test('first sample with no prior average is passed through unsmoothed',
        () {
      expect(emaSpeed(null, 3.2), 3.2);
    });

    test('smooths toward the new sample without jumping straight to it', () {
      final smoothed = emaSpeed(3.0, 5.0, alpha: 0.25);
      expect(smoothed, closeTo(3.5, 1e-9)); // 3.0 + 0.25*(5.0-3.0)
      expect(smoothed, greaterThan(3.0));
      expect(smoothed, lessThan(5.0));
    });

    test('a single noisy spike moves the average only a little', () {
      var v = 3.0;
      v = emaSpeed(v, 3.05); // realistic run-pace jitter
      v = emaSpeed(v, 30.0); // one wild GPS spike
      // alpha=0.25 default: 3.0125 + 0.25*(30-3.0125) ≈ 9.76 — damped, not 30.
      expect(v, lessThan(10));
      expect(v, greaterThan(3));
    });
  });

  group('fallbackSpeedMps', () {
    test('null when there is no previous point', () {
      expect(fallbackSpeedMps(null, _line(count: 1).first), isNull);
    });

    test('derives speed from distance / time between two fixes', () {
      // 100 m in 30 s ≈ 3.33 m/s (matches the _line() helper's default pace).
      final pts = _line(count: 2, stepMeters: 100, stepSec: 30);
      final v = fallbackSpeedMps(pts[0], pts[1]);
      expect(v, isNotNull);
      expect(v!, closeTo(100 / 30, 0.05));
    });

    test('null (not a divide-by-zero) for a non-positive time delta', () {
      final a = _line(count: 1).first;
      final b = RoutePoint(seq: 1, tsMs: a.tsMs, lat: a.lat, lng: a.lng);
      expect(fallbackSpeedMps(a, b), isNull);
    });
  });
}
