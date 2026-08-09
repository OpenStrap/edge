// The workout share card + its preview screen.
//
// WHY THIS EXISTS AS ITS OWN COMPOSITION
//
// Sharing used to capture the finish screen's card wholesale: the header, the
// route, the strain gauge, the peak/avg/kcal/steps row, the time-in-zones bar,
// the heart-rate-recovery curve and any PR badges — everything, in one tall
// PNG. That is a screenshot of a dashboard, not something anyone wants on a
// feed. It also meant the single most share-worthy thing in the whole workout,
// the route, arrived as a thumbnail sandwiched between charts.
//
// A share image has exactly one job: be worth looking at in someone else's
// feed at thumbnail size. So this is composed for that job rather than reused
// from the screen —
//
//   • the map is FULL BLEED and owns the frame; everything else sits on a
//     scrim over it,
//   • one headline number (distance),
//   • three supporting stats, no more,
//   • no gauges, no curves, no badges, no zone bars — none of it survives
//     being scaled to a feed thumbnail anyway,
//   • aspect ratios that match where these actually get posted.
//
// Workouts with no route (indoor, treadmill, permission denied) get the same
// composition with a zone-washed panel in place of the map, so the layout and
// the code path stay identical rather than forking into a second design.

import 'dart:io';
import 'dart:typed_data' show ByteData;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../gps/route_math.dart' as rmath;
import '../../gps/route_models.dart';
import '../../state/units_controller.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon, OsIcon;
import '../kit/share_origin.dart';
import '../kit/route_map.dart';

/// Where the image is going. Strava-style: a feed post and a story, because
/// those are the two shapes people actually post into and a 1:1 crop of a
/// portrait card loses the route.
enum ShareFormat {
  /// 4:5 — the tallest a feed post can be without being cropped.
  feed('Post', 4 / 5),

  /// 9:16 — full-bleed story.
  story('Story', 9 / 16);

  const ShareFormat(this.label, this.aspect);
  final String label;
  final double aspect;
}

/// Everything the card renders. Values arrive pre-formatted so the card stays
/// a pure, testable composition with no unit/locale logic of its own.
class WorkoutShareData {
  /// "Morning Run", "Evening Ride" — the human title.
  final String title;

  /// Quiet date line under the title.
  final String subtitle;

  /// The route. Empty ⇒ the no-map composition.
  final List<RouteVertex> vertices;

  /// Headline figure, split so the unit can be set smaller ("8.42" + "KM").
  final String heroValue;
  final String heroUnit;

  /// Up to three supporting stats — (value, label).
  final List<(String, String)> stats;

  /// Tints the no-map fallback and the accent rule. Defaults to the brand.
  final Color accent;

  const WorkoutShareData({
    required this.title,
    required this.subtitle,
    required this.vertices,
    required this.heroValue,
    required this.heroUnit,
    required this.stats,
    required this.accent,
  });

  bool get hasRoute => vertices.length >= 2;
}

/// The card itself. Fixed logical width; height follows [format].
///
/// Rendered on screen in the preview (never offscreen) so the map tiles are
/// genuinely loaded by the time the user taps Share — capturing a hidden
/// FlutterMap is a race against tile loading that produces half-blank images.
class WorkoutShareCard extends StatelessWidget {
  final WorkoutShareData data;
  final ShareFormat format;

  /// Logical width the card lays out at. The capture scales from this.
  static const double kWidth = 360;

  const WorkoutShareCard({
    super.key,
    required this.data,
    required this.format,
  });

