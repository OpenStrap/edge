// The start card inside a scrolling page: its Spacer needs a bounded height,
// which a ListView does not give. It asserted in debug and had no size.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/start_card.dart';
import 'package:openstrap_edge/ui2/theme.dart';

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets('lays out inside a ListView at text scale $scale', (t) async {
      t.view.physicalSize = const Size(390 * 3, 800 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(children: const [
            StartCard(
              label: 'START A SESSION',
              count: 71,
              noun: 'activities',
              asset: 'mascot_workout.png',
              accent: C.purple,
              deep: C.indigo,
            ),
          ]),
        ),
      ));
      expect(t.takeException(), isNull);
      final card = t.getRect(find.byType(StartCard));
      expect(card.height, greaterThanOrEqualTo(190));
      final label = t.getRect(find.text('START A SESSION'));
      // The only Icon in the card is the play button.
      final play = t.getRect(find.byType(Icon));
      expect(label.bottom, lessThan(play.top),
          reason: 'the label sits above the play button');
      expect(play.bottom, lessThanOrEqualTo(card.bottom));
    });
  }
}
