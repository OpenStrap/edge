// Whole screens at phone width, at every text size a phone reaches.
//
// `ui2_component_sweep_test.dart` sweeps the gallery's COMPONENTS. No screen is
// in the gallery, and the cards a screen builds for itself were never swept:
// this sweep found four that overflowed at large text on a 390 pt phone
// (readiness ring, zone rows, the cycle-day card, a MetricRow holding a
// word), one of them in German already at 2x. Fourteen screens are swept.
//
// The bundled type is loaded so text measures as on a phone, and every shipped
// language runs, because the long words are not in English. A screen added here is
// swept from then on; each takes its own preloaded data, so nothing touches
// the database.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/ai/nightly_sweep.dart' show SweepFinding;
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/activity/zones.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _loadType() async {
  final files = Directory('assets/fonts/Manrope')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'));
  for (final family in const ['Manrope', '.SF Pro Text']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(f
          .readAsBytes()
          .then((b) => ByteData.sublistView(Uint8List.fromList(b))));
    }
    await loader.load();
  }
}

final _onset = DateTime(2026, 5, 19, 23).millisecondsSinceEpoch ~/ 1000;
final _wake = DateTime(2026, 5, 20, 7).millisecondsSinceEpoch ~/ 1000;
final _nine = DateTime(2026, 8, 17, 9).millisecondsSinceEpoch ~/ 1000;


Metric _m(num v) => Metric(value: v, confidence: .8, tier: MetricTier.high);

/// Newest-last daily points at local noon, ending today.
List<ChartPoint> _daily(List<double?> v) {
  final now = DateTime.now();
  return [
    for (var i = 0; i < v.length; i++)
      if (v[i] != null)
        (
          t: DateTime(now.year, now.month, now.day - (v.length - 1 - i), 12)
                  .millisecondsSinceEpoch ~/
              1000,
          v: v[i]!,
        ),
  ];
}

String _todayLabel() {
  final n = DateTime.now();
  String two(int x) => x.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)}';
}

