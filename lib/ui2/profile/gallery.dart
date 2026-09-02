// The component gallery, and the one set of fixtures behind it.
//
// Two things live here, and the second is the reason for the first.
//
//   · [galleryCases] — every reusable component in lib/ui2, built once, with
//     a name. `test/ui2_golden_test.dart` shoots the same map, so the picture
//     on the phone and the picture in the goldens cannot describe two
//     different design systems.
//   · [GalleryScreen] — that map on a real device, at a real text scale, in
//     both themes. Every layout bug this project has shipped lived in one of
//     those two dimensions, and neither is visible on a laptop at 1.0×.
//
// The fixtures are deliberately the LONGEST realistic value for every slot,
// never the tidiest. Three shipped bugs — cards overflowing at 2.0×, a status
// row that fitted only the word "Connected", a greeting baked in the evening
// so the morning branch never rendered — were all invisible because the
// example was two characters long and the happy branch.
//
// Nothing here reads the database, the band or the repository: a gallery that
// needs data is a gallery nobody opens on a fresh install.

import 'dart:convert';
import 'dart:math';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../coach/coach_config.dart';
import '../../data/day_label.dart';
import '../../data/journal_fields.dart';
import '../../data/med_store.dart';
import '../../data/nutrition_store.dart';
import '../../ai/nightly_sweep.dart' show SweepFinding;
import '../../compute/findings.dart';
import '../../models/metric.dart';
import '../activity/catalogue.dart';
import '../activity/live.dart';
import '../activity/picker.dart' show ActivityPicker, ActivityRow;
import '../activity/poster.dart'
    show PosterCard, PosterFormat, PosterStatRow, kPosterMapH, kPosterMapW;
import '../activity/setup.dart' show ActivitySetup;
import '../activity/tiles.dart';
import '../activity/share.dart' show ShareSheet, shareOrigin;
import '../activity/summary.dart';
import '../onboarding/welcome.dart' show ImportOutcome, ImportReport;
// Screens are deliberately not re-exported from the ui2 barrel (see the
// barrel test), so their components are imported by path.
import '../screens/screens.dart';
import '../ui2.dart';
import 'devices.dart';
import 'profile.dart';

/// A deterministic series — a gallery cannot depend on random data, and
/// neither can a golden.
final _series =
    List<double>.generate(24, (i) => 52 + (i * 37 % 23) - (i % 5) * 2.0);

/// The four answers [trendOf] can give: a move clear of its own noise in
/// either direction, a move inside it, and a series too short to compare at
/// all. [_falling] is [_rising] backwards — without it no fixture in this
/// gallery ever produced `Trend.falling`, so the down arrow was the one glyph
/// in the trailing slot nobody could look at.
const _rising = <double?>[50, 51, 50, 52, 51, 53, 58, 59, 60];
const _falling = <double?>[60, 59, 58, 53, 51, 52, 50, 51, 50];
const _flat = <double?>[50, 51, 50, 51, 50, 51, 50, 51, 50];
const _tooShort = <double?>[50, 51, 50];

// ── the three rings, in the four states a ring has ──
//
// Fed as HomeData through the SAME mapping the screen uses, so a state the
// gallery shows is a state the screen can actually produce. Hand-built ring
// objects would drift from it the first time the mapping changed.

/// All three measured. Sleep has a computed need behind it, so its ring has a
/// denominator that is the user's own rather than the hardcoded 480.
const _ringsMeasured = HomeData(
  dayId: '2026-08-16',
  readiness: Metric(value: 72, confidence: .8, tier: MetricTier.high),
  drivers: [
    {'label': 'hrv'},
    {'label': 'rhr'},
    {'label': 'resp'},
  ],
  strain: Metric(value: 14.2, confidence: .6, tier: MetricTier.estimate),
  sleepMin: Metric(
      value: 465, unit: 'min', confidence: .8, tier: MetricTier.estimate),
  sleepNeedMin: Metric(
      value: 462, unit: 'min', confidence: .7, tier: MetricTier.estimate),
);

/// Recovery three nights into a fourteen-night baseline, and a real night with
/// nothing to measure it against.
const _ringsCalibrating = HomeData(
  dayId: '2026-08-16',
  readiness: Metric(note: 'need_baseline:have=3,need=14'),
  strain: Metric(value: 9.8, confidence: .6, tier: MetricTier.estimate),
  sleepMin: Metric(
      value: 401, unit: 'min', confidence: .8, tier: MetricTier.estimate),
);

/// Nothing measured, three different reasons: one the pipeline named, one it
/// named differently, and one nothing said anything about at all.
const _ringsAbsent = HomeData(
  dayId: '2026-08-16',
  readiness: Metric(note: 'need_input:name=nn_beats,have=0,need=1'),
  strain: Metric(note: 'need_input:name=today_activity'),
  sleepMin: Metric(),
);

/// The overnight block held over from an older night while strain describes
/// today — one sentence under the rings rather than a date under two of them.
const _ringsHeldOver = HomeData(
  dayId: '2026-08-16',
  heldOverNight: '2026-08-14',
  readiness: Metric(value: 41, confidence: .6, tier: MetricTier.estimate),
  strain: Metric(value: 3.1, confidence: .6, tier: MetricTier.estimate),
  sleepMin: Metric(
      value: 322, unit: 'min', confidence: .8, tier: MetricTier.estimate),
);

/// Newest first, the shape `availableDays()` returns. Today leads it so the
/// stepper's "Today" state can be photographed; the rest are FIXED dates,
/// because a golden whose label is `DateTime.now()` fails tomorrow morning.
final _navDays = [
  todayLabel(),
  '2026-05-20',
  '2026-05-19',
  '2026-05-18',
  '2026-05-17',
];

const _night = <SleepStage>[
  ...[SleepStage.awake, SleepStage.light, SleepStage.light, SleepStage.deep],
  ...[SleepStage.deep, SleepStage.light, SleepStage.rem, SleepStage.light],
  ...[SleepStage.deep, SleepStage.light, SleepStage.rem, SleepStage.awake],
  ...[SleepStage.light, SleepStage.rem, SleepStage.light, SleepStage.awake],
];

/// Everything, in the order the gallery lists it.
Map<String, Widget> galleryCases() => {...goldenCases(), ...extraCases()};

/// The cases the goldens photograph. Named separately from [extraCases] only
/// because a PNG per case per theme per scale is a file somebody has to
/// review — see the note at the bottom of the golden test.
Map<String, Widget> goldenCases() => {
      // The one number the whole app is judged by, and the picture the app
      // leaves someone else's phone. Both are photographed rather than merely
      // swept: they are the two components a regression would be noticed in
      // last and cost the most.
      'rings': const RingTrio(d: _ringsMeasured),
      // The two states that decide whether the trio is honest, in one picture:
      // recovery still filling its baseline (progress, not a bad score), and a
      // real duration with no computed need to draw it against.
      'rings_calibrating': const RingTrio(d: _ringsCalibrating),
      // All three empty. Each one says the absence in words where the number
      // goes and carries the PIPELINE'S reason on the row that opens the
      // screen which can say more — including the one absence nothing
      // explained, which says exactly that.
      'rings_absent': const RingTrio(d: _ringsAbsent),
      // The ONE card, both faces: the map as the background, and a photograph
      // as the background with the route dissolved into its corner.
      'share_card': _shareCard(photo: false),
      'share_card_photo': _shareCard(photo: true),
      // The other destination. Same hero, same stats, a different shape —
      // shot because a 9:16 card is where the column's arithmetic has the
      // most room to go wrong, not because it is a different design.
      'share_card_story': _shareCard(photo: false, format: PosterFormat.story),
      'signal': const SignalCard(
          LucideIcons.heartPulse, C.blue, 'Resting heart rate', '52',
          unit: 'bpm', sub: '4 BELOW YOUR BASELINE'),
      // A REALISTIC value, not two characters. Every card below used to be
      // shot with '52' / '38 min' / '+6', and the 2.0x tier passed because of
      // it: with a duration or a thousands separator in the same slot, six
      // components overflowed at the very scale the goldens claimed to cover.
      'progress': const ProgressCard(
          'Time asleep', '1h 38m', 'of 2h 00m', .63, C.domMove,
          icon: LucideIcons.footprints),
      'trend': TrendCard('Time asleep', '7h 42m', 'last night', '+38m',
          'vs 14-day baseline', _series, C.green,
          up: true),
      'insight': const InsightCard(
        'Your sleep debt cleared overnight',
        'Seven hours forty, the longest this week, and your heart rate '
            'settled forty minutes earlier than usual.',
        action: 'See the night',
      ),
      'action': const ActionCard('Charge the strap', '18% remaining',
          'Remind me', LucideIcons.batteryLow, C.orange),
      'status': const StatusCard(
        'No respiratory rate last night',
        'The strap was off your wrist between 01:10 and 06:40, so there was '
            'nothing to measure.',
        fix: 'How wear position affects this',
      ),
      'deep_dive': DeepDiveCard('Heart rate variability', '7h 42m', 'ms',
          'Open the full night', C.purple,
          preview: SizedBox(
            height: 48,
            child: CustomPaint(
                size: Size.infinite, painter: LineChart(_series, C.purple)),
          )),
      'metric_row': const Column(children: [
        // The trailing states, in order: good news up, bad news up, bad news
        // DOWN (the arrow that no fixture used to reach), a move inside its
        // own noise, and a series with no basis for a direction (which draws
        // nothing rather than a flat arrow that would read as a measured "no
        // change").
        MetricRow(LucideIcons.activity, C.green, 'HRV', '64',
            unit: 'ms', series: _rising, rising: Rising.good),
        MetricRow(LucideIcons.heart, C.red, 'Resting heart rate', '58',
            unit: 'bpm', series: _rising, rising: Rising.bad),
        MetricRow(LucideIcons.moon, C.indigo, 'Sleep efficiency', '84',
            unit: '%', series: _falling, rising: Rising.good),
        MetricRow(LucideIcons.thermometer, C.orange, 'Skin temperature', '+0.3',
            sub: 'RELATIVE TO BASELINE', unit: '°', series: _rising),
        MetricRow(LucideIcons.brain, C.purple, 'Stress', '31',
            unit: '/100', series: _flat, rising: Rising.bad),
        MetricRow(LucideIcons.wind, C.teal, 'Respiratory rate', '14.2',
            unit: 'br/min', series: _tooShort),
        // A long name, a thousands-separated value and a word in the trailing
        // slot — 'ON TRACK' needs 92 pt at 1.0x and was clipped inside a fixed
        // 52 pt box before any scaling at all.
        MetricRow(LucideIcons.flame, C.orange, 'Active energy burned', '2,310',
            unit: 'kcal', status: 'ON TRACK'),
      ]),
      'inline_metrics': const InlineMetrics([
        ('ASLEEP', '7h 40m', C.blue),
        ('EFFICIENCY', '91%', C.green),
        ('AWAKE', '22m', C.orange),
      ]),
      'recommendation': const Recommendation(
        'Keep it easy today',
        'HRV is six milliseconds below your baseline and resting heart rate '
            'is up three — the same pattern as the day before your last cold.',
        'See what changed',
      ),
      'goal_trajectory': const GoalTrajectory(
          'Weight', '78.4 kg', '75 kg', '0.3 kg per week', .62, C.teal),
      'observation': const Observation(
        'Your resting heart rate has risen on six of the last seven nights',
        'From 51 to 58 bpm, alongside a 0.4° skin-temperature rise.',
        advice: 'Worth mentioning if it continues past a week.',
      ),
      'consistency': const Consistency(
          18, 24, 'Nights with a full sleep record', C.domHealth),
      'pill_row': const Wrap(spacing: S.x2, runSpacing: S.x2, children: [
        Pill('Estimated', C.yellow, icon: LucideIcons.circleDashed),
        Pill('Relative', C.purple),
      ]),
      'big_button': const Column(children: [
        BigButton('Start workout', icon: LucideIcons.play, color: C.domMove),
        SizedBox(height: S.x3),
        BigButton('Not now', color: C.domMove, soft: true),
      ]),
      'sub_tabs': SubTabs(
          const ['Today', 'Sleep', 'Recovery', 'Strain'], 1, (_) {},
          color: C.domHealth),
      // The three states a metric screen's per-device filter draws: a
      // selectable pill with real coverage, a selectable pill with no data in
      // the visible range, and a non-selectable pill with a physical reason —
      // exercises the 3.1x/tap-floor sweep on the disabled path (M6 §7.2).
      'device_filter': DeviceFilter(
        options: const [
          (deviceId: '', label: 'Band', selectable: true, reason: null),
          (
            deviceId: 'ring-A1B2',
            label: 'Ring',
            selectable: true,
            reason: 'no data in this range',
          ),
          (
            deviceId: 'ble_hrs-0a1b2c',
            label: 'Chest strap',
            selectable: false,
            reason: 'no accelerometer',
          ),
        ],
        selected: null,
        onSelect: (_) {},
      ),
      'nav_bar': const NavBar('Last night', sub: 'MON 14 AUG'),
      // The stepper every single-day screen wears. Shot mid-history, where
      // both arrows are live and the middle opens the calendar — the state a
      // user spends all their time in once there is more than a week on disk.
      'day_nav': DayNav(
          day: _navDays[2], days: _navDays, onDay: (_) {}),
      // The newest day: forward is dead, and the label reads Today rather than
      // a date. Both halves of that are the honesty — there is no day after
      // this one, and saying so beats a live arrow that does nothing.
      'day_nav_today': DayNav(
          day: _navDays.first, days: _navDays, onDay: (_) {}),
      'section': const Section('Recovery', StatusCard('Nothing yet today',
          'The first sync of the day has not landed.'),
          action: 'History'),
      ..._chartCases(),
      ..._coachFigureCases(),
      ..._nutritionAndWellnessCases(),
    };

