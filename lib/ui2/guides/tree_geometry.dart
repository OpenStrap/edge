// Geometry and traversal helpers shared by GuideTarget resolution
// (guide_target.dart) and the skeleton plan (../skeleton/skeleton.dart).
//
// Everything here is read-only over an already laid-out tree, and everything
// is expressed in the coordinate space of a ROOT render box: the space the
// overlay paints in, with transforms and clips only counted between the root
// and the object (a Transform ABOVE the root does not enter).

import 'package:flutter/widgets.dart';

/// Visits [element] and every ONSTAGE element below it, parents before
/// children. An `Offstage`, a non-current `IndexedStack` child or a hidden route
/// is skipped, exactly as `find` skips them; and a lazy list only yields the
/// children it is actually showing (`SliverMultiBoxAdaptorElement` and the
/// viewports drop the ones that are merely built inside the cache extent).
///
/// CLAIM(onstage-walk): this is what the user can see; it is Flutter's own
/// `Element.debugVisitOnstageChildren`, the walk `find` uses for
/// `skipOffstage: true` [flutter widgets/framework.dart].
void visitOnstage(Element element, void Function(Element) visitor) {
  void walk(Element e) {
    visitor(e);
    e.debugVisitOnstageChildren(walk);
  }

  walk(element);
}

/// As [visitOnstage], but a lazy list yields every child it has BUILT, also
/// those inside the cache extent beyond the viewport: a target there exists and
/// only needs scrolling into view, so it must not be reported as unbuilt.
void visitBuilt(Element element, void Function(Element) visitor) {
  void walk(Element e) {
    visitor(e);
    final w = e.widget;
    if (e is SliverMultiBoxAdaptorElement || w is Viewport || w is ShrinkWrappingViewport || w is SliverMainAxisGroup) {
      e.visitChildren(walk);
    } else {
      e.debugVisitOnstageChildren(walk);
    }
  }

  walk(element);
}

/// The render box of [element] (its own, or the nearest descendant's) when it
/// is laid out, else null.
RenderBox? laidOutBox(Element element) {
  final ro = element.renderObject;
  return ro is RenderBox && ro.hasSize && ro.attached ? ro : null;
}

/// [local] (default: the whole box) of [box], in [root]'s coordinate space.
Rect rectInRoot(RenderBox box, RenderBox root, [Rect? local]) =>
    MatrixUtils.transformRect(box.getTransformTo(root), local ?? (Offset.zero & box.size));

/// The part of [root]'s bounds that [object] can be seen through: the root's
/// own bounds intersected with every ancestor clip (viewports, ClipRect...)
/// between [object] and [root], in [root]'s space. Empty when fully hidden.
///
/// ↳ CLAIM(ancestor-clips): uses `describeApproximatePaintClip`, the same hook
/// the framework's semantics and hit-testing use to know what a clipping
/// ancestor lets through [rendering/object.dart].
Rect visibleBoundsInRoot(RenderObject object, RenderBox root) {
  var visible = Offset.zero & root.size;
  RenderObject child = object;
  while (!identical(child, root)) {
    final parent = child.parent;
    if (parent == null) break;
    final clip = parent.describeApproximatePaintClip(child);
    if (clip != null) {
      visible = visible.intersect(MatrixUtils.transformRect(parent.getTransformTo(root), clip));
    }
    child = parent;
  }
  return visible;
}
