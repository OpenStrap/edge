// GUIDE TARGET (phase 1): how a guide finds "the thing to tap" on the real,
// laid-out screen.
//
// A target is a translated label or a Key. Resolution reads the LIVE element
// and render tree under a root (no snapshots), in the root's coordinates, and
// always answers with exactly one of four outcomes (sealed [TargetResolution]),
// so a guide can never silently point at nothing.
//
// Mating parts: `Skeletonize` (../skeleton/skeleton.dart) resolves its `keep`
// targets with [GuideTarget.resolve] after every layout; the guide run and
// the review views (test/support/guide_view.dart) call [revealTarget] to scroll
// a lazy screen to the target. Both read rects in the same root space.

import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart' show Pressable;
import 'guide_text.dart';
import 'guide_accordion.dart';
import 'tree_geometry.dart';

/// What a target resolves to: always exactly one of the four, never null.
sealed class TargetResolution {
  const TargetResolution();
}

final class TargetFound extends TargetResolution {
  /// In the coordinate space of the root element passed to `resolve`.
  final Rect rect;
  /// The actual control used for pointer hit-path validation by live guides.
  final RenderBox renderObject;
  const TargetFound(this.rect, {required this.renderObject});
}

/// No match in the built tree, but a scrollable under the root could still
/// build one lazily (a list with extent left to discover).
base class TargetNotBuilt extends TargetResolution {
  final GuideTarget target;
  final String detail;
  const TargetNotBuilt(this.target, this.detail);
}

/// The target exists in a closed body. Ordered outermost first, each header is
/// one real user tap. This refines NotBuilt so callers still abstain from tapping
/// the hidden target while the live overlay shows the first expansion hop.
final class TargetBehindAccordion extends TargetNotBuilt {
  final List<GuideAccordionBody> accordions;
  const TargetBehindAccordion(GuideTarget target, this.accordions)
      : super(target, 'the target is behind a collapsed accordion');
  GuideTarget get header => GuideTarget.key(accordions.first.headerKey);
}

/// No match, and nothing left to build: the target is not on this screen
/// (also: matches that are Offstage; a `within` scope that is itself absent).
final class TargetAbsent extends TargetResolution {
  final GuideTarget target;
  final String detail;
  const TargetAbsent(this.target, this.detail);
}

/// More than one distinct control matched.
final class TargetAmbiguous extends TargetResolution {
  final GuideTarget target;

  /// Distinct controls (Text + Semantics of one control count once).
  final int count;
  final String detail;
  const TargetAmbiguous(this.target, this.count, this.detail);
}

/// What one lookup found: the element a target stands for and its rect, or the
/// failure to report. Internal; [GuideTarget.resolve] flattens it.
sealed class _Lookup {
  const _Lookup();
}

final class _Hit extends _Lookup {
  final Element element;
  final Rect rect;
  const _Hit(this.element, this.rect);
}

final class _Miss extends _Lookup {
  final TargetResolution failure;
  const _Miss(this.failure);
}

sealed class GuideTarget {
  const GuideTarget();

  /// By translated label, matched (exactly after trimming, ignoring letter
  /// case: Home prints its ring labels upper-cased, home_screen.dart:1215)
  /// against `Text` plain text and `Semantics` labels. The resolved rect grows to the nearest tappable
  /// `Pressable` ancestor (grammar.dart:54; one with an `onTap` - a `Surface`
  /// wraps a tap-less Pressable only for its 44 pt minimum) when there is one.
  /// Matches that belong to one control (same nearest Pressable, or one
  /// semantics node) count ONCE. [within] scopes the match to the subtree of
  /// another target (a Key, a Section...).
  factory GuideTarget.label(
    GuideText label, {
    GuideTarget? within,
  }) =>
      _LabelTarget([label], within);

  /// As [label], accepting any of several labels (a control whose text depends
  /// on state, e.g. "Set your own zones" / "Edit your own zones").
  factory GuideTarget.anyLabel(
    List<GuideText> alternatives, {
    GuideTarget? within,
  }) =>
      _LabelTarget(alternatives, within);

  /// As [label], but where several controls read the same words (one "Discard"
  /// per pending row) the FIRST one in screen order is the target instead of
  /// the result being ambiguous: a step then points at exactly one control.
  /// CLAIM(first-of-many): document order = top to bottom on a column, so "first"
  /// is the topmost [guide_target_test 'firstLabel picks the topmost of several'].
  factory GuideTarget.firstLabel(GuideText label, {GuideTarget? within}) =>
      _LabelTarget([label], within, firstOfMany: true);

