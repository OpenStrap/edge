// LIVE GUIDE OVERLAY (live mode): draws a [GuideRun] over the user's own
// screens. It is one entry in the app's ROOT Overlay, above every route.
//
// After frames that change the page, layout, scroll or content it
//   1. finds the top PAGE route's subtree (null while a dialog,
//      sheet or picker is on top),
//   2. lets the run match a step by anchor ([GuideRun.observe]),
//   3. plans the skeleton over that subtree (the same [skeletonPlan] as
//      PR 1: keep = the step's target + alsoKeep + chrome) by the owner's
//      placeholder rule (the card above and below the target's card dimmed, the rest
//      placeholder; see [DimPolicy]). Placeholders show at once; the dim fades in
//      linearly over [kGuideRevealDuration], then the outline and the pill appear,
//   4. scrolls a lazy target into view ([revealTarget]) and shows the scroll
//      marker on `scrollThenTap` steps.
//
// Input: lit and dimmed units pass the original tap to the real control once.
// Placeholder units absorb activation and hand vertical drags to the page; the card's buttons work; Android system Back and the
// NavBar arrow work. Accepted limitation (S6): on step pages the shield absorbs
// the iOS edge-swipe Back gesture. Use the NavBar arrow to leave those pages.
// While a dialog / sheet / picker is on top the overlay is inert and draws nothing, so
// the app's own dialog is fully usable.
//
// Semantics: the step card's caption is a live region; the target gets a proxy
// node "Guide target: <caption>" that performs the tap; covered content stays
// in the semantics tree (foreign semantics cannot be excluded).
//
// CLAIM(overlay-pass-through): lit/dimmed controls receive the original tap once;
// placeholders absorb activation [live_guide_overlay_test 'pointer rules'].
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
import '../app_shell.dart' show AppShell;
import '../grammar.dart' show NavBar, Pressable, ScreenTitle, SubTabs;
import '../theme.dart';
import 'guide.dart';
import 'guide_navigation.dart';
import 'guide_motion.dart';
import 'guide_markers.dart';
import 'guide_step_card.dart';
import 'guide_target.dart';
import 'tree_geometry.dart';

import '../skeleton/skeleton.dart';
import '../skeleton/unit_paint.dart' show hasLooseLayer;
import '../skeleton/guide_plot.dart' show GuideDecoration;
import 'guide_dim.dart';
import 'guide_run.dart';
import 'guide_routes.dart';

/// How long one step's skeleton takes to fade in, top to bottom.
const kGuideRevealDuration = Motion.reveal;

class LiveGuideOverlay extends StatefulWidget {
  final GuideRun run;

  /// The app's root Navigator: where the top page is looked for.
  final GlobalKey<NavigatorState> navigatorKey;
  final GuideRouteObserver routes;

  /// "Exit" on the card.
  final VoidCallback onExit;

  /// "Back to the guide" on the off-path card.
  final VoidCallback onBackToGuide;

