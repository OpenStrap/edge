// SKELETON OVERLAY (phase 1)
//
// Turns the real, laid-out screen into skeleton except the guide's target,
// without touching any screen: everything is derived from the element and
// render tree after layout.
//
// CARD RULE. A "section" is the OUTERMOST `Surface` or `Section` element under
// the root, found by widget type:
//   - `Surface` (grammar.dart:225) builds every card: a Container with
//     `color: p.card`, `borderRadius: R.rLg`, `boxShadow: p.el(..)`. A
//     decoration test would miss `Surface(color: ...)` and would find the tab
//     bar's plain Container, so the TYPE is the rule.
//   - `Section` (grammar.dart:264) is a title row + child; its heading and its
//     ACTION sit outside the card, in no decorated box, so the unit is the
//     whole Section, not just its Surface.
//   - AppShell's tab bar (app_shell.dart:215 `_TabBar`) is a plain Container,
//     not a card: it is chrome, found by [defaultSkeletonChrome].
// Text outside any section is its own unit (one paragraph), on the scaffold.
//
// Mating parts: [GuideTarget] (../guides/guide_target.dart) resolves the rects
// that [skeletonPlan] keeps; [Skeletonize] owns the live loop between them;
// The guide run draws it live; the review views (test/support/guide_view.dart)
// draw it on demo data.

import 'dart:math' as math;
import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart' show ChartFrame, GuideBox, NavBar, Pressable, ScreenTitle, Section, Surface, SubTabs;
import '../guides/guide_target.dart';
import '../guides/guide_accordion.dart';
import '../guides/tree_geometry.dart';
import '../theme.dart';
import 'guide_plot.dart';

enum SkeletonKind {
  /// A card rect repainted in its own surface colour ([SkeletonShape.color]).
  surface,

  sine,

  /// An empty ring track in a muted pigment: what a dial (a ring painter) becomes. No arc,
  /// no value. [SkeletonShape.color] is the pigment.
  ring,

  /// One per text line box.
  bar,

  /// One per chart / image / custom paint.
  block,

  /// An OPAQUE fill in the scaffold background colour, painted before the bar
  /// of loose text and of Section headings/actions (text that sits on the
  /// scaffold, not on a card), so no glyph pixel survives at a bar's rounded
  /// corners. Carries [SkeletonShape.color].
  erase,

  /// ONE translucent layer ([SkeletonShape.color], alpha included) over a whole
  /// component's box: the r2 dim look. Never an erase patch.
  dim,

  /// A rect that stays exactly as it is: an icon inside a placeholder unit. Painted
  /// as nothing; every placeholder fill leaves a hole at it (owner: icons are never
  /// placeholders).
  icon,

  /// A skeleton card's heading (its Section title, else its first text line): the
  /// text itself stays, drawn DIMMED at the unit's top-left, while the body lines
  /// are [bar]s. The rect is the heading line's box; [SkeletonShape.color] is the
  /// veil that dims the real text.
  heading,
}

/// What a plot becomes inside a placeholder: a dial is an empty ring track, every other
/// plot one wave. The one mapping the plan and the paint share.
SkeletonKind skeletonKindOfPlot(GuidePlot plot) => plot is GuideRing ? SkeletonKind.ring : SkeletonKind.sine;

@immutable
class SkeletonShape {
  final SkeletonKind kind;

  /// In paint coordinates of the plan's root (origin = root's top-left).
  final Rect rect;

  /// Set for [SkeletonKind.surface] (the card's own colour) and
  /// [SkeletonKind.erase] (the background colour) only.
  final Color? color;

  /// 0-based index of the skeletonized unit (a card / `Section`, or one loose
  /// text paragraph) this shape belongs to. Ascends with the plan order and is
  /// contiguous: a plan with N units uses 0..N-1.
  final int section;

  const SkeletonShape({
    required this.kind,
    required this.rect,
    required this.section,
    this.color,
  });
}

/// How strongly the r2 dim look veils a component (the scaffold colour at this
/// opacity). Owner decision (pilot APK e828832b): there is NO contrast floor;
/// dimmed text is not meant to be read closely, and its contrast ratio is at most
/// half of its original in light and dark [guide_r2_contrast].
const kDimOpacity = .72;

/// True for a widget with tap semantics (a control the user can press).
bool isGuideControl(Widget w) => w is Pressable && w.onTap != null ||
    w is GestureDetector && (w.onTap != null || w.onLongPress != null) ||
    w is InkResponse && w.onTap != null || w is ButtonStyleButton && w.onPressed != null ||
    w is Semantics && (w.properties.onTap != null || w.properties.button == true) ||
    w is TextField || w is Switch || w is Checkbox || w is Radio;

/// True for a Surface / Section / control box / GuideBox: a component that paints its own guide look.
bool isGuideComponent(Widget w) => w is Surface || w is Section || w is Pressable || w is GuideBox;

/// True for a CARD of the page (owner placeholder rule): a Surface, a Section or a
/// [GuideBox] with `card: true`. Cards are what the three-card window counts.
bool isGuideCard(Widget w) => w is Surface || w is Section || w is GuideBox && w.card;

/// Gap between two boxes: 0 when they overlap, else the distance between their edges.
double rectGap(Rect a, Rect b) {
  final dx = math.max(0.0, math.max(a.left - b.right, b.left - a.right));
  final dy = math.max(0.0, math.max(a.top - b.bottom, b.top - a.bottom));
  return math.sqrt(dx * dx + dy * dy);
}

/// OWNER PLACEHOLDER RULE (2026-11-14), the whole of it:
///
///  * On a step the target's own card stays fully lit (the target is outlined in it);
///    the card ABOVE and the card BELOW it, in reading order, are DIMMED; every other
///    card is PLACEHOLDER (its title stays, dimmed).
///  * Never placeholders: icons (left exactly as they are), card titles, headers and
///    navigation (screen title and header rows, NavBar, tab bar). Loose text is only
///    ever dimmed; a control or chart above the first card (the header band) is dimmed.
///  * Off path: no placeholders, only dim. The route-back control and its neighbouring
///    cards stay lit ([neighboursLit]).
///  * P6, the target is not built ([skeletonAll]): everything on screen is placeholder,
///    the way to the target.
///
/// "Card" = a top-level [isGuideCard] unit of the page; above / below = previous / next
/// in its vertical layout, including lazy lists. Transforms and clipping do not
/// reorder siblings or change target ownership. A non-card control is "in the window"
/// when it lies between the top of the card above and the bottom of the card below.
///
/// All rects are in the page root's coordinates. Replaces kSkeletonReach (a distance
/// falloff around the target) and kLargeUnitHeight (large units dimmed): the window is
/// counted in cards, not pixels.
class DimPolicy {
  /// The target (on a step) or the route-back control (off path): the window's centre.
  final Rect? focus;

  /// P6: the target is not built, so everything on screen collapses to placeholder.
  final bool skeletonAll;

