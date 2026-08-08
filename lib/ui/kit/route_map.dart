// RouteMapView — the shared map widget for GPS workout routes.
//
// TILE SOURCE: CARTO's free "Positron" raster basemap, NOT raw
// tile.openstreetmap.org. The OSM Foundation's tile-usage policy explicitly
// forbids "heavy use (e.g. distributing an app that uses tiles from
// openstreetmap.org)" — an app built against tile.openstreetmap.org directly
// gets silently rate-limited / blocked once real usage shows up, which reads
// to a user as "the map doesn't work" with zero error surfaced (flutter_map
// just renders a blank/grey tile on a failed fetch). CARTO's basemap CDN
// (basemaps.cartocdn.com) is the standard production-safe alternative: same
// OSM-derived data, no API key, explicitly permitted for embedding in apps.
// Still requires OSM data attribution (+ CARTO credit), rendered below.
//
// OUR OWN LOOK, not stock CARTO either: the default light, busy,
// multicoloured basemap style clashes with the app's warm-dark ember design
// language and doesn't read as "OpenStrap" — so every tile is passed through
// a fixed ColorFilter (see [_kMapTileMatrix]) that desaturates the whole
// basemap to a warm charcoal-to-cream monochrome (inverted luminance, tinted
// toward AppColors.night / onNight — the SAME invariant dark hero surface the
// live-workout screen itself uses). The map reads as ONE consistent dark,
// branded surface everywhere it appears — live session, finish card, workout
// detail — regardless of the surrounding screen's light/dark theme. Against
// that quiet monochrome base, the route line (vivid, HR-zone-coloured,
// glow-backed) and the coral position dot are the only colour — a deliberate
// one-accent-colour map style (Nike Run Club / Strava's minimal map, not a
// busy street atlas).
//
// Renders the route polyline SEGMENTED and COLOURED BY HR ZONE
// (AppColors.zone), plus an optional pulsing current-position marker. Two
// modes:
//   • interactive: pan/zoom, live marker (full-screen map + the live session).
//   • thumbnail:   non-interactive, fit-to-bounds (finish card + workout
//     detail card).
//
// LOCAL-FIRST: the route points themselves are on-device only, never
// uploaded. Basemap tiles are fetched on demand (no account, no tracking of
// the athlete — the tile CDN only ever sees anonymous {z,x,y} requests, never
// route data). A minimal "© OSM · CARTO" credit is always shown (required by
// both providers' attribution terms) as a small tucked-away text badge, not
// the stock flutter_map attribution box.

import 'package:flutter/material.dart' hide Split;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../gps/route_math.dart' as rmath;
import '../../gps/route_models.dart';
import '../../state/units_controller.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'kit.dart';

// CARTO Positron ("light_all") — a minimal light basemap, the closest
// production-safe equivalent to plain OSM carto for our ColorFilter to
// desaturate. `{r}` is the retina-tile suffix flutter_map fills in itself.
const String _kOsmTileUrl =
    'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
const List<String> _kTileSubdomains = ['a', 'b', 'c', 'd'];
const String _kUserAgent = 'wtf.openstrap.edge';

/// Ceiling for any bounds-fit auto-zoom (initial fit AND live camera-follow).
/// z17 shows a few blocks of real context — enough to read the route against
/// its surroundings. Without a cap, a tight/small bounding box (early in a
/// workout, a short/slow route, a stationary spell) fits to near-max zoom
/// (19 — individual rooftops), which reads as "the map is broken/too zoomed
/// in" even though it's technically "fitting" correctly.
const double kRouteMapMaxAutoZoom = 17.0;

