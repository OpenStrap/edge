import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gps/ghost_math.dart';
import 'package:openstrap_edge/gps/route_models.dart';

const _mPerDeg = 111319.49; // WGS84 equatorial, at lat 0

/// A straight eastbound route at [mps], a fix every [dt] s, [n] fixes.
List<RoutePoint> line({
  double mps = 3,
  int dt = 5,
  int n = 201,
  double lat = 0,
  double offM = 0,
}) {
  return [
    for (var i = 0; i < n; i++)
      RoutePoint(
        seq: i,
        tsMs: 1000000 + i * dt * 1000,
        lat: lat + offM / _mPerDeg,
        lng: mps * dt * i / _mPerDeg,
      ),
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
            lng: lngAt(1500 - 15.0 * i),
          ),
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
      expect(
        ghostUnusableReason(line(mps: 8, dt: 2, n: 40)),
        GhostRefusal.tooBrief,
      );
    });
    test('clock going backwards', () {
      final l = line();
      final bad = [...l]
        ..[50] = RoutePoint(
          seq: 50,
          tsMs: l[49].tsMs,
          lat: l[50].lat,
          lng: l[50].lng,
        );
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
            lng: p.lng,
          ),
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
      final r = GhostRace(
        ghost,
      ).update(30000, lat: 0.05, lng: lngAt(300)); // ~5.5 km north
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

  group('review fixes', () {
    test('finish time is first arrival even with a stationary tail', () {
      final pts = line(n: 61); // 900 m in 300 s
      for (var i = 0; i < 5; i++) {
        pts.add(RoutePoint(
          seq: 61 + i,
          tsMs: pts.last.tsMs + 5000,
          lat: pts.last.lat,
          lng: pts.last.lng,
        ));
      }
      final tr = GhostTrack.tryBuild(pts);
      // 900 m route is long enough? needs >= 120 s and 400 m: yes.
      expect(tr!.timeAtDistM(tr.totalM), 300000);
    });
    test('finish gap is kept while standing at the line', () {
      final race = GhostRace(ghost);
      // reach the end at 900 s (ghost needs 1000 s): 100 s ahead
      race.update(0, lat: 0, lng: 0);
      for (var t = 5; t <= 880; t += 5) {
        race.update(t * 1000, lat: 0, lng: lngAt(t * 3.4));
      }
      final a = race.update(900000, lat: 0, lng: lngAt(3000));
      expect(a.state, GhostState.finished);
      final b = race.update(1100000, lat: 0, lng: lngAt(3000));
      expect(b.gapSec, a.gapSec);
      expect(b.gapSec!, greaterThan(90));
    });
    test('passing the endpoint 40 m sideways is not a finish', () {
      final race = GhostRace(ghost);
      race.update(0, lat: 0, lng: 0);
      for (var t = 5; t <= 880; t += 5) {
        race.update(t * 1000, lat: 0, lng: lngAt(t * 3.4));
      }
      final r = race.update(900000, lat: 40 / _mPerDeg, lng: lngAt(3000));
      expect(r.state, isNot(GhostState.finished));
    });
    test('a jump the elapsed time cannot cover is not accepted', () {
      final race = GhostRace(ghost);
      race.update(0, lat: 0, lng: 0);
      race.update(10000, lat: 0, lng: lngAt(30));
      // 2000 m further along in 5 s
      final r = race.update(15000, lat: 0, lng: lngAt(2030));
      expect(r.state, GhostState.offRoute);
    });
    test('window search does not match beyond the window', () {
      final p = ghost.project(0, lngAt(690), nearM: 300, backM: 0, aheadM: 300);
      // window ends at 600 m; 690 m is 90 m off -> falls back to whole track
      expect(p.alongM, closeTo(690, 1));
      final w = ghost.project(0, lngAt(590), nearM: 300, backM: 0, aheadM: 300);
      expect(w.alongM, closeTo(590, 1));
    });
  });

  group('buzz policy', () {
    GhostReading at(double gap) => GhostReading(
      gap > 0 ? GhostState.ahead : GhostState.behind,
      gapM: gap,
      ghostLat: 0,
      ghostLng: 0,
      ghostAlongM: 0,
    );
    test('first side is remembered, not buzzed', () {
      final b = GhostBuzzPolicy();
      expect(b.shouldBuzz(at(30), 0), isFalse);
    });
    test(
      'buzzes once when the lead flips, then not again on the same side',
      () {
        final b = GhostBuzzPolicy();
        b.shouldBuzz(at(30), 0);
        expect(b.shouldBuzz(at(-30), 100000), isTrue);
        expect(b.shouldBuzz(at(-40), 101000), isFalse);
      },
    );
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
      const r = GhostReading(
        GhostState.offRoute,
        ghostLat: 0,
        ghostLng: 0,
        ghostAlongM: 0,
      );
      expect(b.shouldBuzz(r, 0), isFalse);
    });
  });

  group('similarity', () {
    test('a route with itself is 1', () {
      expect(routeSimilarity(line(), line()), 1.0);
    });
    test('a slightly wobbly repeat of the same route is the same route', () {
      expect(
        routeSimilarity(line(), line(mps: 3.3, offM: 15))!,
        greaterThan(kSameRouteShare),
      );
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
    test('splitM <= 0 refuses instead of looping', () {
      expect(compareRuns(line(), line(), splitM: 0), isNull);
      expect(compareRuns(line(), line(), splitM: double.nan), isNull);
    });
    test('a run joining 100 m in is timed from there, not from its start', () {
      // ghost: 3 m/s from 0. runner: same speed but starts at 100 m.
      final you = [
        for (var i = 0; i < 181; i++)
          RoutePoint(
            seq: i,
            tsMs: 1000000 + i * 5000,
            lat: 0,
            lng: lngAt(100 + 15.0 * i),
          ),
      ];
      final c = compareRuns(you, line())!;
      expect(c.finalGapSec.abs(), lessThan(2));
      expect(c.sharedM, closeTo(2700, 40));
    });
    test('skipping a loop is not credited as time gained', () {
      // Ghost goes east 1000 m, loops north 150 m and back (300 m), east on.
      // Runner cuts straight across.
      RoutePoint p(int i, double e, double n) => RoutePoint(
        seq: i,
        tsMs: 0,
        lat: n / _mPerDeg,
        lng: e / _mPerDeg,
      );
      final gp = <RoutePoint>[];
      var t = 0, k = 0;
      void add(double e, double n) {
        gp.add(RoutePoint(seq: k++, tsMs: 1000000 + t, lat: n / _mPerDeg, lng: e / _mPerDeg));
        t += 5000;
      }
      for (var e = 0.0; e <= 1000; e += 15) { add(e, 0); }
      for (var n = 15.0; n <= 150; n += 15) { add(1000, n); }
      for (var n = 135.0; n >= 0; n -= 15) { add(1000, n); }
      for (var e = 1015.0; e <= 2000; e += 15) { add(e, 0); }
      final you = <RoutePoint>[];
      var j = 0;
      for (var e = 0.0; e <= 2000; e += 15) {
        you.add(RoutePoint(seq: j, tsMs: 1000000 + 5000 * j, lat: 0, lng: e / _mPerDeg));
        j++;
      }
      expect(p(0, 0, 0).seq, 0);
      expect(routeSimilarity(you, gp)!, greaterThan(kSameRouteShare));
      expect(compareRuns(you, gp), isNull);
    });
    test('a different route refuses instead of inventing a gap', () {
      expect(compareRuns(line(offM: 300), line()), isNull);
    });
  });
}
