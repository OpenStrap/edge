// The shared metric drill-down — density 2 of 3.
//
// Glance (a row on Health) → MetricDetail (your normal range, what moves it,
// how this week compares) → Nerd stats (everything, in mono). There is no
// "advanced mode" switch: depth is a place you walk to, not a preference you
// set, so the same person gets the shallow read on Monday and the deep one
// when something looks wrong.
//
// Every metric goes through THIS screen. Forty bespoke detail screens is how
// the old UI ended up with forty different opinions about what a chart is.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'beats.dart';
import 'day_steps.dart';
import 'home_screen.dart';
import 'investigate.dart';
import 'journal_compose.dart' show OsTextField;
import 'sleep_detail.dart';

// ═══════════════════ the vocabulary ═══════════════════

/// What a metric key means on screen, and whether we are willing to draw it.
class MetricSpec {
  /// The alias `getChart` / `getTrend` understand (`_trendKey` maps it on).
  final String chartKey;
  final String title;
  final String unit;
  final Color color;
  final IconData icon;
  final bool higherBetter;

  /// Non-null when this metric must NOT be charted. The string is the honest
  /// reason, shown as a `StatusCard` in place of the chart.
  final String? suppress;
  final String? suppressFix;

  /// How it is computed, and who published the method. Rendered by Nerd stats.
  final String method;
  final String citation;

  const MetricSpec({
    required this.chartKey,
    required this.title,
    this.unit = '',
    this.color = C.blue,
    this.icon = LucideIcons.activity,
    this.higherBetter = true,
    this.suppress,
    this.suppressFix,
    this.method = '',
    this.citation = '',
  });
}

const _specs = <String, MetricSpec>{
  'resting_hr': MetricSpec(
    chartKey: 'resting_hr',
    title: 'Resting heart rate',
    unit: 'bpm',
    color: C.red,
    icon: LucideIcons.heart,
    higherBetter: false,
    method: 'The lowest sustained sleeping heart rate of the night, taken over '
        'a rolling window of the overnight series. Not a spot reading, and not '
        'a daytime minimum.',
    citation: 'Nocturnal heart-rate minimum; personal baseline, not population',
  ),
  'hrv': MetricSpec(
    chartKey: 'hrv',
    title: 'HRV',
    unit: 'ms',
    color: C.green,
    icon: LucideIcons.activity,
    method: 'RMSSD over the longest artefact-free window during sleep. Beat '
        'timing is recovered from the band\'s 1 Hz records and corrected by '
        'the Lipponen–Tarvainen method before any statistic is taken. '
        'Pulse-derived, so this is PRV: real and trendable, but not ECG HRV.',
    citation: 'Task Force 1996 · Lipponen & Tarvainen 2019',
  ),
  'readiness': MetricSpec(
    chartKey: 'recovery',
    title: 'Readiness',
    color: C.green,
    icon: LucideIcons.batteryCharging,
    // The weights are DATA — `readiness_glassbox` emits one per input and the
    // Readiness screen renders them. Repeating them as prose here meant two
    // surfaces could disagree about the same composite, silently, forever.
    method: 'A weighted composite of a handful of inputs, each scored against '
        'your own history. Every input\'s weight, and whether last night had '
        'enough history to use it, is listed on the Readiness screen. Missing '
        'inputs are re-weighted, never zero-filled.',
    citation: 'Plews 2013 (lnRMSSD) · Hopkins smallest-worthwhile-change gate',
  ),
  'resp_rate': MetricSpec(
    chartKey: 'resp_rate',
    title: 'Respiratory rate',
    unit: 'br/min',
    color: C.teal,
    icon: LucideIcons.wind,
    higherBetter: false,
    method: 'Breathing rate recovered from respiratory sinus arrhythmia — the '
        'periodic modulation breathing imposes on beat timing — over a grid of '
        'candidate rates.',
    citation: 'Pimentel 2017',
  ),
  'sleep': MetricSpec(
    chartKey: 'sleep',
    title: 'Time asleep',
    unit: 'min',
    color: C.blue,
    icon: LucideIcons.moon,
    method: 'Total sleep time from the wrist z-angle sleep window, staged by a '
        'combined actigraphy and heart-rate model.',
    citation: 'van Hees 2015 · Webster / Cole–Kripke rescoring',
  ),
  'efficiency': MetricSpec(
    chartKey: 'efficiency',
    title: 'Sleep efficiency',
    unit: '%',
    color: C.blue,
    icon: LucideIcons.bedDouble,
    method: 'Time asleep as a fraction of time in bed.',
    citation: 'AASM sleep-accounting definitions',
  ),
  'deep': MetricSpec(
    chartKey: 'deep',
    title: 'Deep sleep',
    unit: 'min',
    color: C.blue,
    icon: LucideIcons.moon,
    method: 'A low-confidence overlay: a wrist sensor cannot see slow-wave '
        'activity, so deep sleep here is heart-rate flatness inside NREM.',
    citation: 'Cole–Kripke wake spine + HRV overlay',
  ),
  'rem': MetricSpec(
    chartKey: 'rem',
    title: 'REM sleep',
    unit: 'min',
    color: C.teal,
    icon: LucideIcons.moon,
    method: 'Staged from beat-timing variability and movement. A wrist sensor '
        'separates REM from light sleep only approximately.',
    citation: 'Webster / Cole–Kripke rescoring + HRV staging',
  ),
  'steps': MetricSpec(
    chartKey: 'steps',
    title: 'Steps',
    unit: 'steps',
    color: C.green,
    icon: LucideIcons.footprints,
    method: 'Counted, never modelled. A step count comes from a gait-capable '
        'counter: the band\'s 100 Hz pedometer while it streams, or your '
        'phone\'s. Each stretch of the day is counted by whichever of the two '
        'was actually recording it, and a stretch both covered is counted '
        'once, so a session never takes the day from the sensor that carried '
        'the rest of it. There is no 1 Hz estimate — walking cadence sits above what '
        'one sample a second can resolve, so a day with no counter behind it '
        'reports no steps rather than a guess.',
    citation: 'AN-2554 pedometer · phone pedometer (HealthKit / Health Connect)',
  ),
  'calories': MetricSpec(
    chartKey: 'calories',
    title: 'Active energy',
    unit: 'kcal',
    color: C.orange,
    icon: LucideIcons.flame,
    method: 'Heart-rate-to-energy regression over the waking span, anchored on '
        'your weight, age and sex. An estimate, and sensitive to all three.',
    citation: 'Keytel 2005 · Harris–Benedict / Mifflin BMR floor',
  ),
  'strain': MetricSpec(
    chartKey: 'strain',
    title: 'Strain',
    color: C.purple,
    icon: LucideIcons.zap,
    method: 'Cardiovascular load over the day, compressed onto a 0–21 scale.',
    citation: 'Banister TRIMP family · log-compressed',
  ),
  'trimp': MetricSpec(
    chartKey: 'trimp',
    title: 'Training load',
    color: C.purple,
    icon: LucideIcons.dumbbell,
    method: 'Training impulse: time in each heart-rate zone, weighted by the '
        'physiological cost of that zone.',
    citation: 'Banister 1975 · Edwards 1993',
  ),
  'stress': MetricSpec(
    chartKey: 'stress',
    title: 'Stress',
    color: C.purple,
    icon: LucideIcons.brain,
    higherBetter: false,
    method: 'Baevsky stress index over a resting window: a histogram measure of '
        'how tightly beat intervals cluster. There is deliberately no fallback '
        'when the resting window is missing.',
    citation: 'Baevsky 2008',
  ),
  'dip': MetricSpec(
    chartKey: 'dip',
    title: 'Nocturnal HR dip',
    unit: '%',
    color: C.indigo,
    icon: LucideIcons.trendingDown,
    method: 'How far sleeping heart rate falls below the waking average.',
    citation: 'Nocturnal dipping literature; personal baseline',
  ),
  'hrr': MetricSpec(
    chartKey: 'hrr',
    title: 'Heart-rate recovery',
    unit: 'bpm',
    color: C.red,
    icon: LucideIcons.heartPulse,
    method: 'The drop in heart rate over the 60 seconds after a bout ends, '
        'averaged across the day\'s bouts.',
    citation: 'Cole 1999 (HRR-60)',
  ),
  'lf_hf': MetricSpec(
    chartKey: 'lf_hf',
    title: 'LF / HF',
    color: C.purple,
    icon: LucideIcons.audioWaveform,
    method: 'The ratio of low- to high-frequency power in beat-interval '
        'variability, from a Lomb–Scargle periodogram (the series is unevenly '
        'sampled, so an FFT would be wrong).',
    citation: 'Laguna 1998 · Bigger 1992',
  ),
  'hrv_cv': MetricSpec(
    chartKey: 'hrv_cv',
    title: 'HRV stability',
    unit: '%',
    color: C.green,
    icon: LucideIcons.activity,
    higherBetter: false,
    method: 'Night-to-night coefficient of variation of RMSSD.',
    citation: 'Within-user dispersion',
  ),
  'brv': MetricSpec(
    chartKey: 'brv',
    title: 'Breathing variability',
    color: C.teal,
    icon: LucideIcons.wind,
    higherBetter: false,
    method: 'Coefficient of variation of per-window respiratory rate across '
        'the night.',
    citation: 'Within-user dispersion',
  ),
  // Both of these were written to `metric_series` on every derive since v55 and
  // had no spec, so nothing could open them — `specOf` fell through to a
  // generic entry titled "nap min". They are 17/17 on real data.
  'nap_min': MetricSpec(
    chartKey: 'nap_min',
    title: 'Daytime sleep',
    unit: 'min',
    color: C.indigo,
    icon: LucideIcons.moon,
    method: 'Minutes of sleep detected OUTSIDE the main night: the same wrist '
        'z-angle window detector the night uses, confirmed by a heart-rate dip. '
        'Naps are counted separately and never folded into time asleep.',
    citation: 'van Hees 2015 window detection + nocturnal HR dip',
  ),
  'active_min': MetricSpec(
    chartKey: 'active_min',
    title: 'Movement minutes',
    unit: 'min',
    color: C.green,
    icon: LucideIcons.activity,
    method: 'Minutes whose acceleration sits above a movement floor. That floor '
        'is pooled from your own recent days once there are enough of them, and '
        'a population one before that. This is activity VOLUME, not locomotion: '
        'steps are counted by a pedometer and are never derived from it.',
    citation: 'ENMO over a personal dynamic-range floor',
  ),
  'wear': MetricSpec(
    chartKey: 'wear',
    title: 'Wear time',
    unit: 'min',
    color: C.green,
    icon: LucideIcons.watch,
    method: 'Minutes with a band record present. The band logs to flash only '
        'while it is on a wrist, so record presence IS wear.',
    citation: 'Record-presence, not heart-rate validity',
  ),

  // ── charted nowhere, on purpose ──
  'skin_temp': MetricSpec(
    chartKey: 'skin_temp',
    title: 'Skin temperature',
    color: C.orange,
    icon: LucideIcons.thermometer,
    higherBetter: false,
    suppress: 'A deviation, not a temperature. Imported nights carry different '
              'units, so they are not charted together.',
    suppressFix: 'Shown tonight on Vitals',
    method: 'The night\'s mean raw sensor reading, expressed as distance from '
        'your own recent nights. There is no conversion to degrees anywhere in '
        'the path.',
    citation: 'Relative only — uncalibrated ADC',
  ),
  // `spo2`, `odi_per_hour` and `strain_effort` used to live here as cards that
  // existed only to explain that they were empty. A metric this app does not
  // produce has no entry, no card and no key. See docs/internal/UI_ROADMAP.md.
  //
  // `rmssd_whole`, `stress_si` and `brv_slope` used to live here too, on the
  // same mistake in a quieter form: three fully written specs — title, unit,
  // colour, method, citation — whose whole rendered content was a card saying
  // they cannot be charted. Each is a bundle scalar and none of the three keys
  // is ever written to `metric_series`, so the series behind them is 0 rows and
  // always was. Nothing in the tree ever constructed them, the Explore
  // catalogue excludes them by name, and a spec that can only ever explain its
  // own emptiness is the absent-forever rule again. `stress` and `brv` are the
  // charted forms of two of the three and they stay.
};

