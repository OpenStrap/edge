import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav;
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart' show GuideUnitMark;

import '../../support/layout_shift_probe.dart';

void main() {
  // WHY: enabling an arrow must not rename the adjacent date-picker slot.
  // Catches: retaining paint wrappers in identity or measuring an ancestor box.
  testWidgets('day navigation retains picker identity and measures a real move', (t) async {
    Widget app(String day, {double top = 0}) => MaterialApp(home: Align(
      alignment: Alignment.topLeft,
      child: Padding(padding: EdgeInsets.only(top: top), child: SizedBox(
        width: 300, child: DayNav(key: const ValueKey('daynav'),
          day: day, days: const ['2026-11-14', '2026-11-13'], onDay: (_) {})))));
    final probe = ShiftProbe(trackUnkeyed: true,
      isPaintOnly: (w) => w is GuideUnitMark);
    String pickerId() => probe.idOf(t, find.descendant(
      of: find.byType(Pressable).at(1),
      matching: find.byType(GestureDetector)))!;
    await t.pumpWidget(app('2026-11-14'));
    final before = probe.capture(t, atMs: 0);
    final id = pickerId();
    final rect = before.elements.singleWhere((e) => e.id == id).rect;
    await t.pumpWidget(app('2026-11-13'));
    final after = probe.capture(t, atMs: 100);
    expect(pickerId(), id);
    expect(after.elements.singleWhere((e) => e.id == id).rect, rect);
    await t.pumpWidget(app('2026-11-13', top: 24));
    final moved = probe.capture(t, atMs: 200);
    expect(pickerId(), id);
    expect(moved.elements.singleWhere((e) => e.id == id).rect.top - rect.top, 24);
    final findings = score(probe.scenario(const ShiftRect(0, 0, 800, 600)),
      ShiftPolicy.standard).findings.where((f) => f.rule == 'shift' && f.elementId == id);
    expect(findings.map((f) => f.atMs), [200]);
  });
}
