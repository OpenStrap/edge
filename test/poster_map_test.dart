// The basemap's failure paths, which are the ones that matter.
//
// A share card is the one screen whose output leaves the phone, so the map
// either loads completely or is not drawn at all. Every input below is one
// this has to survive without throwing, because each of them ends with the
// user tapping Share regardless.
//
// `TestWidgetsFlutterBinding` answers every HTTP request with a 400 and there
// is no `path_provider` plugin under a test binding, so this file exercises
// the no-network, no-cache path for real rather than by mocking it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/poster.dart';
import 'package:openstrap_edge/ui2/activity/share.dart' show photoDecodeSize;
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/activity/tiles.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a photo decodes to cover the card, bounded in both dimensions', () {
    // Tall portrait: width is the constraint (900), not height 1600.
    expect(photoDecodeSize(1800, 4000), (900, 2000));
    // Landscape: height 1600.
    expect(photoDecodeSize(4000, 3000), (2133, 1600));
    // Panorama: capped at 4096 on the long side.
    expect(photoDecodeSize(20000, 2000), (4096, 410));
    // Already small: never upscaled.
    expect(photoDecodeSize(600, 800), (600, 800));
  });

  // The consent gate, which every other test in this file has to get past.
  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    await Prefs.ensureLoaded();
    setMapTilesAllowed(true);
  });

  group('the tile fetch is consented, not assumed', () {
    // The app's whole positioning is that nothing leaves the device, and a
    // tile request is addressed BY WHERE THE ROUTE IS — so opening the share
    // sheet used to tell openstreetmap.org roughly where the session was,
    // before the user had touched anything.
    test('no consent, no request — and the card still draws', () async {
      setMapTilesAllowed(false);
      expect(
          await buildRouteMosaic(const [(51.500, -0.120), (51.505, -0.118)],
              width: 128, height: 64, bg: C.n900, ink: C.white),
          isNull);
    });

    // The default is the `false` fallback in [mapTilesAllowed] — a key that
    // was never written reads off, which is what a fresh install is. It cannot
    // be asserted here because `Prefs` caches its store for the process.
    test('the switch is persisted, and off means off', () {
      setMapTilesAllowed(false);
      expect(mapTilesAllowed, isFalse);
      setMapTilesAllowed(true);
      expect(mapTilesAllowed, isTrue);
    });
  });

  group('the projection', () {
    // Pinned against independently-computed slippy-map coordinates. This is
    // the one calculation here that fails PLAUSIBLY — a wrong constant still
    // draws a neat route, just somewhere the user has never been.
    test('lands on the right tile at zoom 12', () {
      for (final (name, lat, lng, x, y) in const [
        ('London', 51.5074, -0.1278, 2046.5459, 1362.0245),
        ('Sydney', -33.8688, 151.2093, 3768.4258, 2457.9779),
        ('Null Island', 0.0, 0.0, 2048.0, 2048.0),
      ]) {
        final p = tileXY(lat, lng, 12);
        expect(p.x, closeTo(x, .001), reason: name);
        expect(p.y, closeTo(y, .001), reason: name);
      }
    });

    test('the poles are clamped, not infinite', () {
      // `tan(90°)` is where a slippy map turns into a NaN.
      for (final lat in const [90.0, -90.0, 89.999]) {
        final p = tileXY(lat, 0, 12);
        expect(p.y.isFinite, isTrue, reason: 'lat \$lat');
        expect(p.y, inInclusiveRange(0, 4096));
      }
    });

    test('zoom doubles the grid', () {
      final a = tileXY(51.5074, -0.1278, 12);
      final b = tileXY(51.5074, -0.1278, 13);
      expect(b.x, closeTo(a.x * 2, .001));
      expect(b.y, closeTo(a.y * 2, .001));
    });
  });

  // The zoom is the number on this card that fails PLAUSIBLY: a wrong one
  // still draws a tidy map, just of the wrong amount of world. It shipped
  // wrong — a tile-budget loop stepped the zoom down while the tile count was
  // over its cap, but the frame is a fixed number of PIXELS, so its width in
  // tiles never changes with zoom and the loop could not converge. A poster's
  // 900x1200 export frame is 25 tiles against a cap of 24, so EVERY card that
  // drew a basemap ran the loop to the floor and drew the whole world.
  group('the frame zooms to the route', () {
    // A ~3 km park loop, a ~40 km ride and a ~900 km flight-shaped glitch.
    // Each must get its OWN zoom, and none may land on the floor.
    RouteFrame frameFor(double latSpan, double lngSpan) => routeFrame(
          loLat: 12.970,
          hiLat: 12.970 + latSpan,
          loLng: 77.590,
          hiLng: 77.590 + lngSpan,
          width: 900,
          height: 1200,
        )!;

    test('a city loop gets a street-level zoom, not the world', () {
      final f = frameFor(.008, .012);
      expect(f.zoom, greaterThanOrEqualTo(13),
          reason: 'a 3 km loop framed at z${f.zoom} is a map of a country.');
      expect(f.zoom, lessThanOrEqualTo(17));
    });

    test('a longer route zooms out, and a shorter one in', () {
      final loop = frameFor(.008, .012);
      final ride = frameFor(.35, .40);
      final glitch = frameFor(8.0, 9.0);
      expect(ride.zoom, lessThan(loop.zoom));
      expect(glitch.zoom, lessThan(ride.zoom));
      // …and even the absurd one is a real frame rather than the floor.
      expect(glitch.zoom, greaterThan(2));
    });

    test('the export frame fits inside the tile budget', () {
      // The regression itself: 900x1200 asks for 25 tiles. If the ceiling is
      // ever set under what a real card needs, this fails instead of silently
      // zooming every poster out to the whole planet.
      for (final f in [frameFor(.008, .012), frameFor(.35, .40)]) {
        expect(f.tiles, lessThanOrEqualTo(64));
        expect(f.tiles, greaterThan(1));
      }
    });

    test('tile count is frame-bound, not zoom-bound', () {
      // The false assumption the old loop rested on, pinned so nobody writes
      // it again. A 3 km loop and a 900 km one are three zoom levels apart and
      // still ask for the same handful of tiles — the count follows the card's
      // pixel size, and only wobbles by a row when the centre lands mid-tile.
      // So there is no zoom you can step down to in order to fetch fewer.
      final tight = frameFor(.008, .012);
      final wide = frameFor(8.0, 9.0);
      expect(wide.zoom, lessThan(tight.zoom));
      expect((tight.tiles - wide.tiles).abs(), lessThanOrEqualTo(11),
          reason: 'tight=${tight.tiles} wide=${wide.tiles} — if these ever '
              'diverge, the count has started tracking the route.');
    });
  });

  group('buildRouteMosaic refuses rather than throws', () {
    Future<RouteMosaic?> run(List<(double, double)> geo) => buildRouteMosaic(
          geo,
          width: 128,
          height: 64,
          bg: C.n900,
          ink: C.white,
        );

    test('fewer than two points is not a route', () async {
      expect(await run(const []), isNull);
      expect(await run(const [(51.5, -0.12)]), isNull);
    });

    test('a NaN coordinate is refused, not projected', () async {
      // Mercator has no poles and `log(tan(NaN))` is NaN — which reaches a
      // Path and takes the card down with it. Caught at the door instead.
      expect(await run(const [(double.nan, -0.12), (51.5, -0.12)]), isNull);
      expect(await run(const [(51.5, double.nan), (51.6, -0.12)]), isNull);
    });

    test('a zero-area route is still a route', () async {
      // Someone who stood still with GPS running. Bounds collapse to a point,
      // which must pick a zoom rather than divide by a zero span.
      expect(() => run(const [(51.5, -0.12), (51.5, -0.12)]),
          returnsNormally);
    });

    test('an absurd bounding box does not become a scrape', () async {
      // A GPS glitch across a hemisphere. The zoom-out loop and the tile cap
      // are the same knob, so this must terminate and stay under the ceiling
      // rather than enumerate the world.
      expect(await run(const [(-33.9, 151.2), (51.5, -0.12)]), isNull,
          reason: 'no network under a test binding — but it must ASK for few '
              'enough tiles to get there without hanging');
    });

    test('no network means no map, not a broken one', () async {
      expect(await run(const [(51.500, -0.120), (51.505, -0.118)]), isNull);
    });

    test('a zero-sized box is refused', () async {
      expect(
          await buildRouteMosaic(const [(51.5, -0.12), (51.6, -0.11)],
              width: 0, height: 64, bg: C.n900, ink: C.white),
          isNull);
    });
  });

  group('a formatted stat splits into a number and a unit', () {
    test('…when the tail is actually a unit', () {
      expect(splitStatUnit('148 bpm'), ('148', 'bpm'));
      expect(splitStatUnit('5:01 /km'), ('5:01', '/km'));
      expect(splitStatUnit('2,310 kcal'), ('2,310', 'kcal'));
      expect(splitStatUnit('+412 m'), ('+412', 'm'));
    });

    test('…and never otherwise', () {
      // The one that made this a function rather than a `split(' ').last`:
      // the last word of a duration is not a unit of anything, and setting
      // '02m' in the unit slot prints the time as '1h'.
      expect(splitStatUnit('1h 02m'), ('1h 02m', null));
      expect(splitStatUnit('10h 24m 18s'), ('10h 24m 18s', null));
      expect(splitStatUnit('12'), ('12', null));
      expect(splitStatUnit('24 bpm in 60 s'), ('24 bpm in 60 s', null));
    });
  });

  test('the pace ramp runs fast-green to slow-red, and clamps', () {
    // The route's OWN ramp, not the UI accents. A line drawn over a
    // photograph and a darkened basemap is not a label on a card, and the
    // accent green went muddy there.
    expect(paceColor(1), C.routeFast);
    expect(paceColor(0), C.routeSlow);
    // Nothing off the ends: a speed of 1.4 is a GPS artefact, not a colour
    // outside the palette.
    expect(paceColor(9), C.routeFast);
    expect(paceColor(-3), C.routeSlow);
    // …and the ramp really passes through its middle rather than lerping
    // straight from red to lime.
    expect(paceColor(2 / 3), C.routeMid);
    expect(paceColor(1 / 3), C.routeHard);
  });

  testWidgets('the poster prints every stat the session has', (t) async {
    t.view.physicalSize = const Size(390 * 3, 900 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: Center(child: PosterCard(_run))),
    ));
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    // There is no picker and no ceiling. The old four-row cap dropped
    // whatever came fifth, which for a hike was the climb it had recorded.
    for (final label in ['TIME', 'PACE', 'HEART RATE']) {
      expect(find.text(label), findsOneWidget, reason: '$label is missing.');
    }
    // …and nothing it did not measure. Every running card in the world pads
    // this slot with cadence; this session did not measure cadence.
    expect(find.text('CALORIES'), findsNothing);
    expect(find.text('ELEVATION'), findsNothing);
    // The distance is the hero. It is not ALSO a cell — one measurement, set
    // large, is still one measurement.
    expect(find.text('DISTANCE'), findsNothing);
    expect(find.textContaining('12.42'), findsOneWidget);
  });

  testWidgets('the poster draws without a basemap', (t) async {
    // The no-signal card. It must render the route on its own surface and
    // keep every number, rather than showing a hole where the map was.
    t.view.physicalSize = const Size(390 * 3, 900 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Center(child: PosterCard(_run)),
      ),
    ));
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.textContaining('12.42'), findsOneWidget);
    expect(find.text('TIME'), findsOneWidget);
    // The credit is drawn only when tiles are — crediting OpenStreetMap for a
    // map that is not on the card would be its own small lie.
    expect(find.text(kOsmAttribution), findsNothing);
  });

  test('a long pace-lit route blurs once, not once per segment', () {
    final n = 2000;
    final canvas = _CountingCanvas();
    PosterMap(
      mosaic: null,
      fallback: [for (var i = 0; i < n; i++) Offset(i / n, (i % 7) / 7)],
      pace: [for (var i = 0; i < n; i++) (i % 10) / 10],
      line: C.routeFast,
      casing: C.n900,
      start: C.routeFast,
      end: C.routeSlow,
      overPhoto: false,
    ).paint(canvas, const Size(300, 300));
    expect(canvas.blurredDraws, 0);
    expect(canvas.blurLayers, 1);
    expect(canvas.draws, greaterThan(n));
  });
}

class _CountingCanvas implements Canvas {
  // Blurred per-segment lines; the pins' own soft shadow is not counted.
  int draws = 0, blurredDraws = 0, blurLayers = 0;
  @override
  dynamic noSuchMethod(Invocation i) {
    final name = i.memberName.toString();
    if (name.contains('draw')) {
      draws++;
      if (i.memberName == #drawLine &&
          (i.positionalArguments[2] as Paint).maskFilter != null) {
        blurredDraws++;
      }
    }
    if (i.memberName == #saveLayer &&
        (i.positionalArguments[1] as Paint).imageFilter != null) {
      blurLayers++;
    }
    if (name.contains('getSaveCount')) return 1;
    return null;
  }
}

final _run = ActivityResult(
  activityByName('Trail running')!,
  start: DateTime(2026, 8, 13, 18, 20),
  duration: Motion.tick * 3734,
  avgHr: 148,
  distanceKm: 12.42,
  route: const [Offset(.2, .8), Offset(.5, .3), Offset(.8, .7)],
  geo: const [(51.500, -0.120), (51.505, -0.118), (51.508, -0.121)],
);
