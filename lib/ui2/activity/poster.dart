// The poster — the share card for a session that actually went somewhere.
//
// The other styles draw the route as a line in a box, which is a shape. This
// one draws it on a real basemap, so the shape becomes a place: the streets
// you ran, at the scale you ran them. That is the whole difference, and it is
// only offered when the session has real coordinates behind it.
//
// The composition is a full-bleed photo with everything else in a left column
// over it: wordmark, activity, the one big number, the stats as a vertical
// list, the map, the stamp. A column reads top-to-bottom in one pass; the
// horizontal stat strip this replaced made three numbers compete for the same
// glance and gave the map the whole bottom of the card for a shape you can
// read in a third of it.
//
// Three rules this card is built around.
//
//   1. NOTHING ON IT IS INVENTED. Every posted running card in the world shows
//      cadence, elevation and weather; this stack measures none of the three
//      for a gen4 band from stored data, so none of the three is here. The
//      rows are the same `shareStats` list the other styles offer — the ones
//      the session genuinely has.
//   2. The photo is the USER'S. It is not fetched, not generated, not a stock
//      backdrop chosen by activity type. If they do not add one, the card is
//      the accent gradient and says nothing about where they were.
//   3. The map is credited. `kOsmAttribution` is drawn ON the map, and only
//      when there are tiles under it — see the licence note in tiles.dart.
//
// Like `ShareCard`, this is a PICTURE at a fixed size and does not inherit the
// reader's text scale: it is exported at one resolution and sent to someone
// else's phone, and a 2× card would export clipped for every recipient.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/display_text.dart';
import '../../l10n/date_text.dart';
import '../../state/clock_format.dart' show formatClockOf;
import '../../state/units_controller.dart';
import '../screens/home_screen.dart' show unitsOf;
import '../theme.dart';
import 'share.dart' show shareHero, shareStats, localizedExportCaption;
import 'summary.dart';
import 'tiles.dart';

/// Where the card is going, which is the only thing that decides its shape.
///
/// Not a style and not a filter — two aspect ratios, because Instagram crops
/// anything that is not one of them. A 3:4 card posted to a story gets pillar
/// -boxed; the same card posted to the feed gets its top and bottom taken.
/// Exporting at the destination's own ratio is the difference between a card
/// somebody posts and a card somebody screenshots and crops themselves.
enum PosterFormat {
  /// 1:1. The feed. Instagram's square is 1080×1080.
  post('Post', 1),

  /// 9:16 PORTRAIT — 1080×1920. Not 16:9, which is the same numbers holding
  /// a phone the wrong way round.
  story('Story', 16 / 9);

  final String label;

  /// Height ÷ width.
  final double ratio;

  const PosterFormat(this.label, this.ratio);

  double get height => kPosterW * ratio;
  Size get size => Size(kPosterW, height);
}

/// The format's user-facing name, for the format switcher — `label` itself
/// stays a plain English enum field so it can serve as the fallback here.
String posterFormatLabel(BuildContext c, PosterFormat f) {
  final l = AppLocalizations.of(c);
  return switch (f) {
    PosterFormat.post => l?.activityPosterFormatPost ?? f.label,
    PosterFormat.story => l?.activityPosterFormatStory ?? f.label,
  };
}

/// Every card is authored at this width and exported at 3×, so a post lands
/// at 900×900 and a story at 900×1600.
const kPosterW = 300.0;

/// The left column owns a little under two thirds of the card. The rest is
/// photo, and the scrim that makes the column legible over it fades out before
/// it gets there.
///
/// It was half while the stats were a single vertical list. They are two
/// across the bottom now, so the column has to be wide enough for two values
/// — and the right of the card has to stay clear for the corner route, which
/// is the other thing that lives down there.
const _colFrac = .60;
const kPosterColW = kPosterW * _colFrac;

const _padL = S.x5;
const _padR = S.x3;