  /// False off path: nothing becomes a placeholder.
  final bool placeholders;

  /// Off path: the cards next to [focus] stay lit instead of dimmed.
  final bool neighboursLit;
  final bool navigationTarget;
  final RenderBox? focusObject;
  const DimPolicy({this.focus, this.skeletonAll = false, this.placeholders = true, this.neighboursLit = false, this.navigationTarget = false, this.focusObject});

  /// The policy for a step whose [target] was found.
  static DimPolicy of(Element page, TargetFound target) {
    final navigation = onstageElements(page).any((e) {
      final w = e.widget;
      final box = laidOutBox(e);
      if (!(w is SubTabs || w.runtimeType.toString() == '_TabBar') || box == null) return false;
      for (RenderObject? object = target.renderObject; object != null; object = object.parent) {
        if (identical(object, box)) return true;
      }
      return false;
    });
    return DimPolicy(focus: target.rect, navigationTarget: navigation, focusObject: target.renderObject);
  }
}

/// A shape before its unit has a number.
class _Draft {
  final SkeletonKind kind;
  final Rect rect;
  final Color? color;
  const _Draft(this.kind, this.rect, [this.color]);
}

/// Shapes that belong together in the plan order: an erase and the bar it
/// precedes, or one block.
class _Item {
  final Rect sortRect;

  /// Blocks sort before bars that tie with them (a bar can sit on a block).
  final int tie;
  final List<_Draft> drafts;

  /// A text line (its bar): the heading of a skeleton card is the first of these.
  final bool text;
  const _Item(this.sortRect, this.tie, this.drafts, {this.text = false});
}

/// One skeletonized unit: its visible bounds (what "kept" is decided on) and
/// its shapes, in paint order.
class _Unit {
  final Rect bounds;
  final List<_Draft> drafts;

  /// The Surface / Section / control element the unit is; null for a loose paragraph.
  final Element? component;

  /// The paragraph of a loose unit.
  final RenderParagraph? paragraph;
  final RenderBox? visual;
  final Rect? fullBounds;

  /// A card of the page: a Surface / Section / card box, or a control that wraps one.
  final bool card;
  const _Unit(this.bounds, this.drafts, [this.component, this.paragraph, this.visual, this.fullBounds, this.card = false]);
}

bool _unitOwnsBox(_Unit unit, RenderBox target) {
  final box = unit.component == null ? unit.paragraph ?? unit.visual : laidOutBox(unit.component!);
  if (box == null) return false;
  for (RenderObject? object = target; object != null; object = object.parent) {
    if (identical(object, box)) return true;
  }
  for (RenderObject? object = box; object != null; object = object.parent) {
    if (identical(object, target)) return true;
  }
  return false;
}

/// How far an erase reaches past its text line, so glyph overhang (descenders,
/// italics) does not survive it.
const _kEraseGrow = 1.0;

/// True for a widget that paints something no text line describes (a chart, a
/// ring, an image). The single definition: the plan covers these with `block`s
/// and the guide view keeps its tap pill off the ones that stay legible.
bool paintsVisual(Widget w, RenderObject ro) =>
    (w is CustomPaint && (w.painter != null || w.foregroundPainter != null)) || ro is RenderImage;

/// The theme at [e], read without registering a dependency (tree inspection must
/// not rebuild the inspected elements, which may themselves be inherited).
ThemeData _themeAt(Element e) => (e.widget is Theme ? e.widget as Theme :
    e.findAncestorWidgetOfExactType<Theme>())?.data ?? ThemeData.fallback();

/// The scaffold colour a component dims toward.
Color scaffoldOf(Element e) => _themeAt(e).scaffoldBackgroundColor;

/// The colour the decorated boxes around [object] (a bar, a card, a button) paint beneath it,
/// over [fallback], with the opacity of every Opacity above each box (a disabled button is drawn
/// at 40%). A dim over loose text uses it so the veil shows only on the glyphs, never as a box.
/// CLAIM(dim-has-no-box) [guide_r5_test R5-7, guide_r5_scenes_test R5-7 'staged'].
Color surfaceBeneath(RenderObject object, Color fallback) {
  // From the object up: a box's colour, or an opacity.
  final chain = <(Color?, double)>[];
  for (RenderObject? o = object.parent; o != null; o = o.parent) {
    if (o is RenderDecoratedBox && o.position == DecorationPosition.background) {
      final d = o.decoration;
      if (d is BoxDecoration && d.color != null) chain.add((d.color, 1));
    } else if (o is RenderOpacity) {
      chain.add((null, o.opacity));
    } else if (o is RenderAnimatedOpacity) {
      chain.add((null, o.opacity.value));
    }
  }
  // From the top down: a box is drawn under every opacity above it.
  var color = fallback;
  var factor = 1.0;
  for (var i = chain.length - 1; i >= 0; i--) {
    final (layer, opacity) = chain[i];
    if (layer == null) {
      factor *= opacity;
    } else {
      color = Color.alphaBlend(layer.withValues(alpha: layer.a * factor), color);
    }
  }
  return color;
}

/// The palette of the theme at [e] (no dependency registered).
P paletteOf(Element e) => P(_themeAt(e).brightness == Brightness.dark);

/// Everything that turns laid-out elements into [_Unit]s, in the coordinates of
/// [rootBox]. One planner serves the whole page (the overlay's plan, in page
/// coordinates) and one component (what a Surface paints for itself, in its own).
class _Planner {
  final RenderBox rootBox;
  final Color scaffold;
  final List<Rect> legible;

  /// Skeleton cards keep their first text line, dimmed (r2 item F).
  final bool heading;
  _Planner(this.rootBox, this.scaffold, this.legible, {required this.heading});

  Color get _veil => scaffold.withValues(alpha: kDimOpacity);

  Rect visibleOf(RenderBox box, [Rect? local]) =>
      rectInRoot(box, rootBox, local).intersect(visibleBoundsInRoot(box, rootBox));

