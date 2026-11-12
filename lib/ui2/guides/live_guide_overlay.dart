// LIVE GUIDE OVERLAY (live mode): draws a [GuideRun] over the user's own
// screens. It is one entry in the app's ROOT Overlay, above every route.
//
// After EVERY frame it
//   1. finds the top PAGE route's subtree ([topPageRoot]; null while a dialog,
//      sheet or picker is on top),
//   2. lets the run match a step by anchor ([GuideRun.observe]),
//   3. plans the skeleton over that subtree (the same [skeletonPlan] as
//      PR 1: keep = the step's target + alsoKeep + chrome) and paints it in the
//      overlay's own coordinates, progressively: whole sections fade to
//      skeleton from the top over [kGuideRevealDuration], then the outline and
//      the pill appear,
//   4. scrolls a lazy target into view ([revealTarget]) and shows the scroll
//      marker on `scrollThenTap` steps.
//
// Input: a tap on the target goes THROUGH to the real control (it does exactly
// what it always does, confirmation dialogs included); every other tap on the
// page is absorbed; the card's buttons work; system Back is untouched. While a
// dialog / sheet / picker is on top the overlay is inert and draws nothing, so
// the app's own dialog is fully usable.
//
// Semantics: the step card's caption is a live region; the target gets a proxy
// node "Guide target: <caption>" that performs the tap; covered content stays
// in the semantics tree (foreign semantics cannot be excluded).
//
// CLAIM(overlay-pass-through): the target's tap reaches the real control; other
// taps on the page do not [live_guide_overlay_test 'pointer rules'].
// CLAIM(overlay-yields-to-dialogs): with a dialog on top the overlay neither
// absorbs taps nor changes the run's state
// [live_guide_overlay_test 'a dialog on top is not leaving the path'].
// CLAIM(overlay-reveal): progress goes 0 -> 1 over [kGuideRevealDuration] per
// step; the outline and pill show only at 1
// [live_guide_overlay_test 'the reveal is progressive'].
//
// Mating parts: [GuideRunner] inserts/removes it; [GuideStepCard] is its card;
// guide_markers.dart holds the pill/outline rules shared with the review views.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/app_localizations.dart';
import '../theme.dart';
import 'guide.dart';
import 'guide_markers.dart';
import 'guide_step_card.dart';
import 'guide_target.dart';
import 'tree_geometry.dart';

import '../skeleton/skeleton.dart';
import 'guide_run.dart';

/// How long one step's skeleton takes to fade in, top to bottom.
const kGuideRevealDuration = Motion.reveal;

/// The subtree of the page route on top of [navigator], or null when the top
/// route is not a page (dialog, bottom sheet, picker) or has no built subtree.
Element? topPageRoot(NavigatorState navigator) {
  ModalRoute<dynamic>? current;
  void walk(Element e) {
    if (current != null || e.widget is LiveGuideOverlay) return;
    final route = ModalRoute.of(e);
    if (route != null && route.isCurrent) {
      current = route;
      return;
    }
    e.debugVisitOnstageChildren(walk);
  }
  walk(navigator.context as Element);
  final route = current;
  if (route is! PageRoute || route.animation?.status != AnimationStatus.completed) return null;
  return route.subtreeContext as Element?;
}

class LiveGuideOverlay extends StatefulWidget {
  final GuideRun run;

  /// The app's root Navigator: where the top page is looked for.
  final GlobalKey<NavigatorState> navigatorKey;

  /// "Exit" on the card.
  final VoidCallback onExit;

  /// "Back to the guide" on the off-path card.
  final VoidCallback onBackToGuide;

  const LiveGuideOverlay({
    super.key,
    required this.run,
    required this.navigatorKey,
    required this.onExit,
    required this.onBackToGuide,
  });

  static const skeletonKey = ValueKey('guide-live-skeleton');
  static const outlineKey = ValueKey('guide-live-outline');
  static const tapPillKey = ValueKey('guide-live-tap-pill');
  static const scrollMarkerKey = ValueKey('guide-live-scroll-marker');
  static const targetProxyKey = ValueKey('guide-live-target-proxy');

  @override
  State<LiveGuideOverlay> createState() => LiveGuideOverlayState();
}