/// The AI coach's figures. The model authors these specs, so the cases that
/// matter are the loose ones: a series with a hole in it, a table wider than the
/// screen, and a figure type the app does not draw. All three are things a model
/// will send, and all three used to be a grey JSON block in the transcript.
Map<String, Widget> _coachFigureCases() => {
  'coach_fig_line': const CoachFigure(spec: {
    'type': 'line',
    'title': 'HRV, last two weeks',
    'unit': 'ms',
    'x_labels': ['1 Aug', '7 Aug', '14 Aug'],
    'series': [
      {
        'name': 'RMSSD',
        'values': [62, 58, null, 71, 66, 69, 74],
      },
    ],
  }),
  'coach_fig_kpis': const CoachFigure(spec: {
    'type': 'kpi_grid',
    'title': 'Last night',
    'cards': [
      {'label': 'Time asleep', 'value': '7:12', 'unit': 'h'},
      {'label': 'Resting HR', 'value': '54', 'unit': 'bpm', 'baseline': 'usual 52–58'},
    ],
  }),
  'coach_fig_table': const CoachFigure(spec: {
    'type': 'table',
    'title': 'Sessions this week',
    'columns': ['Day', 'Type', 'Minutes', 'Strain'],
    'rows': [
      ['Mon', 'Run', '42', '11.4'],
      ['Thu', 'Strength', '55', '8.1'],
    ],
  }),
  'coach_fig_unsupported': const CoachFigure(spec: {
    'type': 'sankey',
    'title': 'Where my day went',
  }),
  // The data boundary. `CoachConfig()` here is unloaded, so it reads as the
  // default cloud endpoint — which is the case worth capturing: the local one
  // is the reassuring half.
  'coach_sent_payload': SentPayload(
    config: CoachConfig(),
    inputs: const {
      'readiness': 62,
      'rmssd_ms': 48,
      'resting_hr': 54,
      'sleep_min': 432,
      'skin_temp_z': -0.4,
    },
  ),
};

/// Charts, framed. Every one of these is captured with the thing that was
/// missing before: a unit in the header, numbers on the y axis, labels under
/// the x axis, a key for every colour — and, for the empty case, an honest
/// sentence where the axis would have been.
Map<String, Widget> _chartCases() {
  // 40…80 bpm, deterministic.
  final rhr = List<double>.generate(30, (i) => 52 + (i * 13 % 17) - (i % 4) * 1.0);
  final minutes = List<double>.generate(7, (i) => 380 + (i * 47 % 90).toDouble());
  // A `Builder`, because a painter's palette is now solved against the surface
  // it lands on — the same case has to draw different ink in the two themes,
  // and this map is built once and shot in both.
  return {
    'chart_line': Builder(builder: (c) {
      final p = P.of(c);
      return Surface(
        child: ChartFrame(
          title: 'Resting heart rate',
          unit: 'bpm',
          yAxis: AxisSpec.of(rhr, floor: 40),
          xLabels: const ['30 Jul', '14 Aug', 'Today'],
          footnote: 'Your usual range is 52–64 bpm.',
          series: rhr,
          child: CustomPaint(
            size: Size.infinite,
            painter: LineChart(rhr, p.on(C.blue),
                axis: AxisSpec.of(rhr, floor: 40), dots: true),
          ),
        ),
      );
    }),
    // The same chart with a release boundary on it. `getChart` has carried
    // `algo_breaks` all along and no screen read it, so a trend drew straight
    // through the day the numbers either side stopped being comparable.
    'chart_line_algo_break': Builder(builder: (c) {
      final p = P.of(c);
      return Surface(
        child: ChartFrame(
          title: 'Readiness',
          unit: 'score',
          yAxis: AxisSpec.of(rhr, floor: 40),
          xLabels: const ['30 Jul', '14 Aug', 'Today'],
          xMarks: const [.55],
          footnote: 'The dotted line is a change in how these days were '
              'computed. Readings either side of it came from different '
              'versions.',
          series: rhr,
          child: CustomPaint(
            size: Size.infinite,
            painter: LineChart(rhr, p.on(C.green),
                axis: AxisSpec.of(rhr, floor: 40), dots: true),
          ),
        ),
      );
    }),
    'chart_bars': Builder(builder: (c) {
      final p = P.of(c);
      return Surface(
        child: ChartFrame(
          title: 'Time asleep',
          unit: 'per night',
          height: 110,
          yAxis: AxisSpec.of(minutes, floor: 0, format: axisHm, step: 120),
          xLabels: const ['Mon', 'Thu', 'Sun'],
          series: minutes,
          child: CustomPaint(
            size: Size.infinite,
            painter: Bars(minutes, p.on(C.domHealth),
                axis: AxisSpec.of(minutes, floor: 0, format: axisHm, step: 120)),
          ),
        ),
      );
    }),
    'chart_hypnogram': Builder(builder: (c) {
      final p = P.of(c);
      return Surface(
        child: ChartFrame(
          title: 'Last night',
          unit: 'sleep stages',
          height: 96,
          xLabels: const ['23:10', '03:00', '06:40'],
          legend: Hypnogram.legend(p),
          footnote: 'Deep sleep is inferred from heart-rate flatness.',
          child: CustomPaint(size: Size.infinite, painter: Hypnogram(_night, p)),
        ),
      );
    }),
    'chart_zones': Builder(builder: (c) {
      final p = P.of(c);
      return Surface(
        child: ChartFrame(
          title: 'Time in heart-rate zones',
          unit: 'share of the session',
          height: 28,
          legend: ZoneBar.legend(p),
          child: CustomPaint(
              size: Size.infinite,
              painter: ZoneBar(const [.18, .34, .28, .15, .05], p)),
        ),
      );
    }),
    'chart_empty': const Surface(
      child: ChartFrame(
        title: 'Respiratory rate',
        unit: 'breaths/min',
        yAxis: AxisSpec(min: 10, max: 20, format: axisInt),
        xLabels: ['Mon', 'Sun'],
        empty: NoData(message: 'No nights recorded this week'),
        child: SizedBox.shrink(),
      ),
    ),
  };
}

/// Nutrition and Wellness. Every one of these is a widget the screens compose
/// from, captured with the state that is easiest to get wrong: a day whose
/// energy is a floor rather than a total, an occasion with no numbers, a dose
/// that has not come due yet.
Map<String, Widget> _nutritionAndWellnessCases() {
  const bare = FoodEntry(
      id: 'a', date: '2026-08-14', meal: 'dinner', label: 'Dinner');
  const known = FoodEntry(
      id: 'b',
      date: '2026-08-14',
      meal: 'breakfast',
      label: 'Porridge and berries',
      kcal: 420,
      proteinG: 14,
      carbsG: 62,
      fatG: 9,
      confirmed: true);
  return {
    // A day that summed past an unknown: the number is a FLOOR and says so.
    'day_energy_floor': DayEnergyCard(
      day: rollupDay('2026-08-14', const [known, bare], today: '2026-08-15'),
      burned: const Metric(
          value: 2350, unit: 'kcal', confidence: .6, tier: MetricTier.estimate),
    ),
    'meal_row': const Column(children: [
      MealRow(meal: 'breakfast', entries: [known]),
      MealRow(meal: 'dinner', entries: []),
    ]),
    'food_row': const Surface(
        pad: EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          FoodRow(entry: known, trailing: LucideIcons.circlePlus),
          FoodRow(entry: bare),
        ])),
    // `.preview`, because the gallery has no band and no Provider. The numbers
    // are a fixture and are shaped like one — a resting wobble, not a workout.
    'live_hr_card': const LiveHrCard.preview(hr: 68, trace: [
      64, 65, 65, 66, 67, 66, 65, 66, 68, 69, 70, 69, 68, 67, 66, 66, 67, 68,
      69, 68, 67, 67, 68, 69, 70, 71, 70, 69, 68, 68,
    ]),
    'mood_picker': MoodPicker(value: 4, onChanged: (_) {}),
    'mood_picker_blank': MoodPicker(onChanged: (_) {}),
    'field_stepper': Surface(
        child: Column(children: [
          FieldStepper(
              spec: kJournalFieldsByKey['water_ml']!,
              value: 1500,
              onChanged: (_) {}),
          FieldStepper(
              spec: kJournalFieldsByKey['caffeine_mg']!,
              value: null,
              onChanged: (_) {}),
        ])),
    'text_field': OsTextField(
        controller: TextEditingController(text: 'Slept badly, big lunch.'),
        label: 'Anything else',
        lines: 3),
    'breath_circle': const BreathCircle(t: .7, label: 'Inhale'),
    'driver_row': const Surface(
        pad: EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          DriverRow(
              label: 'HRV above your baseline',
              detail: '68 ms against a 14-night mean of 61'),
          DriverRow(
              label: 'Slept 52 minutes short', detail: '7h 08m against 8h 00m'),
        ])),
    'med_row': Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (final s in _medSlots) MedRow(slot: s),
        ])),
  };
}

