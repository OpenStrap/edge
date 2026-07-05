// Widget tests for the stats/history screens migrated onto the design system
// (Records / Recap / Journey / Timeline pure content) plus the nav shell:
// each content widget renders in BOTH palettes from sample payloads, the
// Recap share surface still captures to a real PNG, and ShellScaffold's
// tab-select switches pages while a pushed sub-screen still pops/swipes back.
// Explicit pump durations (never blind pumpAndSettle — kit widgets repeat).

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/app.dart' show ShellScaffold;
import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/theme/theme_switcher.dart';
import 'package:openstrap_edge/ui/design/design.dart';
import 'package:openstrap_edge/ui/journey/journey_screen.dart'
    show JourneyContent;
import 'package:openstrap_edge/ui/recap/recap_screen.dart'
    show RecapShareCard;
import 'package:openstrap_edge/ui/records/records_screen.dart'
    show RecordsContent;
import 'package:openstrap_edge/ui/timeline/timeline_screen.dart'
    show TimelineContent;

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

Future<void> _pumpTwice(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(seconds: 1));
}

// ── fixtures ─────────────────────────────────────────────────────────────────

RecordsData _sampleRecords() => RecordsData.fromJson({
  'days_tracked': 42,
  'nights_tracked': 38,
  'workouts_tracked': 12,
  'records': {
    'lowest_rhr': {'value': 47, 'date': '2026-06-20'},
    'top_workout': {'value': 14.2, 'date': '2026-06-18', 'type': 'run'},
    'longest_sleep': {'value': 542, 'date': '2026-06-15'},
    'most_steps': {'value': 18412, 'date': '2026-06-10'},
    'top_readiness': {'value': 93, 'date': '2026-06-22'},
  },
  'streaks': {
    'wear': {'current': 9, 'label': 'best 21'},
    'sleep': {'current': 0, 'label': 'best 12'},
  },
  'rhr_drift': {
    'now': 52.0,
    'then': 55.0,
    'delta': -3.0,
    'direction': 'improving',
    'days': 40,
  },
});

Map<String, dynamic> _sampleRecap() => {
  'from_epoch': 1750000000,
  'to_epoch': 1750604800,
  'worn_days': 7,
  'metrics': {
    'strain': {'avg': 11.8, 'delta_pct': 6.0},
    'resting_hr': {'avg': 52.4, 'delta_pct': -2.1},
    'sleep_duration': {'avg': 452.0},
    'calories': {'total': 15230},
  },
  'series': {
    'steps': [
      for (final v in [8200, 10400, 6100, 12800, 9900, 7300, 11000])
        {'v': v},
    ],
    'strain': [
      for (final v in [10.2, 13.8, 8.4, 15.1, 12.0, 9.7, 13.2]) {'v': v},
    ],
  },
};

String _todayLabel() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

