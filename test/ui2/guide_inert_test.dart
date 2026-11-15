// WHY: installing the engine must preserve pixels, semantics and real taps until
// a guide is started. These are the shared hooks every existing screen uses.
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/skeleton_fixture.dart';

void main() {
  testWidgets('an inactive guide scope preserves pixels, semantics and one real tap', (t) async {
    final dim = GuideDimController();
    addTearDown(dim.dispose);
    final capture = GlobalKey();
    var taps = 0;
    Future<List<int>> frame(bool scoped) async {
      final page = RepaintBoundary(key: capture, child: Scaffold(body: ListView(children: [
        const ScreenTitle('Home'),
        Surface(child: Column(children: [
          const Text('A real value'),
          Pressable(semanticLabel: 'Open details', onTap: () => taps++, child: const Text('Details')),
        ])),
        const Section('Another section', Text('More content')),
      ])));
      final host = skHost(page);
      await t.pumpWidget(scoped ? GuideDimScope(controller: dim,
        child: ScrollConfiguration(behavior: const GuideScrollBehavior(), child: host)) : host);
      await t.pumpAndSettle();
      final node = t.getSemantics(find.byWidgetPredicate((w) => w is Pressable && w.semanticLabel == 'Open details'));
      expect(node.label, 'A real value\nOpen details\nDetails');
      final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      final bytes = await t.runAsync(() async {
        final image = await boundary.toImage();
        try { return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List().toList(); }
        finally { image.dispose(); }
      });
      await t.tap(find.text('Details'));
      await t.pumpAndSettle();
      return bytes!;
    }
    final plain = await frame(false);
    expect(taps, 1);
    final installed = await frame(true);
    expect(installed, plain);
    expect(taps, 2);
    expect(dim.looks, isNull);
    expect(t.binding.hasScheduledFrame, isFalse);
  });
}
