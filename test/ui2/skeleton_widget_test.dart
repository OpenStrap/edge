// Skeletonize + SkeletonBar/SkeletonBlock: what the user sees, touches and
// hears. Skeletonize takes GuideTargets (no snapshot rects) and recomputes its
// plan from the live tree after every layout.
//
// Pixel checks compare the SAME pixels with the overlay at progress 0 and 1, so
// no skeleton colour is hard-coded (that is a design token, not a claim).

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/skeleton_fixture.dart';
import '../support/guide_text.dart';

// Ahem by name: the theme's own family would fall back to a system font, and the
// pixel and size oracles below need glyphs that are exact font-size squares.
const _ahem = TextStyle(fontFamily: 'Ahem', fontSize: 10, height: 1, letterSpacing: 0);
const _shot = ValueKey('shot');
const _sk = ValueKey('sk');
const _tapA = ValueKey('tapA');
const _tapT = ValueKey('tapT');

GuideTarget get _target => GuideTarget.key(_tapT);

/// Card A (text + a tappable), card B (text + the TARGET tappable).
Widget _cards({required VoidCallback onA, required VoidCallback onTarget}) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Surface(
          child: Column(children: [
            const Text('A text', style: _ahem),
            GestureDetector(
              key: _tapA,
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
              key: _tapT,
              behavior: HitTestBehavior.opaque,
              onTap: onTarget,
              child: const SizedBox(height: 30, width: 100, child: Text('target', style: _ahem)),
            ),
          ]),
        ),
      ],
    );

Widget _app({
  List<GuideTarget>? keep,
  List<GuideTarget> alsoKeep = const [],
  double progress = 1,
  VoidCallback? onA,
  VoidCallback? onTarget,
  Widget? child,
  SkeletonChrome? chrome,
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
              keep: keep ?? [_target],
              alsoKeep: alsoKeep,
              progress: progress,
              chrome: chrome ?? const DefaultSkeletonChrome(),
              child: ColoredBox(
                color: const Color(0xFFFFFFFF),
                child: child ?? _cards(onA: onA ?? () {}, onTarget: onTarget ?? () {}),
              ),
            ),
          ),
        ),
      ),
    ));

Rect _local(WidgetTester t, Finder f) => skLocalRect(t, f, find.byKey(_shot));
SkeletonizeState _state(WidgetTester t) => t.state<SkeletonizeState>(find.byKey(_sk));

/// RGBA of every pixel of [r] (rounded inward) in the shot.
Future<List<List<int>>> _pixels(WidgetTester t, Rect r) async {
  late List<List<int>> out;
  await t.runAsync(() async {
    final b = t.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
    final img = await b.toImage();
    final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    out = [];
    for (var y = r.top.ceil(); y < r.bottom.floor(); y++) {
      for (var x = r.left.ceil(); x < r.right.floor(); x++) {
        final i = (y * img.width + x) * 4;
        out.add([for (var k = 0; k < 4; k++) data.getUint8(i + k)]);
      }
    }
  });
  return out;
}

bool _same(List<int> a, List<int> b) => a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];

