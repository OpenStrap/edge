import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/guides/tree_geometry.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import '../support/bundled_fonts.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;
import '../support/guide_r2_manifest.dart';
import '../support/guide_r2_scroll_fixture.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';

// Catalogue-wide sweeps below are skipped: hardening stage (owner 2026-11-14); code kept.

void main() {
  setUpAll(() async {
    await loadFonts();
    await skLoadAppFonts();
    await r2OpenDb('guide_r2_rules.db');
  });
  tearDownAll(LocalDb.close);

  // WHY: a deleted fixture must fail before a vacuous every-step guard passes.
  // # catches: adding a catalogue step without adding a real-shell scene.
  // proves: CLAIM(guide-covered).
  test('r2 scenes cover all eight guides and every step exactly once', () {
    expect(r2Scenes.map((s) => s.id).toList()..sort(), [
      for (final e in kGuideCatalogue) for (final v in e.guide.variants)
        for (final s in v.steps) '${e.guide.id}/${s.id}',
    ]..sort());
    expect(r2Scenes.length, 22);
    expect(r2Scenes.map((s) => s.guide).toSet().length, 8);
  });

  for (final scene in r2Scenes) {
    // WHY: structural r2: the P1-P9 rules, the large-unit rule and the skeleton-card
    // heading rule apply to EVERY step of EVERY guide on demo data (the pilot gate is gone).
    // # catches: blanket skeletonization, per-line dim/erase, missed kept section,
    // hidden caption context or a shape on chrome/blank scaffold, a large card
    // skeletonized for being near the target, a skeleton card that lost its heading,
    // a caption-offered choice (day tabs, every Discard, every bin) left dim.
    // proves: CLAIM(kept-untouched), CLAIM(guide-covered).
    testWidgets('r2 P1-P9 manifest guard ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene);
      try {
        await settleLiveGuide(t, frames: 18);
        expect(m.run.currentStep?.id, scene.step, reason: 'fixture must show the intended live step');
        final manifest = r2Manifest(t, m, scene);
        await r2WriteManifest(t, scene, manifest);
        expect(manifest['units'], isNotEmpty, reason: 'positive control: the real page supplies classified units');
        expect(manifest['violations'], isEmpty, reason: '${scene.id}: P1-P9 independent component oracle');
      } finally { await disposeR2(t, m); }
    }, skip: true); // hardening stage (owner 2026-11-14)

    // WHY: P6 must explain target absence at intermediate scroll offsets as
    // well as at the final reveal destination; card safety is a per-frame rule.
    // # catches: drawing a clipped outline for an offscreen target, no marker
    // during discovery, or card/dim/skeleton covering the visible target.
    // proves: CLAIM(card-never-covers-target), CLAIM(overlay-reveal).
    testWidgets('r2 visibility at every reached scroll offset ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene);
      final violations = <String>[];
      final offsets = <String>{};
      final observations = <Map<String, Object?>>[];
      try {
        for (var frame = 0; frame < 22; frame++) {
          await settleLiveGuide(t, frames: 1);
          final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
          final page = m.app.runner.routes.page!;
          final positions = [for (final e in builtElements(page))
            if (e is StatefulElement && e.state is ScrollableState)
              (e.state as ScrollableState).position.pixels];
          offsets.add(positions.toString());
          final target = overlay.targetRect;
          final visible = target != null && r2Contains(Offset.zero & r2Size, target);
          final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey);
          final cardFinder = find.byKey(GuideStepCard.cardKey);
          final frameCard = cardFinder.evaluate().isEmpty ? null : t.getRect(cardFinder);
          observations.add({'frame': frame, 'offsets': positions,
            'target': target == null ? null : r2Rect(target),
            'revealProgress': overlay.revealProgress,
            'marker': marker.evaluate().isEmpty ? null : r2Rect(t.getRect(marker)),
            'card': frameCard == null ? null : r2Rect(frameCard)});
          // The original progressive reveal intentionally delays the outline.
          // Once it completes, every position must satisfy the full invariant.
          if (overlay.revealProgress < 1 && visible) continue;
          if (!visible) {
            if (find.byKey(LiveGuideOverlay.scrollMarkerKey).evaluate().isEmpty) {
              violations.add('frame $frame offsets=$positions: offscreen/unbuilt target has no scroll marker');
            } else if (target != null) {
              final rotation = t.widget<RotatedBox>(marker).quarterTurns % 4;
              final expectedDirection = target.top < 0 ? 3 : 1;
              if (rotation != expectedDirection) {
                violations.add('frame $frame: scroll arrow points away from target $target');
              }
            }
          } else if (visible) {
            final outline = find.byKey(LiveGuideOverlay.outlineKey);
            if (outline.evaluate().isEmpty || !r2Contains(t.getRect(outline), target)) {
              violations.add('frame $frame offsets=$positions: target not fully outlined');
            }
            if (frameCard?.overlaps(target) ?? false) violations.add('frame $frame: card covers target');
            if (overlay.paintedShapes.any((s) => s.rect.overlaps(target.deflate(.5)))) {
              violations.add('frame $frame: painted placeholder/dim covers target');
            }
          }
        }
        final file = File('build/guides-r2/${scene.guide}/${scene.step}.scroll.json');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
          'guide': scene.guide, 'step': scene.step, 'observations': observations, 'violations': violations}));
        expect(m.run.currentStep?.id, scene.step);
        expect(offsets, isNotEmpty, reason: 'observed the live page, including non-scroll pages');
        expect(violations, isEmpty, reason: scene.id);
      } finally { await disposeR2(t, m); }
    }, skip: true); // hardening stage (owner 2026-11-14)

    // WHY: D-S1 chrome follows visible routes. Root pushes cover the shell.
    // # catches: S1 reserving an invisible tab strip on a pushed page.
    testWidgets('r2 chrome is confined to visible page on ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene);
      try {
        await settleLiveGuide(t, frames: 18);
        final page = m.app.runner.routes.page!;
        final root = laidOutBox(page)!;
        final visible = (Offset.zero & root.size).intersect(visibleBoundsInRoot(root, root));
        final chrome = defaultSkeletonChrome(page);
        for (final rect in chrome) {
          expect(r2Contains(visible, rect), isTrue, reason: 'no chrome outside visible page: $rect');
        }
        if (scene.shell) {
          final tab = t.getRect(r2Tabs());
          final localTab = tab.shift(-root.localToGlobal(Offset.zero));
          expect(chrome.any((r) => r2Contains(r, localTab)), isTrue);
          expect(t.getRect(find.byKey(GuideStepCard.cardKey)).overlaps(tab), isFalse);
        } else {
          expect(r2Tabs(), findsNothing, reason: 'pushed page covers the shell');
          // A phantom tab strip cannot reserve otherwise blank bottom pixels.
          expect(chrome.where((r) => r.top > root.size.height * .75 && r.width > root.size.width / 2), isEmpty);
        }
      } finally { await disposeR2(t, m); }
    });

    // WHY: gesture wiring must obey tab bounds on every page, not just a
    // correctly configured pure placement helper.
    // # catches: T7 a no-op drag, transient page scrolling, phantom tab bounds, or x drift.
    // proves: CLAIM(card-never-covers-target).
    testWidgets('r2 dragged card stays above tabs on ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene);
      try {
        await settleLiveGuide(t, frames: 18);
        final initial = t.getRect(find.byKey(GuideStepCard.cardKey));
        final positions = [for (final e in builtElements(m.app.runner.routes.page!))
          if (e is StatefulElement && e.state is ScrollableState)
            (e.state as ScrollableState).position];
        var changes = 0;
        void changed() { changes++; }
        for (final p in positions) { p.addListener(changed); }
        addTearDown(() { for (final p in positions) { p.removeListener(changed); } });
        var moved = false;
        for (final dy in [-180.0, 2000.0, -2000.0]) {
          final before = t.getRect(find.byKey(GuideStepCard.cardKey));
          await t.dragFrom(Offset(before.right - 7, before.center.dy), Offset(60, dy));
          await settleLiveGuide(t, frames: 2);
          final card = t.getRect(find.byKey(GuideStepCard.cardKey));
          final bottom = scene.shell ? t.getRect(r2Tabs()).top : r2Size.height;
          moved |= (card.top - before.top).abs() > 1;
          expect(card.left, initial.left);
          expect(card.width, initial.width);
          expect(card.top, greaterThanOrEqualTo(0));
          expect(card.bottom, lessThanOrEqualTo(bottom), reason: scene.id);
          final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
          final target = overlay.targetRect!;
          expect(card.overlaps(target), isFalse);
          expect(card.overlaps(t.getRect(find.byKey(LiveGuideOverlay.tapPillKey))), isFalse);
        }
        expect(moved, isTrue, reason: 'T7: at least one pointer drag really moved the card');
        expect(changes, 0, reason: 'T7: no transient underlying page scrolling');
      } finally { await disposeR2(t, m); }
    });

    if (scene.shell) {
      for (var tab = 0; tab < 4; tab++) {
        // WHY: D-S5 only actual navigation leaves the path; re-taps stay put.
        // # catches: W4 forcing sticky off path on a selected-tab re-tap,
        // or a shield absorbing navigation to a different tab.
        // proves: CLAIM(overlay-pass-through).
        testWidgets('r2 tab $tab navigates off path from ${scene.id}', (t) async {
          final m = await pumpR2Scene(t, scene);
          try {
            await settleLiveGuide(t, frames: 18);
            final before = m.run.currentStep!.id;
            final wasSelected = t.widgetList<Semantics>(find.descendant(of: r2Tab(tab),
              matching: find.byType(Semantics))).any((w) => w.properties.selected == true);
            final rect = t.getRect(r2Tab(tab));
            expect(t.getRect(find.byKey(GuideStepCard.cardKey)).overlaps(rect), isFalse);
            await t.tapAt(rect.center);
            await settleLiveGuide(t, frames: 12);
            if (wasSelected) {
              expect(m.run.state, isA<GuideAtStep>());
              expect(m.run.currentStep?.id, before);
              expect(find.byKey(GuideStepCard.offPathKey), findsNothing);
            } else {
              expect(m.run.state, isA<GuideOffPath>(), reason: 'tab $tab from ${scene.id}');
              expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget);
            }
            final widget = t.widget(r2Tab(tab));
            final selected = find.descendant(of: find.byWidget(widget), matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.selected == true));
            expect(selected, findsOneWidget, reason: 'the requested tab is actually selected');
          } finally { await disposeR2(t, m); }
        });
      }
    }
  }
  {
    // WHY: T4 the visibility invariant applies after user scrolling as well
    // as automatic reveal in the dim pilot; legacy absorb remains a control.
    // # catches: W5 marker tied only to automatic reveal; a clipped outline
    // remains after user scrolling, or global input shield swallows the drag.
    testWidgets('r2 user scroll away and back updates marker direction', (t) async {
      final f = R2ScrollFixture();
      await f.pump(t);
      final initial = t.getRect(find.byKey(r2ScrollTarget));
      expect(r2Contains(const Rect.fromLTWH(0, 0, 390, 780), initial), isTrue);
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsOneWidget);
      final before = f.controller.offset;
      // Left edge is outside the card's full-width-but-inset box.
      await t.dragFrom(const Offset(4, 360), const Offset(0, -600));
      await t.pump(const Duration(milliseconds: 50));
      final away = t.getRect(find.byKey(r2ScrollTarget));
      expect(f.controller.offset, greaterThan(before + 300), reason: 'real user scroll reached page');
      expect(away.bottom, lessThan(0), reason: 'target really moved above viewport');
      final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey);
      expect(marker, findsOneWidget);
      expect(t.widget<RotatedBox>(marker).quarterTurns % 4, 3, reason: 'points UP toward hidden target');
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing, reason: 'no clipped outline');
      await t.dragFrom(const Offset(4, 100), const Offset(0, 600));
      await t.pump(const Duration(milliseconds: 50));
      final returned = t.getRect(find.byKey(r2ScrollTarget));
      expect(r2Contains(const Rect.fromLTWH(0, 0, 390, 780), returned), isTrue);
      expect(find.byKey(LiveGuideOverlay.outlineKey), findsOneWidget);
      expect(r2Contains(t.getRect(find.byKey(LiveGuideOverlay.outlineKey)), returned), isTrue);
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      expect(overlay.paintedShapes.where((s) => s.rect.overlaps(returned.deflate(.5))), isEmpty);
      expect(t.getRect(find.byKey(GuideStepCard.cardKey)).overlaps(returned), isFalse);
      expect(f.run.currentStep?.id, 'target');
    });
  }

}
