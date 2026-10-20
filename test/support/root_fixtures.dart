// Fixture data for the design snapshots of whole screens (tab roots and the
// screens Phase 5 re-heroes). Every value is a plausible real reading, never a
// round placeholder: a layout that holds "52" can still break on "7h 45m".
//
// Each entry is a screen handed its data, so nothing here touches a database.

import 'package:flutter/material.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/live.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/onboarding/profile_setup.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:provider/provider.dart';

/// One app state for every screen that reads it, with no repository: each
/// such screen renders its own honest "nothing yet" path.
final _app = AppState.forTesting();

const _m = MetricTier.high;
const _e = MetricTier.estimate;

/// An ordinary morning: every ring measured, every tile present, a plan.
const homeMeasured = HomeData(
  name: 'Alex',
  dayId: '2026-08-16',
  readiness: Metric(value: 72, confidence: .8, tier: _m),
  drivers: [
    {'label': 'hrv'},
    {'label': 'rhr'},
    {'label': 'resp'},
  ],
  strain: Metric(value: 14.2, confidence: .6, tier: _e),
  sleepMin: Metric(value: 465, unit: 'min', confidence: .8, tier: _e),
  sleepNeedMin: Metric(value: 462, unit: 'min', confidence: .7, tier: _e),
  rhr: Metric(value: 52, unit: 'bpm', confidence: .8, tier: _m),
  steps: Metric(value: 8412, confidence: .8, tier: _e),
  calories: Metric(value: 1174, unit: 'kcal', confidence: .6, tier: _e),
  caloriesTotal: Metric(value: 2890, unit: 'kcal', confidence: .6, tier: _e),
  strainTarget: {'value': 11.4, 'low': 10.2, 'high': 12.6},
);

/// Three nights in: recovery still learning, a real night, a real day.
const homeFirstWeek = HomeData(
  name: 'Alex',
  dayId: '2026-08-16',
  readiness: Metric(note: 'need_baseline:have=3,need=14'),
  strain: Metric(value: 9.8, confidence: .6, tier: _e),
  sleepMin: Metric(value: 401, unit: 'min', confidence: .8, tier: _e),
  rhr: Metric(value: 58, unit: 'bpm', confidence: .8, tier: _m),
  steps: Metric(value: 3120, confidence: .8, tier: _e),
);

/// Onset as a LOCAL wall-clock instant, so the rendered clock times are the
/// same in every timezone.
final _onsetTs = DateTime(2026, 8, 15, 23, 7).millisecondsSinceEpoch ~/ 1000;

/// One night, as the repo emits it: stage segments, then the summary.
Map<String, dynamic> _night() {
  const plan = [
    ('light', 40), ('deep', 55), ('light', 30), ('rem', 25), ('awake', 8),
    ('light', 45), ('deep', 30), ('rem', 40), ('light', 35), ('rem', 30),
    ('awake', 12), ('light', 20),
  ];
  final hyp = <Map<String, dynamic>>[];
  var t = _onsetTs;
  for (final (stage, mins) in plan) {
    hyp.add({'t': t, 'stage': stage});
    t += mins * 60;
  }
  hyp.add({'t': t, 'stage': 'awake'});
  return {
    'duration_min': 443,
    'in_bed_min': 486,
    'awake_min': 20,
    'efficiency': .91,
    'onset_ts': _onsetTs,
    'wake_ts': _onsetTs + 486 * 60,
    'light_min': 170,
    'deep_min': 85,
    'rem_min': 95,
    'hypnogram': hyp,
    'cycle_count': 5,
    'cycles_mean_min': 92,
    'nocturnal': {
      'sleeping_hr_avg': 52,
      'sleeping_hr_min': 46,
      'day_hr_avg': 68,
      'vs_baseline_bpm': 0.4,
      'dip_pct': .24,
      'elevated': false,
    },
    'resp': const {'value': 14.2, 'confidence': .6},
  };
}

Map<String, dynamic> _timeline() => {
      'hr': [
        for (var i = 0; i < 120; i++)
          {'t': _onsetTs + i * 240, 'v': 52 + (i % 11) - 5},
      ],
      'hrv': [
        for (var i = 0; i < 120; i++)
          {'t': _onsetTs + i * 240, 'v': 62 + (i % 17) - 8},
      ],
    };