class LiveGuideOverlayState extends State<LiveGuideOverlay> with SingleTickerProviderStateMixin {
  final _layerKey = GlobalKey();
  late final AnimationController _reveal;
  List<SkeletonShape> _shapes = const [];
  Rect? _target;
  List<Rect> _chrome = const [], _legible = const [];
  bool _yielding = true;
  Element? _page;
  GuideStep? _step;
  Object? _revealedPage;
  GuideStep? _revealedStep;
  Object? _searchSignature;
  final Map<int, Offset> _downs = {};

  @visibleForTesting
  List<SkeletonShape> get paintedShapes => _yielding ? const [] : revealedShapes(_shapes, revealProgress);
  @visibleForTesting
  Rect? get targetRect => _target;
  @visibleForTesting
  double get revealProgress => _reveal.value;
  @visibleForTesting
  bool get isYielding => _yielding;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(vsync: this, duration: kGuideRevealDuration)..addListener(_changed);
    widget.run.addListener(_changed);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    _watch();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reveal.duration = motion(context, kGuideRevealDuration);
  }

  @override
  void didUpdateWidget(LiveGuideOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.run != widget.run) {
      oldWidget.run.removeListener(_changed);
      widget.run.addListener(_changed);
      _revealedPage = null;
      _revealedStep = null;
    }
  }

  void _changed() { if (mounted) setState(() {}); }

  void _pointer(PointerEvent event) {
    final layer = _layerKey.currentContext?.findRenderObject();
    if (layer is! RenderBox || !layer.hasSize || _yielding) return;
    final point = layer.globalToLocal(event.position);
    if (event is PointerDownEvent && (_target?.contains(point) ?? false)) _downs[event.pointer] = point;
    if (event is PointerCancelEvent) _downs.remove(event.pointer);
    if (event is PointerMoveEvent) {
      final down = _downs[event.pointer];
      if (down != null && (point - down).distance > kTouchSlop) _downs.remove(event.pointer);
    }
    if (event is PointerUpEvent) {
      final down = _downs.remove(event.pointer);
      if (down != null && (point - down).distance <= kTouchSlop && (_target?.contains(point) ?? false)) {
        // Let the real gesture recognizer handle the tap before completing the run.
        scheduleMicrotask(() { if (mounted) widget.run.targetTapped(); });
      }
    }
  }

  void _activateTarget() {
    final target = _target;
    final layer = _layerKey.currentContext?.findRenderObject();
    if (target == null || layer is! RenderBox) return;
    final position = layer.localToGlobal(target.center);
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: -1, position: position));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: -1, position: position));
  }

  void _watch() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _plan();
      _watch(); // Observes frames; does not request one when geometry is unchanged.
    });
  }

  bool _sameShapes(List<SkeletonShape> a, List<SkeletonShape> b) => a.length == b.length &&
    List.generate(a.length, (i) => a[i].kind == b[i].kind && a[i].rect == b[i].rect &&
      a[i].section == b[i].section && a[i].color == b[i].color).every((same) => same);

  void _plan() {
    final nav = widget.navigatorKey.currentState;
    final layer = _layerKey.currentContext?.findRenderObject();
    if (nav == null || layer is! RenderBox || !layer.hasSize) return;
    final page = topPageRoot(nav);
    final l = AppLocalizations.of(context)!;
    widget.run.observe(page, l);
    final step = widget.run.currentStep;
    final newStep = _revealedPage != page || _revealedStep != step;
    if (page != null && step == null) {
      _revealedPage = null;
      _revealedStep = null;
      _reveal.stop();
    }
    // Retry discovery when async screen data replaces the loading state. A
    // failed search is not retried just because our own animation ticks.
    final content = <Object?>[];
    if (page != null) {
      visitBuilt(page, (e) {
        final w = e.widget;
        if (w is Text) content.add(w.data ?? w.textSpan?.toPlainText());
        if (e is StatefulElement && e.state is ScrollableState) {
          final position = (e.state as ScrollableState).position;
          if (position.hasContentDimensions) content.add(position.maxScrollExtent);
        }
      });
    }
    final signature = Object.hashAll(content);
    if (page != null && step != null && (newStep || (_target == null && _searchSignature != signature))) {
      _revealedPage = page;
      _revealedStep = step;
      _searchSignature = signature;
      // Also reveal plain-tap targets built just beyond the viewport: a target
      // must be visible before the card asks the user to press it.
      unawaited(revealTarget(page, step.target, l));
      if (newStep) _reveal.forward(from: 0);
    }
    final box = page == null ? null : laidOutBox(page);
    Rect? target;
    var shapes = <SkeletonShape>[];
    var chrome = <Rect>[];
    var legible = <Rect>[];
    if (page != null && box != null && step != null) {
      final transform = box.getTransformTo(layer);
      Rect intoOverlay(Rect r) => MatrixUtils.transformRect(transform, r);
      if (step.target.resolve(page, l) case TargetFound(:final rect)) {
        target = intoOverlay(rect);
        final keep = <Rect>[rect];
        for (final extra in step.alsoKeep) {
          if (extra.resolve(page, l) case TargetFound(:final rect)) keep.add(rect);
        }
        final localChrome = defaultSkeletonChrome(page);
        chrome = localChrome.map(intoOverlay).toList();
        legible = legibleContent(page, keep: keep).map(intoOverlay).toList();
        shapes = [for (final shape in skeletonPlan(page, keep: keep, chrome: localChrome))
          SkeletonShape(kind: shape.kind, rect: intoOverlay(shape.rect), section: shape.section, color: shape.color)];
      }
    }
    final changed = _page != page || _step != step || _target != target || _yielding != (page == null) ||
      !_sameShapes(_shapes, shapes) || !listEquals(_chrome, chrome) || !listEquals(_legible, legible);
    _page = page;
    _step = step;
    _target = target;
    _shapes = shapes;
    _chrome = chrome;
    _legible = legible;
    _yielding = page == null;
    if (changed) setState(() {});
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    widget.run.removeListener(_changed);
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final p = P.of(context);
    final run = widget.run;
    final state = run.state;
    final step = run.currentStep;
    final target = _target;
    final model = switch (state) {
      GuideAtStep(:final index) => GuideCardOnStep(number: index + 1, total: run.variant.steps.length,
        caption: run.variant.steps[index].caption(l), missingHelp: run.guide.missingTargetHelp),
      GuideOffPath() => const GuideCardOffPath(),
      GuideFinished() => GuideCardDone(run.guide.doneFooters),
    };
    final show = !_yielding && !run.isExited;
    final marked = show && target != null && step != null && revealProgress == 1;
    return SizedBox.expand(key: _layerKey, child: LayoutBuilder(builder: (context, constraints) {
      final screen = Offset.zero & constraints.biggest;
      final outline = target?.inflate(kGuideOutlineGap).intersect(screen);
      final padding = MediaQuery.paddingOf(context);
      var bounds = Rect.fromLTRB(screen.left, padding.top, screen.right,
        screen.bottom - math.max(padding.bottom, MediaQuery.viewInsetsOf(context).bottom));
      for (final r in _chrome) {
        if (r.top > screen.height / 2 && r.width > screen.width / 2) bounds = Rect.fromLTRB(bounds.left, bounds.top, bounds.right, math.min(bounds.bottom, r.top));
        if (r.top < screen.height / 4 && r.width > screen.width / 2) bounds = Rect.fromLTRB(bounds.left, math.max(bounds.top, r.bottom), bounds.right, bounds.bottom);
      }
      return Stack(children: [
        if (show && target != null && step != null)
          Positioned.fill(child: _GuideShield(
            holes: [target, ..._chrome],
            child: CustomPaint(key: LiveGuideOverlay.skeletonKey, painter: _GuidePainter(paintedShapes, p)),
          )),
        if (marked) Positioned.fromRect(rect: outline!, child: ExcludeSemantics(child: IgnorePointer(child: DecoratedBox(
          key: LiveGuideOverlay.outlineKey,
          decoration: BoxDecoration(border: Border.all(color: kGuideMarkerColor, width: 2.5), borderRadius: R.rMd),
        )))),
        if (marked) Positioned.fromRect(rect: target, child: Semantics(
          key: LiveGuideOverlay.targetProxyKey, container: true, button: true,
          label: l.guideTargetProxy(step.caption(l).replaceAll('**', '')), onTap: _activateTarget,
          child: const SizedBox.expand(),
        )),
        if (show) Positioned.fill(child: CustomMultiChildLayout(
          delegate: _GuideLayout(bounds, marked ? outline : target, _legible),
          children: [
            LayoutId(id: 'card', child: GuideStepCard(model: model, onExit: widget.onExit,
              onBackToGuide: state is GuideOffPath && state.lastIndex != null ? widget.onBackToGuide : null)),
            if (marked) LayoutId(id: 'pill', child: ExcludeSemantics(child: IgnorePointer(
              child: GuideMarkerPill(l.guideTapMarker, key: LiveGuideOverlay.tapPillKey)))),
            if (marked && step.action == GuideAction.scrollThenTap) LayoutId(id: 'scroll', child: ExcludeSemantics(child: IgnorePointer(
              child: RotatedBox(key: LiveGuideOverlay.scrollMarkerKey, quarterTurns: 1,
                child: GuideMarkerPill(l.guideScrollMarker, arrow: true))))),
          ],
        )),
      ]);
    }));
  }
}