  /// The first control matching any of the offered labels, in document order.
  factory GuideTarget.firstAnyLabel(List<GuideText> alternatives, {GuideTarget? within}) =>
      _LabelTarget(alternatives, within, firstOfMany: true);

  /// By Key: the keyed widget's own render box; no growing.
  factory GuideTarget.key(Key key) => _KeyTarget(key);

  /// Resolve in the laid-out tree under [root], in [root]'s coordinates.
  TargetResolution resolve(Element root, AppLocalizations l) {
    final rootBox = laidOutBox(root);
    if (rootBox == null) {
      return TargetNotBuilt(this, 'the root is not laid out yet');
    }
    return switch (_lookup(root, rootBox, root, l)) {
      _Hit(:final rect, :final element) => _resolutionOf(element, rect),
      _Miss(:final failure) => failure,
    };
  }

  TargetResolution _resolutionOf(Element element, Rect rect) {
    final closed = <GuideAccordionBody>[];
    element.visitAncestorElements((a) {
      final w = a.widget;
      if (w is GuideAccordionBody && w.offstage) closed.add(w);
      return true;
    });
    return closed.isEmpty ? TargetFound(rect, renderObject: laidOutBox(element)!)
        : TargetBehindAccordion(this, closed.reversed.toList());
  }

  /// Looks for the target inside [scope] (a descendant-or-self of [root]).
  _Lookup _lookup(Element root, RenderBox rootBox, Element scope, AppLocalizations l);

  /// "Absent" vs "NotBuilt": a scrollable under [scope] that still has extent
  /// before or after its viewport could build children no one has asked for.
  _Miss _miss(Element scope, String what) {
    if (_hasUnexploredScrollable(scope)) {
      return _Miss(TargetNotBuilt(this, '$what; a scrollable could still build it'));
    }
    return _Miss(TargetAbsent(this, what));
  }
}

final class _KeyTarget extends GuideTarget {
  final Key key;
  const _KeyTarget(this.key);

  @override
  _Lookup _lookup(Element root, RenderBox rootBox, Element scope, AppLocalizations l) {
    final hits = <Element>[];
    for (final e in builtElements(scope)) {
      if (e.widget.key == key) hits.add(e);
    }
    if (hits.isEmpty) return _miss(scope, 'no widget with key $key');
    if (hits.length > 1) {
      return _Miss(TargetAmbiguous(this, hits.length, '${hits.length} widgets share key $key'));
    }
    final box = laidOutBox(hits.single);
    if (box == null) return _miss(scope, 'the widget with key $key has no laid-out box');
    return _Hit(hits.single, rectInRoot(box, rootBox));
  }
}

final class _LabelTarget extends GuideTarget {
  final List<GuideText> alternatives;
  final GuideTarget? within;
  final bool firstOfMany;
  const _LabelTarget(this.alternatives, this.within, {this.firstOfMany = false});

  @override
  _Lookup _lookup(Element root, RenderBox rootBox, Element scope, AppLocalizations l) {
    final wanted = {for (final f in alternatives) f.of(l).trim().toUpperCase()}..remove('');
    final quoted = [for (final f in alternatives) '"${f.of(l).trim()}"'].join(' / ');

    var searchIn = scope;
    final w = within;
    if (w != null) {
      switch (w._lookup(root, rootBox, scope, l)) {
        case _Hit(:final element):
          searchIn = element;
        case _Miss(:final failure):
          // A missing scope is the target's absence too: never fall back to an
          // unscoped match (it may be the wrong duplicate).
          return _Miss(switch (failure) {
            TargetAbsent(:final detail) => TargetAbsent(this, 'scope of $quoted: $detail'),
            TargetNotBuilt(:final detail) => TargetNotBuilt(this, 'scope of $quoted: $detail'),
            TargetAmbiguous(:final count, :final detail) =>
              TargetAmbiguous(this, count, 'scope of $quoted: $detail'),
            TargetFound() => failure,
          });
      }
    }

    // Candidates: Text and Semantics labels that equal a wanted label.
    final matches = <Element>[];
    for (final e in builtElements(searchIn)) {
      final widget = e.widget;
      final text = switch (widget) {
        Text() => widget.data ?? widget.textSpan?.toPlainText(),
        Semantics() => widget.properties.label,
        _ => null,
      };
      if (text != null && wanted.contains(text.trim().toUpperCase())) matches.add(e);
    }
    if (matches.isEmpty) return _miss(searchIn, 'nothing on screen reads $quoted');

    final controls = _controlsOf(root, matches);
    if (controls.length > 1 && !firstOfMany) {
      return _Miss(TargetAmbiguous(this, controls.length, '${controls.length} controls read $quoted'));
    }
    final control = controls.keys.first;
    final box = laidOutBox(control) ?? laidOutBox(controls.values.first);
    if (box == null) return _miss(searchIn, '$quoted has no laid-out box');
    return _Hit(control, rectInRoot(box, rootBox));
  }
}

