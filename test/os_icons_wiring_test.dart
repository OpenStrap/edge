// Wiring tests for the openstrap_icons illustrated set: the nav pill renders
// the custom tab icons (every tab full opacity/size — never tinted, dimmed,
// or shrunk; selection is the lozenge + label), and a domain content widget
// (Steps) shows its OsIcon in the tile header. Explicit pump durations —
// kit widgets animate/repeat, never blind pumpAndSettle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/ui/design/design.dart';
import 'package:openstrap_edge/ui/screens/screens.dart' show StepsDayContent;
import 'package:openstrap_edge/ui/sleep/sleep_detail_screen.dart'
    show SleepNightContent;
import 'package:openstrap_edge/ui/today/today_screen.dart' show TodayVitals;

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

const _navItems = [
  NavPillItem(OsIcon.today, 'Today'),
  NavPillItem(OsIcon.sleep, 'Sleep'),
  NavPillItem(OsIcon.heart, 'Heart'),
  NavPillItem(OsIcon.bodyStrain, 'Body'),
  NavPillItem(OsIcon.workouts, 'Workouts'),
];

void main() {
  group('FloatingNavPill · illustrated tabs', () {
    testWidgets('renders every tab as its custom OsIcon (both palettes)', (
      t,
    ) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(_host(
          FloatingNavPill(items: _navItems, index: 0, onSelect: (_) {}),
          palette: p,
        ));
        await t.pump(const Duration(milliseconds: 400));
        for (final item in _navItems) {
          expect(
            find.byWidgetPredicate(
              (w) => w is OsAppIcon && w.icon == item.icon,
            ),
            findsOneWidget,
            reason: 'tab ${item.label} should render its illustrated icon',
          );
        }
      }
    });

    testWidgets('every tab is full-strength — inactive never dimmed or shrunk',
        (t) async {
      await t.pumpWidget(_host(
        FloatingNavPill(items: _navItems, index: 2, onSelect: (_) {}),
      ));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(OsAppIcon), findsNWidgets(_navItems.length));
      // The illustrated art is barely legible when faded/shrunk, so the pill
      // wraps no icon in AnimatedOpacity/AnimatedScale — selection is the
      // lozenge background + label only.
      for (final item in _navItems) {
        final icon = find.byWidgetPredicate(
          (w) => w is OsAppIcon && w.icon == item.icon,
        );
        expect(
          find.ancestor(of: icon, matching: find.byType(AnimatedOpacity)),
          findsNothing,
          reason: 'tab ${item.label} must never be faded',
        );
        expect(
          find.ancestor(of: icon, matching: find.byType(AnimatedScale)),
          findsNothing,
          reason: 'tab ${item.label} must never be shrunk',
        );
      }
      // No center action in the default pill — the nav is just the tabs.
      expect(
        find.byWidgetPredicate((w) => w is OsAppIcon && w.icon == OsIcon.add),
        findsNothing,
      );
    });
  });

  group('domain screen · illustrated header', () {
    testWidgets('Steps content shows the OsIcon.steps tile icon', (t) async {
      await t.pumpWidget(_host(
        const StepsDayContent(steps: 4200, goal: 10000),
      ));
      await t.pump(const Duration(milliseconds: 600));
      expect(
        find.byWidgetPredicate(
          (w) => w is OsAppIcon && w.icon == OsIcon.steps,
        ),
        findsOneWidget,
      );
      // The hugeicons chrome next door is untouched (goal/calibrate rows
      // keep their monochrome glyphs).
      expect(find.byType(AppIcon), findsWidgets);
    });

    testWidgets('Today stress tile + orbit satellite render OsIcon.stress; '
        'calories tile renders OsIcon.calories', (t) async {
      t.view.physicalSize = const Size(390, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(
        TodayVitals(
          t: TodayData.fromJson({
            'daily': {
              'readiness': {'value': 82, 'confidence': 0.9},
              'calories': {'value': 640, 'confidence': 0.6, 'tier': 'estimate'},
            },
            'sleep': <String, dynamic>{},
            'stress': {'score': 34},
          }),
          onOpen: (_) {},
        ),
      ));
      await t.pump(const Duration(milliseconds: 1200));
      // Stress art appears twice: the bento tile header + the orbit satellite.
      expect(
        find.byWidgetPredicate(
          (w) => w is OsAppIcon && w.icon == OsIcon.stress,
        ),
        findsNWidgets(2),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is OsAppIcon && w.icon == OsIcon.calories,
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('Sleep night renders the hypnogram-header art; trend rows '
        'stay icon-free by design', (t) async {
      t.view.physicalSize = const Size(390, 3200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final now = DateTime.now();
      final wake = DateTime(now.year, now.month, now.day, 6, 42);
      final onsetTs =
          wake.subtract(const Duration(hours: 7, minutes: 32))
              .millisecondsSinceEpoch ~/ 1000;
      final today =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      await t.pumpWidget(_host(
        SleepNightContent(
          data: {
            'has_sleep': true,
            'sleep_source': 'auto',
            'duration_min': 452,
            'in_bed_min': 470,
            'onset_ts': onsetTs,
            'wake_ts': wake.millisecondsSinceEpoch ~/ 1000,
            'light_min': 250,
            'deep_min': 62,
            'rem_min': 118,
          },
          date: today,
          onEditTimes: () {},
          onConfirmFallback: () {},
          onClearOverride: () {},
        ),
      ));
      await t.pump(const Duration(milliseconds: 1200));
      // Section header keeps its illustrated art.
      expect(
        find.byWidgetPredicate(
          (w) => w is OsAppIcon && w.icon == OsIcon.sleepHypnogram,
        ),
        findsOneWidget,
        reason: 'the hypnogram section header should render its art',
      );
      // MetricRow trend rows (Deep/Light/etc.) are deliberately icon-free —
      // a whole list of "heading left, score right" rows each with their own
      // chip read as noise; the icon belongs on the metric's own screen/hero.
      for (final icon in [OsIcon.deepSleep, OsIcon.lightSleep]) {
        expect(
          find.byWidgetPredicate((w) => w is OsAppIcon && w.icon == icon),
          findsNothing,
          reason: '$icon should NOT render inside a MetricRow trend row',
        );
      }
      expect(t.takeException(), isNull);
    });
  });
}
