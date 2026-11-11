// Skeletonize + SkeletonBar/SkeletonBlock: what the user sees and can touch.
//
// Pixel checks compare the SAME pixel with the overlay at progress 0 and 1, so
// no skeleton colour is hard-coded (that is a design token, not a claim).

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/skeleton_fixture.dart';

const _ahem = TextStyle(fontSize: 10, height: 1);
const _shot = ValueKey('shot');
const _sk = ValueKey('sk');

/// Card A (text + a tappable), card B (text + the TARGET tappable), a loose
/// line. [keep] is in the Skeletonize's coordinates (origin = the shot's).
Widget _app({
  required List<Rect> keep,
  double progress = 1,
  required VoidCallback onA,
  required VoidCallback onTarget,
}) =>
    skHost(Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: _shot,
          child: SizedBox(
            width: 300,
            height: 400,
            child: Skeletonize(
              key: _sk,
              keep: keep,
              progress: progress,
              child: ColoredBox(
                color: const Color(0xFFFFFFFF),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Surface(
                      child: Column(children: [
                        const Text('A text', style: _ahem),
                        GestureDetector(
                          key: const ValueKey('tapA'),
                          behavior: HitTestBehavior.opaque,
                          onTap: onA,
                          child: const SizedBox(height: 30, width: 100, child: Text('tap A', style: _ahem)),
                        ),
                      ]),
                    ),
                    Surface(
                      child: Column(children: [
                        const Text('B text', style: _ahem),
                        GestureDetector(
                          key: const ValueKey('tapT'),
                          behavior: HitTestBehavior.opaque,
                          onTap: onTarget,
                          child: const SizedBox(height: 30, width: 100, child: Text('target', style: _ahem)),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ));

Rect _local(WidgetTester t, Finder f) => skLocalRect(t, f, find.byKey(_shot));

Future<List<int>> _pixel(WidgetTester t, Offset p) async {
  late List<int> out;
  await t.runAsync(() async {
    final b = t.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
    final img = await b.toImage();
    final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final i = (p.dy.floor() * img.width + p.dx.floor()) * 4;
    out = [for (var k = 0; k < 4; k++) data.getUint8(i + k)];
  });
  return out;
}

void main() {
  group('SkeletonBar / SkeletonBlock', () {
    testWidgets('take exactly the size asked for and are rounded', (t) async {
      // why: they are reusable loading placeholders; a wrong size or square
      // corners breaks the look wherever they are reused.
      await t.pumpWidget(skHost(const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SkeletonBar(width: 120, height: 14, key: ValueKey('bar')),
            SkeletonBlock(width: 200, height: 60, key: ValueKey('block')),
          ]),
        ),
      )));
      expect(t.getSize(find.byKey(const ValueKey('bar'))), const Size(120, 14));
      expect(t.getSize(find.byKey(const ValueKey('block'))), const Size(200, 60));
      for (final k in const ['bar', 'block']) {
        final deco = t.widget<DecoratedBox>(find.descendant(
            of: find.byKey(ValueKey(k)), matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration;
        expect(deco.borderRadius, isNotNull, reason: '$k is rounded');
        expect(deco.color, isNotNull, reason: '$k is filled');
      }
    });

    testWidgets('colours come from the app tokens: light and dark differ', (t) async {
      // why: "plain widgets in the app's tokens (P.of)": a hard-coded grey is
      // invisible on one of the two themes.
      Future<Color?> colour(Brightness b) async {
        await t.pumpWidget(skHost(const Scaffold(body: SkeletonBar(width: 50)), brightness: b));
        final box = t.widget<DecoratedBox>(
            find.descendant(of: find.byType(SkeletonBar), matching: find.byType(DecoratedBox)).first);
        return (box.decoration as BoxDecoration).color;
      }
      final light = await colour(Brightness.light);
      final dark = await colour(Brightness.dark);
      expect(light, isNot(dark));
    });

    testWidgets('no animation by default', (t) async {
      // why: spec 1.1 "no animation by default"; a shimmer ticker would keep
      // every golden and pumpAndSettle from ever settling.
      await t.pumpWidget(skHost(const Scaffold(
        body: Column(children: [SkeletonBar(width: 50), SkeletonBlock(height: 20)]),
      )));
      await t.pump(const Duration(seconds: 1));
      expect(t.binding.transientCallbackCount, 0);
    });
  });

  group('Skeletonize pointer events', () {
    testWidgets('a skeletonized section absorbs taps; the kept target still gets them', (t) async {
      // why: while a guide shows, only the target may act; every other card is
      // painted over and must not fire (a tap on a skeleton bar must not open
      // a screen). Keep = card B's "target". Positive control in the same test:
      // the kept tappable DOES fire.
      skTallView(t);
      var a = 0, target = 0;
      await t.pumpWidget(_app(keep: const [], progress: 0, onA: () => a++, onTarget: () => target++));
      final keep = _local(t, find.byKey(const ValueKey('tapT')));
      await t.pumpWidget(_app(keep: [keep], onA: () => a++, onTarget: () => target++));
      await t.pump();

      await t.tap(find.byKey(const ValueKey('tapA')), warnIfMissed: false);
      await t.tap(find.byKey(const ValueKey('tapT')), warnIfMissed: false);
      expect(a, 0, reason: 'card A is skeletonized: tap absorbed');
      expect(target, 1, reason: 'the kept target must stay tappable');
    });

    testWidgets('nothing is absorbed until a section is actually painted (progress 0)', (t) async {
      // why: absorption follows the painted skeleton. If it ignored progress,
      // the screen would be dead while the overlay is still invisible.
      skTallView(t);
      var a = 0;
      await t.pumpWidget(_app(keep: const [], progress: 0, onA: () => a++, onTarget: () {}));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('tapA')), warnIfMissed: false);
      expect(a, 1);
    });
  });

  group('Skeletonize painting', () {
    testWidgets('progress 0 leaves the child pixels alone; 1 covers skeletonized text, not the target',
        (t) async {
      // why: the overlay really paints. Same pixel, two progress values:
      // - inside card A's text line: must CHANGE (covered by a bar),
      // - inside the kept target's text: must stay IDENTICAL.
      // Also exercises repaint when only `progress` changes.
      skTallView(t);
      await t.pumpWidget(_app(keep: const [], progress: 0, onA: () {}, onTarget: () {}));
      final keep = _local(t, find.byKey(const ValueKey('tapT')));
      final aText = _local(t, find.text('A text'));
      final aPoint = Offset(aText.left + 3, aText.center.dy);
      final tPoint = Offset(_local(t, find.text('target')).left + 3, _local(t, find.text('target')).center.dy);

      await t.pumpWidget(_app(keep: [keep], progress: 0, onA: () {}, onTarget: () {}));
      await t.pump();
      final aBefore = await _pixel(t, aPoint);
      final tBefore = await _pixel(t, tPoint);

      await t.pumpWidget(_app(keep: [keep], progress: 1, onA: () {}, onTarget: () {}));
      await t.pump();
      final aAfter = await _pixel(t, aPoint);
      final tAfter = await _pixel(t, tPoint);

      expect(aAfter, isNot(aBefore), reason: 'card A text must be covered at progress 1');
      expect(tAfter, tBefore, reason: 'the kept target text must be untouched');
    });

    testWidgets('paintedShapes follows progress in whole units', (t) async {
      // why: the state exposes what was painted. Fixture: no kept target and
      // two cards = 2 units; 0.5 -> exactly unit 0; 0 -> none; 1 -> both.
      skTallView(t);
      Future<SkeletonizeState> at(double p) async {
        await t.pumpWidget(_app(keep: const [], progress: p, onA: () {}, onTarget: () {}));
        await t.pump();
        return t.state<SkeletonizeState>(find.byKey(_sk));
      }
      expect((await at(0)).paintedShapes, isEmpty);
      final half = await at(0.5);
      expect(half.shapes.map((s) => s.section).toSet(), {0, 1});
      expect(half.paintedShapes.map((s) => s.section).toSet(), {0});
      final full = await at(1);
      expect(full.paintedShapes, full.shapes);
    });

    testWidgets('the kept rect is excluded from the state plan too', (t) async {
      // why: widget and pure function must agree; the state's plan is the
      // plan for the keep it was given.
      skTallView(t);
      await t.pumpWidget(_app(keep: const [], progress: 0, onA: () {}, onTarget: () {}));
      final keep = _local(t, find.byKey(const ValueKey('tapT')));
      await t.pumpWidget(_app(keep: [keep], onA: () {}, onTarget: () {}));
      await t.pump();
      final shapes = t.state<SkeletonizeState>(find.byKey(_sk)).shapes;
      expect(shapes, isNotEmpty);
      expect(shapes.where((s) => skOverlaps(s.rect, keep)), isEmpty);
    });
  });
}
