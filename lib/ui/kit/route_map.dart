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

class RouteMapView extends StatelessWidget {
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

  List<LatLng> get _points => [for (final v in vertices) v.pos];

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
  List<Polyline> _polylines({bool glow = false}) {
    final v = vertices;
    if (v.length < 2) return const [];
    final out = <Polyline>[];
    Color edgeColor(int i) => _colorFor(v[i + 1].zone);
    final width = interactive ? 5.0 : 4.0;
    var i = 0;
    while (i < v.length - 1) {
      if (v[i + 1].gapBefore) {
        i++; // segment break — no edge across the gap
        continue;
      }
      final c = edgeColor(i);
      final pts = <LatLng>[v[i].pos];
      var j = i;
      while (j < v.length - 1 && edgeColor(j) == c && !v[j + 1].gapBefore) {
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
    final pts = _points;
    if (pts.isEmpty) return const SizedBox.shrink();

    // Detect gesture-driven camera moves so a live map can stop auto-following.
    void onPositionChanged(MapCamera camera, bool hasGesture) {
      if (hasGesture) onUserPan?.call();
    }

    final options = pts.length >= 2
        ? MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(pts),
              padding: const EdgeInsets.all(28),
              // Cap how far bounds-fit will zoom in. Without this, a route
              // whose points are all still close together (early in a
              // workout, a short/slow route, or a tight loop) fits to a
              // near-zero-size box and zooms in to the tile layer's max
              // (19 — rooftop level) instead of a sane street-scale view.
              maxZoom: kRouteMapMaxAutoZoom,
            ),
            onPositionChanged: onPositionChanged,
            interactionOptions: InteractionOptions(
              flags: interactive ? InteractiveFlag.all : InteractiveFlag.none,
            ),
          )
        : MapOptions(
            initialCenter: pts.first,
            initialZoom: 15,
            onPositionChanged: onPositionChanged,
            interactionOptions: InteractionOptions(
              flags: interactive ? InteractiveFlag.all : InteractiveFlag.none,
            ),
          );

    final map = FlutterMap(
      mapController: controller,
      options: options,
      children: [
        // Our own look, not stock OSM — see the file header + _kMapTileMatrix.
        ColorFiltered(
          colorFilter: const ColorFilter.matrix(_kMapTileMatrix),
          child: TileLayer(
            urlTemplate: _kOsmTileUrl,
            subdomains: _kTileSubdomains,
            userAgentPackageName: _kUserAgent,
            maxZoom: 19,
          ),
        ),
        // Glow pass BEHIND the crisp line — the route is the only colour
        // against the monochrome basemap; it needs to read unmistakably as
        // "the route" at a glance, not a thin GPS-app line.
        PolylineLayer(polylines: _polylines(glow: true)),
        PolylineLayer(polylines: _polylines()),
        if (current != null)
          MarkerLayer(
            markers: [
              Marker(
                point: current!,
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
      borderRadius: borderRadius,
      child: map,
    );
    return height == null ? clipped : SizedBox(height: height, child: clipped);
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
class RouteCard extends StatelessWidget {
  final WorkoutRoute route;
  final int maxHr;
  const RouteCard({super.key, required this.route, required this.maxHr});

  @override
  Widget build(BuildContext context) {
    final units = context.watch<UnitsController>();
    final vertices = rmath.buildVertices(route.points, route.hr, maxHr);
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
    // Avg/max speed from the per-point recorded speeds — a Strava-style stat
    // distinct from pace (more natural for cycling, and "max speed" a
    // descent/sprint peak that avg-pace/best-split don't surface at all).
    final speeds = [
      for (final p in route.points)
        if (p.speed != null && p.speed! >= 0) p.speed!,
    ];
    final avgSpeedMps = speeds.isEmpty
        ? null
        : speeds.reduce((a, b) => a + b) / speeds.length;
    final maxSpeedMps =
        speeds.isEmpty ? null : speeds.reduce((a, b) => a > b ? a : b);
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
          if (speeds.isNotEmpty) ...[
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
