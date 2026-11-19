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

  @override
  String toString() => 'ShiftRect($left, $top, $width, $height)';

  @override
  bool operator ==(Object other) =>
      other is ShiftRect && other.left == left && other.top == top &&
      other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

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

/// [placeholder]: a loading stand-in (skeleton, loading indicator) that holds the
/// space its content will fill.
enum ElementRole {
  paragraph,
  input,
  control,
  media,
  decorative,
  other,
  placeholder
}

class ElementSnapshot {
  final String id;
  final ShiftRect rect;
  final ElementRole role;
  final int colorArgb;
  final bool focusable;
  final bool focused;
  final bool enabled;

  /// Tracked ancestors contain this element; they cannot occlude their own child.
  final List<String> ancestorIds;
  const ElementSnapshot({
    required this.id,
    required this.rect,
    this.role = ElementRole.other,
    this.colorArgb = 0xFF000000,
    this.focusable = false,
    this.focused = false,
    this.enabled = true,
    this.ancestorIds = const [],
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
  /// Last frame captured before this action. Later frame indices belong to it,
  /// even when the baseline and post-action frames share [atMs]. Null retains
  /// timestamp-only attribution for hand-built scenarios.
  final int? afterFrameIndex;
  const Interaction(this.atMs, this.sourceId,
      {this.intentTargetId, this.afterFrameIndex});
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
