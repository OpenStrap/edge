// Render tests for the interactive/AI/logging screens migrated onto the design
// language: Coach (plan + chat bubbles), Journal (day tiles, insights, compose
// bubbles + proposal), Cycle, and Spot-check. Each renders in BOTH palettes
// with sample data; explicit pump durations (never blind pumpAndSettle — some
// kit widgets repeat).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/coach/ai_coach_screen.dart' show CoachBubble;
import 'package:openstrap_edge/ui/coach/coach_screen.dart'
    show CoachPlanContent;
import 'package:openstrap_edge/ui/cycle/cycle_screen.dart' show CycleContent;
import 'package:openstrap_edge/ui/journal/journal_compose_screen.dart'
    show JournalChatBubble, JournalProposalCard;
import 'package:openstrap_edge/ui/journal/journal_screen.dart'
    show JournalDayTile, JournalInsightCard;
import 'package:openstrap_edge/ui/spotcheck/spot_check_screen.dart'
    show SpotCheckView;

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

/// Screens that bring their own AppScaffold host as `home` directly.
Widget _hostScreen(Widget screen, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(theme: buildOpenStrapTheme(palette), home: screen);
}

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  group('CoachPlanContent', () {
    CoachData coach() => CoachData({
      'summary': 'Recovered well — lean into training today.',
      'strain_target': {
        'value': 12.5,
        'low': 11.0,
        'high': 14.0,
        'rationale': 'Readiness 82 with a light week behind you.',
      },
      'plan': [
        {
          'id': 's1',
          'category': 'load',
          'severity': 1,
          'title': 'Push today',
          'body': 'Your body is primed for a harder session.',
          'target': 'Aim strain 11–14',
          'why': [
            {'label': 'HRV', 'value': '48ms', 'detail': '+9% vs baseline'},
            {'label': 'RHR', 'value': '52bpm'},
          ],
        },
      ],
    });

    testWidgets('renders summary, strain target band and suggestion in both '
        'palettes', (t) async {
      t.view.physicalSize = const Size(390, 1800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(_host(CoachPlanContent(coach: coach()), palette: p));
        await t.pump(const Duration(milliseconds: 900));
        expect(
          find.text('Recovered well — lean into training today.'),
          findsOneWidget,
        );
        expect(find.text("TODAY'S STRAIN TARGET"), findsOneWidget);
        expect(find.text('12.5'), findsOneWidget);
        expect(find.text('aim 11–14'), findsOneWidget);
        expect(find.text('Push today'), findsOneWidget);
        expect(find.text('Aim strain 11–14'), findsOneWidget);
        expect(find.text('HRV 48ms · +9% vs baseline'), findsOneWidget);
        expect(find.text('RHR 52bpm'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('empty plan shows the affirming row', (t) async {
      await t.pumpWidget(
        _host(CoachPlanContent(coach: CoachData({'summary': ''}))),
      );
      await t.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Nothing flagged — carry on with your day.'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  });

  group('CoachBubble (AI chat)', () {
    testWidgets('user / assistant / error bubbles render in both palettes', (
      t,
    ) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            Column(
              children: [
                CoachBubble(item: CoachItem.user('How recovered am I?')),
                CoachBubble(
                  item: CoachItem.assistant(
                    'You are **well recovered** today.',
                  ),
                ),
                CoachBubble(item: CoachItem.error('Provider unreachable.')),
              ],
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 400));
        expect(find.text('How recovered am I?'), findsOneWidget);
        expect(find.textContaining('well recovered'), findsOneWidget);
        expect(find.text('Provider unreachable.'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });
  });

  group('Journal', () {
    testWidgets('day tile shows date, tags, note; editing chip when active; '
        'taps through', (t) async {
      var taps = 0;
      await t.pumpWidget(
        _host(
          Column(
            children: [
              JournalDayTile(
                date: '2026-07-01',
                tags: const ['caffeine', 'workout'],
                note: 'Long ride in the heat.',
                onTap: () => taps++,
              ),
              const JournalDayTile(
                date: '2026-06-30',
                tags: ['alcohol'],
                note: '',
                active: true,
              ),
            ],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('caffeine'), findsOneWidget);
      expect(find.text('Long ride in the heat.'), findsOneWidget);
      expect(find.text('Editing'), findsOneWidget);
      await t.tap(find.text('Long ride in the heat.'));
      await t.pump(const Duration(milliseconds: 300));
      expect(taps, 1);
    });

    testWidgets('insight card shows tag, days and tinted effect pills in both '
        'palettes', (t) async {
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            JournalInsightCard(
              insight: const {
                'tag': 'alcohol',
                'days': 12,
                'effects': [
                  {
                    'label': 'HRV',
                    'delta_pct': -8.3,
                    'better': false,
                    'n_with': 12,
                  },
                  {
                    'label': 'Deep sleep',
                    'delta_pct': 4.0,
                    'better': true,
                    'n_with': 9,
                  },
                ],
              },
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 500));
        expect(find.text('alcohol'), findsOneWidget);
        expect(find.text('12 days'), findsOneWidget);
        expect(find.text('−8.3%'), findsOneWidget);
        expect(find.text('+4.0%'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('compose bubbles + verbatim proposal card render; save fires', (
      t,
    ) async {
      var saves = 0;
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            Column(
              children: [
                const JournalChatBubble(
                  user: true,
                  text: 'Two coffees and a hard run.',
                ),
                const JournalChatBubble(
                  user: false,
                  text: 'Got it — logging caffeine and workout.',
                ),
                JournalProposalCard(
                  tags: const ['caffeine', 'workout'],
                  note: 'Hard run, double espresso.',
                  onSave: () => saves++,
                ),
              ],
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 600));
        expect(find.text('Two coffees and a hard run.'), findsOneWidget);
        expect(find.text('WILL BE LOGGED'), findsOneWidget);
        expect(find.text('Hard run, double espresso.'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
      await t.tap(find.text('Save to journal'));
      await t.pump(const Duration(milliseconds: 300));
      expect(saves, 1);
    });
  });

  group('CycleContent', () {
    Map<String, dynamic> cycle() => {
      'enabled': true,
      'phase': 'luteal',
      'cycle_day': 18,
      'mean_length': 28,
      'days_until_next': 10,
      'predicted_next': '2026-07-15',
      'fertile_start': '2026-06-28',
      'fertile_end': '2026-07-03',
      'ovulation_est': '2026-07-01',
      'confidence': 0.7,
      'note': 'Based on 4 logged cycles.',
      'overlay': [
        {'skin_temp_idx': 0.3, 'resting_hr': 54, 'hrv_rmssd': 46},
      ],
      'logs': [
        {'date': '2026-06-17', 'kind': 'start'},
      ],
    };

    testWidgets('renders ring hero, prediction, body bento, symptoms and logs '
        'in both palettes', (t) async {
      t.view.physicalSize = const Size(390, 2600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final toggled = <String>[];
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _host(
            CycleContent(
              data: cycle(),
              symptoms: const {'cramps'},
              onToggleSymptom: toggled.add,
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 1200));
        expect(find.text('18'), findsOneWidget); // cycle-day ring center
        expect(find.text('DAY'), findsOneWidget);
        expect(find.text('Luteal phase'), findsOneWidget);
        expect(find.text('in 10 days'), findsOneWidget);
        expect(find.text('Fertile window'), findsOneWidget);
        expect(find.text('+0.3'), findsOneWidget); // skin-temp delta
        expect(find.text('54'), findsOneWidget); // resting HR tile
        expect(find.text('cramps'), findsOneWidget);
        expect(find.text('2026-06-17'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
      await t.tap(find.text('headache'));
      await t.pump(const Duration(milliseconds: 300));
      expect(toggled, contains('headache'));
    });

    testWidgets('honest empty state: no day logged yet', (t) async {
      await t.pumpWidget(
        _host(
          const CycleContent(data: {'enabled': true, 'phase': 'unknown'}),
        ),
      );
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('Log a period to begin'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('SpotCheckView', () {
    testWidgets('active scan shows countdown + live HR; cancel offered', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _hostScreen(
            SpotCheckView(
              connected: true,
              active: true,
              remaining: 42,
              progress: 0.3,
              liveHr: 61,
              onCancel: () {},
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 900));
        expect(find.text('42'), findsOneWidget);
        expect(find.text('SECONDS'), findsOneWidget);
        expect(find.text('61 bpm live'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('result renders the RMSSD ring + numbers bento; rescan fires', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 1800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      var starts = 0;
      for (final p in [kLightPalette, kDarkPalette]) {
        await t.pumpWidget(
          _hostScreen(
            SpotCheckView(
              connected: true,
              active: false,
              result: const {
                'ok': true,
                'rmssd': 54,
                'sdnn': 48,
                'pnn50': 22,
                'mean_hr': 58,
                'n_beats': 61,
              },
              onStart: () => starts++,
            ),
            palette: p,
          ),
        );
        await t.pump(const Duration(milliseconds: 1200));
        expect(find.text('54'), findsWidgets); // ring center + bento tile
        expect(find.text('MS RMSSD'), findsOneWidget);
        expect(find.text('SDNN'), findsOneWidget);
        expect(find.text('MEAN HR'), findsOneWidget);
        expect(find.text('Scan again'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
      await t.tap(find.text('Scan again'));
      await t.pump(const Duration(milliseconds: 300));
      expect(starts, 1);
    });

    testWidgets('disconnected idle state is honest and start disabled', (
      t,
    ) async {
      await t.pumpWidget(
        _hostScreen(const SpotCheckView(connected: false, active: false)),
      );
      await t.pump(const Duration(milliseconds: 900));
      expect(
        find.text('Connect your band to run a spot check.'),
        findsOneWidget,
      );
      expect(find.text('Start 60-second scan'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
