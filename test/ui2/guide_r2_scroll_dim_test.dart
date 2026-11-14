// OWNER BUG (phone, 2026-11-14): scrolling down the Activity page, items that should
// be dimmed showed UNDIMMED during the scroll and during Android's end-of-scroll
// stretch (overscroll); they dimmed again only after the overlay re-planned.
// Requirement: dimmed items stay dimmed in EVERY frame, whatever scrolls, flings or
// stretches them; kept items (target, alsoTap/alsoRead, chrome, route back) are never
// dimmed mid-scroll.
//
// How it is checked: the test pumps in small steps (16 ms, never pumpAndSettle), and on
// EVERY frame reads the composited pixels of the whole screen. In light theme a pixel
// of a dimmed component lies at most (1 - kDimOpacity) of the way from the scaffold
// colour, so no dimmed pixel is further than kFarFromScaffold from it, while the
// original ink of text and coloured banners is far further. Frames are not compared to
// the plan's rectangles (the plan may be stale; the screen is what the user sees).
//
// INTENDED GREEN (owner design): the dim is painted by the components themselves
// (GuideDimScope), so it moves with the content by construction; this test must then
// pass without any per-frame re-planning.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import '../support/bundled_fonts.dart';
import '../support/guide_r2_fixture.dart' show r2Capture;
import '../support/guide_r2_flow_fixture.dart';
import '../support/guide_r2_manifest.dart';
import '../support/guide_r2_pixels.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

/// Dimming leaves at most 28% of an ink's distance from the scaffold colour: 255 * .28 = 71.
/// Anything further than this is undimmed ink. (Derived from kDimOpacity, with margin.)
const kFarFromScaffold = 90;
/// Ink of kept content (dark text on a light card) is at least this far from the scaffold.
const kInkFromScaffold = 150;

/// What one audited frame saw.
class _Frame {
  final int index;
  final String when;
  _Frame(this.index, this.when);
  final undimmed = <String>[];
  final dimmedKept = <String>[];
  bool audited = false;
}

/// Reads the whole screen on the current frame. [target] is the live target rect (null
/// skips the frame: with the target off screen the content collapses to skeleton, P6).
Future<_Frame> _audit(WidgetTester t, int index, String when, {
  required Future<R2Raster> Function() raster,
  required Rect? target,
  required List<Rect> chrome,
  required List<(String, Rect)> kept,
}) async {
  final frame = _Frame(index, when);
  final screen = Offset.zero & (t.view.physicalSize / t.view.devicePixelRatio);
  if (target == null || !screen.contains(target.topLeft) || !screen.contains(target.bottomRight)) return frame;
  frame.audited = true;
  final r = await raster();
  final scaffold = r2Rgb(buildTheme(Brightness.light).scaffoldBackgroundColor);
  final exclude = <Rect>[
    target.inflate(14), // the outline
    ...chrome.map((c) => c.inflate(2)),
    ...kept.map((k) => k.$2.inflate(2)),
  ];
  for (final key in [GuideStepCard.cardKey, LiveGuideOverlay.tapPillKey, LiveGuideOverlay.outlineKey]) {
    final f = find.byKey(key);
    if (f.evaluate().isNotEmpty) exclude.add(t.getRect(f).inflate(4));
  }
  var shown = 0;
  for (var y = 0; y < screen.height; y += 4) {
    for (var x = 0; x < screen.width; x += 4) {
      final p = Offset(x.toDouble(), y.toDouble());
      if (exclude.any((e) => e.contains(p))) continue;
      final d = r2Distance(r.at(x, y), scaffold);
      if (d > kFarFromScaffold && shown++ < 3) frame.undimmed.add('($x,$y) is ${r.at(x, y)}, $d from the scaffold');
    }
  }
  for (final (name, rect) in [(' target', target), ...kept]) {
    final visible = rect.intersect(screen);
    if (visible.isEmpty || visible.width * visible.height < 300) continue;
    final card = find.byKey(GuideStepCard.cardKey);
    if (card.evaluate().isNotEmpty && t.getRect(card).overlaps(visible)) continue;
    if (r2MaxDistance(r, visible.deflate(1), scaffold) < kInkFromScaffold) frame.dimmedKept.add('$name $rect has lost its ink');
  }
  return frame;
}