// ══════════════════ a finished session ══════════════════

/// One completed activity, carrying enough of everything that every share
/// style has something to draw: a route, splits, a heart-rate curve WITH a
/// dropout in it, and elevation.
final _finished = ActivityResult(
  const Activity('Trail running', LucideIcons.mountain, C.green,
      Track.distance, 10.5,
      gps: true),
  // Fixed, never `DateTime.now()` — a gallery case that moves is a golden
  // that fails on a Tuesday.
  start: DateTime(2026, 8, 13, 18, 20),
  // `Motion.tick * seconds` rather than a literal: theme.dart is the only
  // file allowed to spell a Duration, and this is one second times N.
  duration: Motion.tick * 3734,
  avgHr: 148,
  maxHr: 176,
  calories: 812,
  strain: 14.6,
  hr: [
    for (var i = 0; i < 62; i++)
      i > 28 && i < 34 ? null : 132 + (i * 19 % 31) * 1.0,
  ],
  zoneMinutes: const [6, 14, 22, 16, 4],
  route: _route,
  routePace: [for (var i = 0; i < _route.length; i++) (i % 20) / 20],
  distanceKm: 12.42,
  elevationM: _metres,
  gainM: 318,
  lossM: 302,
  splits: const [
    KmSplit(1, 302, avgHr: 141),
    KmSplit(2, 288, avgHr: 149),
    KmSplit(3, 331, avgHr: 152),
  ],
);

/// The card with a photo behind it, and the card without.
///
/// These are the two faces of the ONE card — there are no styles any more.
/// Without a photo the basemap is the background; with one the photograph is,
/// and the route dissolves into the corner. Neither case here has a mosaic
/// (see the note on 'poster'), so what these shoot is the no-basemap face of
/// both, which is also what a user with no signal gets.
Widget _shareCard({required bool photo, PosterFormat format = PosterFormat.post}) =>
    PosterCard(_finished, photo: photo ? _flatPhoto : null, format: format);

/// A four-pixel slab of colour, standing in for the user's photograph.
///
/// Embedded rather than an asset because a golden must not depend on a file
/// somebody can move, and generated rather than fetched because a gallery
/// that needs the network is a gallery that fails on a plane. What the photo
/// case has to show is the LAYOUT — the scrim over a real background and the
/// route dissolving into the corner — and a flat slab shows both.
final _flatPhoto = MemoryImage(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGNIyGuAIwbiOAAd'
    'EhTheEnmewAAAABJRU5ErkJggg=='));

/// A session that measured nothing but its own length — the grid prints the
/// one stat it has rather than a row of blanks, and the hero falls back to
/// the clock.
final _bare = ActivityResult(
  activityByName('Meditation')!,
  start: DateTime(2026, 8, 13, 22, 5),
  duration: Motion.tick * 900,
);

const _medDef = MedDef(
    key: 'custom_d',
    label: 'Vitamin D',
    doseValue: 2000,
    doseUnit: 'IU',
    schedule: [MedSchedule(480, [1, 2, 3, 4, 5, 6, 7])]);

/// Taken, missed and not-yet-due, side by side — the third is the one that
/// must never read as a failure.
const _medSlots = <MedSlot>[
  MedSlot(def: _medDef, date: '2026-08-14', slotMin: 480, state: DoseState.taken),
  MedSlot(
      def: MedDef(key: 'custom_m', label: 'Magnesium', doseValue: 300, doseUnit: 'mg'),
      date: '2026-08-14',
      slotMin: 780,
      state: DoseState.missed),
  MedSlot(
      def: MedDef(key: 'custom_z', label: 'Zinc'),
      date: '2026-08-14',
      slotMin: 1260,
      state: DoseState.upcoming),
];

// ══════════════════ the rest of the vocabulary ══════════════════
//
// The primitives and the painters the goldens do not photograph. They are
// still swept for overflow and for the 44 pt minimum at every text tier by
// the golden test, which is the half of the coverage that catches bugs
// without adding a PNG nobody reviews.

/// An out-and-back loop, normalised 0…1 in both axes — the projection is the
/// caller's job, and here the caller is a fixture.
final _route = [
  for (var i = 0; i < 90; i++)
    Offset(.5 + .38 * cos(i / 90 * 2 * pi),
        .5 + .30 * sin(i / 90 * 2 * pi) * (1 - i / 260)),
];

// A climb and a descent with a rough surface on it, not noise: an elevation
// profile shaped like white noise is a reference picture nobody can tell a
// broken painter from.
final _metres = List<double>.generate(
    120, (i) => 180 + 240 * sin(i / 120 * pi) + (i % 7) * 3.0);
final _psd = List<double>.generate(64, (i) => (i < 20 ? 40 - i : 26 - i * .3)
    .clamp(1, 60)
    .toDouble());