/// [n] daily points ending today at local noon — the shape `getChart` returns.
List<ChartPoint> _days(int n, double base, double amp) {
  final now = DateTime.now();
  return [
    for (var i = 0; i < n; i++)
      (
        t: DateTime(now.year, now.month, now.day - (n - 1 - i), 12)
                .millisecondsSinceEpoch ~/
            1000,
        v: base + ((i * 37) % 17) / 17 * amp - amp / 2,
      ),
  ];
}

const _env = {'confidence': .8, 'tier': 'HIGH'};

/// A month of history and every overview row present.
HealthData _health() => HealthData(
      daysWithData: 30,
      today: {
        'daily': {
          'resting_hr': {'value': 52, ..._env},
        },
        'hrv': {'rmssd': 64, ..._env},
        'sleep': {
          'duration_min': {'value': 443, ..._env},
        },
        'stress': {'value': 31, 'score': 31, 'level': 'Low', ..._env},
        'resp': {'value': 14.2, 'confidence': .6, 'tier': 'ESTIMATE'},
      },
      charts: {
        'resting_hr': _days(24, 53, 6),
        'hrv': _days(24, 62, 18),
        'sleep': _days(24, 440, 60),
        'stress': _days(24, 32, 20),
        'resp_rate': _days(24, 14.2, 1.2),
      },
    );

/// The screens, by name. A builder rather than a widget so every pump gets a
/// fresh State.
final Map<String, Widget Function()> rootCases = {
  'today': () => const HomeScreen(data: homeMeasured, hour: 9),
  'today_first_week': () => const HomeScreen(data: homeFirstWeek, hour: 9),
  'readiness': () => const ReadinessDetail(
        data: ReadinessData(
          readiness: Metric(value: 72, confidence: .8, tier: _m),
          breakdown: [
            {'label': 'hrv', 'weight': .4, 'used': true, 'past_mdc': true},
            {'label': 'rhr', 'weight': .3, 'used': true, 'past_mdc': false},
          ],
          inputsUsed: 2,
        ),
      ),
  'sleep': () => SleepDetail(
        embedded: true,
        data: SleepData(
          day: '2026-08-16',
          days: const ['2026-08-16', '2026-08-15', '2026-08-14'],
          night: _night(),
          timeline: _timeline(),
          tstHistory: const [430, 465, 410, 452, 401, 470, 438],
        ),
      ),
  'activity': () => ChangeNotifierProvider<AppState>.value(
      value: _app, child: const WorkoutScreen()),
  'health': () => HealthScreen(data: _health()),
  'metric_resting_hr': () => MetricDetail('resting_hr',
      data: MetricData(series: _days(30, 54, 6), daysAvailable: 30)),
  'breathing': () => const Center(
      child: BreathCircle(t: .7, label: 'Inhale')),
  // The live workout is a Scaffold of its own and Char in both themes.
  'live': () => LiveShell(
        quickStart.first,
        subtitle: 'Zone 4',
        result: (_) => throw StateError('a snapshot never finishes'),
        body: (c, e) => Column(children: [
          bigNum(P.of(c), '24:18', ''),
          const SizedBox(height: S.x5),
          const LiveHeart(LiveFeed(
            hr: 148,
            zone: 4,
            zoneMinutes: [6, 14, 22, 16, 4],
            hrCurve: [96, 112, 124, 131, 138, null, null, 141, 146, 149,
                144, 151, 148],
            bandConnected: true,
          )),
        ]),
      ),
  // Onboarding: Char in both themes.
  'welcome': () => WelcomeView(onNew: () {}, onImport: () {}),
  'pick_band': () => DevicePickerView(
        query: TextEditingController(),
        title: 'Pick your band',
        subtitle: 'Wake it and hold it close to this phone.',
        scanning: true,
        onSkip: () {},
      ),
  'pairing': () => PairingView(phase: PairPhase.idle, onPair: () {}),
  'about_you': () => ProfileSetupView(onSave: (_) async {}),
  'profile': () => MultiProvider(providers: [
        ChangeNotifierProvider<AppState>.value(value: _app),
        ChangeNotifierProvider<LocaleController>.value(
            value: LocaleController.seed(null)),
      ], child: const ProfileHome()),
};