  const LiveGuideOverlay({
    super.key,
    required this.run,
    required this.navigatorKey,
    required this.routes,
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

class LiveGuideOverlayState extends State<LiveGuideOverlay> with TickerProviderStateMixin implements _GuideLayerSource {
  final _layerKey = GlobalKey();
  late final AnimationController _reveal;
  late final AnimationController _pulse;
  final _cardMotion = GuideCardMotion();
  final _cardOpacity = _CardOpacity();
  /// The card's motion time: the frame clock, so the clock controller may stop and start
  /// between motions without moving it.
  Duration get _elapsed => SchedulerBinding.instance.currentFrameTimeStamp;
  bool get _scrolling => _watchedScrolls.any((p) => p.isScrollingNotifier.value);

  /// True while the page shows at least one placeholder: the only time the pulse has
  /// anything to draw. Off path, on the Done card and on screens whose cards all sit in
  /// the lit/dim window there are none, and the guide then asks for no frames at all.
  bool _hasPlaceholders = false;

  @visibleForTesting
  bool get hasPlaceholders => _hasPlaceholders && !_yieldNow;

  /// True while the overlay clock runs. The clock drives the placeholder pulse and the
  /// card's move-then-restore motion; it runs only while one of them needs it.
  @visibleForTesting
  bool get isPulsing => _pulse.isAnimating;

  bool get _wantsPulse => hasPlaceholders && Motion.enabled(context);

  /// Starts or stops the clock to match what needs it. CLAIM(pulse-only-with-placeholders)
  /// [guide_r3_pulse_test, live_guide_overlay_test 'an idle guide schedules no frames'].
  void _syncClock() {
    if (!mounted) return;
    final wanted = _wantsPulse || _cardMotion.isAnimating;
    if (wanted && !_pulse.isAnimating) {
      Motion.configureGuidePulse(_pulse, enabled: true);
    } else if (!wanted && _pulse.isAnimating) {
      _pulse.stop();
    }
    if (!_wantsPulse) _dim?.setPulse(1);
  }

  void _pulsed() {
    if (_wantsPulse) {
      _dim?.setPulse(guidePulseValue(_pulse.value));
      if (_staticSections.isNotEmpty) _staticTick.value++;
    }
    if (_cardMotion.isAnimating && mounted) setState(() {});
  }
  List<SkeletonShape> _shapes = const [];
  /// The plan per component (what the Surfaces, Sections and Pressables paint for
  /// themselves) and the sections no component paints (the overlay paints those).
  SkeletonPlan? _skeletonPlan;
  List<RenderBox> _keepBoxes = const [];
  List<RenderBox> _chromeBoxes = const [];
  Set<int> _staticSections = const {};
  final _staticTick = ValueNotifier<int>(0);
  /// What the highlighted route-back control is, for the screen-reader proxy.
  _Route? _routeInfo;
  int? _returnHops;
  GuideDimController? _dim;
  GuidePlan? _published;
  Object? _searchSignature;
  Object? _scrollAtReveal;
  Rect? _lastRevealRect;
  Rect? _target;
  RenderBox? _targetObject;
  /// Where the scrollables that carry [_targetObject] stood when [_target] was planned:
  /// the scroll since then moves the target by the same distance ([_liveTarget]).
  List<_ScrollAnchor> _targetScrolls = const [];
  final Set<ScrollPosition> _watchedScrolls = {};
  List<Rect> _chrome = const [], _legible = const [];
  /// The control that leads back to the guide (off path) or to the step's tab: focused like a target.
  Rect? _route;
  bool _yielding = true;
  Element? _page;
  GuideStep? _step;
  Object? _revealedPage;
  GuideStep? _revealedStep;
  Element? _searchingPage;
  Object? _searchToken;
  final Map<int, Offset> _downs = {};
  Object? _plannedSignature;
  Duration? _lastPlanTime;
  int _planningCount = 0;

  @visibleForTesting
  int get planningCount => _planningCount;

  /// Page-tree signatures computed (the walk that hashes every built element). Idle
  /// frames of the pulse must not add to it [guide_r3_pulse_test].
  int _signatureChecks = 0;

  @visibleForTesting
  int get signatureChecks => _signatureChecks;

  /// Something the guide heard about (a scroll, a pointer, a run or route change) since
  /// the page was last read: the next frame re-reads it whatever else is going on.
  bool _planDirty = true;
  Duration? _lastSignatureAt;
  Element? _signedPage;
  Size? _signedSize;

  void _markDirty() => _planDirty = true;

  /// True for a frame the placeholder pulse (or the card's own motion) asked for, with
  /// nothing the guide knows of changed: the page need not be read again yet. The pulse
  /// only repaints; it is not a reason to hash the page. CLAIM(pulse-no-plan-walk).
  bool _pulseOnlyFrame(Element? page, Size size) {
    if (!_pulse.isAnimating || _planDirty || _plannedSignature == null) return false;
    if (!identical(page, _signedPage) || size != _signedSize) return false;
    final last = _lastSignatureAt;
    if (last == null) return false;
    final others = SchedulerBinding.instance.transientCallbackCount - 1 - (_reveal.isAnimating ? 1 : 0);
    if (others > 0) return false; // another animation moves the page: read it as before
    return SchedulerBinding.instance.currentFrameTimeStamp - last < Motion.guidePulsePlanInterval;
  }

  @override
  List<SkeletonShape> get layerShapes => paintedShapes;
  @override
  List<Rect> get layerHoles {
    final layer = _layerKey.currentContext?.findRenderObject();
    if (layer is! RenderBox) return const [];
    return [
      for (final box in [..._keepBoxes, ..._chromeBoxes, ?_routeInfo?.object])
        if (box.attached && box.hasSize) rectInRoot(box, layer).intersect(visibleBoundsInRoot(box, layer)),
    ];
  }

  // CLAIM(guide-live-hit-regions): input uses the component's current render transform,
  // including viewport clips, before any post-frame plan [guide_r2_review_test R1].
  @override
  List<Rect> get layerInk {
    final layer = _layerKey.currentContext?.findRenderObject();
    final looks = _published;
    final page = _page;
    if (layer is! RenderBox || looks == null || page == null || _yieldNow) return const [];
    final ink = <Rect>[];
    void add(RenderBox box) {
      final visible = rectInRoot(box, layer).intersect(visibleBoundsInRoot(box, layer));
      if (!visible.isEmpty) ink.add(visible);
    }

    void visit(Element element) {
      final box = laidOutBox(element);
      if (_paintsItself(element.widget) || isGuideControl(element.widget)) {
        if (box != null && looks.lookOf(element) == GuideUnitLook.skeleton) {
          add(box);
        }
        return;
      }
      final object = element is RenderObjectElement ? element.renderObject : null;
      if (object is RenderParagraph && object.attached && object.hasSize) {
        if (looks.looseLookOf(object) == GuideUnitLook.skeleton) {
          add(object);
        }
        return;
      }
      element.debugVisitOnstageChildren(visit);
    }
    visit(page);
    // Loose visuals have no component foreground; their plan still owns the look.
    for (final unit in _skeletonPlan?.units ?? const <PlannedUnit>[]) {
      final box = unit.visual;
      if (box == null || !box.attached || !box.hasSize || !unit.skeleton) continue;
      if (!layerShapes.any((shape) => shape.section == unit.section)) continue;
      add(box);
    }
    return ink;
  }
  @override
  Set<int> get layerStatic => _staticSections;
  @override
  double get layerFade => _reveal.value;
  @override
  double get layerPulse => _dim?.pulse ?? 1;

  @visibleForTesting
  List<SkeletonShape> get paintedShapes {
    if (_yielding) return const [];
    final shapes = _shapes; // placeholders at once; only the dim fades ([_publish])
    // A scroll since the plan moved the target; no ink may lie over it meanwhile.
    final target = _liveTarget;
    if (target == null || target == _target) return shapes;
    final inner = target.deflate(.5);
    return [for (final s in shapes) if (!s.rect.overlaps(inner)) s];
  }

  /// The target where it stands NOW. The plan is made after a frame and may be
  /// throttled, so a scroll (user or reveal) would leave the outline, the marker's
  /// direction and the card one frame behind. A scroll only translates the target, by
  /// how far each scrollable that carries it has moved since the plan: that needs no
  /// layout, so it is right in the frame the scroll happens in.
  Rect? get _liveTarget {
    final planned = _target;
    if (planned == null || _targetScrolls.isEmpty) return planned;
    var moved = Offset.zero;
    for (final a in _targetScrolls) {
      if (!a.position.hasPixels) continue;
      final d = a.position.pixels - a.pixels;
      moved += switch (a.position.axisDirection) {
        AxisDirection.down => Offset(0, -d),
        AxisDirection.up => Offset(0, d),
        AxisDirection.right => Offset(-d, 0),
        AxisDirection.left => Offset(d, 0),
      };
    }
    return moved == Offset.zero ? planned : planned.shift(moved);
  }

  /// The scrollables among [states] that carry [target], each with where it stands now.
  static List<_ScrollAnchor> _anchorsOf(RenderBox? target, List<ScrollableState> states) {
    if (target == null || !target.attached) return const [];
    final carriers = <_ScrollAnchor>[];
    for (final state in states) {
      final position = state.position;
      if (!position.hasPixels) continue;
      final carrier = state.context.findRenderObject();
      for (RenderObject? o = target; o != null; o = o.parent) {
        if (identical(o, carrier)) {
          carriers.add(_ScrollAnchor(position, position.pixels));
          break;
        }
      }
    }
    return carriers;
  }

  /// A page scrollable moved: rebuild so the overlay's own layout (which follows the
  /// page's) reads the target again. The plan itself stays throttled.
  void _scrolled() {
    if (!mounted) return;
    _markDirty();
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() {}); });
    } else {
      setState(() {});
    }
  }

  void _watchScrolls(Iterable<ScrollPosition> positions) {
    final next = positions.toSet();
    for (final gone in _watchedScrolls.difference(next)) { gone.removeListener(_scrolled); gone.isScrollingNotifier.removeListener(_scrolled); }
    for (final added in next.difference(_watchedScrolls)) { added.addListener(_scrolled); added.isScrollingNotifier.addListener(_scrolled); }
    _watchedScrolls..clear()..addAll(next);
  }

  /// P6: a target not built yet collapses the way to it. A built target keeps
  /// its layout window as it scrolls away, so clipped units never change look.
  bool get _collapsed {
    return _step != null && _liveTarget == null && _lazyTarget;
  }

  /// The step's target is not built yet but a scrollable could build it ([TargetNotBuilt]):
  /// the way to it lies in the scroll. A target that is absent or ambiguous is not that:
  /// there is nothing to scroll to, so nothing is collapsed and no marker is shown.
  bool _lazyTarget = false;

  /// [t] counts as on screen when it lies within [v] vertically and at least half of its
  /// width does horizontally: a sub-tab half hidden by its row's own side scroll is
  /// still there to tap (the guide cannot scroll it, and a vertical marker would lie).
  static bool _onScreen(Rect t, Rect v) => t.top >= v.top - .5 && t.bottom <= v.bottom + .5 &&
      math.min(t.right, v.right) - math.max(t.left, v.left) >= t.width / 2;
  // Edges count as inside: a full-width target ends exactly at the screen edge.
  @visibleForTesting
  Rect? get targetRect => _target;
  @visibleForTesting
  double get revealProgress => _reveal.value;
  @visibleForTesting
  bool get isYielding => _yielding;

  /// True while the guide must not show: the last plan found no page, or the
  /// Navigator's top route is no page NOW (a dialog was pushed since that plan, so
  /// the card must be gone in the next frame, not one frame after the plan).
  bool get _yieldNow => _yielding || widget.routes.page == null;

  void _routeChanged() {
    if (!mounted) return;
    _markDirty();
    _publish();
    _scrolled();
  }

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: kGuidePulseDuration)..addListener(_pulsed);
    _reveal = AnimationController(vsync: this, duration: kGuideRevealDuration)..addListener(_changed);
    widget.run.addListener(_changed);
    widget.routes.addListener(_routeChanged);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    _watch();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _markDirty();
    _reveal.duration = motion(context, kGuideRevealDuration);
    if (!Motion.enabled(context)) Motion.configureGuidePulse(_pulse, enabled: false);
    _syncClock();
    final dim = GuideDimScope.controllerOf(context);
    if (!identical(dim, _dim)) {
      _unpublish();
      _dim = dim;
      _publish();
    }
  }

  @override
  void didUpdateWidget(LiveGuideOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _markDirty();
    if (oldWidget.routes != widget.routes) {
      oldWidget.routes.removeListener(_routeChanged);
      widget.routes.addListener(_routeChanged);
    }
    if (oldWidget.run != widget.run) {
      oldWidget.run.removeListener(_changed);
      widget.run.addListener(_changed);
      _revealedPage = null;
      _revealedStep = null;
      _cardFraction = null;
      _cardMotion.reset();
    }
  }

  void _changed() {
    if (!mounted) return;
    _markDirty();
    _publish(); // The reveal moves on; the components repaint, nothing rebuilds.
    setState(() {});
  }

  // CLAIM(overlay-hit-target): geometry alone cannot prove a tap reaches a
  // control hidden under chrome [occluded target regressions in overlay tests].
  bool _hitsTarget(Offset position) {
    final target = _targetObject;
    if (target == null || !target.attached) return false;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
    return result.path.any((entry) => identical(entry.target, target));
  }

  void _pointer(PointerEvent event) {
    _markDirty();
    final layer = _layerKey.currentContext?.findRenderObject();
    if (layer is! RenderBox || !layer.hasSize || !layer.attached || _yieldNow) return;
    final point = layer.globalToLocal(event.position);
    if (event is PointerDownEvent && (_target?.contains(point) ?? false) && _hitsTarget(event.position)) _downs[event.pointer] = point;
    if (event is PointerCancelEvent) _downs.remove(event.pointer);
    if (event is PointerMoveEvent) {
      final down = _downs[event.pointer];
      if (down != null && (point - down).distance > kTouchSlop) _downs.remove(event.pointer);
    }
    if (event is PointerUpEvent) {
      final down = _downs.remove(event.pointer);
      if (down != null && (point - down).distance <= kTouchSlop && (_target?.contains(point) ?? false) && _hitsTarget(event.position)) {
        // Let the real gesture recognizer handle the tap before completing the run.
        scheduleMicrotask(() { if (mounted) widget.run.targetTapped(); });
      }
    }
  }

  /// The page drag this overlay's input layer handed off to the page's scrollable.
  _PageDrag? _pageDrag;

  /// Dim plan for an off-path page, in the page's coordinates: whole components
  /// (tabs included) except the route-back control, which stays full colour.
  /// [routeTab]: the route is that tab of the shell (never the NavBar back arrow or the
  /// guide's start tab); used when the step's target is inside a tab the user is not on
  /// ([_tabHolding]). Returns the plan, its shapes, and the route control (rect in page
  /// coordinates and what it is), which gets the target's outline and pill.
  (SkeletonPlan, List<SkeletonShape>, Rect?, _Route?) _offPathPlan(Element page, {int? routeTab,
    GuideHop? hop,
  }) {
    final root = laidOutBox(page);
    if (root == null) return (const SkeletonPlan([], [], {}, {}), const [], null, null);
    Rect rectOf(Element e) { final b = laidOutBox(e)!; return rectInRoot(b, root); }
    final tabs = <Rect>[];
    final tabElements = <Element>[];
    Rect? tabBar, back;
    Element? navBar, backElement;
    var backIsTab = false;
    for (final e in onstageElements(page)) {
      if (laidOutBox(e) == null) continue;
      if (e.widget.runtimeType.toString() == '_TabBar') {
        tabBar = rectOf(e);
        for (final c in onstageElements(e)) {
          if (c.widget is Pressable && laidOutBox(c) != null) { tabs.add(rectOf(c)); tabElements.add(c); }
        }
      } else if (e.widget is NavBar && navBar == null) {
        navBar = e;
      }
    }
    if (navBar != null && routeTab == null&&
        (hop == null || hop.kind == GuideHopKind.back)) {
      for (final c in onstageElements(navBar)) {
        if (c.widget is Pressable && laidOutBox(c) != null) { back = rectOf(c); backElement = c; break; }
      }
    }
    if (hop?.kind == GuideHopKind.subTab) {
      final index = GuideNavigation.subTabIndex(hop!.node);
      for (final e in onstageElements(page)) {
        if (e.widget is! SubTabs || index == null) continue;
        final controls = onstageElements(
          e,
        ).where((c) => c.widget is Pressable && laidOutBox(c) != null).toList();
        if (index < controls.length) {
          backElement = controls[index];
          back = rectOf(backElement).intersect(visibleBoundsInRoot(laidOutBox(backElement)!, root));
          backIsTab = true;
        }
        break;
      }
    }
    if (hop?.kind == GuideHopKind.page) {
      final found = GuideNavigation.entry(
        page,
        hop!,
        AppLocalizations.of(context)!,
      );
      if (found != null) {
        back = found.rect;
        backElement = onstageElements(page)
            .where((e) => identical(laidOutBox(e), found.renderObject))
            .firstOrNull;
      }
    }
    final startTab = routeTab ??
        (hop?.kind == GuideHopKind.tab
            ? GuideNavigation.tabIndex(hop!.node)
            : null) ?? switch (widget.run.guide.start) {
      GuideStart.today => 0, GuideStart.sleep => 1, GuideStart.activity => 2, GuideStart.health => 3,
      GuideStart.settings => -1,
    };
    if (back == null &&
        (hop == null || hop.kind == GuideHopKind.tab) && startTab >= 0 && startTab < tabs.length) {
      back = tabs[startTab];
      backElement = tabElements[startTab];
      backIsTab = true;
    }
    final route = back;
    final keepers = [?back];
    final plan = planSkeleton(page, keep: keepers, chrome: [?tabBar],
        dim: DimPolicy(focus: back, placeholders: false, neighboursLit: true, navigationTarget: backIsTab, focusObject: backElement == null ? null : laidOutBox(backElement)));
    final veil = scaffoldOf(page).withValues(alpha: kDimOpacity);
    final out = <SkeletonShape>[...plan.shapes];
    final units = <PlannedUnit>[...plan.units];
    var section = plan.shapes.isEmpty ? 0 : plan.shapes.last.section + 1;
    for (var i = 0; i < tabs.length; i++) {
      if (back != null && tabs[i].overlaps(back)) continue;
      out.add(SkeletonShape(kind: SkeletonKind.dim, rect: tabs[i], color: veil, section: section));
      units.add(PlannedUnit(component: tabElements[i], skeleton: false, section: section++));
    }
    final routeElement = backElement;
    // CLAIM(off-path-one-dim): tab sections belong to their component painters,
    // never the overlay as well [guide_r2_off_path_test].
    final tabPlan = SkeletonPlan(out, units, {...plan.seen, ...tabElements}, plan.seenLoose);
    return (tabPlan, out, route, routeElement == null ? null : _Route.of(routeElement, isTab: backIsTab));
  }

  /// The index of the tab of the shell under [page], other than the one on screen, whose
  /// parked (mounted, hidden) screen holds [target]; null when no other tab does, or when
  /// [page] has no shell. CLAIM(tab-route-only-when-found): a guide points at a tab only
  /// when the target is really in it [guide_r2_tier2_test F1].
  int? _tabHolding(Element page, GuideTarget target, AppLocalizations l) {
    Element? shell;
    for (final e in onstageElements(page)) {
      if (e.widget is AppShell) { shell = e; break; }
    }
    if (shell == null) return null;
    Element? stack;
    for (final e in builtElements(shell)) {
      if (e.widget is IndexedStack) { stack = e; break; }
    }
    if (stack == null) return null;
    final shown = (stack.widget as IndexedStack).index;
    Element? row;
    stack.visitChildren((c) => row ??= c);
    final raw = row;
    if (raw == null) return null;
    final screens = <Element>[];
    raw.visitChildren(screens.add);
    for (var i = 0; i < screens.length; i++) {
      if (i != shown && target.resolve(screens[i], l) is TargetFound) return i;
    }
    return null;
  }

  // The user's card height for THIS run, as a fraction of the travel available
  // between the bounds' edges (survives rotation and keyboard). The overlay is
  // created per run, so a new run starts without one. null = automatic.
  double? _cardFraction;
  final _cardGeometry = _CardGeometry();

  void _moveCard(double dy) {
    final g = _cardGeometry;
    if (g.upper <= g.lower) return;
    _cardMotion.reset();
    setState(() => _cardFraction = ((g.top + dy - g.lower) / (g.upper - g.lower)).clamp(0.0, 1.0));
  }

  // The card follows the finger exactly. A gesture recognizer would eat the touch
  // slop (and apply only the last update per frame), so the drag reads raw pointer
  // events: once the finger has moved a slop vertically, the card sits at
  // (its top when the finger went down) + (finger travel), clamped to its bounds.
  int? _cardPointer;
  double _cardDownY = 0, _cardDownTop = 0;
  bool _cardDragging = false;

  void _cardDown(PointerDownEvent e) {
    if (_cardPointer != null) return;
    _cardPointer = e.pointer;
    _cardDownY = e.position.dy;
    _cardDownTop = _cardGeometry.top;
    _cardDragging = false;
  }

  void _cardMove(PointerMoveEvent e) {
    if (e.pointer != _cardPointer) return;
    final travel = e.position.dy - _cardDownY;
    if (!_cardDragging && travel.abs() < kTouchSlop) return;
    _cardDragging = true;
    final g = _cardGeometry;
    if (g.upper <= g.lower) return;
    final top = (_cardDownTop + travel).clamp(g.lower, g.upper);
    _cardMotion.reset();
    setState(() => _cardFraction = (top - g.lower) / (g.upper - g.lower));
  }

  void _cardEnd(PointerEvent e) {
    if (e.pointer == _cardPointer) _cardPointer = null;
  }

  /// The card, draggable by its blank space (buttons keep their taps) and a
  /// sink for every other pointer: nothing on the card reaches the page below.
  Widget _cardMover(Widget card, AppLocalizations l) => Semantics(
    customSemanticsActions: {
      CustomSemanticsAction(label: l.guideMoveCardUp): () => _moveCard(-_cardGeometry.step),
      CustomSemanticsAction(label: l.guideMoveCardDown): () => _moveCard(_cardGeometry.step),
    },
    child: Listener(
      onPointerDown: _cardDown, onPointerMove: _cardMove,
      onPointerUp: _cardEnd, onPointerCancel: _cardEnd,
      // The card is hit-testable, so the page below is never in the hit path; the
      // no-op tap/long-press sink taps on blank card space. No double-tap: it delays buttons' taps.
      child: GestureDetector(onTap: () {}, onLongPress: () {}, child: card),
    ),
  );

  /// Starts a drag on the page's own innermost vertical scrollable under
  /// [details], so a drag that begins on skeleton ink scrolls the real page.
  void _dragStart(DragStartDetails details) {
    final page = _page;
    if (page == null) return;
    ScrollableState? hit;
    for (final e in builtElements(page)) {
      if (e is! StatefulElement) continue;
      final state = e.state;
      if (state is! ScrollableState || !state.position.hasPixels || state.position.axis != Axis.vertical) continue;
      final box = e.renderObject;
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(details.globalPosition)) hit = state;
    }
    _pageDrag = null;
    if (hit != null) {
      final handoff = _PageDrag();
      handoff.drag = hit.position.drag(details, handoff.ended);
      _pageDrag = handoff;
    }
  }

  /// Ends the handed-off page drag, if one is live. CLAIM(drag-handoff-cancel): the input
  /// layer's recognizer is disposed without telling anyone, and a drag nobody ends leaves
  /// the page's Scrollable ignoring pointers (the user's next tap is lost). Called when the
  /// layer leaves the tree, in build, on deactivate and dispose. Deferred to after the
  /// frame: ending a drag notifies scroll listeners, which must not happen while the tree
  /// is being built or finalized [guide_r2_tier2_test F2].
  void _dropPageDrag() {
    final handoff = _pageDrag;
    if (handoff == null) return;
    _pageDrag = null;
    SchedulerBinding.instance.addPostFrameCallback((_) => handoff.cancel());
  }

  void _activateTarget() {
    final target = _liveTarget;
    final layer = _layerKey.currentContext?.findRenderObject();
    if (target == null || layer is! RenderBox || !layer.attached) return;
    final position = layer.localToGlobal(target.center);
    if (!_hitsTarget(position)) return;
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: -1, position: position));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: -1, position: position));
  }

  /// The route-back proxy's activation: a real tap on the route control, exactly as
  /// the target proxy does for the target.
  void _activateRoute() {
    final route = _route, object = _routeInfo?.object;
    final layer = _layerKey.currentContext?.findRenderObject();
    if (route == null || object == null || !object.attached || layer is! RenderBox || !layer.attached) return;
    final position = layer.localToGlobal(route.center);
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
    if (!result.path.any((entry) => identical(entry.target, object))) return;
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: -2, position: position));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: -2, position: position));
  }

  void _watch() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _plan();
      _syncClock();
      _watch(); // Observes frames; does not request one when geometry is unchanged.
    });
  }

  bool _sameShapes(List<SkeletonShape> a, List<SkeletonShape> b) => a.length == b.length &&
    List.generate(a.length, (i) => a[i].kind == b[i].kind && a[i].rect == b[i].rect &&
      a[i].section == b[i].section && a[i].color == b[i].color).every((same) => same);

  void _plan() {
    final nav = widget.navigatorKey.currentState;
    final layer = _layerKey.currentContext?.findRenderObject();
    if (nav == null || layer is! RenderBox || !layer.hasSize || !layer.attached) return;
    final page = widget.routes.page;
    final l = AppLocalizations.of(context)!;
    widget.run.observe(null, l); // Prune disposed pages even when the plan is cached.
    if (_pulseOnlyFrame(page, layer.size)) return;
    // One traversal replaces repeated anchor, target, chrome, legibility and
    // skeleton walks on idle/reveal frames. Widget identity catches replacement
    // structure (including same-text controls). Transforms catch controls moving
    // without resizing; sliver geometry and counts catch newly built lazy content.
    // See the late-content, real Sleep and History integration regressions.
    final content = <Object?>[];
    final discoveryContent = <Object?>[];
    final scrolls = <Object?>[];
    final scrollPositions = <ScrollPosition>[];
    final scrollStates = <ScrollableState>[];
    var builtCount = 0;
    if (page != null) {
      visitBuilt(page, (e) {
        builtCount++;
        final w = e.widget;
        content.add(e);
        content.add(w);
        if (w is Text) discoveryContent.add(w.data ?? w.textSpan?.toPlainText());
        final object = e is RenderObjectElement ? e.renderObject : null;
        if (object != null && object.attached) {
          content.add(object);
          if (object is RenderBox && object.hasSize) {
            content.add(object.size);
            content.add(Object.hashAll(object.getTransformTo(layer).storage));
          }
          if (object is RenderSliver && object.geometry != null) {
            content.add(object.constraints);
            content.add(object.geometry);
            content.add(Object.hashAll(object.getTransformTo(layer).storage));
          }
        }
        if (e is StatefulElement && e.state is ScrollableState) {
          final position = (e.state as ScrollableState).position;
          scrollPositions.add(position);
          scrollStates.add(e.state as ScrollableState);
          if (position.hasPixels) { content.add(position.pixels); scrolls.add(position.pixels); }
          if (position.hasContentDimensions) {
            content.add(position.minScrollExtent);
            content.add(position.maxScrollExtent);
            content.add(position.viewportDimension);
            discoveryContent.add(position.minScrollExtent);
            discoveryContent.add(position.maxScrollExtent);
            discoveryContent.add(position.viewportDimension);
          }
        }
      });
    }
    // Discovery retries use stable text/extents: rebuilding cached list
    // children during an unsuccessful search must not restart that search.
    _watchScrolls(scrollPositions);
    final signature = Object.hashAll(discoveryContent);
    final scrollSignature = Object.hashAll(scrolls);
    final planSignature = (page, layer.size, builtCount, Object.hashAll(content), widget.run,
      widget.run.state, l, _searchingPage, _revealedPage, _revealedStep);
    _signatureChecks++;
    _planDirty = false;
    _lastSignatureAt = SchedulerBinding.instance.currentFrameTimeStamp;
    _signedPage = page;
    _signedSize = layer.size;
    if (_plannedSignature == planSignature) return;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    // Avoid full-tree planning at animation cadence. Request a trailing frame
    // so even the last throttled layout is eventually measured. New pages,
    // popups and completed animations are always reflected immediately.
    // The overlay's own clock (placeholder pulse, card motion) is not a page animation.
    final animating = SchedulerBinding.instance.transientCallbackCount >
        (_reveal.isAnimating ? 1 : 0) + (_pulse.isAnimating ? 1 : 0);
    if (page != null && identical(page, _page) && animating &&
        _lastPlanTime != null && now - _lastPlanTime! < motion(context, Motion.guidePlanInterval)) {
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    _plannedSignature = planSignature;
    _lastPlanTime = now;
    _planningCount++;
    if (page == null || !identical(page, _searchingPage)) widget.run.observe(page, l);
    final step = widget.run.currentStep;
    final newStep = _revealedPage != page || _revealedStep != step;
    if (_revealedStep != step) _cardMotion.reset();
    if (page != null && step == null) {
      _revealedPage = null;
      _revealedStep = null;
      _reveal.stop();
      if (_reveal.value != 1) _reveal.value = 1; // off path: the dim is there at full strength
    }
    final box = page == null ? null : laidOutBox(page);
    final resolution = page == null || step == null ? null : step.target.resolve(page, l);
    final targetNow = box != null && resolution is TargetFound
        ? MatrixUtils.transformRect(box.getTransformTo(layer), resolution.rect) : null;
    final viewport = Offset.zero & layer.size;
    final outside = targetNow != null && !_onScreen(targetNow, viewport);
    // The page is revealed once per step, and again when LATE CONTENT moves the target
    // away (an async read lands above it). It is never re-revealed after the USER
    // scrolled: the marker shows the way and the overlay must not scroll the page back
    // under their finger. [_scrollAtReveal] is where every scrollable stood when the
    // last reveal settled; any other position is the user's.
    if (_searchingPage == null && _scrollAtReveal == null) _scrollAtReveal = scrollSignature;
    final retry = _searchingPage == null && _scrollAtReveal == scrollSignature &&
        ((targetNow == null && _searchSignature != signature) ||
         (outside && _lastRevealRect != targetNow));
    if (page != null && step != null && (newStep || retry)) {
      _revealedPage = page;
      _revealedStep = step;
      _searchSignature = signature;
      _lastRevealRect = targetNow;
      _scrollAtReveal = null;
      // Also reveal plain-tap targets built just beyond the viewport: a target
      // must be visible before the card asks the user to press it.
      final token = Object();
      _searchToken = token;
      _searchingPage = page;
      unawaited(revealTarget(page, step.target, l, isCurrent: () =>
        mounted && identical(_searchToken, token) && !widget.run.isExited && identical(widget.routes.page, page) &&
        identical(widget.run.currentStep, step)).whenComplete(() {
          if (mounted && identical(_searchToken, token)) {
            _searchingPage = null;
            _searchToken = null;
            // The search can build children or move the target after this
            // frame's snapshot. Always measure its settled result once.
            _plannedSignature = null;
            if (!identical(widget.routes.page, page)) _revealedPage = null;
            setState(() {});
          }
        }));
      if (newStep) _reveal.forward(from: 0);
    }
    Rect? target;
    var shapes = <SkeletonShape>[];
    SkeletonPlan? skeleton;
    var keepBoxes = <RenderBox>[];
    var chrome = <Rect>[];
    var legible = <Rect>[];
    List<SkeletonShape> intoOverlayShapes(List<SkeletonShape> plan, Matrix4 transform) => [
      for (final shape in plan)
        SkeletonShape(kind: shape.kind, rect: MatrixUtils.transformRect(transform, shape.rect), section: shape.section, color: shape.color),
    ];
    if (page != null && box != null && step != null) {
      final transform = box.getTransformTo(layer);
      Rect intoOverlay(Rect r) => MatrixUtils.transformRect(transform, r);
      if (resolution case TargetFound(:final rect, :final renderObject)) {
        target = intoOverlay(rect);
        final keep = <Rect>[rect];
        keepBoxes.add(renderObject);
        for (final extraKeep in step.alsoKeep) {
          if (extraKeep.resolve(page, l) case TargetFound(:final rect, :final renderObject)) {
            keep.add(rect);
            keepBoxes.add(renderObject);
          }
        }
        // P7/P8: caption-offered controls and caption-named details stay full colour.
        for (final content in [...step.alsoTap, ...step.alsoRead]) {
          for (final found in content.resolve(page, l)) {
            keep.add(found.rect);
            keepBoxes.add(found.renderObject);
          }
        }
        // Live status (title row, running timer) stays readable and clear of the card.
        final status = liveStatusRects(page);
        keep.addAll(status);
        final localChrome = defaultSkeletonChrome(page);
        chrome = localChrome.map(intoOverlay).toList();
        legible = [...legibleContent(page, keep: keep), ...status].map(intoOverlay).toList();
        // A built target's window belongs to layout, independently of clipping.
        final policy = DimPolicy.of(page, resolution);
        skeleton = planSkeleton(page, keep: keep, chrome: localChrome, dim: policy);
        shapes = intoOverlayShapes(skeleton.shapes, transform);
      }
    }
    Rect? route;
    _Route? routeInfo;
    if (page != null && box != null && step != null && resolution is! TargetFound) {
      final transform = box.getTransformTo(layer);
      final localChrome = defaultSkeletonChrome(page);
      chrome = [for (final r in localChrome) MatrixUtils.transformRect(transform, r)];
      // Only a target that EXISTS in another tab routes through that tab; one that is
      // simply not on this page covers nothing.
      final hops = step.node != null
          ? widget.routes.routeTo(step.node!)
          : const <GuideHop>[];
      final hop = hops.firstOrNull;
      final holding = hop == null && step.node == null && resolution is TargetAbsent ? _tabHolding(page, step.target, l) : null;
      final (tabPlan, tabShapes, tab, tabRoute) = holding != null
          || hop != null
          ? _offPathPlan(page, routeTab: holding, hop: hop)
          : (const SkeletonPlan([], [], {}, {}), const <SkeletonShape>[], null, null);
      if (tab != null) {
        routeInfo = tabRoute;
        // The step's target is on a tab the user is not on: that tab is the route
        // (outline and pill like a target; it passes taps), the rest is dimmed.
        route = MatrixUtils.transformRect(transform, tab);
        skeleton = tabPlan;
        shapes = intoOverlayShapes(tabShapes, transform);
      } else if (resolution is TargetNotBuilt) {
        // P6: the target is not built yet; everything on screen is the way to it.
        skeleton = planSkeleton(page, keep: const [], chrome: localChrome, dim: const DimPolicy(skeletonAll: true));
        shapes = intoOverlayShapes(skeleton.shapes, transform);
      }
      // A target that is absent or ambiguous with no route to show covers nothing: a guide
      // never hides a screen it cannot point into (the card offers "Don't see it?").
    }
    final offPath = widget.run.state;
    if (page != null && box != null && step == null && offPath is GuideOffPath) {
      // Off path: everything dims except the one control one step closer to the
      // guide (NavBar back arrow, or the start tab); it is focused like a target.
      final transform = box.getTransformTo(layer);
      // The card stays clear of the tab bar and the header, as on a step: a tab is how the
      // user leaves, and a card over it would sink the tap.
      chrome = [for (final r in defaultSkeletonChrome(page)) MatrixUtils.transformRect(transform, r)];
      final last = offPath.lastIndex ?? 0;
      final destination = widget.run.variant.steps[last].node;
      final hops = destination != null
          ? widget.routes.routeTo(destination)
          : const <GuideHop>[];
      _returnHops = hops.isEmpty ? null : hops.length;
      final (plan, planShapes, back, backRoute) = _offPathPlan(page,
        hop: hops.firstOrNull,
      );
      if (back != null) route = MatrixUtils.transformRect(transform, back);
      routeInfo = backRoute;
      skeleton = plan;
      shapes = intoOverlayShapes(planShapes, transform);
    }
    // Sections that no component paints itself: the overlay paints those.
    final inTree = <int>{
      for (final u in skeleton?.units ?? const <PlannedUnit>[])
        if (u.component != null ? _paintsItself(u.component!.widget) : u.paragraph != null && hasLooseLayer(u.paragraph!)) u.section,
    };
    final staticSections = {for (final s in shapes) if (!inTree.contains(s.section)) s.section};
    // The shapes are read at paint and hit-test time ([_GuideLayerSource]): a scroll that
    // only moves them rebuilds nothing; only static ink needs a repaint of its layer.
    if (staticSections.isNotEmpty || _staticSections.isNotEmpty) {
      if (!_sameShapes(_shapes, shapes) || !setEquals(_staticSections, staticSections)) _staticTick.value++;
    }
    final changed = _page != page || _step != step || _target != target || _yielding != (page == null) ||
      !listEquals(_chrome, chrome) || !listEquals(_legible, legible) || _route != route ||
      (_skeletonPlan == null) != (skeleton == null);
    _page = page;
    _step = step;
    _target = target;
    _lazyTarget = resolution is TargetNotBuilt;
    _targetObject = resolution is TargetFound ? resolution.renderObject : null;
    _targetScrolls = _anchorsOf(_targetObject, scrollStates);
    _shapes = shapes;
    _skeletonPlan = skeleton;
    _hasPlaceholders = _collapsed || (skeleton?.units.any((u) => u.skeleton) ?? false);
    _keepBoxes = keepBoxes;
    _staticSections = staticSections;
    _routeInfo = route == null ? null : routeInfo;
    _chromeBoxes = [
      if (page != null) for (final e in onstageElements(page))
        if (e.widget is ScreenTitle || e.widget is NavBar || e.widget is SubTabs || e.widget.runtimeType.toString() == '_TabBar')
          if (laidOutBox(e) case final RenderBox chromeBox) chromeBox,
    ];
    _chrome = chrome;
    _legible = legible;
    _route = route;
    _yielding = page == null;
    _publish();
    if (changed) setState(() {});
  }

  /// True for a component that wraps itself in a [GuideUnitMark].
  static bool _paintsItself(Widget w) => isGuideComponent(w);

  /// Hands the plan to the components (they repaint themselves; nothing rebuilds).
  /// Equal plans notify nobody ([GuideDimController.setLooks]).
  void _publish() {
    final dim = _dim;
    if (dim == null) return;
    final plan = _skeletonPlan;
    if (_yieldNow || widget.run.isExited || plan == null || _page == null) {
      _unpublish();
      return;
    }
    final next = GuidePlan.from(_page, plan, keep: _keepBoxes, skeletonAll: _collapsed);
    _published = next;
    dim.setLooks(next);
    // CLAIM(dim-fade-linear): the placeholders are there at once; the dim ramps 0 -> 1
    // linearly over [kGuideRevealDuration] per step [live_guide_overlay_test 'the dim fades in'].
    dim.setFade(_reveal.value);
    if (_staticSections.isNotEmpty) _staticTick.value++;
    // The controller keeps the plan in force when [next] equals it.
    _published = dim.looks is GuidePlan ? dim.looks as GuidePlan : next;
  }

  // The element is deactivated in the BUILD phase of the frame that removes it (dispose
  // comes after paint), so the components stop dimming in that same frame.
  @override
  void deactivate() {
    _unpublish();
    _dropPageDrag();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _publish();
  }

  /// Takes this overlay's plan back, if it is still the one in force.
  void _unpublish() {
    final dim = _dim, mine = _published;
    _published = null;
    if (dim != null && mine != null && identical(dim.looks, mine)) dim.clear();
  }

  @override
  void dispose() {
    _unpublish();
    _dropPageDrag();
    _watchScrolls(const []);
    widget.routes.removeListener(_routeChanged);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    widget.run.removeListener(_changed);
    _reveal.dispose();
    _pulse.dispose();
    _cardOpacity.dispose();
    _staticTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final p = P.of(context);
    final run = widget.run;
    final state = run.state;
    final step = run.currentStep;
    final model = switch (state) {
      GuideAtStep(:final index) => GuideCardOnStep(number: index + 1, total: run.variant.steps.length,
        caption: run.variant.steps[index].caption(l), missingHelp: run.guide.missingTargetHelp),
      GuideOffPath() => GuideCardOffPath(tapsBack: _returnHops),
      GuideFinished() => GuideCardDone(run.guide.doneFooters),
    };
    final show = !_yieldNow && !run.isExited;
    if (!show || _published == null) _dropPageDrag();
    // The root overlay sits above every route's Material, so text here would
    // fall back to the yellow-underlined debug style. A theme text style fixes
    // that without a Material, which would take part in hit testing.
    return DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
        child: SizedBox.expand(key: _layerKey, child: LayoutBuilder(builder: (context, constraints) {
      final target = _liveTarget; // laid out after the page below: a scroll shows in this frame
      final screen = Offset.zero & constraints.biggest;
      final outline = target?.inflate(kGuideOutlineGap).intersect(screen);
      final marked = show && target != null && step != null && revealProgress == 1 &&
          outline != null && !outline.isEmpty;
      final routeOutline = target == null && show ? _route?.inflate(kGuideOutlineGap).intersect(screen) : null;
      final routeMarked = routeOutline != null && !routeOutline.isEmpty;
      // The target is hidden: scrolled off (resolved, outline empty) or not built
      // yet (then the way to it lies below).
      final offscreen = show && step != null && step.action == GuideAction.scrollThenTap &&
          (target == null ? _lazyTarget : revealProgress == 1 && (outline == null || outline.isEmpty));
      final padding = MediaQuery.paddingOf(context);
      var bounds = Rect.fromLTRB(screen.left, padding.top, screen.right,
        screen.bottom - math.max(padding.bottom, MediaQuery.viewInsetsOf(context).bottom));
      for (final r in _chrome) {
        if (r.top > screen.height / 2 && r.width > screen.width / 2) bounds = Rect.fromLTRB(bounds.left, bounds.top, bounds.right, math.min(bounds.bottom, r.top));
        if (r.top < screen.height / 4 && r.width > screen.width / 2) bounds = Rect.fromLTRB(bounds.left, math.max(bounds.top, r.bottom), bounds.right, bounds.bottom);
      }
      return Stack(children: [
        // CLAIM(lazy-skeleton-input): a published P6 plan needs input even before
        // its target exists, including newly built rows [guide_r2_review_test R4].
        if (show && _published != null)
          Positioned.fill(child: ExcludeSemantics(child: GestureDetector(
            // Skeleton ink swallows activation (tap, long press, double tap) by being
            // hit-tested: the page below is not in the hit path there, so no activation
            // recognizer is needed (a DoubleTapGestureRecognizer here left a pending
            // timer after every press). A vertical drag is handed to the page's own
            // scrollable so P6 scroll-through still works.
            onVerticalDragStart: _dragStart, onVerticalDragUpdate: (d) => _pageDrag?.drag?.update(d),
            onVerticalDragEnd: (d) { _pageDrag?.drag?.end(d); _pageDrag = null; },
            onVerticalDragCancel: () { _pageDrag?.cancel(); _pageDrag = null; },
            // The dim and the skeleton are painted by the components themselves
            // (GuideDimScope); this layer paints only the sections no component
            // paints (a control that is not a Surface/Section/Pressable, a loose chart)
            // and decides hit testing.
            child: CustomPaint(key: LiveGuideOverlay.skeletonKey,
              painter: _GuidePainter(this, p, _staticTick)),
          ))),
        if (marked || routeMarked) Positioned.fromRect(rect: (marked ? outline : routeOutline)!, child: ExcludeSemantics(child: IgnorePointer(child: DecoratedBox(
          key: LiveGuideOverlay.outlineKey,
          decoration: BoxDecoration(border: Border.all(color: kGuideMarkerColor, width: 2.5), borderRadius: R.rMd),
        )))),
        if (marked) Positioned.fromRect(rect: target, child: Semantics(
          key: LiveGuideOverlay.targetProxyKey, container: true, button: true,
          label: l.guideTargetProxy(step.caption(l).replaceAll('**', '')), onTap: _activateTarget,
          child: const SizedBox.expand(),
        )),
        if (routeMarked && _routeInfo != null) Positioned.fromRect(rect: _route!, child: Semantics(
          container: true, button: true,
          label: _routeInfo!.isTab ? l.guideTabProxy(_routeInfo!.tabName ?? '') : l.guideBackProxy,
          onTap: _activateRoute,
          child: const SizedBox.expand(),
        )),
        if (show) Positioned.fill(child: CustomMultiChildLayout(
          delegate: _GuideLayout(bounds, target != null ? outline : routeMarked ? routeOutline : target ?? (offscreen ? Rect.fromLTWH(bounds.center.dx, bounds.bottom + 10, 1, 1) : null),
            _legible, _cardFraction, _cardGeometry, true, _cardMotion, _elapsed, _scrolling, _cardOpacity, Motion.enabled(context)),
          children: [
            LayoutId(id: 'card', child: ValueListenableBuilder<double>(valueListenable: _cardOpacity, builder: (_, value, child) => Opacity(opacity: value, child: child), child: _cardMover(GuideStepCard(model: model, onExit: widget.onExit,
              onBackToGuide: state is GuideOffPath && state.lastIndex != null ? widget.onBackToGuide : null), l))),
            if (target != null || routeMarked) LayoutId(id: 'pill', child: ExcludeSemantics(child: IgnorePointer(
              child: Opacity(opacity: marked || routeMarked ? 1 : 0, child: GuideMarkerPill(l.guideTapMarker, key: marked || routeMarked ? LiveGuideOverlay.tapPillKey : null))))),
            if ((marked || offscreen) && step.action == GuideAction.scrollThenTap) LayoutId(id: 'scroll', child: ExcludeSemantics(child: IgnorePointer(
              child: RotatedBox(key: LiveGuideOverlay.scrollMarkerKey, quarterTurns: offscreen && target != null && target.bottom <= 0 ? 3 : 1,
                child: GuideMarkerPill(l.guideScrollMarker, arrow: true))))),
          ],
        )),
      ]);
    })));
  }
}

