// Redesigned Workout + Sleep screens — render tests in BOTH palettes, plus the
// sleep-stage visibility regression suite: Light AND Deep must actually PAINT
// (pixel-probed) whenever they are present in the hypnogram, including the
// live pipeline's 'wake' stage vocabulary and sub-pixel-short deep bouts.
// (The old Sleep screen drew light/deep/rem as three near-identical corals
// with no row labels — "Light/Deep lines do not even appear".)

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/design/domains.dart';
import 'package:openstrap_edge/ui/design/fake_route_fixture.dart';
import 'package:openstrap_edge/ui/design/hypnogram.dart';
import 'package:openstrap_edge/ui/activity/live_session_screen.dart'
    show WorkoutFinishScreen, WorkoutFinishSnapshot;
import 'package:openstrap_edge/ui/sleep/sleep_detail_screen.dart'
    show SleepNightContent;
import 'package:openstrap_edge/ui/workouts/workouts_screen.dart'
    show WorkoutFeedCard;

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

/// Every distinct RGB present in the first RepaintBoundary under [f].
Future<Set<int>> _paintedColors(WidgetTester t, Finder f) async {
  RenderRepaintBoundary? boundary;
  void visit(RenderObject o) {
    if (boundary != null) return;
    if (o is RenderRepaintBoundary) {
      boundary = o;
      return;
    }
    o.visitChildren(visit);
  }

  visit(f.evaluate().first.renderObject!);
  final img = await boundary!.toImage();
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = <int>{};
  final b = data!.buffer.asUint8List();
  for (var i = 0; i + 3 < b.length; i += 4) {
    out.add((b[i] << 16) | (b[i + 1] << 8) | b[i + 2]);
  }
  return out;
}

