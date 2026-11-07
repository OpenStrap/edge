// CHART ANNOTATIONS — journal items and provenance marks drawn on a chart.
//
// One pure layout function turns "things that happened" plus "how many pixels
// the chart has" plus "what the finger is on" into placed icons, "+n" clusters,
// shaded ranges and ONE static label. The widgets only draw what it returns.
//
// THE RULES (each is pinned by test/chart_annotation_*_test.dart):
//  • An item is an ICON and a DASHED vertical line. The line is always on the
//    item's true x; only the icon is ever nudged to keep icons apart.
//  • Icons never overlap. Unlinked points closer than an icon's width collapse
//    to ONE icon — the focused member, else the OLDEST — with "+n" right after
//    it. If the chart is still too crowded the clusters widen; if it is too
//    narrow for even that, ids are reported in `unplaced`, never dropped.
//  • A linked start/end pair is a SHADED AREA in its kind's colour with ONE icon
//    at its start and dashed lines at both ends. Ranges never cluster.
//  • An algorithm-version mark is provenance, not an event: it keeps its own
//    icon (never clustered, with journal items or other marks) but is nudged
//    like any other icon.
//  • The label of the focused item is drawn in ONE fixed place; it never
//    follows the finger. With nothing focused that place says the main sleep's
//    label (when there is one on the chart). With several main sleeps on the
//    chart, the first by x, then oldest, then id.
//  • The main sleep has priority: never in a "+n", the last icon given up.
//  • Absent is absent: nothing outside the plot, nothing non-finite and no
//    range with a nonsense end is ever drawn or invented.
//  • The positions are in the chart's own x domain (epoch seconds, slot index),
//    so a 23-hour DST day is just a shorter domain; nothing here assumes 86400.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/day_label.dart' show dayLabelOf;
import '../l10n/app_localizations.dart';
import 'grammar.dart' show Pressable;
import 'theme.dart';

/// What an annotation is. One icon and one colour per kind.
enum AnnotationKind {
  water,
  assumedWater,
  moment,
  symptom,
  workout,
  nap,

  /// The night's main sleep, onset to wake (design: day timeline, owner-approved
  /// 2026-10-08). The one kind with PRIORITY: never folded into a "+n" cluster,
  /// never the icon given up first, and its label is the lane's default label
  /// while nothing is focused.
  mainSleep,

  /// A nap/workout range created by the marked-moment review.
  // TODO(moments-review): no producer yet — it arrives with the
  // feature/moments-review branch (not merged). Keep the kind so its colour and
  // icon are settled before then.
  review,
  journal,
  algoVersion,
}

/// The glyph for [k]. Unique per kind.
IconData annotationIcon(AnnotationKind k) => switch (k) {
      AnnotationKind.water => LucideIcons.glassWater,
      AnnotationKind.assumedWater => LucideIcons.droplet,
      AnnotationKind.moment => LucideIcons.bookmark,
      AnnotationKind.symptom => LucideIcons.heartPulse,
      AnnotationKind.workout => LucideIcons.dumbbell,
      AnnotationKind.nap => LucideIcons.bedDouble,
      AnnotationKind.mainSleep => LucideIcons.moon,
      AnnotationKind.review => LucideIcons.clipboardCheck,
      AnnotationKind.journal => LucideIcons.notebookPen,
      AnnotationKind.algoVersion => LucideIcons.gitCommitVertical,
    };

/// The word a screen reader says for [k], before the item's own label:
/// "Workout, Evening run". Existing strings where the app already names the
/// thing; two new ones for a moment and a symptom.
String annotationKindName(AppLocalizations? l, AnnotationKind k) =>
    switch (k) {
      AnnotationKind.water ||
      AnnotationKind.assumedWater =>
        l?.nutritionWaterLabel ?? 'Water',
      AnnotationKind.moment => l?.chartAnnotationKindMoment ?? 'Moment',
      AnnotationKind.symptom => l?.chartAnnotationKindSymptom ?? 'Symptom',
      AnnotationKind.workout => l?.dayTimelineWorkout ?? 'Workout',
      AnnotationKind.nap => l?.dayTimelineNap ?? 'Nap',
      AnnotationKind.mainSleep => l?.dayTimelineAsleep ?? 'Asleep',
      AnnotationKind.review => l?.activityReview ?? 'Review',
      AnnotationKind.journal => l?.journalComposeTitle ?? 'Journal',
      AnnotationKind.algoVersion =>
        l?.investigateAlgoVersionLabel ?? 'Algorithm version',
    };

