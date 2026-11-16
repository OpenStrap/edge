// THE COMPONENTS THAT PAINT THEIR OWN GUIDE LOOK (owner design, 2026-11-14).
//
// A guide run dims or skeletonizes the screen. Painting that in an overlay above
// the page lags the page by a frame while it scrolls, flings or stretches. So the
// look is painted INSIDE the content's own render subtree:
//
//  * [GuideUnitMark] wraps a Surface, Section, Pressable or GuideBox (grammar.dart). At paint
//    time it asks the plan ([GuideDimController.looks]) about its component and
//    paints its own foreground: one whole-box dim, or the skeleton with the heading
//    dimmed. It repaints (never rebuilds) when the plan changes.
//  * [GuideLooseLayer], put inside every Scrollable by [GuideScrollBehavior], paints
//    the same for LOOSE text (a paragraph in no component), inside the scrollable and
//    inside Android's overscroll stretch, in the frame the text moves in.
//
// The target also paints its own hover foreground in this subtree, in a repaint
// boundary. CLAIM(hover-in-target-tree) [guide_r7_hover_test].
//
// A dim follows the drawn box's rounded corners and fades in with [GuideDimController.fade];
// placeholders do not fade. Nothing here knows a guide. With no plan in force both are a
// plain proxy.
//
// COST: with no plan, one proxy render object per component and nothing per frame.
// With a plan, a repaint of a dimmed component is one rect; a skeleton component
// re-reads its own text lines per paint (a few paragraphs).

import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../grammar.dart' show Pressable;
import '../guides/guide_dim.dart';
import '../guides/guide_accordion.dart';
import '../guides/tree_geometry.dart';
import 'skeleton.dart';
import 'placeholder_paint.dart';

/// True for a paragraph that is an icon glyph (one private-use code point): icons
/// are never planned, dimmed or skeletonized on their own.
bool isIconParagraph(RenderParagraph paragraph) {
  final text = paragraph.text.toPlainText(includePlaceholders: false);
  if (text.isEmpty) return false;
  final runes = text.runes.toList();
  if (runes.length > 2) return false;
  return runes.every((r) => r >= 0xE000 && r <= 0xF8FF || r >= 0xF0000 && r <= 0x10FFFD);
}

/// True when [object] sits inside a [GuideLooseLayer], so its loose text paints
/// itself in the tree.
bool hasLooseLayer(RenderObject object) {
  for (RenderObject? o = object.parent; o != null; o = o.parent) {
    if (o is RenderGuideLoose) return true;
  }
  return false;
}

/// The loose paragraphs below [layer] (the element of a [GuideLooseLayer]): those in no
/// [GuideUnitMark] and no nested [GuideLooseLayer]. CLAIM(loose-same-walk): this walks the
/// ONSTAGE ELEMENT tree, exactly as the planner does ([planSkeleton]), never the semantics
/// tree: text under ExcludeSemantics is as loose as any [guide_input_regression_test F3].
Iterable<RenderParagraph> looseParagraphs(Element layer) sync* {
  final children = <Element>[];
  layer.debugVisitOnstageChildren(children.add);
  for (final child in children) {
    yield* _looseBelow(child);
  }
}

/// True for a mark whose component the planner never makes a unit: a Pressable with no
/// tap is not a control ([isGuideControl]), so its label is planned as loose text and
/// nothing else paints it.
bool _marksLooseLabels(GuideUnitMark mark) {
  final c = mark.component;
  return c is Element && c.widget is Pressable && (c.widget as Pressable).onTap == null;
}

Iterable<RenderParagraph> _looseBelow(Element e) sync* {
  final w = e.widget;
  // Chrome (a NavBar, a title, a tab bar) is never dimmed, whatever the plan says of it.
  if (w is GuideUnitMark && !_marksLooseLabels(w) || w is GuideLooseLayer || isGuideChromeWidget(w)) return;
  final ro = e is RenderObjectElement ? e.renderObject : null;
  if (ro is RenderParagraph) yield ro;
  final children = <Element>[];
  e.debugVisitOnstageChildren(children.add);
  for (final child in children) {
    yield* _looseBelow(child);
  }
}