/// A drag the overlay handed to the page's scrollable. It knows when the position
/// itself ended or cancelled it (a disposed position resets the drag), so a late cancel
/// never touches a position that is gone.
class _PageDrag {
  Drag? drag;
  bool _live = true;
  void ended() => _live = false;
  void cancel() {
    if (!_live) return;
    _live = false;
    drag?.cancel();
  }
}

/// A scrollable and where it stood when the target was planned.
class _ScrollAnchor {
  final ScrollPosition position;
  final double pixels;
  const _ScrollAnchor(this.position, this.pixels);
}

/// The highlighted route-back control: the tab of the guide's start, or a pushed
/// page's back arrow. [object] receives the proxy's activation.
class _Route {
  final RenderBox? object;
  final bool isTab;

  /// A tab's name as the tab bar prints it (its Pressable's semantic label).
  final String? tabName;
  const _Route(this.object, this.isTab, this.tabName);

  factory _Route.of(Element e, {required bool isTab}) {
    final w = e.widget;
    final label = isTab && w is Pressable ? w.semanticLabel ?? onstageElements(e).map((c) => c.widget).whereType<Text>().map((t) => t.data).whereType<String>().firstOrNull : null;
    return _Route(laidOutBox(e), isTab, label);
  }
}

/// Where the card last landed, written by layout and read by drag handling.
class _CardGeometry {
  double top = 0, lower = 0, upper = 0, step = 80;
  Rect? bounds;
}