/// One control per match: the nearest tappable Pressable, else the outermost
/// matching Semantics, else the match itself; a control inside another matched
/// control is dropped. Control element -> its first match.
Map<Element, Element> _controlsOf(Element root, List<Element> matches) {
  // One control = one nearest tappable Pressable, else one outermost matching
  // Semantics, else the match itself. CLAIM(one-control-once): a Text and the
  // Semantics label of the same control never count twice [guide_target_test].
  final matchSet = matches.toSet();
  final controls = <Element, Element>{}; // control element -> first match
  for (final m in matches) {
    Element? pressable;
    Element? outermostSemantics = matchSet.contains(m) && m.widget is Semantics ? m : null;
    m.visitAncestorElements((a) {
      if (a.widget is Pressable && (a.widget as Pressable).onTap != null) {
        pressable = a;
        return false;
      }
      if (matchSet.contains(a) && a.widget is Semantics) outermostSemantics = a;
      return !identical(a, root);
    });
    controls.putIfAbsent(pressable ?? outermostSemantics ?? m, () => m);
  }
  // A Semantics label WRAPPING the control that also prints it (day_review.dart's
  // `reviewButton`: Semantics > Opacity > BigButton > Text) is that control, not a
  // second one: drop every control that sits inside another matched control.
  // CLAIM(one-control-once): ↳ [guide_target_test 'a labelled wrapper around a pressable text is one control'].
  final nested = <Element>{};
  for (final outer in controls.keys) {
    for (final inner in controls.keys) {
      if (identical(outer, inner)) continue;
      var inside = false;
      inner.visitAncestorElements((a) {
        if (identical(a, outer)) inside = true;
        return !inside && !identical(a, root);
      });
      if (inside) nested.add(inner);
    }
  }
  nested.forEach(controls.remove);
  return controls;
}

/// EVERY control on the page that reads [label] (a Text or Semantics label equal
/// to it, after trimming, ignoring case), each once: the per-row "Discard"s, the
/// bin of every session. [GuideTarget.label] reports these as ambiguous and
/// [GuideTarget.firstLabel] picks one; a caption that says "every row has its own"
/// needs them all.
List<TargetFound> everyControlLabelled(Element root, GuideText label, AppLocalizations l) {
  final rootBox = laidOutBox(root);
  final wanted = label.of(l).trim().toUpperCase();
  if (rootBox == null || wanted.isEmpty) return const [];
  final matches = <Element>[];
  for (final e in onstageElements(root)) {
    final widget = e.widget;
    final text = switch (widget) {
      Text() => widget.data ?? widget.textSpan?.toPlainText(),
      Semantics() => widget.properties.label,
      _ => null,
    };
    if (text != null && text.trim().toUpperCase() == wanted) matches.add(e);
  }
  final found = <TargetFound>[];
  for (final entry in _controlsOf(root, matches).entries) {
    final box = laidOutBox(entry.key) ?? laidOutBox(entry.value);
    if (box == null) continue;
    final rect = rectInRoot(box, rootBox).intersect(visibleBoundsInRoot(box, rootBox));
    if (!rect.isEmpty) found.add(TargetFound(rect, renderObject: box));
  }
  return found;
}

/// Every [ScrollableState] under [scope] (onstage), outer before inner.
List<ScrollableState> _scrollablesUnder(Element scope) {
  final out = <ScrollableState>[];
  for (final e in builtElements(scope)) {
    if (e is StatefulElement && e.state is ScrollableState) out.add(e.state as ScrollableState);
  }
  return out;
}

