// A real map under a route, as a still picture.
//
// THIS IS THE ONLY THING IN THE APP THAT TALKS TO A SERVER ABOUT YOUR DATA.
// The z/x/y of a tile is a Web-Mercator encoding of the route's bounding box,
// so asking for one tells openstreetmap.org roughly where the session
// happened. Everything else here stays on the phone, so this cannot be
// implicit: [mapTilesAllowed] is off until the user turns it on, and
// [buildRouteMosaic] refuses without it. A card with no basemap is still a
// card — the route draws on the card's own ground.
//
// The share card is EXPORTED — `RenderRepaintBoundary.toImage` runs once and
// whatever is on screen at that instant is what leaves the phone. An
// interactive map widget loads its tiles asynchronously and would export blank
// about as often as not, which is why this is a fetch-then-paint mosaic rather
// than `flutter_map`: every tile is awaited before anything is drawn, so the
// export is deterministic.
//
// OpenStreetMap's tile usage policy is not decoration. This file honours it:
//   · a real User-Agent naming the app and its repo (the policy's first rule);
//   · a disk cache, so a card re-rendered ten times fetches once;
//   · at most [_maxParallel] requests in flight, which is what the policy
//     allows — a card used to hand all forty of its tiles to one `Future.wait`;
//   · a hard ceiling of [_maxTiles] per card and one zoom level per card, so
//     there is no bulk download here under any input;
//   · [kOsmAttribution], which the caller MUST render on the card. Tiles
//     without the credit are a licence breach, not a design choice.
//
// The tiles are the standard raster style, which is a light map. Painting it
// under a dark card would be a white slab, so the mosaic is tinted to the
// surface it lands on — see [_themeFilter]. Tinting is a display transform of
// our own copy; it does not touch the source data or the credit.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../state/prefs.dart';
import '../theme.dart';

/// Required on any card that draws [buildRouteMosaic]'s output.
const kOsmAttribution = '© OpenStreetMap contributors';

/// Whether the user has said the basemap may be fetched.
///
/// Default OFF and persisted, like every other outbound path in this app
/// (crash reports, health contribution, update checks). The share sheet asks
/// in the one place it matters, in the words this actually does: drawing a
/// basemap asks openstreetmap.org for the tiles covering the route.
const kMapTilesConsent = 'share.map_tiles';

bool get mapTilesAllowed => Prefs.getBool(kMapTilesConsent, false);

void setMapTilesAllowed(bool on) => Prefs.setBool(kMapTilesConsent, on);

const _tileSize = 256;

/// Requests in flight at once. OSM's usage policy caps this at two and treats
/// parallel bulk pulls as grounds for blocking.
const _maxParallel = 2;

/// Per card, as a runaway guard only.
///
/// It is NOT the knob that frames the map, and it used to be treated as one:
/// a loop stepped the zoom down while the count was over this cap. The count
/// cannot respond to that. The frame is a fixed number of PIXELS — the card's
/// own size — so its width in tiles is `width / 256` at every zoom level, and
/// lowering the zoom shows more ground through the same number of tiles.
///
/// The old cap was 24. A poster's export frame is 900×1200, which is a 5×5
/// grid, which is 25. So the loop ran to `_minZoom` on EVERY share, and every
/// card that ever drew a basemap drew the whole world behind a route the size
/// of a full stop. The corridor mask hid it: at zoom 2 a blurred band along
/// the route is an unreadable smear either way, and it took removing the mask
/// for anyone to see what was under it.
///
/// A pathological bounding box was never the risk this protected against —
/// zoom-to-fit already answers a hemisphere-wide route with a low zoom, and
/// the tile count stays frame-bound regardless. What is left is a ceiling that
/// a legitimate frame fits inside with room to spare.
const _maxTiles = 64;

const _minZoom = 2;
const _maxZoom = 17;

/// The policy's first requirement. A generic Dart user-agent is the one thing
/// guaranteed to get an app blocked.
const _userAgent =
    'OpenStrap/1.0 (+https://github.com/abdulsahil/openstrap; local-first '
    'health app; one map per shared activity card)';

/// A stitched basemap, and the route already projected onto it.
class RouteMosaic {
  /// The tiles, stitched and themed. Size is exactly [width] × [height].
  final ui.Image image;

