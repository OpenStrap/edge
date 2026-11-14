import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/activity/setup.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';

void main() {
  setUpAll(() => r2OpenDb('guide_r2_workout.db'));
  tearDownAll(LocalDb.close);

  // WHY: P7 specifically promises list selection as an alternative to Search.
  // # catches: the screenshot driver's ActivityRow.onTap callback concealing a
  // shield that still absorbs the user's real pointer tap.
  testWidgets('r2 choose-activity list row pointer advances without callback workaround', (t) async {
    final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.step == 'choose-activity'));
    try {
      await settleLiveGuide(t, frames: 18);
      await t.tapAt(t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)).targetRect!.center);
      await t.enterText(find.descendant(of: find.byType(ActivityPicker), matching: find.byType(TextField)), 'Running');
      await settleLiveGuide(t);
      final row = find.byType(ActivityRow).first;
      expect(row, findsOneWidget, reason: 'search built a real result');
      await t.tapAt(t.getRect(row).center); // Deliberately no .onTap invocation.
      await settleLiveGuide(t, frames: 16);
      expect(find.byType(ActivitySetup), findsOneWidget);
      expect(m.run.currentStep?.id, 'start');
    } finally { await disposeR2(t, m); }
  });

  // WHY: P8's "Check the details" must leave the actual setup details readable.
  // # catches: only Start is kept while Route/Heart rate/Private session are masked.
  testWidgets('r2 start caption keeps setup details legible', (t) async {
    final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.step == 'start'));
    try {
      await settleLiveGuide(t, frames: 18);
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      final labels = [r2Locale.activitySetupRouteLabel, r2Locale.activitySetupHeartRateLabel,
        r2Locale.activitySetupPrivateLabel];
      for (final label in labels) {
        final text = find.text(label);
        expect(text, findsOneWidget);
        final rect = t.getRect(text);
        expect(overlay.paintedShapes.where((s) => s.rect.overlaps(rect)), isEmpty, reason: label);
        expect(t.getRect(find.byKey(GuideStepCard.cardKey)).overlaps(rect), isFalse, reason: label);
      }
    } finally { await disposeR2(t, m); }
  });

  // WHY: the owner's finish screenshot shows the card hiding the live title
  // and timer; those rows belong to the avoidance list even outside NavBar.
  // # catches: keepClear contains only Finish and its pill; live status is erased.
  testWidgets('r2 finish card and placeholders avoid live title and timer', (t) async {
    final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.step == 'finish'));
    try {
      await settleLiveGuide(t, frames: 18);
      final title = find.byWidgetPredicate((w) => w is Text && w.data == 'RUNNING');
      final timers = find.byWidgetPredicate((w) => w is Text && RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(w.data ?? ''));
      expect(title, findsOneWidget);
      expect(timers, findsWidgets, reason: 'the real live clock is visible');
      final card = t.getRect(find.byKey(GuideStepCard.cardKey));
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      for (final element in [...title.evaluate(), ...timers.evaluate()]) {
        final rect = t.getRect(find.byElementPredicate((e) => identical(e, element)));
        expect(card.overlaps(rect), isFalse, reason: 'live status ${element.widget}');
        expect(overlay.paintedShapes.where((s) => s.rect.overlaps(rect)), isEmpty,
          reason: 'live status must stay legible');
      }
    } finally { await disposeR2(t, m); }
  });
}
