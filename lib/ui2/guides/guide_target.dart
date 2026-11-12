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

import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart' show Pressable;
import 'tree_geometry.dart';

/// What a target resolves to: always exactly one of the four, never null.
sealed class TargetResolution {
  const TargetResolution();
}

final class TargetFound extends TargetResolution {
  /// In the coordinate space of the root element passed to `resolve`.
  final Rect rect;
  const TargetFound(this.rect);
}

/// No match in the built tree, but a scrollable under the root could still
/// build one lazily (a list with extent left to discover).
final class TargetNotBuilt extends TargetResolution {
  final GuideTarget target;
  final String detail;
  const TargetNotBuilt(this.target, this.detail);
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
    String Function(AppLocalizations l) label, {
    GuideTarget? within,
  }) =>
      _LabelTarget([label], within);

  /// As [label], accepting any of several labels (a control whose text depends
  /// on state, e.g. "Set your own zones" / "Edit your own zones").
  factory GuideTarget.anyLabel(
    List<String Function(AppLocalizations l)> alternatives, {
    GuideTarget? within,
  }) =>
      _LabelTarget(alternatives, within);

  /// By Key: the keyed widget's own render box; no growing.
  factory GuideTarget.key(Key key) => _KeyTarget(key);

  /// Resolve in the laid-out tree under [root], in [root]'s coordinates.
  TargetResolution resolve(Element root, AppLocalizations l) {
    final rootBox = laidOutBox(root);
    if (rootBox == null) {
      return TargetNotBuilt(this, 'the root is not laid out yet');
    }
    return switch (_lookup(root, rootBox, root, l)) {
      _Hit(:final rect) => TargetFound(rect),
      _Miss(:final failure) => failure,
    };
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
    visitBuilt(scope, (e) {
      if (e.widget.key == key) hits.add(e);
    });
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
  final List<String Function(AppLocalizations l)> alternatives;
  final GuideTarget? within;
  const _LabelTarget(this.alternatives, this.within);

  @override
  _Lookup _lookup(Element root, RenderBox rootBox, Element scope, AppLocalizations l) {
    final wanted = {for (final f in alternatives) f(l).trim().toUpperCase()}..remove('');
    final quoted = [for (final f in alternatives) '"${f(l).trim()}"'].join(' / ');

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
    visitBuilt(searchIn, (e) {
      final widget = e.widget;
      final text = switch (widget) {
        Text() => widget.data ?? widget.textSpan?.toPlainText(),
        Semantics() => widget.properties.label,
        _ => null,
      };
      if (text != null && wanted.contains(text.trim().toUpperCase())) matches.add(e);
    });
    if (matches.isEmpty) return _miss(searchIn, 'nothing on screen reads $quoted');

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
    if (controls.length > 1) {
      return _Miss(TargetAmbiguous(this, controls.length, '${controls.length} controls read $quoted'));
    }
    final control = controls.keys.single;
    final box = laidOutBox(control) ?? laidOutBox(controls.values.single);
    if (box == null) return _miss(searchIn, '$quoted has no laid-out box');
    return _Hit(control, rectInRoot(box, rootBox));
  }
}

/// Every [ScrollableState] under [scope] (onstage), outer before inner.
List<ScrollableState> _scrollablesUnder(Element scope) {
  final out = <ScrollableState>[];
  visitBuilt(scope, (e) {
    if (e is StatefulElement && e.state is ScrollableState) out.add(e.state as ScrollableState);
  });
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
/// work when the user navigates or ends the guide.
Future<TargetResolution> revealTarget(
  Element root,
  GuideTarget target,
  AppLocalizations l, {
  int maxViewports = 20,
  bool Function()? isCurrent,
}) async {
  bool active() => root.mounted && (isCurrent?.call() ?? true);
  if (!active()) return TargetNotBuilt(target, 'page is no longer active');
  var now = target.resolve(root, l);
  if (now is TargetNotBuilt) {
    final search = _Search(root, target, l, maxViewports, active);
    final found = await search.runAll();
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

  _scrollIntoView(root, target, l);
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
  final bool Function() active;

  /// True once any direction stopped because the budget ran out, not because
  /// it reached the end.
  bool budgetSpent = false;
  final _visited = <ScrollableState>{};

  _Search(this.root, this.target, this.l, this.maxViewports, this.active);

  bool _found() => target.resolve(root, l) is TargetFound;

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
        if ((offset - limit).abs() < 0.5) ended[direction] = true;
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
void _scrollIntoView(Element root, GuideTarget target, AppLocalizations l) {
  final owned = _scrollablesUnder(root).toSet();
  final element = switch (target._lookup(root, laidOutBox(root)!, root, l)) {
    _Hit(:final element) => element,
    _Miss() => null,
  };
  if (element == null) return;
  var object = element.renderObject;
  BuildContext cursor = element;
  while (object is RenderBox) {
    final scrollable = cursor.findAncestorStateOfType<ScrollableState>();
    final viewportBox = scrollable?.context.findRenderObject();
    if (scrollable == null || !owned.contains(scrollable) || viewportBox is! RenderBox) break;
    final seen = rectInRoot(object, viewportBox);
    final viewport = Offset.zero & viewportBox.size;
    if (!(viewport.contains(seen.topLeft) && viewport.contains(seen.bottomRight))) {
      // Zero duration = an immediate jump; the returned future is already done.
      unawaited(scrollable.position.ensureVisible(object, alignment: 0.5, duration: Duration.zero));
    }
    cursor = scrollable.context;
    object = viewportBox;
  }
}
