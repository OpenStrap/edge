// ignore_for_file: invalid_use_of_visible_for_testing_member
// Review captures of the real Profile and Activity bottom; not golden baselines.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import '../../test/support/bundled_fonts.dart';
import '../../test/support/guide_r2_scenes.dart' show r2OpenDb, r2Tab;
import '../../test/support/live_guide_harness.dart';
import '../../test/support/skeleton_fixture.dart' show skLoadAppFonts;

final _out = Platform.environment['HELP_ENTRY_SHOTS'];
Future<void> _capture(WidgetTester t, GlobalKey key, String name) async {
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await t.runAsync(() async {
    t.binding.rootPipelineOwner.flushPaint();
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_out/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await loadFonts();
    await skLoadAppFonts();
    await r2OpenDb('help_entry_capture.db');
  });
  testWidgets('dark Profile and Activity bottom', (t) async {
    final key = GlobalKey();
    final app = await pumpLiveGuideApp(
      t,
      brightness: Brightness.dark,
      size: const Size(412, 1300),
      captureKey: key,
    );
    app.navigator.push(
      MaterialPageRoute<void>(builder: (_) => const ProfileHome()),
    );
    await settleLiveGuide(t);
    await _capture(t, key, 'profile-dark');
    app.navigator.pop();
    await settleLiveGuide(t);
    await t.tap(r2Tab(2));
    await settleLiveGuide(t);
    final scrollable = find.byType(Scrollable).first;
    t
        .state<ScrollableState>(scrollable)
        .position
        .jumpTo(t.state<ScrollableState>(scrollable).position.maxScrollExtent);
    await settleLiveGuide(t);
    await _capture(t, key, 'activity-bottom-dark');
    app.dispose();
    await t.pumpWidget(const SizedBox());
    await t.pump();
    expect(t.takeException(), isNull);
  }, skip: _out == null);
}
