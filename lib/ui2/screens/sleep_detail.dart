// SLEEP — one question, answered in three seconds, then revealed by scrolling.
//
// "How did my night go?" → what happened → how it compares to YOUR nights →
// what stood out → the signals underneath → the one thing to do tonight. Same
// screen, layered by scroll depth; there is no advanced mode to switch into.
//
// There is no sleep score. No composite exists in the pipeline, and inventing
// one here would mean choosing weights in a UI file. What replaces it is the
// comparison every "86" is a lossy summary of: last night against the middle
// half of the user's OWN recent nights, per measure, with the night count
// attached. A quartile band needs no thresholds, no population norms and no
// constants — it is the user's own distribution, so it cannot be wrong about
// somebody it was never fitted to.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:provider/provider.dart';

import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/locale_controller.dart';
import '../../state/prefs.dart';
import '../../models/metric.dart';
import '../ui2.dart';
import 'home_screen.dart';
import 'investigate.dart';
import 'metric_detail.dart';
import 'naps.dart';
import 'rough_night.dart';

/// Nights of history before a personal normal is claimed at all. Below this the
/// quartiles of three or four nights are noise wearing a band's clothing.
const _minNights = 7;

/// Nights before "your shortest night in N" is worth saying. A record inside a
/// week is a coincidence.
const _recordNights = 14;

/// How far back the comparison window reaches. Long enough to be stable, short
/// enough to still be "you lately" rather than "you last season".
const _window = 28;

/// A per-second label from the segmenter, or NULL for a second nobody watched.
///
/// `unobserved` is not a stage. The catch-all used to be `SleepStage.light`, so
/// every second the band never recorded was drawn — and read — as light sleep:
/// a three-hour hole came out as three hours of sleep. Null draws as a gap, and
/// an unrecognised label from an older bundle now goes the same way, which is
/// the honest direction to fail in.
SleepStage? _stageOf(Object? raw) => switch (raw?.toString()) {
      'wake' || 'awake' => SleepStage.awake,
      'rem' => SleepStage.rem,
      'deep' => SleepStage.deep,
      'light' || 'nrem' => SleepStage.light,
      _ => null,
    };

/// 15-minute bands. The stager sees a wrist, so "you fell asleep in 7 minutes"
/// is a precision nobody measured.
String _solBand(BuildContext c, double m) {
  final l = AppLocalizations.of(c);
  if (m < 15) return l?.sleepDetailSolUnder15 ?? 'under 15 minutes';
  if (m >= 60) return l?.sleepDetailSolOverHour ?? 'over an hour';
  final lo = (m ~/ 15) * 15;
  return l?.sleepDetailSolRange(lo, lo + 15) ?? '$lo–${lo + 15} minutes';
}

/// Two call sites drew this byte-identical card; one function so they cannot
/// drift apart.
Widget _noOvernightLines(BuildContext c) {
  final l = AppLocalizations.of(c);
  return StatusCard(
    l?.sleepDetailNoOvernightTitle ?? 'No overnight signal lines',
    l?.sleepDetailNoOvernightBody ?? 'No overnight recordings reached this day.',
    icon: LucideIcons.activity,
  );
}

/// Local noon of a 'YYYY-MM-DD' day, in epoch seconds — the stamp `getChart`
/// puts on that day's stored scalar. Used to cut the history at last night, so
/// a night is never compared against a window that contains itself.
int? _noonOf(String? day) => day == null
    ? null
    : (DateTime.tryParse('$day 12:00:00')?.millisecondsSinceEpoch ?? 0) ~/ 1000;

/// The middle half of the user's own nights, plus its median and its count.
///
/// Nearest-rank quartiles, no interpolation: with 20-odd samples the difference
/// is smaller than a minute and interpolation invents a value nobody slept.
/// Null below [_minNights] — the screen says so rather than drawing a band.
({double lo, double mid, double hi, int n})? _band(List<double> xs) {
  if (xs.length < _minNights) return null;
  final s = [...xs]..sort();
  double q(double f) => s[((s.length - 1) * f).round()];
  return (lo: q(.25), mid: q(.5), hi: q(.75), n: s.length);
}

String _pct(double v) => '${v.round()}%';
String _pts(double v) => '${v.round()} points';

/// SLP-13 — the three staged figures of a night, as the intervals they are.
///
/// Null when the night published no stage split. The half-widths come from
/// `stageIntervals`, which scales them by THIS night's own segmentation
/// confidence — a well-covered night gets a narrow range and one scraping the
/// observed floor gets a wide one. A missing confidence is the widest case, not
/// the narrowest: we do not know how well we saw the night, so we say the least.
({ana.StageInterval light, ana.StageInterval deep, ana.StageInterval rem})?
    _ranges(Map<String, dynamic> n) {
  final l = (n['light_min'] as num?)?.round();
  final d = (n['deep_min'] as num?)?.round();
  final r = (n['rem_min'] as num?)?.round();
  final t = (n['duration_min'] as num?)?.round();
  if (l == null || d == null || r == null || t == null) return null;
  return ana.stageIntervals(
    lightSec: l * 60,
    deepSec: d * 60,
    remSec: r * 60,
    tstSec: t * 60,
    confidence: (n['stages_confidence'] as num?)?.toDouble() ?? 0.0,
  );
}

/// A stage interval as one label. Seconds in, because that is what the analytics
/// interval carries; `hm` wants minutes.
String _rangeText(ana.StageInterval i) =>
    '${hm(i.loSec / 60)}–${hm(i.hiSec / 60)}';