MetricSpec specOf(String key) =>
    _specs[key] ??
    MetricSpec(chartKey: key, title: key.replaceAll('_', ' '));

/// Which cross-day percentile block and journal outcome, if any, belongs to
/// this metric. Only four outcomes are correlated by the journal engine.
const _outcomeOf = {
  'hrv': 'rmssd',
  'resting_hr': 'rhr',
  'readiness': 'readiness',
  'efficiency': 'efficiency',
};

// ═══════════════════ the screen ═══════════════════

class MetricData {
  /// DATED points, not bare values. `metric_series` holds one row per DERIVED
  /// day rather than one per calendar day, so a compacted list lets 22 stored
  /// days masquerade as 30 continuous ones — the chart then joins straight
  /// across a sync gap and calls the newest stored point "Today".
  final List<ChartPoint> series;

  /// L4 — THE DENOMINATOR. Worn minutes for the same days, off the same
  /// `getChart` call. A long trend drawn without it is an attendance chart
  /// wearing a physiology label: it cannot make a sparse month comparable, only
  /// refuse to pretend one is.
  final List<ChartPoint> wear;
  final Map<String, dynamic>? percentile;
  final List<Map<String, dynamic>> movers;

  /// Days this install actually has a derived record for. Nothing prunes
  /// `day_result` or `metric_series`, so this is the true horizon — and it is
  /// what decides which range buttons exist.
  final int daysAvailable;

  /// Noon stamps on the days where the algorithm version CHANGED — the days
  /// either side were not produced the same way.
  ///
  /// `getChart` has attached this to every result all along and the only thing
  /// reading it was the briefing engine, so a trend drew straight through a
  /// release boundary. This export holds three versions of the same days and
  /// readiness moved across them: 2026-08-08 went 43.8 → 47.9.
  final List<int> algoBreaks;