/// Deepest zoom the tile SOURCE serves, and the camera's hard ceiling.
///
/// The grey-map bug lived here, and the first fix treated the symptom. The
/// distinction that matters is flutter_map's own:
///
///   • `TileLayer.maxZoom`       — above this the layer is NOT DRAWN AT ALL.
///     Its docs say to leave it infinite "so that there are tiles always
///     displayed"; it exists for swapping in a different layer when zoomed in.
///   • `TileLayer.maxNativeZoom` — above this, tiles at THIS level are
///     displayed and SCALED. This is the one that describes a tile source.
///
/// The layer was setting `maxZoom: 19`, so past z19 it drew nothing and our
/// luminance-inverting ColorFilter rendered that void as a flat grey slab
/// rather than something obviously blank. Capping the camera hid it at the
/// extreme but left the same cliff in place. Now `maxZoom` is left at its
/// default (infinite) and `maxNativeZoom` describes the source, so every
/// reachable zoom has pixels — slightly soft past the native level, never
/// blank.
///
/// Note flutter_map subtracts 1 from `maxNativeZoom` when it SIMULATES retina
/// (tile_layer.dart:312). We request native retina tiles instead (see
/// `retinaMode` below), so that subtraction does not apply here.
const double kRouteMapMaxTileZoom = 19.0;

/// Floor for the camera. Below roughly this the basemap is continents and the
/// route is a dot — zooming further out is never useful here and only risks
/// the same empty-tile washout at the other end.
const double kRouteMapMinZoom = 3.0;

/// Desaturate + invert-luminance + warm-tint every tile pixel in one pass:
/// each output channel is `-(0.2126R + 0.7152G + 0.0722B) + offset`, with the
/// offset solved so a typical OSM land/background luminance (~240) lands on
/// [AppColors.night] and a typical dark label/road-outline luminance (~20)
/// lands on [AppColors.onNight] — i.e. the basemap's own light/dark ends are
/// pinned to the app's real invariant dark-hero palette, not a generic
/// grayscale. `0,0,0,1,0` on the alpha row leaves transparency untouched.
const List<double> _kMapTileMatrix = [
  -0.2126, -0.7152, -0.0722, 0, 264,
  -0.2126, -0.7152, -0.0722, 0, 261,
  -0.2126, -0.7152, -0.0722, 0, 256,
  0, 0, 0, 1, 0,
];

class RouteMapView extends StatefulWidget {
  /// Route vertices in order, each already tagged with its HR zone (0..5) or
  /// null (drawn neutral).
  final List<RouteVertex> vertices;

  /// Current position — when non-null a pulsing marker is drawn (live map).
  final LatLng? current;

  /// Interactive (pan/zoom, rich attribution) vs static thumbnail.
  final bool interactive;

  /// Optional external camera control (the LIVE map passes one so it can keep
  /// the camera following the growing path). When null the camera is static
  /// after the initial fit — correct for thumbnails / finished routes.
  final MapController? controller;

  /// Fired when the USER pans/zooms (gesture-driven camera move) — the live map
  /// uses it to stop auto-following until re-centred.
  final VoidCallback? onUserPan;

  final double? height;
  final BorderRadius borderRadius;

  const RouteMapView({
    super.key,
    required this.vertices,
    this.current,
    this.interactive = false,
    this.controller,
    this.onUserPan,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(R.cardSm)),
  });

  @override
  State<RouteMapView> createState() => _RouteMapViewState();
}

/// PERFORMANCE — why this is stateful and memoized.
///
/// Polyline building is O(N) over the whole route AND allocates fresh
/// `Polyline` + `List<LatLng>` objects. flutter_map keys its projection and
/// simplification caches on element identity, so handing it new instances
/// forces a full LatLng→Mercator projection plus a Douglas-Peucker pass over
/// every point, for BOTH the glow and the crisp layer, on the UI thread.
///
/// As a StatelessWidget this ran on every single build. On the live map that
/// meant once per 1 Hz session tick (~3,600 vertices an hour ⇒ ~10k point
/// projections/second by minute 90), and on the finish screen it ran once per
/// FRAME of the reveal animation. That is the jank, the heat, and a large part
/// of the "app closed mid-ride" ANR.
///
/// Now the work is redone only when the path actually changes.
class _RouteMapViewState extends State<RouteMapView> {
  List<RouteVertex>? _builtFrom;
  Object? _builtPalette;
  bool? _builtInteractive;
  List<LatLng> _points = const [];
  List<Polyline> _glow = const [];
  List<Polyline> _crisp = const [];

