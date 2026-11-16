import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';

import '../support/skeleton_fixture.dart';

void main() {
  // why: lazy nested controls already inherit their card's paint. Merely seeing
  // a new child must not repaint the page when no effective treatment changed.
  testWidgets('a newly seen nested control keeps the same effective paint', (t) async {
    var added = false;
    late StateSetter change;
    const rootKey = ValueKey('plan-root');
    const childKey = ValueKey('new-control');
    await t.pumpWidget(skHost(Scaffold(body: StatefulBuilder(builder: (_, set) {
      change = set;
      return Column(key: rootKey, children: [Surface(child: Column(children: [
        const Text('Card'),
        if (added) Pressable(key: childKey, onTap: () {}, child: const Text('New control')),
      ]))]);
    }))));
    final page = t.element(find.byKey(rootKey));
    GuidePlan plan() => GuidePlan.from(page, planSkeleton(page,
        keep: [], dim: const DimPolicy(placeholders: false)));
    final before = plan();
    change(() => added = true);
    await t.pump();
    final after = plan();
    final child = t.element(find.byKey(childKey));
    expect(before.lookOf(child), isNull);
    expect(after.lookOf(child), isNull);
    expect(before.sameLooks(after), isTrue);
    expect(after.sameLooks(before), isTrue);
  });

  // why: suppressing unchanged plans must still publish a changed loose label.
  testWidgets('a loose paragraph changing from kept to dim changes the plan', (t) async {
    const rootKey = ValueKey('loose-root');
    await t.pumpWidget(skHost(const Scaffold(body: Column(key: rootKey,
        children: [Text('Loose ink')]))));
    final page = t.element(find.byKey(rootKey));
    final paragraph = t.renderObject<RenderParagraph>(find.byType(RichText).first);
    final kept = GuidePlan.from(page, planSkeleton(page,
        keep: [t.getRect(find.text('Loose ink'))], dim: const DimPolicy(placeholders: false)));
    final dimmed = GuidePlan.from(page, planSkeleton(page,
        keep: [], dim: const DimPolicy(placeholders: false)));
    expect(kept.looseLookOf(paragraph), isNull);
    expect(dimmed.looseLookOf(paragraph), GuideUnitLook.dim);
    expect(kept.sameLooks(dimmed), isFalse);
    expect(dimmed.sameLooks(kept), isFalse);
  });

  // why: comparing effective paragraph paint must remain safe after replacing
  // the entire old page root, in either comparison direction.
  testWidgets('replacing a whole plan root compares safely in both directions', (t) async {
    var first = true;
    late StateSetter change;
    const oldKey = ValueKey('old-root'), newKey = ValueKey('new-root');
    await t.pumpWidget(skHost(Scaffold(body: StatefulBuilder(builder: (_, set) {
      change = set;
      return Column(key: first ? oldKey : newKey, children: [Text(first ? 'old ink' : 'new ink')]);
    }))));
    final oldPage = t.element(find.byKey(oldKey));
    final old = GuidePlan.from(oldPage, planSkeleton(oldPage,
        keep: [], dim: const DimPolicy(placeholders: false)));
    change(() => first = false);
    await t.pump();
    expect(oldPage.mounted, isFalse);
    final newPage = t.element(find.byKey(newKey));
    final next = GuidePlan.from(newPage, planSkeleton(newPage,
        keep: [], dim: const DimPolicy(placeholders: false)));
    expect(() => old.sameLooks(next), returnsNormally);
    expect(() => next.sameLooks(old), returnsNormally);
  });
}
