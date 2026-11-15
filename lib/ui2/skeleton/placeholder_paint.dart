// Replaces content at paint time. Decorations keep their own paint; there is
// no erase/fill over the card, so gradients, images and icon controls survive.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../guides/guide_accordion.dart';
import '../grammar.dart' show ChartFrame;
import '../theme.dart';
import '../guides/guide_dim.dart' show GuideKeepsControls;
import 'guide_plot.dart';
import 'skeleton.dart';

class GuidePlaceholderPaint {
  final Set<RenderParagraph> paragraphs;
  final Map<RenderParagraph, Color> inks;
  final Set<RenderParagraph> hidden;
  final Set<RenderCustomPaint> plots;
  final Set<RenderCustomPaint> framePaint;
  final RenderParagraph? title;
  final P palette;
  final double fade, pulse;
  GuidePlaceholderPaint._(
    this.paragraphs,
    this.inks,
    this.hidden,
    this.plots,
    this.framePaint,
    this.title,
    this.palette,
    this.fade,
    this.pulse,
  );

  factory GuidePlaceholderPaint.of(
    Element unit, {
    required double fade,
    required double pulse,
    GuideKeepsControls? keeps,
  }) {
    final paragraphs = <RenderParagraph>{};
    final inks = <RenderParagraph, Color>{};
    final hidden = <RenderParagraph>{};
    final plots = <RenderCustomPaint>{};
    final framePaint = <RenderCustomPaint>{};
    var card = isGuideCard(unit.widget);
    void visit(Element e) {
      final w = e.widget;
      if (w is GuideNavigationHeader || isGuideChromeWidget(w)) return;
      if (w is Icon || w is ImageIcon || w is Image || w is RawImage) return;
      // A control the guide keeps real (the previous or next step's target and the buttons beside
      // it) keeps its own labels inside a placeholder card [guide_r5_scenes_test R5-7].
      if (!identical(e, unit) && keeps != null && keeps.keepsControl(e)) return;
      if (isGuideCard(w)) card = true;
      final ro = e is RenderObjectElement ? e.renderObject : null;
      if (ro is RenderCustomPaint &&
          (ro.painter is GuidePlot || ro.foregroundPainter is GuidePlot)) {
        plots.add(ro);
        return; // axes/labels belong to the plot too
      }
      // A chart frame's own paint is axes and gridlines; a painter that never declared
      // itself ([guide_plot.dart]) or that marks data over a plot is hidden too. Only
      // its child is painted. CLAIM(guide-painters-classified).
      if (ro is RenderCustomPaint &&
          (e.findAncestorWidgetOfExactType<ChartFrame>() != null ||
              !guideKeepsPainter(ro.painter) ||
              !guideKeepsPainter(ro.foregroundPainter))) {
        framePaint.add(ro);
      }
      if (ro is RenderParagraph) {
        final frame = e.findAncestorWidgetOfExactType<ChartFrame>();
        if (frame != null && ro.text.toPlainText() != frame.title) {
          hidden.add(ro);
          return;
        }
        paragraphs.add(ro);
        inks[ro] = placeholderBarColor(placeholderSurfaceOf(e, paletteOf(unit).bg));
        return;
      }
      e.debugVisitOnstageChildren(visit);
    }

    visit(unit);
    return GuidePlaceholderPaint._(
      paragraphs,
      inks,
      hidden,
      plots,
      framePaint,
      card ? paragraphs.firstOrNull : null,
      paletteOf(unit),
      fade,
      pulse,
    );
  }

  factory GuidePlaceholderPaint.paragraphs(
    Set<RenderParagraph> paragraphs,
    P palette, {
    required double fade,
    required double pulse,
  }) => GuidePlaceholderPaint._(
    paragraphs,
    {for (final p in paragraphs) p: placeholderBarColor(palette.bg)},
    {},
    {},
    {},
    null,
    palette,
    fade,
    pulse,
  );

  void paint(
    PaintingContext context,
    RenderBox child,
    Offset offset,
    Size size,
  ) {
    final layer = OffsetLayer();
    context.pushLayer(layer, (_, at) {
      final content = _PlaceholderContext(layer, at & size, this);
      content.paintContents(child, at);
    }, offset);
  }
}

/// A paint context is propagated through clips, opacity and transforms. Nested
/// repaint boundaries are painted here while a guide replaces their leaves;
/// their cached original pictures must not reintroduce hidden data/axes.
class _PlaceholderContext extends PaintingContext {
  final GuidePlaceholderPaint treatment;
  _PlaceholderContext(
    super.containerLayer,
    super.estimatedBounds,
    this.treatment,
  );

  void paintContents(RenderBox child, Offset offset) {
    try {
      paintChild(child, offset);
    } finally {
      stopRecordingIfNeeded();
    }
  }

  @override
  PaintingContext createChildContext(ContainerLayer childLayer, Rect bounds) =>
      _PlaceholderContext(childLayer, bounds, treatment);

  @override
  void paintChild(RenderObject child, Offset offset) {
    final t = treatment;
    if (child is RenderParagraph && t.hidden.contains(child)) return;
    if (child is RenderParagraph && t.paragraphs.contains(child)) {
      if (identical(child, t.title)) {
        // Tint the title's glyphs, not the rectangle behind them. A placeholder
        // cannot replace or darken a patch of the card's own surface.
        canvas.saveLayer(offset & child.size, Paint()..colorFilter = ColorFilter.mode(
          t.palette.bg.withValues(alpha: kDimOpacity * t.fade), BlendMode.srcATop));
        super.paintChild(child, offset);
        canvas.restore();
      } else {
        final pigment = t.inks[child] ?? placeholderBarColor(t.palette.bg);
        final shapes = skeletonOfParagraph(child, t.palette.bg);
        canvas.save();
        canvas.translate(offset.dx, offset.dy);
        paintSkeletonShapes(
          canvas,
          [
            for (final s in shapes)
              SkeletonShape(
                kind: s.kind,
                rect: s.rect,
                section: s.section,
                color: pigment,
              ),
          ],
          t.palette,
          fade: t.fade,
          pulse: t.pulse,
        );
        canvas.restore();
      }
      return;
    }
    if (child is RenderCustomPaint && t.plots.contains(child)) {
      final plot = guidePlotOf(child.painter) ?? guidePlotOf(child.foregroundPainter);
      if (plot == null) return;
      paintSkeletonShapes(
        canvas,
        [
          SkeletonShape(
            // A dial is an empty ring track, a chart one wave: neither carries a value.
            kind: skeletonKindOfPlot(plot),
            rect: offset & child.size,
            section: 0,
            color: mutedGuideColor(plot.guideLineColor),
          ),
        ],
        t.palette,
        pulse: t.pulse,
      );
      return;
    }
    if (child is RenderCustomPaint && t.framePaint.contains(child)) {
      final content = child.child;
      if (content != null) paintChild(content, offset);
      return;
    }
    if (child.isRepaintBoundary) {
      child.paint(this, offset);
    } else {
      super.paintChild(child, offset);
    }
  }
}