  /// One bar (and its erase when the text sits on the scaffold) per line.
  List<_Item> linesOf(RenderParagraph paragraph, {required bool onCard, Color? placeholderInk}) {
    final length = paragraph.text.toPlainText().length;
    if (length == 0) return const [];
    final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length));
    // One rect per LINE: boxes of mixed runs (bold, other sizes) share a line
    // when they overlap vertically by more than half of the shorter one.
    final lines = <Rect>[];
    for (final b in boxes) {
      // Not clipped to the paragraph: a glyph box can be taller than its line
      // (F.t2 draws 30 px in a 28 px line) and the bar must cover all of it.
      final r = Rect.fromLTRB(b.left, b.top, b.right, b.bottom);
      if (r.isEmpty) continue;
      final at = lines.indexWhere((line) {
        final overlap = math.min(line.bottom, r.bottom) - math.max(line.top, r.top);
        return overlap > .5 * math.min(line.height, r.height);
      });
      if (at < 0) {
        lines.add(r);
      } else {
        lines[at] = lines[at].expandToInclude(r);
      }
    }
    final visible = visibleBoundsInRoot(paragraph, rootBox);
    final items = <_Item>[];
    for (final local in lines) {
      final line = rectInRoot(paragraph, rootBox, local);
      final bar = line.intersect(visible);
      if (bar.isEmpty && !heading) continue;
      final drafts = <_Draft>[];
      if (!onCard && !heading) {
        // Scaffold text: erase first (see SkeletonKind.erase). The grown rect
        // is dropped back to the bar when it would touch a legible rect.
        final grown = line.inflate(_kEraseGrow).intersect(visible);
        drafts.add(_Draft(
          SkeletonKind.erase,
          legible.any((k) => k.overlaps(grown)) ? bar : grown,
          scaffold,
        ));
      }
      if (!bar.isEmpty) {
        drafts.add(_Draft(SkeletonKind.bar, bar, heading ? placeholderInk ?? placeholderBarColor(scaffold) : null));
      }
      items.add(_Item(line, 1, drafts, text: true));
    }
    return items;
  }

  /// [items] sorted into plan order, the first text line turned into the dimmed
  /// heading when there are two or more text lines and headings are on.
  List<_Draft> orderedDrafts(List<_Item> items, [List<_Draft> leading = const [], bool keepHeading = false]) {
    items.sort((a, b) {
      final byTop = a.sortRect.top.compareTo(b.sortRect.top);
      if (byTop != 0) return byTop;
      final byLeft = a.sortRect.left.compareTo(b.sortRect.left);
      return byLeft != 0 ? byLeft : a.tie.compareTo(b.tie);
    });
    // A card's title is never a placeholder: the first text line stays, dimmed, when
    // the unit has a body (a second text line or a chart/ring) to turn into bars.
    final firstText = items.indexWhere((i) => i.text);
    final textLines = items.where((i) => i.text).length;
    final hasVisual = items.any((i) => !i.text);
    final headed = heading && keepHeading && firstText >= 0 && (textLines >= 2 || hasVisual) ? firstText : -1;
    return [
      ...leading,
      for (var i = 0; i < items.length; i++)
        if (i == headed) ...[
          if (!items[i].sortRect.intersect(visibleBoundsInRoot(rootBox, rootBox)).isEmpty)
            _Draft(SkeletonKind.heading, items[i].sortRect.intersect(visibleBoundsInRoot(rootBox, rootBox)), _veil),
        ] else ...items[i].drafts,
    ];
  }

  /// The unit a Surface / Section / control opens: its nested surfaces, then its
  /// lines and visuals.
  _Unit? cardUnit(Element card) {
    final box = laidOutBox(card);
    if (box == null) return null;
    final bounds = visibleOf(box);
    if (bounds.isEmpty && !heading) return null;
    final surfaces = <_Draft>[];
    final items = <_Item>[];
    // A control that wraps a Surface / Section (Pressable(child: Surface)) is that card.
    var isCard = isGuideCard(card.widget);

    void inner(Element e, bool onCard) {
      final w = e.widget;
      if (isGuideCard(w)) isCard = true;
      // An icon is never a placeholder: in the dim look it is a hole the fills leave
      // (SkeletonKind.icon); otherwise it is not planned at all.
      if (w is Icon || w is ImageIcon || w is Image || w is RawImage) {
        final iconBox = heading ? laidOutBox(e) : null;
        if (iconBox != null) {
          final rect = visibleOf(iconBox);
          if (!rect.isEmpty) surfaces.add(_Draft(SkeletonKind.icon, rect));
        }
        return;
      }
      var here = onCard;
      if (w is Surface) {
        final surfaceBox = laidOutBox(e);
        if (surfaceBox != null) {
          final rect = visibleOf(surfaceBox);
          if (!heading && !rect.isEmpty) surfaces.add(_Draft(SkeletonKind.surface, rect, w.color ?? P(_themeAt(e).brightness == Brightness.dark).card));
        }
        here = true;
      }
      final ro = e is RenderObjectElement ? e.renderObject : null;
      if (ro is RenderParagraph && ro.hasSize) {
        final frame = e.findAncestorWidgetOfExactType<ChartFrame>();
        if (heading && frame != null && ro.text.toPlainText() != frame.title) return;
        items.addAll(linesOf(ro, onCard: here, placeholderInk: heading ? placeholderBarColor(placeholderSurfaceOf(e, scaffold)) : null));
      } else if (ro is RenderBox && ro.hasSize && paintsVisual(w, ro)) {
        final rect = visibleOf(ro);
        if (!rect.isEmpty) {
          final plot = guidePlotOf(w is CustomPaint ? w.painter ?? w.foregroundPainter : null);
          if (heading && plot != null) {
            items.add(_Item(rect, 0, [_Draft(skeletonKindOfPlot(plot), rect, mutedGuideColor(plot.guideLineColor))]));
          } else if (!heading) {
            items.add(_Item(rect, 0, [_Draft(SkeletonKind.block, rect)]));
          }
        }
      }
      e.debugVisitOnstageChildren((c) => inner(c, here));
    }

    inner(card, false);
    final drafts = orderedDrafts(items, surfaces, isCard);
    // The dim look dims a unit whole, so it needs no drafts to exist.
    return drafts.isEmpty && !heading ? null : _Unit(bounds, drafts, card, null, null, rectInRoot(box, rootBox), isCard);
  }

  /// A loose paragraph as a unit (the dim look boxes the whole paragraph).
  _Unit? looseUnit(RenderParagraph ro, {required bool dimLook}) {
    final items = linesOf(ro, onCard: false);
    if (items.isEmpty) return null;
    return _Unit(
      dimLook ? visibleOf(ro) : items.map((i) => i.sortRect).reduce((a, b) => a.expandToInclude(b)),
      orderedDrafts(items),
      null,
      ro,
    );
  }
}

/// How the window rule treats one unit: placeholder or dim ([null]: lit).
enum GuideUnitLookKind { skeleton, dim }

/// [DimPolicy]'s window rule applied to the units of one page (see [DimPolicy]).
class _WindowLook {
  final DimPolicy policy;
  late final List<_Unit> cards;
  late final _Unit? own, above, below;

  /// Off path (neighboursLit): every card of the layout slots next to the route back, so a
  /// row of tiles beside it is lit whole, not just its first tile.
  late final Set<_Unit> mates;
  late final double spanTop, spanBottom, firstCardTop;