bool _hasUnexploredScrollable(Element scope) => _scrollablesUnder(scope).any((s) {
      final p = s.position;
      return p.hasPixels && p.hasContentDimensions && (p.extentBefore > 0 || p.extentAfter > 0);
    });

// CLAIM(reveal-frame-boundary): scroll discovery waits for Flutter's next
// layout, without rebuilding/finalizing the app inside a post-frame callback
// [guide_target_test bounded scroll discovery; live_guide_overlay_test navigation].
Future<void> _nextLayout() {
  final binding = WidgetsBinding.instance;
  binding.scheduleFrame();
  return binding.endOfFrame;
}

/// Whether a reveal is still wanted: false once the user navigated away or ended
/// the guide. An interface rather than a closure so that the heavy-calc guard
/// (test/guards) can resolve the call.
abstract interface class RevealGate {
  bool get isOpen;
}

/// How [revealTarget] brings a found target into view when it is off screen: a gentle
/// ease-in-out scroll that leaves the target [anchor] of the way down [area] (round 4).
/// One per reveal. [cancel] (any user pointer-down) stops it where it is, and a glide
/// cancelled before it starts never starts: the page is the user's from then on. With a zero
/// [duration] the page jumps, to the same place.
///
/// A class, not a callback, so the heavy-calc guard (test/guards) can resolve the calls.
/// CLAIM(reveal-glide) [guide_r4_test R4-1a, R4-1d].
class RevealGlide {
  /// The part of the screen the target should end up in, in global coordinates (the visible
  /// area between the chrome).
  final Rect area;

  /// 0 = the top of [area], 1 = the bottom: where the target's centre goes.
  final double anchor;

  /// Room kept above the target for the "tap" label.
  final double labelRoom;
  final Duration duration;

  RevealGlide({required this.area, required this.duration, this.anchor = 1 / 3, this.labelRoom = 32});

  final List<ScrollPosition> _moving = [];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  bool _probing = false;

  /// A touch owns the page only once discovery probes or a glide can move it.
  bool get canMove => !_cancelled && (_probing || _moving.isNotEmpty);
  bool get isMoving => !_cancelled && _moving.isNotEmpty;

  /// Stops every scroll of this glide where it stands and keeps it from starting more (the
  /// user touched the screen).
  void cancel() {
    _cancelled = true;
    for (final position in List.of(_moving)) {
      if (position.hasPixels && position.context.storageContext.mounted) position.jumpTo(position.pixels);
    }
  }

  /// Stops owning the scroll: nothing more starts, and nothing is touched (the page may be
  /// gone). For a superseded or disposed glide.
  void abandon() {
    _cancelled = true;
    _moving.clear();
  }

  /// The [ScrollPosition.ensureVisible] alignment that puts an object of [objectHeight]
  /// at the wanted place when the scrollable's viewport starts at [viewportTop] and is
  /// [viewportHeight] tall (global coordinates).
  double alignmentFor(double objectHeight, double viewportTop, double viewportHeight) {
    var top = area.top + area.height * anchor - objectHeight / 2;
    top = math.max(top, area.top + labelRoom);
    top = math.min(top, area.bottom - objectHeight);
    top = math.max(top, area.top);
    final slack = viewportHeight - objectHeight;
    if (slack <= 0) return 0;
    return ((top - viewportTop) / slack).clamp(0.0, 1.0);
  }

  Future<void> _run(ScrollPosition position, RenderObject object, double alignment) {
    if (_cancelled) return Future<void>.value();
    _moving.add(position);
    return position
        .ensureVisible(object, alignment: alignment, duration: duration, curve: Curves.easeInOut)
        .whenComplete(() => _moving.remove(position));
  }
}

/// [RevealGate] that also closes when [root] unmounts.
class _RootGate implements RevealGate {
  final Element root;
  final RevealGate? outer;
  final RevealGlide? glide;
  const _RootGate(this.root, this.outer, this.glide);

  @override
  bool get isOpen => root.mounted && (outer?.isOpen ?? true) && !(glide?.isCancelled ?? false);
}