Map<String, Widget> extraCases() => {
      // The edge treatment that tells a horizontal row it continues. Swept
      // rather than photographed because the state worth seeing is the one a
      // still cannot hold: it is ABSENT when the content fits, present when it
      // does not, and gone again at the end of the scroll. Both halves are
      // asserted in ui2_scroll_hint_test.
      'scroll_hint': Builder(
        builder: (c) => SizedBox(
          height: MediaQuery.textScalerOf(c).scale(S.tap),
          child: ScrollHint(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: const [
                Pill('Mind', C.domMind),
                SizedBox(width: S.x2),
                Pill('Recovery', C.domMind),
                SizedBox(width: S.x2),
                Pill('Habits', C.domMind),
                SizedBox(width: S.x2),
                Pill('Medication', C.domMind),
                SizedBox(width: S.x2),
                Pill('Cycle', C.domMind),
              ],
            ),
          ),
        ),
      ),
      // WHAT CHARGED AND DRAINED YOU, taken apart. Swept rather than
      // photographed because the interesting cases are the ones a golden
      // cannot show: a driver that moved but stayed inside its own spread, and
      // one that could not be used at all. Both have to render as neither
      // helping nor holding you back — a row under "what helped" reading
      // `+0.0` is a small lie, and skin temperature is a raw ADC so its
      // NUMBERS are suppressed as well as its chart.
      'driver_breakdown': DriverBreakdown(driverFacts(
        breakdown: const [
          {
            'label': 'hrv',
            'used': true,
            'weight': 0.40,
            'weighted_contribution': -6.2,
            'past_mdc': true,
          },
          {
            'label': 'rhr',
            'used': true,
            'weight': 0.30,
            'weighted_contribution': 3.1,
            'past_mdc': false,
          },
          {
            'label': 'resp',
            'used': false,
            'weight': 0.15,
            'note': 'need_baseline:have=2,need=7',
          },
          {
            'label': 'temp',
            'used': true,
            'weight': 0.15,
            'weighted_contribution': -1.4,
            'past_mdc': true,
          },
        ],
        baselines: const {
          'hrv': {
            'value': 41.2,
            'baseline': 58.4,
            'spread': 6.1,
            'delta': -17.2,
            'mdc_multiples': -2.3,
          },
          'resting_hr': {
            'value': 54.0,
            'baseline': 56.8,
            'spread': 2.2,
            'delta': -2.8,
            'mdc_multiples': -0.7,
          },
          // Deliberately present and deliberately not printed — see
          // DriverFacts.numeric.
          'skin_temp': {
            'value': 32411.0,
            'baseline': 32380.0,
            'spread': 12.0,
            'delta': 31.0,
            'mdc_multiples': 1.9,
          },
        },
      )),
      // Swept rather than photographed: it is the measured trio plus one
      // sentence. Two of the three rings are last night's and the third is
      // today's, and the morning before the first sync is not a rare case.
      'rings_held_over': const RingTrio(d: _ringsHeldOver),
      // THE ABSENCE THAT KNOWS WHY. `wearGapWhy` reads the day's off-wrist
      // stretches — written on every derive, read by nothing until now — and
      // hands the card the reason as a measurement. Both rankings, because the
      // rule is the whole feature: a sentence the screen made up is REPLACED
      // by the one that was measured, and a reason the pipeline gave keeps its
      // place with the gap added after it.
      'status_wear_gap': StatusCard.forMetric('No sleep', Metric.empty,
          why: 'No sleep period long enough to score was recorded.',
          gap: 'Your band was off your wrist 11:20 PM – 2:14 AM.')!,
      // The three nap states, which are three different answers and must not
      // read as one: a day with naps, a judged day that had none (a MEASURED
      // zero, so it says None rather than a dash), and a day nothing could be
      // said about at all.
      'nap_row': const MetricRow(LucideIcons.sun, C.indigo, 'Daytime sleep',
          '1h 12m',
          sub: '2 naps · Sunday, 16 August'),
      'nap_row_none': const MetricRow(
          LucideIcons.sun, C.indigo, 'Daytime sleep', 'None',
          sub: 'None detected · Sunday, 16 August'),
      'nap_unjudged': const StatusCard(
        'No nap reading for Sunday, 16 August',
        'Naps come off the same 1 Hz recording the rest of the day does, and '
            'this day does not have enough of it.',
        icon: LucideIcons.sun,
      ),
      // A health watch in the log. Two accents across six detectors, not six:
      // a colour per detector reads as a severity scale nobody calibrated.
      'finding_row': const FindingRow(Finding(FindingKind.illness, '2026-08-16')),
      'finding_row_plain':
          const FindingRow(Finding(FindingKind.rhrShift, '2026-08-16', risen: true)),
      'status_wear_gap_after_pipeline': StatusCard.forMetric(
        'No respiratory rate',
        const Metric(note: 'need_input:name=nn_beats,have=12,need=20'),
        gap: 'Your band was off your wrist 11:20 PM – 2:14 AM.',
      )!,
      // Both asks stacked, default (unloaded) Prefs state — the same state
      // an actual first run starts from, since an unset dismissed/last-shown
      // key reads as "eligible, never shown yet".
      'community_nudge': const CommunityNudge(),
      'surface': Builder(
        builder: (c) => Surface(
          child: Text(
            'The base card. Elevation, not outline — and the only surface a '
            'component may sit on.',
            style: F.body.copyWith(color: P.of(c).ink),
          ),
        ),
      ),
      'pressable': Builder(
        builder: (c) => Pressable(
          onTap: () {},
          semanticLabel: 'Open the full night',
          child: Text('Open the full night',
              style: F.body.copyWith(color: P.of(c).on(C.green))),
        ),
      ),
      'screen_title': const ScreenTitle('Sleep and recovery',
          trailing: Pill('Estimated', C.yellow)),
      // Static on purpose: the gallery shows the control, and its position is
      // a fixture like every other value here.
      'scrubber': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Last night',
            unit: 'sleep stages',
            height: 96,
            xLabels: const ['23:10', '03:00', '06:40'],
            legend: Hypnogram.legend(p),
            child: Scrubber(
              value: .42,
              onChanged: (_) {},
              label: 'Hypnogram',
              describe: (_) => '03:12, light sleep',
              child:
                  CustomPaint(size: Size.infinite, painter: Hypnogram(_night, p)),
            ),
          ),
        );
      }),
      'chart_ring': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Readiness',
            unit: 'out of 100',
            height: 120,
            footnote: 'Against your own 14-day baseline, not a population.',
            child: CustomPaint(
                size: Size.infinite,
                painter: Ring(.72, p.on(C.green), p.track)),
          ),
        );
      }),
      'chart_macro_ring': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Protein',
            unit: 'of 140 g',
            height: 44,
            child: CustomPaint(
                size: Size.infinite,
                painter: MacroRing(.48, p.on(C.orange), p.track)),
          ),
        );
      }),
      'chart_actogram': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Rest and activity by hour',
            unit: 'last 28 days',
            height: 120,
            xLabels: const ['18 Jul', '1 Aug', 'Today'],
            // A missing day is a null column, not a quiet one.
            child: CustomPaint(
              size: Size.infinite,
              painter: Actogram([
                for (var d = 0; d < 28; d++)
                  d == 9 || d == 10
                      ? null
                      : [for (var h = 0; h < 24; h++) ((h + d) % 24) / 24],
              ], p.on(C.domMove)),
            ),
          ),
        );
      }),
      'chart_heatmap': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Nights with a full sleep record',
            unit: 'last 12 weeks',
            height: 96,
            xLabels: const ['24 May', '19 Jul', 'This week'],
            child: CustomPaint(
              size: Size.infinite,
              painter: HeatMap([
                for (var w = 0; w < 12; w++)
                  [
                    for (var d = 0; d < 7; d++)
                      (w * 7 + d) % 11 == 0 ? null : ((w + d) % 5) / 4,
                  ],
              ], p.on(C.domHealth), p.track),
            ),
          ),
        );
      }),
      'chart_spectrum': Builder(builder: (c) {
        final p = P.of(c);
        final painter = Spectrum(_psd, lf: p.on(C.blue), hf: p.on(C.purple));
        return Surface(
          child: ChartFrame(
            title: 'Heart-rate variability spectrum',
            unit: 'ms² per Hz',
            height: 96,
            legend: painter.legend,
            footnote: 'Beat timing at 1 Hz is pulse-rate variability, not ECG.',
            child: CustomPaint(size: Size.infinite, painter: painter),
          ),
        );
      }),
      'chart_night_stack': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Heart rate, movement and skin temperature',
            unit: 'over one night',
            height: 140,
            xLabels: const ['23:10', '03:00', '06:40'],
            child: CustomPaint(
              size: Size.infinite,
              painter: NightStack([
                [for (var i = 0; i < 96; i++) 52 + (i * 17 % 19) * 1.0],
                [for (var i = 0; i < 96; i++) (i * 29 % 13) * 1.0],
                // A lane with a gap in it — the honest shape of a night the
                // strap spent partly off the wrist.
                [
                  for (var i = 0; i < 96; i++)
                    i > 40 && i < 52 ? null : 33 + (i % 9) * .1,
                ],
              ], [p.on(C.red), p.on(C.domMove), p.on(C.orange)]),
            ),
          ),
        );
      }),
      'activity_route': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Thursday evening, along the canal',
            unit: '8.4 km',
            height: 160,
            child: CustomPaint(
              size: Size.infinite,
              painter: RouteMap(_route,
                  pace: [for (var i = 0; i < _route.length; i++) (i % 20) / 20],
                  slow: p.on(C.red),
                  fast: p.on(C.green),
                  pinStart: p.on(C.green),
                  pinEnd: p.on(C.red),
                  pinInk: p.inkOnFill),
            ),
          ),
        );
      }),
      'activity_elevation': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Elevation',
            unit: 'm',
            height: 110,
            yAxis: AxisSpec.of(_metres, floor: 0),
            xLabels: const ['Start', '4.2 km', '8.4 km'],
            series: _metres,
            child: CustomPaint(
              size: Size.infinite,
              painter: Elevation(_metres, p.on(C.teal),
                  markerInk: p.inkOnFill, axis: AxisSpec.of(_metres, floor: 0)),
            ),
          ),
        );
      }),
      'activity_lap_bars': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Laps',
            unit: '50 m, fastest first',
            height: 120,
            child: CustomPaint(
              size: Size.infinite,
              painter: LapBars(const [1, .92, .88, .95, .71, .64],
                  p.on(C.domHealth), p.track,
                  done: 3),
            ),
          ),
        );
      }),
      'activity_breath_ring': Builder(builder: (c) {
        final p = P.of(c);
        return Surface(
          child: ChartFrame(
            title: 'Box breathing',
            unit: 'four counts in',
            height: 140,
            child: CustomPaint(
                size: Size.infinite,
                painter: BreathRing(.55, p.on(C.domMind))),
          ),
        );
      }),
      'activity_interval_ladder': Builder(builder: (c) {
        final p = P.of(c);
        final painter = IntervalLadder(const [
          (work: .9, rest: .4),
          (work: .85, rest: .45),
          (work: .8, rest: .5),
          (work: .72, rest: .6),
          (work: .64, rest: .7),
        ], p.on(C.orange), p.on(C.blue));
        return Surface(
          child: ChartFrame(
            title: 'Work and rest, round by round',
            unit: 'share of the hardest round',
            height: 110,
            legend: painter.legend,
            child: CustomPaint(size: Size.infinite, painter: painter),
          ),
        );
      }),
      'activity_pace_bar': Builder(
        builder: (c) => Surface(
          child: Column(children: [
            PaceBar(.78, P.of(c).on(C.domMove)),
            const SizedBox(height: S.x2),
            PaceBar(.21, P.of(c).on(C.domMove)),
          ]),
        ),
      ),
      // The finished-session stat block, in the three shapes it takes: a run
      // (pace and the common three), a lift (the longest list any archetype
      // prints, six rows deep), and a session that measured nothing but its
      // own length — which is what a first workout without a band looks like,
      // and is one row, not five rows of dashes.
      'session_stats': SessionStats(_sessions['route']!),
      'session_stats_strength': SessionStats(_sessions['strength']!),
      'session_stats_bare': SessionStats(ActivityResult(
        activityByName('Walking')!,
        start: DateTime(2026, 8, 16, 8, 0),
        duration: Motion.tick * 1500,
      )),
      // The same rows as a past session lists them, where absence is a word
      // rather than a missing line — see `_HistoryRow._stats`.
      'session_stats_history': Builder(
        builder: (c) => Surface(
          child: Column(children: [
            PosterStatRow(
                icon: statIcon('Time'),
                label: 'Time',
                value: '1:02:14',
                accent: P.of(c).on(C.domMove)),
            Divider(color: P.of(c).line, height: S.x5),
            PosterStatRow(
                icon: statIcon('Calories'),
                label: 'Calories',
                value: 'Not costed',
                accent: P.of(c).on(C.domMove)),
            Divider(color: P.of(c).line, height: S.x5),
            PosterStatRow(
                icon: statIcon('Max HR'),
                label: 'Max HR',
                value: 'No reading',
                accent: P.of(c).on(C.domMove)),
          ]),
        ),
      ),
      ..._liveCases(),
      ..._listCases(),
      ..._onboardingCases(),
      ..._stateCases(),
      ..._shareCases(),
      // No `mosaic`: a gallery that needs the network is a gallery that fails
      // on a plane. This is the card's honest no-basemap face, which is also
      // what a user with no signal gets.
      'poster': PosterCard(_finished),
      // A session that measured nothing but its own length: the grid prints
      // the one stat it has rather than a row of blanks.
      'poster_bare': PosterCard(_bare),
      // The poster's stat row on its own, on a normal card — it takes its ink
      // from the page when none is given, which is the whole reason it is not
      // a private widget inside poster.dart.
      'poster_stat_row': Surface(
        child: Column(children: [
          const PosterStatRow(
              icon: LucideIcons.gauge,
              label: 'Pace',
              value: '5:12',
              unit: '/km',
              accent: C.domMove),
          const SizedBox(height: S.x3),
          const PosterStatRow(
              icon: LucideIcons.flame,
              label: 'Calories',
              value: '2,310',
              unit: 'kcal',
              accent: C.orange),
          const SizedBox(height: S.x3),
          // No unit, and the longest duration anyone will post.
          const PosterStatRow(
              icon: LucideIcons.timer,
              label: 'Time',
              value: '10h 24m 18s',
              accent: C.domHealth),
        ]),
      ),

      // The rough-night card in all three states it can be in. Swept rather
      // than photographed because what can break here is length: four moved
      // measurements, four knowns and fourteen tag chips is the longest this
      // card ever gets, and it is the 3.1x sweep that catches it.
      //
      // Not photographed for a second reason. A PNG of a card offering
      // "alcohol" is a file in the repo that a reviewer meets out of context,
      // and the whole design of this card is that nobody meets that vocabulary
      // without asking for it.
      'rough_night_invite': const RoughNightCard(night: _roughFull),
      'rough_night_asking':
          const RoughNightCard(night: _roughBare, ask: 'on'),
      'rough_night_declined':
          const RoughNightCard(night: _roughTwoSign, ask: 'never'),
    };

/// The longest realistic night: every sign fired and every knowable known.
const _roughFull = RoughNight(
  day: '2026-08-15',
  signs: 4,
  illnessFlagged: true,
  descriptor: 'a rougher night than usual for you — your body worked harder '
      'overnight',
  moved: [
    'your resting heart rate ran higher',
    'your HRV ran lower',
    'your heart rate dropped less overnight than it usually does',
    'your skin ran warmer',
  ],
  knows: [
    'You trained until 9:40 PM, which often does this on its own.',
    'The illness watch flagged this night too — a sustained rise against your '
        'own baseline, not a diagnosis.',
    'You are in the luteal phase, which lifts resting heart rate and skin '
        'temperature by itself.',
    'Your skin ran warmer than your usual — a warm room does this too.',
  ],
);

/// The other end: the app knows nothing about why, so it states the night and
/// asks an open question. This is the common case.
const _roughBare = RoughNight(
  day: '2026-08-15',
  signs: 2,
  descriptor: 'a rougher night than usual for you — your body worked harder '
      'overnight',
  moved: ['your resting heart rate ran higher', 'your HRV ran lower'],
  knows: [],
);

/// Two signs, one knowable. The card's floor — below two signs there is no
/// card at all, which is why there is no "quiet" case here to shoot.
const _roughTwoSign = RoughNight(
  day: '2026-08-15',
  signs: 2,
  descriptor: 'a rougher night than usual for you — your body worked harder '
      'overnight',
  moved: [
    'your HRV ran lower',
    'your heart rate dropped less overnight than it usually does',
  ],
  knows: ['You trained until 10:15 PM, which often does this on its own.'],
);