  _WindowLook(List<_Unit> units, this.policy, List<Rect> keep) {
    Rect boxOf(_Unit u) => u.fullBounds ?? u.bounds;
    final all = [for (final u in units) if (u.card) u];
    cards = all;
    firstCardTop = all.isEmpty ? double.infinity : boxOf(all.first).top;
    final focus = policy.focus;
    _Unit? o, a, b;
    final neighbours = <_Unit>{};
    // A step's tab or sub-tab target has no neighbours (every card is a placeholder). Off
    // path the route back keeps its neighbouring cards lit, also when it is a tab or
    // sub-tab: the owner's rule [guide_r2_off_path_test, guide_r3_routing_test 'R4'].
    if (focus != null && (!policy.navigationTarget || policy.neighboursLit)) {
      bool ownsFocus(_Unit unit) => policy.focusObject == null
          ? boxOf(unit).contains(focus.center) : _unitOwnsBox(unit, policy.focusObject!);
      final at = all.indexWhere(ownsFocus);
      final inside = at >= 0 || policy.focusObject != null ? at : all.indexWhere((c) => boxOf(c).overlaps(focus));
      if (inside >= 0) o = all[inside];
      final focusElement = o?.component ?? units.where((u) =>
        u.component != null && ownsFocus(u)).firstOrNull?.component;
      Element? column;
      List<_Unit> siblings = all;
      Element? slot(Element? unit, Element layout) {
        Element? child = unit;
        var under = false;
        child?.visitAncestorElements((e) {
          if (identical(e, layout)) { under = true; return false; }
          child = e;
          return true;
        });
        return under ? child : null;
      }
      // A focus pinned OUTSIDE the scrolling content (the Save bar under the list) is ordered by
      // position: the cards nearest to it on screen are its neighbours, not the last and first
      // cards of the list's layout order [guide_r5_scenes_test R5-7 'card window'].
      bool scrolls(Element? e) {
        var inside = false;
        e?.visitAncestorElements((a) {
          if (a.widget is Scrollable) { inside = true; return false; }
          return true;
        });
        return inside;
      }
      final pinned = focusElement != null && !scrolls(focusElement) && all.any((u) => scrolls(u.component));
      // A wrapper Column with only this card does not order the page. Lazy
      // ListViews are columns too. A NavBar back arrow can have a card sibling
      // below it even though the focus itself is not a card.
      (pinned ? null : focusElement)?.visitAncestorElements((e) {
        final w = e.widget;
        final direction = e.findAncestorWidgetOfExactType<Scrollable>()?.axisDirection;
        final vertical = w is Flex && w.direction == Axis.vertical ||
            e is SliverMultiBoxAdaptorElement && w is! SliverGrid &&
              (direction == AxisDirection.down || direction == AxisDirection.up);
        if (!vertical) return true;
        final focusSlot = slot(focusElement, e);
        final under = all.where((u) => slot(u.component, e) != null).toList();
        if (focusSlot == null || !under.any((u) => slot(u.component, e) != focusSlot)) return true;
        column = e;
        siblings = under;
        return false;
      });
      if (column != null) {
        final children = <Element>[];
        column!.visitChildren(children.add);
        final focusAt = children.indexOf(slot(focusElement, column!)!);
        final slotOf = <_Unit, int>{};
        for (final sibling in siblings) {
          final at = children.indexOf(slot(sibling.component, column!)!);
          slotOf[sibling] = at;
          if (at < focusAt) a = sibling;
          if (at > focusAt) b ??= sibling;
        }
        // Cards beside the neighbour in the same slot (a row of tiles) are neighbours too;
        // cards stacked below it in a slot that holds a whole list are not.
        bool beside(_Unit u, _Unit? n) {
          if (n == null || slotOf[u] != slotOf[n]) return false;
          final x = boxOf(u), y = boxOf(n);
          return math.min(x.bottom, y.bottom) - math.max(x.top, y.top) > 0;
        }
        for (final entry in slotOf.keys) {
          if (beside(entry, a) || beside(entry, b)) neighbours.add(entry);
        }
      } else if (pinned) {
        for (final u in all) {
          if (u.bounds.isEmpty || identical(u, o)) {
            continue;
          }
          if (u.bounds.top < focus.top && (a == null || u.bounds.bottom > a.bounds.bottom)) a = u;
          if (u.bounds.bottom > focus.bottom && u.bounds.top >= focus.top - 1 && (b == null || u.bounds.top < b.bounds.top)) b = u;
        }
      } else if (o != null) {
        final at = all.indexOf(o);
        if (at > 0) a = all[at - 1];
        if (at + 1 < all.length) b = all[at + 1];
      } else if (policy.neighboursLit) {
        // The route back is in no column of the page (the bottom tab bar floats over it, so
        // no layout order links it to a card): its neighbours are the cards nearest to it by
        // position, the owner's rule for an off-path route back that is a tab.
        for (final u in all) {
          final box = boxOf(u);
          if (box.top < focus.top) {
            if (a == null || box.top > boxOf(a).top) a = u;
          } else if (box.top >= focus.bottom - 1) {
            if (b == null || box.top < boxOf(b).top) b = u;
          }
        }
      }
    }

    own = o;
    above = a;
    below = b;
    mates = {...neighbours, ?a, ?b};
    spanTop = a != null ? boxOf(a).top : o != null ? boxOf(o).top : focus?.top ?? double.infinity;
    spanBottom = b != null ? boxOf(b).bottom : o != null ? boxOf(o).bottom : focus?.bottom ?? double.negativeInfinity;
  }

  GuideUnitLookKind? of(_Unit u) {
    if (policy.skeletonAll || policy.placeholders && policy.navigationTarget && u.card) return GuideUnitLookKind.skeleton;
    if (identical(u, own)) return null;
    final isCard = u.card;
    if (identical(u, above) || identical(u, below) || policy.neighboursLit && mates.contains(u)) {
      return policy.neighboursLit ? null : GuideUnitLookKind.dim;
    }
    if (!policy.placeholders) return GuideUnitLookKind.dim;
    if (isCard) return GuideUnitLookKind.skeleton;
    // Loose text is only ever dimmed (titles, status lines, labels between cards).
    if (u.paragraph != null) return GuideUnitLookKind.dim;
    // A control or chart that is no card: dimmed in the header band (above the first
    // card) and inside the window, a placeholder anywhere else.
    final y = u.bounds.center.dy;
    if (y < firstCardTop || y >= spanTop && y <= spanBottom) return GuideUnitLookKind.dim;
    return GuideUnitLookKind.skeleton;
  }
}

/// One unit of a [SkeletonPlan] as the components need it: which component (or
/// loose paragraph) it is and how it is drawn.
class PlannedUnit {
  /// The Surface / Section / control element; null for a loose paragraph.
  final Element? component;

  /// The loose paragraph; null for a component.
  final RenderParagraph? paragraph;

  /// True: placeholders (heading dimmed, body bars). False: one whole-box dim.
  final bool skeleton;

  /// A loose chart/image, whose live box supplies its input geometry.
  final RenderBox? visual;

  /// The unit's [SkeletonShape.section].
  final int section;
  const PlannedUnit({this.component, this.paragraph, this.visual, required this.skeleton, required this.section});
}