/// The basemap's frame, in card units — the WHOLE card, per format.
///
/// The map is not a component on this card. It is the ground the card stands
/// on, full bleed. So the tile fetch has to ask for the FORMAT'S aspect: a
/// square mosaic cover-fitted into a 9:16 story is a map with its left and
/// right cropped off, and the route cropped with it.
const kPosterMapW = kPosterW;
double kPosterMapH(PosterFormat f) => f.height;

/// The hero's slot. Fixed so the column's arithmetic is fixed: the number
/// inside scales down to fit rather than pushing the map off the card.
///
/// Two of them, because the square is a hundred points shorter than the story
/// and the same column has to hold the same words in both. The number inside
/// scales to whichever it gets.
const _heroH = 44.0;
const _heroHCompact = 34.0;

/// Below this height a card is SHORT and the column tightens: a smaller hero
/// slot, a smaller stat value, less air between the rows. Not a different
/// design — the same one, at the size the destination allows.
const _compactBelow = 360.0;

/// The stats sit two to a line, along the bottom.
///
/// There is no ceiling any more. There used to be one — four rows, because
/// four was what the sheet pre-selected — and it silently dropped the fifth,
/// which for a hike meant printing time, distance, pace and heart rate and
/// binning the climb and the calories the session had actually measured. A
/// card prints everything the session has; two columns is what makes the six
/// a hike can offer fit at a size somebody can read.
const _statCols = 2;

class PosterCard extends StatelessWidget {
  final ActivityResult r;

  /// The user's own picture, or null for the gradient.
  final ImageProvider? photo;

  /// The basemap, already fetched and projected. Null while it is loading, or
  /// forever if there was no network — the card then draws the route on the
  /// card's own surface instead of on streets. A plainer picture, never a
  /// half-loaded one.
  final RouteMosaic? mosaic;

  /// Where this card is going. Decides its shape and nothing else — every
  /// format prints the same hero and the same stats.
  final PosterFormat format;

  const PosterCard(this.r,
      {super.key,
      this.photo,
      this.mosaic,
      this.format = PosterFormat.post});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final u = unitsOf(c);
    final accent = r.activity.color;
    // Everything the session can honestly print. No picker, no subset: the
    // one question a share sheet asked that nobody has a reason to answer
    // differently was which of their own measurements to leave off.
    final stats = posterStats(r, u);