class _GuideLayout extends MultiChildLayoutDelegate {
  final Rect bounds;
  final Rect? target;
  final List<Rect> avoid;
  _GuideLayout(this.bounds, this.target, this.avoid);
  @override
  void performLayout(Size size) {
    Rect? pill;
    if (hasChild('pill')) {
      final pillSize = layoutChild('pill', BoxConstraints.loose(bounds.size));
      pill = GuidePillLayout(target!, bounds, avoid).place(pillSize);
      positionChild('pill', pill.topLeft);
    }
    final cardSize = layoutChild('card', BoxConstraints(maxWidth: math.max(0, bounds.width - 2 * kGuideCardGap), maxHeight: bounds.height));
    final card = placeGuideCard(bounds: bounds, cardSize: cardSize,
      keepClear: [?target, ?pill], avoid: avoid);
    positionChild('card', card.topLeft);
    if (hasChild('scroll')) {
      final markerSize = layoutChild('scroll', BoxConstraints.loose(bounds.size));
      final marker = GuidePillLayout(target!, bounds, [...avoid, card, ?pill]).place(markerSize);
      positionChild('scroll', marker.topLeft);
    }
  }
  @override
  bool shouldRelayout(_GuideLayout old) => bounds != old.bounds || target != old.target || !listEquals(avoid, old.avoid);
}

