import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';

import '../support/guide_text.dart';
import '../support/skeleton_fixture.dart';

void main() {
  setUpAll(skLoadAppFonts);

  // WHY: CLAIM(guide-card-hit-targets). The new guide controls need 48 dp
  // targets even though the app-wide Pressable minimum is 44 dp. Measure the
  // actual gesture receivers and tap their edges, including outside the text.
  // catches: enlarging only semantics or putting padding outside Pressable.
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('${locale.languageCode}: guide actions have usable 48 dp targets', (t) async {
      skTallView(t, w: 390, h: 780);
      var exits = 0;
      var returns = 0;
      final help = GuideFooter(
        kind: GuideFooterKind.missingTarget,
        title: fnText((_) => 'Missing target'),
        body: fnText((_) => 'Scroll to find it.'),
      );
      Future<void> show(GuideCardModel model) async {
        await t.pumpWidget(skHost(Scaffold(body: Center(child: SizedBox(
          width: 366,
          child: GuideStepCard(model: model, onExit: () => exits++, onBackToGuide: () => returns++),
        ))), locale: locale));
        await t.pumpAndSettle();
      }
      Rect hitRect(Key key) {
        final receiver = find.descendant(of: find.byKey(key), matching: find.byType(GestureDetector));
        expect(receiver, findsOneWidget);
        final rect = t.getRect(receiver);
        expect(rect.width, greaterThanOrEqualTo(48), reason: '$key width');
        expect(rect.height, greaterThanOrEqualTo(48), reason: '$key height');
        return rect;
      }
      Future<void> tapEdges(Key key, VoidCallback check) async {
        for (var corner = 0; corner < 4; corner++) {
          final rect = hitRect(key).deflate(1);
          final points = [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight];
          await t.tapAt(points[corner]);
          await t.pumpAndSettle();
          check();
        }
      }
      await show(GuideCardOnStep(number: 1, total: 2, caption: 'Find the control.', missingHelp: help));
      var expanded = false;
      await tapEdges(GuideStepCard.dontSeeItKey, () {
        expanded = !expanded;
        expect(find.byKey(GuideStepCard.missingHelpKey), expanded ? findsOneWidget : findsNothing);
      });
      for (final model in [const GuideCardOffPath(), const GuideCardDone([])]) {
        await show(model);
        if (model is GuideCardOffPath) {
          var expected = returns;
          await tapEdges(GuideStepCard.backToGuideKey, () => expect(returns, ++expected));
        }
        var expected = exits;
        await tapEdges(GuideStepCard.exitKey, () => expect(exits, ++expected));
      }
      expect(t.takeException(), isNull);
    });
  }
}