    return MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.noScaling),
      child: Container(
        width: kPosterW,
        height: format.height,
        decoration: BoxDecoration(
          borderRadius: R.rXl,
          color: C.n900,
          boxShadow: p.el(3),
        ),
        child: ClipRRect(
          borderRadius: R.rXl,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (photo != null)
                Image(image: photo!, fit: BoxFit.cover)
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(C.n900, accent, .18)!,
                        Color.lerp(C.n900, accent, .52)!,
                      ],
                    ),
                  ),
                ),
              // THE MAP, full bleed, directly on the picture and UNDER the scrim.
              //
              // Not a component with a border and a corner radius — the
              // ground the card stands on. It is masked to a soft corridor
              // along the route, so what survives is the streets you actually
              // ran through and the block either side of them, dissolving to
              // nothing after that. Over a photo it additionally fades
              // upward, so it reads as part of the picture rather than as a
              // panel someone dropped on top of it.
              CustomPaint(
                painter: PosterMap(
                  mosaic: mosaic,
                  fallback: r.route,
                  pace: r.routePace,
                  line: accent,
                  casing: C.n900,
                  start: C.routeFast,
                  end: C.routeSlow,
                  overPhoto: photo != null,
                ),
              ),
              // The scrim exists for ONE reason: so the type stays readable
              // whatever picture is behind it. It is not a panel, not a
              // colour wash, not a design element — it is the shadow that
              // buys legibility, and every point of opacity past what does
              // that is opacity spent hiding the photograph the user chose.
              //
              // So it is a real gradient rather than a held slab. It used to
              // sit near-opaque across the whole left column and then drop,
              // which over a light basemap read as a blue-black block with
              // the card's picture starting somewhere off to the right. Now
              // it starts lower, falls away immediately, and is gone by the
              // two-thirds mark — a shadow under the words, nothing more.
              //
              // The floor is set by the worst case, which is not the map —
              // `_themeFilter` already pulls the raster onto this card's own
              // surface, so the basemap arrives dark. It is an unknown
              // PHOTOGRAPH: a bright sky behind the hero is the one thing
              // neither the tint nor the vignette can do anything about.
              // Which is why the two ramps are within a few points of each
              // other rather than the no-photo one being far heavier.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: const [0, .30, .68, 1],
                    colors: [
                      C.n900.withValues(alpha: photo == null ? .78 : .74),
                      C.n900.withValues(alpha: photo == null ? .56 : .50),
                      C.n900.withValues(alpha: .06),
                      C.n900.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
              // A slight vignette, so the card has edges of its own whatever
              // the photo does at the top and bottom of the frame. Light —
              // on a card with no photo this is sitting on the map, which is
              // the thing the card is for.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, .45, 1],
                    colors: [
                      C.n900.withValues(alpha: .24),
                      C.n900.withValues(alpha: 0),
                      C.n900.withValues(alpha: .32),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: kPosterColW,
                child: _column(c, accent, stats, posterHero(r, u)),
              ),
              // The credit. On the card because the map is on the card, and
              // absent when no tiles are DRAWN — crediting OpenStreetMap for
              // a map that is not there would be its own small lie. A photo
              // card is exactly that case: `PosterMap` takes its corner form
              // and never touches the mosaic, so the tiles are fetched and
              // then not used.
              if (_tilesDrawn)
                Positioned(
                  right: S.x2,
                  bottom: S.x1,
                  child: Text(kOsmAttribution,
                      style: F.over.copyWith(
                          color: C.white.withValues(alpha: .55),
                          letterSpacing: 0)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _compact => format.height < _compactBelow;

  /// Whether any tile pixel actually lands on the card — which is the credit's
  /// condition, not whether a mosaic was fetched. Mirrors the `overPhoto`
  /// branch in [PosterMap.paint].
  bool get _tilesDrawn => mosaic != null && photo == null;

  Widget _column(
    BuildContext c,
    Color accent,
    List<(String, String)> stats,
    (String, String, String) hero,
  ) =>
      Padding(
        padding: EdgeInsets.fromLTRB(
            _padL, _compact ? S.x3 : S.x4, _padR, _compact ? S.x3 : S.x4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _wordmark(accent),
        SizedBox(height: _compact ? S.x2 : S.x4),
        _activity(c, accent),
        const SizedBox(height: S.x2),
        _hero((
          hero.$1,
          uiText(c, hero.$2),
          localizedExportCaption(c, r, hero.$3),
        )),
        // The slack lives here, so the stats and the stamp stay pinned to
        // the bottom whether the session printed six or none. The map is
        // not in this column at all — it is behind everything, or in the
        // opposite corner.
        const Spacer(),
        _statGrid(c, accent, stats),
        if (stats.isNotEmpty) SizedBox(height: _compact ? S.x2 : S.x3),
        _stamp(c, accent),
      ],
    ),
  );

  /// The wordmark, and only the wordmark.
  ///
  /// The rounded tile with the activity glyph in it is gone. On a card whose
  /// whole job is one photograph and one route it was a third mark competing
  /// with both, and the app's name does not need a logo beside it to be read
  /// as the app's name.
  Widget _wordmark(Color accent) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        // scaleDown, like everything else in this column: the name of the app
        // is the one string on the card that may never be truncated, and a
        // face wider than the one this was measured in is not a reason to
        // print 'OpenStr…'.
        child: Text('OpenStrap',
            style: F.over.copyWith(
                color: C.white.withValues(alpha: .72),
                fontWeight: FontWeight.w700),
            maxLines: 1),
      );

  /// The activity, set large. It is the card's subject — what this picture is
  /// OF — and it spent a long time as an 11pt caption next to a 48pt number.
  Widget _activity(BuildContext c, Color accent) => Row(
    children: [
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            r.activity.displayName(c).toUpperCase(),
            style: F.n17.copyWith(color: accent, letterSpacing: .6),
            maxLines: 1,
          ),
        ),
      ),
        if (r.private) ...[
          const SizedBox(width: S.x2),
          Icon(LucideIcons.lock, size: 13, color: accent),
        ],
      ]);

  /// The one big number. scaleDown, not ellipsis — this is a fixed-size
  /// PICTURE, so a long value has nowhere to wrap to, and a truncated distance
  /// ('12.4…') on a card somebody else receives is worse than the same
  /// distance a few points smaller.
  Widget _hero((String, String, String) hero) => SizedBox(
        height: _compact ? _heroHCompact : _heroH,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(hero.$1,
                  style: F.n48.copyWith(color: C.white), maxLines: 1),
              if (hero.$2.isNotEmpty) ...[
                const SizedBox(width: S.x2),
                Text(hero.$2,
                    style: F.cap
                        .copyWith(color: C.white.withValues(alpha: .70))),
              ],
            ],
          ),
        ),
      );

  /// Every stat the session has, two to a line.
  ///
  /// Not [PosterStatRow]. That row is the app's stat grammar and it is right
  /// everywhere it is used — a ringed icon, a name, a value — but it is a
  /// WIDE row, and a cell here is about seventy points across. The ring is the
  /// part that does not survive the width, so the cell drops it and keeps what
  /// carries the meaning: the name above the number, same caps, same muted
  /// label, same tabular value. Nothing else on the card changes shape.
  Widget _statGrid(
    BuildContext c,
    Color accent,
    List<(String, String)> stats,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < stats.length; i += _statCols) ...[
        if (i > 0) SizedBox(height: _compact ? S.x2 : S.x3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < _statCols; j++) ...[
              // A gutter, because the labels scale to fill their cell and
              // two that both do run together: 'HEART RATECALORIES'.
              if (j > 0) const SizedBox(width: S.x3),
              Expanded(
                child: i + j < stats.length
                    ? _statCell(c, stats[i + j], accent)
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ],
    ],
  );

  Widget _statCell(BuildContext c, (String, String) s, Color accent) {
    final (value, unit) = splitStatUnit(s.$2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // scaleDown, not ellipsis. A cell is about seventy points wide and
        // 'HEART RATE' does not fit at tracking — it shipped as 'HEART RA…',
        // which is a label that has stopped being a word. Every other string
        // on this card already shrinks rather than truncates; this one was
        // the exception because it used to sit in a full-width row.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            uiText(c, s.$1).toUpperCase(),
              style: F.over
                  .copyWith(color: accent, letterSpacing: 1.1, height: 1.2),
              maxLines: 1),
        ),
        const SizedBox(height: S.x1),
        // scaleDown for the same reason the hero is: this is a fixed-size
        // picture, so '1:04:12' has nowhere to wrap to and must not be cut.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: (_compact ? F.n17 : F.n24).copyWith(color: C.white),
                  maxLines: 1),
              if (unit != null && unit.isNotEmpty) ...[
                const SizedBox(width: 2),
                Text(
                  uiText(c, unit),
                    style: F.cap.copyWith(
                        color: C.white.withValues(alpha: .60),
                        letterSpacing: 0)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _stamp(BuildContext c, Color accent) => Row(
    children: [
      Icon(LucideIcons.calendar, size: 11, color: accent),
      const SizedBox(width: S.x2),
      // The longest string on the card relative to its slot — it shrinks to
      // fit rather than pushing itself off the column.
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            '${displayDate(c, r.start)} • ${formatClockOf(r.start)}',
            style: F.over.copyWith(color: C.white, letterSpacing: 0),
            maxLines: 1,
          ),
        ),
      ),
    ],
  );
}