/// Wraps one component. [component] is the Surface / Section / Pressable's own
/// element: the identity the plan is keyed by.
class GuideUnitMark extends SingleChildRenderObjectWidget {
  final BuildContext component;
  const GuideUnitMark({super.key, required this.component, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderGuideUnit(component as Element, GuideDimScope.controllerOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderGuideUnit renderObject) {
    renderObject
      ..component = component as Element
      ..controller = GuideDimScope.controllerOf(context);
  }
}

/// The component that paints the hover for [target]: its own (or one inside it) as big as it is;
/// a loose labelled control can use its enclosing component. Resolved with layout, never per frame.
RenderGuideUnit? guideHoverMark(RenderBox target) {
  RenderGuideUnit? found;
  void visit(RenderObject object) {
    if (found != null) return;
    if (object is RenderGuideUnit && object.hasSize && object.size == target.size) {
      found = object;
      return;
    }
    object.visitChildren(visit);
  }
  visit(target);
  if (found != null) return found;
  // Never above the target's own scrollable: such a component does not scroll with the target and the
  // viewport does not clip it, so its hover rect would drift (the overlay rect the owner rejected).
  for (RenderObject? parent = target.parent; parent != null; parent = parent.parent) {
    if (parent is RenderGuideUnit) return parent;
    if (parent is RenderAbstractViewport || parent is RenderSliver) return null;
  }
  return null;
}

/// Paints the child, then the component's own look over it.
class RenderGuideUnit extends RenderProxyBox {
  RenderGuideUnit(this._component, this._controller);

  Element _component;
  GuideDimController? _controller;

  set component(Element value) {
    if (identical(_component, value)) return;
    _component = value;
    markNeedsPaint();
  }

  set controller(GuideDimController? value) {
    if (identical(_controller, value)) return;
    if (attached) _unlisten();
    _pulse.stop();
    _controller = value;
    if (attached) _listen();
    markNeedsPaint();
  }

  /// Repaints this component asked for itself, for the tests that pin who repaints:
  /// because the plan changed, and because the pulse ticked.
  @visibleForTesting
  int planRepaints = 0, pulseRepaints = 0;

  void _planChanged() {
    planRepaints++;
    _followHover();
    markNeedsPaint();
  }

  void _pulsed() {
    pulseRepaints++;
    markNeedsPaint();
  }

  /// Listens to the pulse only while this component paints placeholders.
  final _pulse = PulseSubscription();
  GuideHover? _hover;

  @override
  bool get isRepaintBoundary => _hover != null;

  void _followHover() {
    final next = _controller?.hoverOf(this);
    if (identical(next, _hover)) return;
    _hover?.removeListener(_hoverChanged);
    final wasBoundary = isRepaintBoundary;
    _hover = next;
    _hover?.addListener(_hoverChanged);
    if (wasBoundary != isRepaintBoundary) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  void _hoverChanged() { markNeedsPaint(); }

  @visibleForTesting
  GuideHover? get hover => _hover;

  /// The look this component paints now (what [paint] reads from the plan).
  @visibleForTesting
  GuideUnitLook? get paintedLook => _component.mounted ? _controller?.looks?.lookOf(_component) : null;

  @override
  void performLayout() {
    super.performLayout();
    _controller?.geometryChanged();
  }


  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  void _listen() {
    final c = _controller;
    if (c != null && !c.isDisposed) {
      c.addListener(_planChanged);
      c.hoverBindings.addListener(_followHover);
    }
    _followHover();
  }

  void _unlisten() {
    final c = _controller;
    if (c == null) return;
    c.removeListener(_planChanged);
    if (!c.isDisposed) c.hoverBindings.removeListener(_followHover);
  }

  @override
  void detach() {
    _unlisten();
    _hover?.removeListener(_hoverChanged);
    _hover = null;
    _pulse.stop();
    super.detach();
  }

  /// The corner radius of the box this component draws (the first decorated box below
  /// it that is as big as it), so a dim does not stick out past rounded corners.
  BorderRadius? _drawnRadius() {
    RenderObject? o = child;
    for (var depth = 0; o != null && depth < 6; depth++) {
      if (o is RenderDecoratedBox && o.hasSize && o.size == size) {
        final d = o.decoration;
        if (d is BoxDecoration && d.shape == BoxShape.rectangle) {
          final r = d.borderRadius?.resolve(TextDirection.ltr);
          if (r != null) return r;
        }
      }
      RenderObject? next;
      o.visitChildren((c) => next ??= c);
      o = next;
    }
    return null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final looks = _controller?.looks;
    final look = _component.mounted ? looks?.lookOf(_component) : null;
    _pulse.follow(_controller, look == GuideUnitLook.skeleton, _pulsed);
    if (look == GuideUnitLook.skeleton && child != null) {
      GuidePlaceholderPaint.of(_component, fade: _controller?.fade ?? 1, pulse: _controller?.pulse ?? 1,
          keeps: looks is GuideKeepsControls ? looks as GuideKeepsControls : null)
          .paint(context, child!, offset, size);
      _paintHover(context, offset);
      return;
    }
    super.paint(context, offset);
    _paintHover(context, offset);
    if (look == null) return;
    final canvas = context.canvas;
    switch (look) {
      case GuideUnitLook.dim:
        // The dim reaches the edges of the drawn box: its own rounded corners.
        final paint = Paint()..color = scaffoldOf(_component).withValues(alpha: kDimOpacity * (_controller?.fade ?? 1));
        final radius = _drawnRadius();
        // A navigation header stays bright even when an ancestor card is dim.
        // The holes use local transforms, so scrolling/stretching carries both.
        canvas.save();
        for (final e in onstageElements(_component)) {
          if (e.widget is! GuideNavigationHeader) continue;
          final box = laidOutBox(e);
          if (box == null) continue;
          canvas.clipRect(rectInRoot(box, this).shift(offset), clipOp: ClipOp.difference);
        }
        if (radius == null) {
          canvas.drawRect(offset & size, paint);
        } else {
          canvas.drawRRect(radius.toRRect(offset & size), paint);
        }
        canvas.restore();
      case GuideUnitLook.skeleton:
        break;
    }
  }

  /// The guide's hover highlight on this component, in its own coordinates (so it follows scroll and
  /// stretch), over its content and over its placeholders alike.
  void _paintHover(PaintingContext context, Offset offset) {
    final hover = _hover;
    if (hover != null && hover.value > .004) {
      final rr = RRect.fromRectAndRadius(hover.rect.shift(offset), Radius.circular(hover.radius));
      final canvas = context.canvas;
      // Filled outer blur takes a rectangular fast path on large targets and
      // adds a second tint inside. Blurring only the border keeps the centre
      // uniform. CLAIM(hover-in-target-tree) [guide_r7_hover_test RGB check].
      canvas.drawRRect(rr, Paint()..color = hover.color.withValues(alpha: .55 * hover.value)
        ..style = PaintingStyle.stroke..strokeWidth = 2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
      canvas.drawRRect(rr, Paint()..color = hover.color.withValues(alpha: .26 * hover.value));
      canvas.drawRRect(rr.deflate(.5), Paint()..color = hover.color.withValues(alpha: .55 * hover.value)
        ..style = PaintingStyle.stroke..strokeWidth = 1);
    }
  }
}

/// A scroll behavior that gives every Scrollable a [GuideLooseLayer] INSIDE its
/// overscroll indicator. Its painter listens to viewport offsets, so it dims loose text also
/// while Android stretches it. The app sets it as `MaterialApp.scrollBehavior`.
class GuideScrollBehavior extends MaterialScrollBehavior {
  const GuideScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) =>
      super.buildOverscrollIndicator(context, GuideLooseLayer(scrollController: details.controller, child: child), details);
}

/// Paints the guide look of the loose paragraphs below it (those in no
/// [GuideUnitMark] and no nested [GuideLooseLayer]) over its own paint.
class GuideLooseLayer extends SingleChildRenderObjectWidget {
  final ScrollController? scrollController;
  const GuideLooseLayer({super.key, this.scrollController, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderGuideLoose(GuideDimScope.controllerOf(context), context as Element, scrollController);

  @override
  void updateRenderObject(BuildContext context, RenderGuideLoose renderObject) {
    renderObject
      ..element = context as Element
      ..scrollController = scrollController
      ..controller = GuideDimScope.controllerOf(context);
  }
}

class RenderGuideLoose extends RenderProxyBox {
  RenderGuideLoose(this._controller, this._element, this._scrollController);

  GuideDimController? _controller;
  Element _element;
  ScrollController? _scrollController;

  set scrollController(ScrollController? value) {
    if (identical(_scrollController, value)) return;
    if (attached) _scrollController?.removeListener(_scrollChanged);
    _scrollController = value;
    if (attached) _scrollController?.addListener(_scrollChanged);
    markNeedsPaint();
  }

  set element(Element value) => _element = value;

  set controller(GuideDimController? value) {
    if (identical(_controller, value)) return;
    if (attached) _controller?.removeListener(markNeedsPaint);
    _pulse.stop();
    _controller = value;
    if (attached) _listen();
    markNeedsPaint();
  }

  final _pulse = PulseSubscription();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
    _scrollController?.addListener(_scrollChanged);
  }

  void _listen() {
    final c = _controller;
    if (c != null && !c.isDisposed) c.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _scrollController?.removeListener(_scrollChanged);
    _controller?.removeListener(markNeedsPaint);
    _pulse.stop();
    super.detach();
  }

  // CLAIM(loose-scroll-repaint): a viewport repaints independently of this proxy.
  // Listen to its offset so an unchanged plan still repaints the loose masks in
  // the same frame [guide_r2_review_test R2]. No plan means no extra repaint.
  void _scrollChanged() {
    if (_controller?.looks != null) markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final looks = _controller?.looks;
    final c = child;
    if (looks is! GuideLooseLooks || c == null || !_element.mounted) {
      _pulse.stop();
      super.paint(context, offset);
      return;
    }
    final placeholders = {for (final p in looseParagraphs(_element))
      if (looks.looseLookOf(p) == GuideUnitLook.skeleton) p};
    _pulse.follow(_controller, placeholders.isNotEmpty, markNeedsPaint);
    if (placeholders.isEmpty) {
      super.paint(context, offset);
    } else {
      GuidePlaceholderPaint.paragraphs(placeholders, paletteOf(_element),
        fade: _controller?.fade ?? 1, pulse: _controller?.pulse ?? 1).paint(context, c, offset, size);
    }
    final canvas = context.canvas;
    final scaffold = scaffoldOf(_element);
    canvas
      ..save()
      ..clipRect(offset & size);
    for (final p in looseParagraphs(_element)) {
      if (!p.hasSize || !p.attached) continue;
      final look = looks.looseLookOf(p);
      if (look == null) continue;
      switch (look) {
        case GuideUnitLook.dim:
          final visible = rectInRoot(p, this).intersect(visibleBoundsInRoot(p, this));
          if (visible.isEmpty) continue;
          // Toward the surface the text sits on, so there is no box behind it (CLAIM(dim-has-no-box)).
          canvas.drawRect(visible.shift(offset), Paint()..color = surfaceBeneath(p, scaffold).withValues(alpha: kDimOpacity * (_controller?.fade ?? 1)));
        case GuideUnitLook.skeleton:
          break; // source text was replaced above, not erased by a surface fill
      }
    }
    canvas.restore();
  }
}

/// One component's subscription to [GuideDimController.pulseListenable]: held only
/// while it paints placeholders, so lit and dimmed components never hear a pulse tick.
class PulseSubscription {
  GuideDimController? _on;
  VoidCallback? _callback;

  /// True while subscribed.
  bool get active => _on != null;

  /// Subscribes ([placeholders]) or unsubscribes to match what the component paints now.
  void follow(GuideDimController? controller, bool placeholders, VoidCallback onPulse) {
    if (!placeholders || controller == null || controller.isDisposed) {
      stop();
      return;
    }
    if (identical(_on, controller)) return;
    stop();
    controller.pulseListenable.addListener(onPulse);
    _on = controller;
    _callback = onPulse;
  }

  void stop() {
    final on = _on, callback = _callback;
    if (on != null && callback != null && !on.isDisposed) on.pulseListenable.removeListener(callback);
    _on = null;
    _callback = null;
  }
}