/// The pigment for [k]. Unique per kind; a range's shade is this at low alpha.
Color annotationColor(AnnotationKind k) => switch (k) {
      AnnotationKind.water => C.sky,
      AnnotationKind.assumedWater => C.blueSoft,
      AnnotationKind.moment => C.teal,
      AnnotationKind.symptom => C.red,
      AnnotationKind.workout => C.orange,
      AnnotationKind.nap => C.indigo,
      // Pink, not a blue: the Asleep band this replaces was blue, and a range
      // shade in a blue would read as that band coming back.
      AnnotationKind.mainSleep => C.pink,
      AnnotationKind.review => C.purple,
      AnnotationKind.journal => C.yellow,
      // Neutral on purpose: a version change is provenance, not an event that
      // happened to the person.
      AnnotationKind.algoVersion => C.n400,
    };

/// One thing to mark. [at] is in the chart's own x domain (epoch seconds on an
/// intraday chart, slot index on a daily one) — the layout never assumes a
/// day is 86400 s. A non-null [until] greater than [at] makes it a RANGE (a
/// linked start/end pair); anything else is a point.
@immutable
class ChartAnnotation {
  const ChartAnnotation({
    required this.id,
    required this.kind,
    required this.at,
    required this.label,
    this.until,
  });
  final String id;
  final AnnotationKind kind;
  final double at;
  final double? until;
  final String label;
}

/// Domain-to-pixel scale of one chart plus the footprint of one icon.
@immutable
class AnnotationScale {
  const AnnotationScale({
    required this.domainStart,
    required this.domainEnd,
    required this.width,
    this.iconWidth = 24,
    this.badgeWidth = 22,
  });
  final double domainStart;
  final double domainEnd;

  /// Plot width in logical pixels.
  final double width;
  final double iconWidth;

  /// Extra footprint the "+n" badge takes right after a cluster's icon.
  final double badgeWidth;

  /// Pixel x of domain value [at] (not clamped).
  double xOf(double at) {
    final span = domainEnd - domainStart;
    if (!(span > 0)) return 0;
    return (at - domainStart) * width / span;
  }

  bool get usable =>
      width > 0 && width.isFinite && domainEnd > domainStart && domainStart.isFinite && domainEnd.isFinite;
}

/// Where the one label goes. Static: it never follows the finger.
enum AnnotationLabelSlot { topStart }

/// One icon on the lane.
@immutable
class PlacedAnnotation {
  const PlacedAnnotation({
    required this.id,
    required this.kind,
    required this.label,
    required this.x,
    required this.iconLeft,
    required this.iconWidth,
    required this.badgeWidth,
    required this.memberIds,
    required this.focused,
    required this.isRange,
  });

  /// The annotation this icon shows (the focused one, else the oldest).
  final String id;
  final AnnotationKind kind;
  final String label;

  /// Where the dashed line is: the displayed item's true position.
  final double x;

  /// Left edge of the icon box after collision nudging. The line stays at [x].
  final double iconLeft;
  final double iconWidth;
  final double badgeWidth;

  /// Every annotation this icon stands for, OLDEST FIRST. One for a lone item.
  final List<String> memberIds;
  final bool focused;
  final bool isRange;

  /// The "+n": members not shown. Zero means no badge.
  int get more => memberIds.length - 1;

  /// Right edge of everything this icon takes (icon plus badge).
  double get footprintRight =>
      iconLeft + iconWidth + (more > 0 ? badgeWidth : 0);

  /// The member after [current] in this icon, wrapping; the first member if
  /// [current] is not one of them.
  String next(String? current) {
    final i = current == null ? -1 : memberIds.indexOf(current);
    return memberIds[(i + 1) % memberIds.length];
  }
}