/// Pointer script: [moves] steps of [dy] logical px, 16 ms apart with timestamps (so a
/// release is a fling), audited after each, then [after] frames of the aftermath.
Future<List<_Frame>> _script(WidgetTester t, Offset start, double dy, int moves, int after, String name,
    Future<_Frame> Function(int, String) audit) async {
  final frames = <_Frame>[];
  var clock = Duration.zero;
  final g = await t.startGesture(start);
  for (var i = 0; i < moves; i++) {
    clock += const Duration(milliseconds: 16);
    await g.moveBy(Offset(0, dy), timeStamp: clock);
    await t.pump(const Duration(milliseconds: 16));
    frames.add(await audit(frames.length, '$name: finger moving'));
  }
  clock += const Duration(milliseconds: 16);
  await g.up(timeStamp: clock);
  for (var i = 0; i < after; i++) {
    await t.pump(const Duration(milliseconds: 16));
    frames.add(await audit(frames.length, '$name: after release'));
  }
  return frames;
}

void _expectClean(List<_Frame> frames, {required int minAudited}) {
  final audited = frames.where((f) => f.audited).toList();
  expect(audited.length, greaterThanOrEqualTo(minAudited), reason: 'the script really produced audited frames');
  final bad = [for (final f in audited) if (f.undimmed.isNotEmpty) 'frame ${f.index} (${f.when}): undimmed ${f.undimmed}'];
  expect(bad, isEmpty, reason: 'dimmed items must be dimmed in EVERY frame');
  final lost = [for (final f in audited) if (f.dimmedKept.isNotEmpty) 'frame ${f.index} (${f.when}): ${f.dimmedKept}'];
  expect(lost, isEmpty, reason: 'kept items must never be dimmed mid-scroll');
}

// Deferred to hardening (owner 2026-11-14): frame-by-frame pixel sampling and contrast
// sweeps are symptom harnesses. The construction they check (the dim painted by the
// component itself) is pinned by guide_r2_structural_test.
void testWidgets(String description, Future<void> Function(WidgetTester) body) =>
    ft.testWidgets(description, body, skip: true);