// Owns deferred opacity publication and ignores it after disposal/listener removal.
class _CardOpacity extends ValueNotifier<double> {
  _CardOpacity() : super(1);
  double _pending = 1;
  bool _scheduled = false;
  void afterLayout(double next) {
    _pending = next;
    if (_scheduled || next == value) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (hasListeners) value = _pending;
    });
  }
}

class _GuideLayout extends MultiChildLayoutDelegate {
  final Rect bounds;
  final Rect? target;
  final List<Rect> avoid;
  final double? fraction;
  final _CardGeometry geometry;
  final bool seekGap;
  final GuideCardMotion cardMotion;
  final Duration elapsed;
  final bool scrolling;
  final _CardOpacity opacity;
  final bool animate;
  _GuideLayout(this.bounds, this.target, this.avoid, this.fraction, this.geometry, this.seekGap, this.cardMotion, this.elapsed, this.scrolling, this.opacity, this.animate);
  @override
  void performLayout(Size size) {
    Rect? pill;
    if (hasChild('pill')) {
      final pillSize = layoutChild('pill', BoxConstraints.loose(bounds.size));
      pill = GuidePillLayout(target!, bounds, avoid).place(pillSize);
      positionChild('pill', pill.topLeft);
    }
    final maxWidth = math.max(0.0, bounds.width - 2 * kGuideCardGap);
    final keep = [?target, ?pill];
    // A card taller than the room beside the target caps its height (its text
    // scrolls) instead of covering the target. Laid out once: the delegate
    // asserts on a second layoutChild.
    var maxHeight = bounds.height;
    if (keep.isNotEmpty) {
      final union = keep.reduce((a, b) => a.expandToInclude(b));
      final room = math.max(union.top - bounds.top, bounds.bottom - union.bottom) - 2 * kGuideCardGap;
      if (room > 80) maxHeight = math.min(maxHeight, room);
    }
    final cardSize = layoutChild('card', BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight));
    final lower = bounds.top + kGuideCardGap;
    final upper = math.max(lower, bounds.bottom - kGuideCardGap - cardSize.height);
    final card = placeGuideCard(bounds: bounds, cardSize: cardSize, keepClear: keep, avoid: avoid, seekGap: seekGap,
      preferredTop: fraction == null ? null : lower + fraction! * (upper - lower));
    if (geometry.bounds != bounds) { cardMotion.reset(); geometry.bounds = bounds; }
    final held = cardMotion.top;
    final heldRect = held == null ? null : Rect.fromLTWH(card.left, held, cardSize.width, cardSize.height);
    final collision = heldRect != null && keep.any((r) => r.overlaps(heldRect));
    cardMotion.place(card.top, scrolling: scrolling, collision: collision, elapsed: elapsed, animate: animate);
    final top = cardMotion.top!.clamp(lower, upper);
    final placed = Rect.fromLTWH(card.left, top, cardSize.width, cardSize.height);
    positionChild('card', placed.topLeft);
    // Opacity changes after layout so it cannot rebuild during this layout pass.
    opacity.afterLayout(cardMotion.opacity);
    geometry..top = top..lower = lower..upper = upper..step = math.max(40, (upper - lower) / 5);
    if (hasChild('scroll')) {
      final markerSize = layoutChild('scroll', BoxConstraints.loose(bounds.size));
      final marker = GuidePillLayout(target!, bounds, [...avoid, placed, ?pill]).place(markerSize);
      positionChild('scroll', marker.topLeft);
    }
  }
  @override
  bool shouldRelayout(_GuideLayout old) => bounds != old.bounds || target != old.target ||
      !listEquals(avoid, old.avoid) || fraction != old.fraction || scrolling != old.scrolling || elapsed != old.elapsed || animate != old.animate;
}