/// The shaded area of a range, clipped to the plot.
@immutable
class ShadedRange {
  const ShadedRange({
    required this.id,
    required this.kind,
    required this.left,
    required this.right,
    required this.focused,
    this.startsInside = true,
    this.endsInside = true,
  });
  final String id;
  final AnnotationKind kind;
  final double left;
  final double right;
  final bool focused;

  /// Whether the range's real start / end are on the plot (not cut off by its
  /// edge). A cut edge gets no dashed line: a line at the edge would claim the
  /// range began or ended there.
  final bool startsInside;
  final bool endsInside;
}

@immutable
class AnnotationLayout {
  const AnnotationLayout({
    required this.items,
    required this.shades,
    required this.unplaced,
    required this.focusedId,
    required this.labelText,
    this.labelSlot = AnnotationLabelSlot.topStart,
  });

  /// Icons, left to right. Their footprints never overlap and stay in bounds.
  final List<PlacedAnnotation> items;

  /// One per range that is visible at all, whether or not it got an icon.
  final List<ShadedRange> shades;

  /// Ids that are in the plot but could not get any icon (the chart is too
  /// narrow). Never silently dropped.
  final List<String> unplaced;

  /// The annotation that is focused, or null.
  final String? focusedId;

  /// The static label's text — the focused annotation's label, else the main
  /// sleep's label when one is on the chart, else null. With several main
  /// sleeps on the chart the default is the first by x, then oldest, then id.
  final String? labelText;
  final AnnotationLabelSlot labelSlot;
}

// ── layout ──────────────────────────────────────────────────────────────────

/// An annotation that is on the plot, with its pixel geometry.
class _Vis {
  _Vis(this.a, this.x, this.right, this.startsInside, this.endsInside);
  final ChartAnnotation a;

  /// Pixel x of the first VISIBLE instant (the icon and the line).
  final double x;

  /// Pixel x of the last visible instant for a range, else null.
  final double? right;
  final bool startsInside;
  final bool endsInside;

  bool get isRange => right != null;

  /// Ranges, version marks and the main sleep keep their own icon: they never
  /// cluster. The main sleep is solo even as a point (a night with no usable
  /// end), where a plain point would fold into a neighbour's "+n".
  bool get solo =>
      isRange ||
      a.kind == AnnotationKind.algoVersion ||
      a.kind == AnnotationKind.mainSleep;
}

int _byTime(ChartAnnotation a, ChartAnnotation b) {
  final c = a.at.compareTo(b.at);
  return c != 0 ? c : a.id.compareTo(b.id);
}

int _byX(_Vis a, _Vis b) {
  final c = a.x.compareTo(b.x);
  return c != 0 ? c : _byTime(a.a, b.a);
}

List<_Vis> _visible(List<ChartAnnotation> items, AnnotationScale s) {
  // A growable list, not `const []`: the caller sorts it in place. An unusable
  // scale (no width, empty or inverted domain) shows nothing.
  if (!s.usable) return <_Vis>[];
  final out = <_Vis>[];
  for (final a in items) {
    if (!a.at.isFinite) continue;
    final u = a.until;
    if (u != null && u.isFinite && u > a.at) {
      if (u < s.domainStart || a.at > s.domainEnd) continue;
      final l = math.max(a.at, s.domainStart), r = math.min(u, s.domainEnd);
      out.add(_Vis(a, s.xOf(l), s.xOf(r), a.at >= s.domainStart,
          u <= s.domainEnd));
    } else {
      if (a.at < s.domainStart || a.at > s.domainEnd) continue;
      out.add(_Vis(a, s.xOf(a.at), null, true, true));
    }
  }
  return out;
}

/// One icon being placed.
class _Icon {
  _Icon(this.members, this.shown, this.fw);
  final List<_Vis> members; // oldest first
  final _Vis shown;
  final double fw; // footprint width: icon (+ badge)
  double left = 0;
}

/// Left-to-right push, right-to-left pull. Returns whether everything fits.
bool _place(List<_Icon> icons, double width, double iconWidth) {
  var prevRight = 0.0;
  for (final i in icons) {
    final desired = i.shown.x - iconWidth / 2;
    double l = desired.clamp(0.0, math.max(0.0, width - i.fw)).toDouble();
    if (l < prevRight) l = prevRight;
    i.left = l;
    prevRight = l + i.fw;
  }
  var limit = width;
  for (var k = icons.length - 1; k >= 0; k--) {
    final i = icons[k];
    if (i.left + i.fw > limit) i.left = limit - i.fw;
    limit = i.left;
  }
  return icons.isEmpty || icons.first.left >= -1e-9;
}

