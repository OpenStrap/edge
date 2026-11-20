// A parent rebuild with an equal (but new) items list must not snap the
// chip row back to the selected tab while the user is reading the rest.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _harness(List<String> items, int index) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 200, child: SubTabs(items, index, (_) {})),
        ),
      ),
    );

List<String> _items() => [
      for (var i = 0; i < 8; i++) 'Section number $i',
    ];

void main() {
  testWidgets('rebuild with an equal list keeps the scroll offset', (t) async {
    await t.pumpWidget(_harness(_items(), 0));
    await t.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;
    double offset() =>
        t.state<ScrollableState>(scrollable).position.pixels;

    await t.drag(scrollable, const Offset(-300, 0));
    await t.pumpAndSettle();
    final scrolled = offset();
    expect(scrolled, greaterThan(100));

    await t.pumpWidget(_harness(_items(), 0));
    await t.pumpAndSettle();
    expect(offset(), scrolled);
  });

  testWidgets('a new index still reveals the selected tab', (t) async {
    await t.pumpWidget(_harness(_items(), 0));
    await t.pumpAndSettle();
    await t.pumpWidget(_harness(_items(), 7));
    await t.pumpAndSettle();
    final pos =
        t.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(pos.pixels, greaterThan(0));
  });
}