/// Bounded scroll discovery: resolves [target]; while it is [TargetNotBuilt],
/// jumps the scrollables under [root] (no animation, outer then inner),
/// searching BOTH directions from where each started, one viewport further per
/// round in each direction, at most [maxViewports] rounds per scrollable and
/// direction, until it is found; then scrolls so the target is inside the
/// visible viewport.
///
/// - found: returns [TargetFound] with the rect after scrolling;
/// - the end of every scrollable reached in both directions without a match:
///   [TargetAbsent], scroll positions restored to where they started;
/// - [maxViewports] spent in a direction before its end: [TargetNotBuilt]
///   (budget exhausted), positions restored.
///
/// Call it from a post-frame callback or an event handler, never during
/// build or layout. Discovery advances on normal frames. [isCurrent] cancels
/// work when the user navigates or ends the guide. With a [glide], the final scroll to a
/// target that is off screen is animated (see [RevealGlide]) and the future completes when
/// it ends or is cancelled; without one it jumps and centres, as before.
/// CLAIM(reveal-touch-cancel): cancellation also stops discovery, without restoring
/// search origins [guide_r4_test R4-fix-C1].
Future<TargetResolution> revealTarget(
  Element root,
  GuideTarget target,
  AppLocalizations l, {
  int maxViewports = 20,
  RevealGate? isCurrent,
  RevealGlide? glide,
}) async {
  final gate = _RootGate(root, isCurrent, glide);
  bool active() => gate.isOpen;
  if (!active()) return TargetNotBuilt(target, 'page is no longer active');
  if (glide != null) {
    // A page that has only just been pushed is still sliding in and is not current yet:
    // nothing moves (no search jump, no glide) until the next frame, and a gate that has
    // closed by then ends the reveal (the guide reveals again once the page is current).
    await _nextLayout();
    if (!active()) return TargetNotBuilt(target, 'page is no longer active');
  }
  var now = target.resolve(root, l);
  // A target that had to be searched for was off screen on arrival, wherever the search left
  // the page: the glide then places it even if the search left it in view.
  if (now is TargetBehindAccordion) return now;
  final searched = now is TargetNotBuilt;
  if (now is TargetNotBuilt) {
    final search = _Search(root, target, l, maxViewports, gate);
    bool found;
    if (glide != null) glide._probing = true;
    try {
      found = await search.runAll();
    } finally {
      if (glide != null) glide._probing = false;
    }
    if (!active()) return TargetNotBuilt(target, 'page is no longer active');
    if (!found) {
      await _nextLayout();
      if (!active()) return TargetNotBuilt(target, 'page is no longer active');
      return search.budgetSpent
          ? TargetNotBuilt(target, 'not found within $maxViewports viewports of where the search began')
          : TargetAbsent(target, 'searched every scrollable to both ends; ${now.detail}');
    }
    now = target.resolve(root, l);
  }
  if (now is! TargetFound) return now;

  await _scrollIntoView(root, target, l, glide, placeAnyway: searched);
  await _nextLayout();
  if (!active()) return TargetNotBuilt(target, 'page is no longer active');
  return target.resolve(root, l);
}

/// The expanding two-direction search behind [revealTarget].
class _Search {
  final Element root;
  final GuideTarget target;
  final AppLocalizations l;
  final int maxViewports;
  final RevealGate gate;
  bool active() => gate.isOpen;

  /// True once any direction stopped because the budget ran out, not because
  /// it reached the end.
  bool budgetSpent = false;
  final _visited = <ScrollableState>{};

  _Search(this.root, this.target, this.l, this.maxViewports, this.gate);

  bool _found() {
    final resolution = target.resolve(root, l);
    return resolution is TargetFound || resolution is TargetBehindAccordion;
  }

  Future<bool> runAll() async {
    // Re-scanned each round: restoring a scrollable can rebuild the lazily built
    // lists inside it, replacing their States.
    while (active()) {
      final next = _scrollablesUnder(root).where((s) => s.mounted && !_visited.contains(s)).firstOrNull;
      if (next == null) return false;
      if (await _explore(next)) return true;
    }
    return false;
  }