/// The SECOND state of every card.
///
/// Each card above is shown once, holding a number. Every one of them also has
/// a state where the number is missing, negative, over target, or long — and
/// that is the state a screenshot never catches, because a demo device always
/// has data. A card is not in this design system until both of its faces are
/// in here.
Map<String, Widget> _stateCases() => {
      'signal_absent': const SignalCard(
          LucideIcons.wind, C.teal, 'Respiratory rate', '—',
          sub: 'BEAT TIMING WAS TOO NOISY LAST NIGHT'),
      'progress_over': const ProgressCard(
          'Protein', '164 g', 'of 140 g', 1.17, C.orange,
          icon: LucideIcons.beef),
      // Down AND bad, which is the pairing the colour logic gets wrong: a
      // falling number is not automatically a win.
      'trend_down_bad': TrendCard('Heart-rate variability', '48', 'ms', '−13',
          'vs 14-day baseline', _series, C.orange,
          good: false),
      // A gap in the middle of the series — the strap was off the wrist for
      // three days, and the line must BREAK rather than interpolate across it.
      'trend_with_gap': TrendCard(
          'Resting heart rate',
          '58',
          'bpm',
          '+4',
          'vs 14-day baseline',
          [for (var i = 0; i < 24; i++) i > 9 && i < 13 ? null : _series[i]],
          C.red,
          up: true,
          good: false),
      'insight_no_action': const InsightCard(
        'You went to bed at the same time four nights running',
        'That is the longest stretch since May, and your resting heart rate '
            'fell on three of them.',
      ),
      'status_title_only': const StatusCard('Location is off',
          '', fix: 'Allow location'),
      'deep_dive_no_preview': const DeepDiveCard(
          'Sleep debt', '2h 14m', 'owed', 'See the fortnight', C.indigo),
      'goal_trajectory_gaining': const GoalTrajectory(
          'Weight', '71.2 kg', '76 kg', '0.25 kg per week', .34, C.teal,
          rateDown: false),
      'observation_no_advice': const Observation(
        'Your skin temperature has been above baseline for three nights',
        '+0.6° against your own 28-night mean.',
      ),
      'consistency_none': const Consistency(
          0, 7, 'Nights with a full sleep record', C.domHealth),
      'consistency_full': const Consistency(
          7, 7, 'Nights with a full sleep record', C.domHealth),
      // Every accent, so a palette change is one picture rather than a hunt.
      'pill_every_colour': const Wrap(spacing: S.x2, runSpacing: S.x2, children: [
        Pill('Measured', C.green),
        Pill('Estimated', C.yellow, icon: LucideIcons.circleDashed),
        Pill('Relative', C.purple),
        Pill('Private', C.n500, icon: LucideIcons.lock),
        Pill('Beta', C.blue),
        Pill('Needs attention', C.orange),
        Pill('Not scored', C.red),
      ]),
      'big_button_no_icon': const BigButton('Save the night', color: C.domHealth),
      'sub_tabs_five': SubTabs(
          const ['Today', '7 days', '30 days', '6 months', 'Year'], 0, (_) {},
          color: C.domHealth),
      'nav_bar_no_sub': const NavBar('Component gallery'),
      // The oldest day on disk — back is dead, forward is live.
      'day_nav_oldest': DayNav(
          day: _navDays.last, days: _navDays, onDay: (_) {}),
      'section_no_action': const Section(
          'Recovery', StatusCard('Nothing yet today', '')),
      'inline_metrics_two': const InlineMetrics([
        ('VOLUME', '1,578 kg', C.purple),
        ('SETS', '4', C.n500),
      ]),
      'metric_row_absent': const MetricRow(
          LucideIcons.wind, C.teal, 'Respiratory rate', '—',
          sub: 'NEED 4 MORE NIGHTS'),
    };

/// The share card in every archetype it can be.
///
/// Eight archetypes on the one card. The picture no longer changes with the
/// sport — that was the textured card, and it is gone — but the STATS do, and
/// the grid has to hold all of them: a hike prints six, a lift prints five,
/// and the old four-row ceiling silently dropped whatever came after.
Map<String, Widget> _shareCases() => {
      for (final s in _sessions.entries) 'share_${s.key}': PosterCard(s.value),
    };

/// The fixture sessions, for a test that has to build one screen per
/// archetype. Public for the same reason [galleryCases] is: a test asserting
/// over its own copy of these would assert about a session the gallery does
/// not show.
List<ActivityResult> get gallerySessions => _sessions.values.toList();

/// Every activity the flow tab offers, flattened out of the catalogue groups.
List<Activity> get flowActivities =>
    [for (final g in activityLibrary) ...g.items];

/// One finished session per archetype, so the eight share cards and the eight
/// summaries have something real to draw. Deterministic throughout.
final _sessions = <String, ActivityResult>{
  'journey': _finished,
  'route': ActivityResult(
    activityByName('Running')!,
    start: DateTime(2026, 8, 12, 7, 5),
    duration: Motion.tick * 2712,
    avgHr: 156,
    maxHr: 181,
    // The drop in the minute after. Stored on every scored session and read by
    // nothing until now.
    hrr60: 27,
    calories: 604,
    hr: [for (var i = 0; i < 45; i++) 140 + (i * 23 % 37) * 1.0],
    zoneMinutes: const [2, 8, 19, 13, 3],
    route: _route,
    routePace: [for (var i = 0; i < _route.length; i++) (i % 20) / 20],
    distanceKm: 8.02,
  ),
  'strength': ActivityResult(
    activityByName('Weight training')!,
    start: DateTime(2026, 8, 11, 18, 40),
    duration: Motion.tick * 3320,
    avgHr: 112,
    calories: 388,
    strength: StrengthLog([
      for (var i = 0; i < 4; i++)
        LoggedSet('bench_press', 8 - i,
            loadKg: 70 + i * 5, at: DateTime(2026, 8, 11, 18, 45 + i * 4)),
      for (var i = 0; i < 3; i++)
        LoggedSet('barbell_row', 10,
            loadKg: 60, at: DateTime(2026, 8, 11, 19, 5 + i * 4)),
    ]),
  ),
  'laps': ActivityResult(
    activityByName('Swimming')!,
    start: DateTime(2026, 8, 10, 12, 15),
    duration: Motion.tick * 1980,
    avgHr: 134,
    calories: 421,
    distanceKm: 1.5,
    poolLengthM: 25,
    stroke: 'Freestyle',
    lapSecs: const [52, 54, 55, 53, 58, 61, 59, 57],
  ),
  'interval': ActivityResult(
    activityByName('Jump rope')!,
    start: DateTime(2026, 8, 9, 6, 30),
    duration: Motion.tick * 1140,
    avgHr: 158,
    maxHr: 186,
    calories: 302,
    rounds: const [
      IntervalRound(40, 20, avgHr: 148),
      IntervalRound(40, 20, avgHr: 159),
      IntervalRound(40, 25, avgHr: 166),
      IntervalRound(40, 30, avgHr: 171),
      IntervalRound(40, 35, avgHr: 174),
    ],
  ),
  'flow': ActivityResult(
    activityByName('Yoga') ?? activityByName('Stretching')!,
    start: DateTime(2026, 8, 8, 21, 10),
    duration: Motion.tick * 2400,
    avgHr: 72,
    calories: 118,
    breathsPerMin: 6.2,
    poses: const ['Down dog', 'Warrior II', 'Pigeon', 'Savasana'],
  ),
  'match': ActivityResult(
    activityByName('Tennis')!,
    start: DateTime(2026, 8, 7, 17, 0),
    duration: Motion.tick * 4560,
    avgHr: 141,
    maxHr: 179,
    calories: 712,
    hr: [for (var i = 0; i < 76; i++) 120 + (i * 31 % 51) * 1.0],
    zoneMinutes: const [8, 17, 24, 22, 5],
    gameScore: const [(6, 4), (3, 6), (7, 5)],
  ),
  'basic': ActivityResult(
    activityByName('Treadmill')!,
    start: DateTime(2026, 8, 6, 19, 30),
    duration: Motion.tick * 1800,
    avgHr: 147,
    maxHr: 168,
    calories: 356,
    hr: [for (var i = 0; i < 30; i++) 130 + (i * 17 % 33) * 1.0],
    zoneMinutes: const [1, 6, 14, 8, 1],
  ),
};

/// The live-session vocabulary. These are the pieces every `Live*` screen is
/// assembled from; the screens themselves are `Scaffold`s and belong on a
/// device, not in a scroll.
Map<String, Widget> _liveCases() => {
      'live_heart': const LiveHeart(LiveFeed(
          hr: 148,
          zone: 4,
          zoneMinutes: [6, 14, 22, 16, 4],
          bandConnected: true)),
      // The two absences say different things, and one card used to cover
      // both — it told a user whose band had dropped to adjust the fit of a
      // band that was not on their wrist.
      'live_heart_waiting':
          const LiveHeart(LiveFeed(bandConnected: true)),
      'live_heart_dropped': const LiveHeart(LiveFeed()),
      'live_big_num': Builder(
        builder: (c) => Surface(
          child: Column(children: [
            bigNum(P.of(c), '1:02:14', ''),
            const SizedBox(height: S.x4),
            bigNum(P.of(c), '12.42', 'km'),
          ]),
        ),
      ),
      'live_stat_row': Builder(
        builder: (c) => Surface(
          child: statRow(P.of(c), const [
            ('148', 'AVG HEART RATE'),
            ('812', 'CALORIES'),
            ('14.6', 'STRAIN'),
          ]),
        ),
      ),
      'live_counter_buttons': Builder(
        builder: (c) {
          final p = P.of(c);
          return Surface(
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              counterButton(p, LucideIcons.minus, p.on(C.red), 'One less rep',
                  () {}),
              const SizedBox(width: S.x5),
              counterButton(p, LucideIcons.plus, p.on(C.green), 'One more rep',
                  () {}),
            ]),
          );
        },
      ),
    };

