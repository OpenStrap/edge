// Uses Flutter test instrumentation in an explicit capture/profile command.
// ignore_for_file: invalid_use_of_visible_for_testing_member
// WHY: owner R7 asks to measure travel before changing its speed. This is a debug widget-frame CPU probe, not a device GPU/raster benchmark.
import 'package:flutter_test/flutter_test.dart'; import '../../test/support/guide_r2_scenes.dart'; import '../../test/support/live_guide_harness.dart';
void main() { setUpAll(() => r2OpenDb('guide_r7_profile.db')); testWidgets('R7 travel frame CPU probe on the real review screen', (t) async {
    final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.id == 'remove-detected/discard'), singlePending: false); try {
      await settleLiveGuide(t, frames: 24); final frames = <int>[]; for (var i = 0; i < 240; i++) { final watch = Stopwatch()..start();
        await t.pump(const Duration(milliseconds: 16)); frames.add(watch.elapsedMicroseconds); } frames.sort();
      // Recorded in the research report; machine load must not make CI flaky.
      // ignore: avoid_print
      print('R7_FRAME_CPU_US median=${frames[120]} p95=${frames[228]} max=${frames.last}'); expect(t.takeException(), isNull); } finally { await disposeR2(t, m); } }); }