void main() {
  group('SkeletonBar / SkeletonBlock', () {
    testWidgets('take exactly the size asked for and are rounded', (t) async {
      // why: reusable loading placeholders; a wrong size or square corners
      // breaks the look wherever they are reused.
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
        final deco = t
            .widget<DecoratedBox>(find
                .descendant(of: find.byKey(ValueKey(k)), matching: find.byType(DecoratedBox))
                .first)
            .decoration as BoxDecoration;
        expect(deco.borderRadius, isNotNull, reason: '$k is rounded');
        expect(deco.color, isNotNull, reason: '$k is filled');
      }
    });

    testWidgets('colours come from the app tokens: light and dark differ', (t) async {
      // why: "plain widgets in the app's tokens (P.of)": a hard-coded grey is
      // invisible on one of the two themes.
      Future<Color?> colour(Brightness b) async {
        await t.pumpWidget(skHost(const Scaffold(body: SkeletonBar(width: 50)), brightness: b));
        await t.pumpAndSettle(); // MaterialApp animates a theme change (200 ms)
        final box = t.widget<DecoratedBox>(
            find.descendant(of: find.byType(SkeletonBar), matching: find.byType(DecoratedBox)).first);
        return (box.decoration as BoxDecoration).color;
      }

      expect(await colour(Brightness.light), isNot(await colour(Brightness.dark)));
    });

    testWidgets('no animation by default', (t) async {
      // why: spec 1.1; a shimmer ticker would keep pumpAndSettle from settling.
      await t.pumpWidget(skHost(const Scaffold(
        body: Column(children: [SkeletonBar(width: 50), SkeletonBlock(height: 20)]),
      )));
      await t.pump(const Duration(seconds: 1));
      expect(t.binding.transientCallbackCount, 0);
    });
  });

  group('pointer events', () {
    testWidgets('a skeletonized section absorbs taps; the kept target still gets them', (t) async {
      // why: while a guide shows, only the target may act; every other card is
      // painted over and must not fire. Positive control in the same test: the
      // kept tappable DOES fire.
      skTallView(t);
      var a = 0, target = 0;
      await t.pumpWidget(_app(onA: () => a++, onTarget: () => target++));
      await t.pump();
      await t.tap(find.byKey(_tapA), warnIfMissed: false);
      await t.tap(find.byKey(_tapT), warnIfMissed: false);
      expect(a, 0, reason: 'card A is skeletonized: tap absorbed');
      expect(target, 1, reason: 'the kept target must stay tappable');
    });

    testWidgets('nothing is absorbed until a section is actually painted (progress 0)', (t) async {
      // why: absorption follows the painted skeleton; the screen must not be
      // dead while the overlay is still invisible.
      skTallView(t);
      var a = 0;
      await t.pumpWidget(_app(progress: 0, onA: () => a++));
      await t.pump();
      await t.tap(find.byKey(_tapA), warnIfMissed: false);
      expect(a, 1);
    });

    testWidgets('chrome stays tappable: a tab bar tap reaches AppShell under the overlay (item 11)', (t) async {
      // why: the default chrome resolver finds AppShell's private tab bar BY
      // TYPE. If it did not, the overlay would cover and absorb the tabs.
      skTallView(t, w: 400, h: 800);
      await t.pumpWidget(skHost(
        Skeletonize(
          keep: const [],
          child: AppShell(
            builder: (c, d) => ListView(children: [
              Surface(child: Text('page ${d.name}')),
            ]),
          ),
        ),
      ));
      await t.pump();
      expect(find.text('page today'), findsOneWidget);
      await t.tap(find.text('Sleep'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('page sleep'), findsOneWidget, reason: 'the tab must have switched');
    });
  });

  group('painting', () {
    testWidgets('progress 0 leaves pixels alone; 1 covers skeletonized text, not the target', (t) async {
      // why: the overlay really paints. Same pixel, two progress values: card
      // A's text must CHANGE, the kept target's text must stay IDENTICAL. Also
      // exercises repaint when only `progress` changes.
      skTallView(t);
      await t.pumpWidget(_app(progress: 0));
      await t.pump();
      final aLine = _local(t, find.text('A text'));
      final tLine = _local(t, find.text('target'));
      // whole-pixel probes: _pixels reads nothing for a rect straddling pixels
      final aPoint = Rect.fromLTWH((aLine.left + 3).floorToDouble(), aLine.center.dy.floorToDouble(), 1, 1);
      final tPoint = Rect.fromLTWH((tLine.left + 3).floorToDouble(), tLine.center.dy.floorToDouble(), 1, 1);
      final aBefore = (await _pixels(t, aPoint)).single;
      final tBefore = (await _pixels(t, tPoint)).single;

      await t.pumpWidget(_app(progress: 1));
      await t.pump();
      expect(_same((await _pixels(t, aPoint)).single, aBefore), isFalse, reason: 'card A text must be covered');
      expect(_same((await _pixels(t, tPoint)).single, tBefore), isTrue, reason: 'target text must be untouched');
    });

    testWidgets('loose text and Section headings: NO glyph pixel survives under their bars (item 10, G2)', (t) async {
      // why: bars are rounded; over bare scaffold the glyph squares (Ahem: solid
      // ink) would poke out at the corners unless the plan erases first. The
      // three texts have DIFFERENT foregrounds (loose: default text colour,
      // heading: p.ink, action: p.on(C.blue)), so a single sampled ink colour
      // (the old test) would miss two of them. Instead: per text, the foreground
      // mask = every pixel of its line box that is not the white ColoredBox
      // background at progress 0; then each mask pixel (corners outside the
      // rounded bar included) must have a DIFFERENT value at progress 1.
      skTallView(t);
      Widget app(double progress) => _app(
            progress: progress,
            keep: const [],
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: const [
              Padding(padding: EdgeInsets.all(8), child: Text('loose line here', style: _ahem)),
              Section('Heading', SizedBox(height: 10), action: 'Act'),
            ]),
          );
      await t.pumpWidget(app(0));
      await t.pump();
      final lines = [
        for (final s in ['loose line here', 'Heading', 'Act']) _local(t, find.text(s)),
      ];
      const white = [255, 255, 255, 255];
      final before = [for (final r in lines) await _pixels(t, r)];
      final masks = [
        for (final px in before) [for (var i = 0; i < px.length; i++) if (!_same(px[i], white)) i],
      ];
      // positive control: each text really has foreground pixels at progress 0,
      // and the three foregrounds are not one colour.
      for (var k = 0; k < lines.length; k++) {
        expect(masks[k], isNotEmpty, reason: 'no foreground pixel at progress 0 in ${lines[k]}');
      }
      final colours = {for (var k = 0; k < 3; k++) before[k][masks[k].first].join(',')};
      expect(colours.length, greaterThan(1), reason: 'oracle sanity: the texts differ in foreground colour');

      await t.pumpWidget(app(1));
      await t.pump();
      for (var k = 0; k < lines.length; k++) {
        final after = await _pixels(t, lines[k]);
        final survivors = masks[k].where((i) => _same(after[i], before[k][i])).length;
        expect(survivors, 0, reason: '$survivors of ${masks[k].length} glyph pixels survive in ${lines[k]}');
      }
    });

    testWidgets('paintedShapes follows progress in whole units; shapes is the full plan', (t) async {
      // why: fixture has two cards = 2 units; 0.5 -> exactly unit 0; 0 -> none.
      skTallView(t);
      Future<SkeletonizeState> at(double p) async {
        await t.pumpWidget(_app(keep: const [], progress: p));
        await t.pump();
        return _state(t);
      }

      expect((await at(0)).paintedShapes, isEmpty);
      final half = await at(0.5);
      expect(half.shapes.map((s) => s.section).toSet(), {0, 1});
      expect(half.paintedShapes.map((s) => s.section).toSet(), {0});
      final full = await at(1);
      expect(full.paintedShapes, full.shapes);
    });
  });

  group('live plan: targets, not snapshots (item 3)', () {
    Widget scrolling(ScrollController c, {int cards = 6}) => skHost(Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 300,
              child: Skeletonize(
                key: _sk,
                keep: [_target],
                child: ListView(
                  controller: c,
                  cacheExtent: 2000,
                  padding: EdgeInsets.zero,
                  children: [
                    for (var i = 0; i < cards; i++)
                      Surface(
                        key: ValueKey('card$i'),
                        child: i == 3
                            ? GestureDetector(key: _tapT, onTap: () {}, child: const Text('target', style: _ahem))
                            : Text('card $i', style: _ahem),
                      ),
                    const SizedBox(height: 900),
                  ],
                ),
              ),
            ),
          ),
        ));

    testWidgets('scrolling under ONE mounted overlay: shapes follow the cards, the target stays clear', (t) async {
      // why: a snapshot plan taken before the scroll would cover the target and
      // leave the other cards uncovered. Oracle: the cards' real rects, read
      // from the tree after each scroll. Same State instance throughout.
      skTallView(t);
      final c = ScrollController();
      addTearDown(c.dispose);
      await t.pumpWidget(scrolling(c));
      await t.pump();
      final state = _state(t);
      final root = find.byType(Skeletonize);

      void check(String when) {
        expect(state.resolutions.single, isA<TargetFound>(), reason: when);
        final target = skLocalRect(t, find.byKey(_tapT), root);
        final surfaces = state.shapes.where((s) => s.kind == SkeletonKind.surface).toList();
        for (final s in state.shapes) {
          expect(skOverlaps(s.rect, target), isFalse, reason: '$when: ${s.kind} ${s.rect} hits target $target');
        }
        // every other VISIBLE card has a surface shape on it (clipped to the 300 px viewport)
        const viewport = Rect.fromLTWH(0, 0, 300, 300);
        for (final i in [0, 1, 2, 4, 5]) {
          final card = skLocalRect(t, find.byKey(ValueKey('card$i'), skipOffstage: false), root).intersect(viewport);
          if (card.isEmpty) continue;
          expect(surfaces.any((s) => (s.rect.top - card.top).abs() < 0.6 && (s.rect.bottom - card.bottom).abs() < 0.6),
              isTrue, reason: '$when: no surface on card $i at $card; have ${surfaces.map((s) => s.rect)}');
        }
      }

      check('initial');
      final before = [for (final s in state.shapes) s.rect];
      c.jumpTo(100);
      await t.pump();
      expect(identical(_state(t), state), isTrue, reason: 'overlay must not be remounted');
      check('after scroll');
      expect([for (final s in state.shapes) s.rect], isNot(before));
    });

    testWidgets('replacing the content under the same mounted overlay replans', (t) async {
      // why: data rebuilds (a screen finishing its load) swap the whole subtree;
      // the plan must follow without anyone calling refresh.
      skTallView(t);
      await t.pumpWidget(_app());
      await t.pump();
      final state = _state(t);
      expect(state.shapes.where((s) => s.kind == SkeletonKind.surface), hasLength(1), reason: 'card A (B is kept)');

      await t.pumpWidget(_app(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Surface(child: Text('new one', style: _ahem)),
          const Surface(child: Text('new two', style: _ahem)),
          Surface(child: GestureDetector(key: _tapT, onTap: () {}, child: const Text('target', style: _ahem))),
        ]),
      ));
      await t.pump();
      expect(identical(_state(t), state), isTrue);
      expect(state.shapes.where((s) => s.kind == SkeletonKind.surface), hasLength(2));
      expect(state.shapes.where((s) => s.kind == SkeletonKind.bar), hasLength(2));
    });

    testWidgets('a keep target that cannot be resolved yields NO shapes and absorbs nothing', (t) async {
      // why: never cover a screen whose target cannot be found (the reader
      // would see a skeleton with nothing to tap). The reason stays readable.
      skTallView(t);
      var a = 0;
      await t.pumpWidget(_app(keep: [GuideTarget.key(const ValueKey('nope'))], onA: () => a++));
      await t.pump();
      final state = _state(t);
      expect(state.shapes, isEmpty);
      expect(state.paintedShapes, isEmpty);
      expect(state.resolutions.single, isA<TargetAbsent>());
      await t.tap(find.byKey(_tapA), warnIfMissed: false);
      expect(a, 1);
    });

    testWidgets('alsoKeep leaves extra units readable; an unresolved alsoKeep is skipped, not fatal', (t) async {
      // why: step 3 keeps "Your zones" besides the link.
      skTallView(t);
      await t.pumpWidget(_app(alsoKeep: [GuideTarget.key(_tapA)]));
      await t.pump();
      expect(_state(t).shapes, isEmpty, reason: 'both cards kept');

      await t.pumpWidget(_app(alsoKeep: [GuideTarget.key(const ValueKey('nope'))]));
      await t.pump();
      expect(_state(t).shapes.where((s) => s.kind == SkeletonKind.surface), hasLength(1), reason: 'card A still covered');
      expect(_state(t).resolutions, hasLength(1), reason: 'resolutions describe keep only');
    });

    testWidgets('a custom chrome resolver decides what stays legible', (t) async {
      // why: chrome comes from a resolver, not a rect list. Positive control:
      // with the default resolver (no ScreenTitle here) the same text is covered.
      skTallView(t);
      Widget app(SkeletonChrome? chrome) => _app(
            chrome: chrome,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Chrome text', style: _ahem),
              _cards(onA: () {}, onTarget: () {}),
            ]),
          );
      const strip = Rect.fromLTWH(0, 0, 300, 10);
      await t.pumpWidget(app(null));
      await t.pump();
      expect(_state(t).shapes.where((s) => skOverlaps(s.rect, strip)), isNotEmpty);
      await t.pumpWidget(app(FnChrome((root) => const [strip])));
      await t.pump();
      expect(_state(t).shapes.where((s) => skOverlaps(s.rect, strip)), isEmpty);
    });
  });

  group('defaultSkeletonChrome (item 11)', () {
    testWidgets('finds ScreenTitle and NavBar by type, nothing else', (t) async {
      // why: the title bar must stay legible on every detail screen.
      skTallView(t);
      const root = ValueKey('root');
      await t.pumpWidget(skHost(Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: root,
            width: 300,
            child: Column(children: [
              NavBar('Nav', onBack: () {}),
              const ScreenTitle('Title'),
              const Surface(child: Text('body')),
            ]),
          ),
        ),
      )));
      final rects = defaultSkeletonChrome(t.element(find.byKey(root)));
      for (final f in [find.byType(NavBar), find.byType(ScreenTitle)]) {
        final r = skLocalRect(t, f, find.byKey(root));
        expect(rects.any((c) => skContains(c, r)), isTrue, reason: '$f not in $rects');
      }
      final body = skLocalRect(t, find.byType(Surface), find.byKey(root));
      expect(rects.where((c) => c.overlaps(body)), isEmpty);
    });

    testWidgets("finds AppShell's tab bar by type without app_shell.dart changes", (t) async {
      // why: the real bottom navigation is a private _TabBar (app_shell.dart:215).
      // The resolver must cover all four tabs and only them.
      skTallView(t, w: 400, h: 800);
      const root = ValueKey('root');
      await t.pumpWidget(skHost(SizedBox(
        key: root,
        width: 400,
        height: 800,
        child: AppShell(builder: (c, d) => Center(child: Text('page ${d.name}'))),
      )));
      final rects = defaultSkeletonChrome(t.element(find.byKey(root)));
      final tabs = [for (final l in ['Today', 'Sleep', 'Activity', 'Health']) skLocalRect(t, find.text(l), find.byKey(root))];
      expect(rects.any((c) => tabs.every((r) => skContains(c, r))), isTrue, reason: 'one chrome rect must hold all 4 tabs: $rects');
      final page = skLocalRect(t, find.text('page today'), find.byKey(root));
      expect(rects.where((c) => c.overlaps(page)), isEmpty);
    });

    testWidgets('a plain tree has no chrome', (t) async {
      // why: nothing to find must mean nothing returned, not the whole root.
      skTallView(t);
      await t.pumpWidget(_app());
      expect(defaultSkeletonChrome(t.element(find.byKey(_sk))), isEmpty);
    });
  });

  group('semantics (item 7)', () {
    Widget app(double progress) => _app(
          progress: progress,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const ScreenTitle('Chrome title'),
            Surface(
              child: Semantics(
                button: true,
                label: 'cover me',
                child: GestureDetector(onTap: () {}, child: const Text('A text', style: _ahem)),
              ),
            ),
            Surface(
              child: Semantics(
                button: true,
                label: 'the target',
                child: GestureDetector(key: _tapT, onTap: () {}, child: const Text('target', style: _ahem)),
              ),
            ),
          ]),
        );

    testWidgets('covered units leave the semantics tree; target and chrome keep theirs; it follows progress', (t) async {
      // why: painted-over content must not be announced or activatable by a
      // screen reader (the sighted reader cannot see it either).
      final h = t.ensureSemantics();
      skTallView(t);

      await t.pumpWidget(app(0));
      await t.pump();
      expect(skHasSemanticsLabel(t, 'cover me'), isTrue, reason: 'progress 0 covers nothing');

      await t.pumpWidget(app(1));
      await t.pump();
      expect(skHasSemanticsLabel(t, 'cover me'), isFalse, reason: 'covered: excluded');
      expect(skHasSemanticsLabel(t, 'the target'), isTrue, reason: 'target keeps its semantics');
      expect(skHasSemanticsLabel(t, 'Chrome title'), isTrue, reason: 'chrome keeps its semantics');

      await t.pumpWidget(app(0));
      await t.pump();
      expect(skHasSemanticsLabel(t, 'cover me'), isTrue, reason: 'back to progress 0 restores it');
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose();
    });
  });
}