String _capitalise(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class SleepData {
  final String? day;

  /// Every day this install has derived, newest first — what [DayNav] steers
  /// over. Empty in a fixture, which is why a golden shows no stepper.
  final List<String> days;

  final Map<String, dynamic> night;
  final Map<String, dynamic> timeline;
  final Metric need, debt, bedtime;

  /// The user's own recent nights, LAST NIGHT EXCLUDED, oldest→newest. Minutes
  /// for duration and deep, whole percent for efficiency, epoch seconds for
  /// onset. Empty until enough nights exist, which the screen renders as a
  /// [StatusCard] rather than as a comparison against nothing.
  final List<double> tstHistory, deepHistory, effHistory;
  final List<int> onsetHistory;

  /// The shape of last night, as the pipeline published it to `metric_series`.
  /// Not recomputed here: `_sleepRuns` in `onehz_pipeline.dart` owns where a run
  /// ends, and a second definition on this screen is how the hypnogram and the
  /// sentence under it start disagreeing.
  ///
  ///   * [unobservedMin] — minutes of the in-bed window nobody watched.
  ///   * [awakenings] — sustained wake runs, a FLOOR, never a total.
  ///   * [longestSleepMin] — the longest unbroken stretch; never bridges a hole.
  ///   * [solMin] — sleep-onset latency, and ONLY on a user-set window.
  final double? unobservedMin, awakenings, longestSleepMin, solMin;

  const SleepData({
    this.day,
    this.days = const [],
    this.night = const {},
    this.timeline = const {},
    this.need = Metric.empty,
    this.debt = Metric.empty,
    this.bedtime = Metric.empty,
    this.tstHistory = const [],
    this.deepHistory = const [],
    this.effHistory = const [],
    this.onsetHistory = const [],
    this.unobservedMin,
    this.awakenings,
    this.longestSleepMin,
    this.solMin,
  });

  bool get hasNight => night['duration_min'] is num;

  /// Stage samples for the painter — the segment list resampled onto a fixed
  /// number of columns so a four-hour segment and a four-minute one stay in
  /// proportion.
  List<SleepStage?> get stages {
    final pts = night['hypnogram'];
    if (pts is! List || pts.length < 2) return const [];
    final ts = <int>[], st = <SleepStage?>[];
    for (final e in pts) {
      if (e is Map && e['t'] is num) {
        ts.add((e['t'] as num).round());
        st.add(_stageOf(e['stage']));
      }
    }
    if (ts.length < 2) return const [];
    final t0 = ts.first, t1 = ts.last;
    if (t1 <= t0) return const [];
    const cols = 240;
    return [
      for (var i = 0; i < cols; i++)
        st[_indexAt(ts, t0 + ((t1 - t0) * i / cols).round())],
    ];
  }

  static int _indexAt(List<int> ts, int t) {
    var lo = 0;
    for (var i = 0; i < ts.length; i++) {
      if (ts[i] <= t) lo = i;
    }
    return lo;
  }

  /// The trailing [_window] values of a stored scalar series, with any point
  /// dated on or after [cut] dropped.
  static List<double> _trailing(Object? chart, int? cut, {double scale = 1}) {
    final pts = [
      for (final p in pointsOf(chart))
        if (cut == null || p.t < cut) p.v * scale,
    ];
    return pts.length <= _window ? pts : pts.sublist(pts.length - _window);
  }

  /// One stored scalar for ONE day. `metric_series` stamps a day at local noon,
  /// which is exactly what [_noonOf] builds, so this is an equality match rather
  /// than a nearest-point search.
  static double? _on(Object? chart, int? noon) {
    if (noon == null) return null;
    for (final p in pointsOf(chart)) {
      if (p.t == noon) return p.v;
    }
    return null;
  }

  static Future<SleepData> load(LocalRepository repo, {String? want}) async {
    final today = await repo.getToday();
    // THE NIGHT `getToday` ACTUALLY SERVED. Home's Sleep card is that night, so
    // tapping it has to open that night. Resolving on `today_day` alone opened
    // a day that has a day_result but no night — wear the band all day with it
    // off overnight and the card said "7h 04m" while this screen answered "No
    // night to show" about the same tap.
    final days = await repo.availableDays();
    final day = pickDay(
        days,
        want,
        heldOverNightOf(today) ??
            (today['status'] as Map?)?['today_day']?.toString());
    if (day == null) return SleepData(days: days);

    final night = await repo.getDaySleepV2(day);
    final timeline = await repo.getDayTimeline(day);
    final cd = await repo.getInsights();
    final coach = cd['sleep_coach'];
    final needEnv = coach is Map ? coach['need'] : null;
    final needSec = envValue(needEnv)?['need_sec'] as num?;
    final debtEnv = cd['sleep_debt'];
    final debtH = envValue(debtEnv)?['debt_hours'] as num?;
    final bedEnv = coach is Map ? coach['bedtime'] : null;

    // Personal history for the comparisons. These are `metric_series` reads —
    // one small row per day per key — not day bundles, so the whole comparison
    // costs three scalar queries and one window query rather than 28 payload
    // decodes.
    final cut = _noonOf(day);
    final tst = _trailing(await repo.getChart('sleep'), cut);
    final deep = _trailing(await repo.getChart('deep'), cut);
    // Stored as whole percent; the night's own `efficiency` is 0…1.
    final eff = _trailing(await repo.getChart('efficiency'), cut);
    // The shape of THIS night. Four scalar series, read for one day each — the
    // day bundle's `accounting` carries the same figures but `_daySleep` does
    // not re-export them, and metric_series is one row per day per key.
    final unobserved = _on(await repo.getChart('unobserved_min'), cut);
    final wakeups = _on(await repo.getChart('awakenings'), cut);
    final longest = _on(await repo.getChart('longest_sleep_min'), cut);
    final sol = _on(await repo.getChart('sol_min'), cut);
    final wins = await repo.sleepWindows(days: _window + 1);
    final onsets = <int>[
      for (final w in wins.reversed)
        if (w['date'] != day && w['onset_ts'] is num) (w['onset_ts'] as num).round(),
    ];

    return SleepData(
      day: day,
      days: days,
      night: night,
      timeline: timeline,
      need: envMetric(needEnv, needSec == null ? null : needSec / 60, unit: 'min'),
      debt: envMetric(debtEnv, debtH == null ? null : debtH * 60, unit: 'min'),
      bedtime:
          envMetric(bedEnv, envValue(bedEnv)?['bedtime_min_of_day'] as num?),
      tstHistory: tst,
      deepHistory: deep,
      effHistory: eff,
      onsetHistory: onsets,
      unobservedMin: unobserved,
      awakenings: wakeups,
      longestSleepMin: longest,
      solMin: sol,
    );
  }
}

class SleepDetail extends StatefulWidget {
  final SleepData? data;

  /// The night to open. Null means last night — which is what every caller
  /// passed before this existed and what the stepper starts from.
  final String? day;

  const SleepDetail({super.key, this.data, this.day});

  @override
  State<SleepDetail> createState() => _SleepDetailState();
}

class _SleepDetailState extends State<SleepDetail> {
  SleepData? _d;
  bool _loading = true;
  String? _day;
  bool _saving = false; // an override write + its forced re-derive is in flight
  double? _scrub; // 0..1 across the night

  /// Why the last correction did not take. Null when it did.
  String? _overrideFailed;

  /// Last night's state against the user's own nights, when it was rough enough
  /// to say so and has not been dismissed. See `rough_night.dart` — it REPLACES
  /// the elevated-sleeping-HR card rather than joining it, so one night can
  /// never read as two observations.
  RoughNight? _rough;

  @override
  void initState() {
    super.initState();
    _day = widget.day;
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  // `_rough` bakes `AppLocalizations` strings into `knows`/`moved` at load
  // time (see `loadRoughNight`), so a language switch while this screen is
  // alive would otherwise leave the rough-night card showing the old locale
  // until the user steps to another day. Sentinel so the system-default
  // locale (`code == null`) is not mistaken for "never seen yet" on the first
  // pass — same fix as `RevisionReload`/`DayTimelineScreen`.
  static const Object _localeUnset = Object();
  Object? _seenLocale = _localeUnset;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Object localeKey;
    try {
      final code = context.watch<LocaleController>().code;
      localeKey = code ?? Localizations.localeOf(context);
    } catch (_) {
      return;
    }
    if (identical(_seenLocale, _localeUnset)) {
      _seenLocale = localeKey;
    } else if (_seenLocale != localeKey && widget.data == null) {
      _seenLocale = localeKey;
      _load();
    }
  }

  // A locale change and `_goDay` can each kick off a `_load()` while a prior
  // one is still in flight; whichever resolves last would otherwise win and
  // could paint the wrong night. Stamp each call and only apply the result
  // still holding the latest stamp.
  int _loadGen = 0;

  Future<void> _load() async {
    final gen = ++_loadGen;
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
      return;
    }
    try {
      final d = await SleepData.load(repo, want: _day);
      // LAST NIGHT ONLY. The card names the luteal phase, and `getCycle` knows
      // today's phase and no other day's — so a card offered while stepping
      // back through the record would either drop that half or invent it.
      // Stepping back is also not the moment to ask about a night, which is the
      // stronger half of the reason.
      final rough = d.day == todayLabel() &&
              Prefs.getString(kRoughNightDismissed, '') != d.day
          ? await loadRoughNight(repo, d.day!, c: mounted ? context : null)
          : null;
      if (mounted && gen == _loadGen) {
        setState(() => (_d = d, _rough = rough, _loading = false));
      }
    } catch (_) {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  /// Another night. The scrub cursor belongs to the night it was placed on, so
  /// it goes with it.
  void _goDay(String day) {
    setState(() {
      _day = day;
      _scrub = null;
      _loading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext c) {
    final d = _d ?? const SleepData();
    final l = AppLocalizations.of(c);
    final title = l?.sleepDetailNavTitle ?? 'Sleep';

    if (_loading && _d == null) {
      return detailScaffold(c, title, const [
        SizedBox(height: S.x8),
        Center(child: CircularProgressIndicator()),
      ]);
    }

    if (!d.hasNight) {
      // "No night" also covers a night the user REJECTED outright (edge#248):
      // staging was skipped on purpose, so this day has no window at all — but
      // that must stay reversible the same way any other override is.
      final rejectedDay = d.day;
      final rejected =
          (d.night['sleep_source'] as String?) == 'rejected' && rejectedDay != null;
      return detailScaffold(c, title, [
        ...dayNavRow(_day ?? d.day, d.days, _goDay),
        const SizedBox(height: S.x2),
        // A day CAN be in `availableDays` and still hold no night — the band
        // was worn through the day and off overnight. Stepping onto one of
        // those says so and leaves the stepper above it, so it is a day you
        // walk off rather than a dead end.
        StatusCard(
          rejected
              ? (l?.sleepDetailRejectedTitle ?? 'Marked as not sleep')
              : (l?.sleepDetailNoNightTitle ?? 'No night to show'),
          rejected
              ? (l?.sleepDetailRejectedBody ??
                  'You told us this stretch was not sleep, so nothing is '
                      'scored for it.')
              : (l?.sleepDetailNoNightBody ??
                  'No stretch of band recordings long enough to score.'),
          fix: rejected ? '' : (l?.sleepDetailNoNightFix ??
              'Wear the band overnight and sync in the morning'),
          icon: rejected ? LucideIcons.undo2 : LucideIcons.moon,
        ),
        if (rejected) ...[
          const SizedBox(height: S.x2),
          TextButton(
            onPressed: _saving ? null : () => _clearWindow(rejectedDay),
            child: Text(
                l?.sleepDetailUndoRejection ?? 'Undo — go back to automatic'),
          ),
        ],
      ]);
    }

    final p = P.of(c);
    final n = d.night;
    final unusual = _unusual(c, p, d, n);

    // The stepper names the night, so the nav bar does not say it twice. With
    // one night on disk there is no stepper, and then the subtitle is the only
    // thing that dates the screen.
    return detailScaffold(c, title,
        sub: d.days.length < 2 ? (d.day ?? '').toUpperCase() : '', [
      ...dayNavRow(_day ?? d.day, d.days, _goDay),

      // ── 1 · THE ANSWER ──
      _answer(c, p, d, n),

      // ── 2 · THE NIGHT ITSELF ──
      const SizedBox(height: S.x3),
      _night(c, p, d, n),
      if (_scrub != null) _scrubCard(c, p, d),

      // ── 2b · WHOSE WINDOW IS THIS ──
      ...?_windowCard(c, p, d, n),

      // ── 3 · WHAT IT WAS MADE OF ──
      Section(l?.sleepDetailStagesSection ?? 'Stages', _stages(c, p, n)),

      // ── 4 · AGAINST THE USER'S OWN NIGHTS ──
      if (_versusUsual(c, p, d, n) case final versus?)
        Section(l?.sleepDetailVersusUsualSection ?? 'Against your usual', versus),

      // ── 5 · WHAT STOOD OUT ──
      // Named after the night the nav bar is already showing. "Unusual last
      // night — Nothing stood out." is a present-tense all-clear, and it was
      // printed over a night that could be days old.
      if (unusual != null)
        Section(
            (daysBehind(_noonOf(d.day)) ?? 0) <= 0
                ? (l?.sleepDetailUnusualLastNight ?? 'Unusual last night')
                : (l?.sleepDetailUnusualOnDay(prettyDay(d.day, l)) ??
                    'Unusual on ${prettyDay(d.day, l)}'),
            unusual),

      // ── 6 · THE SIGNALS UNDERNEATH ──
      Section(l?.sleepDetailOvernightSection ?? 'Overnight signals',
          _overnight(c, p, d)),

      // ── 7 · ONE TAKEAWAY ──
      Section(l?.sleepDetailTonightSection ?? 'Tonight', _tonight(c, p, d)),

      const SizedBox(height: S.x5),
      // The night this screen is steered to, not the newest one. Dropping it
      // meant stepping back to Tuesday and then tapping Nerd stats landed
      // on last night — the same numbers every time, whichever day you
      // came from.
      investigateRow(
          c, () => go(c, Investigate('sleep', day: _day ?? d.day))),
    ]);
  }

  /// Total sleep, when it ran, and the two ratios that qualify it. Everything
  /// here is measured; nothing is a judgement.
  Widget _answer(BuildContext c, P p, SleepData d, Map<String, dynamic> n) {
    final l = AppLocalizations.of(c);
    final tst = n['duration_min'] as num?;
    final eff = n['efficiency'] as num?;
    final inBed = n['in_bed_min'] as num?;
    final from = clockOfTs(n['onset_ts'] as num?);
    final to = clockOfTs(n['wake_ts'] as num?);
    // Wall clock minus the minutes nobody watched. `efficiency_pct` has always
    // divided by this, so on a night with a hole the honest denominator just
    // read as a worse night unless the screen says which window it is.
    final unobserved = d.unobservedMin;
    final watched = (inBed == null || unobserved == null || unobserved <= 0)
        ? null
        : math.max(0, inBed - unobserved);
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hm(tst), style: F.n48.copyWith(color: p.ink)),
        const SizedBox(height: S.x1),
        Text(l?.sleepDetailTotalSleep ?? 'Total sleep',
            style: F.cap.copyWith(color: p.ink3)),
        if (from.isNotEmpty && to.isNotEmpty) ...[
          const SizedBox(height: S.x4),
          Row(children: [
            Icon(LucideIcons.moon, size: 15, color: p.ink3),
            const SizedBox(width: S.x2),
            Flexible(
              child: Text('$from → $to',
                  style: F.body
                      .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
            ),
          ]),
        ],
        if (inBed != null || eff != null) ...[
          const SizedBox(height: S.x4),
          InlineMetrics([
            if (inBed != null) (l?.sleepDetailInBed ?? 'IN BED', hm(inBed), C.indigo),
            if (watched != null)
              (l?.sleepDetailWatched ?? 'WATCHED', hm(watched), C.sky),
            if (eff != null)
              (watched == null
                  ? (l?.sleepDetailAsleepOfThat ?? 'ASLEEP OF THAT')
                  : (l?.sleepDetailAsleep ?? 'ASLEEP'),
                  _pct(eff * 100), C.green),
          ]),
        ],
        if (watched != null) ...[
          const SizedBox(height: S.x3),
          Text(
            l?.sleepDetailWatchedExplain(hm(watched), hm(inBed!)) ??
                'We watched ${hm(watched)} of your ${hm(inBed!)} in bed; the rest '
                    'is not a measurement. Asleep, and the stage shares below, are out '
                    'of the time we watched.',
            style: F.over.copyWith(color: p.ink3, height: 1.5),
          ),
        ],
      ]),
    );
  }

  /// Where this night's window came from, and the user's say over it.
  ///
  /// `sleep_source` has been on the day bundle all along — 'auto' (staged from
  /// the signals), 'auto_fallback' (the HR-led guess staging falls back to when
  /// it cannot find the edges), 'manual' / 'confirmed' (the user's own). The
  /// repository comment already said it "drives the Sleep screen's confirm
  /// prompt + edit affordance"; nothing did, and `sleep_override` had no writer
  /// anywhere in the app, so the derive engine's user-window restage path could
  /// never run and a mis-staged night was uncorrectable.
  ///
  /// Naps have their own screen and their own table (`sleep_nap`, with a real
  /// writer — `LocalDb.putNapEdit`/`deleteNapEdit`), reached from the Health
  /// screen's nap row. They are not folded into this card: a night's window
  /// is one thing you either confirm or move, naps are a list you add to and
  /// remove from, and `_editWindow` below only ever asks two time pickers for
  /// one pair of times — the wrong shape for "how many, which ones".
  List<Widget>? _windowCard(
      BuildContext c, P p, SleepData d, Map<String, dynamic> n) {
    final l = AppLocalizations.of(c);
    final day = d.day;
    final t0 = (n['onset_ts'] as num?)?.round();
    final t1 = (n['wake_ts'] as num?)?.round();
    if (day == null || t0 == null || t1 == null) return null;
    final source = (n['sleep_source'] as String?) ?? 'auto';
    final mine = source == 'manual' || source == 'confirmed';
    final fallback = source == 'auto_fallback';

    final busy = _saving;
    return [
      const SizedBox(height: S.x3),
      Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(mine ? LucideIcons.userCheck : LucideIcons.wandSparkles,
                size: 16, color: p.ink3),
            const SizedBox(width: S.x2),
            Expanded(
              child: Text(
                mine
                    ? (l?.sleepDetailWindowMine ?? 'You set this window')
                    : fallback
                        ? (l?.sleepDetailWindowFallback ??
                            'This window was inferred from heart rate')
                        : (l?.sleepDetailWindowAuto ??
                            'This window was staged from the signals'),
                style: F.body.copyWith(color: p.ink),
              ),
            ),
          ]),
          if (fallback) ...[
            const SizedBox(height: S.x2),
            Text(
              l?.sleepDetailWindowFallbackBody ??
                  'Staging could not find the edges, so the times are a best '
                      'guess.',
              style: F.cap.copyWith(color: p.ink3),
            ),
          ],
          // SLP-02 — settling time, and ONLY here. On the auto path the window
          // is built from stillness gated on a sleep-ish heart rate, so it
          // cannot begin before you are already lying quiet: the 40 minutes of
          // tossing falls outside it and the latency would come out near zero.
          // On a window the user asserted, the number means what people think
          // it means. The pipeline abstains for both reasons; this only draws
          // what it published.
          if (mine && d.solMin != null) ...[
            const SizedBox(height: S.x2),
            Text(
              l?.sleepDetailWindowSol(_solBand(c, d.solMin!)) ??
                  'From the start of your window to asleep: '
                      '${_solBand(c, d.solMin!)}.',
              style: F.cap.copyWith(color: p.ink3),
            ),
          ],
          const SizedBox(height: S.x2),
          Wrap(spacing: S.x2, children: [
            if (fallback)
              TextButton(
                onPressed: busy ? null : () => _confirmWindow(day),
                child: Text(l?.sleepDetailConfirmTimes ?? 'These times are right'),
              ),
            TextButton(
              onPressed: busy ? null : () => _editWindow(day, t0, t1),
              child: Text(mine
                  ? (l?.sleepDetailChangeTimes ?? 'Change the times')
                  : (l?.sleepDetailSetTimesMyself ?? 'Set the times myself')),
            ),
            if (mine)
              TextButton(
                onPressed: busy ? null : () => _clearWindow(day),
                child:
                    Text(l?.sleepDetailBackToAutomatic ?? 'Back to automatic'),
              ),
            // The missing third answer next to "Looks right"/"Edit": naps
            // already have a reject action (sleep_nap source='rejected');
            // a whole-night main-sleep session didn't (edge#248).
            TextButton(
              onPressed: busy ? null : () => _rejectWindow(day),
              child: Text(l?.sleepDetailNotSleep ?? 'Not sleep'),
            ),
            // Naps live on their own screen with their own writer; this is
            // the door to it from the night someone is already looking at.
            TextButton(
              onPressed: busy ? null : () => go(c, NapsScreen(day: day)),
              child: Text(l?.sleepDetailEditNaps ?? 'Naps'),
            ),
          ]),
          if (busy) ...[
            const SizedBox(height: S.x2),
            Text(l?.sleepDetailReanalysing ?? 'Re-analysing the night…',
                style: F.cap.copyWith(color: p.ink3)),
          ],
          if (!busy && _overrideFailed != null) ...[
            const SizedBox(height: S.x3),
            StatusCard(
              l?.sleepDetailCorrectionFailedTitle ??
                  'That correction has not been applied',
              _overrideFailed!,
              icon: LucideIcons.triangleAlert,
            ),
          ],
        ]),
      ),
    ];
  }

  Future<void> _confirmWindow(String day) =>
      _runOverride(() => context.read<AppState>().confirmSleep(day));

  Future<void> _clearWindow(String day) =>
      _runOverride(() => context.read<AppState>().clearSleepOverride(day));

  Future<void> _rejectWindow(String day) =>
      _runOverride(() => context.read<AppState>().rejectSleep(day));

  /// Two pickers, seeded from the window we already have — the user is
  /// correcting times, not entering a date, so the DATES stay as measured and
  /// only the clock moves. A wake that lands before the onset belongs to the
  /// next morning.
  Future<void> _editWindow(String day, int t0, int t1) async {
    final onset = DateTime.fromMillisecondsSinceEpoch(t0 * 1000);
    final wake = DateTime.fromMillisecondsSinceEpoch(t1 * 1000);
    final l = AppLocalizations.of(context);
    final bed = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(onset),
      helpText: l?.sleepDetailBedTimeHelp ?? 'WHEN YOU GOT INTO BED',
    );
    if (bed == null || !mounted) return;
    final up = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(wake),
      helpText: l?.sleepDetailWakeTimeHelp ?? 'WHEN YOU GOT UP',
    );
    if (up == null || !mounted) return;
    final newOnset =
        DateTime(onset.year, onset.month, onset.day, bed.hour, bed.minute);
    // A wake at or before the onset is the next morning. `day + 1` rather than
    // adding a Duration: DateTime normalises the overflow, and it is calendar
    // arithmetic across a possible DST boundary, not a span of elapsed time.
    var newWake =
        DateTime(onset.year, onset.month, onset.day, up.hour, up.minute);
    if (!newWake.isAfter(newOnset)) {
      newWake = DateTime(
          onset.year, onset.month, onset.day + 1, up.hour, up.minute);
    }
    await _runOverride(
      () => context.read<AppState>().setSleepOverride(day, newOnset, newWake),
    );
  }

  /// Every override path is the same shape: write it, wait for the forced
  /// re-derive, then reload the screen from what the engine produced. The
  /// screen must not keep drawing the old night's numbers under a new window.
  Future<void> _runOverride(Future<void> Function() write) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _overrideFailed = null;
    });
    String? failed;
    try {
      await write();
    } catch (e) {
      failed = '$e';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    final before = _source;
    if (mounted) await _load();
    if (!mounted) return;
    // EVERY failure below this screen is silent: the forced re-derive catches
    // and logs its own throw, and it returns at its first line when another
    // re-analysis is already running. Both leave the write in the database and
    // the night on screen unchanged — indistinguishable from a correction that
    // worked, which is how a rejected one got dropped without a word. The
    // window's source changes on all three actions, so an unchanged source
    // means nothing was restaged.
    if (failed != null || _source == before) {
      final l = AppLocalizations.of(context);
      setState(() => _overrideFailed = failed ??
          l?.sleepDetailReanalyseFailed ??
          'The night was not re-analysed — another re-analysis was already '
              'running, or it failed. The times you set are saved; '
              'Re-analyze everything on Your data applies them.');
    }
  }

  /// Where the drawn window came from: 'auto', 'auto_fallback', 'manual' or
  /// 'confirmed'.
  String? get _source => (_d?.night['sleep_source'] as String?) ?? 'auto';

  /// The hypnogram, as the centrepiece rather than as an illustration. The
  /// cycle count rides underneath it because it is a property of this shape,
  /// not a section of its own.
  Widget _night(BuildContext c, P p, SleepData d, Map<String, dynamic> n) {
    final l = AppLocalizations.of(c);
    final stages = d.stages;
    if (stages.isEmpty) {
      return StatusCard(
        l?.sleepDetailNoHypnogramTitle ?? 'No hypnogram for this night',
        l?.sleepDetailNoHypnogramBody ??
            'Staging needs movement and beat timing. One was missing.',
        icon: LucideIcons.chartNoAxesColumn,
      );
    }
    final t0 = (n['onset_ts'] as num?)?.round();
    final t1 = (n['wake_ts'] as num?)?.round();
    final cycles = (n['cycle_count'] as num?)?.toInt() ?? 0;
    final mean = n['cycles_mean_min'] as num?;
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ChartFrame(
          title: l?.sleepDetailThroughTheNight ?? 'Through the night',
          unit: l?.sleepDetailUnitStage ?? 'stage',
          height: 132,
          xLabels: [
            clockOfTs(t0),
            if (t0 != null && t1 != null && t1 > t0)
              clockOfTs(t0 + (t1 - t0) ~/ 2),
            clockOfTs(t1),
          ],
          // Driven by the night, not by the enum: a night with no REM in
          // it used to still print REM in its key.
          legend: [
            for (final e in Hypnogram.legend(p))
              if (stages.any((s) => s?.label == e.$1)) e,
          ],
          child: _hypnogram(c, p, stages, n),
        ),
        const SizedBox(height: S.x2),
        Text(
          cycles > 0
              ? (mean == null
                  ? (l?.sleepDetailTapDragCycles(cycles) ??
                      'Tap or drag the chart for any moment. $cycles '
                          '${cycles == 1 ? 'cycle' : 'cycles'}.')
                  : (l?.sleepDetailTapDragCyclesAvg(cycles, hm(mean)) ??
                      'Tap or drag the chart for any moment. $cycles '
                          '${cycles == 1 ? 'cycle' : 'cycles'}, ${hm(mean)} '
                          'on average.'))
              : (l?.sleepDetailTapDragNone ??
                  'Tap or drag the chart for any moment of the night.'),
          style: F.over.copyWith(color: p.ink3, height: 1.5),
        ),
        if (_shape(c, d) case final shape?) ...[
          const SizedBox(height: S.x2),
          Text(shape, style: F.over.copyWith(color: p.ink3, height: 1.5)),
        ],
      ]),
    );
  }

  /// The shape of the night in one line — how broken it was, and the longest
  /// piece of it. Null when the pipeline published neither.
  ///
  /// The count is a FLOOR and says so: our stager sees sustained wake, and the
  /// 3-15 s cortical arousals a PSG counts are invisible to a 1 Hz wrist, so the
  /// true number is higher than this one. Five minutes is a choice, not
  /// physiology, so it is stated rather than assumed. No arousal index, no
  /// explanation, only the shape.
  String? _shape(BuildContext c, SleepData d) {
    final l = AppLocalizations.of(c);
    final w = d.awakenings?.round();
    final longest = d.longestSleepMin;
    final parts = [
      if (w != null)
        w == 0
            ? (l?.sleepDetailNoWakeups ??
                'No wake-ups of 5 minutes or more; shorter ones are invisible to '
                    'a wrist.')
            : (l?.sleepDetailAtLeastWakeups(w) ??
                'At least $w wake-up${w == 1 ? '' : 's'} of 5 minutes or more; '
                    'shorter ones are invisible to a wrist.'),
      if (longest != null)
        l?.sleepDetailLongestStretch(hm(longest)) ??
            'Longest unbroken stretch ${hm(longest)}.',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// The night split into stretches we watched and holes we did not:
  /// `(stages, columns)`, where a null stage list is time the band was not
  /// recording and is drawn as NOTHING.
  ///
  /// A gap is the only honest mark for "not a measurement". There is no fifth
  /// lane and there should not be one — a lane is a stage, and this is the
  /// absence of one.
  static List<(List<SleepStage>?, int)> _runs(List<SleepStage?> st) {
    final out = <(List<SleepStage>?, int)>[];
    var i = 0;
    while (i < st.length) {
      var j = i;
      while (j + 1 < st.length && (st[j + 1] == null) == (st[i] == null)) {
        j++;
      }
      out.add(st[i] == null
          ? (null, j - i + 1)
          : (st.sublist(i, j + 1).cast<SleepStage>(), j - i + 1));
      i = j + 1;
    }
    return out;
  }

  /// A [Scrubber], not a drag gesture: what matters is where the pointer IS,
  /// and the 44 pt tap rule does not apply to a continuous readout. What DOES
  /// apply is that the readout has to exist without a pointer — [Scrubber]
  /// carries the slider role and speaks [describe] at each step.
  Widget _hypnogram(BuildContext c, P p, List<SleepStage?> stages,
          Map<String, dynamic> n) =>
      Scrubber(
        value: _scrub,
        onChanged: (v) => setState(() => _scrub = v),
        label: AppLocalizations.of(c)?.sleepDetailHypnogramLabel ?? 'Hypnogram',
        describe: (v) {
          final l = AppLocalizations.of(c);
          final t0 = (n['onset_ts'] as num?)?.toInt();
          final t1 = (n['wake_ts'] as num?)?.toInt();
          final st = stages.isEmpty
              ? null
              : stages[(v * (stages.length - 1)).round().clamp(0, stages.length - 1)];
          final at = (t0 == null || t1 == null || t1 <= t0)
              ? (l?.sleepDetailPercentThroughNight((v * 100).round()) ??
                  '${(v * 100).round()}% through the night')
              : clockOfTs(t0 + ((t1 - t0) * v).round());
          final stageName = st == null
              ? (l?.sleepDetailNotMeasured ?? 'not measured')
              : _stageName(c, st);
          return l?.sleepDetailScrubAt(at, stageName) ?? '$at, $stageName';
        },
        child: SizedBox(
          height: 132,
          child: Stack(children: [
            // One painter per watched stretch, laid out by its width in
            // columns, with nothing at all where the band was not recording.
            // Every painter gets the same height, so the four lanes stay on the
            // same four lines across the whole night.
            Row(children: [
              for (final (st, cols) in _runs(stages))
                Expanded(
                  flex: cols,
                  child: st == null
                      ? const SizedBox.expand()
                      : CustomPaint(
                          size: Size.infinite,
                          painter: Hypnogram(st, p, t: animate(c, 1))),
                ),
            ]),
            if (_scrub != null)
              // Aligned by fraction rather than by a measured offset, so the
              // cursor needs no width from the layout.
              Align(
                alignment: Alignment(_scrub! * 2 - 1, 0),
                child: SizedBox(width: 2, height: double.infinity,
                    child: ColoredBox(color: p.ink)),
              ),
          ]),
        ),
      );

  /// What every signal read at the scrubbed instant. Each line abstains on its
  /// own — a night with no respiration series still shows heart rate.
  Widget _scrubCard(BuildContext c, P p, SleepData d) {
    final l = AppLocalizations.of(c);
    final n = d.night;
    final t0 = (n['onset_ts'] as num?)?.toInt();
    final t1 = (n['wake_ts'] as num?)?.toInt();
    if (t0 == null || t1 == null || t1 <= t0) return const SizedBox.shrink();
    final t = t0 + ((t1 - t0) * _scrub!).round();

    num? at(String key) {
      final list = d.timeline[key];
      if (list is! List) return null;
      num? best;
      var bestGap = 1 << 30;
      for (final e in list) {
        if (e is Map && e['t'] is num && e['v'] is num) {
          final gap = ((e['t'] as num).round() - t).abs();
          if (gap < bestGap) {
            bestGap = gap;
            best = e['v'] as num;
          }
        }
      }
      return bestGap > 900 ? null : best;
    }

    final stages = d.stages;
    final stage = stages.isEmpty
        ? null
        : stages[(_scrub! * (stages.length - 1)).round()];
    final items = <(String, String, Color)>[
      if (at('hr') != null)
        (l?.sleepDetailHeartRate ?? 'Heart rate', '${at('hr')!.round()} bpm', C.red),
      if (at('hrv') != null)
        (l?.sleepDetailHrv ?? 'HRV', '${at('hrv')!.round()} ms', C.green),
      if (at('resp') != null)
        (l?.sleepDetailBreathing ?? 'Breathing',
            '${at('resp')!.toStringAsFixed(1)} br/min', C.teal),
      if (at('skin_temp') != null)
        (l?.sleepDetailTemp ?? 'Temp', at('skin_temp')!.toStringAsFixed(2), C.orange),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Surface(
        color: p.card2,
        elevation: 0,
        child: Column(children: [
          Row(children: [
            Text(clockOfTs(t),
                style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (stage != null)
              Pill(_stageName(c, stage), Hypnogram.pigment[stage] ?? C.blue)
            else if (stages.isNotEmpty)
              // Not a stage, so not a Pill: this instant has no colour because
              // the band was not recording it.
              Text(l?.sleepDetailNotMeasuredCap ?? 'Not measured',
                  style: F.cap.copyWith(color: p.ink3)),
          ]),
          if (items.isEmpty) ...[
            const SizedBox(height: S.x3),
            Text(l?.sleepDetailNoSignalAtMoment ?? 'No signal recorded at this moment.',
                style: F.cap.copyWith(color: p.ink3)),
          ] else ...[
            const SizedBox(height: S.x4),
            InlineMetrics(items),
          ],
        ]),
      ),
    );
  }

  String _stageName(BuildContext c, SleepStage s) {
    final l = AppLocalizations.of(c);
    return switch (s) {
      SleepStage.awake => l?.sleepDetailStageAwake ?? 'Awake',
      SleepStage.rem => l?.sleepDetailStageRem ?? 'REM',
      SleepStage.light => l?.sleepDetailStageLight ?? 'Light sleep',
      SleepStage.deep => l?.sleepDetailStageDeep ?? 'Deep sleep',
    };
  }

  /// One stage of the night: a name and what it came to. The value is one
  /// string — the range for a staged figure, a plain duration for Awake — so
  /// the column has ONE right edge down the whole table. It is `Flexible`
  /// rather than fixed because "1h 15m–2h 30m" is twice the width the old
  /// minutes column was sized for; above the big-text threshold the row
  /// restacks rather than squeeze, exactly like [MetricRow].
  Widget _stageRow(BuildContext c, P p, (String, String, Color) s) {
    final dot = Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: s.$3, shape: BoxShape.circle));
    final name = Text(s.$1, style: F.body.copyWith(color: p.ink));
    final value = Text(s.$2,
        textAlign: TextAlign.right,
        style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w600));
    if (!bigText(c)) {
      return Row(children: [
        dot,
        const SizedBox(width: S.x3),
        Expanded(child: name),
        const SizedBox(width: S.x3),
        Flexible(child: value),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      dot,
      const SizedBox(width: S.x3),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          name,
          const SizedBox(height: S.x1),
          Text(s.$2, style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
        ]),
      ),
    ]);
  }

  /// SLP-13 — the stage block, as ranges.
  ///
  /// The share column is GONE and that is the point. A percentage is computed
  /// from the exact minute count, so printing "19%" beside "45m–1h 15m" would
  /// have restored, on the same row, the precision the range exists to retire.
  /// Nothing is lost that the range does not carry better.
  ///
  /// Awake keeps a single figure. It is not one of the three the overlay splits
  /// — asleep-versus-awake is a different decision with a different weakness,
  /// already stated where the awakening count is, and `stageIntervals` publishes
  /// no interval for it. Inventing one here would be exactly the fabricated
  /// precision this item removes.
  Widget _stages(BuildContext c, P p, Map<String, dynamic> n) {
    final l = AppLocalizations.of(c);
    final r = _ranges(n);
    final awake = n['awake_min'] as num?;
    final rows = <(String, String, Color)>[
      if (r != null) (l?.sleepDetailDeep ?? 'Deep', _rangeText(r.deep), C.blue),
      if (r != null) (l?.sleepDetailStageRem ?? 'REM', _rangeText(r.rem), C.teal),
      if (r != null) (l?.sleepDetailLight ?? 'Light', _rangeText(r.light), C.sky),
      if (awake != null)
        (l?.sleepDetailStageAwake ?? 'Awake', hm(awake), C.orange),
    ];
    if (rows.isEmpty) {
      return StatusCard(
        l?.sleepDetailNoStageSplitTitle ?? 'No stage split for this night',
        l?.sleepDetailNoStageSplitBody ??
            'No beat timing across the whole window.',
        icon: LucideIcons.chartNoAxesColumn,
      );
    }
    return Column(children: [
      Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: _stageRow(c, p, rows[i]),
            ),
          ],
        ]),
      ),
      if (r != null) ...[
        const SizedBox(height: S.x2),
        // The range IS the reading, and the copy says so straight. A wrist
        // infers stages from beat timing and movement; it does not count them.
        // The width is this night's own — better coverage, narrower range —
        // rather than one published figure applied to every night.
        Text(
            l?.sleepDetailStageRangeExplain ??
                'Each stage is a range, not a count — the better we saw the night, '
                    'the narrower it is. Deep is the widest. Awake stays one figure. '
                    'Nerd stats has the exact counts.',
            style: F.over.copyWith(color: p.ink3, height: 1.5)),
      ],
    ]);
  }

  // ── AGAINST YOUR USUAL ────────────────────────────────────────────────────

  /// The four comparisons that used to be five progress bars against invented
  /// denominators (`1 - waso/120`, `1 - sol/3600`) — numbers with no owner,
  /// which moved when nothing physiological had. Each row is now the user's own
  /// distribution: the middle half of their recent nights, and where last night
  /// landed in it.
  ///
  /// This section absorbs the separate "what was different" block a delta table
  /// would have been. Deltas and verdicts are the same comparison rendered
  /// twice; the strip IS the delta, the sentence beside it IS the verdict.
  Widget? _versusUsual(
      BuildContext c, P p, SleepData d, Map<String, dynamic> n) {
    final l = AppLocalizations.of(c);
    final rows = <Widget>[];

    final tst = (n['duration_min'] as num?)?.toDouble();
    if (tst != null) {
      rows.add(_Compare(
        label: l?.sleepDetailTimeAsleep ?? 'Time asleep',
        value: hm(tst),
        tonight: tst,
        history: d.tstHistory,
        color: C.indigo,
        low: l?.sleepDetailShorterThanUsual ?? 'shorter than usual',
        high: l?.sleepDetailLongerThanUsual ?? 'longer than usual',
        fmt: (v) => hm(v),
        dfmt: (v) => hm(v),
      ));
    }

    // SLP-13 — the deep row keeps its band but stops asserting a difference off
    // a figure the Stages card has just published as a range. `blur` is this
    // night's own half-width in minutes: the verdict only fires when the WHOLE
    // interval sits outside the band, and it drops the magnitude, because the
    // size of a gap between one fuzzy number and a band of fuzzy numbers is the
    // most confident thing on the card and the least supported.
    final deepRange = _ranges(n)?.deep;
    if (deepRange != null) {
      final deep = deepRange.pointSec / 60;
      rows.add(_Compare(
        label: l?.sleepDetailStageDeep ?? 'Deep sleep',
        value: _rangeText(deepRange),
        tonight: deep,
        blur: (deepRange.hiSec - deepRange.loSec) / 120,
        history: d.deepHistory,
        color: C.blue,
        low: l?.sleepDetailLessThanUsual ?? 'less than usual',
        high: l?.sleepDetailMoreThanUsual ?? 'more than usual',
        fmt: (v) => hm(v),
        dfmt: (v) => hm(v),
      ));
    }

    final eff = (n['efficiency'] as num?)?.toDouble();
    if (eff != null) {
      rows.add(_Compare(
        label: l?.sleepDetailAsleepWhileInBed ?? 'Asleep while in bed',
        value: _pct(eff * 100),
        tonight: eff * 100,
        history: d.effHistory,
        color: C.green,
        low: l?.sleepDetailLowerThanUsual ?? 'lower than usual',
        high: l?.sleepDetailHigherThanUsual ?? 'higher than usual',
        fmt: _pct,
        dfmt: _pts,
      ));
    }

    // Timing is measured on an axis anchored at last night's onset: every past
    // night becomes signed minutes relative to it, wrapped across midnight, so
    // 11:50 PM and 12:10 AM are twenty minutes apart rather than 23 hours. The
    // band edges are formatted back into clock times, which is the only form
    // anyone reads a bedtime in.
    final onset = (n['onset_ts'] as num?)?.round();
    if (onset != null && d.onsetHistory.isNotEmpty) {
      final rel = [for (final o in d.onsetHistory) _relMinutes(o, onset)];
      rows.add(_Compare(
        label: l?.sleepDetailFellAsleep ?? 'Fell asleep',
        value: clockOfTs(onset),
        tonight: 0,
        history: rel,
        color: C.purple,
        low: l?.sleepDetailEarlierThanUsual ?? 'earlier than usual',
        high: l?.sleepDetailLaterThanUsual ?? 'later than usual',
        fmt: (v) => clockOfTs(onset + (v * 60).round()),
        dfmt: (v) => hm(v),
      ));
    }

    final have = [
      d.tstHistory.length,
      d.deepHistory.length,
      d.effHistory.length,
      d.onsetHistory.length,
    ].reduce(math.max);

    // Title and the COUNT, no prose. The sentence about population averages
    // was slop; "3 of 7 nights so far" is the one thing on this card a user can
    // act on — it says the comparison is coming and when. Dropping the whole
    // card took the count with it.
    if (rows.isEmpty || have < _minNights) {
      return StatusCard(
        l?.sleepDetailNotEnoughNightsTitle ?? 'Not enough nights to compare',
        '',
        fix: l?.sleepDetailNightsSoFar(have, _minNights) ??
            '$have of $_minNights nights so far',
        icon: LucideIcons.chartNoAxesColumn,
      );
    }

    return Column(children: [
      Surface(
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: S.x5),
            rows[i],
          ],
        ]),
      ),
      const SizedBox(height: S.x2),
      Text(
          l?.sleepDetailBarExplain ??
              'The bar is the middle half of your own nights.',
          style: F.over.copyWith(color: p.ink3, height: 1.5)),
    ]);
  }

  /// Signed minutes from [ref] to [t], as times of day, wrapped to ±12 h.
  static double _relMinutes(int t, int ref) {
    final a = DateTime.fromMillisecondsSinceEpoch(t * 1000);
    final b = DateTime.fromMillisecondsSinceEpoch(ref * 1000);
    var diff = (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute);
    if (diff > 720) diff -= 1440;
    if (diff < -720) diff += 1440;
    return diff.toDouble();
  }

  // ── UNUSUAL ───────────────────────────────────────────────────────────────

  /// Only what genuinely stands out, and only against this user's own record.
  ///
  /// An extreme is a FACT — "the shortest night in your last 28" needs no
  /// threshold, no population norm and no model. Everything softer than an
  /// extreme is already visible one section up, where it belongs. When nothing
  /// qualifies, that is the answer and it is shown.
  Widget? _unusual(BuildContext c, P p, SleepData d, Map<String, dynamic> n) {
    final l = AppLocalizations.of(c);
    final items = <Widget>[];

    void extreme(
      double? v,
      List<double> hist,
      String noun,
      String lowLabel,
      String highLabel,
      String Function(double) fmt,
    ) {
      if (v == null || hist.length < _recordNights) return;
      final lo = hist.reduce(math.min), hi = hist.reduce(math.max);
      // Strictly beyond, not equal to. Stage minutes are whole minutes so ties
      // are ordinary, and a tie printed "less than any of your last 20 nights,
      // the lowest of which was 41m" — the claim and its evidence disagreeing
      // in one sentence.
      if (v < lo) {
        items.add(InsightCard(
            lowLabel,
            l?.sleepDetailLessThanAny(noun, fmt(v), hist.length, fmt(lo)) ??
                '$noun ${fmt(v)} — less than any of your last ${hist.length} '
                    'nights, the lowest of which was ${fmt(lo)}.',
            icon: LucideIcons.trendingDown,
            color: C.orange));
      } else if (v > hi) {
        items.add(InsightCard(
            highLabel,
            l?.sleepDetailMoreThanAny(noun, fmt(v), hist.length, fmt(hi)) ??
                '$noun ${fmt(v)} — more than any of your last ${hist.length} '
                    'nights, the highest of which was ${fmt(hi)}.',
            icon: LucideIcons.trendingUp,
            color: C.green));
      }
    }

    extreme(
        (n['duration_min'] as num?)?.toDouble(),
        d.tstHistory,
        l?.sleepDetailYouSlept ?? 'You slept',
        l?.sleepDetailShortestNightLately ?? 'Your shortest night lately',
        l?.sleepDetailLongestNightLately ?? 'Your longest night lately',
        hm);
    // SLP-13a — NO deep-sleep extreme. `segment.dart` emits
    // `deep_low_confidence` and calls the Light/Deep split unvalidated; ranking
    // last night's deep minutes against 28 other nights of the same unvalidated
    // split is the most confident wrong claim the screen could make. The row in
    // "Against your usual" stays, because a band is a distribution, not a
    // record claim.

    // Detection against the user's own resting baseline, never a diagnosis: a
    // sleeping heart rate this far above baseline is the signal the illness
    // watch is built on, and it is worth saying on the night it happens.
    // ONE CARD ABOUT THE NIGHT'S AUTONOMIC STATE, EVER.
    //
    // When the rough-night card is up it says everything this one says and
    // more, off a strictly harder gate: `elevated` is a flat baseline + 4 bpm
    // on one channel, the rough card needs two of four channels past their own
    // minimal detectable change on this person's scale. Showing both puts two
    // cards on one observation and the reader cannot tell they are one.
    final rough = _rough;
    if (rough != null) {
      items.add(RoughNightCard(
        night: rough,
        onDismiss: () => setState(() => _rough = null),
      ));
    }

    final noc = n['nocturnal'];
    final vsBase = noc is Map ? noc['vs_baseline_bpm'] as num? : null;
    if (rough == null &&
        noc is Map &&
        noc['elevated'] == true &&
        vsBase != null) {
      items.add(InsightCard(
        l?.sleepDetailSleepingHrHighTitle ?? 'Sleeping heart rate ran high',
        l?.sleepDetailSleepingHrHighBody(vsBase.toStringAsFixed(1)) ??
            '${vsBase.toStringAsFixed(1)} bpm above your own baseline. Common '
                'after alcohol, a late meal, a hard session or an infection '
                'starting — this is a measurement, not a diagnosis.',
        icon: LucideIcons.heartPulse,
        color: C.red,
      ));
    }

    if (items.isEmpty) {
      // Only claim "nothing unusual" once there is enough history to have
      // looked. Before that the section is absent rather than reassuring from
      // no evidence — and the section above has already said why.
      if (d.tstHistory.length < _recordNights) return null;
      return Surface(
        color: p.card2,
        elevation: 0,
        child: Row(children: [
          Icon(LucideIcons.check, size: 16, color: p.on(C.green)),
          const SizedBox(width: S.x3),
          Expanded(
            child: Text(l?.sleepDetailNothingStoodOut ?? 'Nothing stood out.',
                style: F.cap.copyWith(color: p.ink2, height: 1.5)),
          ),
        ]),
      );
    }

    return Column(children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(height: S.x3),
        items[i],
      ],
    ]);
  }

  // ── OVERNIGHT SIGNALS ─────────────────────────────────────────────────────

  Widget _overnight(BuildContext c, P p, SleepData d) {
    final loc = AppLocalizations.of(c);
    /// One lane as `(timestamp, value)`. The timestamp is the point — the
    /// signals arrive on different cadences.
    List<(int, double)> stamped(String key) {
      final l = d.timeline[key];
      if (l is! List) return const [];
      return [
        for (final e in l)
          if (e is Map && e['v'] is num && e['t'] is num)
            ((e['t'] as num).round(), (e['v'] as num).toDouble()),
      ];
    }

    final n = d.night;
    final hr = stamped('hr'),
        hrv = stamped('hrv'),
        resp = stamped('resp'),
        temp = stamped('skin_temp');
    final all = [...hr, ...hrv, ...resp, ...temp];

    // The night's own nocturnal summary — measured, and until now shown
    // nowhere on the screen that owns it.
    final noc = d.night['nocturnal'];
    final respV = (d.night['resp'] is Map)
        ? (d.night['resp'] as Map)['value'] as num?
        : null;
    // Three, not four: `InlineMetrics` divides the card evenly, and a fourth
    // column truncates "14.2 br/min" to "14.2 br/…" at 390 pt. The nocturnal
    // dip was the fourth and is the one number here that is a ratio of two
    // others rather than a reading of its own.
    final summary = <(String, String, Color)>[
      if (noc is Map && noc['sleeping_hr_avg'] != null)
        (loc?.sleepDetailSleepingHr ?? 'SLEEPING HR',
            '${noc['sleeping_hr_avg']} bpm', C.red),
      if (noc is Map && noc['sleeping_hr_min'] != null)
        (loc?.sleepDetailLowest ?? 'LOWEST', '${noc['sleeping_hr_min']} bpm',
            C.blue),
      if (respV != null)
        (loc?.sleepDetailBreathingCaps ?? 'BREATHING',
            '${respV.toStringAsFixed(1)} br/min', C.teal),
    ];

    if (all.isEmpty) {
      return summary.isEmpty
          ? _noOvernightLines(c)
          : Surface(child: InlineMetrics(summary));
    }

    // ONE grid for all lanes. `NightStack` reads index as instant, so lanes of
    // different lengths spread across the same width put different times under
    // one vertical slice — which is the entire premise of a stacked night view.
    // The window is the night the axis labels name, and the column count is the
    // densest lane, capped: past ~a column per pixel the extra buckets only add
    // holes.
    var t0 = (n['onset_ts'] as num?)?.round() ??
        all.map((e) => e.$1).reduce((a, b) => a < b ? a : b);
    var t1 = (n['wake_ts'] as num?)?.round() ??
        all.map((e) => e.$1).reduce((a, b) => a > b ? a : b);
    if (t1 <= t0) {
      t0 = all.map((e) => e.$1).reduce((a, b) => a < b ? a : b);
      t1 = all.map((e) => e.$1).reduce((a, b) => a > b ? a : b);
    }
    // The bucket width is set by the SPARSEST lane, not the densest.
    //
    // Heart rate is stored per minute and breathing and skin temperature per
    // five, so a grid sized to heart rate leaves four empty buckets between
    // every breathing sample — and an empty bucket is a HOLE, which the painter
    // correctly draws as a break. The breathing lane was therefore drawn as a
    // dotted line on every night the app has ever rendered, describing a sensor
    // dropout that never happened. Sizing the grid to the slowest lane makes
    // every lane continuous and costs the fast lane nothing a 330 pt chart
    // could have shown anyway. Lanes with almost nothing in them are excluded
    // from the vote (they really are sparse) and the floor keeps a stray short
    // lane from coarsening the whole night.
    //
    // The vote counts points INSIDE the window, not stored points. These lanes
    // are ALL-DAY curves — `hr_curve` at one a minute, `resp_day`/
    // `skin_temp_day` at one per five — so voting on their total length picked
    // ~385 columns from the 24 h heart-rate lane and left the 5-min lanes with
    // a hole in three buckets out of four, on every normal night.
    int inWindow(List<(int, double)> l) {
      var n = 0;
      for (final (t, _) in l) {
        if (t >= t0 && t <= t1) n++;
      }
      return n;
    }

    final lens = [
      for (final l in [hr, hrv, resp, temp])
        if (inWindow(l) >= 8) inWindow(l),
    ];
    // The floor is the admission threshold, not 60: a lane admitted with 48
    // in-window samples was still stretched over 60 buckets and drawn broken.
    final cols = t1 <= t0
        ? 0
        : lens.isEmpty
            ? 2
            : lens.reduce(math.min).clamp(8, 480);

    /// Bucket mean per column; null where the lane has nothing in that
    /// bucket. A null is a HOLE — the painter breaks the line rather than
    /// drawing across a gap the data never covered.
    List<double?> grid(List<(int, double)> v) {
      final sum = List<double>.filled(cols, 0), cnt = List<int>.filled(cols, 0);
      for (final (t, x) in v) {
        if (t < t0 || t > t1) continue;
        final i = (((t - t0) / (t1 - t0)) * (cols - 1)).round().clamp(0, cols - 1);
        sum[i] += x;
        cnt[i]++;
      }
      return [
        for (var i = 0; i < cols; i++)
          cnt[i] == 0 ? null : sum[i] / cnt[i],
      ];
    }

    final series = <List<double?>>[], colors = <Color>[];
    final legend = <(String, Color)>[];
    final axes = <AxisSpec?>[];
    final units = <String>[];

    // Each lane keeps its own scale — they are different quantities — but the
    // scale is PINNED to the night's own range and its unit is named. Three
    // unlabelled lines on three invisible axes was the least readable chart
    // in the app.
    void lane(List<(int, double)> raw, String label, String unit, Color col,
        {String Function(double) format = axisInt}) {
      if (raw.isEmpty || cols == 0) return;
      final g = grid(raw);
      final present = <double>[for (final v in g) ?v];
      if (present.length < 2) return;
      series.add(g);
      colors.add(col);
      legend.add(('$label ($unit)', col));
      axes.add(AxisSpec.of(present, ticks: 2, format: format));
      units.add(unit);
    }

    // Solved against the card, like every other mark: raw pigment measures
    // 1.7-2.5:1 on white and a lane's colour is what tells you which signal
    // you are looking at.
    lane(hr, loc?.sleepDetailHeartRate ?? 'Heart rate', 'bpm', p.on(C.red));
    lane(hrv, loc?.sleepDetailHrv ?? 'HRV', 'ms', p.on(C.green));
    lane(resp, loc?.sleepDetailBreathing ?? 'Breathing', 'br/min', p.on(C.teal));
    // Skin temperature is ADC-relative — a deviation, never a °C. The unit
    // says so rather than implying a thermometer.
    lane(temp, loc?.sleepDetailSkinTemp ?? 'Skin temp', 'rel', p.on(C.orange),
        format: axisFixed);

    if (series.isEmpty) {
      return summary.isEmpty
          ? _noOvernightLines(c)
          : Surface(child: InlineMetrics(summary));
    }
    return Surface(
      child: Column(children: [
        if (summary.isNotEmpty) ...[
          InlineMetrics(summary),
          const SizedBox(height: S.x5),
        ],
        ChartFrame(
          title: loc?.sleepDetailThroughTheNight ?? 'Through the night',
          unit: units.join(' · '),
          height: 44.0 * series.length + 20,
          xLabels: [
            clockOfTs(n['onset_ts'] as num?),
            clockOfTs(n['wake_ts'] as num?),
          ],
          legend: legend,
          // No footnote. The legend already names each lane and its unit, and
          // the lanes are visibly separate — a paragraph explaining that they
          // are separate was describing the picture instead of letting it work.
          child: CustomPaint(
              size: Size.infinite,
              painter: NightStack(series, colors, axes: axes)),
        ),
      ]),
    );
  }

  // ── TONIGHT ───────────────────────────────────────────────────────────────

  /// One takeaway. The old block listed need, debt, strain bonus, nap credit,
  /// target bed and target wake — six numbers, no instruction. A target bedtime
  /// is the only one of them anybody can act on before midnight.
  Widget _tonight(BuildContext c, P p, SleepData d) {
    final l = AppLocalizations.of(c);
    final need = d.need.value;
    final bed = d.bedtime.value;
    final debt = d.debt.value;

    if (need == null && bed == null) {
      return StatusCard.forMetric(
              l?.sleepDetailSleepNeedNotEstablished ??
                  'Sleep need not established',
              d.need) ??
          const SizedBox.shrink();
    }

    final reason = [
      if (need != null) l?.sleepDetailYourNeedIs(hm(need)) ?? 'Your need is ${hm(need)}',
      if (debt != null && debt >= 1)
        l?.sleepDetailYouAreDown(hm(debt)) ?? 'you are ${hm(debt)} down',
    ].join(', ');

    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(bed != null ? clock(bed) : hm(need),
                    style: F.n34.copyWith(color: p.ink)),
              ),
              const SizedBox(width: S.x2),
              Flexible(
                child: Text(
                    bed != null
                        ? (l?.sleepDetailLightsOut ?? 'lights out')
                        : (l?.sleepDetailToAimFor ?? 'to aim for'),
                    style: F.cap.copyWith(color: p.ink3)),
              ),
            ]),
        if (reason.isNotEmpty) ...[
          const SizedBox(height: S.x3),
          Text('$reason.', style: F.body.copyWith(color: p.ink2, height: 1.5)),
        ],
      ]),
    );
  }
}