/// What the overlay's input and paint layer reads at paint and hit-test time, so a
/// scroll that only moves shapes never rebuilds the overlay.
abstract interface class _GuideLayerSource {
  List<SkeletonShape> get layerShapes;
  List<Rect> get layerHoles;
  double get layerFade;
  double get layerPulse;
  Set<int> get layerStatic;
  List<Rect> get layerInk;
}

class _GuidePainter extends CustomPainter implements GuideDecoration {
  final _GuideLayerSource source;
  final P palette;
  _GuidePainter(this.source, this.palette, Listenable repaint) : super(repaint: repaint);


  @override
  void paint(Canvas canvas, Size size) {
    final painted = source.layerStatic;
    if (painted.isEmpty) return;
    paintSkeletonShapes(canvas, [for (final s in source.layerShapes) if (painted.contains(s.section)) s], palette,
        fade: source.layerFade, pulse: source.layerPulse);
  }

  @override
  bool shouldRepaint(_GuidePainter old) => !identical(old.source, source) || old.palette != palette;

  /// Input per layer (owner decision, r2): ONLY skeleton ink takes pointers; a
  /// dim layer, a hole (target, chrome) or blank scaffold lets them through to
  /// the real page.
  @override
  bool? hitTest(Offset position) {
    if (source.layerHoles.any((r) => r.contains(position))) return false;
    return source.layerInk.any((r) => r.contains(position));
  }
}