  // TileLayer DISPOSES whatever provider it is handed when it leaves the tree,
  // and NetworkTileProvider closes its internal client on dispose — so the
  // instance cannot simply be held for the life of the State. The `pts.isEmpty`
  // early return in build() tears the layer down, so a route that empties and
  // refills (a live workout before its first accepted fix) would come back with
  // a closed client and fail every tile from then on. Build a fresh one on each
  // remount instead.
  //
  // `silenceExceptions` is the actual fix for the reported issue: a tile fetch
  // that fails with no network resolves to a transparent tile instead of
  // throwing into the zone error handler, which was reporting every failed
  // basemap request as an app error.
  NetworkTileProvider? _tiles;

  @override
  void initState() {
    super.initState();
    _rebuildIfNeeded();
  }

  @override
  void didUpdateWidget(RouteMapView old) {
    super.didUpdateWidget(old);
    _rebuildIfNeeded();
  }

  /// Identity check, not a deep compare: RouteTracker publishes a NEW
  /// unmodifiable list per accepted fix, so identity changes exactly when the
  /// path really grew. A deep compare would cost as much as the rebuild.
  ///
  /// The key includes the palette and `interactive` because the cached
  /// polylines bake BOTH in: `_colorFor` resolves AppColors.zone() from the
  /// active palette, and the stroke width comes from `interactive`. Keying on
  /// the vertex list alone meant a theme switch left a finished route drawn in
  /// the old palette's colours until the route object itself changed — and the
  /// design gallery toggles the theme with exactly this widget on screen.
  void _rebuildIfNeeded() {
    if (identical(_builtFrom, widget.vertices) &&
        identical(_builtPalette, AppColors.active) &&
        _builtInteractive == widget.interactive) {
      return;
    }
    _builtFrom = widget.vertices;
    _builtPalette = AppColors.active;
    _builtInteractive = widget.interactive;
    _points = [for (final v in widget.vertices) v.pos];
    _glow = _polylines(glow: true);
    _crisp = _polylines();
  }

  Color _colorFor(int? zone) =>
      zone == null ? AppColors.inkMuted : AppColors.zone(zone);

  /// Group consecutive same-zone edges into coloured polylines. Each new
  /// polyline starts at the previous segment's last point so the path is
  /// visually continuous — EXCEPT across a recording gap (`gapBefore`), where
  /// the line breaks instead of drawing a straight edge across the gap.
  /// [glow] draws the same segmentation wider + faded, for a soft backlit
  /// look under the crisp line — the only colour against the monochrome
  /// basemap, so it needs to read as unmistakably "the route", not a thin
  /// GPS-app line lost against a busy street atlas.
  // A bad GPS fix can carry NaN/Inf lat/lng (see the finite-filter in build()
  // below for the camera/bounds path). _points there is filtered, but
  // _polylines() reads straight from `vertices`, so it needs its own check —
  // an unfiltered NaN/Inf vertex reaching PolylineLayer can crash or corrupt
  // rendering.
  bool _validPos(List<RouteVertex> v, int i) {
    final p = v[i].pos;
    return p.latitude.isFinite && p.longitude.isFinite;
  }