// ── the comparison row ──────────────────────────────────────────────────────

/// One measure of last night against the middle half of the user's own nights.
///
/// Deliberately not a chart: a full plot per measure is four charts in a
/// section nobody would read, and the only two facts here are "where is the
/// band" and "where did last night land". A strip carries both, and the
/// sentence under it carries the same thing in words for anyone who cannot see
/// the strip.
class _Compare extends StatelessWidget {
  final String label, value, low, high;
  final double tonight;
  final List<double> history;
  final Color color;

  /// How far [tonight] could be wrong on this row's own axis, in the same
  /// units. Zero for a measured quantity. Non-zero on a row whose value is an
  /// ESTIMATE with a published interval (SLP-13): the verdict then needs the
  /// whole interval to clear the band, and it states the direction without a
  /// size, because the size would be a difference of two things neither of
  /// which is a count.
  final double blur;

  /// [fmt] renders a value on this row's axis (minutes → `7h 23m`, relative
  /// minutes → a clock time). [dfmt] renders the SIZE of a difference on it.
  final String Function(double) fmt, dfmt;

  const _Compare({
    required this.label,
    required this.value,
    required this.tonight,
    this.blur = 0,
    required this.history,
    required this.color,
    required this.low,
    required this.high,
    required this.fmt,
    required this.dfmt,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final band = _band(history);

    final head = Row(children: [
      Expanded(child: Text(label, style: F.body.copyWith(color: p.ink))),
      const SizedBox(width: S.x2),
      Flexible(
        child: Text(value,
            textAlign: TextAlign.right,
            style: F.n17.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
      ),
    ]);

    if (band == null) {
      // The value is real, the comparison is not available yet. Say which is
      // which rather than dropping the row or drawing an empty band.
      return Column(children: [
        head,
        const SizedBox(height: S.x1),
        Text(
            l?.sleepDetailNoPersonalRangeYet(history.length, _minNights) ??
                'No personal range yet — ${history.length} of $_minNights nights.',
            style: F.over.copyWith(color: p.ink3)),
      ]);
    }

    final verdict = tonight + blur < band.lo
        ? (blur > 0 ? _capitalise(low) : '${dfmt((band.mid - tonight).abs())} $low')
        : tonight - blur > band.hi
            ? (blur > 0
                ? _capitalise(high)
                : '${dfmt((tonight - band.mid).abs())} $high')
            : blur > 0
                // NOT "typical". The interval overlaps the band, which means
                // this night is not far enough from usual for us to tell —
                // a different statement, and the honest one.
                ? (l?.sleepDetailNotFarEnoughToCall ??
                    'Not far enough from usual to call')
                : (l?.sleepDetailTypicalForYou ?? 'Typical for you');

    final lo = math.min(tonight, history.reduce(math.min));
    final hi = math.max(tonight, history.reduce(math.max));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      head,
      const SizedBox(height: S.x3),
      _Strip(
          lo: lo,
          hi: hi,
          bandLo: band.lo,
          bandHi: band.hi,
          mark: tonight,
          color: color),
      const SizedBox(height: S.x2),
      Text(
          l?.sleepDetailVerdictSummary(
                  verdict, fmt(band.lo), fmt(band.hi), band.n) ??
              '$verdict · usual ${fmt(band.lo)}–${fmt(band.hi)} over ${band.n} '
                  'nights',
          style: F.over.copyWith(color: p.ink3, height: 1.5)),
    ]);
  }
}

