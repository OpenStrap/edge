// Sanity check for the Design Gallery's fake-route fixture: it must produce
// a well-formed, plausible route (not degenerate/zero), since a broken
// fixture would make the gallery preview lie about what the real layout
// looks like.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui/design/fake_route_fixture.dart';

void main() {
  test('fakeRunRoute produces a well-formed, plausible route', () {
    final route = fakeRunRoute();

    expect(route.hasPath, isTrue);
    expect(route.points.length, greaterThan(50));
    expect(route.hr.length, route.points.length);

    // ~3.2 km loop — generous bounds, just guarding against a degenerate
    // (near-zero) or absurd (thousands of km) generator regression.
    expect(route.distanceMeters, greaterThan(2000));
    expect(route.distanceMeters, lessThan(5000));

    // ~20 minutes of continuous movement, no huge implausible gaps eating
    // most of the moving time.
    expect(route.movingSec, greaterThan(15 * 60));
    expect(route.movingSec, lessThanOrEqualTo(20 * 60));

    // HR stays in a plausible human range throughout.
    for (final h in route.hr) {
      expect(h.hr, greaterThan(80));
      expect(h.hr, lessThan(190));
    }

    expect(route.splitsKm, isNotEmpty);
    expect(route.splitsMi, isNotEmpty);
  });

  test('deterministic: two calls produce identical routes (fixed seed)', () {
    final a = fakeRunRoute();
    final b = fakeRunRoute();
    expect(a.distanceMeters, b.distanceMeters);
    expect(a.points.length, b.points.length);
    expect(a.points.first.lat, b.points.first.lat);
    expect(a.points.last.lng, b.points.last.lng);
  });
}