class _GuidePainter extends CustomPainter {
  final List<SkeletonShape> shapes;
  final P palette;
  _GuidePainter(this.shapes, this.palette);
  @override
  void paint(Canvas canvas, Size size) {
    for (final s in shapes) {
      switch (s.kind) {
        case SkeletonKind.surface:
          canvas.drawRRect(R.rLg.toRRect(s.rect), Paint()..color = s.color!);
        case SkeletonKind.erase:
          canvas.drawRect(s.rect, Paint()..color = s.color!);
        case SkeletonKind.bar:
          final h = math.min(s.rect.height, math.max(8.0, s.rect.height * .55));
          final pill = Rect.fromCenter(center: s.rect.center, width: s.rect.width, height: h);
          canvas.drawRRect(RRect.fromRectAndRadius(pill, Radius.circular(h / 2)), Paint()..color = palette.line);
        case SkeletonKind.block:
          canvas.drawRRect(R.rMd.toRRect(s.rect), Paint()..color = palette.line);
      }
    }
  }
  @override
  bool shouldRepaint(_GuidePainter old) => true;
}

/// Hit-test holes let Navigator hit the actual page, including its recognizers.
class _GuideShield extends SingleChildRenderObjectWidget {
  final List<Rect> holes;
  const _GuideShield({required this.holes, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGuideShield(holes);
  @override
  void updateRenderObject(BuildContext context, _RenderGuideShield renderObject) { renderObject.holes = holes; }
}
class _RenderGuideShield extends RenderProxyBox {
  List<Rect> holes;
  _RenderGuideShield(this.holes);
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position) || holes.any((r) => r.contains(position))) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}