/// The strip: a neutral track across the observed range, the middle half of the
/// user's nights filled in, and last night as a mark that overhangs both so it
/// is legible whether it lands on the band or off it.
class _Strip extends StatelessWidget {
  final double lo, hi, bandLo, bandHi, mark;
  final Color color;

  const _Strip({
    required this.lo,
    required this.hi,
    required this.bandLo,
    required this.bandHi,
    required this.mark,
    required this.color,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final span = hi - lo;
    double f(double v) => span <= 0 ? .5 : ((v - lo) / span).clamp(0.0, 1.0);
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (c, box) {
          final w = box.maxWidth;
          final left = f(bandLo) * w;
          // A degenerate band (every night identical) still has to be visible,
          // so it keeps a minimum width rather than collapsing to nothing.
          final width = math.max(4.0, (f(bandHi) - f(bandLo)) * w);
          return SizedBox(
            height: 18,
            width: w,
            child: Stack(children: [
              Positioned(
                left: 0,
                top: 5,
                width: w,
                height: 8,
                child: DecoratedBox(
                    decoration:
                        BoxDecoration(color: p.track, borderRadius: R.rPill)),
              ),
              Positioned(
                left: math.min(left, w - width),
                top: 5,
                width: width,
                height: 8,
                child: DecoratedBox(
                    decoration: BoxDecoration(
                        color: p.on(color), borderRadius: R.rPill)),
              ),
              Positioned(
                left: (f(mark) * w - 1.5).clamp(0.0, w - 3),
                top: 0,
                width: 3,
                height: 18,
                child: DecoratedBox(
                    decoration:
                        BoxDecoration(color: p.ink, borderRadius: R.rPill)),
              ),
            ]),
          );
        },
      ),
    );
  }
}
