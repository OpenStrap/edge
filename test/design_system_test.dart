// Widget tests for the design-system foundation (lib/ui/design): MetricCard,
// ArcGauge, AppScaffold's back button, BentoGrid packing, InfoSheet/InfoDot,
// SegmentedControl, Sparkline, and both-theme rendering. Tests pump with
// explicit durations (never pumpAndSettle blindly — some kit widgets repeat).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:provider/provider.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/design/gallery_screen.dart';
import 'package:openstrap_edge/ui/design/app_scaffold.dart';
import 'package:openstrap_edge/ui/design/arc_gauge.dart';
import 'package:openstrap_edge/ui/design/bento.dart';
import 'package:openstrap_edge/ui/design/controls.dart';
import 'package:openstrap_edge/ui/design/info_sheet.dart';
import 'package:openstrap_edge/ui/design/metric_card.dart';
import 'package:openstrap_edge/ui/design/nav_pill.dart';
import 'package:openstrap_edge/ui/design/spark.dart';
import 'package:openstrap_edge/ui/design/surface.dart';

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: 360, child: SingleChildScrollView(child: child)),
      ),
    ),
  );
}

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  group('MetricCard', () {
    testWidgets('renders label, value, unit; whole-card tap fires', (t) async {
      var taps = 0;
      await t.pumpWidget(
        _host(
          MetricCard(
            label: 'Resting HR',
            value: '52',
            unit: 'bpm',
            onTap: () => taps++,
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 700));
      expect(find.text('RESTING HR'), findsOneWidget);
      expect(find.text('52'), findsOneWidget);
      expect(find.text('bpm'), findsOneWidget);
      await t.tap(find.text('52'));
      await t.pump(const Duration(milliseconds: 300));
      expect(taps, 1);
    });

    testWidgets('null value renders the honest em-dash', (t) async {
      await t.pumpWidget(
        _host(const MetricCard(label: 'Skin temp', value: null)),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('count-up lands exactly on the final text', (t) async {
      await t.pumpWidget(
        _host(
          const MetricCard(label: 'Readiness', value: '82', animateFrom: 82),
        ),
      );
      // Mid-flight: some intermediate number is rendered without crashing.
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 2000));
      expect(find.text('82'), findsOneWidget);
    });

    testWidgets('(i) opens the InfoSheet with the hidden copy', (t) async {
      await t.pumpWidget(
        _host(
          const MetricCard(
            label: 'HRV',
            value: '48',
            info: MetricInfo(
              title: 'About HRV',
              body: 'Beat-to-beat variability.',
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 700));
      // Copy is NOT on the card.
      expect(find.text('Beat-to-beat variability.'), findsNothing);
      await t.tap(find.text('i'));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('About HRV'), findsOneWidget);
      expect(find.text('Beat-to-beat variability.'), findsOneWidget);
      // Drain the ink/route short timers so teardown is clean.
      await t.pumpAndSettle(const Duration(milliseconds: 200));
    });

    testWidgets('renders in dark palette with spark + delta', (t) async {
      await t.pumpWidget(
        _host(
          const MetricCard(
            label: 'RHR',
            value: '52',
            unit: 'bpm',
            spark: [3.0, 2, 4, null, 5, 4],
            delta: Text('+1'),
          ),
          palette: kDarkPalette,
        ),
      );
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('52'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('ArcGauge', () {
    testWidgets('built-in center shows value + label after reveal', (t) async {
      await t.pumpWidget(
        _host(
          const ArcGauge(
            value: 0.82,
            valueText: '82',
            label: 'ready',
            endDot: true,
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 1100));
      expect(find.text('82'), findsOneWidget);
      expect(find.text('READY'), findsOneWidget);
      expect(find.byType(RepaintBoundary), findsWidgets);
    });

    testWidgets('open arc + target + low confidence + NaN never throw', (
      t,
    ) async {
      for (final g in const [
        ArcGauge(value: 0.6, sweepFraction: 0.75, target: 0.8, endDot: true),
        ArcGauge(value: 0.3, confidence: 0.2, zone: 4),
        ArcGauge(value: double.nan),
      ]) {
        await t.pumpWidget(_host(g));
        await t.pump(const Duration(milliseconds: 1100));
        expect(t.takeException(), isNull);
      }
    });
  });

  group('AppScaffold', () {
    testWidgets('back button appears on pushed route and pops', (t) async {
      AppColors.active = kLightPalette;
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: buildOpenStrapTheme(kLightPalette),
          home: const AppScaffold(title: 'Root', children: []),
        ),
      );
      await t.pump();
      // Root cannot pop → no back button.
      expect(find.byType(AppBackButton), findsNothing);

      nav.currentState!.push(
        MaterialPageRoute(
          builder: (_) => const AppScaffold(title: 'Detail', children: []),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Detail'), findsOneWidget);
      expect(find.byType(AppBackButton), findsOneWidget);

      await t.tap(find.byType(AppBackButton));
      // Let the pop transition finish AND the popped route dispose.
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Root'), findsOneWidget);
      expect(find.byType(AppBackButton), findsNothing);
    });

    testWidgets('renders title, subtitle, actions and children', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: buildOpenStrapTheme(kLightPalette),
          home: AppScaffold(
            title: 'Sleep',
            subtitle: 'Last night',
            actions: const [Icon(Icons.calendar_month)],
            children: const [Text('card')],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Last night'), findsOneWidget);
      expect(find.byIcon(Icons.calendar_month), findsOneWidget);
      expect(find.text('card'), findsOneWidget);
    });
  });

  group('BentoGrid', () {
    testWidgets('packs spans into rows without overflow at narrow width', (
      t,
    ) async {
      await t.pumpWidget(
        _host(
          BentoGrid(
            entrance: false,
            items: const [
              BentoItem.wide(SizedBox(height: 60, child: Text('hero'))),
              BentoItem(SizedBox(height: 40, child: Text('a'))),
              BentoItem(SizedBox(height: 40, child: Text('b'))),
              BentoItem(SizedBox(height: 40, child: Text('c'))), // partial row
            ],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 100));
      expect(t.takeException(), isNull);
      for (final s in ['hero', 'a', 'b', 'c']) {
        expect(find.text(s), findsOneWidget);
      }
      // 'a' and 'b' share a row; 'c' wraps to its own.
      final ya = t.getTopLeft(find.text('a')).dy;
      final yb = t.getTopLeft(find.text('b')).dy;
      final yc = t.getTopLeft(find.text('c')).dy;
      expect(ya, yb);
      expect(yc, greaterThan(ya));
      // Partial row stays on-grid: 'c' starts in the left column, like 'a'.
      expect(t.getTopLeft(find.text('c')).dx, t.getTopLeft(find.text('a')).dx);
      expect(
        t.getTopLeft(find.text('b')).dx,
        greaterThan(t.getTopLeft(find.text('a')).dx),
      );
    });
  });

  group('InfoSheet', () {
    testWidgets('showInfoSheet presents title, body, bullets, method note', (
      t,
    ) async {
      late BuildContext ctx;
      await t.pumpWidget(
        MaterialApp(
          theme: buildOpenStrapTheme(kLightPalette),
          home: Builder(
            builder: (c) {
              ctx = c;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      showInfoSheet(
        ctx,
        title: 'Readiness',
        body: 'How ready you are.',
        bullets: const ['Above baseline is good'],
        methodNote: 'Composite z-score',
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(find.text('Readiness'), findsOneWidget);
      expect(find.text('How ready you are.'), findsOneWidget);
      expect(find.text('Above baseline is good'), findsOneWidget);
      expect(find.text('Composite z-score'), findsOneWidget);
    });
  });

  group('Controls + Sparkline + SurfaceCard', () {
    testWidgets('SegmentedControl switches selection on tap', (t) async {
      var idx = 0;
      await t.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => SegmentedControl(
              options: const ['Day', 'Week', 'Month'],
              index: idx,
              expanded: true,
              onChanged: (i) => setState(() => idx = i),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('Month'));
      await t.pump(const Duration(milliseconds: 400));
      expect(idx, 2);
    });

    testWidgets('Sparkline draws with gaps/gradient/area in both palettes', (
      t,
    ) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            Column(
              children: const [
                Sparkline([1.0, 2, null, 3, 2.5], area: true, baseline: 2),
                Sparkline([
                  5.0,
                  5,
                  5,
                  5,
                ]), // flat series must not divide-by-zero
              ],
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 700));
        expect(t.takeException(), isNull);
      }
    });

    testWidgets(
      'DesignGalleryScreen scrolls through every component at phone width '
      'without overflow, in both palettes',
      (t) async {
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);
        for (final (palette, choice) in [
          (kLightPalette, AppThemeChoice.light),
          (kDarkPalette, AppThemeChoice.dark),
        ]) {
          AppColors.active = palette;
          await t.pumpWidget(
            ChangeNotifierProvider<ThemeController>.value(
              value: ThemeController.seed(choice, Brightness.light),
              child: MaterialApp(
                theme: buildOpenStrapTheme(palette),
                home: const DesignGalleryScreen(),
              ),
            ),
          );
          await t.pump(const Duration(milliseconds: 1200));
          expect(find.text('Design system'), findsOneWidget);
          // Scroll to the bottom in steps, building (and layout-checking)
          // every section. StateCard's breathe loop repeats → plain pumps.
          // 15 steps (not 12): the "Workout preview" section added real
          // height below FloatingNavPill, so fewer steps stopped short of
          // the new bottom and let it fall out of the Sliver's cache extent.
          final list = find.byType(ListView).first;
          for (var i = 0; i < 15; i++) {
            await t.drag(list, const Offset(0, -500));
            await t.pump(const Duration(milliseconds: 350));
            expect(t.takeException(), isNull, reason: 'overflow at step $i');
          }
          expect(find.byType(FloatingNavPill), findsOneWidget);
        }
      },
    );

    testWidgets('SurfaceCard levels render in both palettes', (t) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            Column(
              children: [
                for (var e = 0; e <= 3; e++)
                  SurfaceCard(level: e, child: Text('e$e')),
              ],
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
        for (var e = 0; e <= 3; e++) {
          expect(find.text('e$e'), findsOneWidget);
        }
        expect(t.takeException(), isNull);
      }
    });
  });
}
