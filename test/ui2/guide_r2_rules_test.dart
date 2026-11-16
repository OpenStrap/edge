// WHY: user scrolling must update target visibility and marker direction in both directions.
import 'package:flutter/material.dart'; import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart'; import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart'; import '../support/live_guide_focus.dart';
import '../support/guide_r2_scroll_fixture.dart'; import '../support/skeleton_fixture.dart'; void main() {
    testWidgets('r2 user scroll away and back updates marker direction', (t) async { final f = R2ScrollFixture(); await f.pump(t);
      final initial = t.getRect(find.byKey(r2ScrollTarget)); expect(skContains(const Rect.fromLTWH(0, 0, 390, 780), initial), isTrue);
      expect(liveGuideFocus, findsOneWidget); final before = f.controller.offset;
      // Left edge is outside the card's full-width-but-inset box.
      await t.dragFrom(const Offset(4, 360), const Offset(0, -600)); await t.pump(const Duration(milliseconds: 50)); final away = t.getRect(find.byKey(r2ScrollTarget));
      expect(f.controller.offset, greaterThan(before + 300), reason: 'real user scroll reached page');
      expect(away.bottom, lessThan(0), reason: 'target really moved above viewport'); final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey); expect(marker, findsOneWidget);
      expect(find.descendant(of: marker, matching: find.byIcon(LucideIcons.chevronUp)), findsOneWidget, reason: 'points UP toward hidden target');
      expect(liveGuideFocus, findsNothing, reason: 'no clipped outline'); await t.dragFrom(const Offset(4, 100), const Offset(0, 600));
      await t.pump(const Duration(milliseconds: 50)); final returned = t.getRect(find.byKey(r2ScrollTarget));
      expect(skContains(const Rect.fromLTWH(0, 0, 390, 780), returned), isTrue); expect(liveGuideFocus, findsOneWidget);
      expect(skContains(t.getRect(liveGuideFocus), returned), isTrue); final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      expect(overlay.paintedShapes.where((s) => s.rect.overlaps(returned.deflate(.5))), isEmpty);
      expect(t.getRect(find.byKey(GuideStepCard.cardKey)).overlaps(returned), isFalse); expect(f.run.currentStep?.id, 'target'); }); }
