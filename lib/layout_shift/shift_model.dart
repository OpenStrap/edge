// Layout shift model: plain data for one scored scenario.
//
// Pure Dart on purpose (no Flutter import) so the scorer runs anywhere and
// stays deterministic. Colours are int ARGB, times are int ms since the
// scenario start, lengths are logical pixels. See docs/LAYOUT_SHIFT.md.

import 'dart:math';

class ShiftPoint {
  final double x;
  final double y;
  const ShiftPoint(this.x, this.y);
}

class ShiftRect {
  final double left;
  final double top;
  final double width;
  final double height;
  const ShiftRect(this.left, this.top, this.width, this.height);

  double get area => width * height;
  ShiftPoint get center => ShiftPoint(left + width / 2, top + height / 2);

  /// Overlap of the two rects, or null when they do not overlap.
  ShiftRect? intersect(ShiftRect other) {
    final l = max(left, other.left), t = max(top, other.top);
    final r = min(left + width, other.left + other.width);
    final b = min(top + height, other.top + other.height);
    return r > l && b > t ? ShiftRect(l, t, r - l, b - t) : null;
  }

  /// Bounding box of both rects.
  ShiftRect union(ShiftRect other) {
    final l = min(left, other.left), t = min(top, other.top);
    final r = max(left + width, other.left + other.width);
    final b = max(top + height, other.top + other.height);
    return ShiftRect(l, t, r - l, b - t);
  }

  /// Centre to centre distance.
  double distanceTo(ShiftRect other) {
    final a = center, b = other.center;
    return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));
  }
}

enum ElementRole { paragraph, input, control, media, decorative, other }

class ElementSnapshot {
  final String id;
  final ShiftRect rect;
  final ElementRole role;
  final int colorArgb;
  final bool focusable;
  final bool focused;
  final bool enabled;
  const ElementSnapshot({
    required this.id,
    required this.rect,
    this.role = ElementRole.other,
    this.colorArgb = 0xFF000000,
    this.focusable = false,
    this.focused = false,
    this.enabled = true,
  });
}

class Frame {
  final int atMs;
  final List<ElementSnapshot> elements;
  const Frame(this.atMs, this.elements);
}

class Interaction {
  final int atMs;
  final String sourceId;
  final String? intentTargetId;
  const Interaction(this.atMs, this.sourceId, {this.intentTargetId});
}

class FocusEvent {
  final int atMs;
  final String elementId;
  const FocusEvent(this.atMs, this.elementId);
}

class AnimationSpan {
  final int startMs;
  final int endMs;
  final String? elementId;
  final String? chainId;
  const AnimationSpan(this.startMs, this.endMs, {this.elementId, this.chainId});
}

class Scenario {
  final ShiftRect viewport;
  final List<Frame> frames;
  final List<Interaction> interactions;
  final List<FocusEvent> focus;
  final List<AnimationSpan> animations;
  const Scenario({
    required this.viewport,
    required this.frames,
    this.interactions = const [],
    this.focus = const [],
    this.animations = const [],
  });
}