/// Rows. Everything that lives in a list — settings, sources, activities,
/// workbench tables. Each is captured with the LONGEST value its slot can
/// hold: `SourceRow` shipped an overflow because every fixture said
/// "Connected", and nothing said "Syncing · 4 minutes ago".
Map<String, Widget> _listCases() => {
      'set_row': Builder(
        builder: (c) => settingsGroup(c, 'Settings row', [
          SetRow(LucideIcons.bell, C.purple, 'Manage notifications',
              sub: 'Bedtime, recovery, and the ones the band raises itself',
              onTap: () {}),
          SetRow(LucideIcons.ruler, C.blue, 'Units',
              value: 'Metric', onTap: () {}),
          const SetRow(LucideIcons.clock, C.n500, 'Last backup',
              value: '2026-08-16 04:12', chevron: false),
          SetRow(LucideIcons.trash2, C.red, 'Delete everything on this device',
              danger: true, onTap: () {}),
        ]),
      ),
      'source_row': Column(children: [
        SourceRow(
          HealthSource(
            name: 'Abdul’s WHOOP band',
            kind: 'WHOOP 4 · wrist optical',
            tier: SourceTier.wristOptical,
            icon: LucideIcons.watch,
            connected: true,
            syncing: true,
            batteryPct: 18,
            lastData: DateTime(2026, 8, 16, 4, 12),
            isBand: true,
          ),
          onTap: () {},
        ),
        const SizedBox(height: S.x3),
        const SourceRow(HealthSource(
          name: 'iPhone',
          kind: 'Motion coprocessor',
          tier: SourceTier.phone,
          icon: LucideIcons.smartphone,
        )),
      ]),
      'tier_row': const Column(children: [
        TierRow(SourceTier.wristOptical, filled: true),
        SizedBox(height: S.x3),
        TierRow(SourceTier.beatToBeat),
      ]),
      'activity_row': Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          const ActivityRow(
              Activity('Trail running', LucideIcons.mountain, C.green,
                  Track.distance, 10.5,
                  gps: true),
              weightKg: 78.4),
          // No weight on file: the row falls back to the MET value rather
          // than inventing a body to burn calories from.
          const ActivityRow(Activity('Weight training', LucideIcons.dumbbell,
              C.purple, Track.sets, 6.0)),
        ]),
      ),
      'legend': const Surface(
        child: Legend([
          ('Deep', C.indigo),
          ('REM', C.purple),
          ('Light', C.blue),
          ('Awake', C.orange),
        ]),
      ),
      'mono_table': const MonoTable('What went into this number', [
        ('rmssd_ms', '61.4'),
        ('baseline_mean_ms', '67.2'),
        ('nights_in_baseline', '14'),
        ('artifact_share', '2.1%'),
      ]),
      'investigate_row': Builder(builder: (c) => investigateRow(c, () {})),
      'no_data': const Surface(
          child: NoData(message: 'No nights recorded this week')),
      'moment_row': Builder(
        builder: (c) => Surface(
          child: Column(children: [
            // The longest realistic line, and the muted one: a fact about the
            // band rather than about the person takes no domain colour.
            for (final m in dayMoments(timeline: _tlJoin).take(2)) MomentRow(m),
            MomentRow(Moment(
                at: _tlAt(20, 2),
                title: 'Band off your wrist',
                detail: '8:02 PM – 8:58 PM · 56m',
                icon: LucideIcons.watch)),
          ]),
        ),
      ),
      'sweep_finding_row': Surface(
        child: Column(
            children: [for (final f in _wcFindings) SweepFindingRow(f)]),
      ),
      ..._dayTimelineCases(),
      ..._monthGridCases(),
      ..._whatChangedCases(),
    };

// ── the day, in order ─────────────────────────────────────────────────────
//
// Built through the real `dayMoments` join rather than from hand-made rows:
// the ordering, the off-wrist floor and the "this has no clock, so it is not
// on the clock" split are the parts worth having a case for, and a list of
// pre-sorted fixtures would exercise none of them.

/// Local midnight of a fixed day, so the fixture reads the same every run.
final int _tlDay =
    DateTime(2026, 8, 14).millisecondsSinceEpoch ~/ 1000;
int _tlAt(int h, [int m = 0]) => _tlDay + h * 3600 + m * 60;

Map<String, dynamic> get _tlJoin => {
      'day_start': _tlDay,
      'sleep': [
        {'onset_ts': _tlDay - 3600, 'wake_ts': _tlAt(6, 42)},
      ],
      'naps': [
        {'start': _tlAt(14, 10), 'end': _tlAt(14, 48), 'duration_min': 38},
      ],
      'sessions': [
        {
          'start_ts': _tlAt(18, 5),
          'end_ts': _tlAt(19, 20),
          'type': 'football',
          'duration_min': 75,
          'avg_hr': 141,
        },
      ],
      'events': [
        // Delivered twice, which the strap really does — the row must appear
        // once.
        {'event_id': 7, 'ts': _tlAt(20, 5)},
        {'event_id': 7, 'ts': _tlAt(20, 5)},
        {'event_id': 8, 'ts': _tlAt(20, 55)},
      ],
      'highs': {
        'peak_hr': {'v': 176, 't': _tlAt(18, 51)},
        'low_hr': {'v': 44, 't': _tlAt(4, 12)},
      },
    };

TimelineData get _tlFull => TimelineData(
      day: '2026-08-14',
      days: const ['2026-08-15', '2026-08-14', '2026-08-13'],
      moments: dayMoments(
        timeline: _tlJoin,
        wear: {
          'segments': [
            {'on': false, 'start': _tlAt(20, 2), 'end': _tlAt(20, 58), 'len_min': 56},
            // Under the floor: a three-minute dropout is not an event in a day.
            {'on': false, 'start': _tlAt(11, 0), 'end': _tlAt(11, 3), 'len_min': 3},
          ],
        },
        meals: [
          FoodEntry(
            id: 'm1',
            date: '2026-08-14',
            meal: 'Breakfast',
            label: 'Porridge with blueberries and honey',
            atTs: _tlAt(8, 20),
            kcal: 412,
          ),
          // No time on it: it belongs under the axis, not on it.
          const FoodEntry(
              id: 'm2', date: '2026-08-14', meal: 'Snack', label: 'Flapjack'),
        ],
        doses: [(label: 'Vitamin D 1000 IU', at: _tlAt(8, 32))],
        journal: const {
          'caffeine': JournalMetricValue(3, atMinuteOfDay: 16 * 60 + 40),
          'alcohol': JournalMetricValue(2),
        },
        fields: kJournalFields,
      ),
      notes: dayNotes(
        meals: [
          const FoodEntry(
              id: 'm2', date: '2026-08-14', meal: 'Snack', label: 'Flapjack'),
        ],
        journal: const {'alcohol': JournalMetricValue(2)},
        fields: kJournalFields,
        journalRows: const [
          {
            'date': '2026-08-14',
            'tags_json': '["late meal","travel"]',
            'note': 'Long drive back, ate at the services around eleven.',
          },
        ],
      ),
    );

Map<String, Widget> _dayTimelineCases() => {
      'timeline_day': Builder(
          builder: (c) =>
              Column(children: timelineBody(c, _tlFull))),
      // The common day on a new strap, and the one this page must not dress
      // up: nothing was recorded, and the reason is usually the wrist.
      'timeline_empty': Builder(
          builder: (c) =>
              Column(children: timelineBody(c, const TimelineData(day: '2026-08-14')))),
      // Logged, but nothing carrying a time. The axis is empty and the block
      // underneath is not — which is the distinction the whole file is built on.
      'timeline_untimed_only': Builder(
        builder: (c) => Column(
          children: timelineBody(
            c,
            TimelineData(
              day: '2026-08-14',
              notes: dayNotes(
                journal: const {'alcohol': JournalMetricValue(2)},
                fields: kJournalFields,
                journalRows: const [
                  {'date': '2026-08-14', 'tags_json': '["travel"]', 'note': ''},
                ],
              ),
            ),
          ),
        ),
      ),
    };

// ── the month, as three strips ────────────────────────────────────────────

final DateTime _now = DateTime.now();

/// A month of a metric: enough history to shade against, and four days
/// missing, so both cell states are in every picture.
List<ChartPoint> _gridPoints(double base, double spread, {int days = 60}) => [
      for (var i = days - 1; i >= 0; i--)
        if (i % 9 != 3)
          (
            // `DateTime(y, m, d - i)` rather than a `Duration`: durations in
            // lib/ui2 are motion, and the token test enforces it.
            t: DateTime(_now.year, _now.month, _now.day - i)
                    .millisecondsSinceEpoch ~/
                1000,
            v: base + (i * 37 % 23) / 23 * spread,
          ),
    ];

Map<String, Widget> _monthGridCases() => {
      'month_grid': MonthGrid([
        gridRow('sleep', _gridPoints(360, 140)),
        gridRow('readiness', _gridPoints(38, 55)),
        gridRow('strain', _gridPoints(4, 12)),
      ]),
      // A fortnight in. One metric has a range to place a day inside and two
      // do not, and the two that do not say so in words rather than in a
      // paler version of the same claim.
      'month_grid_calibrating': MonthGrid([
        gridRow('sleep', _gridPoints(360, 140, days: 20)),
        gridRow('readiness', _gridPoints(38, 55, days: 6)),
        gridRow('strain', _gridPoints(4, 12, days: 2)),
      ]),
    };

// ── what changed ──────────────────────────────────────────────────────────

const _wcFindings = [
  SweepFinding(
      key: 'rhr',
      text: 'resting heart rate 68 bpm — the highest in 45 days '
          '(usually 53–55 bpm)',
      z: 3.4,
      high: true),
  SweepFinding(
      key: 'rmssd',
      text: 'HVR 32 ms — below your usual range (usually 41–58 ms)',
      z: -2.7,
      high: false),
];

Map<String, Widget> _whatChangedCases() => {
      'what_changed': Builder(
        builder: (c) => Column(
          children: whatChangedBody(
            c,
            WhatChangedData(
              day: '2026-08-14',
              findings: _wcFindings,
              longestHistory: 45,
              hadToday: true,
              grid: [gridRow('readiness', _gridPoints(38, 55))],
            ),
          ),
        ),
      ),
      // The normal night, and the one the screen is most likely to get wrong
      // by padding it out with numbers to look like more.
      'what_changed_quiet': Builder(
        builder: (c) => Column(
          children: whatChangedBody(
            c,
            const WhatChangedData(
                day: '2026-08-14', longestHistory: 45, hadToday: true),
          ),
        ),
      ),
      'what_changed_calibrating': Builder(
        builder: (c) => Column(
          children: whatChangedBody(
            c,
            const WhatChangedData(
                day: '2026-08-14', longestHistory: 6, hadToday: true),
          ),
        ),
      ),
    };

/// Onboarding and import — the two flows a user sees exactly once, which is
/// why they are the two nobody re-checks after a change.
Map<String, Widget> _onboardingCases() => {
      'import_report': const ImportReport(ImportOutcome(
          source: 'WHOOP export', days: 412, lateRows: 38, strandedDays: 2)),
      'import_report_failed': const ImportReport(ImportOutcome(
          source: 'physiological_cycles.csv',
          error: 'The first row named columns this importer does not know, so '
              'nothing in the file could be placed.')),
    };

/// A REAL run, on a real park loop, so the poster can be seen doing the one
/// thing the offline case cannot show: sitting on actual streets.
///
/// Deliberately not in [galleryCases]. Every case in that map is shot by the
/// goldens and swept for overflow at five text scales, and a case that reaches
/// the network would make both of those a function of the wifi. This is
/// screen-only, opt-in, and fetches nothing until it is on screen.
final _demoRun = ActivityResult(
  activityByName('Running')!,
  start: DateTime(2026, 8, 16, 6, 40),
  duration: Motion.tick * 920,
  avgHr: 152,
  maxHr: 171,
  calories: 214,
  strain: 8.4,
  distanceKm: 3.07,
  hr: [for (var i = 0; i < 15; i++) 138 + (i * 23 % 29) * 1.0],
  zoneMinutes: const [1, 3, 6, 4, 1],
  geo: _demoLoop,
  route: _normalisedDemoLoop,
  routePace: [for (var i = 0; i < _demoLoop.length; i++) (i * 7 % 20) / 20],
);