  /// The route in [image]'s pixel space, ready for a `Path`.
  final List<Offset> path;

  final double width, height;

  const RouteMosaic(this.image, this.path, this.width, this.height);

  void dispose() => image.dispose();
}

/// Web Mercator, in tile units at [z] — the slippy-map convention, origin at
/// the top-left of the world, `2^z` tiles across.
///
/// Public because it is the one piece of arithmetic here that can be silently,
/// plausibly wrong: an error in it puts a correct-looking route in the wrong
/// country, and the only way to catch that is to pin it against known
/// coordinates. See `test/poster_map_test.dart`.
///
/// Latitude is clamped to the projection's own limit. Mercator has no poles,
/// `tan(90°)` is infinite, and the NaN that follows propagates into a Path and
/// takes the whole card down with it.
({double x, double y}) tileXY(double lat, double lng, int z) {
  final n = math.pow(2, z).toDouble();
  final clamped = lat.clamp(-85.05112878, 85.05112878);
  final rad = clamped * math.pi / 180;
  // Clamped into the grid at the end too: at exactly the latitude limit the
  // arithmetic lands 2.5e-8 the wrong side of zero, which is right to eight
  // decimal places and still a negative tile row.
  return (
    x: (lng.clamp(-180.0, 180.0) + 180) / 360 * n,
    y: ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n)
        .clamp(0.0, n),
  );
}

/// The input luma window that gets stretched across [bg] → [ink].
///
/// This is the whole reason a dark map was either a grey slab or invisible,
/// and no amount of moving [ink] fixed it. OSM's standard raster has almost
/// no dark pixels: land is `#F2EFE9`, water `#AAD3DF`, parks `#C8FACC`,
/// road fill white. Every feature on the map lives between about 0.78 and
/// 1.0 luma — the top fifth of the range.
///
/// Mapping 0…1 onto the two ends therefore crushed the entire map into the
/// few percent nearest [ink]: water, land and roads came out within a couple
/// of values of each other, so a light [ink] made one flat grey field and a
/// dark [ink] made one flat black field. Neither is a map.
///
/// Stretching the window the source actually uses is what gives water, land
/// and roads room to be told apart while the card stays dark.
const _lumaLo = 0.72, _lumaHi = 1.0;

/// Desaturate the raster and pull it onto the line between [bg] and [ink].
///
/// Two transforms, in order: drop to Rec. 709 luminance, then stretch
/// [_lumaLo]…[_lumaHi] of that grey across `bg`…`ink`. The result reads as a
/// map — roads, water and parks keep their relative brightness, and gain the
/// separation the source's own compressed range denied them — without
/// fighting the card it sits on.
ColorFilter _themeFilter(Color bg, Color ink) {
  // Rec. 709 luma.
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  const span = _lumaHi - _lumaLo;
  // out = from + (luma − lo) / (hi − lo) × (to − from), per channel, which is
  // linear in luma: out = luma × k + (from − lo × k), with k the gain.
  //
  // `ColorFilter.matrix` rows are [r, g, b, a, offset] against 0…255 inputs
  // with a 0…255 offset, while `Color.r/g/b` are 0…1 — hence the ×255 on the
  // offset only. The offset goes NEGATIVE here, which is both legal and the
  // point: it is what pushes everything below `lo` to black rather than
  // leaving the map floating off the bottom of its own range.
  //
  // Sanity, both ends: a source pixel at `hi` luma lands exactly on `to`; one
  // at `lo` lands exactly on `from`; anything below clamps to black in the
  // raster pipeline, which is what should happen to ink the map does not use.
  List<double> row(double from, double to) {
    final k = (to - from) / span;
    return [lr * k, lg * k, lb * k, 0, (from - _lumaLo * k) * 255];
  }

  return ColorFilter.matrix(<double>[
    ...row(bg.r, ink.r),
    ...row(bg.g, ink.g),
    ...row(bg.b, ink.b),
    0, 0, 0, 1, 0,
  ]);
}

Directory? _cacheDir;

