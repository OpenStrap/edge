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
//   4. brings a target that is off screen into view ([revealTarget]): a gentle 600 ms
//      ease-in-out glide to about a third down the visible area (a jump with reduced
//      motion; any pointer-down cancels it; it is done once per step, so it never
//      fights the user's own scroll afterwards), and shows the scroll indicator while
//      the target is out of view.
//
// Markers: the "tap" label sits ABOVE its target (below only where above would leave
// the visible area) and keeps its side (hysteresis; reset on each step); a pointing hand
// beside it nudges toward the target. The mid-screen scroll indicator replaces the old
// side marker. The hand and the chevron follow the shared 1.6 s overlay clock, which runs
// only while one of them, a placeholder or the card's own motion needs it. A hand
// alone sleeps through the still half; the route-back hand nudges off path too.
//
// Input: lit and dimmed units pass the original tap to the real control once.
// Placeholder units absorb activation and hand vertical drags to the page; the card's buttons work; Android system Back and the
// NavBar arrow work. CLAIM(glide-tap-stops): Flutter absorbs the first tap on a
// moving scrollable to stop it; it activates nothing. A second tap works
// [guide_r4_test R4-fix-D1]. Accepted limitation (S6): on step pages the shield absorbs
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
import 'dart:ui' show ClipOp;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/app_localizations.dart';
import '../app_shell.dart' show AppShell;
import '../grammar.dart' show NavBar, Pressable, SubTabs;
import '../theme.dart';
import 'guide.dart';
import 'guide_hand.dart';
import 'guide_navigation.dart';
import 'guide_accordion.dart';
import 'guide_motion.dart';
import 'guide_markers.dart';
import 'guide_step_card.dart';
import 'guide_target.dart';
import 'tree_geometry.dart';

import '../skeleton/skeleton.dart';
import '../skeleton/unit_paint.dart' show hasLooseLayer, guideHoverMark;
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
  /// The mid-screen scroll indicator (shown while the target is out of view).
  static const scrollMarkerKey = ValueKey('guide-live-scroll-marker');
  static const tapHandKey = GuideTapHand.handKey;
  static const scrollChevronKey = GuideScrollIndicator.chevronKey;
  static const targetProxyKey = ValueKey('guide-live-target-proxy');
  static const routeProxyKey = ValueKey('guide-live-route-proxy');
  /// The moving hand's own transform layer.
  static const handKey = ValueKey('guide-live-hand');
  static const rippleKey = ValueKey('guide-live-ripple');

  @override
  State<LiveGuideOverlay> createState() => LiveGuideOverlayState();
}

class LiveGuideOverlayState extends State<LiveGuideOverlay> with TickerProviderStateMixin implements _GuideLayerSource, GuideHandSource, GuideHandEvents {
  final _layerKey = GlobalKey();
  late final AnimationController _reveal;
  late final AnimationController _pulse;
  final _cardMotion = GuideCardMotion();
  final _cardOpacity = _CardOpacity();
  /// The side the "tap" label took on the last frame of this step (hysteresis memory; the
  /// hand's direction).
  final _pillSide = _PillSide();
  /// The reveal's glide while a step is arriving; any pointer-down cancels it.
  RevealGlide? _glide;
  /// A touch interrupted a probe/glide, or a step returned during the user's scroll:
  /// no re-reveal.
  bool _touched = false;
  /// The card's motion time: the frame clock, so the clock controller may stop and start
  /// between motions without moving it.
  Duration get _elapsed => SchedulerBinding.instance.currentFrameTimeStamp;
  bool get _scrolling => _watchedScrolls.any((p) => p.isScrollingNotifier.value);

  /// True while the page shows at least one placeholder: the only time the pulse has
  /// anything to draw. Off path, on the Done card and on screens whose cards all sit in
  /// the lit/dim window there are none. A visible hand can still need the clock.
  bool _hasPlaceholders = false;

  @visibleForTesting
  bool get hasPlaceholders => _hasPlaceholders && !_yieldNow;

  /// True while the overlay clock runs. The clock drives the placeholder pulse and the
  /// card's move-then-restore motion and markers; it runs only while one needs it.
  @visibleForTesting
  bool get isPulsing => _pulse.isAnimating;

  bool get _wantsPulse => hasPlaceholders && Motion.enabled(context);

  Timer? _handRest;
  bool _handOnly = false;

  /// CLAIM(clock-only-when-needed): the hands (tap and scroll indicator) keep the same 1.6 s
  /// phase, sleeping through their still half. Placeholders and card motion need the
  /// full cycle [guide_r4_test R4-fix-P1b]. Marker visibility is read after layout,
  /// never written by build.
  void _syncClock() {
    if (!mounted) return;
    final layer = _layerKey.currentContext?.findRenderObject();
    final markers = layer is RenderBox && layer.hasSize ? _markersFor(layer.size) : null;
    final enabled = Motion.enabled(context);
    final continuous = enabled && (_wantsPulse || _cardMotion.isAnimating);
    // The tap hand and the scroll indicator's hand share the nudge: still for half of the cycle.
    final hand = enabled && (((markers?.marked ?? false) && !_movingNow) || ((markers?.routeMarked ?? false) && !_movingNow) || (markers?.hidden ?? false));
    if (continuous) {
      _handRest?.cancel();
      _handRest = null;
      if (_handOnly) _pulse.stop();
      _handOnly = false;
      Motion.configureGuidePulse(_pulse, enabled: true);
    } else if (hand) {
      if (!_handOnly) _pulse.stop();
      _handOnly = true;
      if (_pulse.value >= .5) {
        _pulse.stop();
        _handRest ??= Timer(kGuidePulseDuration * (1 - _pulse.value), _resumeHand);
      } else if (!_pulse.isAnimating) {
        unawaited(_pulse.animateTo(.5, duration: kGuidePulseDuration * (.5 - _pulse.value), curve: Curves.linear));
      }
    } else {
      _handRest?.cancel();
      _handRest = null;
      _handOnly = false;
      _pulse.stop();
    }
    if (!_wantsPulse) _dim?.setPulse(1);
  }

  void _resumeHand() {
    _handRest = null;
    if (!mounted) return;
    _pulse.value = 0;
    _syncClock();
  }