  List<Polyline> _polylines({bool glow = false}) {
    final v = widget.vertices;
    if (v.length < 2) return const [];
    final out = <Polyline>[];
    Color edgeColor(int i) => _colorFor(v[i + 1].zone);
    final width = widget.interactive ? 5.0 : 4.0;
    var i = 0;
    while (i < v.length - 1) {
      if (v[i + 1].gapBefore || !_validPos(v, i) || !_validPos(v, i + 1)) {
        // Segment break — no edge across a recording gap OR an invalid
        // (NaN/Inf) vertex; either way we never draw an edge touching it.
        i++;
        continue;
      }
      final c = edgeColor(i);
      final pts = <LatLng>[v[i].pos];
      var j = i;
      while (j < v.length - 1 &&
          edgeColor(j) == c &&
          !v[j + 1].gapBefore &&
          _validPos(v, j + 1)) {
        pts.add(v[j + 1].pos);
        j++;
      }
      out.add(Polyline(
        points: pts,
        color: glow ? c.withValues(alpha: 0.35) : c,
        strokeWidth: glow ? width * 3.2 : width,
        strokeCap: StrokeCap.round,
        strokeJoin: StrokeJoin.round,
      ));
      i = j;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    // Also checked here, not only in didUpdateWidget: the palette is a global
    // static, so a theme switch that leaves this widget instance untouched
    // would otherwise never invalidate the cache. Three identity comparisons
    // when nothing changed.
    _rebuildIfNeeded();
    // Drop any non-finite GPS coordinate (a bad fix can carry NaN/Inf lat/lng).
    // Left in, it makes LatLngBounds + camera-fit NaN and crashes the tile layer
    // at build (NaN.toInt in flutter_map's _clampToNativeZoom) — a real FATAL.
    final pts = [
      for (final p in _points)
        if (p.latitude.isFinite && p.longitude.isFinite) p,
    ];
    if (pts.isEmpty) {
      // The TileLayer is about to be disposed (and with it our provider); drop
      // the reference so the next mount builds a live one.
      _tiles = null;
      return const SizedBox.shrink();
    }
    final tileProvider = _tiles ??= NetworkTileProvider(silenceExceptions: true);

    // Detect gesture-driven camera moves so a live map can stop auto-following.
    void onPositionChanged(MapCamera camera, bool hasGesture) {
      if (hasGesture) widget.onUserPan?.call();
    }

    // Only bounds-fit when the box has real area. A zero-area box (every point
    // identical — a stationary or aborted route) makes CameraFit.bounds emit a
    // NaN/Infinite zoom that the tile layer then crashes on; fall back to a
    // fixed-zoom center view in that case.
    LatLngBounds? fitBounds;
    if (pts.length >= 2) {
      final b = LatLngBounds.fromPoints(pts);
      if ((b.north - b.south).abs() > 1e-7 ||
          (b.east - b.west).abs() > 1e-7) {
        fitBounds = b;
      }
    }
    final options = fitBounds != null
        ? MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: fitBounds,
              padding: const EdgeInsets.all(28),
              // Cap how far bounds-fit will zoom in. Without this, a route
              // whose points are all still close together (early in a
              // workout, a short/slow route, or a tight loop) fits to a
              // near-zero-size box and zooms in to the tile layer's max
              // (19 — rooftop level) instead of a sane street-scale view.
              maxZoom: kRouteMapMaxAutoZoom,
            ),
            onPositionChanged: onPositionChanged,
            minZoom: kRouteMapMinZoom,
            maxZoom: kRouteMapMaxTileZoom,
            interactionOptions: InteractionOptions(
              flags:
                  widget.interactive ? InteractiveFlag.all : InteractiveFlag.none,
            ),
          )
        : MapOptions(
            initialCenter: pts.first,
            initialZoom: 15,
            onPositionChanged: onPositionChanged,
            minZoom: kRouteMapMinZoom,
            maxZoom: kRouteMapMaxTileZoom,
            interactionOptions: InteractionOptions(
              flags:
                  widget.interactive ? InteractiveFlag.all : InteractiveFlag.none,
            ),
          );