/// THE LAYOUT. Pure. See the file header for the rules.
AnnotationLayout layoutAnnotations({
  required List<ChartAnnotation> annotations,
  required AnnotationScale scale,
  String? focusId,
}) {
  final vis = _visible(annotations, scale)..sort(_byX);
  final byId = {for (final v in vis) v.a.id: v};
  final focusedId = focusId != null && byId.containsKey(focusId) ? focusId : null;
  final solos = [for (final v in vis) if (v.solo) v];
  final points = [for (final v in vis) if (!v.solo) v];

  // Point clusters, widening until everything fits: a cluster carries a "+n"
  // badge, so the first pass (an icon's width) can leave too little room.
  var t = scale.iconWidth;
  late List<_Icon> icons;
  for (;;) {
    final groups = <List<_Vis>>[];
    double anchor = 0;
    for (final p in points) {
      if (groups.isEmpty || p.x - anchor >= t) {
        groups.add([p]);
        anchor = p.x;
      } else {
        groups.last.add(p);
      }
    }
    icons = [
      for (final g in groups) _iconOf(g, focusedId, byId, scale),
      for (final s in solos) _iconOf([s], focusedId, byId, scale),
    ]..sort((a, b) => _byX(a.shown, b.shown));
    if (_place(icons, scale.width, scale.iconWidth)) break;
    if (t > scale.width + scale.iconWidth) break; // all points are one cluster
    t += scale.badgeWidth;
  }

  // Still no room: give up icons from the right. The main sleep goes LAST, of
  // every other icon, the focused one included (a focused item keeps the fixed
  // label slot whether or not its icon survives). Among the rest the focused
  // one goes last. Their ids are reported, and a range keeps its shade.
  final unplaced = <String>[];
  bool holdsFocus(_Icon i) => i.members.any((m) => m.a.id == focusedId);
  bool holdsNight(_Icon i) =>
      i.members.any((m) => m.a.kind == AnnotationKind.mainSleep);
  while (!_place(icons, scale.width, scale.iconWidth)) {
    var drop = icons.lastIndexWhere((i) => !holdsFocus(i) && !holdsNight(i));
    if (drop < 0) drop = icons.lastIndexWhere((i) => !holdsNight(i));
    if (drop < 0) drop = icons.length - 1;
    unplaced.addAll([for (final m in icons[drop].members) m.a.id]);
    icons.removeAt(drop);
  }

  final placed = [
    for (final i in icons)
      PlacedAnnotation(
        id: i.shown.a.id,
        kind: i.shown.a.kind,
        label: i.shown.a.label,
        x: i.shown.x,
        iconLeft: i.left,
        iconWidth: scale.iconWidth,
        badgeWidth: scale.badgeWidth,
        memberIds: [for (final m in i.members) m.a.id],
        focused: i.shown.a.id == focusedId,
        isRange: i.shown.isRange,
      ),
  ];
  return AnnotationLayout(
    items: placed,
    shades: [
      for (final v in vis)
        if (v.isRange)
          ShadedRange(
            id: v.a.id,
            kind: v.a.kind,
            left: v.x,
            right: v.right!,
            focused: v.a.id == focusedId,
            startsInside: v.startsInside,
            endsInside: v.endsInside,
          ),
    ],
    unplaced: unplaced,
    focusedId: focusedId,
    labelText: focusedId != null
        ? byId[focusedId]!.a.label
        // Nothing focused: the night's own label is the default, if the night
        // is on the chart at all. Never invented.
        : [
            for (final v in vis)
              if (v.a.kind == AnnotationKind.mainSleep) v.a.label
          ].firstOrNull,
  );
}

_Icon _iconOf(List<_Vis> g, String? focusedId, Map<String, _Vis> byId,
    AnnotationScale s) {
  final members = [...g]..sort((a, b) => _byTime(a.a, b.a));
  final shown = focusedId != null && members.any((m) => m.a.id == focusedId)
      ? byId[focusedId]!
      : members.first;
  return _Icon(members, shown,
      s.iconWidth + (members.length > 1 ? s.badgeWidth : 0));
}

