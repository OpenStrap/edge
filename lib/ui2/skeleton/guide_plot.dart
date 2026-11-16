import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart' show CustomPainter;

// CLAIM(guide-painters-classified): every CustomPainter under lib/ui2 declares what a
// guide placeholder does with it, by implementing exactly one of the four interfaces
// below [test/ui2/guide_paint_regression_test.dart]. A painter that declares none is drawn as
// NOTHING inside a placeholder, never as its real data: the safe default for the
// next chart someone adds.

/// A painter that draws data as a line, bars or shapes. Inside a placeholder it becomes
/// one muted sine wave over the plot's bounds in [guideLineColor]: no axes, no
/// labels, no values.
abstract interface class GuidePlot {
  Color get guideLineColor;
}

/// A [GuidePlot] that is a dial. Inside a placeholder it becomes an empty ring track
/// (no arc, no value), not a wave.
abstract interface class GuideRing implements GuidePlot {}

/// A painter that draws no data: a frame, an illustration, a symbol, the guide's own
/// paint. A placeholder leaves it exactly as it is.
abstract interface class GuideDecoration {}

/// A painter that marks positions of data over a plot (event lines). Inside a
/// placeholder it draws nothing: the plot under it is already a wave.
abstract interface class GuidePlotOverlay {}

/// The muted version of a plot's own colour: what placeholder waves and rings use.
/// One formula for every placeholder, so a plot never looks different in the plan
/// than in the paint.
Color mutedGuideColor(Color original) {
  final hsv = HSVColor.fromColor(original);
  return hsv.withSaturation(hsv.saturation * .45).withValue(hsv.value * .8).toColor();
}

/// True when a placeholder leaves [painter] as it is: it has none, or it declared
/// [GuideDecoration]. Every other painter is replaced or hidden.
bool guideKeepsPainter(CustomPainter? painter) => painter == null || painter is GuideDecoration;

/// [painter] as a [GuidePlot], or null. (A `CustomPainter` does not promote to an
/// unrelated interface, so the planner asks here.)
GuidePlot? guidePlotOf(Object? painter) => painter is GuidePlot ? painter : null;