    final map = FlutterMap(
      mapController: widget.controller,
      options: options,
      children: [
        // Our own look, not stock OSM — see the file header + _kMapTileMatrix.
        ColorFiltered(
          colorFilter: const ColorFilter.matrix(_kMapTileMatrix),
          child: TileLayer(
            urlTemplate: _kOsmTileUrl,
            subdomains: _kTileSubdomains,
            userAgentPackageName: _kUserAgent,
            tileProvider: tileProvider,
            // NOT `maxZoom` — see kRouteMapMaxTileZoom. Leaving the display
            // ceiling at its default keeps tiles on screen at every zoom.
            maxNativeZoom: kRouteMapMaxTileZoom.round(),
            // The URL carries the `{r}` retina placeholder, but flutter_map
            // only substitutes it when retinaMode is ON — left unset (the
            // default is false) it silently resolved to "" and we fetched
            // standard-resolution tiles on every device, then scaled them up
            // on a 3× display. That is a soft, slightly muddy basemap
            // everywhere, and it shows most in the shared image where the map
            // is the whole point. flutter_map logs a warning about exactly
            // this; it was being missed in the test noise.
            retinaMode: RetinaMode.isHighDensity(context),
          ),
        ),
        // Glow pass BEHIND the crisp line — the route is the only colour
        // against the monochrome basemap; it needs to read unmistakably as
        // "the route" at a glance, not a thin GPS-app line.
        PolylineLayer(polylines: _glow),
        PolylineLayer(polylines: _crisp),
        if (widget.current != null)
          MarkerLayer(
            markers: [
              Marker(
                point: widget.current!,
                width: 34,
                height: 34,
                child: const _PulseDot(),
              ),
            ],
          ),
        _attribution(),
      ],
    );

    final clipped = ClipRRect(
      borderRadius: widget.borderRadius,
      // The map paints continuously (tile fades, the live pulse dot) and sits
      // inside screens that rebuild at 1 Hz — isolate it so those repaints
      // never dirty the surrounding stats/cards.
      child: RepaintBoundary(child: map),
    );
    return widget.height == null
        ? clipped
        : SizedBox(height: widget.height, child: clipped);
  }

  /// A minimal, tucked-away credit — required by both the OSM data licence
  /// and CARTO's basemap terms, but styled as a small text badge that blends
  /// into our own dark map rather than flutter_map's stock boxed attribution
  /// widget.
  Widget _attribution() => Positioned(
        right: 6,
        bottom: 6,
        child: GestureDetector(
          onTap: () => launchUrl(
            Uri.parse('https://www.openstreetmap.org/copyright'),
            mode: LaunchMode.externalApplication,
          ),
          child: Text(
            '© OpenStreetMap · CARTO',
            style: AppText.captionMuted.copyWith(
              color: AppColors.onNightSoft,
              fontSize: 9,
            ),
          ),
        ),
      );
}

/// Full-screen interactive map (tapped from a route thumbnail).
class RouteMapScreen extends StatelessWidget {
  final List<RouteVertex> vertices;
  final String title;
  const RouteMapScreen({
    super.key,
    required this.vertices,
    this.title = 'Route',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(title, style: AppText.h2),
      ),
      body: Column(
        children: [
          Expanded(
            child: RouteMapView(
              vertices: vertices,
              interactive: true,
              borderRadius: BorderRadius.zero,
            ),
          ),
          const SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(Sp.x4),
              child: RouteZoneLegend(),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact HR-zone colour key for the route map.
class RouteZoneLegend extends StatelessWidget {
  const RouteZoneLegend({super.key});
  static const _labels = ['Rest', 'Warm', 'Fat', 'Aero', 'Thr', 'Max'];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Sp.x3,
      runSpacing: Sp.x2,
      alignment: WrapAlignment.center,
      children: [
        for (var z = 0; z < 6; z++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: AppColors.zone(z),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: Sp.x1),
              Text(_labels[z], style: AppText.captionMuted),
            ],
          ),
      ],
    );
  }
}

/// A ProCard with a static route thumbnail + distance / pace summary; tapping
/// opens the full interactive map. Render only when `route.hasPath`.
class RouteCard extends StatefulWidget {
  final WorkoutRoute route;
  final int maxHr;
  const RouteCard({super.key, required this.route, required this.maxHr});

  @override
  State<RouteCard> createState() => _RouteCardState();
}