/// The annotation a scrub at [cursorPx] is ON or NEAREST to, or null (no
/// cursor, nothing to pick, or farther than [reach] px when given).
String? pickAnnotationFocus({
  required List<ChartAnnotation> annotations,
  required AnnotationScale scale,
  required double? cursorPx,
  double? reach,
}) {
  if (cursorPx == null || !cursorPx.isFinite) return null;
  _Vis? best;
  double bestD = 0;
  for (final v in _visible(annotations, scale)) {
    final r = v.right;
    final d = r != null && cursorPx >= v.x && cursorPx <= r
        ? 0.0
        : r != null && cursorPx > r
            ? cursorPx - r
            : (v.x - cursorPx).abs();
    var better = best == null || d < bestD;
    if (!better && d == bestD) {
      // Equally near: a point is more specific than a range, then the older.
      if (v.isRange != best.isRange) {
        better = !v.isRange;
      } else {
        better = _byTime(v.a, best.a) < 0;
      }
    }
    if (better) {
      best = v;
      bestD = d;
    }
  }
  if (best == null) return null;
  if (reach != null && bestD > reach) return null;
  return best.a.id;
}

// ── sources ─────────────────────────────────────────────────────────────────

/// An algorithm-version change as annotations, in the daily slot domain
/// (slot i is at i, the last slot is today). [breakDaysBehind] is each break's
/// stamp as "days behind today" — the first day computed the new way. The mark
/// sits half a slot LEFT of it, and a break at slot 0 (nothing before it in
/// the window) or outside the window is dropped.
List<ChartAnnotation> algoBreakAnnotations({
  required List<int> breakDaysBehind,
  required int seriesLength,
  required String label,
}) {
  if (seriesLength < 2) return const [];
  final seen = <int>{};
  return [
    for (final b in breakDaysBehind)
      if (b >= 0 && b < seriesLength && seriesLength - 1 - b > 0 && seen.add(b))
        ChartAnnotation(
          id: 'algo:$b',
          kind: AnnotationKind.algoVersion,
          at: seriesLength - 1 - b - .5,
          label: label,
        ),
  ];
}

/// Intraday annotations (domain: epoch seconds) onto a daily chart whose slots
/// are the local day [dayLabels] ('YYYY-MM-DD', oldest first). Slot i is at
/// domain i. A point lands on its LOCAL day; a range inside one day is that
/// day's point; a range across days spans its first to its last day's slot. A
/// bound outside the window is kept as slot -1 / length, not clamped, so the
/// layout can tell a range that ended at the edge from one that ran past it. Anything outside the labels is dropped. Never
/// invents an item.
List<ChartAnnotation> dailyAnnotations(
  List<ChartAnnotation> timed,
  List<String> dayLabels,
) {
  if (dayLabels.isEmpty) return const [];
  final slot = {for (var i = 0; i < dayLabels.length; i++) dayLabels[i]: i};
  String dayOf(double sec) =>
      dayLabelOf(DateTime.fromMillisecondsSinceEpoch((sec * 1000).round()));
  // -1: before the window; length: after it; else the slot.
  int? slotOf(double sec) {
    if (!sec.isFinite) return null;
    final d = dayOf(sec);
    if (d.compareTo(dayLabels.first) < 0) return -1;
    if (d.compareTo(dayLabels.last) > 0) return dayLabels.length;
    return slot[d];
  }

  final out = <ChartAnnotation>[];
  for (final a in timed) {
    final s = slotOf(a.at);
    if (s == null) continue;
    final u = a.until;
    final e = u != null && u.isFinite && u > a.at ? slotOf(u) : null;
    if (e != null && e < 0) continue; // the whole range is before the window
    if (s >= dayLabels.length) continue;
    if (e == null && s < 0) continue;
    // Off-window bounds (-1 / length) are KEPT: the layout clips the shade and
    // draws no dashed edge on a side that lies outside the window.
    out.add(ChartAnnotation(
      id: a.id,
      kind: a.kind,
      at: s.toDouble(),
      until: e != null && e > s ? e.toDouble() : null,
      label: a.label,
    ));
  }
  return out;
}

