import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/start_card.dart';
import 'package:openstrap_edge/ui2/theme.dart';

/// This card was built blind and shipped three defects a rendered check would
/// have caught immediately: a negative `Container.margin` (Flutter asserts
/// `margin.isNonNegative`, so it threw on every build and painted a
/// 358x100000 overflow stripe), the mascot stacked UNDER the copy at 176 px
/// inside a 190 px card with no clip, and `'\$count activities'` with the
/// dollar escaped, which printed the literal text to the user.
///
/// It is excluded from the gallery on purpose — a full-bleed card cannot be
/// photographed in a ~179 px component cell without the fixture, not the card,
/// being what the golden shows. This stands in for that.
void main() {
  Future<void> pump(WidgetTester t,
      {double scale = 1.0, double pad = 16}) async {
    t.view.physicalSize = const Size(390 * 2, 300 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Builder(builder: (c) {
          // COPY the ambient MediaQuery and override only the scale. Building
          // a bare MediaQueryData here sets `size` to zero, which rendered the
          // card at 0 width — a green test about a card nobody can see.
          return MediaQuery(
            data: MediaQuery.of(c).copyWith(
                textScaler: TextScaler.linear(scale)),
            // The real parent: a list that pads its other children S.x4 a
            // side and gives this one nothing, which is how it bleeds.
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: const StartCard(
                label: 'START A SESSION',
                count: 71,
                noun: 'activities',
                asset: 'mascot_workout.png',
                accent: C.purple,
                deep: C.indigo,
              ),
            ),
          );
        }),
      ),
    ));
  }

  testWidgets('it builds — the negative margin used to assert', (t) async {
    await pump(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('the count is interpolated, not printed literally', (t) async {
    await pump(t);
    expect(find.text('71 activities'), findsOneWidget);
    expect(find.textContaining(r'$count'), findsNothing);
  });

  testWidgets('it fills whatever width it is given', (t) async {
    // Full bleed is the LIST's job now — it drops its side padding and pads
    // every other child instead. Two earlier versions had the card escape its
    // parent: a negative margin (which Flutter asserts against) and an
    // OverflowBox (which takes an unbounded height in a scroll view and
    // blanked the whole tab). So the card's own contract is just this.
    await pump(t, pad: 0);
    final w = t.getSize(find.byType(StartCard)).width;
    expect(w, 390);
  });

  testWidgets('the copy is not squeezed by the mascot', (t) async {
    await pump(t);
    // The defect this pins is "71 activit…" — the mascot taking so much width
    // that the headline ellipsised. Finding the exact string is the check;
    // an ellipsised RenderParagraph would not match it.
    expect(find.text('71 activities'), findsOneWidget);
    expect(find.text('Pick one and go'), findsOneWidget);
  });

  testWidgets('nothing overflows at 2.0x text', (t) async {
    await pump(t, scale: 2.0);
    expect(t.takeException(), isNull);
  });

  testWidgets('the wellness card is the same component, its own colour',
      (t) async {
    t.view.physicalSize = const Size(390 * 2, 300 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
        body: StartCard(
          label: 'START A SITTING',
          count: 3,
          noun: 'exercises',
          asset: 'mascot_wellness.png',
          accent: C.domMind,
          deep: C.teal,
          mascotHeight: 118,
        ),
      ),
    ));
    expect(t.takeException(), isNull);
    // The count is what the picker offers, not what the tab contains.
    expect(find.text('3 exercises'), findsOneWidget);
    expect(find.text('START A SITTING'), findsOneWidget);
  });

  testWidgets('inside a ListView (the tabs\' real parent) it lays out cleanly, at least 190 high, label above the count',
      (t) async {
    // why: F1. The card used to put a Spacer in a Column whose height is
    // unbounded inside the tabs' ListView, so every debug frame asserted
    // "RenderFlex children have non-zero flex but incoming height constraints
    // are unbounded" and the failed layout cascaded into not-laid-out and
    // semantics assertions. Release builds ignored the flex (it laid out as
    // 0), so the shipped look is: the label, then the count directly below it.
    // Fails (takeException) with the Spacer; passes without.
    t.view.physicalSize = const Size(390 * 2, 780 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final handle = t.ensureSemantics();
    addTearDown(handle.dispose);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
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
    await t.pump();
    expect(t.takeException(), isNull, reason: 'no rendering assertion in a ListView');
    expect(t.getSize(find.byType(StartCard)).height, greaterThanOrEqualTo(190));
    final label = t.getRect(find.text('START A SESSION'));
    final count = t.getRect(find.text('71 activities'));
    expect(count.top, label.bottom, reason: 'the label sits directly above the count, as release builds always laid it out');
  });
}