  /// The daily step-goal target, read from the profile. Only ever loaded for
  /// `key == 'steps'` — every other metric leaves it at the default and never
  /// draws it.
  final int stepGoal;

  const MetricData({
    this.series = const [],
    this.wear = const [],
    this.percentile,
    this.movers = const [],
    this.daysAvailable = 0,
    this.algoBreaks = const [],
    this.stepGoal = kDefaultStepGoal,
  });

  static Future<MetricData> load(LocalRepository repo, String key) async {
    final spec = specOf(key);
    if (spec.suppress != null) return const MetricData();
    final chart = await repo.getChart(spec.chartKey);
    final days = await repo.availableDays();
    final outcome = _outcomeOf[key];
    final stepGoal = key == 'steps'
        ? ((await repo.getProfile())['step_goal'] as num?)?.toInt() ??
            kDefaultStepGoal
        : kDefaultStepGoal;

    Map<String, dynamic>? pct;
    var movers = const <Map<String, dynamic>>[];
    if (outcome != null) {
      final cd = await repo.getInsights();
      final all = cd['percentiles'];
      final one = all is Map ? all[outcome] : null;
      pct = envValue(one);
      final j = await repo.getJournalInsights(range: '90d');
      final ins = j['insights'];
      movers = [
        for (final e in (ins is List ? ins : const []))
          if (e is Map && e['outcome'] == outcome) e.cast<String, dynamic>(),
      ];
    }
    return MetricData(
      series: pointsOf(chart),
      wear: pointsOf({'points': chart['wear']}),
      percentile: pct,
      movers: movers,
      daysAvailable: days.length,
      algoBreaks: [
        for (final b in (chart['algo_breaks'] as List? ?? const []))
          if (b is Map && b['t'] is num) (b['t'] as num).round(),
      ],
      stepGoal: stepGoal,
    );
  }
}

class MetricDetail extends StatefulWidget {
  final String metricKey;
  final MetricData? data;
  const MetricDetail(this.metricKey, {super.key, this.data});

  @override
  State<MetricDetail> createState() => _MetricDetailState();
}

class _MetricDetailState extends State<MetricDetail> {
  // Today is its own window, not the left edge of the 7-day one. Asking "what
  // is it right now" and "what has it been lately" are different questions,
  // and a range list that starts at 7 days made the first one unanswerable.
  static const _windows = [1, 7, 30, 182, 365];

  List<String> _labelsOf(BuildContext c) {
    final l = AppLocalizations.of(c);
    return [
      l?.metricDetailToday ?? 'Today',
      l?.metricDetailRange7Days ?? '7 days',
      l?.metricDetailRange30Days ?? '30 days',
      l?.metricDetailRange6Months ?? '6 months',
      l?.metricDetailRangeYear ?? 'Year',
    ];
  }

  /// TODAY. A tile on Home shows today's number, so the screen behind that tap
  /// opens on today's number — anything else is a different question than the
  /// one that was asked.
  ///
  /// It used to open on 30 days, and worse, on the WIDEST range the install had
  /// data for: the clamp below meant three weeks of history landed you on 7
  /// days and three months on 30, so the default moved as the install aged and
  /// was never today. The range switcher is still here and still remembers
  /// nothing between visits — a default is where a screen starts, not a
  /// preference.
  int _range = 0;
  MetricData? _d;
  bool _loading = true;

  /// The slot the user has put a finger on, as an index into the DENSE window.
  /// Null until they touch the chart. A window change clears it: slot 12 of a
  /// 30-day window is not slot 12 of a year.
  int? _pick;

  /// How many range buttons this install has data behind.
  ///
  /// Nothing prunes the derived series, so the honest horizon is the life of
  /// the install — but offering "Year" to someone with three weeks is offering
  /// a button that can only ever show three weeks under a label that says a
  /// year. A range appears once there are enough days to fill it; the shortest
  /// one always appears, because it is where a new user starts.
  int _offered(MetricData d) {
    var n = 1;
    for (var i = 1; i < _windows.length; i++) {
      if (d.daysAvailable >= _windows[i]) n = i + 1;
    }
    return n;
  }

  /// The reason the next range up is not there yet, in its own words.
  String? _lockedNote(BuildContext c, MetricData d) {
    final n = _offered(d);
    if (n >= _windows.length) return null;
    final l = AppLocalizations.of(c);
    final label = _labelsOf(c)[n];
    return l?.metricDetailLockedNote(label, _windows[n], d.daysAvailable) ??
        '$label needs ${_windows[n]} days of history. '
            'You have ${d.daysAvailable}.';
  }

