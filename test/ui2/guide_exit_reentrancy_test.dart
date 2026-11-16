import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';

import '../support/guide_text.dart';
import '../support/live_guide_stage.dart';

void main() {
  for (final replace in [false, true]) {
    // why: an exited run's public listener can start another guide synchronously.
    // Cleanup must retain ownership of every overlay, including during replacement.
    // proves: CLAIM(run-one-at-a-time).
    testWidgets('run Exit listener retains one removable overlay, replace=$replace', (t) async {
      final stage = await pumpLiveStage(t, insertOverlay: false);
      final runner = GuideRunner(navigatorKey: stage.navigatorKey, routes: stage.routes);
      addTearDown(runner.dispose);
      runner.attachShell(FnShellLink(selectTab: (_) {}, openSettings: () async {}));
      final first = await runner.start(stageGuide(), band: null) as GuideStarted;
      await t.pump();
      Future<GuideStartResult>? restart;
      first.run.addListener(() {
        if (first.run.isExited && restart == null) {
          restart = runner.start(stageGuide(), band: null);
        }
      });
      GuideStartResult? outer;
      if (replace) {
        outer = await runner.start(stageGuide(), band: null);
      } else {
        runner.exit();
      }
      final nested = await restart!;
      expect(nested, isA<GuideStarted>());
      if (replace) expect(outer, isA<GuideStartBlocked>());
      await t.pump();
      expect(find.byType(LiveGuideOverlay), findsOneWidget);
      expect(runner.activeRun, same((nested as GuideStarted).run));
      runner.exit();
      await t.pump();
      expect(find.byType(LiveGuideOverlay), findsNothing);
      expect(runner.activeRun, isNull);
    });
  }
}