int _rgb(Color c) =>
    ((c.r * 255).round() << 16) |
    ((c.g * 255).round() << 8) |
    (c.b * 255).round();

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  // ── THE bug regression: Light + Deep must PAINT when present ─────────────
  group('Hypnogram stage visibility (regression)', () {
    // labels:false → a text-free tree, so the raster probe needs no fonts.
    Widget plot(List<HypnoSeg> segs) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 120,
                child: Hypnogram(segs, height: 120, labels: false),
              ),
            ),
          ),
        );

    const wideNight = [
      HypnoSeg(SleepStage.awake, 0.00, 0.05),
      HypnoSeg(SleepStage.light, 0.05, 0.35),
      HypnoSeg(SleepStage.deep, 0.35, 0.50),
      HypnoSeg(SleepStage.rem, 0.50, 0.70),
      HypnoSeg(SleepStage.light, 0.70, 0.95),
      HypnoSeg(SleepStage.awake, 0.95, 1.00),
    ];

    for (final (name, palette) in [
      ('light', kLightPalette),
      ('dark', kDarkPalette),
    ]) {
      testWidgets('Light AND Deep segments paint in the $name palette', (
        t,
      ) async {
        AppColors.active = palette;
        // Resolve the palette-specific stage colours at the same moment the
        // widget builds them.
        final light = _rgb(DomainAccent.stageLight);
        final deep = _rgb(DomainAccent.stageDeep);
        final rem = _rgb(DomainAccent.stageRem);
        final awake = _rgb(DomainAccent.stageAwake);
        await t.pumpWidget(plot(wideNight));
        await t.pump();
        final colors =
            (await t.runAsync(() => _paintedColors(t, find.byType(Hypnogram))))!;
        expect(colors.contains(awake), isTrue, reason: 'awake row must paint');
        expect(colors.contains(rem), isTrue, reason: 'REM row must paint');
        expect(colors.contains(light), isTrue,
            reason: 'LIGHT row must paint ($name palette)');
        expect(colors.contains(deep), isTrue,
            reason: 'DEEP row must paint ($name palette)');
        // The four stage colours must be four DISTINCT colours — the old
        // palette collapse (light/deep/rem as near-identical corals) is the
        // bug this guards against.
        expect({awake, rem, light, deep}.length, 4,
            reason: 'stage palette must stay visually distinct');
      });
    }

    testWidgets('sub-pixel-short deep bouts still paint (min-width dash)', (
      t,
    ) async {
      AppColors.active = kLightPalette;
      final deep = _rgb(DomainAccent.stageDeep);
      // An 8 h night with only 1–2 min deep bouts — each under a pixel wide.
      const m = 1 / 480.0;
      final segs = <HypnoSeg>[
        const HypnoSeg(SleepStage.light, 0.0, 0.40),
        HypnoSeg(SleepStage.deep, 0.40, 0.40 + m),
        HypnoSeg(SleepStage.light, 0.40 + m, 0.75),
        HypnoSeg(SleepStage.deep, 0.75, 0.75 + 2 * m),
        HypnoSeg(SleepStage.light, 0.75 + 2 * m, 1.0),
      ];
      await t.pumpWidget(plot(segs));
      await t.pump();
      final colors =
          (await t.runAsync(() => _paintedColors(t, find.byType(Hypnogram))))!;
      expect(colors.contains(deep), isTrue,
          reason: 'a 1-minute deep bout must stay visible');
    });

    testWidgets("parses the live pipeline's 'wake' vocabulary into the awake row",
        (t) async {
      final segs = hypnoSegmentsFromPoints(const [
        {'t': 0, 'stage': 'wake'},
        {'t': 600, 'stage': 'light'},
        {'t': 1200, 'stage': 'deep'},
        {'t': 1800, 'stage': 'rem'},
        {'t': 2400, 'stage': 'wake'},
        {'t': 3000, 'stage': 'wake'},
      ]);
      expect(segs.first.stage, SleepStage.awake);
      expect(segs.map((s) => s.stage).toSet(), {
        SleepStage.awake,
        SleepStage.light,
        SleepStage.deep,
        SleepStage.rem,
      });
    });
  });

  // ── Sleep detail on the new language ──────────────────────────────────────
  group('SleepNightContent (redesigned)', () {
    Map<String, dynamic> night({num? deepMin = 62}) {
      final now = DateTime.now();
      final wake = DateTime(now.year, now.month, now.day, 6, 42);
      final onset = wake.subtract(const Duration(hours: 7, minutes: 32));
      final onsetTs = onset.millisecondsSinceEpoch ~/ 1000;
      // LIVE stage vocabulary ('wake', not 'awake') — what the pipeline emits.
      const stages = ['wake', 'light', 'deep', 'light', 'rem', 'wake', 'rem'];
      return {
        'has_sleep': true,
        'sleep_source': 'auto',
        'stages_beta': true,
        'duration_min': 452,
        'need_min': 480,
        'in_bed_min': 470,
        'awake_min': 18,
        'debt_min': 28,
        'efficiency': 0.92,
        'regularity': 78,
        'onset_ts': onsetTs,
        'wake_ts': wake.millisecondsSinceEpoch ~/ 1000,
        'light_min': 250,
        'deep_min': deepMin,
        'rem_min': 118,
        'hypnogram': [
          for (var i = 0; i < stages.length; i++)
            {'t': onsetTs + i * 3600, 'stage': stages[i]},
        ],
      };
    }

    String today() {
      final d = DateTime.now();
      return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }

    Widget content(Map<String, dynamic> data, Palette p) => _host(
          SleepNightContent(
            data: data,
            date: today(),
            onEditTimes: () {},
            onConfirmFallback: () {},
            onClearOverride: () {},
          ),
          palette: p,
        );

    testWidgets(
        'hypnogram receives Light AND Deep segments from live-vocabulary data '
        'in both palettes', (t) async {
      t.view.physicalSize = const Size(390, 3600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(content(night(), p));
        await t.pump(const Duration(milliseconds: 1200));
        final hyp = t.widget<Hypnogram>(find.byType(Hypnogram));
        final stages = hyp.segments.map((s) => s.stage).toSet();
        expect(stages.contains(SleepStage.light), isTrue,
            reason: 'Light must reach the hypnogram');
        expect(stages.contains(SleepStage.deep), isTrue,
            reason: 'Deep must reach the hypnogram');
        // Labelled stage rows — the fix for "which line is which".
        expect(find.text('Light'), findsWidgets);
        expect(find.text('Deep'), findsWidgets);
        // Stage minutes rows.
        expect(find.text('4h 10m'), findsWidgets); // light 250
        expect(find.text('1h 2m'), findsWidgets); // deep 62
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('bento + hero survive both palettes with the new tiles', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 3600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(content(night(), p));
        await t.pump(const Duration(milliseconds: 1200));
        expect(find.text('TIME ASLEEP'), findsOneWidget);
        expect(find.text('7h 32m'), findsWidgets);
        expect(find.text('94%'), findsOneWidget);
        expect(find.text('EFFICIENCY'), findsOneWidget);
        expect(find.text('SLEEP DEBT'), findsOneWidget);
        expect(find.text('CONSISTENCY'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });

    testWidgets(
        'absent Deep renders an HONEST labelled row, not an invisible gap', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 3600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(content(night(deepMin: 0), kLightPalette));
      await t.pump(const Duration(milliseconds: 1200));
      expect(find.text('Deep'), findsWidgets); // the row still exists
      expect(
        find.text('none detected · low-confidence estimate'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  });

  // ── Workout feed + finish on the new language ─────────────────────────────
  group('Workout feed (redesigned)', () {
    final startTs = DateTime.now()
            .subtract(const Duration(hours: 3))
            .millisecondsSinceEpoch ~/
        1000;

    testWidgets('LIVE session renders as the ink tile with the LIVE chip', (
      t,
    ) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            WorkoutFeedCard({
              'id': 'w-live',
              'type': 'run',
              'status': 'live',
              'start_ts': startTs,
              'duration_min': 18,
            }),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 900));
        expect(find.text('Run'), findsOneWidget);
        expect(find.text('LIVE'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('duration is the big figure; strain dial + zones render', (
      t,
    ) async {
      await t.pumpWidget(
        _host(
          WorkoutFeedCard({
            'id': 'w1',
            'type': 'cycle',
            'status': 'done',
            'start_ts': startTs,
            'duration_min': 65,
            'avg_hr': 141,
            'strain': 11.6,
            'zone_min': [4.0, 18, 25, 14, 4],
          }),
        ),
      );
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('1h 5m'), findsOneWidget);
      expect(find.text('11.6'), findsOneWidget);
      expect(find.textContaining('141 bpm'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('WorkoutFinishScreen (redesigned)', () {
    testWidgets('cinematic finish card renders from the snapshot alone '
        'in both palettes', (t) async {
      t.view.physicalSize = const Size(390, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      for (final p in [kLightPalette, kDarkPalette]) {
        AppColors.active = p;
        await t.pumpWidget(
          MaterialApp(
            theme: buildOpenStrapTheme(p),
            home: const WorkoutFinishScreen(
              id: 'w1',
              snapshot: WorkoutFinishSnapshot(
                type: 'run',
                duration: Duration(minutes: 42, seconds: 30),
                peakHr: 172,
                calories: 512,
                strain: 14.2,
                steps: 6100,
              ),
            ),
          ),
        );
        // Let the staggered reveal play out (fixed pumps, no pumpAndSettle).
        await t.pump(const Duration(milliseconds: 1400));
        await t.pump(const Duration(milliseconds: 1400));
        expect(find.text('Run complete'), findsOneWidget);
        expect(find.text('STRAIN'), findsWidgets);
        expect(find.text('PEAK BPM'), findsOneWidget);
        expect(find.text('TIME IN ZONES'), findsOneWidget);
        expect(find.text('Full breakdown'), findsOneWidget);
        expect(find.text('Share'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pump(const Duration(milliseconds: 1600)); // settle shimmers
      }
    });

    testWidgets(
        'a route hero (RouteCard) renders first for a GPS workout, ahead of '
        'the strain/zone/PR cards',
        (t) async {
      t.view.physicalSize = const Size(390, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      AppColors.active = kLightPalette;
      await t.pumpWidget(
        ChangeNotifierProvider<UnitsController>.value(
          value: UnitsController.seed(UnitSystem.metric),
          child: MaterialApp(
            theme: buildOpenStrapTheme(kLightPalette),
            home: WorkoutFinishScreen(
              id: 'preview-run',
              previewRoute: fakeRunRoute(),
              previewMaxHr: 190,
              snapshot: const WorkoutFinishSnapshot(
                type: 'run',
                duration: Duration(minutes: 20, seconds: 6),
                peakHr: 166,
                calories: 284,
                strain: 11.6,
                steps: 4312,
              ),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 1400));
      await t.pump(const Duration(milliseconds: 1400));
      // NOT asserting takeException() here: RouteCard's map makes a REAL
      // network tile fetch (CARTO), which the test sandbox always fails
      // with a 400 (no network access) — a benign, expected-in-tests
      // ClientException unrelated to this screen's own correctness, not
      // something to assert away. The meaningful check is the widget tree
      // itself, below.
      t.takeException();
      // The route (RouteCard's ROUTE label) appears — the hero, not the old
      // small end-of-card thumbnail.
      expect(find.text('ROUTE'), findsOneWidget);
      // Share is the REAL production flow here too (opens the OS share
      // sheet) — not automated further: RouteCard's map has pending
      // network-image state (blocked in the offline test sandbox) that
      // keeps RenderRepaintBoundary.toImage() from ever resolving under
      // TestWidgetsFlutterBinding, a sandboxing limitation, not a product
      // bug. Verify the actual share output manually on a real
      // device/simulator via the Design Gallery's "Workout preview" section.
      expect(find.text('Share'), findsOneWidget);
    });
  });
}