/// PERFORMANCE — see the note on [_RouteMapViewState] too.
///
/// `buildVertices` is O(N) over the route with a binary search into the HR
/// series and a haversine per point, and it allocates a `RouteVertex` for each
/// one. The per-point speed scan below is another full pass.
///
/// This used to sit directly in a StatelessWidget's build. The workout finish
/// screen wraps its whole list in an `AnimatedBuilder`, so for a 60-minute ride
/// (~3,600 points) that was roughly 200k trig ops and allocations PER SECOND
/// for the duration of the reveal animation — which is exactly why the finish
/// screen felt broken. Hoisted into state and recomputed only when the route or
/// max-HR actually changes.
class _RouteCardState extends State<RouteCard> {
  WorkoutRoute? _builtFrom;
  int? _builtMaxHr;
  List<RouteVertex> _vertices = const [];
  double? _avgSpeedMps;
  double? _maxSpeedMps;

  @override
  void initState() {
    super.initState();
    _rebuildIfNeeded();
  }

  @override
  void didUpdateWidget(RouteCard old) {
    super.didUpdateWidget(old);
    _rebuildIfNeeded();
  }

  void _rebuildIfNeeded() {
    final route = widget.route;
    if (identical(_builtFrom, route) && _builtMaxHr == widget.maxHr) return;
    _builtFrom = route;
    _builtMaxHr = widget.maxHr;
    _vertices = rmath.buildVertices(route.points, route.hr, widget.maxHr);
    // Avg/max speed from the per-point recorded speeds — a Strava-style stat
    // distinct from pace (more natural for cycling, and "max speed" a
    // descent/sprint peak that avg-pace/best-split don't surface at all).
    final speeds = [
      for (final p in route.points)
        if (p.speed != null && p.speed! >= 0) p.speed!,
    ];
    _avgSpeedMps = speeds.isEmpty
        ? null
        : speeds.reduce((a, b) => a + b) / speeds.length;
    _maxSpeedMps = speeds.isEmpty ? null : speeds.reduce((a, b) => a > b ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final units = context.watch<UnitsController>();
    final route = widget.route;
    final vertices = _vertices;
    final avgPace = units.pace(route.distanceMeters, route.movingSec);
    // Best pace = the fastest FULL split (partial trailing split excluded).
    final unitMeters = units.distanceUnitMeters;
    final splits = units.isImperial ? route.splitsMi : route.splitsKm;
    double? bestPace;
    for (final s in splits) {
      if (s.meters < unitMeters - 1) continue; // skip the partial split
      final p = s.paceSecPerUnit(unitMeters);
      if (p.isFinite && (bestPace == null || p < bestPace)) bestPace = p;
    }
    final bestPaceText =
        bestPace == null ? '—' : '${units.formatPace(bestPace)} ${units.paceUnit}';
    final avgSpeedMps = _avgSpeedMps;
    final maxSpeedMps = _maxSpeedMps;
    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(OsIcon.activity, size: 16, color: AppColors.coral),
              const SizedBox(width: Sp.x2),
              Text('ROUTE', style: AppText.overline),
            ],
          ),
          const SizedBox(height: Sp.x3),
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    RouteMapScreen(vertices: vertices, title: 'Route'),
              ),
            ),
            child: RouteMapView(vertices: vertices, height: 168),
          ),
          const SizedBox(height: Sp.x4),
          Row(
            children: [
              Expanded(
                child: _RouteStat(
                  units.distance(route.distanceMeters),
                  'distance',
                ),
              ),
              Expanded(child: _RouteStat(avgPace, 'avg pace')),
              Expanded(child: _RouteStat(bestPaceText, 'best pace')),
            ],
          ),
          // Speed is only meaningful when the platform actually reported it
          // for this route (older recordings / some Android devices may
          // have none) — omit the row entirely rather than show a row of "—".
          if (avgSpeedMps != null) ...[
            const SizedBox(height: Sp.x4),
            Row(
              children: [
                Expanded(
                  child: _RouteStat(units.speed(avgSpeedMps), 'avg speed'),
                ),
                Expanded(
                  child: _RouteStat(units.speed(maxSpeedMps), 'max speed'),
                ),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RouteStat extends StatelessWidget {
  final String value;
  final String label;
  const _RouteStat(this.value, this.label);
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppText.metricSm),
        Text(label, style: AppText.captionMuted),
      ],
    );
  }
}