  _GuideMarkers _markersFor(Size size) {
    final show = !_yieldNow && !widget.run.isExited;
    final step = widget.run.currentStep;
    final target = _liveTarget;
    final screen = Offset.zero & size;
    final outline = target?.inflate(kGuideOutlineGap).intersect(screen);
    // In view means inside the VISIBLE area (between the bars), not merely on the screen: a target
    // under the app bar or the status bar is out of view [guide_r5_test R5-1a].
    final area = _boundsOf(size, MediaQuery.paddingOf(context), MediaQuery.viewInsetsOf(context).bottom, _barsTop, _barsBottom);
    final inView = target != null && _verticallyIn(target, area, _targetInChrome);
    final marked = show && target != null && step != null && revealProgress == 1 && inView &&
        outline != null && !outline.isEmpty;
    final routeOutline = target == null && show ? _route?.inflate(kGuideOutlineGap).intersect(screen) : null;
    final routeMarked = routeOutline != null && !routeOutline.isEmpty;
    final hidden = show && step != null && !(_glide?.isMoving ?? false) &&
        (target == null ? _lazyTarget : !inView);
    return _GuideMarkers(target, outline, routeOutline, marked, routeMarked, hidden,
        target != null && target.center.dy < screen.center.dy);
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
  GuideAccordionBody? _accordionHop;
  GlobalKey? _revealedHeader;
  RenderBox? _targetObject;
  /// Where the scrollables that carry [_targetObject] stood when [_target] was planned:
  /// the scroll since then moves the target by the same distance ([_liveTarget]).
  List<_ScrollAnchor> _targetScrolls = const [];
  final Set<ScrollPosition> _watchedScrolls = {};
  List<Rect> _chrome = const [], _legible = const [], _legibleText = const [];
  /// The bars that bound the usable area, in overlay coordinates: the pinned top bars and the
  /// bottom tab bar ([guideBars]); a sub-tab row is never the bottom bar.
  List<Rect> _barsTop = const [], _barsBottom = const [];
  /// The controls kept real inside placeholder cards: the previous and next step's targets and
  /// the buttons beside them [_neighbourControls].
  Set<Element> _keptControls = const {};
  // The overlay owns the hand and cached target geometry for every guide.
  final _hand = GuideHandMachine();
  Ticker? _handTicker;
  Duration? _handLast;
  final _handTick = ValueNotifier<int>(0);

  /// Every control the hover highlight marks, and the ones the hand visits now (overlay coordinates).
  List<_Tracked> _hl = const [], _visit = const [];
  List<_Tracked> _alsoTapTargets = const [];

  /// What the label sits above when that is not the whole visiting set (an open list's rows).
  List<_Tracked> _labelOver = const [];

  /// The page whose first group the guide has opened (once per arrival at the screen).
  Element? _openedPage;
  bool _expanding = false;
  Timer? _expandTimer;
  int _expandCount = 0;

  /// True while the guide opens a group and the screen takes no taps.
  @visibleForTesting
  bool get isExpanding => _expanding;

  /// How many times this overlay has opened a group (once per arrival at the screen).
  @visibleForTesting
  int get expandCount => _expandCount;

  @visibleForTesting
  GuideHandMachine get hand => _hand;

  @override
  GuideHandMachine get handMachine => _hand;

  @override
  Color get handColor => _hl.length > 1 || (_step?.multi != null) ? C.blue : kGuideMarkerColor;

  @override
  List<GuideHandTarget> get handTargets => _cachedTargets;

  /// How many of the visiting set's targets are in view now.
  @visibleForTesting
  int get visitCount => _cachedVisits.length;

  /// The text the label keeps clear of (overlay coordinates).
  @visibleForTesting
  List<Rect> get legibleTextRects => _legibleText;

  /// Animated guides use the moving aid whenever their focus is resolved.
  bool get _movingNow =>
      Motion.enabled(context) && _hl.isNotEmpty;

  @visibleForTesting
  bool get handActive => _handTicker?.isActive ?? false;

  /// The visiting set's rects that are in view now, in visiting order.
  List<Rect> _visitRects() {
    final layer = _layerKey.currentContext?.findRenderObject();
    if (layer is! RenderBox || !layer.hasSize) return const [];
    final area = _boundsOf(layer.size, MediaQuery.paddingOf(context), MediaQuery.viewInsetsOf(context).bottom, _barsTop, _barsBottom);
    return [for (final t in _visit) if (_verticallyIn(t.live, area, _targetInChrome || _route != null)) t.live];
  }

  GuideHandMode _handMode() {
    final multi = _accordionHop == null ? _step?.multi : null;
    if (multi == null) return GuideHandMode.single;
    if (multi.opens != null) return identical(_openedPage, _page) && !_expanding ? GuideHandMode.list : GuideHandMode.opening;
    return _visit.length <= 1 ? GuideHandMode.single : multi.visit == GuideVisit.list ? GuideHandMode.list : GuideHandMode.row;
  }

  /// What changed since the hover was last bound. A scroll moves positions only: the hovers are local
  /// to their components and the hand keeps its loop. CLAIM(hover-scroll-cheap) [guide_r7_fix1_test F1].
  bool _handRebindDirty = true, _handPositionsDirty = true;
  List<Rect> _cachedVisits = const [];
  List<GuideHandTarget> _cachedTargets = const [];

  /// The hover of each target of [_hl] (null: no component paints it); the components that hold them.
  List<GuideHover?> _hoverAt = const [];
  Map<RenderBox, GuideHover> _bound = const {};
  int _geometryRevision = -1;
  List<RenderBox> _cachedObjects = const [];

  /// Positions only (a scroll, a replan of the same targets): where the targets are in the overlay now.
  /// It never notifies a component. The hand restarts only when the visiting set changes size.
  void _updateHandPositions() {
    final visits = _visitRects();
    final resized = visits.length != _cachedVisits.length;
    _cachedVisits = visits;
    _cachedTargets = [for (final t in _hl) GuideHandTarget(t.live, t.radius)];
    if (resized) _hand.restart();
  }

  /// Binds each target's hover to the component that paints it. A binding that still matches is kept
  /// (same object, same opacity); the components hear about it only when a binding changed.
  void _rebindHovers() {
    // A fresh loop only when the hand is sent to different controls; a highlighted control that came or
    // went (a header scrolled out of view) leaves the loop alone.
    final visiting = [for (final t in _visit) t.object];
    if (!listEquals(visiting, _cachedObjects)) _hand.restart();
    _cachedObjects = visiting;
    final bindings = <RenderBox, GuideHover>{};
    final at = <GuideHover?>[];
    for (final target in _hl) {
      final mark = guideHoverMark(target.object);
      if (mark == null || !mark.attached || !mark.hasSize || bindings.containsKey(mark)) {
        at.add(null);
        continue;
      }
      final local = MatrixUtils.transformRect(target.object.getTransformTo(mark), Offset.zero & target.object.size);
      final radius = math.min(target.radius, local.shortestSide / 2);
      final kept = _bound[mark];
      final hover = kept != null && !kept.isDisposed && kept.rect == local && kept.radius == radius && kept.color == handColor
          ? kept
          : (GuideHover(local, radius, handColor)..value = guideHoverOpacity((target.live.center - _hand.tip).distance));
      bindings[mark] = hover;
      at.add(hover);
    }
    _hoverAt = at;
    if (!mapEquals(bindings, _bound)) {
      _bound = bindings;
      _dim?.setHovers(bindings, owner: this);
    }
  }

  GuideStep? _handStep;
  GuideHandMode? _handModeNow;

  /// Starts, retargets or stops the hand to match the step on screen. Runs after every plan.
  void _syncHand() {
    if (!mounted) return;
    final layer = _layerKey.currentContext?.findRenderObject();
    final markers = layer is RenderBox && layer.hasSize ? _markersFor(layer.size) : null;
    final want = _movingNow && ((markers?.marked ?? false) || (markers?.routeMarked ?? false));
    if (!want) {
      _handTicker?.stop();
      _handLast = null;
      _handStep = null;
      _handModeNow = null;
      _dim?.clearHovers(owner: this);
      _hoverAt = const [];
      _bound = const {};
      _cachedObjects = const [];
      _cachedVisits = const [];
      _handRebindDirty = true;
      _handPositionsDirty = true;
      return;
    }
    if (_handRebindDirty) {
      _handRebindDirty = false;
      _rebindHovers();
      _handPositionsDirty = true;
    }
    if (_handPositionsDirty) {
      _handPositionsDirty = false;
      _updateHandPositions();
    }
    if (_cachedVisits.isEmpty) {
      _handTicker?.stop();
      _handLast = null;
      return;
    }
    final mode = _handMode();
    if (_handStep != _step || _handModeNow != mode) {
      final newStep = _handStep != _step;
      _handStep = _step;
      _handModeNow = mode;
      _hand.events = this;
      _hand.setMode(mode);
      if (newStep) _hand.restart();
    }
    final ticker = _handTicker ??= createTicker(_handFrame);
    if (!ticker.isActive) {
      _handLast = null;
      ticker.start();
    }
  }

  void _handFrame(Duration elapsed) {
    final last = _handLast;
    _handLast = elapsed;
    final dt = last == null ? 0.0 : (elapsed - last).inMicroseconds / 1000;
    if (_yieldNow || widget.run.isExited) return;
    _hand.advance(dt, _cachedVisits);
    for (var i = 0; i < _hoverAt.length && i < _cachedTargets.length; i++) {
      final hover = _hoverAt[i];
      if (hover == null) continue;
      if (hover.isDisposed) {
        _handRebindDirty = true;
        continue;
      }
      hover.value = guideHoverOpacity((_cachedTargets[i].rect.center - _hand.tip).distance);
    }
    _handTick.value++;
  }

  @override
  void handPressed(int index) {
    if (_hand.mode == GuideHandMode.opening) _openFirstGroup();
  }

  /// The one app action a guide may take: tap the control [GuideMultiTarget.opens] names, once per
  /// arrival at the screen, then let the screen settle with its input blocked. It never selects,
  /// saves or starts anything.
  void _openFirstGroup() {
    final page = _page, step = _step;
    final opens = step?.multi?.opens;
    if (page == null || opens == null || identical(_openedPage, page) || _yieldNow) return;
    final l = AppLocalizations.of(context)!;
    _openedPage = page;
    if (step!.multi!.alreadyOpen?.resolve(page, l).isNotEmpty ?? false) {
      // The user opened a group between the plan and this press: pressing the header would close it.
      _plannedSignature = null;
      _markDirty();
      setState(() {});
      return;
    }
    final found = opens.resolve(page, l).firstOrNull;
    if (found == null || !found.renderObject.attached) return;
    final position = found.renderObject.localToGlobal(found.renderObject.size.center(Offset.zero));
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
    if (!result.path.any((entry) => identical(entry.target, found.renderObject))) return;
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: -3, position: position));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: -3, position: position));
    _expandCount++;
    _expanding = true;
    _expandTimer?.cancel();
    _expandTimer = Timer(Motion.guideOpenSettle, _expanded);
    _markDirty();
    setState(() {});
  }

  void _expanded() {
    _expandTimer = null;
    if (!mounted) return;
    _expanding = false;
    _plannedSignature = null;
    _markDirty();
    setState(() {});
  }

  /// The step's target is itself a bar control (a tab, a sub-tab): it lives outside the usable
  /// area by design, so it counts as in view.
  bool _targetInChrome = false;

  /// True when [resolution]'s target sits inside a chrome widget of [page] (a tab, a sub-tab, a title).
  static bool _isInChrome(Element? page, TargetResolution? resolution) {
    if (page == null || resolution is! TargetFound) return false;
    for (final e in onstageElements(page)) {
      if (!isGuideChromeWidget(e.widget)) continue;
      final box = laidOutBox(e);
      if (box == null) continue;
      for (RenderObject? o = resolution.renderObject; o != null; o = o.parent) {
        if (identical(o, box)) return true;
      }
    }
    return false;
  }
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

  /// Whether the plan was made with motion on: the highlight set exists only then.
  bool? _planMotion;
  Element? _signedPage;
  Size? _signedSize;

  void _markDirty() => _planDirty = true;

  /// Guide-owned clocks only repaint. Layout hooks and scheduled widget builds
  /// invalidate the plan; another animation still triggers geometry discovery.
  /// CLAIM(pulse-no-plan-walk) CLAIM(hand-cached-paths) [guide_r7_test].
  bool _ownedMotionFrame(Element? page, Size size) {
    if ((!_pulse.isAnimating && !handActive) || _planDirty || _plannedSignature == null) return false;
    if (!identical(page, _signedPage) || size != _signedSize) return false;
    final others = SchedulerBinding.instance.transientCallbackCount - (_pulse.isAnimating ? 1 : 0) - (handActive ? 1 : 0) - (_reveal.isAnimating ? 1 : 0);
    if (others > 0) return false; // another animation moves the page: read it as before
    return true;
  }

  @override
  List<SkeletonShape> get layerShapes => paintedShapes;
  List<Rect> get _navigationHoles {
    final layer = _layerKey.currentContext?.findRenderObject();
    final page = _page;
    if (layer is! RenderBox || page == null) return const [];
    final headers = (_walk ?? _walkPage(page)).headers;
    return [for (final e in headers)
      if (e.mounted)
        if (laidOutBox(e) case final RenderBox box)
          rectInRoot(box, layer).intersect(visibleBoundsInRoot(box, layer))];
  }

  /// Which page elements the holes and the ink come from. The page's elements only
  /// change through a build, so pulse repaints and hover hit-tests reuse one walk
  /// until the next build has run; every rect is still read from the live transform.
  ({List<Element> headers, List<Element> components, List<RenderParagraph> paragraphs})? _walk;
  int _pageWalks = 0;
  @visibleForTesting
  int get pageWalks => _pageWalks;
  ({List<Element> headers, List<Element> components, List<RenderParagraph> paragraphs}) _walkPage(Element page) {
    _pageWalks++;
    final headers = <Element>[], components = <Element>[], paragraphs = <RenderParagraph>[];
    for (final e in onstageElements(page)) {
      if (e.widget is GuideNavigationHeader || isGuideChromeWidget(e.widget)) headers.add(e);
    }
    void visit(Element element) {
      // Chrome never carries ink, whenever it was built (the plan may not have seen it yet).
      if (isGuideChromeWidget(element.widget)) return;
      if (_paintsItself(element.widget) || isGuideControl(element.widget)) {
        components.add(element);
        return;
      }
      final object = element is RenderObjectElement ? element.renderObject : null;
      if (object is RenderParagraph && object.attached && object.hasSize) {
        paragraphs.add(object);
        return;
      }
      element.debugVisitOnstageChildren(visit);
    }
    visit(page);
    final walk = (headers: headers, components: components, paragraphs: paragraphs);
    if (!_walkHeld) _walk = walk;
    return walk;
  }

  bool _walkHeld = false;
  void _buildScheduled() {
    _walk = null;
    if (_walkHeld) return;
    _walkHeld = true; // Not reused until the frame that runs the build has ended.
    // A build scheduled during layout or paint runs in the next frame, so hold across two.
    final scheduler = SchedulerBinding.instance;
    scheduler.addPostFrameCallback((_) {
      scheduler.addPostFrameCallback((_) { _walkHeld = false; _walk = null; });
      scheduler.scheduleFrame();
    });
  }

  @override
  List<Rect> get layerHoles {
    final layer = _layerKey.currentContext?.findRenderObject();
    if (layer is! RenderBox) return const [];
    return [
      ..._navigationHoles,
      for (final box in [..._keepBoxes, ..._chromeBoxes, ?_routeInfo?.object,
          for (final e in _keptControls) if (e.mounted) ?laidOutBox(e)])
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

    final walk = _walk ?? _walkPage(page);
    for (final element in walk.components) {
      if (!element.mounted) continue;
      final box = laidOutBox(element);
      if (box != null && looks.lookOf(element) == GuideUnitLook.skeleton) add(box);
    }
    for (final object in walk.paragraphs) {
      if (!object.attached || !object.hasSize) continue;
      if (looks.looseLookOf(object) == GuideUnitLook.skeleton) add(object);
    }
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
    return planned == null ? null : _shifted(planned, _targetScrolls);
  }

  /// [planned] moved by how far each of [scrolls] has moved since it was planned.
  static Rect _shifted(Rect planned, List<_ScrollAnchor> scrolls) {
    if (scrolls.isEmpty) return planned;
    var moved = Offset.zero;
    for (final a in scrolls) {
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
    _handPositionsDirty = true;
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
  static bool _onScreen(Rect t, Rect v, bool targetIsBar) => _verticallyIn(t, v, targetIsBar) &&
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
    if (!identical(widget.routes.page, _searchingPage)) _glide?.cancel();
    _publish();
    _scrolled();
  }

  @override
  void initState() {
    super.initState();
    GuideBuildChanges.addListener(_markDirty);
    GuideBuildChanges.addListener(_buildScheduled);
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
      _dim?.discoverFor(this, false);
      _dim = dim;
      _dim?.discoverFor(this, true);
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
  RenderBox? _hitTarget(Offset position, Offset point) {
    final candidates = _step?.multi != null && _accordionHop == null
        ? <RenderBox?>[for (final target in _hl) if (target.live.contains(point)) target.object]
        : <RenderBox?>[if (_target?.contains(point) ?? false) _targetObject];
    // Offered alternatives complete the same action in either motion mode.
    // Readable context and neighbouring controls do not count as completion.
    if (_accordionHop == null) {
      candidates.addAll([
        for (final target in _alsoTapTargets) if (target.live.contains(point)) target.object,
      ]);
    }
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
    for (final target in candidates) {
      if (target != null && target.attached && result.path.any((entry) => identical(entry.target, target))) return target;
    }
    return null;
  }

  bool _hitsTarget(Offset position) {
    final layer = _layerKey.currentContext?.findRenderObject();
    return layer is RenderBox && _hitTarget(position, layer.globalToLocal(position)) != null;
  }

  final _downControls = <int, RenderBox>{};

  void _pointer(PointerEvent event) {
    _markDirty();
    // The page is the user's from the first touch: a glide stops where it is.
    if (event is PointerDownEvent && _glide != null) {
      if (_glide!.canMove) _touched = true; // late content must not take the page back
      _glide!.cancel();
    }
    final layer = _layerKey.currentContext?.findRenderObject();
    if (layer is! RenderBox || !layer.hasSize || !layer.attached || _yieldNow) return;
    final point = layer.globalToLocal(event.position);
    if (event is PointerDownEvent) {
      final target = _hitTarget(event.position, point);
      if (target != null) { _downs[event.pointer] = point; _downControls[event.pointer] = target; }
    }
    if (event is PointerCancelEvent) { _downs.remove(event.pointer); _downControls.remove(event.pointer); }
    if (event is PointerMoveEvent) {
      final down = _downs[event.pointer];
      if (down != null && (point - down).distance > kTouchSlop) { _downs.remove(event.pointer); _downControls.remove(event.pointer); }
    }
    if (event is PointerUpEvent) {
      final down = _downs.remove(event.pointer);
      final target = _downControls.remove(event.pointer);
      if (_accordionHop == null && down != null && (point - down).distance <= kTouchSlop && identical(target, _hitTarget(event.position, point))) {
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
    // A route back that is chrome (the NavBar arrow, a tab, a sub-tab) leaves every content unit
    // dimmed, the route's neighbouring card too; only a route that is itself content (a Settings
    // row) keeps its neighbours lit [guide_r5_scenes_test R5-3].
    final chromeRoute = hop == null || hop.kind != GuideHopKind.page;
    final route = back;
    final keepers = [?back];
    final plan = planSkeleton(page, keep: keepers, chrome: [?tabBar],
        dim: DimPolicy(focus: back, placeholders: false, neighboursLit: !chromeRoute, navigationTarget: backIsTab, focusObject: backElement == null ? null : laidOutBox(backElement)));
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
  /// when the target is really in it [guide_input_regression_test F1].
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
  /// is being built or finalized [guide_input_regression_test F2].
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
      final revision = _dim?.geometryRevision ?? 0;
      if (_geometryRevision != revision) {
        _geometryRevision = revision;
        _markDirty();
        _handRebindDirty = true;
      }
      _plan();
      _syncClock();
      _syncHand();
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
    final motionOn = Motion.enabled(context);
    if (motionOn != _planMotion) {
      _planMotion = motionOn;
      _planDirty = true;
    }
    if (_ownedMotionFrame(page, layer.size)) return;
    _walk = null; // The page is read again: so are its holes and ink.
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
      for (final e in builtElements(page)) {
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
      }
    }
    // Discovery retries use stable text/extents: rebuilding cached list
    // children during an unsuccessful search must not restart that search.
    _watchScrolls(scrollPositions);
    final signature = Object.hashAll(discoveryContent);
    final scrollSignature = Object.hashAll(scrolls);
    final planSignature = (page, layer.size, builtCount, Object.hashAll(content), widget.run,
      widget.run.state, l, _searchingPage, _revealedPage, _revealedStep, motionOn);
    _signatureChecks++;
    _planDirty = false;
    _signedPage = page;
    _signedSize = layer.size;
    if (_plannedSignature == planSignature) return;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    // Avoid full-tree planning at animation cadence. Request a trailing frame
    // so even the last throttled layout is eventually measured. New pages,
    // popups and completed animations are always reflected immediately.
    // The overlay's own clock (placeholder pulse, card motion) is not a page animation.
    final animating = SchedulerBinding.instance.transientCallbackCount >
        (_reveal.isAnimating ? 1 : 0) + (_pulse.isAnimating ? 1 : 0) + (handActive ? 1 : 0);
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
    final rawResolution = page == null || step == null ? null : step.target.resolve(page, l);
    final behind = rawResolution is TargetBehindAccordion ? rawResolution : null;
    final accordionHop = behind?.accordions.first;
    final effectiveTarget = behind?.header ?? step?.target;
    final hopChanged = _revealedHeader != accordionHop?.headerKey;
    final newStep = _revealedPage != page || _revealedStep != step || hopChanged;
    if (hopChanged) { _touched = false; _pillSide.reset(); }
    if (_step != step) {
      _cardMotion.reset();
      _pillSide.reset();
      // CLAIM(reveal-touch-scope): matching another step on the same page while
      // the user scrolls is discovery, not a new arrival [guide_r4_test R4-fix-C6b].
      _touched = identical(page, _page) && _scrolling && !(_glide?.isMoving ?? false);
    }
    if (page != null && step == null) {
      _revealedPage = null;
      _revealedStep = null;
      _reveal.stop();
      if (_reveal.value != 1) _reveal.value = 1; // off path: the dim is there at full strength
    }
    final box = page == null ? null : laidOutBox(page);
    final resolution = page == null || effectiveTarget == null ? null : effectiveTarget.resolve(page, l);
    final targetNow = box != null && resolution is TargetFound
        ? MatrixUtils.transformRect(box.getTransformTo(layer), resolution.rect) : null;
    final bars = page == null || box == null ? null : guideBars(page);
    final barXf = box?.getTransformTo(layer);
    final barsTop = bars == null ? const <Rect>[] : [for (final r in bars.top) MatrixUtils.transformRect(barXf!, r)];
    final barsBottom = bars == null ? const <Rect>[] : [for (final r in bars.bottom) MatrixUtils.transformRect(barXf!, r)];
    final area = _boundsOf(layer.size, MediaQuery.paddingOf(context), MediaQuery.viewInsetsOf(context).bottom, barsTop, barsBottom);
    final outside = targetNow != null && !_onScreen(targetNow, area, _isInChrome(page, resolution));
    // The page is revealed once per step, and again when LATE CONTENT moves the target
    // away (an async read lands above it). It is never re-revealed after the USER
    // scrolled: the marker shows the way and the overlay must not scroll the page back
    // under their finger. [_scrollAtReveal] is where every scrollable stood when the
    // last reveal settled; any other position is the user's.
    if (_searchingPage == null && _scrollAtReveal == null) _scrollAtReveal = scrollSignature;
    final retry = _searchingPage == null && _scrollAtReveal == scrollSignature &&
        ((targetNow == null && _searchSignature != signature) ||
         (outside && _lastRevealRect != targetNow));
    if (page != null && step != null && (newStep || retry) && !_touched) {
      _revealedPage = page;
      _revealedStep = step;
      _revealedHeader = accordionHop?.headerKey;
      _searchSignature = signature;
      _lastRevealRect = targetNow;
      _scrollAtReveal = null;
      // Also reveal plain-tap targets built just beyond the viewport: a target
      // must be visible before the card asks the user to press it.
      final token = Object();
      _searchToken = token;
      _searchingPage = page;
      _glide?.abandon();
      final glide = RevealGlide(
        area: area,
        duration: motion(context, Motion.guideScroll),
        anchor: kGuideScrollAnchor,
      );
      _glide = glide;
      unawaited(revealTarget(page, effectiveTarget!, l, isCurrent: _StepGate(this, token, page, step), glide: glide).whenComplete(() {
          if (identical(_glide, glide)) _glide = null;
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
    var keptControls = <Element>{};
    var alsoTapTargets = <_Tracked>[];
    var hl = <_Tracked>[], visitSet = <_Tracked>[], labelSet = <_Tracked>[];
    var chrome = <Rect>[];
    var legible = <Rect>[], legibleText = <Rect>[];
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
            if (step.alsoTap.contains(content)) {
              alsoTapTargets.add(_Tracked(found.renderObject, intoOverlay(found.rect),
                  _anchorsOf(found.renderObject, scrollStates), _radiusOf(found.renderObject)));
            }
          }
        }
        // Live status (title row, running timer) stays readable and clear of the card.
        final status = liveStatusRects(page);
        keep.addAll(status);
        final localChrome = defaultSkeletonChrome(page);
        chrome = localChrome.map(intoOverlay).toList();
        // Every target the hover highlight marks stays real, including the visiting set.
        if (Motion.enabled(context)) {
          final multi = accordionHop == null ? step.multi : null;
          final all = multi == null ? <TargetFound>[TargetFound(rect, renderObject: renderObject)] : [...multi.targets.resolve(page, l)];
          var visit = all;
          final opens = multi?.opens;
          if (multi != null && opens != null) {
            // A group the user opened first counts as the arrival's opening: the guide never presses
            // a toggle over it. CLAIM(guide-never-undoes) [guide_r7_fix1_test F2].
            if (!identical(_openedPage, page) && (multi.alreadyOpen?.resolve(page, l).isNotEmpty ?? false)) _openedPage = page;
            final opened = identical(_openedPage, page) && !_expanding;
            final after = opened ? (multi.afterOpen?.resolve(page, l) ?? all) : opens.resolve(page, l).take(1).toList();
            visit = after;
            if (opened) all.addAll([for (final f in after) if (!all.any((a) => identical(a.renderObject, f.renderObject))) f]);
          }
          for (final f in all) {
            keep.add(f.rect);
            keepBoxes.add(f.renderObject);
          }
          _Tracked track(TargetFound f) => _Tracked(f.renderObject, intoOverlay(f.rect), _anchorsOf(f.renderObject, scrollStates), _radiusOf(f.renderObject));
          hl = [for (final f in all) track(f)];
          visitSet = [for (final f in visit) track(f)];
          if (multi != null && opens != null && identical(_openedPage, page) && !_expanding) {
            labelSet = [for (final f in multi.labelAfterOpen?.resolve(page, l) ?? const <TargetFound>[]) track(f)];
          }
        }
        // The previous and next step's controls (and the buttons beside them) stay real.
        keptControls = _neighbourControls(page, step, l);
        // The kept previous/next controls are real and tappable: the card keeps clear of them too.
        final keptRects = [for (final e in keptControls) if (laidOutBox(e) case final RenderBox b when b.hasSize) rectInRoot(b, box).intersect(visibleBoundsInRoot(b, box))];
        final pageText = <Rect>[];
        legible = [...legibleContent(page, keep: keep, textOut: pageText), ...status, for (final r in keptRects) if (!r.isEmpty) r].map(intoOverlay).toList();
        legibleText = [...pageText, ...status].map(intoOverlay).toList();
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
      final expansions = destination == null ? 0 : widget.routes.accordionHopsTo(
          destination, widget.run.variant.steps[last].target, l);
      _returnHops = hops.isEmpty && expansions == 0 ? null : hops.length + expansions;
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
    if (hl.isEmpty && route != null && routeInfo?.object != null) {
      final routeObject = routeInfo!.object!;
      hl = [_Tracked(routeObject, route, _anchorsOf(routeObject, scrollStates), _radiusOf(routeObject))];
      visitSet = hl;
    }
    final changed = !listEquals([for (final t in _hl) t.planned], [for (final t in hl) t.planned]) || _page != page || _step != step || _target != target || _yielding != (page == null) ||
      !listEquals(_chrome, chrome) || !listEquals(_legible, legible) || !listEquals(_legibleText, legibleText) || _route != route ||
      (_skeletonPlan == null) != (skeleton == null);
    _page = page;
    _step = step;
    final captionChanged = _accordionHop?.title != accordionHop?.title;
    _accordionHop = accordionHop;
    _target = target;
    _lazyTarget = resolution is TargetNotBuilt;
    _targetObject = resolution is TargetFound ? resolution.renderObject : null;
    _targetScrolls = _anchorsOf(_targetObject, scrollStates);
    _shapes = shapes;
    _skeletonPlan = skeleton;
    _hasPlaceholders = _collapsed || (skeleton?.units.any((u) => u.skeleton) ?? false);
    _keepBoxes = keepBoxes;
    _keptControls = keptControls;
    final sameTargets = _hl.length == hl.length && [for (var i = 0; i < hl.length; i++) i].every((i) =>
        identical(_hl[i].object, hl[i].object) && _hl[i].radius == hl[i].radius && _hl[i].size == hl[i].size);
    _hl = hl;
    _alsoTapTargets = alsoTapTargets;
    _visit = visitSet;
    _labelOver = labelSet;
    if (sameTargets) { _handPositionsDirty = true; } else { _handRebindDirty = true; }
    _staticSections = staticSections;
    _routeInfo = route == null ? null : routeInfo;
    _chromeBoxes = [
      if (page != null) for (final e in onstageElements(page))
        if (isGuideChromeWidget(e.widget))
          if (laidOutBox(e) case final RenderBox chromeBox) chromeBox,
    ];
    _chrome = chrome;
    _barsTop = barsTop;
    _targetInChrome = _isInChrome(page, resolution);
    _barsBottom = barsBottom;
    _legible = legible;
    _legibleText = legibleText;
    _route = route;
    _yielding = page == null;
    _publish();
    if (changed || captionChanged) setState(() {});
  }

  /// The controls of the PREVIOUS and NEXT steps' targets that this page shows, with the buttons
  /// beside them (the other controls of the same row): they stay real, readable and tappable,
  /// dimmed at most, even inside a placeholder card (owner, round 5 item 7: after Discard the
  /// staged row's Keep / Discard / Edit became grey bars). CLAIM(neighbour-targets-real)
  /// [guide_r5_scenes_test R5-7].
  Set<Element> _neighbourControls(Element page, GuideStep step, AppLocalizations l) {
    final steps = widget.run.variant.steps;
    final at = steps.indexOf(step);
    final out = <Element>{};
    for (final i in [at - 1, at + 1]) {
      if (at < 0 || i < 0 || i >= steps.length) continue;
      final other = steps[i];
      final found = <TargetFound>[];
      for (final target in [other.target, ...other.alsoKeep]) {
        if (target.resolve(page, l) case final TargetFound f) found.add(f);
      }
      for (final content in other.alsoTap) {
        // "Every pressable row" names no particular control.
        if (content is UnscopedGuideContent) continue;
        found.addAll(content.resolve(page, l));
      }
      for (final f in found) {
        final controls = _controlsAround(page, f.renderObject);
        out.addAll(controls);
        out.addAll(_buttonsBeside(controls));
      }
    }
    return out;
  }

  /// Every control element of [page] whose box holds [object] and is about its size (the control
  /// itself and the wrappers drawn tight around it: a page-wide gesture detector is no part of it).
  static List<Element> _controlsAround(Element page, RenderBox object) {
    final found = <Element>[];
    for (final e in onstageElements(page)) {
      if (!isGuideControl(e.widget)) continue;
      final box = laidOutBox(e);
      if (box == null || !box.hasSize || !object.hasSize) continue;
      if (box.size.width > object.size.width + 24 || box.size.height > object.size.height + 24) continue;
      for (RenderObject? o = object; o != null; o = o.parent) {
        if (identical(o, box)) { found.add(e); break; }
      }
    }
    return found;
  }

  /// The other controls of the row [controls] sit in: the nearest Flex around the outermost one,
  /// when it holds no card (a row of buttons, not a page column).
  static Set<Element> _buttonsBeside(List<Element> controls) {
    if (controls.isEmpty) return const {};
    Element? row;
    controls.first.visitAncestorElements((a) {
      if (a.widget is Flex) { row = a; return false; }
      return true;
    });
    final flex = row;
    if (flex == null) return const {};
    final inside = onstageElements(flex).toList();
    if (inside.any((e) => isGuideCard(e.widget))) return const {};
    return {for (final e in inside) if (isGuideControl(e.widget)) e};
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
    final next = GuidePlan.from(_page, plan, keep: _keepBoxes, keepControls: _keptControls, skeletonAll: _collapsed);
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
    if (dim != null && mine != null && identical(dim.looks, mine)) {
      _handTicker?.stop();
      _handLast = null;
      _hoverAt = const [];
      _bound = const {};
      _handRebindDirty = true;
      dim.clear();
    }
  }

  @override
  void dispose() {
    GuideBuildChanges.removeListener(_markDirty);
    GuideBuildChanges.removeListener(_buildScheduled);
    _dim?.discoverFor(this, false);
    _unpublish();
    _dropPageDrag();
    _watchScrolls(const []);
    widget.routes.removeListener(_routeChanged);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    widget.run.removeListener(_changed);
    _expandTimer?.cancel();
    _handTicker?.dispose();
    _dim?.clearHovers(owner: this);
    _handTick.dispose();
    _reveal.dispose();
    _handRest?.cancel();
    _pulse.dispose();
    _glide?.abandon();
    _cardOpacity.dispose();
    _pillSide.dispose();
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
        caption: _accordionHop == null ? run.variant.steps[index].captionFor(still: !Motion.enabled(context)).of(l)
            : l.guideExpandAccordion(_accordionHop!.title), missingHelp: run.guide.missingTargetHelp),
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
      final markers = _markersFor(constraints.biggest);
      final target = markers.target, outline = markers.outline, routeOutline = markers.routeOutline;
      final marked = markers.marked, routeMarked = markers.routeMarked, hidden = markers.hidden, up = markers.up;
      final screen = Offset.zero & constraints.biggest;
      final bounds = _boundsOf(screen.size, MediaQuery.paddingOf(context), MediaQuery.viewInsetsOf(context).bottom, _barsTop, _barsBottom);
      // Every animated guide uses the moving hand; reduced motion keeps the static look.
      final moving = (marked || routeMarked) && _movingNow;
      Rect? targetUnion;
      // The label and the card go by the targets the hand visits now (a picker with every group header
      // marked would otherwise leave them no room).
      for (final t in (_visit.isEmpty ? _hl : _visit)) {
        final r = t.live;
        if (r.overlaps(screen)) targetUnion = targetUnion == null ? r : targetUnion.expandToInclude(r);
      }
      Rect? labelUnion;
      for (final t in _labelOver) {
        final r = t.live;
        if (r.overlaps(screen)) labelUnion = labelUnion == null ? r : labelUnion.expandToInclude(r);
      }
      final union = moving ? targetUnion?.inflate(kGuideOutlineGap).intersect(screen) : null;
      final labelAnchor = moving ? labelUnion?.inflate(kGuideOutlineGap).intersect(screen) : null;
      final cardTarget = union ?? outline;
      final tapLabel = _accordionHop != null ? l.guideExpandAccordion(_accordionHop!.title) : _step?.multi != null ? (_step!.multi!.label?.of(l) ?? l.guideTapOneOf) : l.guideTapMarker;
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
        if (!moving && (marked || routeMarked)) Positioned.fromRect(rect: (marked ? outline : routeOutline)!, child: ExcludeSemantics(child: IgnorePointer(child: DecoratedBox(
          key: LiveGuideOverlay.outlineKey,
          decoration: BoxDecoration(border: Border.all(color: kGuideMarkerColor, width: 2.5), borderRadius: R.rMd),
        )))),
        if (marked) Positioned.fromRect(rect: target!, child: Semantics(
          key: LiveGuideOverlay.targetProxyKey, container: true, button: true,
          label: l.guideTargetProxy((_accordionHop == null ? step!.captionFor(still: !Motion.enabled(context)).of(l) : l.guideExpandAccordion(_accordionHop!.title)).replaceAll('**', '')), onTap: _activateTarget,
          child: const SizedBox.expand(),
        )),
        if (routeMarked && _routeInfo != null) Positioned.fromRect(rect: _route!, child: Semantics(
          key: LiveGuideOverlay.routeProxyKey, container: true, button: true,
          label: _routeInfo!.isTab ? l.guideTabProxy(_routeInfo!.tabName ?? '') : l.guideBackProxy,
          onTap: _activateRoute,
          child: const SizedBox.expand(),
        )),
        // Content waits for the picker's brief expansion; navigation remains tappable.
        if (show && _expanding) Positioned.fill(child: GestureDetector(onTap: () {},
          child: CustomPaint(painter: _GuideNavigationShield(this), child: const SizedBox.expand()))),
        if (moving) Positioned.fill(child: ExcludeSemantics(child: IgnorePointer(child: RepaintBoundary(
          child: CustomPaint(key: LiveGuideOverlay.rippleKey, painter: GuideHandPainter(this, _handTick)))))),
        if (moving) Positioned(left: 0, top: 0, child: ExcludeSemantics(child: IgnorePointer(child: RepaintBoundary(
          child: GuideHandCursor(key: LiveGuideOverlay.handKey, source: this, clock: _handTick))))),
        if (show) Positioned.fill(child: CustomMultiChildLayout(
          delegate: _GuideLayout(bounds, target != null ? cardTarget : routeMarked ? routeOutline : target ?? (hidden ? Rect.fromLTWH(bounds.center.dx, bounds.bottom + 10, 1, 1) : null),
            _legible, _cardFraction, _cardGeometry, true, _cardMotion, _elapsed, _scrolling, _cardOpacity, Motion.enabled(context),
            _pillSide, marked || routeMarked, moving, labelAnchor, _legibleText),
          children: [
            LayoutId(id: 'card', child: ValueListenableBuilder<double>(valueListenable: _cardOpacity, builder: (_, value, child) => Opacity(opacity: value, child: child), child: _cardMover(GuideStepCard(model: model, onExit: widget.onExit,
              onBackToGuide: state is GuideOffPath && state.lastIndex != null ? widget.onBackToGuide : null), l))),
            if (target != null || routeMarked) LayoutId(id: 'pill', child: ExcludeSemantics(child: IgnorePointer(
              child: RepaintBoundary(child: Opacity(opacity: marked || routeMarked ? 1 : 0, child: GuideMarkerPill(moving || _accordionHop != null ? tapLabel : l.guideTapMarker,
                key: marked || routeMarked ? LiveGuideOverlay.tapPillKey : null,
                color: moving ? handColor : kGuideMarkerColor,
                leading: moving ? null : RepaintBoundary(child: GuideTapHand(clock: _pulse, side: _pillSide)))))))),
            if (hidden) LayoutId(id: 'indicator', child: ExcludeSemantics(child: IgnorePointer(
              child: RepaintBoundary(child: GuideScrollIndicator(key: LiveGuideOverlay.scrollMarkerKey, text: l.guideScrollMarker, clock: _pulse, up: up))))),
          ],
        )),
      ]);
    })));
  }
}