/// One fixture per screen, longest realistic values where there is a choice.
Map<String, Widget Function()> _screens() => {
      'sleep': () => SleepDetail(
            data: SleepData(
              day: '2026-05-20',
              night: {
                'duration_min': 360,
                'in_bed_min': 480,
                'efficiency': .75,
                'onset_ts': _onset,
                'wake_ts': _wake,
                'hypnogram': [
                  {'t': _onset, 'stage': 'light'},
                  {'t': _onset + 3600, 'stage': 'deep'},
                  {'t': _onset + 7200, 'stage': 'awake'},
                  {'t': _onset + 7800, 'stage': 'rem'},
                  {'t': _wake, 'stage': 'deep'},
                ],
              },
              timeline: {
                'hr': [
                  {'t': _onset, 'v': 50},
                  {'t': _onset + 14400, 'v': 58},
                  {'t': _wake, 'v': 66},
                ],
                'resp': [
                  {'t': _onset + 14400, 'v': 17.5},
                ],
              },
            ),
          ),
      'readiness': () => ReadinessDetail(
            data: ReadinessData(
              readiness: const Metric(
                  value: 62,
                  unit: '',
                  confidence: .8,
                  tier: MetricTier.estimate),
              series: [for (var i = 0; i < 28; i++) 40.0 + i],
              anchor: DateTime(2026, 5, 20),
            ),
          ),
      'zones': () => ZonesDetail(
            data: ZonesData(zones: [
              for (var i = 0; i < 5; i++)
                (
                  zone: i + 1,
                  name: 'Zone ${i + 1}',
                  lo: 100 + i * 18,
                  hi: 117 + i * 18,
                ),
            ], age: 34),
          ),
      'circadian': () => CircadianDetail(
            data: CircadianData(actogram: [
              for (var i = 0; i < 7; i++) List<double>.filled(24, .5),
            ]),
          ),
      'day_strain': () => DayStrainDetail(
            data: DayStrainData(
              day: DateTime(2026, 5, 20),
              curve: [
                for (var m = 0; m < 1440; m++)
                  m > 420 && m < 1140 ? (m - 420) / 60 : null,
              ],
              strain: 16.8,
              zoneMin: const [212, 96, 41, 18, 4],
              maxHrUsed: 190,
              peakHr: 171,
              wornMin: 743,
              coveragePct: 51,
            ),
          ),
      'day_steps': () => DayStepsDetail(
            data: DayStepsData(
              spans: [
                DayStepSpan(
                    startTs: _nine,
                    endTs: _nine + 3600,
                    steps: 1200,
                    fromBand: false),
                DayStepSpan(
                    startTs: _nine + 14400,
                    endTs: _nine + 18000,
                    steps: 3240,
                    fromBand: true,
                    activity: 'walking'),
              ],
              total: 4440,
              strap: 3240,
              phone: 1200,
              bandLabel: 'WHOOP 4',
            ),
          ),
      'home': () => HomeScreen(
            data: HomeData(
              dayId: '2026-10-04',
              readiness: _m(62),
              sleepMin: _m(412),
              sleepNeedMin: _m(486),
              strain: _m(14.6),
              strainTarget: const {'value': 12, 'low': 10, 'high': 14},
            ),
          ),
      'health': () => HealthScreen(
            data: HealthData(charts: {
              'hrv': _daily([for (var i = 0; i < 30; i++) 60.0 + i % 7]),
              'rhr': _daily([for (var i = 0; i < 30; i++) 52.0 + i % 4]),
            }),
          ),
      'investigate': () => Investigate(
            'rhr',
            data: InvestigateData(
              day: _todayLabel(),
              series: [for (var i = 0; i < 30; i++) 52.0 + i % 4],
              stress: const {'si': 112.5, 'level': 'moderate', 'score': 54.2},
            ),
          ),
      'metric_detail': () => MetricDetail(
            'rhr',
            data: MetricData(
              daysAvailable: 30,
              series: _daily([for (var i = 0; i < 30; i++) 50.0 + i % 6]),
            ),
          ),
      'timeline': () => DayTimelineScreen(
            data: TimelineData(
              day: '2026-08-14',
              graph: DayGraph(
                dayStart: DateTime(2026, 8, 14).millisecondsSinceEpoch ~/ 1000,
                hr: [for (var i = 0; i < 1440; i++) 60 + (i % 20).toDouble()],
                movement: List.filled(1440, null),
              ),
            ),
          ),
      'beats': () => Beats(
            data: BeatsData(
              day: '2026-08-15',
              nn: [
                for (var i = 0; i < 2400; i++)
                  880 + (i % 37) * 3.0 - (i % 11) * 4.0,
              ],
              rawBeats: 2685,
              cleanFraction: .983,
              poincare: const {'sd1': 29.9, 'sd2': 150.7, 'flag': false},
              bins: [
                for (var i = 0; i < 17; i++)
                  (
                    startSec: i * 1800,
                    nBeats: 900,
                    v: 30 + i * 1.5,
                    lo: 26 + i * 1.5,
                    hi: 35 + i * 1.5,
                  ),
              ],
              firstThirdMs: 34.1,
              lastThirdMs: 51.2,
              shape: const Metric(value: 1, confidence: .9),
              dcPoints: _daily([for (var i = 0; i < 30; i++) 7.5 + (i % 5) * .4]),
              dcAnchors: 10435,
              dc: const Metric(value: 8.27, confidence: .95),
              rhythmPoints:
                  _daily([for (var i = 0; i < 30; i++) i == 17 ? 1 : 0]),
              deviceFamily: 'gen4',
            ),
          ),
      'what_changed': () => WhatChangedScreen(
            data: WhatChangedData(
              day: _todayLabel(),
              days: [_todayLabel()],
              findings: const [
                SweepFinding(
                    key: 'rhr',
                    text: 'Resting heart rate was higher than your usual '
                        'for the third night running',
                    z: 2.4,
                    high: true),
                SweepFinding(
                    key: 'rmssd',
                    text: 'Heart rate variability was well below your usual',
                    z: -2.1,
                    high: false),
              ],
              longestHistory: 30,
              hadToday: true,
            ),
          ),
      'cycle': () => const CycleTab(
            data: CycleData(
              enabled: true,
              phase: 'luteal',
              cycleDay: 23,
              medianLength: 29,
              predictedNext: '2026-12-01',
              predictedFrom: '2026-11-28',
              predictedTo: '2026-12-03',
              gapN: 4,
              logs: [
                {'date': '2026-11-09', 'kind': 'start'},
                {'date': '2026-10-11', 'kind': 'start'},
              ],
            ),
          ),
    };

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadType();
  });

  for (final locale in const ['en', 'de', 'es', 'fr', 'hi', 'ru', 'th', 'zh']) {
    for (final scale in const [1.0, 2.0, 3.1]) {
      testWidgets('no screen overflows: $locale, ${scale}x text', (t) async {
        t.view.physicalSize = const Size(390 * 3, 9000 * 3);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        final app = AppState.forTesting();
        addTearDown(app.dispose);

        final failures = <String>[];
        for (final e in _screens().entries) {
          final errors = <FlutterErrorDetails>[];
          final previous = FlutterError.onError;
          FlutterError.onError = errors.add;
          try {
            await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
              value: app,
              child: MaterialApp(
                locale: Locale(locale),
                localizationsDelegates:
                    AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: buildTheme(Brightness.light),
                builder: (c, child) => MediaQuery(
                  data: MediaQuery.of(c)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: e.value(),
              ),
            ));
            await t.pumpAndSettle();
          } finally {
            FlutterError.onError = previous;
          }
          for (final err in errors) {
            final s = err.toString();
            final what = RegExp(r'A RenderFlex overflowed by [^\n]+')
                    .firstMatch(s)
                    ?.group(0) ??
                s.split('\n').first;
            final where = RegExp(r'lib/ui2/[^\s:]+:\d+')
                .allMatches(s)
                .map((m) => m.group(0))
                .toSet()
                .join(', ');
            failures.add('${e.key}: $what ($where)');
          }
          await t.pumpWidget(const SizedBox());
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
  }
}
