// GUIDE DIM SCOPE: the seam through which a guide run tells the app's own
// components how to draw themselves, so the dim and the skeleton are part of the
// SAME widget subtree as the content. That way they scroll, fling and
// overscroll-stretch with it, in every frame (owner design, 2026-11-14).
//
//  * [GuideDimScope] sits once at the app root. Its [GuideDimController] holds the
//    plan: which component is dimmed, which is skeleton.
//  * `Surface`, `Section`, `Pressable` and `GuideBox` (grammar.dart) wrap themselves in
//    [GuideUnitMark] (../skeleton/unit_paint.dart), which asks the plan at PAINT
//    time and paints its own foreground. Loose text inside a scrollable is painted
//    by [GuideScrollBehavior]'s layer, inside the scrollable and its overscroll
//    stretch.
//  * The overlay (live_guide_overlay.dart) computes the plan and writes it with
//    [GuideDimController.setLooks]; it keeps the card, outline, pill, scroll marker
//    and per-layer hit testing, and paints only what no component paints itself.
//
// CLAIM(dim-in-tree): a component painted under a plan paints its own dim in the
// frame it moves in [guide_r2_scroll_dim_test, guide_r2_structural_test].
// CLAIM(dim-notifies-on-change): the controller notifies only when the plan changed
// [guide_r2_structural_test 'plan equality'].

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import '../skeleton/skeleton.dart';
import '../skeleton/unit_paint.dart' show isIconParagraph;
import 'tree_geometry.dart';

/// How a guide run wants one component drawn. A component absent from the plan
/// (the target, caption-named content, chrome, the route-back control) is drawn
/// as usual and has no look.
enum GuideUnitLook {
  /// One translucent whole-component layer (kDimOpacity of the scaffold colour).
  dim,

  /// Placeholders for the component's content (bars and blocks), with the heading
  /// drawn dimmed at the top-left.
  skeleton,
}

/// The plan, as the components see it. An interface, not a function type, so the
/// heavy-calc guard can resolve the call. Identity is the component's own
/// element ([unit] is the BuildContext of the Surface / Section / Pressable).
abstract interface class GuideUnitLooks {
  /// The look for [unit], or null when the component stays as it is.
  GuideUnitLook? lookOf(BuildContext unit);
}

/// A [GuideUnitLooks] that also decides loose paragraphs (text in no component).
abstract interface class GuideLooseLooks implements GuideUnitLooks {
  /// The look for the loose [paragraph], or null when it stays as it is.
  GuideUnitLook? looseLookOf(RenderParagraph paragraph);
}

/// Holds the current [GuideUnitLooks] and tells the components when it changes.
class GuideDimController extends ChangeNotifier {
  GuideUnitLooks? _looks;
  bool _disposed = false;

  /// True after [dispose]: a run that ends after its app root went away (a test
  /// tear-down, an app shutting down) clears into nothing instead of failing.
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    _disposed = true;
    _looks = null;
    _pulse.dispose();
    super.dispose();
  }

  /// The plan in force; null when no guide is dimming anything.
  GuideUnitLooks? get looks => _looks;

  final _pulse = ValueNotifier<double>(1);

  /// The shared placeholder pulse (a multiplier on the pigments' value, 1 = rest).
  double get pulse => _pulse.value;

  /// Its own listenable. A component listens to it ONLY while it paints placeholders, so a
  /// tick repaints placeholders and nothing else; it never reaches [addListener]'s
  /// plan listeners (lit and dimmed components, loose layers).
  /// CLAIM(pulse-own-listenable) [guide_r3_pulse_test].
  ValueListenable<double> get pulseListenable => _pulse;

  void setPulse(double value) {
    if (_disposed) return;
    _pulse.value = value;
  }

  double _fade = 1;

  /// How far the dim has faded in, 0..1 (linear, owner: 800 ms per step). The
  /// placeholders are not faded: they appear at once.
  double get fade => _fade;

  /// Sets [fade] and repaints the components (they never rebuild).
  void setFade(double value) {
    final next = value.clamp(0.0, 1.0);
    if (_disposed || next == _fade) return;
    _fade = next;
    notifyListeners();
  }

  /// Replaces the plan and repaints the components that read it. A plan that gives
  /// every component the same look as the one in force ([GuidePlan.sameLooks])
  /// replaces it silently: nothing is marked for paint, so a scroll that only brings
  /// in more dimmed content costs no repaint beyond the scroll's own.
  void setLooks(GuideUnitLooks? looks) {
    if (_disposed) return;
    final old = _looks;
    if (identical(old, looks)) return;
    final same = old is GuidePlan && looks is GuidePlan && old.sameLooks(looks);
    _looks = looks;
    if (same) return;
    // A plan replacing a plan repaints at the START of the next frame (the plan is made
    // after a frame, and marking paint dirty then would leave that frame's tree dirty);
    // a first plan or a cleared one repaints now.
    if (old == null || looks == null) {
      notifyListeners();
    } else if (!_pending) {
      _pending = true;
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        _pending = false;
        if (!_disposed) notifyListeners();
      });
    }
  }

  bool _pending = false;

  /// Removes the plan: every component draws as usual.
  void clear() => setLooks(null);
}

/// Provided once at the app root (above the Navigator). Components inside read
/// the plan from here.
///
/// An [InheritedWidget] that carries the controller and does NOT rebuild anything when
/// the plan changes: each component listens to the controller itself and repaints
/// (never rebuilds), so a plan change costs one repaint per component and a run can
/// end while the tree is being torn down.
class GuideDimScope extends InheritedWidget {
  final GuideDimController controller;
  const GuideDimScope({super.key, required this.controller, required super.child});

