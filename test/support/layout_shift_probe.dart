// Widget-test probe: snapshots the render tree into the layout shift model.
//
// Only elements whose widget has a `ValueKey<String>` are tracked; the key's
// value is the element id. Role is inferred from the keyed widget and its
// subtree: a 'skeleton:' key or an isPending match at, in or around it =>
// placeholder, before text-based roles,
// Text/RichText => paragraph, EditableText => input, Semantics
// button or Focus with canRequestFocus => control, otherwise other. Colour is
// the nearest ColoredBox/DecoratedBox colour at or below the keyed element
// (0x00000000 when none). focusable/focused come from the Focus in the
// subtree. Times are explicit ms offsets: the probe never reads a clock.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'layout_shift/layout_shift.dart';

class ShiftProbe {
  /// Opt-in: also track widgets WITHOUT a `ValueKey<String>` under a stable
  /// synthetic id (see [_synthKind]). Off by default so keyed-only tests are
  /// unchanged.
  ///
  /// Id = `~<kind>|<scope>|<ancestor types>#<ordinal>` (identity is the SLOT,
  /// never the content):
  ///  * scope: the nearest ancestor `ValueKey<String>` value (or empty), so a
  ///    keyed section anchors everything inside it;
  ///  * ancestor types: runtimeTypes of the 3 nearest ancestors (left empty for
  ///    `card`, so a loading indicator and the card that replaces it match).
  ///    Sibling INDEX is deliberately left out: a card inserted above would
  ///    renumber every later sibling and the shift would vanish;
  ///  * ordinal: assigned on first observation, retained by element identity.
  /// Content is NOT in the id: "—" replaced by "72" is the same element (a
  /// resize if the box changed, nothing if not), not disappear + appear. The
  /// content hash is kept in [contentOf] for diagnostics. A progress indicator
  /// is tracked as a `card` slot sized by its outermost sizing wrapper
  /// (SizedBox/Container/Padding/...), so loading box -> chart is one resize.
  /// Deterministic: the same initial tree gives the same ids.
  final bool trackUnkeyed;

  /// Recognizes application-specific loading widgets without importing them.
  final bool Function(Widget)? isPending;

  /// Paint-only wrappers excluded from synthetic structural identity.
  final bool Function(Widget)? isPaintOnly;

  /// When set, elements whose rect does not intersect it are dropped (a
  /// lazily built list item far below the fold is not a visible shift).
  final ShiftRect? visibleOnly;

  /// When set, a route that is no longer the current one (a page covered by a
  /// push, still painted while the transition runs) is not tracked. Its slide
  /// and fade belong to the framework's route transition, and the push is what
  /// the user asked for: scoring the old page "moving" under the new one is a
  /// false positive. Off by default.
  final bool skipCoveredRoutes;
  ShiftProbe(
      {this.trackUnkeyed = false,
      this.visibleOnly,
      this.skipCoveredRoutes = false,
      this.isPending,
      this.isPaintOnly});

  Map<Element, String> _ids = {};

  /// Content hash per element id from the last capture (not part of identity).
  final Map<String, String> contentOf = {};

  /// The id of the nearest tracked element at or above the match of [f] in the
  /// last capture, for naming an Interaction source.
  String? idOf(WidgetTester tester, Finder f) {
    Element? hit = f.evaluate().firstOrNull;
    if (hit == null) return null;
    String? found = _ids[hit];
    hit.visitAncestorElements((a) {
      if (found != null) return false;
      found = _ids[a];
      return found == null;
    });
    return found;
  }

  final _elementIds = <Element, String>{};
  final _elementCounts = <String, int>{};
  final List<Frame> frames = [];
  final List<Interaction> interactions = [];
  final List<FocusEvent> focus = [];
  final List<AnimationSpan> animations = [];

