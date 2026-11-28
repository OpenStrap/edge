import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gps/ghost_math.dart';
import 'package:openstrap_edge/gps/route_models.dart';

const _mPerDeg = 111319.49; // WGS84 equatorial, at lat 0

/// A straight eastbound route at [mps], a fix every [dt] s, [n] fixes.
List<RoutePoint> line(
    {double mps = 3, int dt = 5, int n = 201, double lat = 0, double offM = 0}) {
  return [
    for (var i = 0; i < n; i++)
      RoutePoint(
          seq: i,
          tsMs: 1000000 + i * dt * 1000,
          lat: lat + offM / _mPerDeg,
          lng: mps * dt * i / _mPerDeg),
  ];
}

double lngAt(double m) => m / _mPerDeg;

void main() {
  final ghost = GhostTrack.tryBuild(line())!; // 3000 m in 1000 s

  group('track', () {
    test('length and duration', () {
      expect(ghost.totalM, closeTo(3000, 1));
      expect(ghost.durationMs, 1000000);
    });
    test('position by time interpolates between fixes', () {
      final g = ghost.at(12500); // 2.5 fixes in
      expect(g.distM, closeTo(37.5, 0.1));
      expect(g.lng, closeTo(lngAt(37.5), 1e-9));
    });
    test('clamps before the start and after the finish', () {
      expect(ghost.at(-5).distM, 0);
      expect(ghost.at(99999999).distM, closeTo(3000, 1));
    });
    test('time at distance is the inverse of position by time', () {
      expect(ghost.timeAtDistM(1500), closeTo(500000, 50));
      expect(ghost.timeAtDistM(-1), 0);
      expect(ghost.timeAtDistM(9999), 1000000);
    });
    test('projection lands on the path with the right offset', () {
      final p = ghost.project(lngAt(900) * 0 + 20 / _mPerDeg, lngAt(900));
      expect(p.alongM, closeTo(900, 1));
      expect(p.offsetM, closeTo(20, 0.5));
    });
    test('windowed projection does not jump to a revisited spot', () {
      // out and back: east 1500 m then west back to the start
      final out = line(n: 101);
      final back = [
        for (var i = 1; i <= 100; i++)
          RoutePoint(
              seq: 100 + i,
              tsMs: out.last.tsMs + i * 5000,
              lat: 0,
              lng: lngAt(1500 - 15.0 * i)),
      ];
      final t = GhostTrack.tryBuild([...out, ...back])!;
      final near = t.project(0, lngAt(750), nearM: 2250); // on the way back
      expect(near.alongM, closeTo(2250, 2));
      final blind = t.project(0, lngAt(750)); // no hint: either pass is fine
      expect(blind.offsetM, lessThan(1));
    });
  });

  group('usability', () {
    test('too few points', () {
      expect(ghostUnusableReason(line(n: 10)), GhostRefusal.tooFewPoints);
    });
    test('too short in distance', () {
      expect(ghostUnusableReason(line(mps: 0.5, n: 30)), GhostRefusal.tooShort);
    });
    test('too brief in time', () {
      expect(ghostUnusableReason(line(mps: 8, dt: 2, n: 40)),
          GhostRefusal.tooBrief);
    });
    test('clock going backwards', () {
      final l = line();
      final bad = [...l]..[50] = RoutePoint(
          seq: 50, tsMs: l[49].tsMs, lat: l[50].lat, lng: l[50].lng);
      expect(ghostUnusableReason(bad), GhostRefusal.brokenClock);
    });
    test('a quarter of the run unrecorded', () {
      final l = line();
      final gappy = [
        for (final p in l)
          RoutePoint(
              seq: p.seq,
              tsMs: p.tsMs + (p.seq >= 100 ? 400000 : 0),
              lat: p.lat,
              lng: p.lng),
      ];
      expect(ghostUnusableReason(gappy), GhostRefusal.gappy);
    });
    test('a good route passes', () {
      expect(ghostUnusableReason(line()), isNull);
    });
  });

  // A race that began at the start line, as a real one does.
  GhostRace started() => GhostRace(ghost)..update(0, lat: 0, lng: 0);

  group('live gap', () {
    test('no fix is waiting, with no gap', () {
      final r = GhostRace(ghost).update(10000);
      expect(r.state, GhostState.waiting);
      expect(r.gapM, isNull);
      expect(r.gapSec, isNull);
    });
    test('running exactly the ghost pace reads level', () {
      final race = started();
      final r = race.update(100000, lat: 0, lng: lngAt(300));
      expect(r.state, GhostState.level);
      expect(r.gapM!.abs(), lessThan(1));
    });
    test('ahead: 60 m further at the same clock, 20 s up', () {
      final r = started().update(100000, lat: 0, lng: lngAt(360));
      expect(r.state, GhostState.ahead);
      expect(r.gapM, closeTo(60, 0.5));
      expect(r.gapSec, closeTo(20, 0.2));
    });
    test('behind: 30 m short is 10 s down', () {
      final r = started().update(100000, lat: 0, lng: lngAt(270));
      expect(r.state, GhostState.behind);
      expect(r.gapM, closeTo(-30, 0.5));
      expect(r.gapSec, closeTo(-10, 0.2));
    });
    test('gaps under a few metres are level, not a lead', () {
      final r = started().update(100000, lat: 0, lng: lngAt(303.5));
      expect(r.state, GhostState.level);
    });
    test('a different place has no gap', () {
      final r = GhostRace(ghost)
          .update(30000, lat: 0.05, lng: lngAt(300)); // ~5.5 km north
      expect(r.state, GhostState.offRoute);
      expect(r.gapM, isNull);
    });
    test('leaving the path mid-run is off route', () {
      final race = started();
      race.update(60000, lat: 0, lng: lngAt(180));
      final r = race.update(70000, lat: 200 / _mPerDeg, lng: lngAt(210));
      expect(r.state, GhostState.offRoute);
    });
    test('reaching the finish', () {
      final race = started();
      race.update(900000, lat: 0, lng: lngAt(2700));
      final r = race.update(950000, lat: 0, lng: lngAt(3000));
      expect(r.state, GhostState.finished);
      expect(r.gapSec, closeTo(50, 0.2)); // ghost took 1000 s, you 950
    });
    test('the ghost marker moves by the old clock', () {
      final r = GhostRace(ghost).update(200000, lat: 0, lng: 0);
      expect(r.ghostAlongM, closeTo(600, 0.5));
    });
  });

  group('buzz policy', () {
    GhostReading at(double gap) => GhostReading(
        gap > 0 ? GhostState.ahead : GhostState.behind,
        gapM: gap,
        ghostLat: 0,
        ghostLng: 0,
        ghostAlongM: 0);
    test('first side is remembered, not buzzed', () {
      final b = GhostBuzzPolicy();
      expect(b.shouldBuzz(at(30), 0), isFalse);
    });
    test('buzzes once when the lead flips, then not again on the same side',
        () {
      final b = GhostBuzzPolicy();
      b.shouldBuzz(at(30), 0);
      expect(b.shouldBuzz(at(-30), 100000), isTrue);
      expect(b.shouldBuzz(at(-40), 101000), isFalse);
    });
    test('hovering on the threshold cannot spam', () {
      final b = GhostBuzzPolicy();
      b.shouldBuzz(at(30), 0);
      expect(b.shouldBuzz(at(-30), 100000), isTrue);
      expect(b.shouldBuzz(at(-10), 105000), isFalse); // dead band
      expect(b.shouldBuzz(at(30), 110000), isFalse); // inside cooldown
      expect(b.shouldBuzz(at(-30), 120000), isFalse);
    });
    test('off route never buzzes', () {
      final b = GhostBuzzPolicy();
      const r = GhostReading(GhostState.offRoute,
          ghostLat: 0, ghostLng: 0, ghostAlongM: 0);
      expect(b.shouldBuzz(r, 0), isFalse);
    });
  });

  group('similarity', () {
    test('a route with itself is 1', () {
      expect(routeSimilarity(line(), line()), 1.0);
    });
    test('a slightly wobbly repeat of the same route is the same route', () {
      expect(routeSimilarity(line(), line(mps: 3.3, offM: 15))!,
          greaterThan(kSameRouteShare));
    });
    test('a parallel street 200 m away is a different route', () {
      expect(routeSimilarity(line(), line(offM: 200))!, lessThan(0.1));
    });
    test('a short loop inside a long route does not pass', () {
      final short = line(n: 70); // first 1000 m only
      expect(routeSimilarity(line(), short)!, lessThan(kSameRouteShare));
    });
    test('unusable input is null, not a number', () {
      expect(routeSimilarity(line(n: 5), line()), isNull);
    });
  });

  group('comparison', () {
    test('same pace is level at the end and every split', () {
      final c = compareRuns(line(), line())!;
      expect(c.finalGapSec.abs(), lessThan(1));
      expect(c.splits.length, 3);
      for (final s in c.splits) {
        expect(s.deltaSec.abs(), lessThan(1));
      }
    });
    test('a faster repeat wins by the right number of seconds', () {
      // 3.3 m/s: 3000 m in 909 s vs 1000 s
      final fast = line(mps: 3.3, n: 182);
      final c = compareRuns(fast, line())!;
      expect(c.won, isTrue);
      expect(c.finalGapSec, closeTo(1000 - 3000 / 3.3, 3));
      expect(c.sharedM, closeTo(2970, 40));
    });
    test('where time was lost: a slow middle km', () {
      // 3 m/s for 1 km, 2 m/s for km 2, 3 m/s for km 3
      final pts = <RoutePoint>[];
      var t = 1000000;
      var d = 0.0;
      pts.add(RoutePoint(seq: 0, tsMs: t, lat: 0, lng: 0));
      for (var i = 1; d < 3000; i++) {
        final v = (d >= 1000 && d < 2000) ? 2.0 : 3.0;
        d += v * 5;
        t += 5000;
        pts.add(RoutePoint(seq: i, tsMs: t, lat: 0, lng: lngAt(d)));
      }
      final c = compareRuns(pts, line())!;
      expect(c.splits[1].deltaSec, lessThan(-100)); // ~167 s vs 333 s
      expect(c.biggestLoss!.index, 2);
      expect(c.won, isFalse);
    });
    test('a different route refuses instead of inventing a gap', () {
      expect(compareRuns(line(offM: 300), line()), isNull);
    });
  });
}
