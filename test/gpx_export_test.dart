// Tests for GPX generation — pure string building, no DB / no plugin.
//
// Asserted as plain text rather than parsed XML: `xml` is only a transitive
// dependency here (nothing in the app parses GPX/XML directly), and the
// output is simple enough that substring checks pin its shape without
// pulling in a package this repo doesn't otherwise depend on.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gps/gpx_export.dart';
import 'package:openstrap_edge/gps/route_models.dart';

WorkoutRoute _route({List<HrSample> hr = const []}) => WorkoutRoute(
      sessionId: 's1',
      points: const [
        RoutePoint(seq: 0, tsMs: 1000000, lat: 51.5, lng: -0.12, alt: 10),
        RoutePoint(seq: 1, tsMs: 1005000, lat: 51.501, lng: -0.121),
        RoutePoint(seq: 2, tsMs: 1010000, lat: 51.502, lng: -0.122, alt: 12),
      ],
      hr: hr,
      distanceMeters: 200,
      movingSec: 10,
      splitsKm: const [],
      splitsMi: const [],
    );

/// Number of `<trkpt` occurrences — one per recorded fix.
int _trkptCount(String xml) => RegExp('<trkpt ').allMatches(xml).length;

void main() {
  group('buildGpx', () {
    test('emits one trkpt per route point, in order, with lat/lon/time', () {
      final xml = buildGpx(_route(), name: 'Run');
      expect(_trkptCount(xml), 3);
      expect(xml, contains('lat="51.5" lon="-0.12"'));
      expect(xml, contains('lat="51.501" lon="-0.121"'));
      // Elevation only when the point actually carries one.
      expect(xml, contains('<ele>10.0</ele>'));
      expect(xml, contains('<ele>12.0</ele>'));
      // Times match the source timestamps and stay in point order.
      final t0 = DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true)
          .toIso8601String();
      final t2 = DateTime.fromMillisecondsSinceEpoch(1010000, isUtc: true)
          .toIso8601String();
      expect(xml.indexOf(t0), lessThan(xml.indexOf(t2)));
    });

    test('track name is escaped and set from the activity name', () {
      final xml = buildGpx(_route(), name: 'Run & Gun');
      expect(xml, contains('<name>Run &amp; Gun</name>'));
    });

    test('attaches the nearest HR sample within tolerance as a TPX extension',
        () {
      final route = _route(hr: const [
        HrSample(tsMs: 999500, hr: 140), // 500ms from point 0 → attaches
        HrSample(tsMs: 1005200, hr: 150), // 200ms from point 1 → attaches
        // No sample anywhere near point 2 (tsMs 1010000) — stays HR-less.
      ]);
      final xml = buildGpx(route, name: 'Run');
      expect(xml, contains('<gpxtpx:hr>140</gpxtpx:hr>'));
      expect(xml, contains('<gpxtpx:hr>150</gpxtpx:hr>'));
      expect(RegExp('<gpxtpx:hr>').allMatches(xml).length, 2);
    });

    test('no HR extension anywhere when the route has no HR samples', () {
      final xml = buildGpx(_route(), name: 'Run');
      expect(xml.contains('gpxtpx:hr'), isFalse);
      expect(xml.contains('<extensions>'), isFalse);
    });

    test('a HR sample far outside tolerance is not attached to a distant point',
        () {
      final route = _route(hr: const [HrSample(tsMs: 1000000, hr: 140)]);
      final xml = buildGpx(route, name: 'Run');
      // Point 0 (tsMs 1000000) gets it; point 2 (tsMs 1010000, 10s away,
      // tolerance is 3s) must not.
      expect(RegExp('<gpxtpx:hr>').allMatches(xml).length, 1);
    });

    test('balanced tags for the minimum 2-point route', () {
      final route = WorkoutRoute(
        sessionId: 's2',
        points: const [
          RoutePoint(seq: 0, tsMs: 0, lat: 0, lng: 0),
          RoutePoint(seq: 1, tsMs: 1000, lat: 0.001, lng: 0.001),
        ],
        hr: const [],
        distanceMeters: 100,
        movingSec: 1,
        splitsKm: const [],
        splitsMi: const [],
      );
      final xml = buildGpx(route, name: 'Walk');
      expect(_trkptCount(xml), 2);
      expect(RegExp('<trkpt ').allMatches(xml).length,
          RegExp('</trkpt>').allMatches(xml).length);
      expect(xml, contains('<gpx version="1.1"'));
      expect(xml, contains('</gpx>'));
    });
  });
}
