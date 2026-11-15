// Real Sleep content can finish several reads while a reveal is already moving. Wait for the motion to settle, rather than treating 24 frames as a settled page.
import 'package:flutter/widgets.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import 'package:openstrap_edge/ui2/guides/guide_hand.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart'; import 'package:openstrap_edge/ui2/theme.dart'; import 'live_guide_harness.dart';
Future<void> settleMovingGuide(WidgetTester t) async { var stable = 0; for (var i = 0; i < 160; i++) { await settleLiveGuide(t, frames: 1);
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay)); final scrolling = find.byType(Scrollable).evaluate().whereType<StatefulElement>()
        .any((e) => (e.state as ScrollableState).position.isScrollingNotifier.value); final widget = t.widget<LiveGuideOverlay>(find.byType(LiveGuideOverlay));
    final opensGroup = widget.run.currentStep?.multi?.opens != null; final enabled = Motion.enabled(t.element(find.byType(LiveGuideOverlay)));
    final aidVisible = find.byKey(enabled ? LiveGuideOverlay.handKey : LiveGuideOverlay.outlineKey).evaluate().isNotEmpty; final card = find.byKey(GuideStepCard.cardKey);
    final cardVisible = card.evaluate().isNotEmpty && find.ancestor(of: card, matching: find.byType(Opacity)) .evaluate().every((e) => (e.widget as Opacity).opacity >= .999);
    final ready = cardVisible && aidVisible && overlay.revealProgress == 1 && !scrolling && !overlay.isExpanding &&
        (!enabled || !opensGroup || overlay.hand.mode == GuideHandMode.list) && (!enabled || overlay.handActive);
    stable = ready ? stable + 1 : 0; if (stable == 3) return; } fail('Guide never settled with a visible pointing aid'); }