  Widget _ranges(BuildContext c, MetricData d, Color color) {
    final p = P.of(c);
    final n = _offered(d);
    final note = _lockedNote(c, d);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SubTabs(_labelsOf(c).sublist(0, n), _range.clamp(0, n - 1),
          (i) => setState(() => (_range = i, _pick = null)),
          color: color),
      if (note != null) ...[
        const SizedBox(height: S.x2),
        Text(note, style: F.over.copyWith(color: p.ink3)),
      ],
    ]);
  }

  /// The AppState this screen told "a live-HR view is on screen", captured
  /// here so `dispose` can release it without touching `context`. Only the
  /// LIVE resting-HR screen (data == null) reads AppState at all — fixtures
  /// and goldens render with no Provider above them.
  AppState? _liveHrOwner;

  @override
  void initState() {
    super.initState();
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    if (widget.metricKey == 'resting_hr') {
      _liveHrOwner = context.read<AppState>()..retainLiveHrView();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _liveHrOwner?.releaseLiveHrView();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final d = await MetricData.load(repo, widget.metricKey);
      if (mounted) setState(() => (_d = d, _loading = false));
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final spec = specOf(widget.metricKey);
    final d = _d ?? const MetricData();

    final all = d.series;
    final win = _windows[_range.clamp(0, _offered(d) - 1)];
    // Dense: one slot per calendar day in the window, `null` where no day
    // derived. The painter breaks the line at a null rather than joining over
    // it, and the axis labels can be dated because the slots ARE the dates.
    final series = denseDays(all, win);
    final vals = [for (final v in series) ?v];

    return detailScaffold(c, spec.title, [
      // Resting heart rate is the NIGHT's number; this is what the chest is
      // doing this second. Two different quantities, so the live one gets its
      // own card above the trend rather than a second figure on the same card,
      // where it would read as a correction to the headline.
      // `data == null` is the LIVE path: every fixture and golden injects its
      // own MetricData, and those render with no Provider above them by design.
      // The live card reads AppState, so it belongs only on the real one.
      if (widget.metricKey == 'resting_hr' && widget.data == null) ...[
        const SizedBox(height: S.x2),
        const LiveHrCard(),
        const SizedBox(height: S.x5),
      ],
      if (spec.suppress != null) ...[
        const SizedBox(height: S.x2),
        StatusCard(
          l?.metricDetailNotShownTitle ?? 'Not shown as a trend',
          spec.suppress!,
          fix: spec.suppressFix ?? '',
          icon: spec.icon,
        ),
        const SizedBox(height: S.x5),
        investigateRow(c, () => go(c, Investigate(widget.metricKey))),
      ] else if (vals.isEmpty) ...[
        _ranges(c, d, spec.color),
        const SizedBox(height: S.x5),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          StatusCard(
            win == 1
                ? (l?.metricDetailNothingRecordedToday ??
                    'Nothing recorded today')
                : (l?.metricDetailNoHistoryYet(spec.title.toLowerCase()) ??
                    'No history for ${spec.title.toLowerCase()} yet'),
            win == 1
                ? (all.isEmpty
                    ? (l?.metricDetailNoValueYet ??
                        'Today has not produced a value yet.')
                    : (l?.metricDetailNoValueYetWiderRanges ??
                        'Today has not produced a value yet. The wider ranges '
                            'above hold the days that did.'))
                : (l?.metricDetailNoValueInWindow ??
                    'No day in this window produced a value.'),
            // Today opens first now, so this card is what someone with months
            // of history sees on a morning before the derive lands. Telling
            // them to wear the band is a promise that cannot change anything —
            // they already did, and the days are one tab away.
            fix: all.isEmpty
                ? (l?.metricDetailWearBandFix ??
                    'Wear the band overnight to start the series')
                : '',
            icon: spec.icon,
          ),
        // The goal is editable even before today has a steps value — the
        // gate below matches the measured branch's. `steps: null` keeps the
        // ring an empty track rather than fabricating a 0% reading. Gated on
        // `!_loading` too: before the real profile loads, `d` is the
        // placeholder `MetricData()` and `d.stepGoal` is just the fallback
        // default, not this user's goal — showing the editor pre-filled with
        // that would risk saving it over their real one.
        if (!_loading && widget.metricKey == 'steps' && win == 1) ...[
          const SizedBox(height: S.x5),
          _StepGoalGauge(
              steps: null, goal: d.stepGoal, color: spec.color, onSaved: _load),
        ],
        const SizedBox(height: S.x5),
        investigateRow(c, () => go(c, Investigate(widget.metricKey))),
      ] else ...[
        _ranges(c, d, spec.color),
        const SizedBox(height: S.x5),
        _hero(c, spec, all, series, vals, win, d.wear, d.algoBreaks),
        // Today's count against the goal set on this screen's own edit
        // affordance — a trend average has no goal to be measured against, so
        // this stays win == 1 only, same gate as the Breakdown link below.
        if (widget.metricKey == 'steps' && win == 1) ...[
          const SizedBox(height: S.x5),
          _StepGoalGauge(
              steps: vals.last,
              goal: d.stepGoal,
              color: spec.color,
              onSaved: _load),
        ],
        // On Today the window holds one value, and its lowest, typical and
        // highest would all be that same number. The normal range is a
        // property of your history, not of the window — so on Today it reads
        // the whole series.
        Section(
            l?.metricDetailNormalRangeSection ?? 'Your normal range',
            _range3(c, spec, win == 1 ? valuesOf(all) : vals, d.percentile,
                all.isEmpty ? null : all.last.t)),
        if (d.movers.isNotEmpty)
          Section(l?.metricDetailWhatMovesItSection ?? 'What moves it',
              _movers(c, d.movers)),
        const SizedBox(height: S.x5),
        // Steps are the one metric assembled from SPANS of the day, each
        // counted by a different sensor. That breakdown is a day's worth of
        // detail and it belongs behind a tap, not on the tile and not as a
        // fourth card here.
        // HRV's own substrate. RMSSD is one number squeezed out of tens of
        // thousands of beat intervals, and the geometry of those intervals —
        // the Poincaré cloud, the night's curve, deceleration capacity, the
        // rhythm screen — is the most differentiated thing this app computes.
        // It is a screen, not a fourth card here: one number's drill-down does
        // not become five pictures.
        if (widget.metricKey == 'hrv') ...[
          // Wording, not a gate: this door opens the newest night and Beats
          // carries its own day stepper, so it is honest under any range — but
          // "behind this number" was not, with a 30-day average as the number.
          detailLinkRow(
              c,
              LucideIcons.heartPulse,
              l?.metricDetailBeatsLinkTitle ?? 'Beats',
              l?.metricDetailBeatsLinkSub ??
                  'The intervals a night is made of, drawn',
              () => go(c, const Beats())),
          const SizedBox(height: S.x3),
        ],
        // TODAY ONLY, and it is called Breakdown.
        //
        // It describes how TODAY's number was put together, and it rendered
        // under the 7- and 30-day charts too, where it explained a day the
        // picture was not showing. On a wider range the way into one day is
        // the chart itself — touch a point and it opens that day.
        //
        // "Where today's came from" was the old name: accurate about the
        // content, and it read as a phrase rather than a place. A doorway
        // wants the plainest noun that is still true.
        if (widget.metricKey == 'steps' && win == 1) ...[
          detailLinkRow(
              c,
              LucideIcons.footprints,
              l?.metricDetailBreakdownLinkTitle ?? 'Breakdown',
              l?.metricDetailBreakdownLinkSub ??
                  'Each stretch of today, and what counted it',
              () => go(c, const DayStepsDetail())),
          const SizedBox(height: S.x3),
        ],
        investigateRow(c, () => go(c, Investigate(widget.metricKey))),
      ],
    ]);
  }

  // ── value → context → trend ──
  //
  // THE HEADLINE IS THE WINDOW'S NUMBER, not the latest reading.
  //
  // It used to be `vals.last`, which is the same figure in every range — so
  // switching 7 days to 30 days changed the chart and left the big number
  // sitting there, and on an additive metric it was worse than confusing:
  // today's 43 steps under a "30 days" tab reads as a month's total.
  //
  // The day count beside it is not decoration. It is what explains the case
  // that looks broken: with one day of history, seven days and thirty days
  // really do average to the same number, and "1 of 30 days" says so where
  // a bare figure looked like a bug.
  Widget _hero(BuildContext c, MetricSpec spec, List<ChartPoint> all,
      List<double?> series, List<double> vals, int win,
      List<ChartPoint> wear, List<int> algoBreaks) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final mean = vals.reduce((a, b) => a + b) / vals.length;
    final latest = vals.last;
    // WHICH DAY the newest reading is from. `metric_series` gets a row only on
    // a day that derives, so after a sync gap the newest stored point is days
    // old — and this line is the answer to "is there a today?".
    final asOf = all.isEmpty ? '' : axisDay(all.last.t);

    return Surface(
      child: Column(children: [
        Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(_fmt(spec, mean), style: F.n48.copyWith(color: p.ink)),
              const SizedBox(width: S.x2),
              // NOT `spec.unit`. `metricValue('min', 443)` is already "7h 23m",
              // so every min-unit metric — Time asleep, Deep, REM, Wear time —
              // rendered its headline as "7h 23m min".
              Text(unitBeside(spec.unit),
                  style: F.body.copyWith(color: p.ink3)),
            ]),
        const SizedBox(height: S.x1),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            win == 1
                ? (l?.metricDetailToday ?? 'Today')
                : (l?.metricDetailDailyAverage(vals.length, win) ??
                    'Daily average · ${vals.length} of $win days'),
            style: F.cap.copyWith(color: p.ink3),
          ),
        ),
        // On a multi-day window the average is the headline, so the newest
        // reading needs its own line. On Today they are the same number, and
        // printing it twice would read as two different facts.
        if (win > 1 && asOf.isNotEmpty) ...[
          const SizedBox(height: S.x2),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
                (l?.metricDetailLatestReading(
                            _fmt(spec, latest), unitBeside(spec.unit), asOf) ??
                        'Latest ${_fmt(spec, latest)} ${unitBeside(spec.unit)} · $asOf')
                    .replaceAll('  ', ' '),
                style: F.cap.copyWith(color: p.ink3)),
          ),
        ],
        // No chart on Today. These series carry one value per day, so a
        // one-day window is a single point — and a single point drawn on an
        // axis is a shape pretending to be a trend. "Your normal range" below
        // is the context that actually helps here.
        if (win > 1) const SizedBox(height: S.x5),
        if (win > 1)
        Builder(builder: (c) {
          // One axis, shared by the labels and the curve. `min` unit metrics
          // print `7h 30m` on the gridlines rather than `450`.
          final axis = AxisSpec.of(vals,
              ticks: 3,
              format: spec.unit == 'min'
                  ? axisHm
                  : (spec.unit == 'steps' || spec.unit == 'kcal'
                      ? (v) => thousands(v)
                      : (vals.every((v) => v.abs() >= 10)
                          ? axisInt
                          : axisFixed)),
              floor: spec.unit == '%' ? 0 : null);
          // WHERE A RELEASE SITS ON THE LINE.
          //
          // A break's stamp is the first day computed the NEW way, so the
          // boundary is between two slots, not on one — half a slot left of it.
          // A break at slot 0 is dropped: there is nothing before it in this
          // window to be incomparable with.
          final marks = <double>[
            if (series.length > 1)
              for (final t in algoBreaks)
                if (daysBehind(t) case final b?
                    when b >= 0 && b < series.length && series.length - 1 - b > 0)
                  (series.length - 1 - b - .5) / (series.length - 1),
          ];
          return ChartFrame(
            title: spec.title,
            unit: spec.unit.isEmpty ? 'score' : spec.unit,
            height: 150,
            yAxis: axis,
            xMarks: marks,
            // The mark's only screen-reader form, and the only thing that can
            // say what it is. Deliberately flat: a version change is
            // provenance, not an event that happened to the user.
            footnote: marks.isEmpty
                ? null
                : (l?.metricDetailAlgoBreakFootnote(marks.length) ??
                    (marks.length == 1
                        ? 'The dotted line is a change in how these days were '
                            'computed. Readings either side of it came from '
                            'different versions.'
                        : 'The dotted lines are changes in how these days were '
                            'computed. Readings either side of one came from '
                            'different versions.')),
            // The window IS the span now: `series` has one slot per calendar
            // day whether or not that day derived, so both edges are dates
            // rather than array positions. It used to read the length of a
            // compacted list, which meant a chart spanning two months labelled
            // its left edge "30 days ago".
            // Slot 0 is `length - 1` days behind today, not `length` — the
            // last slot IS today. A 30-slot window spans 29 days of distance.
            xLabels: [
              l?.metricDetailDaysAgoLabel(series.length - 1) ??
                  '${series.length - 1} day${series.length == 2 ? '' : 's'} ago',
              l?.metricDetailToday ?? 'Today',
            ],
            // The dots are already beside the big number two rows up; twice on
            // one card reads as two different claims.
            series: series,
            // TOUCHING A POINT OPENS THAT DAY.
            //
            // This chart will draw the night somebody's sleep collapsed and
            // there was no way into it: every single-day screen resolved the
            // newest day and stopped. A slot with a value came out of
            // `metric_series`, which gets a row only on a day that DERIVED, so
            // a non-null slot is by construction a day this install can open —
            // no membership check, and a null slot offers no door.
            child: Scrubber(
              // Slot i sits at i/(len-1) — exactly where `minMaxRuns` plots it,
              // so the readout names the day under the finger rather than the
              // bucket the finger is in.
              value: _pick == null ? null : _slotAt01(_pick!, series.length),
              step: 1 / (series.length - 1),
              label: spec.title,
              describe: (v) =>
                  _slotSays(c, spec, series, _slotAt(v, series.length)),
              onChanged: (v) =>
                  setState(() => _pick = _slotAt(v, series.length)),
              child: CustomPaint(
                size: Size.infinite,
                // Fill only when the axis genuinely starts at zero. Shaded to
                // a baseline of 52 bpm, a 52→60 week reads as a mountain — the
                // truncated-axis form with the truncation hidden.
                painter: LineChart(series, p.on(spec.color),
                    fill: axis?.min == 0,
                    dots: series.length <= 40,
                    t: animate(c, 1),
                    dotInk: p.card,
                    axis: axis),
              ),
            ),
          );
        }),
        if (_pick != null) _picked(c, spec, series),
        // L4 — the coverage denominator, under the curve it belongs to.
        //
        // Deliberately unflattering, and gated to the ranges where it changes
        // the reading: a 7-day chart is one week you either wore or did not,
        // while a 6-month line drawn over four worn nights a month is an
        // attendance chart with a physiology label on it. It cannot make a
        // sparse month comparable — only refuse to pretend.
        //
        // A day with no `worn_min` row draws NOTHING, not a zero: wear older
        // than the 3-day substrate window is knowable only through this derived
        // key, and nothing here reconstructs it. Same card, not a new one; the
        // denominator is part of reading the chart, not a second claim.
        if (win >= 30 && spec.chartKey != 'wear' && wear.isNotEmpty)
          Builder(builder: (c) {
            final hrs = [
              for (final v in denseDays(wear, win)) v == null ? null : v / 60,
            ];
            final have = [for (final v in hrs) ?v];
            if (have.isEmpty) return const SizedBox.shrink();
            final axis =
                AxisSpec.of(have, ticks: 2, floor: 0, ceil: 24, format: axisInt);
            return Padding(
              padding: const EdgeInsets.only(top: S.x4),
              child: ChartFrame(
                title: l?.metricDetailWornChartTitle ?? 'Worn',
                unit: l?.metricDetailHoursADayUnit ?? 'h a day',
                height: 56,
                yAxis: axis,
                series: hrs,
                footnote: l?.metricDetailWearFootnote(have.length, win) ??
                    '${have.length} of these $win days have a wear '
                        'record. The rest are gaps in both charts — the line above '
                        'is not carried across one.',
                child: CustomPaint(
                  size: Size.infinite,
                  painter: Bars(hrs, p.ink3, axis: axis),
                ),
              ),
            );
          }),
      ]),
    );
  }

  // ── a point on the chart is a day you can open ──────────────────────────

  /// A 0…1 position along the plot as a slot index into the dense window, and
  /// back. Point i is drawn at `i / (len - 1)` — see `minMaxRuns` — so that is
  /// what both directions use.
  int _slotAt(double v, int len) =>
      len < 2 ? 0 : (v * (len - 1)).round().clamp(0, len - 1);

  double _slotAt01(int i, int len) => len < 2 ? 0 : i / (len - 1);

  /// The calendar day a dense slot stands for. Slot `len - 1` is today and
  /// slot 0 is `len - 1` days behind it — the same arithmetic [denseDays] fills
  /// with, walked through [DateTime]'s own calendar so the two days a year that
  /// are 23 or 25 hours long land on the right date.
  String _dayOfSlot(int i, int len) {
    final n = DateTime.now();
    return dayLabelOf(DateTime(n.year, n.month, n.day - (len - 1 - i)));
  }

  /// What the slider reads out. The value, or the fact that the day is a hole.
  String _slotSays(BuildContext c, MetricSpec spec, List<double?> series, int i) {
    final l = AppLocalizations.of(c);
    final day = prettyDay(_dayOfSlot(i, series.length), l);
    final v = series[i];
    return v == null
        ? (l?.metricDetailSlotNoRecord(day) ?? '$day, no record')
        : (l?.metricDetailSlotWithValue(
                    day, _fmt(spec, v), unitBeside(spec.unit)) ??
                '$day, ${_fmt(spec, v)} ${unitBeside(spec.unit)}')
            .trimRight();
  }

  /// The touched day, and the door into it.
  ///
  /// A day with a value is a day that derived, so the door always leads
  /// somewhere. A day with no value says so and offers nothing — an action
  /// button is a promise, and there is no screen behind an empty day.
  Widget _picked(BuildContext c, MetricSpec spec, List<double?> series) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final i = _pick!.clamp(0, series.length - 1);
    final day = _dayOfSlot(i, series.length);
    final v = series[i];
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Surface(
        color: p.card2,
        elevation: 0,
        onTap: v == null ? null : () => go(c, _dayScreen(widget.metricKey, day)),
        semanticLabel: v == null
            ? (l?.metricDetailSlotNoRecord(prettyDay(day, l)) ??
                '${prettyDay(day, l)}, no record')
            : (l?.metricDetailOpenDay(prettyDay(day, l)) ??
                'Open ${prettyDay(day, l)}'),
        child: Row(children: [
          Expanded(
            child: Text(dayNavLabel(day),
                style:
                    F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: S.x3),
          Text(
            v == null
                ? (l?.metricDetailNoRecordLabel ?? 'No record')
                : '${_fmt(spec, v)} ${unitBeside(spec.unit)}'.trimRight(),
            style: v == null
                ? F.cap.copyWith(color: p.ink3)
                : F.n17.copyWith(color: p.ink),
          ),
          if (v != null) ...[
            const SizedBox(width: S.x2),
            Icon(LucideIcons.chevronRight, size: 18, color: p.ink3),
          ],
        ]),
      ),
    );
  }

  /// Where a day opens. Each metric lands on the screen that actually shows
  /// that day — Nerd stats is the fallback because it is the one screen that
  /// exists for every key.
  Widget _dayScreen(String key, String day) => switch (key) {
        'sleep' ||
        'deep' ||
        'rem' ||
        'efficiency' =>
          SleepDetail(day: day),
        'hrv' => Beats(day: day),
        'steps' => DayStepsDetail(day: day),
        _ => Investigate(key, day: day),
      };

  /// [latestTs] is the stamp on the newest STORED point — the day the rank was
  /// computed for. `metric_series` gets a row only on a day that derives and
  /// the rollup is served for a week, so "Today sits at the 12th percentile"
  /// was printed unconditionally two rows under a hero saying "4 days ago".
  Widget _range3(BuildContext c, MetricSpec spec, List<double> win,
      Map<String, dynamic>? pct, int? latestTs) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final sorted = [...win]..sort();
    final lo = sorted.first, hi = sorted.last;
    final mid = sorted[sorted.length ~/ 2];
    final band = pct?['label']?.toString();
    final rank = (pct?['percentile_of_you'] as num?);
    final isToday = (daysBehind(latestTs) ?? 0) <= 0;
    final ordinal = rank == null ? '' : _ordinal(rank.round(), l);

    return Surface(
      child: Column(children: [
        Row(children: [
          Expanded(
              child: _stat(p, _fmt(spec, lo), l?.metricDetailLowest ?? 'Lowest')),
          Expanded(
              child:
                  _stat(p, _fmt(spec, mid), l?.metricDetailTypical ?? 'Typical')),
          Expanded(
              child: _stat(
                  p, _fmt(spec, hi), l?.metricDetailHighest ?? 'Highest')),
        ]),
        const SizedBox(height: S.x4),
        Text(
          rank == null
              ? (l?.metricDetailFromDaysCount(win.length) ??
                  'From ${win.length} of your own days.')
              : (isToday
                  ? (band == null
                      ? (l?.metricDetailPercentileTodayNoBand(ordinal) ??
                          'Today sits at the $ordinal percentile of your own '
                              'history.')
                      : (l?.metricDetailPercentileTodayBand(ordinal, band) ??
                          'Today sits at the $ordinal percentile of your own '
                              'history — $band.'))
                  : (band == null
                      ? (l?.metricDetailPercentileFromNoBand(
                              axisDay(latestTs), ordinal) ??
                          'Your reading from ${axisDay(latestTs)} sits at the '
                              '$ordinal percentile of your own history.')
                      : (l?.metricDetailPercentileFromBand(
                              axisDay(latestTs), ordinal, band) ??
                          'Your reading from ${axisDay(latestTs)} sits at the '
                              '$ordinal percentile of your own history — '
                              '$band.'))),
          style: F.cap.copyWith(color: p.ink3, height: 1.5),
        ),
      ]),
    );
  }

  /// [n]th, localized. `{ordinal}` gets substituted whole into an ARB
  /// sentence, so this is the one place the suffix has to match the reader's
  /// language — an English "12th" inside a French sentence reads as broken,
  /// not translated.
  String _ordinal(int n, AppLocalizations? l) {
    switch (l?.localeName.split('_').first) {
      case 'fr':
        return n == 1 ? '1er' : '${n}e';
      case 'de':
        return '$n.';
      case 'es':
        return '$nº';
      case 'hi':
      case 'zh':
        // Neither language marks the ordinal with a suffix here — the
        // surrounding ARB sentence already carries the "the Nth" framing
        // (Hindi's postposition, Chinese's 第 prefix), so a bare number is
        // the correct rendering, not a fallback.
        return '$n';
      default:
        if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
        return '$n${const ['th', 'st', 'nd', 'rd'][n % 10 < 4 ? n % 10 : 0]}';
    }
  }

  Widget _stat(P p, String v, String l) => Column(children: [
        Text(v, style: F.n24.copyWith(color: p.ink)),
        const SizedBox(height: 3),
        Text(l, style: F.over.copyWith(color: p.ink3)),
      ]);

  /// Journal ↔ metric rank correlations. These are ASSOCIATIONS in your own
  /// history, which is why the copy says "on days you logged" and never
  /// "because".
  Widget _movers(BuildContext c, List<Map<String, dynamic>> movers) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final rows = movers.take(5).toList();
    return Column(children: [
      Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rows[i]['tag']?.toString() ?? '',
                            style: F.body.copyWith(color: p.ink)),
                        Text(
                            l?.metricDetailDaysWithWithout(
                                    (rows[i]['n_with'] as num? ?? 0).toInt(),
                                    (rows[i]['n_without'] as num? ?? 0).toInt()) ??
                                '${rows[i]['n_with'] ?? 0} days with · '
                                    '${rows[i]['n_without'] ?? 0} without',
                            style: F.over.copyWith(color: p.ink3)),
                      ]),
                ),
                Text(
                  _signed(rows[i]['delta'] as num?, rows[i]['unit']?.toString()),
                  style: F.body.copyWith(
                      color: p.on(rows[i]['helped'] == true ? C.green : C.orange),
                      fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          ],
        ]),
      ),
      const SizedBox(height: S.x3),
      Text(
          l?.metricDetailPatternsNotCauses ??
              'Patterns in your own logs, not causes.',
          style: F.over.copyWith(color: p.ink3, height: 1.5)),
    ]);
  }

  String _signed(num? v, String? unit) {
    if (v == null) return '';
    final s = v.abs() >= 10 ? v.abs().round().toString() : v.abs().toStringAsFixed(1);
    return '${v >= 0 ? '+' : '−'}$s${unit == null || unit.isEmpty ? '' : ' $unit'}';
  }

  String _fmt(MetricSpec spec, double v) => metricValue(spec.unit, v);
}