/// What [planSkeleton] decided: the shapes (the plan as rectangles) and the same
/// decisions per component, for the components that paint themselves.
class SkeletonPlan {
  final List<SkeletonShape> shapes;

  /// One per skeletonized or dimmed unit; kept units are absent.
  final List<PlannedUnit> units;

  /// Every Surface / Section / control element the plan has seen (kept, nested or
  /// planned): a component that is NOT in here was built after the plan.
  final Set<Element> seen;

  /// Every loose paragraph the plan has seen, kept or not.
  final Set<RenderParagraph> seenLoose;
  const SkeletonPlan(this.shapes, this.units, this.seen, this.seenLoose);
}

/// PURE over an already laid-out subtree. Output order: unit by unit,
/// top-to-bottom; inside a unit, containers before what they contain (an erase
/// before its bar), then by (top, left). Shapes are in the root's local space,
/// after applying every ancestor clip (viewports, ClipRect, the root bounds)
/// and transform between the root and the shape's render object; a shape whose
/// clipped rect is empty is dropped.
///
/// A unit is kept (no shapes) when its visible bounds overlap any [keep] or
/// [chrome] rect: the section holding a target stays whole; a target outside
/// every card keeps only its own paragraph.
///
/// ↳ CLAIM(kept-untouched): no returned shape overlaps a [keep]/[chrome] rect
/// [skeleton_plan_test 'what stays legible'].
List<SkeletonShape> skeletonPlan(
  Element root, {
  required List<Rect> keep,
  List<Rect> chrome = const [],
  DimPolicy? dim,
}) => planSkeleton(root, keep: keep, chrome: chrome, dim: dim).shapes;

/// [skeletonPlan] and, for the same units, which component each one is.
SkeletonPlan planSkeleton(
  Element root, {
  required List<Rect> keep,
  List<Rect> chrome = const [],
  DimPolicy? dim,
}) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return const SkeletonPlan([], [], {}, {});
  final legible = [...keep, ...chrome];
  final scaffold = scaffoldOf(root);
  final planner = _Planner(rootBox, scaffold, legible, heading: dim != null);
  final seen = <Element>{};
  final seenLoose = <RenderParagraph>{};

  /// Marks [e] and every component below it as seen.
  void see(Element e) {
    seen.add(e);
    for (final c in onstageElements(e)) {
      final w = c.widget;
      if (isGuideComponent(w)) seen.add(c);
    }
  }

  final units = <_Unit>[];
  void find(Element e) {
    final w = e.widget;
    if (w is GuideNavigationHeader) { see(e); return; }
    // The dim look treats the OUTERMOST control as one component too (its whole
    // box, padding and background included), not just the text inside it.
    if (w is Surface || w is Section || w is GuideBox || (dim != null && isGuideControl(w) && laidOutBox(e) != null)) {
      see(e);
      final unit = planner.cardUnit(e);
      if (unit != null) units.add(unit);
      return; // everything inside belongs to this unit
    }
    // A Pressable with no tap (a disabled button) is no unit of its own: its text is planned as loose
    // text. It is SEEN, though, so the plan's fallback for components built after it never dims the
    // button a second time (a lighter box behind its label) [guide_r5_scenes_test R5-7 'staged'].
    if (w is Pressable) seen.add(e);
    // An icon is never a unit: it is left exactly as it is.
    if (w is Icon || w is ImageIcon || dim != null && (w is Image || w is RawImage)) return;
    final ro = e is RenderObjectElement ? e.renderObject : null;
    if (ro is RenderParagraph && ro.hasSize) {
      seenLoose.add(ro);
      final unit = planner.looseUnit(ro, dimLook: dim != null);
      if (unit != null) units.add(unit);
    } else if (ro is RenderBox && ro.hasSize && paintsVisual(w, ro)) {
      final rect = planner.visibleOf(ro);
      final plot = guidePlotOf(w is CustomPaint ? w.painter ?? w.foregroundPainter : null);
      if (!rect.isEmpty && (dim == null || plot != null)) {
        units.add(_Unit(rect, [_Draft(dim == null || plot == null ? SkeletonKind.block : skeletonKindOfPlot(plot), rect,
          plot == null ? null : mutedGuideColor(plot.guideLineColor))], null, null, ro));
      }
    }
    e.debugVisitOnstageChildren(find);
  }

  find(root);

  // KEPT: a unit that overlaps a keep rect (the target, caption-named content, live
  // status) stays as it is. Chrome keeps only the units that lie IN it (their centre
  // inside), so a card that merely touches the NavBar's box is not kept [Day strain's
  // top card was, on the phone, and nothing on that page dimmed].
  //
  // A keep rect keeps a unit when its centre lies in the unit (the target in its card, a timer
  // in its card) or the unit's centre lies in it (a kept section): a status line that merely
  // overlaps a card's top edge keeps nothing.
  bool kept(_Unit u) => dim == null
      ? legible.any((k) => k.overlaps(u.bounds))
      : keep.any((k) => dim.focusObject != null && k == dim.focus
          ? _unitOwnsBox(u, dim.focusObject!)
          : k.overlaps(u.bounds) && (u.bounds.contains(k.center) || k.contains(u.bounds.center))) ||
          chrome.any((c) => c.contains(u.bounds.center));
  final skeletonized = [
    for (final u in units)
      if (!kept(u)) u,
  ]..sort((a, b) {
      final byTop = a.bounds.top.compareTo(b.bounds.top);
      return byTop != 0 ? byTop : a.bounds.left.compareTo(b.bounds.left);
    });
  final look = dim == null ? null : _WindowLook(units, dim, keep);
  final shapes = <SkeletonShape>[];
  final planned = <PlannedUnit>[];
  final veil = scaffold.withValues(alpha: kDimOpacity);
  var section = 0;
  for (final u in skeletonized) {
    final GuideUnitLookKind? kind = look == null ? GuideUnitLookKind.skeleton : look.of(u);
    if (kind == null) continue; // lit: neighbours of an off-path route, like a kept unit
    final skeleton = kind == GuideUnitLookKind.skeleton;
    if (skeleton) {
      for (final d in u.drafts) {
        shapes.add(SkeletonShape(kind: d.kind, rect: d.rect, color: d.color, section: section));
      }
    } else {
      // A loose line dims toward the surface it sits on, not toward the scaffold: over a bar or card
      // of another colour a scaffold veil is a dark box behind the text (owner's "1 staged").
      final color = u.paragraph == null ? veil : surfaceBeneath(u.paragraph!, scaffold).withValues(alpha: kDimOpacity);
      shapes.add(SkeletonShape(kind: SkeletonKind.dim, rect: u.bounds, color: color, section: section));
    }
    if (u.component != null || u.paragraph != null || u.visual != null) {
      planned.add(PlannedUnit(component: u.component, paragraph: u.paragraph, visual: u.visual, skeleton: skeleton, section: section));
    }
    section++;
  }
  return SkeletonPlan(shapes, planned, seen, seenLoose);
}