/// What a chart is annotated with.
@immutable
class AnnotationSet {
  const AnnotationSet({
    required this.items,
    required this.domainStart,
    required this.domainEnd,
    this.reach,
  });
  final List<ChartAnnotation> items;
  final double domainStart;
  final double domainEnd;

  /// How far (px) the scrub may be from an item and still focus it; null means
  /// the nearest item is focused however far away.
  final double? reach;
}

// ── drawing ─────────────────────────────────────────────────────────────────

/// One dashed line, as the painter draws it.
@immutable
class AnnotationLine {
  const AnnotationLine({
    required this.id,
    required this.x,
    required this.color,
    required this.bold,
    required this.strokeWidth,
    this.dashed = true,
  });
  final String id;
  final double x;
  final Color color;
  final bool bold;
  final double strokeWidth;
  final bool dashed;
}

/// Paints the dashed lines. Public so tests can read what it will draw.
class AnnotationLinesPainter extends CustomPainter {
  const AnnotationLinesPainter({required this.lines});
  final List<AnnotationLine> lines;

  static const double dash = 4, gap = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    for (final l in lines) {
      final paint = Paint()
        ..color = l.color
        ..strokeWidth = l.strokeWidth;
      final x = l.x.clamp(l.strokeWidth / 2, size.width - l.strokeWidth / 2);
      if (!l.dashed) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        continue;
      }
      for (var y = 0.0; y < size.height; y += dash + gap) {
        canvas.drawLine(
            Offset(x, y), Offset(x, math.min(y + dash, size.height)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant AnnotationLinesPainter old) {
    if (old.lines.length != lines.length) return true;
    for (var i = 0; i < lines.length; i++) {
      final a = lines[i], b = old.lines[i];
      if (a.x != b.x ||
          a.color != b.color ||
          a.strokeWidth != b.strokeWidth ||
          a.dashed != b.dashed) {
        return true;
      }
    }
    return false;
  }
}

/// One kind's glyph at the lane's icon size. [bold] is the focused look: a
/// filled disc and a ring instead of a tint. The footprint never changes.
class AnnotationIcon extends StatelessWidget {
  const AnnotationIcon({super.key, required this.kind, required this.bold});
  final AnnotationKind kind;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final accent = annotationColor(kind);
    final ink = p.on(accent);
    return SizedBox(
      width: ChartAnnotationLane.iconSize,
      height: ChartAnnotationLane.iconSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bold ? p.fill(accent) : ink.withValues(alpha: .14),
          border: Border.all(color: ink, width: bold ? 2 : 0),
        ),
        child: Center(
          child: Icon(annotationIcon(kind),
              size: bold ? 15 : 13, color: bold ? p.inkOnFill : ink),
        ),
      ),
    );
  }
}

/// The annotation lane: icons (and "+n"), the static label, the shaded ranges
/// and the dashed lines running [plotHeight] down through the plot. Width is
/// whatever it is given; the layout is computed from it.
///
/// [cursor] is the scrub position 0…1 (null: none). A tap on an icon or its
/// "+n" steps to the next member of that icon, and a moved [cursor] clears
/// that pin.
class ChartAnnotationLane extends StatefulWidget {
  const ChartAnnotationLane({
    super.key,
    required this.set,
    required this.cursor,
    required this.plotHeight,
  });
  final AnnotationSet set;
  final double? cursor;
  final double plotHeight;

  static const double iconSize = 24;

  /// The label row at 1x text: the least the row ever is. At a larger text
  /// scale use [labelRowHeight], which is what the lane really reserves.
  static const double labelHeight = 16;

  /// Everything above the plot at 1x text: the label row, then the icon row.
  /// Use [headerFor] wherever the text scale is known.
  /// Never less than a full tap box, which ends at the plot seam.
  static const double header =
      labelHeight + iconSize > _tap ? labelHeight + iconSize : _tap;

  /// The style of the static label. One place, so the row is sized from the
  /// very style it draws with.
  static TextStyle labelStyle() =>
      F.cap.copyWith(fontWeight: FontWeight.w700, height: 1);