/// A lap of Cubbon Park, Bengaluru — about 3.07 km. Real coordinates, because
/// the whole point is that the tiles underneath are a real place.
const _demoLoop = <(double, double)>[
  (12.9763, 77.597333),
  (12.977093, 77.597514),
  (12.977862, 77.597305),
  (12.978521, 77.596848),
  (12.979079, 77.596298),
  (12.979556, 77.595704),
  (12.979903, 77.595035),
  (12.980017, 77.594288),
  (12.979867, 77.593545),
  (12.97958, 77.5929),
  (12.979384, 77.592342),
  (12.979424, 77.591733),
  (12.979626, 77.59093),
  (12.979724, 77.589952),
  (12.979465, 77.589029),
  (12.978799, 77.588459),
  (12.9779, 77.588388),
  (12.977021, 77.588702),
  (12.9763, 77.589124),
  (12.975704, 77.589429),
  (12.975126, 77.58959),
  (12.974521, 77.589739),
  (12.973936, 77.590009),
  (12.973428, 77.590427),
  (12.972974, 77.59093),
  (12.972499, 77.59148),
  (12.971988, 77.59212),
  (12.97158, 77.5929),
  (12.971505, 77.593768),
  (12.971907, 77.594541),
  (12.972697, 77.595035),
  (12.973595, 77.595229),
  (12.974323, 77.595318),
  (12.974799, 77.595569),
  (12.975164, 77.596102),
  (12.975632, 77.596787),
  (12.9763, 77.597333),
];

/// The same loop in the 0…1 box, so the no-map fallback draws the same shape.
final _normalisedDemoLoop = () {
  var loLat = _demoLoop.first.$1, hiLat = loLat;
  var loLng = _demoLoop.first.$2, hiLng = loLng;
  for (final (lat, lng) in _demoLoop) {
    loLat = min(loLat, lat);
    hiLat = max(hiLat, lat);
    loLng = min(loLng, lng);
    hiLng = max(hiLng, lng);
  }
  final k = cos((loLat + hiLat) / 2 * pi / 180).abs();
  final w = (hiLng - loLng) * k, h = hiLat - loLat;
  final span = max(w, h);
  final dx = (1 - w / span) / 2, dy = (1 - h / span) / 2;
  return [
    for (final (lat, lng) in _demoLoop)
      Offset(dx + (lng - loLng) * k / span, dy + (hiLat - lat) / span),
  ];
}();

/// The poster with a live basemap, and a photo slot.
///
/// Everything else in the gallery is a pure function of its fixtures. This one
/// is not — it fetches tiles and it reads a file the user picks — which is
/// exactly why it lives at the bottom of the screen, behind its own button,
/// and not in the map the goldens shoot.
class _PosterPreview extends StatefulWidget {
  const _PosterPreview();

  @override
  State<_PosterPreview> createState() => _PosterPreviewState();
}

class _PosterPreviewState extends State<_PosterPreview> {
  RouteMosaic? _mosaic;
  File? _photo;
  bool _loading = false;
  bool _tried = false;

  /// The card, as pixels. This is the only place in the app a share can be
  /// exercised without a recorded session, so it captures the SAME way the
  /// share sheet does — boundary, 3×, `shareXFiles` with an anchor.
  final _card = GlobalKey();
  bool _sharing = false;

  @override
  void dispose() {
    _mosaic?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _tried = true;
    });
    // The card's own map styling, not the reader's palette — the same two
    // tokens the real share sheet passes, so this preview cannot show a map
    // the shipped card would never draw.
    final m = await buildRouteMosaic(
      _demoLoop,
      width: kPosterMapW.round() * 3,
      height: kPosterMapH(PosterFormat.post).round() * 3,
      bg: C.mapFloor,
      ink: C.mapCeil,
    );
    if (!mounted) {
      m?.dispose();
      return;
    }
    setState(() {
      _mosaic?.dispose();
      _mosaic = m;
      _loading = false;
    });
  }

  Future<void> _pick() async {
    try {
      final picked = await FilePicker.platform
          .pickFiles(type: FileType.image, allowMultiple: false);
      final path = picked?.files.single.path;
      if (path != null && mounted) setState(() => _photo = File(path));
    } catch (_) {/* cancelled, or no picker — neither is an error */}
  }

  /// Share the card that is on screen, rather than re-drawing a second,
  /// slightly different one. The anchor is `shareOrigin` from share.dart and
  /// not a rect invented here: `UIActivityViewController` is a popover on iPad
  /// and `share_plus` throws rather than guessing without one.
  Future<void> _share() async {
    if (_sharing) return;
    _sharing = true;
    final origin = shareOrigin(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary =
          _card.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return;
      await Share.shareXFiles(
        [
          XFile.fromData(png.buffer.asUint8List(),
              mimeType: 'image/png', name: 'poster.png'),
        ],
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not open the share sheet.')));
      debugPrint('gallery share failed: $e');
    } finally {
      _sharing = false;
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('poster · live', style: F.over.copyWith(color: p.ink3)),
      const SizedBox(height: S.x2),
      Center(
        child: RepaintBoundary(
          key: _card,
          child: PosterCard(
            _demoRun,
            photo: _photo == null ? null : FileImage(_photo!),
            mosaic: _mosaic,
          ),
        ),
      ),
      const SizedBox(height: S.x3),
      Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          SetRow(LucideIcons.map, C.green,
              _mosaic == null ? 'Load the map' : 'Reload the map',
              sub: 'A real lap of Cubbon Park — fetches OpenStreetMap tiles',
              value: _loading ? 'Loading' : '',
              onTap: _loading ? null : _load),
          Divider(color: p.line, height: 1),
          SetRow(LucideIcons.imagePlus, C.purple,
              _photo == null ? 'Add a photo' : 'Change photo',
              sub: 'From this phone. Nothing is uploaded', onTap: _pick),
          if (_photo != null) ...[
            Divider(color: p.line, height: 1),
            SetRow(LucideIcons.trash2, C.red, 'Remove the photo',
                chevron: false, onTap: () => setState(() => _photo = null)),
          ],
          Divider(color: p.line, height: 1),
          SetRow(LucideIcons.share2, C.blue, 'Share this card',
              sub: 'The real export — the boundary above, at 3×',
              chevron: false, onTap: _share),
        ]),
      ),
      if (_tried && !_loading && _mosaic == null) ...[
        const SizedBox(height: S.x3),
        const StatusCard(
          'No map came back',
          'The tiles could not be fetched, so the route is drawn on its own — '
              'which is exactly what the card does on a phone with no signal.',
          icon: LucideIcons.mapPinOff,
        ),
      ],
    ]);
  }
}

// ══════════════════ THE SCREEN ══════════════════

// ══════════════════ the activity flows ══════════════════
//
// Every activity in the catalogue, walkable end to end. A component scroll
// shows the pieces; it cannot show the ORDER — which screen follows which,
// what the hero says at each step, which tabs an archetype gets — and the
// order is what a person opening this is checking.
//
// The eight hand-written sessions above are richer than anything synthesised
// (a real loop, a heart-rate dropout, a named top set), so an activity that
// has one uses it. The other sixty-three are built from the catalogue entry
// itself — see [_placeholder].

/// A deterministic 0…1 from a name and a salt.
///
/// FNV-1a rather than `name.hashCode`: Dart's string hash is stable within a
/// run and NOT across them, which is the one property a fixture must not have
/// — a gallery that reshuffles between launches is a gallery you cannot
/// compare two screenshots of, and a golden that fails on a Tuesday.
double _n(String name, int salt) {
  var h = 2166136261 ^ salt;
  for (final u in name.codeUnits) {
    h = ((h ^ u) * 16777619) & 0xFFFFFFFF;
  }
  return (h % 1000) / 1000;
}

/// The body weight the placeholder calories are costed at.
///
/// A real screen has no default weight — [Activity.kcal] returns null without
/// one, and that is the whole point of it. This is a FIXTURE constant, named
/// so that it cannot be mistaken for one: it exists so the calorie row has
/// something to draw, and it never leaves this file.
const _fixtureWeightKg = 72.0;

/// A finished session for [a], invented from its own catalogue entry.
///
/// Every number is derived from the activity's MET, track and name, so a
/// 1.3-MET meditation and a 23-MET sprint cannot end up sharing a heart-rate
/// curve — which is what a single shared fixture would have done, and is
/// exactly the class of bug the gallery exists to catch. The one activity
/// with NO MET falls back to a preview-only 5.0 for the shape, and keeps its
/// real null calories — see below.
///
/// This is a PREVIEW, not a measurement, and nothing outside the gallery may
/// read it. What it is faithful about is SHAPE: which fields an archetype
/// fills and which it leaves null, so the screen has to handle the same
/// absences here that it handles on a device.
ActivityResult _placeholder(Activity a) {
  final arch = archOf(a);
  final mins = 18 + (_n(a.name, 1) * 57).round();
  // The catch-all activity has no MET (it names no activity), and a fixture
  // still has to draw a heart rate and a zone spread. 5.0 is invented HERE,
  // in the preview, where inventing is the whole job — `calories` below stays
  // `a.kcal(...)` and so previews the absent figure the real screen shows.
  final met = a.met ?? 5.0;
  final avg = (58 + met * 7).clamp(50, 172).round();
  final peak = (avg + 9 + _n(a.name, 3) * 24).clamp(avg + 4, 198).round();

  // One slot per minute, and a dropout in roughly a quarter of them, because
  // a preview where the band never misses a beat is a preview that never
  // shows the hole the chart is supposed to draw.
  final drop = _n(a.name, 9) < .25;
  final hr = [
    for (var i = 0; i < mins; i++)
      drop && i > mins ~/ 3 && i < mins ~/ 3 + 4
          ? null
          : avg - 8 + (i * 13 % 21) * 1.0,
  ];

  // Mass moves up the zones with the MET. Meditation sits in Z1; a sprint
  // session spends its minutes at the top.
  final hard = (met / 23).clamp(0.0, 1.0);
  final w = [1.6 - hard, 1.4 - hard * .5, .9 + hard, .4 + hard * 1.4, .1 + hard];
  final sum = w.reduce((x, y) => x + y);
  final zones = [for (final x in w) (mins * x / sum)];

  // Fixed, never `DateTime.now()`. Spread over the preceding fortnight so a
  // list of them does not read as one impossible afternoon.
  final start = DateTime(2026, 8, 14, 6, 0)
      .subtract(Motion.tick * ((_n(a.name, 4) * 1209600).round()));

  // Speed from the MET, which is the only thing the catalogue knows about how
  // fast this activity moves. Good enough for a picture, and wrong enough
  // that nobody could mistake it for a recording.
  final km = double.parse((met * 1.02 * mins / 60).toStringAsFixed(2));
  final paceSec = (mins * 60 / km).round();
  final onRoute = arch == Arch.route || arch == Arch.journey;
  // Laps are TAPPED, never measured — so the lap times are the invention here
  // and the swim distance falls out of them, not the other way round.
  final laps = arch == Arch.laps ? 8 + (_n(a.name, 7) * 22).round() : 0;

  // One constructor, not a chain of `copyWith`: the record's own `copyWith`
  // deliberately carries the archetype fields through rather than taking
  // them, because on a device nothing may swap a session's laps for its
  // rounds. A fixture is not the reason to widen it.
  return ActivityResult(
    a,
    start: start,
    duration: Motion.tick * (mins * 60),
    private: a.private,
    avgHr: avg,
    maxHr: peak,
    calories: a.kcal(_fixtureWeightKg, mins),
    strain:
        double.parse((met * mins / 60 * 1.15).clamp(0, 21).toStringAsFixed(1)),
    hr: hr,
    zoneMinutes: zones,
    // Only a GPS activity gets a line. An indoor row or a treadmill leaves
    // this empty and the screen says so — which is the state worth previewing.
    route: onRoute && a.gps ? _route : const [],
    routePace: onRoute && a.gps
        ? [for (var i = 0; i < _route.length; i++) (i % 20) / 20]
        : null,
    distanceKm: switch (arch) {
      Arch.route || Arch.journey => a.gps ? km : null,
      Arch.laps => laps * 25 / 1000,
      _ => null,
    },
    splits: onRoute && a.gps
        ? [
            for (var i = 1; i <= km.floor(); i++)
              KmSplit(i.toDouble(), paceSec + (i * 7 % 19) - 9,
                  avgHr: avg + (i * 5 % 11) - 5),
          ]
        : const [],
    elevationM: arch == Arch.journey ? _metres : const [],
    gainM: arch == Arch.journey
        ? 120 + (_n(a.name, 5) * 620).roundToDouble()
        : null,
    lossM: arch == Arch.journey
        ? 110 + (_n(a.name, 6) * 600).roundToDouble()
        : null,
    // Two lifts, one loaded and one not: the unloaded-set caveat is a real
    // state of this screen, and a preview that never enters it is a preview
    // of half the screen.
    strength: arch == Arch.strength
        ? StrengthLog([
            for (var i = 0; i < 4; i++)
              LoggedSet(exerciseLibrary[0].key, 10 - i,
                  loadKg: 55 + i * 5 + (_n(a.name, 8) * 20).roundToDouble(),
                  at: start.add(Motion.tick * (240 * i))),
            for (var i = 0; i < 3; i++)
              LoggedSet(exerciseLibrary[8].key, 8,
                  at: start.add(Motion.tick * (1400 + 200 * i))),
          ])
        : StrengthLog.empty,
    lapSecs: [for (var i = 0; i < laps; i++) 48 + (i * 9 % 17)],
    poolLengthM: arch == Arch.laps ? 25 : null,
    stroke: arch == Arch.laps ? 'Freestyle' : null,
    rounds: arch == Arch.interval
        ? [
            for (var i = 0; i < 5 + (_n(a.name, 2) * 7).round(); i++)
              IntervalRound(30 + (i * 7 % 25), 15 + (i * 5 % 20),
                  avgHr: avg + i * 3),
          ]
        : const [],
    poses: arch == Arch.flow
        ? _poses.take(3 + (_n(a.name, 3) * 4).round()).toList()
        : const [],
    breathsPerMin: arch == Arch.flow
        ? double.parse((5 + _n(a.name, 4) * 6).toStringAsFixed(1))
        : null,
    gameScore: arch == Arch.match
        ? [
            for (var i = 0; i < 2 + (_n(a.name, 5) * 2).round(); i++)
              (6, 2 + (i * 3 % 5)),
          ]
        : const [],
  );
}

