// CLAIM growing-tail: an unknown tail may grow, but it cannot move or resize
// the content before it. The tail's cost is scored separately, never erased.
import 'package:flutter_test/flutter_test.dart';
import 'layout_shift/layout_shift.dart';

({ShiftReport prefix, ShiftReport tail}) checkGrowingTail({
  required Scenario scenario,
  required Frame pending,
  required double tailTop,
  required String route,
}) {
  final protected = {
    for (final e in pending.elements)
      if (!e.id.startsWith('~pending|') &&
          e.rect.top < tailTop &&
          e.rect.top + e.rect.height <= tailTop + 1)
        e.id: e,
  };
  expect(
    protected,
    isNotEmpty,
    reason: '$route must actually observe a prefix',
  );
  for (final frame in scenario.frames.where((f) => f.atMs > pending.atMs)) {
    final now = {for (final e in frame.elements) e.id: e};
    for (final e in protected.values) {
      final current = now[e.id];
      expect(current, isNotNull, reason: '$route lost prefix ${e.id}');
      if (current == null) continue;
      final before = e.rect, after = current.rect;
      expect(
        (before.left - after.left).abs(),
        lessThanOrEqualTo(1),
        reason: '$route ${e.id} left',
      );
      expect(
        (before.top - after.top).abs(),
        lessThanOrEqualTo(1),
        reason: '$route ${e.id} top',
      );
      expect(
        (before.width - after.width).abs(),
        lessThanOrEqualTo(1),
        reason: '$route ${e.id} width',
      );
      expect(
        (before.height - after.height).abs(),
        lessThanOrEqualTo(1),
        reason: '$route ${e.id} height',
      );
    }
  }
  Scenario subset(bool prefix) => Scenario(
    viewport: scenario.viewport,
    interactions: scenario.interactions,
    focus: scenario.focus,
    animations: scenario.animations,
    frames: [
      for (final f in scenario.frames.where((f) => f.atMs >= pending.atMs))
        Frame(f.atMs, [
          for (final e in f.elements)
            if (protected.containsKey(e.id) == prefix) e,
        ]),
    ],
  );
  final policy = ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0);
  final prefix = score(subset(true), policy),
      tail = score(subset(false), policy);
  for (final f in prefix.findings.where((f) => f.rule == 'shift')) {
    expect(
      f.score,
      lessThan(.002),
      reason: '$route prefix ${f.elementId} at ${f.atMs}',
    );
  }
  expect(prefix.total, lessThan(.016), reason: '$route prefix total');
  return (prefix: prefix, tail: tail);
}