  /// The row reserved for the static label (always there, so focus never
  /// changes the lane's height): one line of [labelStyle] at the ambient
  /// [scaler], never less than [labelHeight]. Sized from the real line height
  /// so a large-text setting cannot clip the default label.
  static double labelRowHeight(TextScaler scaler,
      [TextDirection direction = TextDirection.ltr]) {
    final tp = TextPainter(
      text: TextSpan(text: 'Ag', style: labelStyle()),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    return math.max(labelHeight, tp.height.ceilToDouble());
  }

  /// Everything above the plot at [scaler]: the label row, then the icon row.
  /// This is what pushes the plot down, so the dashed lines and icons stay on it.
  static double headerFor(TextScaler scaler,
          [TextDirection direction = TextDirection.ltr]) =>
      math.max(_tap, labelRowHeight(scaler, direction) + iconSize);

  static const laneKey = ValueKey('annotation-lane');
  static const linesKey = ValueKey('annotation-lines');
  static const boundaryKey = ValueKey('annotation-boundary');
  static const labelKey = ValueKey('annotation-label');
  static ValueKey<String> iconKey(String id) => ValueKey('annotation-icon:$id');
  static ValueKey<String> moreKey(String id) => ValueKey('annotation-more:$id');
  static ValueKey<String> shadeKey(String id) => ValueKey('annotation-shade:$id');

  @override
  State<ChartAnnotationLane> createState() => _ChartAnnotationLaneState();
}

/// How far a 44 pt tap target overhangs the 24 pt icon on each side.
const double _tap = 44;
const double _overhang = (_tap - ChartAnnotationLane.iconSize) / 2;

class _ChartAnnotationLaneState extends State<ChartAnnotationLane> {
  /// The member a tap on an icon stepped to. Cleared when the cursor moves.
  String? _pin;