/// Per-split table (per km or per mi by the user's unit). Each row shows the
/// split index, a pace bar (fuller = faster, coloured by the split's avg-HR
/// zone), the pace, and the average HR.
class SplitsTable extends StatelessWidget {
  final WorkoutRoute route;
  final int maxHr;
  const SplitsTable({super.key, required this.route, required this.maxHr});

  @override
  Widget build(BuildContext context) {
    final units = context.watch<UnitsController>();
    final imperial = units.isImperial;
    final splits = imperial ? route.splitsMi : route.splitsKm;
    final unitMeters = units.distanceUnitMeters;
    if (splits.isEmpty) return const SizedBox.shrink();

    // Fastest pace (smallest sec/unit) among full splits → bar normalization.
    double? fastest;
    for (final s in splits) {
      final p = s.paceSecPerUnit(unitMeters);
      if (p.isFinite && (fastest == null || p < fastest)) fastest = p;
    }

    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('SPLITS', style: AppText.overline),
              const Spacer(),
              Text('pace ${units.paceUnit} · bpm', style: AppText.captionMuted),
            ],
          ),
          const SizedBox(height: Sp.x3),
          for (final s in splits) ...[
            _SplitRow(
              split: s,
              unitMeters: unitMeters,
              unitLabel: units.distanceUnit,
              fastest: fastest,
              maxHr: maxHr,
              paceText: units.formatPace(s.paceSecPerUnit(unitMeters)),
            ),
            const SizedBox(height: Sp.x3),
          ],
        ],
      ),
    );
  }
}

class _SplitRow extends StatelessWidget {
  final Split split;
  final double unitMeters;
  final String unitLabel;
  final double? fastest;
  final int maxHr;
  final String paceText;
  const _SplitRow({
    required this.split,
    required this.unitMeters,
    required this.unitLabel,
    required this.fastest,
    required this.maxHr,
    required this.paceText,
  });

  @override
  Widget build(BuildContext context) {
    final pace = split.paceSecPerUnit(unitMeters);
    final frac = (fastest != null && pace.isFinite && pace > 0)
        ? (fastest! / pace).clamp(0.0, 1.0)
        : 0.0;
    final avgHr = split.avgHr;
    final zoneColor = avgHr == null
        ? AppColors.inkMuted
        : AppColors.zone(rmath.zoneForHr(avgHr.round(), maxHr));
    // Label the split by its distance mark; the final partial split shows its
    // actual fractional distance.
    final full = split.meters >= unitMeters - 1;
    final label = full
        ? '${split.index}'
        : (split.meters / unitMeters).toStringAsFixed(2);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 34,
          child: Text(label, style: AppText.label),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Stack(
              children: [
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                Container(
                  height: 10,
                  width: c.maxWidth * frac,
                  decoration: BoxDecoration(
                    color: zoneColor,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: Sp.x3),
        SizedBox(
          width: 56,
          child: Text(
            paceText,
            style: AppText.label,
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: Sp.x2),
        SizedBox(
          width: 44,
          child: Text(
            avgHr == null ? '—' : '${avgHr.round()}',
            style: AppText.captionMuted,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

/// A softly pulsing dot for the live current position.
class _PulseDot extends StatefulWidget {
  const _PulseDot();
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_c.value);
        return Stack(
          alignment: Alignment.center,
          children: [
            // Expanding halo.
            Opacity(
              opacity: (1 - t) * 0.5,
              child: Container(
                width: 12 + 22 * t,
                height: 12 + 22 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.coral.withValues(alpha: 0.4),
                ),
              ),
            ),
            // Solid core with a white ring.
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.coral,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