/// One geometry snapshot shared by build and the post-layout clock decision.
class _GuideMarkers {
  final Rect? target, outline, routeOutline;
  final bool marked, routeMarked, hidden, up;
  const _GuideMarkers(this.target, this.outline, this.routeOutline, this.marked, this.routeMarked, this.hidden, this.up);
}

/// The area the card, the pill and the auto-scroll may use: the screen between the top chrome
/// (title, NavBar, sub-tabs) and the bottom chrome (tab bar), above the keyboard.
///
/// [top] and [bottom] are the BARS ([guideBars]): chrome is told by what it is, not by where it
/// lies. Alarm's Mon-Sun row is a SubTabs inside the scrolling content below mid-screen; the old
/// geometric rule took it for the tab bar and cut the room above it [guide_r5_test R5-1b].
Rect _boundsOf(Size screen, EdgeInsets padding, double bottomInset, List<Rect> top, List<Rect> bottom) {
  var bounds = Rect.fromLTRB(0, padding.top, screen.width, screen.height - math.max(padding.bottom, bottomInset));
  for (final r in bottom) {
    if (r.width > screen.width / 2) bounds = Rect.fromLTRB(bounds.left, bounds.top, bounds.right, math.min(bounds.bottom, r.top));
  }
  for (final r in top) {
    if (r.top < screen.height / 4 && r.width > screen.width / 2) bounds = Rect.fromLTRB(bounds.left, math.max(bounds.top, r.bottom), bounds.right, bounds.bottom);
  }
  return bounds;
}