  /// Probes [s] at origin +/- i viewports, i = 1..maxViewports; descends into
  /// scrollables each probe newly builds. Restores [s] to its origin on failure.
  Future<bool> _explore(ScrollableState s) async {
    _visited.add(s);
    final position = s.position;
    if (!position.hasPixels || !position.hasContentDimensions) return false;
    final origin = position.pixels;
    final viewport = position.viewportDimension;
    if (viewport <= 0) return false;

    // Per direction: the last offset probed (null = none yet) and whether the
    // end was reached.
    final lastProbed = <int, double?>{1: null, -1: null};
    final ended = <int, bool>{1: false, -1: false};
    for (var i = 1; i <= maxViewports && !(ended[1]! && ended[-1]!); i++) {
      for (final direction in const [1, -1]) {
        if (ended[direction]!) continue;
        final want = origin + direction * i * viewport;
        final limit = direction > 0 ? position.maxScrollExtent : position.minScrollExtent;
        final offset = (direction > 0
                ? want.clamp(position.minScrollExtent, limit)
                : want.clamp(limit, position.maxScrollExtent))
            .toDouble();
        final previous = lastProbed[direction] ?? origin;
        if ((offset - previous).abs() < 0.5) {
          ended[direction] = true; // no progress: the end was already probed
          continue;
        }
        lastProbed[direction] = offset;
        if (!active() || !s.mounted) return false;
        position.jumpTo(offset);
        await _nextLayout();
        if (!active() || !s.mounted) return false;
        if (_found()) return true;
        for (final inner in _scrollablesUnder(root)) {
          if (inner.mounted && !_visited.contains(inner) && _isUnder(inner, s) && await _explore(inner)) return true;
        }
        // The end is where the extent is NOW: a lazy list revises its estimate
        // while it lays out, so the limit read before the jump can be stale.
        final settled = direction > 0 ? position.maxScrollExtent : position.minScrollExtent;
        if ((offset - settled).abs() < 0.5) ended[direction] = true;
      }
    }
    if (!(ended[1]! && ended[-1]!)) budgetSpent = true;
    if (!active() || !s.mounted) return false;
    position.jumpTo(origin);
    await _nextLayout();
    return false;
  }

  bool _isUnder(ScrollableState inner, ScrollableState outer) {
    var inside = false;
    inner.context.visitAncestorElements((a) {
      if (identical(a, outer.context)) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside;
  }
}

/// Scrolls every scrollable under [root] that contains the resolved target so
/// it sits inside that scrollable's viewport (centred when it had to move).
/// Scrollables ABOVE the root (the page the guide sits in) are left alone.
///
/// With a [glide], the first vertical scrollable on the way up moves the target to the
/// glide's place (animated) when the target is not fully inside that scrollable's
/// viewport, or when [placeAnyway] (the target had to be searched for); the future
/// completes when those scrolls end.
Future<void> _scrollIntoView(Element root, GuideTarget target, AppLocalizations l, RevealGlide? glide, {bool placeAnyway = false}) {
  final owned = _scrollablesUnder(root).toSet();
  final element = switch (target._lookup(root, laidOutBox(root)!, root, l)) {
    _Hit(:final element) => element,
    _Miss() => null,
  };
  if (element == null) return Future<void>.value();
  var object = element.renderObject;
  // Outer viewports reveal THIS, not the inner viewport it sits in: an inner
  // viewport taller than the outer one would otherwise be centred whole and
  // leave the target outside.
  final targetObject = object;
  BuildContext cursor = element;
  final moves = <Future<void>>[];
  var glided = false;
  while (object is RenderBox) {
    final scrollable = cursor.findAncestorStateOfType<ScrollableState>();
    final viewportBox = scrollable?.context.findRenderObject();
    if (scrollable == null || !owned.contains(scrollable) || viewportBox is! RenderBox) break;
    final seen = rectInRoot(object, viewportBox);
    final viewport = Offset.zero & viewportBox.size;
    var inside = viewport.contains(seen.topLeft) && viewport.contains(seen.bottomRight);
    if (glide != null && !glided && scrollable.position.axis == Axis.vertical) {
      glided = true;
      if (!inside || placeAnyway) {
        if (glide.isCancelled) break;
        final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
        final alignment = glide.alignmentFor(object.size.height, viewportTop, viewportBox.size.height);
        moves.add(glide._run(scrollable.position, object, alignment));
      }
    } else if (!inside) {
      // Zero duration = an immediate jump; the returned future is already done.
      unawaited(scrollable.position.ensureVisible(object, alignment: 0.5, duration: Duration.zero, targetRenderObject: targetObject));
    }
    cursor = scrollable.context;
    object = viewportBox;
  }
  return Future.wait(moves);
}
