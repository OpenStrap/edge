// CHART ANNOTATIONS - RED-PHASE STUBS. Every function and widget here is inert
// on purpose: the red tests (test/chart_annotation_*_test.dart,
// test/main_sleep_annotation_layout_test.dart, test/graphs_*_test.dart) must
// compile and then FAIL ON ASSERTIONS. The green phase replaces this file with
// the real layout (see edge.research/sol/graphs/scope-map.md, section 3).
//
// The intended behaviour, for the implementer:
//  * An item is an ICON and a DASHED vertical line on its true x.
//  * Icons never overlap: close unlinked points collapse to one icon with "+n";
//    a tap on the icon steps through the members.
//  * A linked start/end pair is a SHADED range with one icon and two edges.
//  * The main sleep is a priority mark: never in a "+n", the last icon given up.
//  * An unusable scale (zero width, empty domain) lays out nothing.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'theme.dart';

/// What an annotation is. One icon and one colour per kind.
enum AnnotationKind {
  water,
  assumedWater,
  moment,
  symptom,
  workout,
  nap,
  mainSleep,
  review,
  journal,
  algoVersion,
}

/// The glyph for [k]. STUB: one glyph for every kind.
IconData annotationIcon(AnnotationKind k) => LucideIcons.circle;

/// The pigment for [k]. STUB: one colour for every kind.
Color annotationColor(AnnotationKind k) => C.n400;

/// One thing to mark, in the chart's own x domain (epoch seconds, or a slot
/// index on a daily chart). A non-null [until] greater than [at] is a range.
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
  final double width;
  final double iconWidth;
  final double badgeWidth;

  /// STUB: always 0.
  double xOf(double at) => 0;

  /// STUB: never usable.
  bool get usable => false;
}

enum AnnotationLabelSlot { topStart }

/// One icon after layout, possibly standing for a cluster.
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

  final String id;
  final AnnotationKind kind;
  final String label;
  final double x;
  final double iconLeft;
  final double iconWidth;
  final double badgeWidth;
  final List<String> memberIds;
  final bool focused;
  final bool isRange;

  /// How many more items the icon stands for ("+n").
  int get more => memberIds.length - 1;

  double get footprintRight =>
      iconLeft + iconWidth + (more > 0 ? badgeWidth : 0);

  /// The member a tap on the icon moves to after [current] (wraps).
  /// STUB: never moves.
  String next(String? current) => memberIds.first;
}

/// A shaded span for a linked start/end pair.
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
  final bool startsInside;
  final bool endsInside;
}

/// Everything the lane draws.
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

  final List<PlacedAnnotation> items;
  final List<ShadedRange> shades;
  final List<String> unplaced;
  final String? focusedId;
  final String? labelText;
  final AnnotationLabelSlot labelSlot;
}

/// STUB: lays out nothing.
AnnotationLayout layoutAnnotations({
  required List<ChartAnnotation> annotations,
  required AnnotationScale scale,
  String? focusId,
}) =>
    const AnnotationLayout(
      items: [],
      shades: [],
      unplaced: [],
      focusedId: null,
      labelText: null,
    );

/// The annotation the finger is on (nearest, a range when inside it).
/// STUB: nothing.
String? pickAnnotationFocus({
  required List<ChartAnnotation> annotations,
  required AnnotationScale scale,
  required double? cursorPx,
  double? reach,
}) =>
    null;

/// Moves the focus [delta] stops through the laid-out members (clamped).
/// STUB: nothing.
String? stepAnnotationFocus(
  AnnotationLayout layout,
  String? current,
  int delta,
) =>
    null;

/// An algorithm-version change as annotations in the daily slot domain.
/// STUB: none.
List<ChartAnnotation> algoBreakAnnotations({
  required List<int> breakDaysBehind,
  required int seriesLength,
  required String label,
}) =>
    const [];

/// Intraday annotations (epoch seconds) onto a daily chart's slots.
/// STUB: none.
List<ChartAnnotation> dailyAnnotations(
  List<ChartAnnotation> timed,
  List<String> dayLabels,
) =>
    const [];

/// Reads the annotations for the local days [from]..[to] inclusive
/// ('YYYY-MM-DD'), in epoch seconds. Failure is an empty list, never null.
typedef AnnotationLoader = Future<List<ChartAnnotation>> Function(
    String from, String to);

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
  final double? reach;
}

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

/// STUB: paints nothing.
class AnnotationLinesPainter extends CustomPainter {
  const AnnotationLinesPainter({required this.lines});
  final List<AnnotationLine> lines;

  static const double dash = 4, gap = 3;

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant AnnotationLinesPainter old) => false;
}

/// STUB: an empty box.
class AnnotationIcon extends StatelessWidget {
  const AnnotationIcon({super.key, required this.kind, required this.bold});
  final AnnotationKind kind;
  final bool bold;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// STUB: draws nothing.
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
  static const double labelHeight = 16;
  static const double header = labelHeight + iconSize;

  static TextStyle labelStyle() => F.cap;

  static double labelRowHeight(TextScaler scaler,
          [TextDirection direction = TextDirection.ltr]) =>
      labelHeight;

  static double headerFor(TextScaler scaler,
          [TextDirection direction = TextDirection.ltr]) =>
      header;

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

class _ChartAnnotationLaneState extends State<ChartAnnotationLane> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
