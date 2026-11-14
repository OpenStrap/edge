// Tier 2 review fix F3 (r2-review-opus-tier2.md): the loose-text layer and the planner see the same text.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/theme.dart';

const _control = ValueKey('t2-control');

void main() {
  // WHY: CLAIM(loose-same-walk) the loose text layer and the planner must see the same text.
  // The planner walks the element tree; the layer walked the SEMANTICS tree, which
  // ExcludeSemantics / Semantics(excludeSemantics: true) cut: such text was planned but never
  // painted, so it stayed bright on a dimmed page.
  // # catches: a loose paragraph under an excluded-semantics subtree left undimmed (F3).
  testWidgets('F3 loose text under ExcludeSemantics is dimmed like any other', (t) async {
    final dim = GuideDimController();
    addTearDown(dim.dispose);
    await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(
      scrollBehavior: const GuideScrollBehavior(), theme: buildTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Pressable(key: _control, onTap: () {}, child: const Text('Target')),
        const Text('Plain words'),
        const ExcludeSemantics(child: Text('Excluded widget words')),
        Semantics(excludeSemantics: true, label: 'x', child: const Text('Excluded flag words')),
        const SizedBox(height: 1500),
      ]))))));
    await t.pump();
    final root = t.element(find.byType(Scaffold));
    final targetBox = t.renderObject<RenderBox>(find.byKey(_control));
    final target = TargetFound(t.getRect(find.byKey(_control)), renderObject: targetBox);
    final plan = planSkeleton(root, keep: [target.rect], dim: DimPolicy.of(root, target));
    final planned = {for (final u in plan.units) if (u.paragraph != null) u.paragraph!.text.toPlainText()};
    expect(planned, containsAll(['Plain words', 'Excluded widget words', 'Excluded flag words']),
      reason: 'positive control: the planner sees all three loose paragraphs');
    dim.setLooks(GuidePlan.from(root, plan, keep: [targetBox]));
    await t.pump();
    final dimColor = scaffoldOf(root).withValues(alpha: kDimOpacity);
    final layer = t.renderObject<RenderGuideLoose>(find.byType(GuideLooseLayer));
    expect(layer, paints..rect(color: dimColor)..rect(color: dimColor)..rect(color: dimColor),
      reason: 'one dim per loose paragraph, the excluded ones included');
  });
}