/// Today's steps against the goal, as one small ring — the same [Ring]
/// painter Home's recovery/strain/sleep dials use, at a size that reads as a
/// detail beside the hero number rather than a fourth headline. The goal
/// itself is editable in place: tap it, type, hit the check — no dialog.
/// Same 500–100,000 bound as `LocalRepositoryImpl.setStepGoal` — this is the
/// UI writer of `step_goal`, through `AppState.updateProfile` directly rather
/// than through that method.
class _StepGoalGauge extends StatefulWidget {
  /// Null when today has not produced a steps value yet — the ring then
  /// shows only the empty track, never a fabricated 0%.
  final double? steps;
  final int goal;
  final Color color;
  final Future<void> Function() onSaved;

  const _StepGoalGauge(
      {required this.steps,
      required this.goal,
      required this.color,
      required this.onSaved});

  @override
  State<_StepGoalGauge> createState() => _StepGoalGaugeState();
}

class _StepGoalGaugeState extends State<_StepGoalGauge> {
  bool _editing = false;
  late final TextEditingController _ctrl =
      TextEditingController(text: '${widget.goal}');

  @override
  void didUpdateWidget(covariant _StepGoalGauge old) {
    super.didUpdateWidget(old);
    // The goal just saved (or changed under us some other way) — keep the
    // field in sync so reopening the editor shows the current value, not
    // the one it was first built with.
    if (!_editing && old.goal != widget.goal) {
      _ctrl.text = '${widget.goal}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = Typed.of(_ctrl.text);
    final typed = (t.bad || t.value == null) ? null : t.value!.round();
    if (typed == null) {
      setState(() => _editing = false);
      return;
    }
    if (typed < 500 || typed > 100000) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('A step goal of 500–100,000 is a real one. Nothing was saved.'),
      ));
      return;
    }
    setState(() => _editing = false);
    await context.read<AppState>().updateProfile({'step_goal': typed});
    // The parent's onSaved reloads and calls setState — never on a widget
    // that navigated away while the write was in flight.
    if (!mounted) return;
    await widget.onSaved();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final steps = widget.steps;
    final frac =
        steps == null || widget.goal <= 0 ? null : steps / widget.goal;
    return Surface(
      child: Row(children: [
        SizedBox(
          width: 56,
          height: 56,
          child: Stack(alignment: Alignment.center, children: [
            CustomPaint(
              size: Size.infinite,
              painter:
                  Ring(frac ?? 0, widget.color, p.track, stroke: 7, solid: true),
            ),
            // No steps recorded yet is absent, not zero — the track alone
            // says that; a percentage here would fabricate a reading.
            if (frac != null)
              Text('${(frac * 100).clamp(0, 999).round()}%',
                  style: F.over.copyWith(color: p.ink)),
          ]),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: _editing
              ? Row(children: [
                  Expanded(
                    child: OsTextField(
                        controller: _ctrl,
                        label: 'Goal',
                        keyboard: TextInputType.number),
                  ),
                  const SizedBox(width: S.x2),
                  Pressable(
                    semanticLabel: 'Save step goal',
                    onTap: _save,
                    child: Icon(LucideIcons.check, size: 20, color: p.ink),
                  ),
                ])
              : Pressable(
                  semanticLabel: 'Edit daily step goal',
                  onTap: () => setState(() => _editing = true),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text('Goal', style: F.over.copyWith(color: p.ink3)),
                        const SizedBox(width: S.x1),
                        Icon(LucideIcons.pencil, size: 12, color: p.ink3),
                      ]),
                      Text('${thousands(widget.goal)} steps',
                          style: F.body.copyWith(color: p.ink)),
                    ],
                  ),
                ),
        ),
      ]),
    );
  }
}