Future<File?> _cacheFile(int z, int x, int y) async {
  try {
    _cacheDir ??= Directory('${(await getTemporaryDirectory()).path}/osm_tiles')
      ..createSync(recursive: true);
    return File('${_cacheDir!.path}/${z}_${x}_$y.png');
  } catch (_) {
    // No cache directory is survivable — it means every card refetches, which
    // is slower and ruder but still correct. It is not a reason to draw no map.
    return null;
  }
}

Future<ui.Image?> _tile(int z, int x, int y, http.Client client) async {
  final f = await _cacheFile(z, x, y);
  try {
    if (f != null && f.existsSync() && f.lengthSync() > 0) {
      return await decodeImageFromList(f.readAsBytesSync());
    }
  } catch (_) {
    // A truncated cache entry (killed mid-write) is not fatal — refetch it.
  }
  try {
    final res = await client
        .get(Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png'),
            headers: const {'User-Agent': _userAgent})
        .timeout(Motion.tick * 8);
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
    try {
      f?.writeAsBytesSync(res.bodyBytes);
    } catch (_) {/* cache is best-effort */}
    return await decodeImageFromList(res.bodyBytes);
  } catch (_) {
    return null;
  }
}

/// Fetch a basemap that frames [geo], and project the route onto it.
///
/// Returns null when [mapTilesAllowed] is off, when there is no route, no
/// network, or ANY tile failed — and the caller must then fall back to drawing
/// the route on its own. A missing map is a plainer card; a half-loaded one is
/// a broken picture that somebody else receives.
///
/// [pad] is the fraction of the frame left around the route, so the line never
/// runs into the card's edge. It is also the only zoom control there is, and
/// it is a COARSE one: zoom levels are integers, so shrinking the margin moves
/// a route to the next level only if it was already near the boundary. A 3 km
/// loop steps 16 -> 17 here; a 40 km ride stays at 11 whatever this is set to.
/// Which tiles a route's basemap needs, and at what zoom.
///
/// Pulled out of [buildRouteMosaic] and made pure so it can be tested. The
/// zoom is the one number on this card that fails PLAUSIBLY — a wrong one
/// still draws a tidy map, just of the wrong amount of world — and while it
/// lived inside a function that needs the network, nothing could look at it.
class RouteFrame {
  final int zoom;
  final ({double x, double y}) centre;

  /// Half the frame, in tile units. Deliberately independent of [zoom]: the
  /// frame is a fixed pixel size, and that is the fact the old tile-budget
  /// loop was written as though it were not.
  final double halfW, halfH;

  /// The tile range to fetch, x0/y0 inclusive and x1/y1 exclusive.
  final int x0, x1, y0, y1;

  const RouteFrame({
    required this.zoom,
    required this.centre,
    required this.halfW,
    required this.halfH,
    required this.x0,
    required this.x1,
    required this.y0,
    required this.y1,
  });

  int get tiles => (x1 - x0) * (y1 - y0);
}

/// The largest zoom at which the route still fits inside the padded frame.
///
/// Null when the frame is unusable, or when even the coarsest zoom would ask
/// for more tiles than [_maxTiles] — which a real card cannot do, and which is
/// therefore a refusal rather than a silent zoom-out.
RouteFrame? routeFrame({
  required double loLat,
  required double hiLat,
  required double loLng,
  required double hiLng,
  required int width,
  required int height,
  double pad = .02,
}) {
  if (width <= 0 || height <= 0) return null;
  final usableW = width * (1 - pad * 2), usableH = height * (1 - pad * 2);

  // Largest zoom whose projected bounds still fit the frame. This is the ONLY
  // thing that decides how much world is on the card, so a 3 km loop gets a
  // street map and a 300 km ride gets a region.
  var z = _maxZoom;
  for (; z > _minZoom; z--) {
    final a = tileXY(hiLat, loLng, z), b = tileXY(loLat, hiLng, z);
    final w = (b.x - a.x).abs() * _tileSize, h = (b.y - a.y).abs() * _tileSize;
    if (w <= usableW && h <= usableH) break;
  }

  final centre = tileXY((loLat + hiLat) / 2, (loLng + hiLng) / 2, z);
  final halfW = width / 2 / _tileSize, halfH = height / 2 / _tileSize;
  final frame = RouteFrame(
    zoom: z,
    centre: centre,
    halfW: halfW,
    halfH: halfH,
    x0: (centre.x - halfW).floor(),
    x1: (centre.x + halfW).ceil(),
    y0: (centre.y - halfH).floor(),
    y1: (centre.y + halfH).ceil(),
  );
  return frame.tiles > _maxTiles ? null : frame;
}

