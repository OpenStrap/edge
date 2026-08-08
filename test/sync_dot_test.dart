// The sync indicator has to be quiet AND honest.
//
// "Don't get to know if syncing is happening or not" (TestFlight). The answer
// is a dot, so the two things worth pinning are that it is absent when nothing
// is arriving, and that it never leaves an animation running while invisible —
// a repeating controller on a hidden widget is a permanent frame-rate wake-up
// on the screen that already competes with a drain for the main isolate.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui/design/sync_dot.dart';

void main() {
  // MaterialApp's own route transitions are FadeTransitions too — scope every
  // finder to the widget under test or they match the scaffolding.
  final dotFade = find.descendant(
    of: find.byType(SyncDot),
    matching: find.byType(FadeTransition),
  );

  Future<void> pumpDot(WidgetTester t, {required bool active}) =>
      t.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: SyncDot(active: active))),
      ));

  testWidgets('nothing is drawn when no data is arriving', (t) async {
    await pumpDot(t, active: false);
    expect(dotFade, findsNothing);
    expect(find.bySemanticsLabel('Syncing with your band'), findsNothing);
  });

  testWidgets('it breathes while records land, and says so to a screen reader',
      (t) async {
    await pumpDot(t, active: true);
    expect(dotFade, findsOneWidget);
    expect(find.bySemanticsLabel('Syncing with your band'), findsOneWidget);

    final before = t.widget<FadeTransition>(dotFade);
    final o1 = before.opacity.value;
    await t.pump(const Duration(milliseconds: 700));
    final o2 = t.widget<FadeTransition>(dotFade).opacity.value;
    expect(o1, isNot(o2), reason: 'a static dot is not a sync indicator');
  });

  testWidgets('the animation stops when the sync does', (t) async {
    await pumpDot(t, active: true);
    await pumpDot(t, active: false);
    // A still-repeating controller would keep scheduling frames forever, and
    // pumpAndSettle times out rather than settling.
    await t.pumpAndSettle();
    expect(dotFade, findsNothing);
  });

  testWidgets('it occupies the same space either way', (t) async {
    await pumpDot(t, active: false);
    final quiet = t.getSize(find.byType(SyncDot));
    await pumpDot(t, active: true);
    expect(t.getSize(find.byType(SyncDot)), quiet,
        reason: 'the title must not shift when a sync starts or ends');
  });
}