  @override
  Widget build(BuildContext context) {
    final height = kWidth / format.aspect;
    return SizedBox(
      width: kWidth,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(R.card),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── The map owns the frame ──────────────────────────────────
            if (data.hasRoute)
              RouteMapView(
                vertices: data.vertices,
                borderRadius: BorderRadius.zero,
              )
            else
              _NoRouteBackdrop(accent: data.accent),

            // A scrim only where type sits, so the top of the route stays
            // clean. Two stops, weighted low — a full-height gradient greys
            // the whole map out, which is what makes these cards look muddy.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  height: height * 0.52,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.night.withValues(alpha: 0.0),
                        AppColors.night.withValues(alpha: 0.72),
                        AppColors.night.withValues(alpha: 0.94),
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // ── Content ────────────────────────────────────────────────
            Positioned(
              left: Sp.x5,
              right: Sp.x5,
              bottom: Sp.x5,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.overline.copyWith(
                      color: AppColors.onNightMuted,
                      fontSize: 10,
                      letterSpacing: 2.5,
                    ),
                  ),
                  const SizedBox(height: Sp.x2),
                  // Headline: the number, with its unit set small beside it so
                  // the figure itself reads at thumbnail size.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            data.heroValue,
                            maxLines: 1,
                            style: AppText.display.copyWith(
                              color: AppColors.onNight,
                              fontSize: 64,
                              height: 1.0,
                              fontWeight: FontWeight.w900,
                              fontFeatures: [
                                const FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (data.heroUnit.isNotEmpty) ...[
                        const SizedBox(width: Sp.x2),
                        Text(
                          data.heroUnit.toUpperCase(),
                          style: AppText.h2.copyWith(
                            color: AppColors.onNightSoft,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: Sp.x4),
                  Container(height: 2, width: 34, color: data.accent),
                  const SizedBox(height: Sp.x4),
                  Row(
                    children: [
                      for (final (value, label) in data.stats)
                        Expanded(child: _ShareStat(value: value, label: label)),
                    ],
                  ),
                  const SizedBox(height: Sp.x4),
                  Row(
                    children: [
                      AppIcon(OsIcon.activity, size: 13, color: data.accent),
                      const SizedBox(width: Sp.x2),
                      Text(
                        'OpenStrap',
                        style: AppText.caption.copyWith(
                          color: AppColors.onNightMuted,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        data.subtitle,
                        style: AppText.caption
                            .copyWith(color: AppColors.onNightMuted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareStat extends StatelessWidget {
  final String value;
  final String label;
  const _ShareStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.metric.copyWith(
              color: AppColors.onNight,
              fontSize: 19,
              fontFeatures: [const FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label.toUpperCase(),
            style: AppText.overline.copyWith(
              color: AppColors.onNightMuted,
              fontSize: 8,
              letterSpacing: 1.6,
            ),
          ),
        ],
      );
}

/// Stand-in for the map on an indoor/no-GPS workout. Deliberately the same
/// composition, not a different card: a quiet zone-tinted field so the type
/// below still has something to sit on.
class _NoRouteBackdrop extends StatelessWidget {
  final Color accent;
  const _NoRouteBackdrop({required this.accent});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.35),
            radius: 1.1,
            colors: [
              Color.alphaBlend(
                  accent.withValues(alpha: 0.34), AppColors.night),
              AppColors.night,
            ],
          ),
        ),
      );
}

/// Preview-then-share, the way every app that takes sharing seriously does it.
///
/// Tapping Share used to silently rasterise the finish screen and hand the PNG
/// straight to the OS sheet — the athlete never saw what they were about to
/// post until it was already in the composer. Here the card is on screen at
/// real proportions, the format is switchable, and Share is the one obvious
/// action.
///
/// It also removes a real failure mode: capturing a map that was never on
/// screen races tile loading and yields half-blank images. What you see here
/// is literally the thing that gets captured.
class WorkoutSharePreviewScreen extends StatefulWidget {
  final WorkoutShareData data;
  const WorkoutSharePreviewScreen({super.key, required this.data});

  @override
  State<WorkoutSharePreviewScreen> createState() =>
      _WorkoutSharePreviewScreenState();
}

class _WorkoutSharePreviewScreenState extends State<WorkoutSharePreviewScreen> {
  final GlobalKey _captureKey = GlobalKey();
  ShareFormat _format = ShareFormat.feed;
  bool _sharing = false;

  Future<void> _share() async {
    if (_sharing) return;
    // Measured before the capture/encode/write awaits below, per shareOriginFor:
    // after an async gap this widget may have been relaid out and the rect would
    // describe a box that has moved.
    final origin = shareOriginFor(context);
    setState(() => _sharing = true);
    try {
      final boundary = _captureKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('Card not ready');

      // Let the current frame finish so the boundary definitely has a layer to
      // rasterise. The card has been on screen since this route opened, so this
      // is belt-and-braces rather than the main defence.
      //
      // This deliberately does NOT use `boundary.debugNeedsPaint`. That getter
      // is debug-only:
      //
      //     bool get debugNeedsPaint {
      //       late bool result;
      //       assert(() { result = _needsPaint; return true; }());
      //       return result;
      //     }
      //
      // In release and profile builds the assert is stripped, `result` is never
      // assigned, and reading it throws LateInitializationError — so sharing
      // worked in debug and failed on every real build. Nothing catches this:
      // the analyzer is happy, and the whole test suite runs in debug mode.
      // Treat any `debug*` member as unusable outside an assert.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      // Target ~1080 px wide — the native width of a feed post; anything more
      // is bytes nobody sees.
      final pixelRatio = 1080 / WorkoutShareCard.kWidth;
      final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) throw StateError('Failed to encode image');

      final dir = await getTemporaryDirectory();
      // ONE reused filename, not a timestamped file per share. Each capture is
      // a ~1080 px PNG; a unique name per tap left every one of them sitting in
      // the temp directory until the OS felt like reclaiming it. The share
      // sheet has finished reading the file before the next share overwrites.
      final file = File('${dir.path}/openstrap_share.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());

      if (!mounted) return;
      // No caption text: the image carries everything, and a canned
      // "My OpenStrap workout" string is exactly the kind of filler that makes
      // a share feel automated.
      await Share.shareXFiles([XFile(file.path)], sharePositionOrigin: origin);
    } catch (e, st) {
      // Log the detail; show the athlete a fixed sentence. "Couldn't share:
      // PlatformException(...)" puts an internal error string in front of
      // someone who just finished a workout and can do nothing with it.
      debugPrint('[share] failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't prepare the image — try again")),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark().copyWith(scaffoldBackgroundColor: AppColors.night),
      child: Scaffold(
        backgroundColor: AppColors.night,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x3, Sp.x4, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(Icons.close_rounded,
                          color: AppColors.onNightSoft),
                      tooltip: 'Close',
                    ),
                    const Spacer(),
                    Text('Share workout',
                        style: AppText.label
                            .copyWith(color: AppColors.onNight)),
                    const Spacer(),
                    const SizedBox(width: 48), // balances the close button
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: Sp.x4),
                    child: RepaintBoundary(
                      key: _captureKey,
                      child: WorkoutShareCard(
                        data: widget.data,
                        format: _format,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.x5, 0, Sp.x5, Sp.x5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FormatToggle(
                      value: _format,
                      onChanged: (f) => setState(() => _format = f),
                    ),
                    const SizedBox(height: Sp.x4),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton.icon(
                        onPressed: _sharing ? null : _share,
                        icon: _sharing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.ios_share_rounded, size: 19),
                        label: Text(_sharing ? 'Preparing…' : 'Share'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FormatToggle extends StatelessWidget {
  final ShareFormat value;
  final ValueChanged<ShareFormat> onChanged;
  const _FormatToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in ShareFormat.values)
              GestureDetector(
                onTap: () => onChanged(f),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: Motion.fast,
                  curve: Motion.curve,
                  padding: const EdgeInsets.symmetric(
                      horizontal: Sp.x5, vertical: 8),
                  decoration: BoxDecoration(
                    color: f == value
                        ? Colors.white.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(R.pill),
                  ),
                  child: Text(
                    f.label,
                    style: AppText.caption.copyWith(
                      color: f == value
                          ? AppColors.onNight
                          : AppColors.onNightSoft,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// THE one place a share composition is built.
///
/// Both entry points — the finish screen right after a workout, and the detail
/// screen for any past workout — go through here, so the card can never say
/// one thing in one place and something else in the other. Everything the card
/// renders is decided here; the card itself just lays out what it's handed.
///
/// The rule it encodes: **distance leads when there is a route**, because the
/// map is what the image is showing and the headline should name it. With no
/// route the clock leads instead, and the supporting stats swap to the ones
/// that still mean something indoors.
WorkoutShareData buildWorkoutShareData({
  required UnitsController units,
  required String type,
  required Duration duration,
  required DateTime when,
  required int maxHr,

  /// Null when the session was never scored (a profile anchor the Banister
  /// formula needs is missing, or no HR was ever captured for the window).
  /// Nullable all the way to the card: a `?? 0` at the call site prints a
  /// confident "0.0 Strain" for a workout we simply could not score, which is
  /// the same fabrication issue #206 reported on the detail gauge.
  required double? strain,

  /// Null when the profile lacks the anchors Keytel needs — a shared card is
  /// the most public place a fabricated calorie figure could end up, so it
  /// dashes out exactly like [strain].
  required int? calories,
  WorkoutRoute? route,
  int? avgHr,
}) {
  final hasRoute = route != null && route.hasPath;
  final strainText = strain?.toStringAsFixed(1) ?? '—';
  final title = type.isEmpty
      ? 'Workout'
      : type[0].toUpperCase() + type.substring(1);

  String heroValue;
  String heroUnit;
  List<(String, String)> stats;
  if (hasRoute) {
    final parts = units.distance(route.distanceMeters).split(' ');
    heroValue = parts.first;
    heroUnit = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    stats = [
      (_shareDuration(duration), 'Time'),
      // Moving pace, like everywhere else — see the note in _GpsControlPanel.
      (units.pace(route.distanceMeters, route.movingSec), 'Pace'),
      (strainText, 'Strain'),
    ];
  } else {
    heroValue = _shareDuration(duration);
    heroUnit = '';
    stats = [
      (strainText, 'Strain'),
      (calories?.toString() ?? '—', 'Kcal'),
      (avgHr != null && avgHr > 0 ? '$avgHr' : '—', 'Avg bpm'),
    ];
  }

  return WorkoutShareData(
    title: title,
    subtitle: _shareDate(when),
    vertices: hasRoute
        ? rmath.buildVertices(route.points, route.hr, maxHr)
        : const [],
    heroValue: heroValue,
    heroUnit: heroUnit,
    stats: stats,
    accent: AppColors.coral,
  );
}

String _shareDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  return '${m}m ${s.toString().padLeft(2, '0')}s';
}

const _shareMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _shareDate(DateTime t) =>
    '${t.day} ${_shareMonths[t.month - 1]} ${t.year}';