  /// Walks the current tree, records and returns a Frame stamped [atMs].
  Frame capture(WidgetTester tester, {required int atMs}) {
    final out = <ElementSnapshot>[];
    final ids = <Element, String>{};
    final seen = <String, int>{};
    final ctlSeen = <String>{};
    final tracked = <String>{};
    contentOf.clear();
    for (final e in _elements(tester, skipCoveredRoutes)) {
      final k = e.widget.key;
      String? id;
      if (k is ValueKey<String>) {
        id = k.value;
        // Shared chart internals repeat on a page. A marker on the night plot
        // must not become the overnight plot's marker when a tail exposes it.
        if (id.startsWith('chart-panel')) {
          for (final ancestor in _ancestors(e)) {
            final key = ancestor.widget.key;
            if (key is ValueKey<String> &&
                !key.value.startsWith('chart-panel')) {
              id = '$id@${key.value}';
              break;
            }
          }
        }
      } else if (trackUnkeyed) {
        id = _synthId(e, seen);
      }
      if (id == null) continue;
      final box = _slotBox(e);
      if (box == null || !box.hasSize) continue;
      final o = box.localToGlobal(Offset.zero);
      // What the user sees: clipped by every scroll viewport / ClipRect above
      // it. Without this a list row scrolled under a pinned Save bar "covers"
      // the bar, though the viewport never paints it there.
      final seen0 = _clip(box, ShiftRect(o.dx, o.dy, box.size.width, box.size.height));
      if (seen0 == null) continue;
      final sub = _subtree(e);
      final focusEl = sub.where((x) => x.widget is Focus).firstOrNull;
      final node = focusEl == null ? null : _nodeOf(focusEl);
      final ownsControl = _ownsControl(e);
      final canFocus = ownsControl && (node?.canRequestFocus ?? false);
      final vis = visibleOnly;
      if (vis != null &&
          vis.intersect(seen0) == null) {
        continue;
      }
      // A synthetic element filling exactly the box of one already tracked
      // (the control inside a keyed chip) is that element again: counting it
      // twice doubled every chip's score.
      final at = '${seen0.left.round()},${seen0.top.round()},'
          '${seen0.width.round()},${seen0.height.round()}';
      if (id.startsWith('~') && tracked.contains(at) &&
          _synthKind(e.widget) != 'pending') {
        continue;
      }
      // One control = one element: InkWell, Semantics and Pressable wrappers
      // around the same button share a rect and label; keep the first.
      if (id.startsWith('~ctl|')) {
        final sig = '${id.substring(id.lastIndexOf('|'), id.lastIndexOf('#'))}@'
            '${o.dx.round()},${o.dy.round()},${box.size.width.round()},'
            '${box.size.height.round()}';
        if (!ctlSeen.add(sig)) continue;
      }
      tracked.add(at);
      ids[e] = id;
      contentOf[id] = _contentHash(e);
      out.add(ElementSnapshot(
        id: id,
        rect: seen0,
        role: _synthKind(e.widget) == 'ctl'
            ? ElementRole.control
            : _isPlaceholder(e, sub)
                ? ElementRole.placeholder
                : _role(e.widget, sub, ownsControl),
        colorArgb: _color(sub),
        focusable: canFocus,
        focused: ownsControl && (node?.hasFocus ?? false),
        ancestorIds: [for (final a in _ancestors(e)) if (ids[a] != null) ids[a]!],
      ));
    }
    _ids = ids;
    final f = Frame(atMs, out);
    frames.add(f);
    return f;
  }

  /// Everything captured so far as a scorable scenario.
  Scenario scenario(ShiftRect viewport) => Scenario(
        viewport: viewport,
        frames: List.of(frames),
        interactions: List.of(interactions),
        focus: List.of(focus),
        animations: List.of(animations),
      );

  /// Elements in tree order, skipping Offstage and hidden-Visibility subtrees
  /// (not painted).
  static List<Element> _elements(WidgetTester tester, bool skipCovered) {
    final l = <Element>[];
    void visit(Element x) {
      final w = x.widget;
      if (w is Offstage && w.offstage) return;
      // A parked IndexedStack tab (Visibility with maintainState, not
      // painted): built and sized, but not on screen.
      if (w is Visibility && !w.visible) return;
      // The framework's private per-route status widget; read dynamically.
      if (skipCovered &&
          w.runtimeType.toString() == '_ModalScopeStatus' &&
          (w as dynamic).isCurrent == false) {
        return;
      }
      l.add(x);
      x.visitChildren(visit);
    }

    visit(tester.binding.rootElement!);
    return l;
  }

