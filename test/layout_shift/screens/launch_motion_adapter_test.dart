import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/onboarding/splash.dart';

import '../../support/layout_shift_probe.dart';
import '../../support/layout_shift/layout_shift.dart';

void main() {
  // WHY: reduced motion removes the splash immediately and never covers again.
  // Catches: a cover returning after ready changes back to false.
  testWidgets('reduced-motion splash keeps the revealed layout on retry', (t) async {
    Widget app(bool ready) => MaterialApp(
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(disableAnimations: true), child: child!),
      home: BootSplash(ready: ready, child: const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(key: ValueKey('content'), width: 100, height: 80))));
    final probe = ShiftProbe();
    await t.pumpWidget(app(true));
    final before = probe.capture(t, atMs: 0);
    expect(find.byType(AnimatedOpacity), findsNothing);
    await t.pumpWidget(app(false));
    final after = probe.capture(t, atMs: 100);
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(before.elements.map((e) => e.id), ['content']);
    expect(compareLayouts(before, after, ShiftPolicy.standard,
      viewport: const ShiftRect(0, 0, 800, 600)).findings, isEmpty);
  });
}