/// What one component paints over itself when its look is skeleton: its shapes in
/// ITS OWN coordinates (origin = the component's top-left), with the heading
/// dimmed. Empty when it has nothing to show.
List<SkeletonShape> skeletonOfComponent(Element component, RenderBox box) {
  final planner = _Planner(box, scaffoldOf(component), const [], heading: true);
  final unit = planner.cardUnit(component);
  if (unit == null) return const [];
  return [for (final d in unit.drafts) SkeletonShape(kind: d.kind, rect: d.rect, color: d.color, section: 0)];
}

/// What a loose paragraph paints over itself when its look is skeleton, in the
/// PARAGRAPH's own coordinates.
List<SkeletonShape> skeletonOfParagraph(RenderParagraph paragraph, Color scaffold) {
  final unit = _Planner(paragraph, scaffold, const [], heading: true).looseUnit(paragraph, dimLook: true);
  if (unit == null) return const [];
  return [for (final d in unit.drafts) SkeletonShape(kind: d.kind, rect: d.rect, color: d.color, section: 0)];
}

/// The opaque surface already painted beneath an element. No fill is added.
Color placeholderSurfaceOf(Element element, Color fallback) {
  final layers = <Color>[];
  element.visitAncestorElements((a) {
    final w = a.widget;
    final color = w is DecoratedBox && w.decoration is BoxDecoration
        ? (w.decoration as BoxDecoration).color : w is ColoredBox ? w.color : null;
    if (color != null) layers.add(color);
    return color == null || color.a < 1;
  });
  var color = fallback;
  for (final layer in layers.reversed) { color = Color.alphaBlend(layer, color); }
  return color;
}

/// Difference-white at kPlaceholderStrength, evaluated before the shared value
/// pulse. This keeps each surface's tone without repainting its background.
Color placeholderBarColor(Color surface) => Color.from(alpha: 1,
  red: surface.r + kPlaceholderStrength * (1 - 2 * surface.r),
  green: surface.g + kPlaceholderStrength * (1 - 2 * surface.g),
  blue: surface.b + kPlaceholderStrength * (1 - 2 * surface.b));

/// How strongly a placeholder bar or block darkens or lightens what is under it: it is
/// painted with [BlendMode.difference] against white, so the tone comes from the unit's
/// own surface (lighter on a dark card, darker on a light one, a tint on a coloured
/// one) and no colour pair is fixed (owner, 2026-11-14).
const kPlaceholderStrength = .14;

/// Paints [shapes] with [palette]: the single painter of placeholders, shared by
/// the review overlay ([Skeletonize]) and the components that paint themselves.
/// A heading is the REAL text: the surface fills leave a hole at its line and a
/// veil dims it. An icon is a hole in every fill. [fade] (0..1) scales the dim
/// layers' alpha (the dim fades in; placeholders never fade).
void paintSkeletonShapes(Canvas canvas, Iterable<SkeletonShape> shapes, P palette, {double fade = 1, double pulse = 1}) {
  Color pulsed(Color color) {
    final hsv = HSVColor.fromColor(color);
    return hsv.withValue((hsv.value * pulse).clamp(0.0, 1.0)).toColor();
  }
  final headings = [for (final s in shapes) if (s.kind == SkeletonKind.heading) s.rect];
  final icons = [for (final s in shapes) if (s.kind == SkeletonKind.icon) s.rect];
  Color veilOf(Color c) => c.withValues(alpha: c.a * fade.clamp(0.0, 1.0));
  final ink = Paint()
    ..blendMode = BlendMode.difference
    ..color = C.white.withValues(alpha: kPlaceholderStrength);
  // Dimmed headings first: a block laid over the same control then tones them evenly.
  final ordered = [
    ...shapes.where((s) => s.kind == SkeletonKind.heading || s.kind == SkeletonKind.dim),
    ...shapes.where((s) => s.kind != SkeletonKind.heading && s.kind != SkeletonKind.dim),
  ];
  for (final s in ordered) {
    switch (s.kind) {
      case SkeletonKind.sine:
        final path = Path();
        for (var i = 0; i <= 80; i++) {
          final x = s.rect.left + s.rect.width * i / 80;
          final y = s.rect.center.dy - math.sin(i / 80 * math.pi * 2) * s.rect.height * .28;
          if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
        }
        canvas.drawPath(path, Paint()..color = pulsed(s.color ?? palette.ink3)..style = PaintingStyle.stroke..strokeWidth = 2);
        break;
      case SkeletonKind.ring:
        final side = math.min(s.rect.width, s.rect.height);
        final stroke = (side * .09).clamp(3.0, 10.0);
        if (side > stroke) {
          canvas.drawCircle(s.rect.center, (side - stroke) / 2,
            Paint()..color = pulsed(s.color ?? palette.ink3)..style = PaintingStyle.stroke..strokeWidth = stroke);
        }
      case SkeletonKind.icon:
        break;
      case SkeletonKind.heading || SkeletonKind.dim:
        canvas.drawRect(s.rect, Paint()..color = veilOf(s.color!));
      case SkeletonKind.surface || SkeletonKind.erase || SkeletonKind.bar || SkeletonKind.block:
        canvas.save();
        for (final hole in icons) { canvas.clipRect(hole, clipOp: ClipOp.difference); }
        if (s.kind == SkeletonKind.surface) {
          // The heading is real text: the card fill leaves its line alone.
          for (final h in headings) { canvas.clipRect(h, clipOp: ClipOp.difference); }
          canvas.drawRRect(R.rLg.toRRect(s.rect), Paint()..color = s.color!);
        } else if (s.kind == SkeletonKind.erase) {
          canvas.drawRect(s.rect, Paint()..color = s.color!);
        } else if (s.kind == SkeletonKind.bar) {
          // The shape is the whole line box; the drawn bar is a slimmer pill
          // centred in it, as in the mock-up.
          final h = math.min(s.rect.height, math.max(8.0, s.rect.height * .55));
          final pill = Rect.fromCenter(center: s.rect.center, width: s.rect.width, height: h);
          canvas.drawRRect(RRect.fromRectAndRadius(pill, Radius.circular(h / 2)),
            s.color == null ? ink : (Paint()..color = pulsed(s.color!)));
        } else {
          canvas.drawRRect(R.rMd.toRRect(s.rect), ink);
        }
        canvas.restore();
    }
  }
}

/// The shapes `progress` (0..1, clamped) reveals: WHOLE units only,
/// `floor(progress * unitCount)` of them, from the top.
List<SkeletonShape> revealedShapes(List<SkeletonShape> plan, double progress) {
  if (plan.isEmpty) return plan;
  final units = plan.last.section + 1; // contiguous 0..N-1, ascending
  final shown = (progress.clamp(0.0, 1.0) * units).floor();
  if (shown >= units) return plan;
  return [for (final s in plan) if (s.section < shown) s];
}