  @override
  void didUpdateWidget(covariant ChartAnnotationLane old) {
    super.didUpdateWidget(old);
    if (old.cursor != widget.cursor) _pin = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final set = widget.set;
    final labelH = ChartAnnotationLane.labelRowHeight(
        MediaQuery.textScalerOf(context), Directionality.of(context));
    final header = ChartAnnotationLane.headerFor(
        MediaQuery.textScalerOf(context), Directionality.of(context));
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth.isFinite ? box.maxWidth : 0.0;
      final scale = AnnotationScale(
          domainStart: set.domainStart, domainEnd: set.domainEnd, width: width);
      final cur = widget.cursor;
      final cursorPx = cur == null ? null : cur.clamp(0.0, 1.0) * width;
      AnnotationLayout layoutFor(String? f) => layoutAnnotations(
          annotations: set.items, scale: scale, focusId: f);
      final picked = pickAnnotationFocus(
          annotations: set.items,
          scale: scale,
          cursorPx: cursorPx,
          reach: set.reach);
      var layout = layoutFor(_pin ?? picked);
      if (_pin != null && layout.focusedId != _pin) layout = layoutFor(picked);

      final lines = <AnnotationLine>[];
      final shadeFor = {for (final s in layout.shades) s.id: s};
      for (final s in layout.shades) {
        // Both ends of a range are dashed lines; a cut end is not an end.
        final c = p.on(annotationColor(s.kind));
        if (s.endsInside) {
          lines.add(AnnotationLine(
              id: '${s.id}:end',
              x: s.right,
              color: c,
              bold: s.focused,
              strokeWidth: s.focused ? 2 : 1));
        }
      }
      for (final i in layout.items) {
        final s = shadeFor[i.id];
        if (i.isRange && s != null && !s.startsInside) continue;
        lines.add(AnnotationLine(
            id: i.id,
            x: i.x,
            color: p.on(annotationColor(i.kind)),
            bold: i.focused,
            strokeWidth: i.focused ? 2 : 1));
      }
      // Items with a shade but no icon still get their edges.
      for (final s in layout.shades) {
        if (layout.items.any((i) => i.id == s.id) || !s.startsInside) continue;
        lines.add(AnnotationLine(
            id: s.id,
            x: s.left,
            color: p.on(annotationColor(s.kind)),
            bold: s.focused,
            strokeWidth: s.focused ? 2 : 1));
      }

      final l = AppLocalizations.of(context);
      final byId = {for (final a in set.items) a.id: a};
      // A label that is only the kind's name (a version mark) is said once.
      String said(ChartAnnotation a) {
        final kind = annotationKindName(l, a.kind);
        return a.label == kind ? kind : '$kind, ${a.label}';
      }
      // Too crowded for even a "+n": still spoken, never dropped.
      final unplaced = [
        for (final id in layout.unplaced)
          if (byId[id] != null) byId[id]!,
      ]..sort(_byTime);

      void step(PlacedAnnotation i) =>
          setState(() => _pin = i.next(layout.focusedId));

      final children = <Widget>[
        for (final s in layout.shades)
          Positioned(
            left: s.left,
            width: math.max(s.right - s.left, 1),
            top: header,
            height: widget.plotHeight,
            child: IgnorePointer(
              child: ColoredBox(
                key: ChartAnnotationLane.shadeKey(s.id),
                color: annotationColor(s.kind)
                    .withValues(alpha: s.focused ? .26 : .14),
              ),
            ),
          ),
        if (lines.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            top: header,
            height: widget.plotHeight,
            child: IgnorePointer(
              child: CustomPaint(
                key: ChartAnnotationLane.linesKey,
                painter: AnnotationLinesPainter(lines: lines),
              ),
            ),
          ),
        if (layout.labelText != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: labelH,
            // Spoken by the icon it labels.
            child: ExcludeSemantics(
              child: IgnorePointer(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  layout.labelText!,
                  key: ChartAnnotationLane.labelKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ChartAnnotationLane.labelStyle()
                      .copyWith(color: p.ink),
                ),
              ),
            ),
            ),
          ),
        for (final i in layout.items) ...[
          // The tap target is 44 pt (Pressable) around a 24 pt icon: it
          // overhangs the icon's box rather than pushing the lane apart. It
          // ends at the seam with the plot (the overhang is all above the icon,
          // into the label row), so a drag that starts under an icon scrubs.
          Positioned(
            left: i.iconLeft - _overhang,
            top: header - _tap,
            child: Pressable(
              onTap: () => step(i),
              semanticLabel: said(byId[i.id]!),
              // The icon sits at the bottom of the box, on the seam row.
              child: Padding(
                padding: const EdgeInsets.only(top: _overhang * 2),
                child: AnnotationIcon(
                    key: ChartAnnotationLane.iconKey(i.id),
                    kind: i.kind,
                    bold: i.focused),
              ),
            ),
          ),
          if (i.more > 0)
            Positioned(
              left: i.iconLeft + i.iconWidth - (_tap - i.badgeWidth) / 2,
              top: header - _tap,
              child: Pressable(
                onTap: () => step(i),
                // The members the icon does not show, so stepping is
                // something a screen reader can both hear and do.
                semanticLabel: [
                  '+${i.more}',
                  for (final id in i.memberIds)
                    if (id != i.id && byId[id] != null) said(byId[id]!),
                ].join(', '),
                child: Padding(
                  padding: const EdgeInsets.only(top: _overhang * 2),
                  child: ExcludeSemantics(
                  child: SizedBox(
                  width: i.badgeWidth,
                  height: ChartAnnotationLane.iconSize,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '+${i.more}',
                          key: ChartAnnotationLane.moreKey(i.id),
                          maxLines: 1,
                          style: F.over.copyWith(
                              color: p.ink3,
                              fontWeight: i.focused
                                  ? FontWeight.w700
                                  : FontWeight.w500),
                        ),
                      ),
                    ),
                  ),
                ),
                ),
                ),
              ),
            ),
        ],
      ];

      return RepaintBoundary(
        key: ChartAnnotationLane.boundaryKey,
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          label: unplaced.isEmpty ? null : unplaced.map(said).join('; '),
          child: SizedBox(
            key: ChartAnnotationLane.laneKey,
            height: header + widget.plotHeight,
            width: double.infinity,
            child: Stack(clipBehavior: Clip.none, children: children),
          ),
        ),
      );
    });
  }
}

/// Reads the annotations for the local days [from]..[to] inclusive
/// ('YYYY-MM-DD'), in epoch seconds. Failure is an empty list, never null.
typedef AnnotationLoader = Future<List<ChartAnnotation>> Function(
    String from, String to);
