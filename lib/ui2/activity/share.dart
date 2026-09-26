// Share — one card, one photo slot, one button.
//
// This screen used to ask three questions: which of three styles, which four
// of nine stats, and whether to add a photo. Two of them were the screen
// asking the user to do its job. The style list offered a textured card whose
// texture a lift and a flow session could not have; the chip row asked which
// of your own measurements to leave off a card with room for all of them.
//
// What is left is the one question only the user can answer — is there a
// picture of this — and the card rearranges itself around the answer:
//
//   · no photo  → the basemap IS the card, whole, start to stop
//   · a photo   → the photograph is the card, and the route dissolves into
//                 its bottom-right corner with no frame of its own
//
// Nothing on the card is invented. If a session has no distance, "Distance"
// is not printed, so it cannot be shared.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state/units_controller.dart';
import '../grammar.dart';
import '../profile/profile.dart' show SetRow;
import '../theme.dart';
import 'poster.dart';
import 'summary.dart';
import 'tiles.dart';

/// The rect an iPad or Mac share popover points at.
///
/// `UIActivityViewController` is a popover on those, and `share_plus` throws
/// rather than guessing when it is given no anchor — which is how every iPad
/// share in this app failed silently. Any `share_plus` call from a widget
/// should pass this.
Rect shareOrigin(BuildContext c) {
  final box = c.findRenderObject();
  if (box is! RenderBox || !box.hasSize) {
    return const Rect.fromLTWH(0, 0, 1, 1);
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

class ShareSheet extends StatefulWidget {
  final ActivityResult result;
  const ShareSheet(this.result, {super.key});

  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  /// The card, as pixels. Sharing a picture of it means capturing the thing on
  /// screen rather than re-drawing a second, slightly different one.
  final _card = GlobalKey();
  bool _sharing = false;

  /// The user's own picture, and only ever the user's. Nothing here fetches
  /// or generates one.
  File? _photo;

  /// Where the card is going. The one thing besides the photo that changes it.
  PosterFormat _format = PosterFormat.post;

  /// The basemap. Fetched per FORMAT, because the mosaic is built at the
  /// card's aspect — see the note on [kPosterMapH]. Held so that flipping
  /// back to a format already fetched does not re-hit the tile server, which
  /// the usage policy in tiles.dart is explicit about.
  final _mosaics = <PosterFormat, RouteMosaic>{};
  final _mapTried = <PosterFormat>{};

  /// The formats with a fetch in flight. Without this the sheet showed "the
  /// tiles could not be fetched" for the whole duration of a fetch that was
  /// still running, because `_mapTried` is set before the first await.
  final _mapLoading = <PosterFormat>{};

  /// Whether the tile fetch is allowed at all. Persisted, default off — see
  /// [mapTilesAllowed].
  late bool _mapConsent = mapTilesAllowed;

  RouteMosaic? get _mosaic => _mosaics[_format];
  bool get _mapTried_ => _mapTried.contains(_format);
  bool get _mapBusy => _mapLoading.contains(_format);

  ActivityResult get r => widget.result;

  /// Whether this session went anywhere. Decides whether there is a map at
  /// all — not which of several cards to draw, because there is one card.
  bool get _hasRoute => r.geo.length >= 2;

  Future<void> _share() async {
    if (_sharing) return;
    _sharing = true;
    // Both read the tree, so both are read before the first await.
    final origin = shareOrigin(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary =
          _card.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return;
      await Share.shareXFiles(
        [
          XFile.fromData(png.buffer.asUint8List(),
              mimeType: 'image/png', name: '${r.activity.typeKey}.png'),
        ],
        sharePositionOrigin: origin,
      );
    } catch (e) {
      // A share that quietly does nothing is worse than one that says it
      // failed: this swallowed every iPad share for the life of the screen.
      if (mounted) {
        final l = AppLocalizations.of(context);
        messenger.showSnackBar(SnackBar(
            content: Text(
                l?.activityShareOpenFailed ?? 'Could not open the share sheet.')));
      }
      debugPrint('share failed: $e');
    } finally {
      _sharing = false;
    }
  }

  /// The user's own picture, from this phone. No upload, no fetch, no stock
  /// backdrop picked by activity type — the card either has their photo on it
  /// or it has the accent gradient.
  Future<void> _pickPhoto() async {
    try {
      final picked = await FilePicker.platform
          .pickFiles(type: FileType.image, allowMultiple: false);
      final path = picked?.files.single.path;
      if (path != null && mounted) setState(() => _photo = File(path));
    } catch (e) {
      debugPrint('photo pick failed: \$e');
    }
  }

  /// Turn the basemap on or off, and mean it.
  ///
  /// Off drops the tiles already on the card as well as the consent — leaving
  /// a fetched map on screen after the user said no would make the switch a
  /// label rather than a control.
  void _toggleMap() {
    final on = !_mapConsent;
    setMapTilesAllowed(on);
    setState(() {
      _mapConsent = on;
      if (!on) {
        for (final m in _mosaics.values) {
          m.dispose();
        }
        _mosaics.clear();
        _mapTried.clear();
      }
    });
    if (on) _ensureMap();
  }

  /// Fetch the basemap once, for a session that went somewhere — and only
  /// once the user has said openstreetmap.org may be asked for it.
  ///
  /// It used to be deferred until the Poster style was selected, so a session
  /// whose owner never opened it never hit the tile server. There is no style
  /// to select now — a card with no photo IS the map — so a session with
  /// coordinates needs one, and it is fetched once per format and held.
  Future<void> _ensureMap() async {
    final f = _format;
    if (!_mapConsent || _mapTried.contains(f) || !_hasRoute) return;
    _mapTried.add(f);
    setState(() => _mapLoading.add(f));
    // Midnight, both ends, and NOT the reader's palette.
    //
    // This card is exported and sent to someone else — it is dark whichever
    // theme drew it, so tinting the basemap to the viewer's surface produced
    // a bright map on a dark card for half the users. `mapFloor`/`mapCeil`
    // are the card's own map styling: near-black land and water, and a dim
    // slate ceiling so roads, buildings and the labels baked into the raster
    // sit down as texture rather than standing up as type.
    final m = await buildRouteMosaic(
      r.geo,
      // The card's own map box, at export resolution (`toImage` runs at 3x).
      width: kPosterMapW.round() * 3,
      height: kPosterMapH(f).round() * 3,
      bg: C.mapFloor,
      ink: C.mapCeil,
    );
    if (!mounted) {
      m?.dispose();
      return;
    }
    setState(() {
      _mapLoading.remove(f);
      if (m != null) _mosaics[f] = m;
    });
  }

  @override
  void initState() {
    super.initState();
    if (_hasRoute) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureMap());
    }
  }

  @override
  void dispose() {
    for (final m in _mosaics.values) {
      m.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(l?.activityShareTitle ?? 'Share'),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x8),
                children: [
                  // One card. There is no style list any more, and no chip row
                  // deciding which of the session's own measurements to leave
                  // off it — the card prints everything the session has, and
                  // the only thing the reader chooses is whether their photo
                  // is behind it.
                  // scaleDown, so a narrow viewport shrinks the card WHOLE.
                  // The boundary underneath keeps its authored 300 pt width
                  // whatever the screen does, and `toImage` reads the boundary
                  // — so a 320 pt phone exports the same 1:1 square as a big
                  // one instead of the 0.96:1 Instagram crops.
                  Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: RepaintBoundary(
                        key: _card,
                        child: PosterCard(
                          r,
                          photo: _photo == null ? null : FileImage(_photo!),
                          mosaic: _mosaic,
                          format: _format,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: S.x6),
                  // Not a style picker coming back. A format is where the
                  // card is GOING — Instagram crops anything that is not its
                  // own ratio, so this is the difference between posting the
                  // card and posting a crop of it.
                  SubTabs(
                    [for (final f in PosterFormat.values) posterFormatLabel(c, f)],
                    PosterFormat.values.indexOf(_format),
                    (i) {
                      setState(() => _format = PosterFormat.values[i]);
                      _ensureMap();
                    },
                    color: r.activity.color,
                  ),
                  const SizedBox(height: S.x6),
                  Text(l?.activitySharePhotoHeader ?? 'YOUR PHOTO',
                      style: F.over.copyWith(color: p.ink3)),
                  const SizedBox(height: S.x3),
                  Surface(
                    pad: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: Column(children: [
                      SetRow(
                          LucideIcons.imagePlus,
                          r.activity.color,
                          _photo == null
                              ? (l?.activityShareAddPhoto ?? 'Add a photo')
                              : (l?.activityShareChangePhoto ??
                                  'Change photo'),
                          sub: _photo == null
                              ? (l?.activitySharePhotoHint ??
                                  'From this phone. Nothing is uploaded')
                              : _photo!.path.split('/').last,
                          onTap: _pickPhoto),
                      if (_photo != null) ...[
                        Divider(color: p.line, height: 1),
                        SetRow(LucideIcons.trash2, C.red,
                            l?.activityShareRemovePhoto ?? 'Remove the photo',
                            chevron: false,
                            onTap: () => setState(() => _photo = null)),
                      ],
                    ]),
                  ),
                  // The one thing on this screen that leaves the phone. Off
                  // until it is turned on, in the words of what it does — the
                  // tiles are addressed by where the route is, so asking for
                  // them tells openstreetmap.org roughly where you were.
                  if (_hasRoute) ...[
                    const SizedBox(height: S.x6),
                    Text(l?.activityShareBasemapHeader ?? 'BASEMAP',
                        style: F.over.copyWith(color: p.ink3)),
                    const SizedBox(height: S.x3),
                    Surface(
                      pad: const EdgeInsets.symmetric(horizontal: S.x4),
                      child: SetRow(
                        LucideIcons.map,
                        r.activity.color,
                        l?.activityShareDrawMap ?? 'Draw the real map',
                        sub: l?.activityShareMapHint ??
                            'Asks openstreetmap.org for the tiles covering '
                                'this route. Off, the route draws on its own',
                        value: _mapConsent
                            ? (l?.stateOn ?? 'On')
                            : (l?.stateOff ?? 'Off'),
                        chevron: false,
                        onTap: _toggleMap,
                      ),
                    ),
                  ],
                  // A fetch in flight is not a failure. This card used to
                  // appear the instant a format was selected and sit there for
                  // the whole fetch, because `_mapTried` is set before the
                  // first await.
                  if (_hasRoute && _mapBusy) ...[
                    const SizedBox(height: S.x3),
                    StatusCard(
                      l?.activityShareFetchingMapTitle ?? 'Fetching the map',
                      l?.activityShareFetchingMapBody ??
                          'The card draws as soon as every tile is here.',
                      icon: LucideIcons.map,
                    ),
                  ]
                  // Only when a map was expected AND is missing. A lift never
                  // had one to lose, and telling its owner the tiles failed
                  // would be explaining an absence that is not one — and
                  // neither is a basemap the user has switched off.
                  else if (_hasRoute &&
                      _mapConsent &&
                      _mapTried_ &&
                      _mosaic == null) ...[
                    const SizedBox(height: S.x3),
                    StatusCard(
                      l?.activityShareNoMapTitle ?? 'No map for this card',
                      l?.activityShareNoMapBody ??
                          'The map tiles could not be fetched, so the route is '
                              'drawn on its own. Everything else on the card is '
                              'unchanged.',
                      icon: LucideIcons.mapPinOff,
                    ),
                  ],
                  const SizedBox(height: S.x6),
                  // One button, and it is the system share sheet — which is
                  // where "story", "message" and "save" actually live. The
                  // four destination tiles that used to sit here were four
                  // integrations this app does not have.
                  BigButton(
                    l?.activityShareTitle ?? 'Share',
                    icon: LucideIcons.share2,
                    color: r.activity.color,
                    onTap: _share,
                  ),
                  if (r.private) ...[
                    const SizedBox(height: S.x4),
                    StatusCard(
                      l?.activityShareStatusPrivateTitle ??
                          'This session is private',
                      l?.activityShareStatusPrivateBody ??
                          'Hidden from summaries and exports.',
                      icon: LucideIcons.lock,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
/// that list answers about the numbers, and it must stay in step with `_art`.
/// The session's average pace in the reader's unit, or null when there is no
/// pace worth printing — the stat is then not offered at all rather than
/// offered with a placeholder in it.
String? _paceOf(ActivityResult r, UnitsController? u) {
  final secPerKm = r.paceSecPerKm;
  if (secPerKm == null) return null;
  final perUnit = u == null ? 1.0 : u.distanceUnitMeters / 1000;
  return UnitsController.formatPace(secPerKm * perUnit);
}

/// The stats a card may print, in offer order — the public name for
/// [_available], so the poster and the small card cannot drift apart about
/// what a session measured.
List<(String, String)> shareStats(ActivityResult r, [UnitsController? u]) =>
    _available(r, u);

/// The one big number, its unit, and the line under it. Public for the same
/// reason as [shareStats]: two styles describing one session must agree.
(String, String, String) shareHero(ActivityResult r, UnitsController? u) =>
    _heroOf(r, u);

/// The stats this session can honestly put on a card, in offer order.
///
/// [u] is the reader's unit system, null in a golden (and at the one call site
/// that only reads the stat NAMES, which no unit system changes) — metric is
/// what the store holds, so that is what a card without one shows.
List<(String, String)> _available(ActivityResult r, [UnitsController? u]) => [
  ('Time', hms(r.duration)),
  if (r.distanceKm != null)
    (
      'Distance',
      u == null
          ? '${r.distanceKm!.toStringAsFixed(2)} km'
          : u.distance(r.distanceKm! * 1000)!,
    ),
  if (_paceOf(r, u) != null)
    ('Pace', '${_paceOf(r, u)} /${u?.distanceUnit ?? 'km'}'),
  // Bare, like Sets and Laps: the label already says what they are, and
  // 'STEPS 8,412 steps' spends a cell saying it twice.
  if (r.stepsCounted != null) ('Steps', grouped(r.stepsCounted!)),
  if (r.avgHr != null) ('Heart rate', '${r.avgHr} bpm'),
  // With its unit. A bare "612" on a card is a number nobody can read back.
  if (r.calories != null) ('Calories', '${grouped(r.calories!)} kcal'),
  if (r.gainM != null) ('Elevation', '+${r.gainM!.round()} m'),
  if (r.strength.volumeKg != null)
    (
      'Volume',
      '${grouped(u == null ? r.strength.volumeKg! : u.weightValue(r.strength.volumeKg!))} '
          '${u?.weightUnit ?? 'kg'}',
    ),
  if (!r.strength.isEmpty) ('Sets', '${r.strength.setCount}'),
  if (r.lapCount != null) ('Laps', '${r.lapCount}'),
];


(String, String, String) _heroOf(ActivityResult r, UnitsController? u) {
  final fallback = (hms(r.duration), '', r.activity.name);
  final km = r.distanceKm;
  return switch (r.arch) {
    Arch.route || Arch.journey =>
      km == null
          ? fallback
          : (
              (u == null ? km : u.distanceValue(km * 1000))
                  .toStringAsFixed(2),
              u?.distanceUnit ?? 'km',
              r.gainM == null
                  ? r.activity.name
                  : '+${r.gainM!.round()} m elevation',
            ),
    Arch.strength =>
      r.strength.volumeKg == null
          ? fallback
          : (
              grouped(u == null
                  ? r.strength.volumeKg!
                  : u.weightValue(r.strength.volumeKg!)),
              u?.weightUnit ?? 'kg',
              // The same caption the summary picks, off the same fact.
              // `volumeKg` is Σ over the sets that HAVE a load, so calling it
              // a total on a session with bodyweight sets in it asserts a
              // total that leaves some of them out — and the screen this card
              // was made from says exactly that.
              r.strength.hasUnloadedSets
                  ? 'Volume of the loaded sets'
                  : 'Total volume',
            ),
    Arch.laps =>
      r.swimMetres == null
          ? fallback
          : (grouped(r.swimMetres!), 'm', '${r.lapCount} laps'),
    Arch.interval || Arch.flow || Arch.match || Arch.basic => fallback,
  };
}