void main() {
  setUpAll(() async {
    await loadFonts();
    await skLoadAppFonts();
    await r2OpenDb('guide_r2_scroll_dim.db');
  });
  tearDownAll(LocalDb.close);

  group('fixture page: pinned target over a long list', () {
    Future<(R2FlowFixture, Future<_Frame> Function(int, String))> setup(WidgetTester t) async {
      final f = R2FlowFixture();
      await f.pump(t);
      final settled = await _audit(t, -1, 'settled', raster: () => r2Raster(t, find.byKey(r2Capture)),
        target: t.getRect(find.byKey(flowTarget)), chrome: [t.getRect(find.byType(ScreenTitle))],
        kept: [('kept note', t.getRect(find.byKey(flowKept)))]);
      expect(settled.audited, isTrue);
      expect(settled.undimmed, isEmpty, reason: 'positive control: the settled page passes the audit');
      expect(settled.dimmedKept, isEmpty, reason: 'positive control: kept content has its ink when settled');
      Future<_Frame> audit(int i, String when) async {
        final page = f.routes.page!;
        final kept = [for (final r in [GuideTarget.key(flowKept).resolve(page, r2Locale)])
          if (r is TargetFound) ('kept note', r.rect)];
        return _audit(t, i, when, raster: () => r2Raster(t, find.byKey(r2Capture)),
          target: t.getRect(find.byKey(flowTarget)), chrome: [t.getRect(find.byType(ScreenTitle))], kept: kept);
      }
      return (f, audit);
    }

    // WHY: owner bug: dimmed content flashes undimmed while it scrolls and flings.
    // # catches: dim painted in the overlay from a plan one frame behind the scroll, so
    // every moving unit is bright until the next re-plan; kept content that is dimmed
    // because the hole did not follow it.
    testWidgets('r2 dim holds on every frame of a drag and fling', (t) async {
      final (f, audit) = await setup(t);
      final frames = await _script(t, const Offset(200, 330), -40, 10, 60, 'drag+fling', audit);
      expect(f.controller.offset, greaterThan(300), reason: 'positive control: the list really scrolled');
      _expectClean(frames, minAudited: 40);
    });

    // WHY: owner bug at the stretch: Android's overscroll stretch transforms the list
    // without changing layout; a plan built from layout rects leaves the stretched
    // content bright.
    // # catches: dim tied to layout geometry instead of the painted content; reveal of
    // undimmed pixels at the stretched edge.
    testWidgets('r2 dim holds on every frame of the overscroll stretch at the top', (t) async {
      final (f, audit) = await setup(t);
      expect(f.controller.offset, 0);
      final frames = await _script(t, const Offset(200, 330), 35, 8, 50, 'overscroll top', audit);
      _expectClean(frames, minAudited: 40);
    });

    // WHY: the other end of the same effect.
    // # catches: a fix that only covers the top edge.
    testWidgets('r2 dim holds on every frame of the overscroll stretch at the bottom', (t) async {
      final (f, audit) = await setup(t);
      f.controller.jumpTo(f.controller.position.maxScrollExtent);
      await t.pump(const Duration(milliseconds: 16));
      final frames = await _script(t, const Offset(200, 500), -35, 8, 50, 'overscroll bottom', audit);
      expect(f.controller.position.pixels, closeTo(f.controller.position.maxScrollExtent, 80),
        reason: 'positive control: the drag stayed at the end of the list');
      _expectClean(frames, minAudited: 40);
    });

    // WHY: kept content moves with the list; it must keep its ink at its CURRENT place on
    // every frame, not only where it was planned.
    // # catches: hole rects frozen at the settled position (kept note dimmed after it moves).
    testWidgets('r2 the caption-named note keeps its ink while it scrolls through the screen', (t) async {
      final (f, audit) = await setup(t);
      final before = t.getRect(find.byKey(flowKept));
      final frames = await _script(t, const Offset(200, 330), -25, 8, 4, 'slow drag', audit);
      expect(t.getRect(find.byKey(flowKept)).top, lessThan(before.top - 100), reason: 'positive control: the note moved');
      expect(frames.where((f) => f.audited).length, greaterThanOrEqualTo(10));
      expect([for (final fr in frames) ...fr.dimmedKept], isEmpty);
      expect(f.controller.offset, greaterThan(150));
    });
  });

  group('real Activity page (log-past-workout / open-history)', () {
    // WHY: the owner's exact report: the Activity page. Same audit on the real screen,
    // real data, real overscroll behaviour of the shell.
    // # catches: the fixture passing while the real page (nested scrollables, charts,
    // accordions) still flashes bright.
    for (final (id, size, name, dy, moves, from) in [
      ('log-past-workout/open-history', r2Size, 'overscroll at the top', 35.0, 8, const Offset(200, 480)),
      ('log-past-workout/open-history', r2Size, 'short drag and fling', -30.0, 6, const Offset(200, 480)),
      // A short screen, so the Day strain page scrolls toward and past its target.
      ('heart-rate-zones/open-zones', const Size(412, 520), 'overscroll at the top', 35.0, 8, const Offset(200, 260)),
      ('heart-rate-zones/open-zones', const Size(412, 520), 'short drag and fling', -20.0, 6, const Offset(200, 260)),
    ]) {
      testWidgets('r2 $id: dim holds on every frame of $name', (t) async {
        final scene = r2Scenes.firstWhere((s) => s.id == id);
        final m = await pumpR2Scene(t, scene, size: size);
        try {
          await settleLiveGuide(t, frames: 18);
          final step = m.run.variant.steps.firstWhere((s) => s.id == scene.step);
          final page = m.app.runner.routes.page!;
          final boundary = r2RootBoundary(t, find.byType(LiveGuideOverlay));
          Future<_Frame> audit(int i, String when) async {
            final resolved = step.target.resolve(page, r2Locale);
            return _audit(t, i, when, raster: () => r2RasterOf(t, boundary),
              target: resolved is TargetFound ? resolved.rect : null,
              chrome: defaultSkeletonChrome(page), kept: [for (final r in r2Kept(page, step).skip(1)) ('kept', r)]);
          }
          final first = await audit(-1, 'settled');
          expect(first.audited, isTrue, reason: 'positive control: target on screen when settled');
          expect(first.undimmed, isEmpty, reason: 'positive control: the settled screen passes');
          final frames = await _script(t, from, dy, moves, 40, name, audit);
          _expectClean(frames, minAudited: 8);
        } finally { await disposeR2(t, m); }
      });
    }
  });
}
