// Phone feedback round (owner, 2026-11-14, APK 09bc0763): the dim and the
// placeholders on the owner's three pages, on the REAL screens with device-like
// data (a drawn Day strain curve, not the fixture's trace-less day).
//
// Also an opt-in screenshot capture (GUIDE_RERENDER_DIR): 412x915, dpr 2.625,
// real fonts, dark, en. Not a golden.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Section, Surface;
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:path/path.dart' as p;

import '../support/bundled_fonts.dart';
import '../support/guide_r2_scenes.dart' show r2OpenDb;
import '../support/live_guide_harness.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

final _out = Platform.environment['GUIDE_RERENDER_DIR'];
const _screen = Size(412, 915);
const _dpr = 2.625;

/// A day with a drawn strain curve, like the phone's (the shared fixture has none).
class DeviceLikeRepo extends GuideFakeRepo {
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async {
    final n = DateTime.now();
    final start = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch ~/ 1000;
    return {
      ...await super.getDayStrain(date),
      'strain': 3.2,
      'hr': {'max': 141},
      'curve': [
        for (var m = 0; m < 305; m++) {'t': start + m * 60, 'v': 3.3 * (1 - 1 / (1 + m / 20))},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {'worn_min': 304, 'coverage_pct': 94};
}

Guide _guide(String id) => kGuideCatalogue.map((e) => e.guide).firstWhere((g) => g.id == id);

Future<LiveGuideApp> _start(WidgetTester t, String id, GlobalKey key) async {
  final app = await pumpLiveGuideApp(t,
      size: _screen, devicePixelRatio: _dpr, brightness: Brightness.dark, captureKey: key, repo: DeviceLikeRepo());
  final started = await app.runner.start(_guide(id), band: null);
  expect(started, isA<GuideStarted>());
  await settleLiveGuide(t, frames: 14);
  final overlay = _overlay(t);
  for (var frame = 0; frame < 100; frame++) {
    final page = app.runner.routes.page;
    final step = app.runner.activeRun?.currentStep;
    if (page != null && step != null && !overlay.isSearching &&
        overlay.revealProgress == 1 &&
        step.target.resolve(page, AppLocalizations.of(page)!) is TargetFound) {
      break;
    }
    await settleLiveGuide(t, frames: 1);
  }
  return app;
}

LiveGuideOverlayState _overlay(WidgetTester t) => t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));

Future<void> _png(WidgetTester t, GlobalKey key, String name) async {
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await t.runAsync(() async {
    t.binding.rootPipelineOwner.flushPaint();
    final image = await boundary.toImage(pixelRatio: _dpr);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(p.join(_out!, name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// The shapes covering [at] (a point in screen coordinates).
Iterable<SkeletonShape> _over(LiveGuideOverlayState o, Rect r) =>
    o.paintedShapes.where((s) => s.rect.overlaps(r));

/// Debug: the top-level components and the plan's shapes, one line each.
void _dump(WidgetTester t, String tag) {
  final o = _overlay(t);
  final buf = StringBuffer('DUMP $tag\n');
  for (final s in o.paintedShapes) {
    buf.writeln('  shape ${s.kind.name} sec=${s.section} ${s.rect}');
  }
  for (final e in find.byType(Surface).evaluate().followedBy(find.byType(Section).evaluate())) {
    final b = e.renderObject;
    if (b is RenderBox && b.hasSize) {
      final r = MatrixUtils.transformRect(b.getTransformTo(null), Offset.zero & b.size);
      buf.writeln('  comp ${e.widget.runtimeType} $r');
    }
  }
  // ignore: avoid_print
  print(buf);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadFonts();
    await skLoadAppFonts();
    await r2OpenDb('guide_phone_feedback.db');
  });

  // why: on the phone NOTHING on Day strain was dimmed. The phone's top card is a Surface
  // holding a chart (with "00:00 / 12:00 / 24:00" axis labels), a LATEST panel, text and the
  // metrics row; the axis labels counted as a running timer and kept the whole card lit.
  // The target ("How these are set") sits in the Time in zones Section below it, so this card
  // is the card ABOVE the target's card and must be dimmed whole, as one unit.
  // catches: a card kept lit by clock-shaped text or by touching the NavBar's box, a dim over
  // only part of the card, the card's inner boxes dimmed again.
  testWidgets('heart-rate-zones step 2 on a day with a curve dims the whole top card as one unit', (t) async {
    final key = GlobalKey();
    final app = await _start(t, 'heart-rate-zones', key);
    final strain = _overlay(t);
    await t.tapAt(strain.targetRect!.center);
    await settleLiveGuide(t, frames: 14);
    final o = _overlay(t);
    expect((app.runner.activeRun!.state as GuideAtStep).index, 1);
    final title = find.text('Strain through the day');
    expect(title, findsOneWidget, reason: 'positive control: the drawn-curve card is on screen');
    final card = t.getRect(find.ancestor(of: title, matching: find.byType(Surface)).last);
    final over = _over(o, card.deflate(1)).toList();
    expect(over.map((s) => s.kind), [SkeletonKind.dim], reason: 'one dim layer over the card, nothing else: $over');
    expect(over.single.rect, card, reason: 'over the card\'s whole drawn box: chart, LATEST panel, description, value row');
    for (final inside in ['Peak HR', 'Worn']) {
      expect(find.textContaining(inside), findsWidgets, reason: 'positive control: $inside is in the card');
    }
  });

  /// 'lit', 'dim' (exactly one whole-box dim) or 'placeholder' for the box [r].
  String look(LiveGuideOverlayState o, Rect r) {
    final over = _over(o, r.deflate(1)).toList();
    if (over.isEmpty) return 'lit';
    if (over.every((s) => s.kind == SkeletonKind.dim)) {
      expect(over, hasLength(1), reason: 'one dim layer per unit: $over');
      // (the plan clips to the screen: the box may run past the tab bar)
      expect(over.single.rect.left, r.left);
      expect(over.single.rect.right, r.right);
      expect(over.single.rect.top, r.top);
      expect(over.single.rect.bottom, lessThanOrEqualTo(r.bottom + .5), reason: 'the dim covers the drawn box down to the screen edge');
      return 'dim';
    }
    return 'placeholder';
  }

  // why: the owner's Home screenshot: the ring card was not dimmed, the day selector's next-day
  // box was dimmed apart from its bar (a seam). Now: the target's card (rings and the Recovery
  // row) is lit; the card below is dimmed; the day selector is one dimmed bar; a control after
  // the window is a placeholder.
  // catches: the day selector as separate boxes, a window that dims the target's own card.
  testWidgets('heart-rate-zones step 1 on Home: own card lit and next card dim', (t) async {
    final key = GlobalKey();
    await _start(t, 'heart-rate-zones', key);
    final o = _overlay(t);
    final ring = t.getRect(find.ancestor(of: find.text('STRAIN'), matching: find.byType(Surface)).last);
    expect(look(o, ring), 'lit', reason: 'the target\'s own card');
    final review = t.getRect(find.ancestor(of: find.text('Detected activities'), matching: find.byType(Surface)).last);
    expect(look(o, review), 'dim');

  });

  // why: the owner's Sleep screenshot: Recalculate / Not sleep lit next to the target, a darker
  // rectangle inside the dimmed Naps row, chevron boxes dimmed apart from their accordion.
  // Now the accordion is one card: the target's card (the night with its actions and Naps) is lit
  // as a whole, the next accordion is dimmed whole (one layer, chevron included), those after it
  // are placeholders that keep their titles.
  // catches: an accordion that is not one unit, inner boxes dimmed again.
  testWidgets('fix-sleep-times step 1 on Sleep: window card lit and Stages dimmed', (t) async {
    final key = GlobalKey();
    await _start(t, 'fix-sleep-times', key);
    final o = _overlay(t);
    final targetText = find.text('Set the times myself');
    expect(targetText, findsOneWidget, reason: 'the window edit action is built');
    final ownFinder = find.ancestor(of: targetText, matching: find.byType(Surface));
    expect(ownFinder, findsWidgets, reason: 'main renders the edit action inside its window Surface');
    final own = t.getRect(ownFinder.last);
    expect(look(o, own), 'lit');
    for (final title in ['Not sleep']) {
      expect(_over(o, t.getRect(find.text(title).first).deflate(1)), isEmpty, reason: '$title is in the target\'s card');
    }
    final next = t.getRect(find.ancestor(of: find.text('Stages'), matching: find.byType(Section)).first);
    expect(look(o, next), 'dim');
  });

  testWidgets('capture the four owner pages', (t) async {
    final dir = _out!;
    {
      final key = GlobalKey();
      final app = await _start(t, 'heart-rate-zones', key);
      _dump(t, 'hrz1');
      await _png(t, key, '1-hrz-step1-home-strain.png');
      await t.tapAt(_overlay(t).targetRect!.center);
      await settleLiveGuide(t, frames: 14);
      _dump(t, 'hrz2');
      await _png(t, key, '2-hrz-step2-day-strain.png');
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      await t.pump();
    }
    {
      final key = GlobalKey();
      final app = await _start(t, 'fix-sleep-times', key);
      _dump(t, 'sleep1');
      await _png(t, key, '3-fix-sleep-times-step1-sleep.png');
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      await t.pump();
    }
    {
      final key = GlobalKey();
      await _start(t, 'log-past-workout', key);
      _dump(t, 'history1');
      await _png(t, key, '4-log-past-workout-step1-activity-history.png');
    }
    expect(Directory(dir).existsSync(), isTrue);
  }, skip: _out == null || _out!.isEmpty);
}