  /// Which unkeyed widgets are worth tracking: text, inputs, tappable
  /// controls and card/material surfaces.
  String? _synthKind(Widget w) {
    if (isPending?.call(w) ?? false) return 'pending';
    if (w is Text) return 'text';
    if (w is EditableText) return 'input';
    if (w is ButtonStyleButton || w is InkResponse) return 'ctl';
    if (w is GestureDetector && w.onTap != null) return 'ctl';
    if (w is Card || w is ProgressIndicator) return 'card';
    return null;
  }

  String? _synthId(Element e, Map<String, int> seen) {
    final kind = _synthKind(e.widget);
    if (kind == null) return null;
    // A control wrapped by another control within 16 levels (Semantics and
    // InkWell around a button) is the same control: track the outer one only.
    // Bounded so a page-level tap handler does not swallow every control.
    // Same for a label inside a control: the control owns its text, and a
    // tracked Text over its own button would score as covering it.
    if (kind == 'ctl' || kind == 'text') {
      var nested = false;
      var depth = 0;
      e.visitAncestorElements((a) {
        depth++;
        // A button's InkWell sits ~20 levels under it; a plain tap handler
        // only counts when close (a page-level one must not swallow the page).
        if (a.widget is ButtonStyleButton ||
            (depth < 16 && _synthKind(a.widget) == 'ctl')) {
          nested = true;
        }
        return !nested && depth < 60;
      });
      if (nested) return null;
    }
    if (e.widget is ProgressIndicator) {
      // Inside a Card the Card is the slot.
      var inCard = false;
      var d = 0;
      e.visitAncestorElements((a) {
        d++;
        if (a.widget is Card) inCard = true;
        return !inCard && d < 8;
      });
      if (inCard) return null;
    }
    var scope = '';
    final types = <String>[];
    e.visitAncestorElements((a) {
      final k = a.widget.key;
      if (k is ValueKey<String>) {
        scope = k.value;
        return false;
      }
      if (isPaintOnly?.call(a.widget) ?? false) return true;
      if (types.length < 3) types.add(a.widget.runtimeType.toString());
      return true;
    });
    final base = '~$kind|$scope|${kind == 'card' ? '' : types.join('<')}';
    // Flutter preserves an unkeyed element when rows are inserted around it.
    // Re-numbering the whole tree each frame incorrectly pairs unrelated rows.
    // Loading indicators/card replacements keep their explicit slot contract.
    if (kind == 'card') {
      final n = seen[base] = (seen[base] ?? -1) + 1;
      return '$base#$n';
    }
    return _elementIds.putIfAbsent(e, () {
      final n = _elementCounts[base] = (_elementCounts[base] ?? -1) + 1;
      return '$base#$n';
    });
  }

  static ShiftRect? _clip(RenderBox box, ShiftRect r) {
    ShiftRect? out = r;
    for (RenderObject? a = box.parent; a != null && out != null; a = a.parent) {
      if ((a is RenderAbstractViewport || a is RenderClipRect) &&
          a is RenderBox &&
          a.hasSize) {
        final g = a.localToGlobal(Offset.zero);
        out = out.intersect(ShiftRect(g.dx, g.dy, a.size.width, a.size.height));
      }
    }
    return out;
  }