// ═══════════════════ shared detail chrome ═══════════════════

/// Every detail screen is the same frame: a back bar, then a scroll. Keeping it
/// in one function is the reason the back affordance is in the same place on
/// all of them.
Widget detailScaffold(BuildContext c, String title, List<Widget> body,
    {String sub = '', Widget? trailing}) {
  final p = P.of(c);
  return Scaffold(
    backgroundColor: p.bg,
    body: SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: S.x4),
          child: NavBar(title,
              sub: sub,
              trailing: trailing,
              onBack: () => Navigator.of(c).maybePop()),
        ),
        Expanded(
          child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x12),
              children: body),
        ),
      ]),
    ),
  );
}

// ═══════════════════ which day a detail screen is showing ═══════════════════
//
// Nothing prunes `day_result`, so an install holds every day it has ever
// derived — and until this existed every single-day screen resolved `days.first`
// and stopped there. The chart on this screen would happily draw the night
// somebody's sleep collapsed and offer no way into it.

/// The day a single-day screen should load: the one it was OPENED with when
/// that day exists, else the screen's own idea of now, else the newest day on
/// disk.
///
/// [want] is the day the caller asked for and [prefer] the screen's own
/// resolution (`today_day`, a held-over night). With no [want] this is exactly
/// what every loader did inline, which is why passing no day changes nothing.
String? pickDay(List<String> days, String? want, [String? prefer]) {
  final d = want ?? prefer;
  // No derived days at all: there is nothing to fall back TO, so the caller's
  // own answer stands or the screen renders its absence.
  if (days.isEmpty) return d;
  if (d != null && days.contains(d)) return d;
  return days.first;
}

