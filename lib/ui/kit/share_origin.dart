import 'package:flutter/widgets.dart';

/// Anchor rect for the iOS share sheet.
///
/// On iPad — and since iOS 26 on iPhone too — `UIActivityViewController` is
/// presented as a popover, and it rejects a missing origin AND a degenerate one
/// ("{{0, 0}, {0, 0}} must be non-zero and within coordinate space of source
/// view"). Passing `null` is therefore not a safe fallback: it is the crashing
/// input. When the render box is gone, unsized, or scrolled off screen, anchor
/// to the middle of the screen instead so the sheet still opens.
///
/// Call this BEFORE any await. After one the widget may have been unmounted or
/// relaid out, and the rect would describe a box that no longer exists.
Rect shareOriginFor(BuildContext context) {
  final screen = Offset.zero & MediaQuery.of(context).size;
  final box = context.findRenderObject() as RenderBox?;
  if (box != null && box.hasSize) {
    final visible = (box.localToGlobal(Offset.zero) & box.size).intersect(screen);
    if (visible.width > 0 && visible.height > 0) return visible;
  }
  return Rect.fromCenter(center: screen.center, width: 1, height: 1);
}