/// True when [target] lies fully inside [area] vertically (a horizontal overhang is a row's own
/// side scroll; a vertical indicator would say nothing about it). A target that is itself a bar
/// (a tab, a sub-tab) lives outside the area by design and counts as in view.
bool _verticallyIn(Rect target, Rect area, bool targetIsBar) =>
    targetIsBar || target.top >= area.top - .5 && target.bottom <= area.bottom + .5;

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

/// A target of the hover highlight: its render box, where it was planned, which scrollables carry it
/// and its own corner radius.
class _Tracked {
  final RenderBox object;
  final Rect planned;
  final List<_ScrollAnchor> scrolls;
  final double radius;

  /// The object's size when planned: a different size means a different hover rect.
  final Size size;
  _Tracked(this.object, this.planned, this.scrolls, this.radius) : size = object.hasSize ? object.size : Size.zero;

  /// Where it stands now (a scroll since the plan moved it by the same distance).
  Rect get live => LiveGuideOverlayState._shifted(planned, scrolls);
}

/// The corner radius of the box [object] draws (the decorated box around or inside it that is as big
/// as it is), so the highlight follows the target's own shape; a modest default when there is none.
double _radiusOf(RenderBox object) {
  double? from(RenderObject? o) {
    for (var depth = 0; o != null && depth < 5; depth++) {
      if (o is RenderDecoratedBox && o.hasSize && (o.size.width - object.size.width).abs() < 3 && (o.size.height - object.size.height).abs() < 3) {
        final d = o.decoration;
        if (d is BoxDecoration && d.shape == BoxShape.rectangle) {
          final r = d.borderRadius?.resolve(TextDirection.ltr);
          if (r != null) return r.topLeft.x;
        }
      }
      RenderObject? next;
      o.visitChildren((c) => next ??= c);
      o = next;
    }
    return null;
  }

  var found = from(object);
  for (RenderObject? up = object.parent; found == null && up != null && up is! RenderView; up = up.parent) {
    if (up is RenderDecoratedBox) {
      found = from(up);
      break;
    }
  }
  return found ?? R.md;
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

/// The side the "tap" label took on the last frame, kept for the next frame's hysteresis
/// ([remembered], read in layout) and published to the hand after layout so it points
/// toward the target ([afterLayout]; a notifier must not fire in the middle of layout).
class _PillSide extends ValueNotifier<GuidePillSide> {
  _PillSide() : super(GuidePillSide.above);
  GuidePillSide? remembered;
  GuidePillSide _pending = GuidePillSide.above;
  bool _scheduled = false;

  void reset() => remembered = null;

  void afterLayout(GuidePillSide? side) {
    remembered = side;
    if (side == null) return;
    _pending = side;
    if (_scheduled || side == value) return;
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
  final _PillSide pillSide;

  /// The pill shows (target on screen, reveal ended): only then does it have a side to keep.
  final bool pillVisible;

  /// The label sits top centre above the targets' union.
  final bool centerPill;

  /// What the label sits above when that is less than [target] (an open list's rows, not the search bar).
  final Rect? labelTarget;

  /// The text the label slides clear of (it may lie over a plain background).
  final List<Rect> avoidText;
  _GuideLayout(this.bounds, this.target, this.avoid, this.fraction, this.geometry, this.seekGap, this.cardMotion, this.elapsed, this.scrolling, this.opacity, this.animate, this.pillSide, this.pillVisible, [this.centerPill = false, this.labelTarget, this.avoidText = const []]);
  @override
  void performLayout(Size size) {
    Rect? pill;
    if (hasChild('pill')) {
      // Runtime accordion titles can wrap. Keep the same six-pixel edge margin
      // even when the wrapped label consumes all available width.
      final pillSize = layoutChild('pill', BoxConstraints.loose(Size(math.max(0, bounds.width - 12), bounds.height)));
      if (centerPill) {
        final anchor = labelTarget ?? target!;
        final lo = (anchor.left + 6).clamp(bounds.left + 6, bounds.right).toDouble();
        final hi = math.min(anchor.right - 6 - pillSize.width, bounds.right - pillSize.width - 6);
        final centred = (anchor.center.dx - pillSize.width / 2).clamp(bounds.left + 6, math.max(bounds.left + 6, bounds.right - pillSize.width - 6)).toDouble();
        final above = anchor.top - pillSize.height - 4;
        final below = anchor.bottom + 4;
        final aboveFits = above >= bounds.top;
        final belowFits = below + pillSize.height <= bounds.bottom;
        final keepBelow = pillVisible && pillSide.remembered == GuidePillSide.below && belowFits &&
            !(aboveFits && above - bounds.top >= GuidePillLayout.kGuidePillBand);
        final preferred = keepBelow || !aboveFits && belowFits ? GuidePillSide.below : GuidePillSide.above;
        // Centred over the choices; if that covers legible text, slide along them to the nearest clear
        // spot; failing that, stand a little further off. Text never changes the side: only the
        // off-screen/chrome rule above does (owner: always above). Failing all, the centred spot.
        // CLAIM(label-clear-of-text) [guide_r7_fix1_test F6]. CLAIM(label-side-kept) [guide_r7_fix1_test N1].
        final h = pillSize.height;
        Rect at(GuidePillSide side, double x, double away) => Rect.fromLTWH(x,
            (side == GuidePillSide.above ? above - away : below + away).clamp(bounds.top, math.max(bounds.top, bounds.bottom - h)).toDouble(),
            pillSize.width, h);
        bool clear(Rect r) => !avoidText.any((a) => a.overlaps(r.deflate(1)));
        bool fits(GuidePillSide side, double away) => side == GuidePillSide.above ? above - away >= bounds.top : below + away + h <= bounds.bottom;
        Rect? found;
        for (var away = 0.0; away <= 48 && found == null; away += 4) {
          if (!fits(preferred, away)) continue;
          for (var step = 0; step <= 150 && found == null; step++) {
            for (final x in [centred + 4.0 * step, centred - 4.0 * step]) {
              if (x < math.min(lo, centred) || x > math.max(hi, centred) || !clear(at(preferred, x, away))) continue;
              found = at(preferred, x, away);
              break;
            }
          }
        }
        pill = found ?? at(preferred, centred, 0);
        positionChild('pill', pill.topLeft);
        pillSide.afterLayout(pillVisible ? preferred : null);
      } else {
        final layout = GuidePillLayout(target!, bounds, pillVisible ? pillSide.remembered : null);
        pill = layout.place(pillSize);
        positionChild('pill', pill.topLeft);
        pillSide.afterLayout(pillVisible ? layout.sideFor(pillSize) : null);
      }
    }
    // The scroll indicator sits mid-screen; the card keeps clear of it.
    Rect? indicator;
    if (hasChild('indicator')) {
      final indicatorSize = layoutChild('indicator', BoxConstraints.loose(bounds.size));
      indicator = Rect.fromCenter(center: bounds.center, width: indicatorSize.width, height: indicatorSize.height);
      positionChild('indicator', indicator.topLeft);
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
    final card = placeGuideCard(bounds: bounds, cardSize: cardSize, keepClear: keep, avoid: [...avoid, ?indicator], seekGap: seekGap,
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
  }
  @override
  bool shouldRelayout(_GuideLayout old) => bounds != old.bounds || target != old.target ||
      !listEquals(avoid, old.avoid) || fraction != old.fraction || scrolling != old.scrolling || elapsed != old.elapsed || animate != old.animate ||
      pillVisible != old.pillVisible || centerPill != old.centerPill || labelTarget != old.labelTarget || !listEquals(avoidText, old.avoidText);
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
    // Nothing the overlay paints reaches into a hole: chrome, the target, the route back and the kept
    // controls are never covered, whatever extent a scrolled-away unit reports (the owner's dimmed NavBar:
    // a shape from a unit above the list ran down into it) [guide_r5_scenes_test R5-4g].
    canvas.save();
    for (final hole in source.layerHoles) {
      canvas.clipRect(hole, clipOp: ClipOp.difference);
    }
    paintSkeletonShapes(canvas, [for (final s in source.layerShapes) if (painted.contains(s.section)) s], palette,
        fade: source.layerFade, pulse: source.layerPulse);
    canvas.restore();
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

// During the picker's brief automatic expansion, navigation still takes taps.
class _GuideNavigationShield extends CustomPainter implements GuideDecoration {
  final LiveGuideOverlayState source;
  _GuideNavigationShield(this.source);
  @override
  void paint(Canvas canvas, Size size) {}
  @override
  bool hitTest(Offset position) => !source._navigationHoles.any((r) => r.contains(position));
  @override
  bool shouldRepaint(_GuideNavigationShield oldDelegate) => false;
}

/// Whether the reveal search started for ([page], [step]) is still wanted: this
/// overlay is mounted, still on that search, the run is alive and still on that
/// page and step. A class (not a closure) so the heavy-calc guard can resolve it.
class _StepGate implements RevealGate {
  final LiveGuideOverlayState _state;
  final Object _token;
  final Element _page;
  final GuideStep _step;
  const _StepGate(this._state, this._token, this._page, this._step);

  @override
  bool get isOpen =>
      _state.mounted &&
      identical(_state._searchToken, _token) &&
      !_state.widget.run.isExited &&
      identical(_state.widget.routes.page, _page) &&
      identical(_state.widget.run.currentStep, _step);
}