/// 'Today' when it is, otherwise the day itself. Never "N days ago" — a
/// control you steer with needs the name of the place, not the distance to it.
String dayNavLabel(String? day) =>
    (_dayBehind(day) ?? 1) <= 0 ? 'Today' : prettyDay(day);

int? _dayBehind(String? dayId) {
  final d = dayId == null ? null : DateTime.tryParse(dayId);
  return d == null ? null : calendarDaysBetween(d, DateTime.now());
}

/// The calendar, restricted to the days that exist. A picker that offers an
/// empty day is a dead end, so [days] greys out everything it does not contain.
Future<String?> chooseDay(
    BuildContext c, List<String> days, String? current) async {
  if (days.isEmpty) return null;
  final have = days.toSet();
  final sorted = [...days]..sort(); // oldest → newest
  final first = DateTime.parse(sorted.first);
  final last = DateTime.parse(sorted.last);
  final want = DateTime.tryParse(current ?? '') ?? last;
  final picked = await showDatePicker(
    context: c,
    initialDate: want.isBefore(first) ? first : (want.isAfter(last) ? last : want),
    firstDate: first,
    lastDate: last,
    selectableDayPredicate: (d) => have.contains(dayLabelOf(d)),
    helpText: AppLocalizations.of(c)?.metricDetailChooseDayHelp ?? 'Choose a day',
  );
  return picked == null ? null : dayLabelOf(picked);
}