  static String _contentHash(Element e) {
    var content = '';
    final w = e.widget;
    if (w is Text) {
      content = w.data ?? w.textSpan?.toPlainText() ?? '';
    } else {
      void find(Element x) {
        if (content.isNotEmpty) return;
        final y = x.widget;
        if (y is Text) {
          content = y.data ?? y.textSpan?.toPlainText() ?? '';
          return;
        }
        x.visitChildren(find);
      }

      e.visitChildren(find);
    }
    var h = 0x811c9dc5;
    for (final c in content.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  /// The box that stands for [e]: its own, except a progress indicator, whose
  /// slot is the outermost sizing wrapper around it.
  static RenderBox? _slotBox(Element e) {
    if (e.widget is! ProgressIndicator) return _box(e);
    Element top = e;
    var cur = e;
    for (var i = 0; i < 8; i++) {
      Element? parent;
      cur.visitAncestorElements((a) {
        parent = a;
        return false;
      });
      final p = parent;
      if (p == null) break;
      final w = p.widget;
      if (w is SizedBox ||
          w is Container ||
          w is Padding ||
          w is ConstrainedBox ||
          w is Center ||
          w is Align) {
        top = p;
        cur = p;
      } else {
        break;
      }
    }
    return _box(top);
  }

  static RenderBox? _box(Element e) {
    RenderBox? found;
    void visit(Element x) {
      if (found != null) return;
      final r = x.renderObject;
      if (r is RenderBox) {
        found = r;
        return;
      }
      x.visitChildren(visit);
    }

    visit(e);
    return found;
  }

  /// [e] and every descendant, depth first.
  static List<Element> _subtree(Element e) {
    final l = <Element>[];
    void visit(Element x) {
      l.add(x);
      x.visitChildren(visit);
    }

    visit(e);
    return l;
  }

  static FocusNode? _nodeOf(Element focusEl) {
    // Focus.maybeOf looks upward, so ask from the Focus's own child.
    FocusNode? n;
    focusEl.visitChildren((c) => n ??= Focus.maybeOf(c, scopeOk: false, createDependency: false));
    return n;
  }

  /// A loading stand-in: a 'skeleton:' key, or an isPending match in its
  /// subtree or within a few levels above it (the spinner and status text an
  /// unkeyed probe tracks inside one are part of the placeholder).
  bool _isPlaceholder(Element e, List<Element> sub) {
    final k = e.widget.key;
    if (k is ValueKey<String> && k.value.startsWith('skeleton:')) return true;
    bool pending(Widget w) => isPending?.call(w) ?? false;
    if (sub.any((x) => pending(x.widget))) return true;
    var inside = false;
    var depth = 0;
    e.visitAncestorElements((a) {
      inside = pending(a.widget);
      return !inside && ++depth < 40;
    });
    return inside;
  }

  bool _ownsControl(Element e) {
    var current = e;
    for (var depth = 0; depth < 30; depth++) {
      final w = current.widget;
      if (w is Focus || _synthKind(w) == 'ctl' ||
          w is Semantics && ((w.properties.button ?? false) || (w.properties.slider ?? false))) { return true; }
      // A layout containing controls does not itself become a control.
      if (w is Flex || w is Stack || w is ScrollView) return false;
      final children = <Element>[]; current.visitChildren(children.add);
      if (children.length != 1) return false;
      current = children.single;
    }
    return false;
  }

  static Iterable<Element> _ancestors(Element e) {
    final parents = <Element>[];
    e.visitAncestorElements((a) { parents.add(a); return true; });
    return parents;
  }

  ElementRole _role(Widget w, List<Element> sub, bool canFocus) {
    if (w is Text || w is RichText) return ElementRole.paragraph;
    if (sub.any((x) => x.widget is EditableText)) return ElementRole.input;
    if (_synthKind(w) == 'ctl' || w is Semantics && (w.properties.button ?? false)) {
      return ElementRole.control;
    }
    if (canFocus) return ElementRole.control;
    if (sub.any((x) => x.widget is Text || x.widget is RichText)) {
      return ElementRole.paragraph;
    }
    return ElementRole.other;
  }

  static int _color(List<Element> sub) {
    for (final x in sub) {
      final w = x.widget;
      if (w is ColoredBox) return w.color.toARGB32();
      if (w is DecoratedBox) {
        final d = w.decoration;
        if (d is BoxDecoration && d.color != null) return d.color!.toARGB32();
      }
    }
    return 0x00000000;
  }
}