/// One measured thing: a ringed icon, its name, and the number.
///
/// Public and poster-free on purpose — the workout screens print the same
/// three-part row, and two widgets drawing one grammar is how the last design
/// system ended up with four stat rows that disagreed about their own spacing.
///
/// [ink] is the ink to set the value in; null takes the page's own, so the row
/// works on a card as well as on a photo. The label and the unit are derived
/// from it rather than passed, so a caller cannot half-theme the row.
class PosterStatRow extends StatelessWidget {
  final IconData icon;

  /// Printed in caps. Pass it in sentence case.
  final String label;

  final String value;

  /// Trails the value, smaller and muted. Null for a bare count.
  final String? unit;

  final Color accent;

  /// The value's ink. Null resolves to the page's — see the class note.
  final Color? ink;

  const PosterStatRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    this.unit,
    this.ink,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final on = ink ?? p.ink;
    final muted = ink == null ? p.ink3 : ink!.withValues(alpha: .62);
    // The mark grows with the type, up to a point. On the poster this is
    // always 1.0 — that card pins `TextScaler.noScaling` — but the workout
    // screens use this row for real and inherit the reader's size, where a
    // fixed 24 pt ring beside 34 pt type reads as a bullet. Clamped at 2×
    // because past that the mark starts costing the value its width.
    final k = MediaQuery.textScalerOf(c).scale(1).clamp(1.0, 2.0);
    return Row(children: [
      Container(
        width: S.x6 * k,
        height: S.x6 * k,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: accent.withValues(alpha: .55)),
        ),
        child: Icon(icon, size: 12 * k, color: accent),
      ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                uiText(c, label).toUpperCase(),
                style: F.over.copyWith(color: muted, letterSpacing: 1),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // scaleDown rather than ellipsis, for the same reason the hero
              // uses it: '2,310 kcal' and '52 bpm' are both real and are not the
              // same width, and a truncated number is not a number.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(value, style: F.n17.copyWith(color: on), maxLines: 1),
                    if (unit != null) ...[
                      const SizedBox(width: S.x1),
                      Text(
                        uiText(c, unit!),
                        style: F.cap.copyWith(color: muted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Split a formatted stat into its number and its unit.
///
/// `shareStats` hands back one string because that is what a chip prints. A
/// row sets the two halves differently, so it has to take them apart — and it
/// only does so when the tail actually LOOKS like a unit. '1h 02m' is a
/// duration whose last word is not a unit of anything, and splitting it would
/// print '1h' in the value slot.
(String, String?) splitStatUnit(String s) {
  final m = RegExp(r'^(.+?)\s+([a-zA-Z/][a-zA-Z/]*)$').firstMatch(s.trim());
  return m == null ? (s, null) : (m.group(1)!, m.group(2)!);
}

/// The glyph for a stat name, from the same offer list `shareStats` returns.
/// Anything unrecognised gets the neutral mark rather than a guess.
IconData posterStatIcon(String name) => switch (name) {
      'Time' => LucideIcons.timer,
      'Distance' => LucideIcons.ruler,
      'Pace' => LucideIcons.gauge,
      'Steps' => LucideIcons.footprints,
      'Heart rate' => LucideIcons.heart,
      'Calories' => LucideIcons.flame,
      'Elevation' => LucideIcons.mountain,
      'Volume' => LucideIcons.dumbbell,
      'Sets' => LucideIcons.layers,
      'Laps' => LucideIcons.repeat,
      _ => LucideIcons.activity,
    };

/// Slow → fast, as a four-stop ramp. [t] is the 0…1 speed a fix was carrying,
/// 1 being the fastest of the session — so orange is where you were moving
/// and blue is where you were not, as on the session screen's route.
Color paceColor(double t) {
  // The route's own ramp, not the UI accents. Slow to fast: blue, sky,
  // amber, orange. See the note on [C.routeFast] for why these are a separate
  // set — a line over a photograph is not a label on a card.
  const ramp = [C.routeSlow, C.routeHard, C.routeMid, C.routeFast];
  final x = t.clamp(0.0, 1.0) * (ramp.length - 1);
  final i = x.floor().clamp(0, ramp.length - 2);
  return Color.lerp(ramp[i], ramp[i + 1], x - i)!;
}

/// The route, on the basemap when there is one and on bare card when there is
/// not.
///
/// Two passes for the line — a dark casing under a coloured core — because a
/// single stroke over an arbitrary photo or an arbitrary map tile is legible
/// against some of them and invisible against the rest.
/// The route layer. It has two forms, and which one it takes is decided by a
/// single fact: whether the user gave the card a photograph.
///
/// **No photo — the map IS the card.** The whole basemap, full bleed, edge to
/// edge, showing the journey start to stop. There is nothing else to look at,
/// so nothing is masked away.
///
/// **A photo — the route alone, bottom right, dissolving.** The photograph is
/// the picture; a basemap behind it would be two pictures fighting, and a
/// framed mini-map dropped into the corner would be a sticker. So the tiles
/// are not drawn at all: what survives is the SHAPE of where they went, in the
/// corner, fading up and to the left into the photograph. No panel, no border,
/// no corner radius, no backdrop — nothing that gives it an edge.
class PosterMap extends CustomPainter {
  final RouteMosaic? mosaic;

  /// The 0…1 normalised route. The only geometry the corner form uses, and
  /// the fallback for the full form when there are no tiles.
  final List<Offset> fallback;

  /// Per-point 0…1 speed for the ramp. Null when the fixes carried no speed.
  final List<double>? pace;

  final Color line, casing, start, end;

  /// Whether a photo is behind — which is to say, which form this takes.
  final bool overPhoto;

  PosterMap({
    required this.mosaic,
    required this.fallback,
    required this.pace,
    required this.line,
    required this.casing,
    required this.start,
    required this.end,
    required this.overPhoto,
  });

  /// The corner form's box, as fractions of the card. Nothing draws this rect
  /// — it is only where the shape is fitted before it is faded out.
  static const _cornerW = .42;
  static const _cornerH = .30;
  static const _cornerPad = S.x3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    if (overPhoto) return _paintCorner(canvas, size);
    final pts = projectRoute(mosaic, fallback, size);
    if (pts.length < 2) return;

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final o in pts.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    final rect = Offset.zero & size;
    final m = mosaic;

    if (m != null) {
      // The tiles, cover-fitted, WHOLE — see `projectRoute`, which fits the
      // route through the identical transform so the line stays on its own
      // streets.
      //
      // This used to be masked to a blurred corridor along the route, so the
      // map survived only within a block of the path. That made sense when a
      // photo could be behind it. Nothing is behind it now — a card with no
      // photo has the map as its background and nothing else, and a corridor
      // is a keyhole over an empty room. The scrim and the vignette the card
      // draws on top are what keep the type legible.
      final k = math.max(size.width / m.width, size.height / m.height);
      canvas.save();
      canvas.clipRect(rect);
      canvas.translate(
          (size.width - m.width * k) / 2, (size.height - m.height * k) / 2);
      canvas.scale(k, k);
      // `filterQuality` defaults to none, i.e. nearest-neighbour — and this
      // draws a 900 px mosaic into a 300 pt card, so the preview moiréd while
      // the export (3x, k·3 = 1) was pixel-exact. The card the user approves
      // has to be the card that ships. The mosaic builder already composites
      // its tiles at medium.
      canvas.drawImage(
        m.image,
        Offset.zero,
        Paint()
          ..isAntiAlias = true
          ..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }

    // The line itself, at full strength on top of the dissolve — the one part
    // of this layer that is a measurement rather than a texture.
    _drawRoute(canvas, path, pts, width: 3.6, glow: 7);
    drawPin(canvas, pts.first, start);
    drawPin(canvas, pts.last, end);
  }

  /// The route, in three passes: a soft glow, a dark casing, then the coloured
  /// core.
  ///
  /// The glow is what stops the line reading as a sticker on the picture. It
  /// is the route's own colour, blurred and at low alpha, so an orange stretch
  /// bleeds orange and a blue one bleeds blue — a single white halo would put the
  /// same ring around both and flatten the ramp it exists to support. The
  /// casing stays because a glow is not a separator: over a pale patch of
  /// photograph the core still needs a dark edge to sit against.
  void _drawRoute(
    Canvas canvas,
    Path path,
    List<Offset> pts, {
    required double width,
    required double glow,
  }) {
    final ramp = pace;
    final lit = ramp != null && ramp.length == pts.length;
    Color at(int i) =>
        lit ? paceColor((ramp[i] + ramp[i - 1]) / 2) : (line);

    final halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = glow
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, glow * .55)
      ..isAntiAlias = true;
    if (lit) {
      for (var i = 1; i < pts.length; i++) {
        canvas.drawLine(
            pts[i - 1], pts[i], halo..color = at(i).withValues(alpha: .20));
      }
    } else {
      canvas.drawPath(path, halo..color = line.withValues(alpha: .20));
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 1.9
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = casing.withValues(alpha: .40)
        ..isAntiAlias = true,
    );

    final core = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    if (lit) {
      for (var i = 1; i < pts.length; i++) {
        canvas.drawLine(pts[i - 1], pts[i], core..color = at(i));
      }
    } else {
      canvas.drawPath(path, core..color = line);
    }
  }

  /// The route alone, fitted bottom-right, dissolving up and to the left.
  ///
  /// Drawn into its own layer and then multiplied by a gradient in `dstIn`, so
  /// the fade takes the casing, the line and the pins together. Fading them
  /// separately is how a "faded" mark ends up with its outline still crisp.
  void _paintCorner(Canvas canvas, Size size) {
    final box = Rect.fromLTWH(
      size.width - size.width * _cornerW - _cornerPad,
      size.height - size.height * _cornerH - _cornerPad,
      size.width * _cornerW,
      size.height * _cornerH,
    );
    // Square, so the shape keeps its proportions — a route squeezed to fit a
    // wide box is a map of a place that is not there.
    final s = math.min(box.width, box.height);
    final ox = box.left + (box.width - s) / 2;
    final oy = box.top + (box.height - s) / 2;
    final pts = [
      for (final o in fallback) Offset(ox + o.dx * s, oy + o.dy * s),
    ];
    if (pts.length < 2) return;
    for (final o in pts) {
      if (o.dx.isNaN || o.dy.isNaN) return;
    }
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final o in pts.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }

    // Room for the pins, which stand above the fix they mark.
    final bleed = box.inflate(S.x4);
    canvas.saveLayer(bleed, Paint());
    // The same three passes as the full form, scaled to the corner — one
    // route grammar, so the glow and the ramp cannot drift apart between the
    // photo card and the map card.
    _drawRoute(canvas, path, pts, width: 2.6, glow: 5);
    // Start and stop stay. They are the two facts that make the shape a
    // journey rather than a squiggle, and the ask was start to stop.
    drawPin(canvas, pts.first, start);
    drawPin(canvas, pts.last, end);

    // The dissolve. Full strength at the bottom-right corner it sits in, gone
    // by the time it reaches the middle of the card — so it belongs to the
    // photograph rather than sitting on it.
    canvas.drawRect(
      bleed,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          bleed.bottomRight,
          bleed.topLeft,
          [C.white, C.white, C.white.withValues(alpha: 0)],
          const [0, .38, 1],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PosterMap o) =>
      o.mosaic != mosaic ||
      o.fallback != fallback ||
      o.line != line ||
      o.overPhoto != overPhoto;
}

/// The route in paint space, through the same transform the tiles get.
///
/// With a mosaic that is a cover-fit of the fetched frame — one uniform scale,
/// centred, cropping the overhang, because a basemap scaled unevenly is a map
/// of somewhere that does not exist. Without one it is the normalised shape
/// fitted into the box, which is all the card can honestly draw.
///
/// Returns an empty list rather than a NaN: a NaN reaches a `Path` and takes
/// the whole card down with it.
List<Offset> projectRoute(
    RouteMosaic? mosaic, List<Offset> fallback, Size size) {
  List<Offset> pts;
  final m = mosaic;
  if (m != null) {
    final k = math.max(size.width / m.width, size.height / m.height);
    final ox = (size.width - m.width * k) / 2;
    final oy = (size.height - m.height * k) / 2;
    pts = [for (final o in m.path) Offset(ox + o.dx * k, oy + o.dy * k)];
  } else {
    // No basemap: the shape, inset, with room at the top for the pins — they
    // stand ABOVE the point they mark.
    const pad = .14;
    final s = size.shortestSide * (1 - pad * 2);
    final ox = (size.width - s) / 2, oy = (size.height - s) / 2;
    pts = [for (final o in fallback) Offset(ox + o.dx * s, oy + o.dy * s)];
  }
  if (pts.length < 2) return const [];
  for (final o in pts) {
    if (o.dx.isNaN || o.dy.isNaN) return const [];
  }
  return pts;
}

/// A dot ON the fix, white-ringed.
///
/// It used to be a teardrop marker standing above the point — the shape every
/// navigation app uses, which is exactly the association this card is trying
/// not to make. A teardrop also points at a place the route does not go: the
/// head floats eleven points north of the last fix, so on a small corner route
/// the two pins read as being somewhere the line never went.
///
/// A ring on the point says the same thing (here, and here) without borrowing
/// a map app's furniture, and it sits on the coordinate it marks.
void drawPin(Canvas canvas, Offset o, Color col) {
  const rad = 3.4;
  canvas.drawCircle(
    o,
    rad,
    Paint()
      ..color = col.withValues(alpha: .35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
      ..isAntiAlias = true,
  );
  canvas.drawCircle(o, rad, Paint()..color = col..isAntiAlias = true);
  canvas.drawCircle(
    o,
    rad,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = C.white
      ..isAntiAlias = true,
  );
}

/// `May 20, 2026 • 7:15 AM` (or `07:15`), in the reader's own clock terms.
String posterDate(DateTime t) {
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${m[t.month - 1]} ${t.day}, ${t.year} • ${formatClockOf(t)}';
}

/// Hero, unit, caption — distance when the session has one, time when it does
/// not. Shared with `ShareCard`'s own hero so the two styles cannot disagree
/// about the same session.
(String, String, String) posterHero(ActivityResult r, UnitsController? u) =>
    shareHero(r, u);

/// The stats the grid prints, in offer order, MINUS the one the hero is.
///
/// The hero is not a decoration above the stats — it is one of them, set
/// large. A run whose hero says `8.02 km` and whose grid also says
/// `DISTANCE 8.02 km` has printed one measurement twice and spent a cell
/// doing it. This never showed while the card was capped at four hand-picked
/// stats, because nobody picked the one already in the hero; printing
/// everything is what surfaced it.
///
/// If the session did not measure a thing, it is not on the list at all.
List<(String, String)> posterStats(ActivityResult r, UnitsController? u) {
  final hero = _heroStat(r);
  return [
    for (final s in shareStats(r, u))
      if (s.$1 != hero) s,
  ];
}

/// Which stat the hero is already showing.
///
/// Mirrors `shareHero`'s own fallbacks: each archetype has a headline number,
/// and when the session lacks it the hero falls back to the clock — at which
/// point the duplicate is `Time` instead.
String _heroStat(ActivityResult r) => switch (r.arch) {
      Arch.route || Arch.journey =>
        r.distanceKm == null ? 'Time' : 'Distance',
      Arch.strength => r.strength.volumeKg == null ? 'Time' : 'Volume',
      // The hero is the swim in metres and the row would be the same swim in
      // kilometres. One measurement, two units, still one measurement.
      Arch.laps => r.swimMetres == null ? 'Time' : 'Distance',
      Arch.interval || Arch.flow || Arch.match || Arch.basic => 'Time',
    };