Future<RouteMosaic?> buildRouteMosaic(
  List<(double lat, double lng)> geo, {
  required int width,
  required int height,
  required Color bg,
  required Color ink,
  double pad = .02,
}) async {
  // The consent boundary, at the door rather than at each caller. The tile
  // request encodes where the session was, so nothing may ask for one until
  // the user has said it may.
  if (!mapTilesAllowed) return null;
  if (geo.length < 2 || width <= 0 || height <= 0) return null;

  var loLat = geo.first.$1, hiLat = loLat;
  var loLng = geo.first.$2, hiLng = loLng;
  for (final (lat, lng) in geo) {
    if (lat.isNaN || lng.isNaN) return null;
    loLat = math.min(loLat, lat);
    hiLat = math.max(hiLat, lat);
    loLng = math.min(loLng, lng);
    hiLng = math.max(hiLng, lng);
  }

  final frame = routeFrame(
    loLat: loLat,
    hiLat: hiLat,
    loLng: loLng,
    hiLng: hiLng,
    width: width,
    height: height,
    pad: pad,
  );
  if (frame == null) return null;
  final z = frame.zoom;
  final centre = frame.centre;
  final halfW = frame.halfW, halfH = frame.halfH;
  final x0 = frame.x0, x1 = frame.x1, y0 = frame.y0, y1 = frame.y1;

  final n = math.pow(2, z).toInt();
  // Longitude wraps; latitude does not. An out-of-range row is empty ocean off
  // the top or bottom of the world, not a tile to ask for.
  final want = <(int, int)>[
    for (var x = x0; x < x1; x++)
      for (var y = y0; y < y1; y++)
        if (y >= 0 && y < n) (x, y),
  ];
  if (want.isEmpty) return null;

  final client = http.Client();
  final fetched = <(int, int), ui.Image>{};
  var missing = false;
  try {
    // [_maxParallel] at a time, and stop at the first failure: the card needs
    // every tile, so there is nothing to gain from asking for the rest.
    // Consent is re-read per batch: switching the map off mid-fetch stops the
    // requests, and the incomplete mosaic is dropped below.
    for (var i = 0;
        i < want.length && !missing && mapTilesAllowed;
        i += _maxParallel) {
      await Future.wait([
        for (final (x, y) in want.skip(i).take(_maxParallel))
          _tile(z, (x % n + n) % n, y, client).then((img) {
            if (img == null) {
              missing = true;
            } else {
              fetched[(x, y)] = img;
            }
          }),
      ]);
    }
  } finally {
    client.close();
  }
  // ALL of them or none. A mosaic with a tile missing draws a hard-edged
  // near-black square where that tile should be, and it is drawn, exported and
  // sent to somebody else with nothing on screen saying it is broken.
  if (missing || fetched.length != want.length) {
    for (final img in fetched.values) {
      img.dispose();
    }
    return null;
  }

  // Top-left of the frame in tile units, so a tile at (x, y) lands at
  // ((x - originX) * 256, (y - originY) * 256).
  final originX = centre.x - halfW, originY = centre.y - halfH;

  final rec = ui.PictureRecorder();
  final canvas = Canvas(
      rec, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = bg);
  final paint = Paint()
    ..colorFilter = _themeFilter(bg, ink)
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;
  fetched.forEach((k, img) {
    final (tx, ty) = k;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH((tx - originX) * _tileSize, (ty - originY) * _tileSize,
          _tileSize.toDouble(), _tileSize.toDouble()),
      paint,
    );
  });
  final picture = rec.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  for (final img in fetched.values) {
    img.dispose();
  }

  return RouteMosaic(
    image,
    [
      for (final (lat, lng) in geo)
        () {
          final p = tileXY(lat, lng, z);
          return Offset(
              (p.x - originX) * _tileSize, (p.y - originY) * _tileSize);
        }(),
    ],
    width.toDouble(),
    height.toDouble(),
  );
}