/// A representative /day/timeline payload anchored on TODAY so the journey's
/// minute-detail branch (retention-gated) renders.
Map<String, dynamic> _sampleDay() {
  final now = DateTime.now();
  final dayStart =
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
  final hr = [
    for (var i = 0; i < 12; i++)
      {'t': dayStart + 3600 + i * 900, 'v': 55 + (i % 5) * 14},
  ];
  return {
    'date': _todayLabel(),
    'day_start': dayStart,
    'hr': hr,
    'activity': [
      for (var i = 0; i < 12; i++)
        {'t': dayStart + 3600 + i * 900, 'v': (i % 4) * 0.25},
    ],
    'highs': {
      'peak_hr': {'t': dayStart + 7 * 3600, 'v': 171},
      'low_hr': {'t': dayStart + 2 * 3600, 'v': 44},
    },
    'sleep': [
      {'onset_ts': dayStart, 'wake_ts': dayStart + 6 * 3600},
    ],
    'sessions': [
      {
        'type': 'run',
        'start_ts': dayStart + 8 * 3600,
        'end_ts': dayStart + 9 * 3600,
        'avg_hr': 142,
        'max_hr': 171,
        'strain': 12.4,
      },
    ],
    'hrv': [
      for (var i = 0; i < 8; i++)
        {'t': dayStart + 3600 + i * 1800, 'v': 40 + (i % 3) * 12},
    ],
    'resp': [
      for (var i = 0; i < 8; i++)
        {'t': dayStart + 3600 + i * 1800, 'v': 13 + (i % 3)},
    ],
    'skin_temp': [
      for (var i = 0; i < 8; i++)
        {'t': dayStart + 3600 + i * 1800, 'v': -0.4 + (i % 4) * 0.3},
    ],
    'naps': [
      {'start': dayStart + 13 * 3600, 'end': dayStart + 13 * 3600 + 1800},
    ],
  };
}

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  group('RecordsContent', () {
    testWidgets('summary, medal, PR bento, drift + streaks in both palettes', (
      t,
    ) async {
      for (final palette in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            RecordsContent(
              r: _sampleRecords(),
              rhrSpark: const [55, 54, 53.5, 54, 53, 52.5, 52],
            ),
            palette: palette,
          ),
        );
        await _pumpTwice(t);

        // Inverted tally tile.
        expect(find.text('42'), findsOneWidget);
        expect(find.text('NIGHTS'), findsOneWidget);
        // Headline PR → medal (top_workout wins the priority).
        expect(find.byType(MedalCard), findsOneWidget);
        expect(find.textContaining('Top workout strain — 14.2'), findsWidgets);
        // The remaining PRs land in bento tiles with formatted values.
        expect(find.text('47'), findsOneWidget); // lowest RHR
        // Steps group with a thin space.
        expect(find.text('18\u2009412'), findsOneWidget);
        expect(find.text('9h 2m'), findsOneWidget); // longest sleep
        // RHR drift with a real sparkline + streak tiles.
        expect(find.byType(Sparkline), findsOneWidget);
        expect(find.textContaining('Down 3.0 bpm'), findsOneWidget);
        expect(find.text('WEAR STREAK'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });
  });

  group('RecapShareCard', () {
    testWidgets('hero, inner bento and highlight render in both palettes', (
      t,
    ) async {
      for (final palette in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            RecapShareCard(
              data: _sampleRecap(),
              range: '7d',
              sleepBars: const [420, 465, 431, 480, 445, 452, 470],
              topWorkout: const {
                'type': 'run',
                'strain': 15.1,
                'duration_min': 48,
              },
            ),
            palette: palette,
          ),
        );
        await _pumpTwice(t);

        expect(find.text('OpenStrap'), findsOneWidget);
        expect(find.text('11.8'), findsOneWidget); // avg strain hero
        expect(find.text('AVG STRAIN'), findsOneWidget);
        expect(find.text('52'), findsOneWidget); // resting HR cell
        expect(find.text('7h 32m'), findsOneWidget); // sleep/night
        expect(find.text('15k'), findsOneWidget); // calories compact (>=10k)
        expect(find.textContaining('Top workout — Run'), findsOneWidget);
        expect(find.byType(MiniBars), findsNWidgets(3));
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('share surface still captures to a non-empty PNG', (t) async {
      final key = GlobalKey();
      await t.pumpWidget(
        _host(
          RepaintBoundary(
            key: key,
            child: RecapShareCard(data: _sampleRecap(), range: '7d'),
          ),
        ),
      );
      await _pumpTwice(t);

      // The exact pipeline RecapScreen._share runs: boundary → image → PNG.
      final bytes = await t.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final ui.Image image = await boundary.toImage(pixelRatio: 2);
        return image.toByteData(format: ui.ImageByteFormat.png);
      });
      expect(bytes, isNotNull);
      expect(bytes!.lengthInBytes, greaterThan(1000));
    });
  });

  group('JourneyContent', () {
    testWidgets(
      'merged multi-vital lookback, movement and workouts in both palettes',
      (t) async {
        for (final palette in [kLightPalette, kDarkPalette]) {
          await t.pumpWidget(
            _host(
              JourneyContent(data: _sampleDay(), requestedDate: _todayLabel()),
              palette: palette,
            ),
          );
          await _pumpTwice(t);

          // The merged multi-vital timeline (TimelineContent) is embedded
          // here — one selector chip + color per continuously-recorded vital.
          for (final label in ['Heart rate', 'HRV', 'Resp', 'Skin temp']) {
            expect(find.text(label), findsOneWidget);
          }
          expect(find.text('HEART RATE · BPM'), findsOneWidget);
          expect(find.text('PEAK · HEART RATE'), findsOneWidget);
          expect(find.text('LOW · HEART RATE'), findsOneWidget);
          // No play/replay control — scrub replaces tap-to-replay.
          expect(find.byType(HrReplayOverlay), findsNothing);
          // The merged timeline's own event bands (sleep/nap/workout).
          expect(find.text('EVENTS'), findsOneWidget);
          expect(find.text('Sleep'), findsOneWidget);
          expect(find.text('Nap'), findsOneWidget);
          // Movement chart tile + workout list row (Journey-only content).
          expect(find.text('MOVEMENT'), findsOneWidget);
          expect(find.text('WORKOUTS · 1'), findsOneWidget);
          expect(find.text('Run'), findsWidgets); // event band + workout row
          expect(find.text('12.4 strain'), findsOneWidget);
          expect(t.takeException(), isNull);
        }
      },
    );
  });

  group('TimelineContent', () {
    testWidgets('chips, merged chart, peak/low and events in both palettes', (
      t,
    ) async {
      for (final palette in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(TimelineContent(data: _sampleDay()), palette: palette),
        );
        await _pumpTwice(t);

        // All four vitals present as selector chips.
        for (final label in ['Heart rate', 'HRV', 'Resp', 'Skin temp']) {
          expect(find.text(label), findsOneWidget);
        }
        // Active vital header in real units + its peak/low BigStats.
        expect(find.text('HEART RATE · BPM'), findsOneWidget);
        expect(find.text('PEAK · HEART RATE'), findsOneWidget);
        expect(find.text('LOW · HEART RATE'), findsOneWidget);
        // Event list: sleep + nap + workout bands as clean rows.
        expect(find.text('EVENTS'), findsOneWidget);
        expect(find.text('Sleep'), findsOneWidget);
        expect(find.text('Nap'), findsOneWidget);
        expect(find.text('Run'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('tapping a vital chip switches the active scale', (t) async {
      await t.pumpWidget(_host(TimelineContent(data: _sampleDay())));
      await _pumpTwice(t);
      expect(find.text('HEART RATE · BPM'), findsOneWidget);

      await t.tap(find.text('HRV'));
      await _pumpTwice(t);
      expect(find.text('HRV · MS'), findsOneWidget);
      expect(find.text('PEAK · HRV'), findsOneWidget);
      expect(find.text('HEART RATE · BPM'), findsNothing);
    });

    testWidgets('empty payload renders the honest empty card', (t) async {
      expect(TimelineContent.hasVitals(const {}), isFalse);
      await t.pumpWidget(_host(TimelineContent(data: const {})));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('No timeline yet'), findsOneWidget);
    });
  });

  group('ShellScaffold (nav shell)', () {
    Widget shellApp(GlobalKey<NavigatorState> nav) {
      AppColors.active = kLightPalette;
      return ChangeNotifierProvider<ThemeController>.value(
        value: ThemeController.seed(AppThemeChoice.light, Brightness.light),
        child: MaterialApp(
          navigatorKey: nav,
          theme: buildOpenStrapTheme(kLightPalette),
          home: const _ShellHarness(),
        ),
      );
    }

    testWidgets('tab select switches the PageView page', (t) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(shellApp(nav));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('PAGE Today'), findsOneWidget);

      // Tap the Heart tab (icon-only until selected) — illustrated icon.
      await t.tap(find.byWidgetPredicate(
        (w) => w is OsAppIcon && w.icon == OsIcon.heart,
      ));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('PAGE Heart'), findsOneWidget);
      expect(find.text('PAGE Today'), findsNothing);
      // The selected item blooms with its label inside the pill.
      expect(find.text('Heart'), findsOneWidget);
    });

    testWidgets('pill renders 5 even tabs and no center action', (t) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(shellApp(nav));
      await t.pump(const Duration(milliseconds: 400));
      // All five tabs, no add coin — starting a workout lives on the
      // Workouts screen, not in the nav pill.
      expect(find.byType(OsAppIcon), findsNWidgets(5));
      expect(
        find.byWidgetPredicate((w) => w is OsAppIcon && w.icon == OsIcon.add),
        findsNothing,
      );
      expect(find.bySemanticsLabel('Start a workout'), findsNothing);
    });

    testWidgets('a pushed sub-screen still pops via the back button', (
      t,
    ) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(shellApp(nav));
      await t.pump(const Duration(milliseconds: 400));

      nav.currentState!.push(
        themedRoute((_) => const AppScaffold(title: 'Detail', children: [])),
      );
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Detail'), findsOneWidget);

      await t.tap(find.byType(AppBackButton));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Detail'), findsNothing);
      expect(find.text('PAGE Today'), findsOneWidget);
    });

    testWidgets(
      'a pushed sub-screen still swipes back over the shell (iOS)',
      (t) async {
        final nav = GlobalKey<NavigatorState>();
        await t.pumpWidget(shellApp(nav));
        await t.pump(const Duration(milliseconds: 400));

        nav.currentState!.push(
          themedRoute((_) => const AppScaffold(title: 'Detail', children: [])),
        );
        await t.pumpAndSettle(const Duration(milliseconds: 100));
        expect(find.text('Detail'), findsOneWidget);

        final route =
            ModalRoute.of(t.element(find.text('Detail')))! as PageRoute;
        expect(route.popGestureEnabled, isTrue,
            reason: 'pushed route must support the iOS back-swipe gesture');

        final gesture = await t.startGesture(const Offset(5, 300));
        await gesture.moveBy(const Offset(50, 0));
        await t.pump();
        await gesture.moveBy(const Offset(450, 0));
        await t.pump();
        await gesture.up();
        await t.pumpAndSettle(const Duration(milliseconds: 100));

        expect(find.text('Detail'), findsNothing);
        expect(find.text('PAGE Today'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

/// Minimal AppState-free stand-in for the app's _Shell: same ShellScaffold,
/// same PageController wiring, plain text pages.
class _ShellHarness extends StatefulWidget {
  const _ShellHarness();
  @override
  State<_ShellHarness> createState() => _ShellHarnessState();
}

class _ShellHarnessState extends State<_ShellHarness> {
  int _index = 0;
  final _controller = PageController();

  static const _nav = [
    NavPillItem(OsIcon.today, 'Today'),
    NavPillItem(OsIcon.sleep, 'Sleep'),
    NavPillItem(OsIcon.heart, 'Heart'),
    NavPillItem(OsIcon.bodyStrain, 'Body'),
    NavPillItem(OsIcon.workouts, 'Workouts'),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShellScaffold(
      controller: _controller,
      index: _index,
      items: _nav,
      pages: [
        for (final n in _nav) Center(child: Text('PAGE ${n.label}')),
      ],
      onSelect: (i) {
        if (i == _index) return;
        _controller.animateToPage(
          i,
          duration: Motion.med,
          curve: Motion.curve,
        );
      },
      onPageChanged: (i) => setState(() => _index = i),
    );
  }
}