/// A rounded placeholder line. Reusable for loading states. No animation.
class SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBar({super.key, this.width, this.height = 12});

  @override
  Widget build(BuildContext context) => _Placeholder(
        width: width,
        height: height,
        radius: BorderRadius.circular(height / 2),
      );
}

/// A rounded placeholder block (chart / image). No animation.
class SkeletonBlock extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBlock({super.key, this.width, required this.height});

  @override
  Widget build(BuildContext context) => _Placeholder(width: width, height: height, radius: R.rMd);
}

class _Placeholder extends StatelessWidget {
  final double? width;
  final double height;
  final BorderRadius radius;
  const _Placeholder({required this.width, required this.height, required this.radius});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(decoration: BoxDecoration(color: P.of(context).line, borderRadius: radius)),
      );
}

/// Resolver for the regions that must stay legible and interactive. Rects in
/// the root element's local space. An interface, not a function type, so the
/// heavy-calc guard (test/guards) can resolve the call.
abstract interface class SkeletonChrome {
  List<Rect> of(Element root);
}

/// [defaultSkeletonChrome] as a [SkeletonChrome].
class DefaultSkeletonChrome implements SkeletonChrome {
  const DefaultSkeletonChrome();

  @override
  List<Rect> of(Element root) => defaultSkeletonChrome(root);
}

/// The default: finds `ScreenTitle` and `NavBar` by widget type, and AppShell's
/// private tab bar by its runtime type (app_shell.dart:215), without editing
/// app_shell.dart. The tab bar's name is a string match on purpose: the class
/// is private, and the test 'finds AppShell's tab bar by type' fails if it is
/// ever renamed.
List<Rect> defaultSkeletonChrome(Element root) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return const [];
  final out = <Rect>[];
  void find(Element e) {
    final w = e.widget;
    if (isGuideChromeWidget(w)) {
      final box = laidOutBox(e);
      if (box != null) out.add(rectInRoot(box, rootBox));
      return;
    }
    e.debugVisitOnstageChildren(find);
  }

  find(root);
  return out;
}

/// True for the widgets that are navigation chrome: a screen title, a NavBar, a sub-tab
/// row, AppShell's private tab bar (matched by runtime type, see [defaultSkeletonChrome]).
/// Chrome is never dimmed, never a placeholder and never absorbs a tap, whenever it was
/// built [guide_r5_scenes_test R5-4]. CLAIM(chrome-never-covered).
bool isGuideChromeWidget(Widget w) =>
    w is ScreenTitle || w is NavBar || w is SubTabs || w.runtimeType.toString() == '_TabBar';

/// The bars that bound the area the guide may use (the card, the pill, the glide): the top bars
/// (a title, a NavBar, a sub-tab row) and the bottom bar, which is AppShell's tab bar and nothing
/// else. A [SubTabs] row is never the bottom bar, wherever it lies: Alarm's Mon-Sun row sits below
/// mid-screen and the old geometric rule took it for the tab bar, cutting the room above it
/// [guide_r5_test R5-1b]. Rects are in [root]'s coordinates. CLAIM(bars-are-bars).
({List<Rect> top, List<Rect> bottom}) guideBars(Element root) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return (top: const [], bottom: const []);
  final top = <Rect>[], bottom = <Rect>[];
  void find(Element e) {
    final w = e.widget;
    if (w is GuideNavigationHeader) return;
    if (isGuideChromeWidget(w)) {
      final box = laidOutBox(e);
      if (box != null) (w.runtimeType.toString() == '_TabBar' ? bottom : top).add(rectInRoot(box, rootBox));
      return;
    }
    e.debugVisitOnstageChildren(find);
  }

  find(root);
  return (top: top, bottom: bottom);
}

/// What a screen reader gets for something that stays readable while the rest
/// of the screen is excluded: its words, whether it is a button, and what a
/// double-tap does.
class _SemanticProxy {
  final Rect rect;
  final String label;
  final bool button;
  final VoidCallback? onTap;
  const _SemanticProxy(this.rect, this.label, this.button, this.onTap);

  @override
  bool operator ==(Object other) =>
      other is _SemanticProxy &&
      other.rect == rect &&
      other.label == label &&
      other.button == button &&
      other.onTap == onTap;

  @override
  int get hashCode => Object.hash(rect, label, button, onTap);
}

/// Wraps [child]; after every layout it re-resolves [keep] / [alsoKeep] against
/// the LIVE tree and recomputes the plan; paints [revealedShapes]. Revealed
/// units absorb pointer events and are excluded from semantics; kept targets
/// and chrome stay tappable and keep their semantics.
///
/// A [keep] target that does not resolve (absent / ambiguous / not built)
/// yields an EMPTY plan - never cover a screen whose target cannot be found -
/// and the reason is in [SkeletonizeState.resolutions]. An unresolved
/// [alsoKeep] target is skipped.
///
/// SEMANTICS. Flutter cannot exclude individual descendants of a foreign
/// subtree from the semantics tree, so while any unit is painted over, the
/// whole child is excluded and every label OUTSIDE the covered units is
/// re-published by a transparent proxy at its rect (Text, Semantics labels and
/// Pressables, with their tap handler). Known limit for phase 4: a proxy does
/// not carry scroll actions.
///
/// WHEN THE PLAN RUNS. In this overlay's `paint` (so the painted shapes always
/// match the frame), and again at the end of every frame that happens
/// afterwards, to catch changes that repaint only below an inner repaint
/// boundary (a scroll is caught immediately through its notifications).
class Skeletonize extends StatefulWidget {
  final Widget child;

  /// The targets the guide points at.
  final List<GuideTarget> keep;

  /// Extra units to leave readable (e.g. "Your zones" in step 3).
  final List<GuideTarget> alsoKeep;
  final SkeletonChrome chrome;
  final double progress;

  const Skeletonize({
    super.key,
    required this.child,
    required this.keep,
    this.alsoKeep = const [],
    this.chrome = const DefaultSkeletonChrome(),
    this.progress = 1,
  });

  @override
  State<Skeletonize> createState() => SkeletonizeState();
}

class SkeletonizeState extends State<Skeletonize> {
  final _layerKey = GlobalKey();
  _RenderSkeleton? _render;

  List<SkeletonShape> _shapes = const [];
  List<TargetResolution> _resolutions = const [];

  /// keep + alsoKeep + chrome, root space: hit-testing never absorbs here.
  List<Rect> _legible = const [];

  /// Bounds of each painted unit, root space: what pointer events are absorbed in.
  List<Rect> _absorbing = const [];
  List<_SemanticProxy> _proxies = const [];

  /// What the last build used, to know when semantics must rebuild.
  List<_SemanticProxy> _builtProxies = const [];
  bool _builtExcluding = false;
  bool _watching = false;
  bool _semanticsStale = false;

  P _palette = const P(false);

  /// The full plan as of the last layout (valid after the first frame).
  List<SkeletonShape> get shapes => _shapes;