const _poses = [
  'Down dog', 'Warrior II', 'Pigeon', 'Child\'s pose', 'Bridge',
  'Triangle', 'Savasana',
];

/// The fixture behind an activity's flow: the hand-written session if it has
/// one, the synthesised one otherwise.
///
/// A GPS activity is then given REAL coordinates. This is not decoration: the
/// share sheet offers the Poster style only when `geo.length >= 2`, and the
/// Poster is what carries the OpenStreetMap basemap and the photo picker. A
/// flow built on the normalised 0…1 path alone silently hid both — the map,
/// the tile fetch, the attribution, the offline `StatusCard` and the whole
/// photo slot were unreachable from every one of these screens.
ActivityResult flowFixture(Activity a) {
  final base = _sessions.values
          .where((s) => s.activity.name == a.name)
          .firstOrNull ??
      _placeholder(a);
  if (!a.gps || base.geo.isNotEmpty) return base;
  return base.copyWith(
    geo: _demoLoop,
    // The SAME loop in both spaces, or the painters and the basemap draw two
    // different runs — the normalised path is what the no-map fallback uses.
    route: _normalisedDemoLoop,
    routePace: [
      for (var i = 0; i < _normalisedDemoLoop.length; i++) (i % 20) / 20,
    ],
  );
}

/// Every activity in the catalogue, grouped as the picker groups them. Tapping
/// one opens its flow.
class _Flows extends StatelessWidget {
  const _Flows();

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return ListView(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x10),
      children: [
        for (final g in activityLibrary) ...[
          Text('${g.name.toUpperCase()} · ${g.items.length}',
              style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: S.x2),
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Column(children: [
              for (final (i, a) in g.items.indexed) ...[
                SetRow(a.icon, a.color, a.name,
                    sub: archLabel(archOf(a)),
                    onTap: () => Navigator.of(c).push(MaterialPageRoute<void>(
                        builder: (_) => _FlowScreen(a)))),
                if (i < g.items.length - 1)
                  Divider(color: p.line, height: 1),
              ],
            ]),
          ),
          const SizedBox(height: S.x6),
        ],
      ],
    );
  }
}

/// One activity's flow, in the order the app walks it.
///
/// Every row pushes the REAL screen — the same `ActivityPicker`,
/// `ActivitySetup`, `liveFor`, `ActivitySummary` and `ShareSheet` the app
/// routes to — over [ActivityHost.none]. Nothing is persisted and nothing
/// reads the database, which is the only reason a gallery can push them.
class _FlowScreen extends StatelessWidget {
  final Activity a;
  const _FlowScreen(this.a);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final r = flowFixture(a);
    final synthetic = !_sessions.values.any((s) => s.activity.name == a.name);
    // Live really runs: it starts its 1 Hz tick with no feed behind it, so the
    // clock moves and the heart rate does not. Finishing it pops to the app
    // root the same way the real one does — the Summary row below is the way
    // to see the end of a session without leaving.
    final stages = <(String, IconData, String, Widget)>[
      ('Pick', LucideIcons.listChecks, 'The catalogue, as the app opens it',
          const ActivityPicker()),
      ('Set up', LucideIcons.sliders, 'Goal, target and privacy',
          ActivitySetup(a)),
      ('Live', LucideIcons.circleDot, 'Runs for real, with no band behind it',
          liveFor(a)),
      ('Summary', LucideIcons.flag, 'What this session becomes',
          ActivitySummary(r, weightKg: _fixtureWeightKg)),
      ('Share', LucideIcons.share2, 'Styles, stat chips and the card',
          ShareSheet(r)),
    ];
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(a.name,
                sub: a.met == null
                    ? archLabel(r.arch).toUpperCase()
                    : '${archLabel(r.arch).toUpperCase()} · '
                        '${a.met!.toStringAsFixed(1)} MET'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Surface(
                  pad: const EdgeInsets.symmetric(horizontal: S.x4),
                  child: Column(children: [
                    for (final (i, s) in stages.indexed) ...[
                      SetRow(s.$2, a.color, s.$1,
                          sub: s.$3,
                          onTap: () => Navigator.of(c).push(
                              MaterialPageRoute<void>(builder: (_) => s.$4))),
                      if (i < stages.length - 1)
                        Divider(color: p.line, height: 1),
                    ],
                  ]),
                ),
                const SizedBox(height: S.x4),
                if (synthetic)
                  const StatusCard(
                    'These numbers are invented',
                    'Derived from this activity\'s MET and name so the '
                        'screens have something to draw — or from a '
                        'preview-only stand-in, where the activity has no '
                        'MET. The SHAPE is real: the fields this archetype '
                        'fills, and the ones it leaves empty.',
                    icon: LucideIcons.flaskConical,
                  )
                else
                  const StatusCard(
                    'A hand-written fixture',
                    'This one carries a real loop, a heart-rate dropout and a '
                        'named top set — the awkward cases the goldens shoot.',
                    icon: LucideIcons.pin,
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// The whole design system on one scroll, at a scale and a theme you choose.
///
/// The two controls are the point. 2.0× and 3.1× are what iOS hands an app
/// whose owner turned on Larger Accessibility Sizes, and the dark palette is
/// solved separately from the light one — both are places a component can be
/// wrong while looking perfect on the machine it was written on.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  static const _scales = [1.0, 1.4, 2.0, 3.1];

  int _scale = 0;
  int _theme = 0;

  /// Flows first. The component scroll is what the goldens shoot; the flow is
  /// what a person opens the gallery to walk.
  int _mode = 0;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final cases = galleryCases();
    final flows = _mode == 0;
    // Named, NOT `Brightness.values[_theme - 1]`. Flutter declares the enum
    // as `{ dark, light }` — dark first — so indexing it against a
    // ['System', 'Light', 'Dark'] tab list handed 'Light' the dark theme and
    // 'Dark' the light one. Both tabs worked, both showed the wrong palette,
    // and the whole point of this screen is that dark is solved separately
    // from light: every review done through it was reviewing the other one.
    final brightness = switch (_theme) {
      1 => Brightness.light,
      2 => Brightness.dark,
      _ => Theme.of(c).brightness,
    };
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            // The title is the label on the Settings row that opens it. A
            // screen whose name changes with its tab is a screen nobody can
            // be told to go to.
            child: NavBar('Component gallery',
                sub: flows
                    ? '${flowActivities.length} ACTIVITY FLOWS'
                    : '${cases.length} COMPONENTS'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x3),
            child: Column(children: [
              SubTabs(const ['Flows', 'Components'], _mode,
                  (i) => setState(() => _mode = i),
                  color: C.domMove),
              const SizedBox(height: S.x2),
              SubTabs(const ['1.0×', '1.4×', '2.0×', '3.1×'], _scale,
                  (i) => setState(() => _scale = i),
                  color: C.domHealth),
              const SizedBox(height: S.x2),
              SubTabs(const ['System', 'Light', 'Dark'], _theme,
                  (i) => setState(() => _theme = i),
                  color: C.domHealth),
            ]),
          ),
          // The controls stay at the app's own scale and theme; only what is
          // under test is overridden, or a 3.1× stepper would push itself off
          // the screen it exists to control.
          Expanded(
            child: Theme(
              data: buildTheme(brightness),
              child: Builder(builder: (c) {
                final gp = P.of(c);
                return MediaQuery(
                  data: MediaQuery.of(c)
                      .copyWith(textScaler: TextScaler.linear(_scales[_scale])),
                  child: ColoredBox(
                    color: gp.bg,
                    child: flows
                        ? const _Flows()
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(
                                S.x4, S.x4, S.x4, S.x10),
                            children: [
                              // FIRST, not last. It is the only case that
                              // touches the network or the filesystem, and it
                              // is also the one worth opening the gallery for
                              // — burying it under ninety other cases at 3.1x
                              // text would make it unreachable in practice.
                              const _PosterPreview(),
                              const SizedBox(height: S.x6),
                              for (final e in cases.entries) ...[
                                Text(e.key,
                                    style: F.over.copyWith(color: gp.ink3)),
                                const SizedBox(height: S.x2),
                                e.value,
                                const SizedBox(height: S.x6),
                              ],
                            ],
                          ),
                  ),
                );
              }),
            ),
          ),
        ]),
      ),
    );
  }
}