/// The day stepper every single-day screen wears under its nav bar.
///
/// [days] is `availableDays()` — NEWEST FIRST, and only days that derived. Both
/// arrows and the picker walk that list, so there is no way to steer onto a day
/// this install has no record of. With fewer than two days there is nowhere to
/// go and the control renders nothing rather than two dead arrows.
class DayNav extends StatelessWidget {
  final String? day;
  final List<String> days;
  final ValueChanged<String> onDay;

  const DayNav({
    super.key,
    required this.day,
    required this.days,
    required this.onDay,
  });

  @override
  Widget build(BuildContext c) {
    if (days.length < 2) return const SizedBox.shrink();
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final i = days.indexOf(day ?? '');
    // days is newest first: the OLDER day is further down the list.
    final older = i < 0 ? days.first : (i + 1 < days.length ? days[i + 1] : null);
    final newer = i > 0 ? days[i - 1] : null;

    Widget arrow(IconData icon, String label, String? to) => Opacity(
          opacity: to == null ? .35 : 1,
          child: Pressable(
            onTap: to == null ? null : () => onDay(to),
            semanticLabel: label,
            child: Icon(icon, size: 20, color: p.ink),
          ),
        );

    return Container(
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
      child: Row(children: [
        arrow(LucideIcons.chevronLeft, l?.metricDetailPreviousDay ?? 'Previous day',
            older),
        Expanded(
          child: Pressable(
            onTap: () async {
              final picked = await chooseDay(c, days, day);
              if (picked != null && picked != day) onDay(picked);
            },
            semanticLabel: l?.metricDetailChooseDayShowing(dayNavLabel(day)) ??
                'Choose a day. Showing ${dayNavLabel(day)}',
            child: Text(
              dayNavLabel(day),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        arrow(LucideIcons.chevronRight, l?.metricDetailNextDay ?? 'Next day', newer),
      ]),
    );
  }
}

/// [DayNav] and the gap under it, spread into a `detailScaffold` body — or
/// nothing at all when there is only one day to look at.
List<Widget> dayNavRow(
        String? day, List<String> days, ValueChanged<String> onDay) =>
    days.length < 2
        ? const []
        : [
            DayNav(day: day, days: days, onDay: onDay),
            const SizedBox(height: S.x3),
          ];

/// A plain door onto another screen. Deliberately quiet: a doorway is not a
/// card, and a metric screen that grows a second loud card stops having a
/// headline.
Widget detailLinkRow(BuildContext c, IconData icon, String title, String sub,
    VoidCallback onTap) {
  final p = P.of(c);
  return Pressable(
    onTap: onTap,
    semanticLabel: '$title: $sub',
    child: Container(
      padding: const EdgeInsets.all(S.x4),
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
      child: Row(children: [
        Icon(icon, size: 17, color: p.ink3),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
            Text(sub, style: F.over.copyWith(color: p.ink3)),
          ]),
        ),
        Icon(LucideIcons.chevronRight, size: 18, color: p.ink3),
      ]),
    ),
  );
}

/// The door into density 3 — the screen the user sees as "Nerd stats". Kept
/// deliberately plain: it is a workbench entrance, not a feature, and it now
/// reads as a companion to the picture above it rather than as the place the
/// interesting numbers are hiding.
///
/// The identifier stays `investigateRow` to match `investigate.dart` and the
/// `investigate_row` gallery key; only the string changed.
Widget investigateRow(BuildContext c, VoidCallback onTap) => detailLinkRow(
    c,
    LucideIcons.cpu,
    AppLocalizations.of(c)?.metricDetailNerdStatsTitle ?? 'Nerd stats',
    // One line at 1x. A subtitle that wraps makes this row taller than every
    // other `detailLinkRow` in the app, which is a layout change dressed up as
    // a copy change — keep it at or under the old string's length.
    AppLocalizations.of(c)?.metricDetailNerdStatsSub ??
        'The figures behind the picture',
    onTap);

/// A two-column legend. Used by the hypnogram and the overnight stack.
class Legend extends StatelessWidget {
  final List<(String, Color)> items;
  const Legend(this.items, {super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Wrap(
      spacing: S.x4,
      runSpacing: S.x2,
      children: [
        for (final e in items)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: e.$2, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text(e.$1, style: F.over.copyWith(color: p.ink2)),
          ]),
      ],
    );
  }
}

/// The mono table Nerd stats is built from — label left, value right, both in
/// a fixed-pitch face so columns line up and nothing pretends to be prose.
class MonoTable extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;
  const MonoTable(this.title, this.rows, {super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    // A row with nothing behind it is dropped, not dashed. On a workbench an
    // em-dash reads as "we tried and got nothing", which is indistinguishable
    // from "this metric does not apply to this night".
    final present = [for (final r in rows) if (r.$2 != '—' && r.$2.isNotEmpty) r];
    if (present.isEmpty) return const SizedBox.shrink();
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title.toUpperCase(), style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x3),
        for (final r in present)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(r.$1,
                        style: F.cap
                            .copyWith(color: p.ink3, fontFamily: 'Menlo')),
                  ),
                  const SizedBox(width: S.x3),
                  Flexible(
                    child: Text(r.$2,
                        textAlign: TextAlign.right,
                        style: F.cap.copyWith(
                            color: p.ink,
                            fontFamily: 'Menlo',
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
          ),
      ]),
    );
  }
}