  /// The controller of the nearest scope, or null outside one. Registers a
  /// dependency on the scope widget (it changes only when the controller object does).
  static GuideDimController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GuideDimScope>()?.controller;

  /// As [maybeOf] without the dependency: for the components and the overlay, which
  /// listen to the controller themselves.
  static GuideDimController? controllerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<GuideDimScope>()?.controller;

  @override
  bool updateShouldNotify(GuideDimScope oldWidget) => !identical(controller, oldWidget.controller);
}


/// The plan the overlay writes: its decisions per component and per loose
/// paragraph, plus the rules for what the plan has not seen (a component built by
/// a scroll after the plan was made).
///
/// A component the plan has not seen is dimmed (skeleton when the whole page is
/// collapsed, [fallback]) if it is the OUTERMOST component on the guided [page] and
/// overlaps none of the [keep] boxes: so freshly scrolled-in content is never bright
/// for the frames before the next plan.
class GuidePlan implements GuideLooseLooks {
  final Element? page;
  final Map<Element, GuideUnitLook> _byComponent;
  final Map<RenderParagraph, GuideUnitLook> _byParagraph;
  final Set<Element> _seen;
  final Set<RenderParagraph> _seenLoose;
  final List<RenderBox> _keep;
  final GuideUnitLook fallback;

  GuidePlan._(this.page, this._byComponent, this._byParagraph, this._seen, this._seenLoose, this._keep, this.fallback);

  /// A plan from [plan] on [page]. [keep]: the live boxes that stay legible
  /// (target, caption-named content), against which unseen components are tested.
  /// [skeletonAll]: the P6 collapse, so unseen components are skeleton too.
  factory GuidePlan.from(Element? page, SkeletonPlan plan, {
    List<RenderBox> keep = const [],
    bool skeletonAll = false,
  }) {
    final components = <Element, GuideUnitLook>{};
    final paragraphs = <RenderParagraph, GuideUnitLook>{};
    for (final u in plan.units) {
      final look = u.skeleton ? GuideUnitLook.skeleton : GuideUnitLook.dim;
      final c = u.component;
      // A control that is not a Surface / Section / Pressable cannot paint itself: the
      // overlay paints its section (live_guide_overlay.dart). Keyed here anyway, harmless.
      if (c != null) components[c] = look;
      final p = u.paragraph;
      if (p != null) paragraphs[p] = look;
    }
    return GuidePlan._(page, components, paragraphs, plan.seen, plan.seenLoose, keep,
        skeletonAll ? GuideUnitLook.skeleton : GuideUnitLook.dim);
  }

  /// True when no component and no loose paragraph would be painted differently under
  /// [other]. A component only the plan in force or only [other] names is compared
  /// with what the other plan does to a component it never saw (its [fallback]), so
  /// content that scrolled in and is dimmed like the fallback does not count.
  bool sameLooks(GuidePlan other) {
    if (fallback != other.fallback) return false;
    return _agree(_byComponent, _seen, other._byComponent, other._seen) &&
        _agree(_byParagraph, _seenLoose, other._byParagraph, other._seenLoose);
  }

  GuideUnitLook? _effective<K>(Map<K, GuideUnitLook> byKey, Set<K> seen, K key) =>
      byKey[key] ?? (seen.contains(key) ? null : fallback);

  bool _agree<K>(Map<K, GuideUnitLook> a, Set<K> aSeen, Map<K, GuideUnitLook> b, Set<K> bSeen) {
    for (final key in a.keys) {
      if (_effective(a, aSeen, key) != _effective(b, bSeen, key)) return false;
    }
    for (final key in b.keys) {
      if (_effective(a, aSeen, key) != _effective(b, bSeen, key)) return false;
    }
    return true;
  }

  @override
  GuideUnitLook? lookOf(BuildContext unit) {
    if (unit is! Element) return null;
    final known = _byComponent[unit];
    if (known != null) return known;
    if (_seen.contains(unit)) return null;
    return _unseen(unit);
  }

  @override
  GuideUnitLook? looseLookOf(RenderParagraph paragraph) {
    final known = _byParagraph[paragraph];
    if (known != null) return known;
    if (_seenLoose.contains(paragraph) || isIconParagraph(paragraph)) return null;
    final pageBox = page == null ? null : laidOutBox(page!);
    if (pageBox == null || !_isUnder(paragraph, pageBox) || _overlapsKeep(paragraph)) return null;
    return fallback;
  }

  GuideUnitLook? _unseen(Element unit) {
    final page = this.page;
    if (page == null) return null;
    var onPage = false, outermost = true;
    unit.visitAncestorElements((a) {
      if (identical(a, page)) {
        onPage = true;
        return false;
      }
      if (isGuideComponent(a.widget)) {
        outermost = false;
        return false;
      }
      return true;
    });
    if (!onPage || !outermost) return null;
    final box = unit.renderObject;
    if (box is! RenderBox || !box.hasSize || _overlapsKeep(box)) return null;
    return fallback;
  }

  bool _isUnder(RenderObject object, RenderObject ancestor) {
    for (RenderObject? o = object; o != null; o = o.parent) {
      if (identical(o, ancestor)) return true;
    }
    return false;
  }

  bool _overlapsKeep(RenderObject object) {
    if (object is! RenderBox || !object.hasSize || !object.attached) return true;
    final rect = MatrixUtils.transformRect(object.getTransformTo(null), Offset.zero & object.size);
    for (final k in _keep) {
      if (!k.attached || !k.hasSize) continue;
      if (MatrixUtils.transformRect(k.getTransformTo(null), Offset.zero & k.size).overlaps(rect)) return true;
    }
    return false;
  }
}