  /// The subset actually painted at the current `progress`.
  List<SkeletonShape> get paintedShapes => revealedShapes(_shapes, widget.progress);

  /// One resolution per [Skeletonize.keep] target, same order, as of the last
  /// layout.
  List<TargetResolution> get resolutions => _resolutions;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(Skeletonize oldWidget) {
    super.didUpdateWidget(oldWidget);
    _render?.markNeedsPaint();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _render?.markNeedsPaint();
  }

  /// Re-plan at the end of every frame that happens while mounted. It never
  /// asks for a frame itself: a changed plan marks the overlay dirty, which does.
  void _watch() {
    if (_watching) return;
    _watching = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _watching = false;
      if (!mounted) return;
      if (_replan()) _render?.markNeedsPaint();
      if (_semanticsStale) {
        _semanticsStale = false;
        setState(() {});
      }
      _watch();
    });
  }

  /// Recomputes everything from the live tree. True when the plan or the
  /// legible/absorbing rects changed (so a repaint is needed).
  bool _replan() {
    final layer = _layerKey.currentContext;
    if (layer is! Element) return false;
    final l = AppLocalizations.of(layer) ?? lookupAppLocalizations(const Locale('en'));

    final resolutions = [for (final t in widget.keep) t.resolve(layer, l)];
    final keepRects = <Rect>[];
    var unresolved = false;
    for (final r in resolutions) {
      switch (r) {
        case TargetFound(:final rect):
          keepRects.add(rect);
        case TargetNotBuilt() || TargetAbsent() || TargetAmbiguous():
          unresolved = true;
      }
    }
    for (final t in widget.alsoKeep) {
      if (t.resolve(layer, l) case TargetFound(:final rect)) keepRects.add(rect);
    }
    final chrome = widget.chrome.of(layer);
    final shapes = unresolved ? const <SkeletonShape>[] : skeletonPlan(layer, keep: keepRects, chrome: chrome);

    final painted = revealedShapes(shapes, widget.progress);
    final bounds = <int, Rect>{};
    for (final s in painted) {
      bounds[s.section] = bounds[s.section]?.expandToInclude(s.rect) ?? s.rect;
    }
    final absorbing = bounds.values.toList();
    final proxies = painted.isEmpty ? const <_SemanticProxy>[] : _collectProxies(layer, absorbing);

    final changed = !_samePlan(shapes, _shapes) || !_sameRects(absorbing, _absorbing);
    _resolutions = resolutions;
    _shapes = shapes;
    _legible = [...keepRects, ...chrome];
    _absorbing = absorbing;
    _proxies = proxies;
    if (!_sameProxies(proxies, _builtProxies) || painted.isNotEmpty != _builtExcluding) {
      _semanticsStale = true;
      _watch();
    }
    return changed;
  }

  static bool _samePlan(List<SkeletonShape> a, List<SkeletonShape> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].kind != b[i].kind ||
          a[i].rect != b[i].rect ||
          a[i].color != b[i].color ||
          a[i].section != b[i].section) {
        return false;
      }
    }
    return true;
  }

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameProxies(List<_SemanticProxy> a, List<_SemanticProxy> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Every label outside the covered units, as proxies (see the class doc).
  List<_SemanticProxy> _collectProxies(Element layer, List<Rect> covered) {
    final rootBox = laidOutBox(layer);
    if (rootBox == null) return const [];
    final out = <_SemanticProxy>[];

    String textBelow(Element e) {
      final parts = <String>[];
      for (final c in onstageElements(e)) {
        final w = c.widget;
        if (w is Text) {
          final t = (w.data ?? w.textSpan?.toPlainText() ?? '').trim();
          if (t.isNotEmpty) parts.add(t);
        }
      }
      return parts.join(', ');
    }

    void take(Element e, String label, bool button, VoidCallback? onTap) {
      final box = laidOutBox(e);
      if (box == null || label.isEmpty) return;
      final rect = rectInRoot(box, rootBox).intersect(visibleBoundsInRoot(box, rootBox));
      if (rect.isEmpty || covered.any((c) => c.contains(rect.center))) return;
      out.add(_SemanticProxy(rect, label, button, onTap));
    }

    void walk(Element e) {
      final w = e.widget;
      if (w is Icon || w is ImageIcon) return;
      if (w is Pressable && (w.semanticLabel != null || w.onTap != null)) {
        take(e, w.semanticLabel ?? textBelow(e), w.onTap != null, w.onTap);
        return;
      }
      if (w is Semantics && (w.properties.label?.isNotEmpty ?? false)) {
        take(e, w.properties.label!, w.properties.button ?? false, w.properties.onTap);
        return;
      }
      if (w is Text) {
        take(e, (w.data ?? w.textSpan?.toPlainText() ?? '').trim(), false, null);
        return;
      }
      e.debugVisitOnstageChildren(walk);
    }

    layer.debugVisitOnstageChildren(walk);
    return out;
  }

  bool _absorbs(Offset position) =>
      _absorbing.any((r) => r.contains(position)) && !_legible.any((r) => r.contains(position));

  @override
  Widget build(BuildContext context) {
    _palette = P.of(context);
    _builtProxies = _proxies;
    _builtExcluding = paintedShapes.isNotEmpty;
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        ExcludeSemantics(
          excluding: _builtExcluding,
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _render?.markNeedsPaint();
              return false;
            },
            child: _SkeletonLayer(key: _layerKey, skeleton: this, child: widget.child),
          ),
        ),
        for (final p in _proxies)
          Positioned.fromRect(
            rect: p.rect,
            child: IgnorePointer(
              child: Semantics(
                container: true,
                label: p.label,
                button: p.button,
                onTap: p.onTap,
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }
}

class _SkeletonLayer extends SingleChildRenderObjectWidget {
  final SkeletonizeState skeleton;
  const _SkeletonLayer({super.key, required this.skeleton, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSkeleton(skeleton);

  @override
  void updateRenderObject(BuildContext context, _RenderSkeleton renderObject) {
    renderObject.skeleton = skeleton;
  }
}

/// Paints the child, then the plan over it; absorbs pointer events on painted
/// units.
class _RenderSkeleton extends RenderProxyBox {
  SkeletonizeState skeleton;

  _RenderSkeleton(this.skeleton) {
    skeleton._render = this;
  }

  @override
  void detach() {
    if (identical(skeleton._render, this)) skeleton._render = null;
    super.detach();
  }

  @override
  void attach(PipelineOwner pipelineOwner) {
    super.attach(pipelineOwner);
    skeleton._render = this;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    skeleton._replan();
    final shapes = skeleton.paintedShapes;
    if (shapes.isEmpty) return;
    final p = skeleton._palette;
    final canvas = context.canvas;
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    paintSkeletonShapes(canvas, shapes, p);
    canvas.restore();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.contains(position) && skeleton._absorbs(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return super.hitTest(result, position: position);
  }
}
