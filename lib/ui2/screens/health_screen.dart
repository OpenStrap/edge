// HEALTH — observation-oriented. "What is happening, what is changing, is
// anything unusual?"
//
// Rows, not a wall of cards. A card is a claim that something deserves your
// attention; forty of them side by side is a claim about nothing. Overview is
// a list you scan, Trends is where change lives, Vitals is what the sensor
// measured, and Labs is what a laboratory measured — the only numbers in this
// app that are absolute.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../compute/findings.dart';
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/lab_catalogue.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart';
import '../ui2.dart';
import 'circadian_detail.dart';
import 'ecg.dart' show EcgEntryCard, pairedIsMaverickOf;
import 'findings_log.dart';
import 'home_screen.dart';
import 'investigate.dart';
import 'metric_detail.dart';
import 'naps.dart';

/// A read this screen can live without. The wear block and the nap block are
/// ADDITIONS to the repository interface, so an implementation written before
/// them throws `UnimplementedError` from the base class — and neither is worth
/// taking every number on Health down for. An empty map is what both readers
/// already treat as "we never looked", which is the truth in that case.
///
/// Deliberately not applied to the metric reads above it: a failure there IS
/// the screen failing, and it must not be swallowed into a page of blanks.
/// Takes a CALLBACK, not a future: the base class's stub is `=> throw`, which
/// fires synchronously at the call site and never becomes a future to await.
Future<Map<String, dynamic>> _soft(
    Future<Map<String, dynamic>> Function() read) async {
  try {
    return await read();
  } catch (_) {
    return const {};
  }
}

class HealthData {
  final Map<String, dynamic> today, insights, profile;

  /// Timestamped. The x axis and the "how old is this number" line are both
  /// read off the points' own dates — `metric_series` has one row per DERIVED
  /// day, so the newest stored point can be a week old.
  final Map<String, List<ChartPoint>> charts;

  /// Derived days INSIDE THE LAST 30 CALENDAR DAYS — see [load].
  final int daysWithData;
  final Metric need;

  /// Non-null when the cross-day rollup was withheld — see [staleInsightsCard].
  final Map<String, dynamic>? insightsStale;

  /// THE MEASURED REASON THE OVERNIGHT ROWS ARE EMPTY, or null.
  ///
  /// Five of the rows below are read from the night, and when the band was on a
  /// charger through it they are all absent for one reason that is already on
  /// disk. `_wearBlock` has written the off-wrist stretches on every derive
  /// since it existed and nothing has ever read them. See [wearGapWhy] for what
  /// disqualifies a gap from being the answer.
  final String? nightGap;

  /// The newest derived day's naps — minutes, how many, and whether the day
  /// produced a nap answer at all. `nap_min` has been written on every judged
  /// day and read by nothing; the `naps` block behind it had no reader either.
  final int? napMin;
  final int? napCount;
  final String napDay;

  /// EVERYTHING THE APP HAS EVER NOTICED, newest first — see findings.dart.
  /// Recomputed from the rollup on every load rather than logged, so the
  /// history is there from the first run instead of starting empty today.
  final List<Finding> findings;

  const HealthData({
    this.today = const {},
    this.insights = const {},
    this.profile = const {},
    this.charts = const {},
    this.daysWithData = 0,
    this.need = Metric.empty,
    this.insightsStale,
    this.nightGap,
    this.napMin,
    this.napCount,
    this.napDay = '',
    this.findings = const [],
  });

  /// The stored points for [key].
  List<ChartPoint> points(String key) => charts[key] ?? const [];

  /// [days] slots ending today, `null` where nothing was derived — the shape
  /// every painter in this app takes.
  List<double?> spark(String key, int days) => denseDays(points(key), days);

  Metric daily(String k) {
    final d = today['daily'];
    return metricOf(d is Map ? d[k] : null);
  }

  /// Every one of these is a real envelope from the pipeline, read in one
  /// place so Overview cannot disagree with itself. Trends is a different
  /// question — it plots what is STORED, and dates its hero when the newest
  /// stored point is not today's.
  Metric get hrv {
    final b = today['hrv'];
    final rmssd = b is Map ? b['rmssd'] as num? : null;
    if (rmssd == null || b is! Map) return Metric.empty;
    return Metric.parse(
        {...b.cast<String, dynamic>(), 'value': rmssd, 'unit': 'ms'});
  }

  Metric get sleepMin {
    final b = today['sleep'];
    return metricOf(b is Map ? b['duration_min'] : null);
  }

  Metric get stress => metricOf(today['stress']);
  Metric get resp => metricOf(today['resp']);

  static Future<HealthData> load(LocalRepository repo) async {
    final today = await repo.getToday();
    final cd = await repo.getInsights();
    final profile = await repo.getProfile();
    final days = await repo.availableDays();

    final charts = <String, List<ChartPoint>>{};
    for (final k in const [
      'resting_hr',
      'hrv',
      'sleep',
      'stress',
      'resp_rate',
    ]) {
      charts[k] = pointsOf(await repo.getChart(k));
    }

    final coach = cd['sleep_coach'];
    final needEnv = coach is Map ? coach['need'] : null;
    final needSec = envValue(needEnv)?['need_sec'] as num?;

    // The last 30 CALENDAR days, not the newest 30 rows. `availableDays()` is
    // unbounded — every derived day since install — so `daysWithData` was the
    // whole history and `.clamp(0, 30)` painted "30 of 30" for anyone past
    // their first month, however many days they had actually missed.
    // `DateTime(y, m, d - 29)` and not `subtract(Duration(days: 29))`: the
    // duration form lands at 23:00 the day before across a DST boundary.
    final n = DateTime.now();
    final from = dayLabelOf(DateTime(n.year, n.month, n.day - 29));

    // The night the overnight rows describe, and the evening before it: a gap
    // that starts at 11:20 PM is filed under the previous calendar day's wear
    // block, and asking only about the night's own day would report it as
    // beginning at midnight. The window is 8 PM → 10 AM, which is wide enough
    // to hold any bedtime this app would score and narrow enough that an
    // afternoon on the charger is not offered as the reason a night is missing.
    final nightDay = heldOverNightOf(today) ?? todayLabel();
    final nd = DateTime.tryParse(nightDay);
    // `day - 1`, not a subtracted duration: calendar arithmetic, which lands
    // on the right date across a DST boundary where 24 h does not.
    final prevDay = nd == null
        ? nightDay
        : dayLabelOf(DateTime(nd.year, nd.month, nd.day - 1));
    final nightStart = localDayStartSec(prevDay);
    final dayStart = localDayStartSec(nightDay);
    final gap = (nightStart == null || dayStart == null)
        ? null
        : wearGapWhy(
            [await _soft(() => repo.getDayWear(prevDay)),
             await _soft(() => repo.getDayWear(nightDay))],
            fromSec: nightStart + 20 * 3600,
            toSec: dayStart + 10 * 3600,
          );

    // The two inputs the rollup's `recent[]` does not carry. Both come off
    // `metric_series`, which keeps one value per derived day for as long as the
    // day exists — the same store the trend charts draw, so the log cannot
    // disagree with the chart a tap away about which mornings were low.
    String labelAt(int t) =>
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(t * 1000));
    final ready = {
      for (final p in pointsOf(await repo.getChart('recovery')))
        labelAt(p.t): p.v,
    };
    final irregular = {
      for (final p in pointsOf(await repo.getChart('irregular_rhythm_flag')))
        if (p.v == 1) labelAt(p.t),
    };

    // The newest DERIVED day, not today: `getDayNaps` reads the exact day it is
    // asked for (an editable list must not be served off another day), and
    // today has usually not derived yet.
    final napDay = days.isEmpty ? todayLabel() : days.first;
    final naps = await _soft(() => repo.getDayNaps(napDay));

    return HealthData(
      today: today,
      insights: cd,
      profile: profile,
      charts: charts,
      daysWithData: days.where((d) => d.compareTo(from) >= 0).length,
      need: envMetric(needEnv, needSec == null ? null : needSec / 60,
          unit: 'min'),
      insightsStale: staleReasonOf(cd),
      nightGap: gap,
      napMin: (naps['nap_min'] as num?)?.round(),
      napCount: (naps['naps'] as List?)?.length,
      napDay: napDay,
      findings:
          findingsHistory(cd, readiness: ready, irregularDays: irregular),
    );
  }
}

class VitalsData {
  /// The day these four blocks describe. When today has no derived record the
  /// loader falls back to the newest one there is, which is routinely days ago
  /// — and every row was captioned "Today" regardless.
  final String? day;

  /// Every derived day, newest first — what [DayNav] steers over.
  final List<String> days;

  final Map<String, dynamic> timeline, lungs, wear, hrv;
  const VitalsData({
    this.day,
    this.days = const [],
    this.timeline = const {},
    this.lungs = const {},
    this.wear = const {},
    this.hrv = const {},
  });

  static Future<VitalsData> load(LocalRepository repo, {String? want}) async {
    final today = await repo.getToday();
    final days = await repo.availableDays();
    final day = pickDay(
        days, want, (today['status'] as Map?)?['today_day']?.toString());
    if (day == null) return VitalsData(days: days);
    final timeline = await repo.getDayTimeline(day);
    return VitalsData(
      // The repository stamps the bundle it actually served; prefer it over the
      // day we asked for, which is what its own comment says to do.
      day: timeline['date']?.toString() ?? day,
      days: days,
      timeline: timeline,
      lungs: await repo.getDayLungs(day),
      wear: await repo.getDayWear(day),
      hrv: await repo.getDayHrv(day),
    );
  }
}

/// Whole calendar days between a `'YYYY-MM-DD'` day id and today, or null when
/// there is no day. Zero or less means the day IS today.
int? _behind(String? dayId) {
  final d = dayId == null ? null : DateTime.tryParse(dayId);
  return d == null ? null : calendarDaysBetween(d, DateTime.now());
}

class LabsData {
  final List<Map<String, dynamic>> results;
  final List<LabMarker> markers;
  const LabsData({this.results = const [], this.markers = const []});

  static Future<LabsData> load() async {
    final rows = await LocalDb.labResults();
    final defs = await LocalDb.labMarkerDefs();
    return LabsData(
      results: rows,
      markers: [
        ...kLabMarkers,
        for (final d in defs)
          if (!kLabMarkersByKey.containsKey(d['key']))
            LabMarker(
              key: d['key'].toString(),
              label: (d['label'] ?? d['key']).toString(),
              unit: (d['unit'] ?? '').toString(),
              category: LabCategory.blood,
              decimals: (d['decimals'] as num?)?.toInt() ?? 1,
              ranges: [
                if (d['ref_low'] is num && d['ref_high'] is num)
                  LabRefRange(
                      low: (d['ref_low'] as num).toDouble(),
                      high: (d['ref_high'] as num).toDouble()),
              ],
              custom: true,
            ),
      ],
    );
  }
}

// ═══════════════════ the catalogue ═══════════════════
//
// EXPLORE. The app persists 39 daily series and carries 25 written metric
// specs — title, unit, colour, icon, method, citation — and until this tab
// existed `MetricDetail` was constructed with SEVEN keys anywhere in the tree.
// Sixteen finished screens had no navigation edge at all. That is a routing
// gap, not a content gap, and this is the routing.
//
// It is an index, not a dashboard: nothing here computes, nothing here is a
// number about you. It says what this app can tell you, groups it the way a
// person would look for it, and says for each one how many days it actually
// has — which is the only honest answer to "is there anything in there".

/// One catalogue entry: the [MetricSpec] key (which is what [MetricDetail]
/// takes), the `metric_series` key its history is stored under, and the single
/// line that says what it answers.
///
/// Icon, colour and title are NOT here — they come off the spec. A second copy
/// is how two screens end up disagreeing about what a metric is called.
class _CatRow {
  final String key, series, blurb;
  const _CatRow(this.key, this.series, this.blurb);
}

class _Cat {
  final String title;
  final List<_CatRow> rows;
  const _Cat(this.title, this.rows);
}

/// The families, in the order a person looks for them.
///
/// What is deliberately NOT here:
/// - SpO2, ODI and anything apnea-shaped. Refused outright — a capability this
///   app does not produce has no entry, no card and no key, and an index that
///   listed them to explain their absence would be the exact thing the
///   absent-forever rule forbids.
/// - Cycle. It is a Wellness tab with its own door and its own on/off switch;
///   a second entrance from Health would be a duplicate route, not a feature.
/// - `rmssd_whole`, `stress_si`, `brv_slope`. Real numbers, but single-night
///   with no series ever. They had written specs for a while and nothing could
///   open them; the specs are gone now, so there is nothing to route to either.
///   `stress` and `brv` below are the charted forms of two of the three.
/// - Body clock, zones, Nerd stats. Each already has a door at the same depth
///   as this one; adding a second is navigation debt.
const _catalogue = <_Cat>[
  _Cat('Heart & rhythm', [
    _CatRow('resting_hr', 'rhr', 'The lowest sustained rate of the night'),
    _CatRow('hrv', 'rmssd', 'RMSSD over the cleanest window of sleep'),
    _CatRow('hrv_cv', 'hrv_cv', 'How much that swings from night to night'),
    _CatRow('lf_hf', 'lf_hf', 'Where beat-timing power sits across frequencies'),
    _CatRow('dip', 'dip_pct', 'How far your heart rate falls while you sleep'),
    _CatRow('hrr', 'hrr_bpm', 'How fast it falls in the minute after a bout'),
  ]),
  _Cat('Sleep', [
    _CatRow('sleep', 'tst_min', 'Time asleep, from motion and beat timing'),
    _CatRow('efficiency', 'efficiency', 'Asleep as a share of time in bed'),
    _CatRow('deep', 'deep_min', 'Heart-rate flatness inside NREM'),
    _CatRow('rem', 'rem_min', 'Staged from beat variability and movement'),
    _CatRow('nap_min', 'nap_min', 'Sleep detected outside the main night'),
  ]),
  _Cat('Breathing', [
    _CatRow('resp_rate', 'resp_rate', 'Breaths per minute, recovered from beat timing'),
    _CatRow('brv', 'brv_cv', 'How much that rate varies across the night'),
  ]),
  _Cat('Movement & load', [
    _CatRow('steps', 'steps', 'Counted by a pedometer, never modelled'),
    _CatRow('active_min', 'active_min', 'Minutes of movement volume, not locomotion'),
    _CatRow('calories', 'calories', 'Active energy from heart rate and your profile'),
    _CatRow('strain', 'strain', 'Cardiovascular load over the day, on 0–21'),
    _CatRow('trimp', 'trimp', 'Time in each zone, weighted by its cost'),
  ]),
  _Cat('Body & wear', [
    _CatRow('skin_temp', 'skin_temp_z', 'Distance from your own recent nights'),
    _CatRow('wear', 'worn_min', 'Minutes with a band record present'),
  ]),
];

/// Catalogue category titles and row blurbs are read off a top-level `const`
/// list, which cannot call `AppLocalizations.of(context)` itself — so the
/// lookup happens here, at render time, keyed off the same literal English
/// text/row key the const list already carries as its fallback.
String _catTitle(AppLocalizations? l, String title) => switch (title) {
      'Heart & rhythm' => l?.healthCatHeartRhythm ?? title,
      'Sleep' => l?.healthRowSleep ?? title,
      'Breathing' => l?.healthCatBreathing ?? title,
      'Movement & load' => l?.healthCatMovementLoad ?? title,
      'Body & wear' => l?.healthCatBodyWear ?? title,
      _ => title,
    };

String _rowBlurb(AppLocalizations? l, String key, String blurb) =>
    switch (key) {
      'resting_hr' => l?.healthBlurbRestingHr ?? blurb,
      'hrv' => l?.healthBlurbHrv ?? blurb,
      'hrv_cv' => l?.healthBlurbHrvCv ?? blurb,
      'lf_hf' => l?.healthBlurbLfHf ?? blurb,
      'dip' => l?.healthBlurbDip ?? blurb,
      'hrr' => l?.healthBlurbHrr ?? blurb,
      'sleep' => l?.healthBlurbSleep ?? blurb,
      'efficiency' => l?.healthBlurbEfficiency ?? blurb,
      'deep' => l?.healthBlurbDeep ?? blurb,
      'rem' => l?.healthBlurbRem ?? blurb,
      'nap_min' => l?.healthBlurbNapMin ?? blurb,
      'resp_rate' => l?.healthBlurbRespRate ?? blurb,
      'brv' => l?.healthBlurbBrv ?? blurb,
      'steps' => l?.healthBlurbSteps ?? blurb,
      'active_min' => l?.healthBlurbActiveMin ?? blurb,
      'calories' => l?.healthBlurbCalories ?? blurb,
      'strain' => l?.healthBlurbStrain ?? blurb,
      'trimp' => l?.healthBlurbTrimp ?? blurb,
      'skin_temp' => l?.healthBlurbSkinTemp ?? blurb,
      'wear' => l?.healthBlurbWear ?? blurb,
      _ => blurb,
    };

class ExploreData {
  /// Non-null `metric_series` rows per key — used ONLY as has / hasn't.
  ///
  /// The number itself is never rendered per row (see `_family`): as a value
  /// beside a metric it reads as a score, and it collapses "rare", "new key"
  /// and "substrate pruned" into one figure. What it is good for is the split —
  /// which rows have history, which are named in the empty card, and the
  /// "N of M measures" header, where the aggregate is honest because it is
  /// about the DEVICE and not about any one metric.
  final Map<String, int> counts;
  const ExploreData({this.counts = const {}});

  static Future<ExploreData> load() async => ExploreData(
        counts: await LocalDb.metricSeriesCounts([
          for (final f in _catalogue)
            for (final r in f.rows) r.series,
        ]),
      );
}

class HealthScreen extends StatefulWidget {
  final HealthData? data;
  final VitalsData? vitals;
  final LabsData? labs;
  final ExploreData? explore;

  /// Which sub-tab to open on. Goldens use it; production always starts at 0.
  final int tab;

  const HealthScreen(
      {super.key,
      this.data,
      this.vitals,
      this.labs,
      this.explore,
      this.tab = 0});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> with RevisionReload {
  // EXPLORE SITS SECOND, not last. Five chips do not fit a 390 pt frame at 1×:
  // the fifth is clipped by the edge, and a half-visible chip is exactly the
  // discoverability failure this tab exists to fix. Labs takes the clip instead
  // — it is the manual-entry tab, the one a user goes looking for on purpose,
  // and the only one here that holds numbers this app did not measure.
  List<String> _tabsOf(AppLocalizations? l) => [
        l?.healthTabOverview ?? 'Overview',
        l?.healthTabExplore ?? 'Explore',
        l?.healthTabTrends ?? 'Trends',
        l?.healthTabVitals ?? 'Vitals',
        l?.healthTabLabs ?? 'Labs',
      ];
  late int _tab = widget.tab;

  HealthData? _d;
  VitalsData? _v;
  LabsData? _l;
  ExploreData? _e;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _d = widget.data;
    _v = widget.vitals;
    _l = widget.labs;
    _e = widget.explore;
    if (widget.data != null) {
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Handed its data (golden, gallery) — nothing behind it to re-read.
  @override
  bool get revisionReloads => widget.data == null;

  /// A tab kept alive by the IndexedStack for the life of the process: it read
  /// the database once at launch, so an import or a derive that landed after
  /// that was invisible here until the app was relaunched. The already-loaded
  /// sub-tabs are re-read too — they cache on `!= null`, which is the same
  /// load-once bug one level down.
  ///
  /// EVERY SUB-TAB THAT HAS EVER READ, not every sub-tab that holds data. This
  /// gated on `!= null` and so skipped the one case that matters most — a
  /// sub-tab whose first read is still in flight when the revision lands, which
  /// is the ordinary state of the first load after an import. See [hasRead].
  @override
  void reload() {
    _load();
    if (hasRead(#vitals)) _loadVitals(force: true);
    if (hasRead(#labs)) {
      _l = null;
      _loadLabs();
    }
    if (hasRead(#explore)) {
      _e = null;
      _loadExplore();
    }
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final t = beginRead(#day);
    try {
      final d = await HealthData.load(repo);
      if (stillNewest(#day, t)) setState(() => (_d = d, _loading = false));
    } catch (_) {
      if (stillNewest(#day, t)) setState(() => _loading = false);
    }
  }

  /// A tab's read THREW. `_v`/`_l` stay null on that path and null renders the
  /// spinner, so swallowing the error left the tab spinning silently for as
  /// long as the user stayed on it — there was no absent state on that path at
  /// all, whatever the old comment here said.
  bool _vFailed = false, _lFailed = false, _eFailed = false;

  /// The day the Vitals tab is showing, once the user has steered off the
  /// default. Null means "whatever the loader resolves", which is today.
  String? _vDay;

  Future<void> _loadVitals({bool force = false}) async {
    final repo = repoOf(context);
    if (repo == null || (_v != null && !force)) return;
    // Keyed per sub-tab: steering to another day starts a read that must beat
    // the one already in flight, and neither may cancel Labs or Explore.
    final t = beginRead(#vitals);
    try {
      final v = await VitalsData.load(repo, want: _vDay);
      if (stillNewest(#vitals, t)) setState(() => (_v = v, _vFailed = false));
    } catch (_) {
      if (stillNewest(#vitals, t)) setState(() => _vFailed = true);
    }
  }

  void _goVitalsDay(String day) {
    setState(() => _vDay = day);
    _loadVitals(force: true);
  }

  Future<void> _loadLabs() async {
    if (_l != null) return;
    final t = beginRead(#labs);
    try {
      final l = await LabsData.load();
      if (stillNewest(#labs, t)) setState(() => (_l = l, _lFailed = false));
    } catch (_) {
      if (stillNewest(#labs, t)) setState(() => _lFailed = true);
    }
  }

  /// The one card both failed reads render. Not "nothing logged yet" — a read
  /// that went wrong and an empty table are different states.
  StatusCard _readFailed(String what, VoidCallback retry) {
    final l = AppLocalizations.of(context);
    return StatusCard(
      l?.healthCouldNotRead(what) ?? 'Could not read your $what',
      l?.healthReadFailedBody ??
          'The stored rows failed to load. Nothing was deleted — this is a '
              'read that went wrong.',
      fix: l?.healthTryAgain ?? 'Try again',
      icon: LucideIcons.databaseZap,
      onFix: retry,
    );
  }

  Future<void> _loadExplore() async {
    if (_e != null) return;
    final t = beginRead(#explore);
    try {
      final e = await ExploreData.load();
      if (stillNewest(#explore, t)) setState(() => (_e = e, _eFailed = false));
    } catch (_) {
      if (stillNewest(#explore, t)) setState(() => _eFailed = true);
    }
  }

  void _select(int i) {
    setState(() => _tab = i);
    if (i == 1) _loadExplore();
    if (i == 3) _loadVitals();
    if (i == 4) _loadLabs();
  }

  @override
  Widget build(BuildContext c) {
    final d = _d ?? const HealthData();
    final l = AppLocalizations.of(c);
    return ListView(padding: pad, children: [
      ScreenTitle(l?.healthTitle ?? 'Health'),
      SubTabs(_tabsOf(l), _tab, _select, color: C.blue),
      const SizedBox(height: S.x5),
      if (_loading && _d == null)
        const Padding(
          padding: EdgeInsets.only(top: S.x8),
          child: Center(child: CircularProgressIndicator()),
        )
      else
        switch (_tab) {
          0 => _overview(c, d),
          1 => _explore(c),
          2 => _trends(c, d),
          3 => _vitals(c, d),
          _ => _labs(c),
        },
    ]);
  }

  // ─────────────── OVERVIEW ───────────────
  Widget _overview(BuildContext c, HealthData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final rows = <Widget>[];
    final gaps = <Widget>[];

    // ALL FIVE ROWS ARE READ FROM THE NIGHT, so all five take the same
    // measured gap. `overnight: false` is for a row that is not — a hole at
    // 2 AM says nothing about a daytime number, and offering it as the reason
    // would be the invented cause the whole absence layer refuses.
    // `rising` is the ONE value judgement a row makes, and it is per metric:
    // resting heart rate falling is good news, HRV rising is. A metric this
    // project makes no directional claim about takes [Rising.neither] and
    // draws its arrow in ink — the direction is stated, the verdict is not
    // invented.
    void row(Metric m, IconData icon, Color col, String name, String sub,
        String value, String unit, List<double?> series, String metricKey,
        {String? whyAbsent,
        bool overnight = true,
        Rising rising = Rising.neither}) {
      if (m.isEmpty) {
        final s = StatusCard.forMetric(
            l?.healthNoMetric(name.toLowerCase()) ??
                'No ${name.toLowerCase()}',
            m,
            why: whyAbsent ?? '', gap: overnight ? d.nightGap : null);
        if (s != null) gaps.add(s);
        return;
      }
      rows.add(MetricRow(icon, col, name, value,
          sub: sub,
          unit: unit,
          series: series,
          rising: rising,
          onTap: () => go(c, MetricDetail(metricKey))));
    }

    // Five of these rows come off the overnight block, and `getToday` holds
    // that block over until today's settles. "Last night" / "Overnight" were
    // fixed literals, so a days-old night was stated as last night's — while
    // the Trends tab one tap away correctly said "as of 4 days ago" about the
    // same numbers.
    final night = heldOverNightOf(d.today);
    String ofNight(String s) => night == null ? s : '$s · ${prettyDay(night)}';

    final sleepMin = d.sleepMin;

    final rhr = d.daily('resting_hr');
    row(rhr, LucideIcons.heart, C.red, l?.healthRowRestingHr ?? 'Resting heart rate',
        ofNight(l?.healthSubOvernight ?? 'Overnight'),
        rhr.value == null ? '' : '${rhr.value!.round()}', 'bpm',
        d.spark('resting_hr', 24), 'resting_hr',
        // Sleep duration and nocturnal RHR are gated separately, so "no night
        // was scored" is often the wrong reason and contradicts the Sleep row
        // sitting two lines down. Only the branch this screen can SEE is
        // stated — the other named a beat-quality gate it never read.
        // Nocturnal resting heart rate: lower is the direction every part of
        // this app already treats as better — it is what the illness CUSUM
        // watches for a RISE, and what readiness scores as `lowerIsBetter`.
        rising: Rising.bad,
        whyAbsent: sleepMin.isEmpty
            ? (l?.healthWhyReadFromSleep ??
                'Read from sleep, and no night was scored.')
            : '');

    final hrvMetric = d.hrv;
    row(hrvMetric, LucideIcons.activity, C.green, l?.healthRowHrv ?? 'HRV',
        ofNight(l?.healthSubRmssdAsleep ?? 'RMSSD, asleep'),
        hrvMetric.value == null ? '' : '${hrvMetric.value!.round()}', 'ms',
        d.spark('hrv', 24), 'hrv',
        rising: Rising.good,
        // Blaming signal quality unconditionally told a day-one user their
        // sensor produced dirty data on a night that never happened.
        whyAbsent: sleepMin.isEmpty
            ? (l?.healthWhyReadOnlyFromSleep ??
                'Read only from sleep, and no night was scored.')
            : '');

    row(sleepMin, LucideIcons.moon, C.blue, l?.healthRowSleep ?? 'Sleep',
        night == null ? (l?.healthSubLastNight ?? 'Last night') : prettyDay(night),
        hm(sleepMin.value), '', d.spark('sleep', 24), 'sleep',
        // More sleep is the direction this app coaches towards — `sleepNeed`
        // exists to say you are short of it, never over it.
        rising: Rising.good,
        whyAbsent: l?.healthWhySleepNotLongEnough ??
            'No sleep period long enough to score was recorded.');

    final stressBlock = d.today['stress'];
    final stressScore =
        stressBlock is Map ? (stressBlock['score'] as num?) : null;
    row(
        d.stress,
        LucideIcons.brain,
        C.purple,
        l?.healthRowStress ?? 'Stress',
        ofNight((stressBlock is Map ? stressBlock['level']?.toString() : null) ??
            (l?.healthRowStress ?? 'Stress')),
        stressScore == null ? '' : '${stressScore.round()}',
        // 0–100, and the scale has to be on the row. Wellness has always shown
        // it for the same number.
        '/100',
        d.spark('stress', 24),
        'stress',
        rising: Rising.bad,
        // Was 'No resting stretch long enough last night.' — one of several
        // gates stress abstains on, asserted for all of them.
        whyAbsent: sleepMin.isEmpty
            ? (l?.healthWhyReadFromNight ??
                'Read from the night, and no night was scored.')
            : '');

    final respMetric = d.resp;
    row(respMetric, LucideIcons.wind, C.teal, l?.healthRowRespRate ?? 'Respiratory rate',
        ofNight(l?.healthSubAsleep ?? 'Asleep'),
        respMetric.value == null ? '' : respMetric.value!.toStringAsFixed(1),
        'br/min',
        d.spark('resp_rate', 24), 'resp_rate',
        // DELIBERATELY UNJUDGED. Readiness scores a rise as a cost, but that
        // is a deviation from your own baseline, not a claim that breathing
        // slower is better health — nobody here would tell you a falling
        // respiratory rate is good news. Direction, no verdict.
        // THE ESTIMATOR'S OWN REASON when it left one, not a guess written
        // here. `respiration.rsa` records which gate it failed — too few beats,
        // artifact fraction over the gate, no stable HF peak, or a peak that
        // moved across spectral resolutions — and the repository now carries
        // that note through. This screen guessed "too noisy" for all four,
        // which was right about a quarter of the time.
        whyAbsent: respMetric.note?.isNotEmpty == true
            ? respMetric.note!
            : (sleepMin.isEmpty
                ? (l?.healthWhyReadOnlyFromSleep ??
                    'Read only from sleep, and no night was scored.')
                : (l?.healthWhyNoReadingLastNight ??
                    'No reading from last night.')));

    final illness = d.today['illness'];
    final state = illness is Map ? illness['state']?.toString() : null;
    // The CUSUM watch runs on NOCTURNAL RESTING HEART RATE ALONE. The copy here
    // used to name skin temperature as a second firing signal; the detector has
    // never been given a temperature series. `z` is its own standardised
    // deviation, so the sentence can say how far out the night sat.
    final illnessZ = illness is Map ? (illness['z'] as num?) : null;
    // The payload carries the night it is about. It is one entry per DERIVED
    // day, so after a gap "Last night" named a night the user did not wear the
    // band for.
    final illnessDay = illness is Map ? illness['date']?.toString() : null;
    final illnessBehind = _behind(illnessDay);

    // Hoisted out of the tree so the section that now wraps it does not push
    // its copy two levels deeper. The card itself is untouched.
    final illnessCard = state == null || state == 'green'
        ? null
        : Observation(
            state == 'red'
                ? (l?.healthIllnessRedTitle ??
                    'Several nights in a row are away from your normal')
                : (illnessBehind == null || illnessBehind <= 0
                    ? (l?.healthIllnessLastNightTitle ??
                        'Last night sat outside your normal range')
                    : (l?.healthIllnessDayTitle(prettyDay(illnessDay)) ??
                        '${prettyDay(illnessDay)} sat outside your normal range')),
            // The RUN is what is above baseline — the accumulator only clears
            // after two nights back under. The stored z is the LATEST night's
            // own deviation and can be negative while the run is still up,
            // which read as "tracking above your own baseline, 1.3 deviations
            // below it".
            illnessZ == null
                ? (l?.healthIllnessBodyNoZ ??
                    'Your nocturnal resting heart rate has been running above '
                        'your own baseline. This watches one signal only. It '
                        'names a pattern, not a cause.')
                : (l?.healthIllnessBodyWithZ(
                        illnessZ.abs().toStringAsFixed(1),
                        illnessZ >= 0
                            ? (l.healthDirectionAbove)
                            : (l.healthDirectionBelow)) ??
                    'Your nocturnal resting heart rate has been running above '
                        'your own baseline; that night sat '
                        '${illnessZ.abs().toStringAsFixed(1)} standard deviations '
                        '${illnessZ >= 0 ? 'above' : 'below'} it. This watches '
                        'one signal only. It names a pattern, not a cause.'),
            advice: l?.healthIllnessAdvice ??
                'Worth noting if it continues past a couple of days.',
          );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // WHOOP MG only: the ECG door appears once the paired band has
      // positively identified itself as an MG, and stays while it is away.
      if (pairedIsMaverickOf(c)) ...[
        const EcgEntryCard(),
        const SizedBox(height: S.x3),
      ],
      if (rows.isNotEmpty)
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: p.line, height: 1),
              rows[i],
            ],
          ]),
        ),
      for (final g in gaps) ...[const SizedBox(height: S.x3), g],

      // OBSERVATIONS — the illness watch, wrapped, plus a door to the other
      // three detectors.
      //
      // The illness card is unchanged and stays first: it is the one finding
      // with copy specific enough to be worth a card of its own. What it gains
      // is a title over it and a way through to the anomaly, skin temperature
      // and resting-HR findings, which fired for months and reached no screen
      // at all. NOT a feed — see findings_log.dart. Nothing here is unread,
      // badged or dismissible, and it does not appear on Home.
      if (illnessCard != null || d.findings.isNotEmpty) ...[
        const SizedBox(height: S.x4),
        Section(
          l?.healthObservationsTitle ?? 'Observations',
          illnessCard ??
              // No live illness, but the log is not empty: the newest entry in
              // place and the rest one tap away. ONE row — a wall of findings
              // on the tab you land on is the feed this is not.
              Surface(
                onTap: () => go(c, FindingsLog(d.findings)),
                child: FindingRow(d.findings.first),
              ),
          action: d.findings.isEmpty ? null : (l?.healthSeeAll ?? 'See all'),
          onAction:
              d.findings.isEmpty ? null : () => go(c, FindingsLog(d.findings)),
        ),
      ],

      // NAPS — the display and the correction, which are one feature. The
      // section is here on a day with no naps too, because the door to logging
      // one has to exist on exactly the day the detector found nothing.
      Section(
        l?.healthNapsTitle ?? 'Naps',
        d.napCount == null
            // `napDay` defaults to '' and `prettyDay` returns '' for anything
            // it cannot parse, so this printed "No nap reading for" with the
            // sentence hanging off the end of the word "for". Name the day only
            // when there is one to name.
            ? StatusCard(
                prettyDay(d.napDay).isEmpty
                    ? (l?.healthNoNapReading ?? 'No nap reading')
                    : (l?.healthNoNapReadingFor(prettyDay(d.napDay)) ??
                        'No nap reading for ${prettyDay(d.napDay)}'),
                l?.healthNapsBody ??
                    'Naps come off the same second-by-second recording as the '
                        'rest of the day, and this day does not have enough of '
                        'it.',
                icon: LucideIcons.sun,
              )
            : Surface(
                pad: const EdgeInsets.symmetric(horizontal: S.x4),
                child: MetricRow(
                  LucideIcons.sun,
                  C.indigo,
                  l?.healthDaytimeSleep ?? 'Daytime sleep',
                  // A MEASURED zero, not a dash: the day was judged and held
                  // no nap. The two are different answers and read as two.
                  d.napCount == 0 ? (l?.healthValueNone ?? 'None') : hm(d.napMin),
                  sub: d.napCount == 0
                      ? (l?.healthNoneDetectedOn(prettyDay(d.napDay)) ??
                          'None detected · ${prettyDay(d.napDay)}')
                      : '${l?.healthNapCountLabel(d.napCount!) ?? '${d.napCount} '
                              'nap${d.napCount == 1 ? '' : 's'}'} · '
                          '${prettyDay(d.napDay)}',
                  onTap: () => go(c, NapsScreen(day: d.napDay)),
                ),
              ),
        action: l?.healthAddOrCorrect ?? 'Add or correct',
        onAction: () => go(c, NapsScreen(day: d.napDay)),
      ),

      // THERE IS NO "BODY COMPOSITION" SECTION, AND THE NEXT PERSON SHOULD NOT
      // BUILD ONE. It used to print the onboarding weight scalar, and the ask
      // that replaced it was "is their weight normal for the intake and the
      // burn" — a bar like the against-your-usual ones. Three measurements
      // killed it, in order of how hard they kill it:
      //
      //   1. INTAKE. `food_entry` (nutrition_store.dart) does not exist in any
      //      real database on hand, and `journal_metric` exists in one with
      //      zero rows. So the honest fill rate for logged days is 0, and
      //      `DayLogState.partial` is the state a real log lands in most of the
      //      time by design — an occasion with no kcal is a VALID log and makes
      //      the day's energy a floor, not a total. Self-report is also under
      //      by 20-30% in free-living adults, which is the same size as the
      //      deficits anyone would be looking for. A balance computed off that
      //      is not a small error, it is the wrong sign about half the time.
      //
      //   2. BURN. `calories_total` is tier ESTIMATE, confidence 0.5: a Mifflin
      //      floor over the covered day plus a Keytel surplus over the wake
      //      span. On the real export it swings 2 454 - 4 545 kcal across a
      //      fortnight, and a barely-worn day still publishes a confident
      //      1 715 with 0 active. That daily swing alone is bigger than the
      //      imbalance a verdict would be claiming to see.
      //
      //   3. WEIGHT. It is one profile scalar here, not a series, so it can
      //      never be an against-your-usual bar. The trend that IS honest
      //      already exists somewhere better: `weightTrendEwma` drawn by the
      //      Journal weight screen, gaps left as gaps. Read the ceiling written
      //      above it in journal_fields.dart before reopening this — weekly
      //      scale noise is +/-1 kg and a 2 400 kcal weekly imbalance moves
      //      ~0.3 kg, so the residual is several times smaller than the noise
      //      it would have to be read out of. The 7 700 kcal/kg rule is a
      //      population approximation, never a personal constant.
      //
      // A bar drawn from any two of those three is arithmetic on a floor
      // wearing the costume of a measurement, and this screen exists to not do
      // that. If someone logs food completely for months AND weighs in
      // repeatedly, the thing to build is still not a verdict on the person.
    ]);
  }

  // ─────────────── TRENDS ───────────────
  Widget _trends(BuildContext c, HealthData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final cd = d.insights;
    final chrono = envValue(cd['chronotype']) ?? const {};
    final sjl = envValue(cd['social_jetlag']) ?? const {};
    final reg = envValue(cd['regularity']) ?? const {};
    final sjlH = sjl['abs_hours'] as num?;
    final sri = reg['sri'] as num?;
    final stale = staleInsightsCard(d.insightsStale, syncOf(c));

    /// [against] is the number the card compares the latest reading TO. Pass it
    /// and the delta is measured against that; leave it null and the delta is
    /// measured against the trailing mean of what is stored.
    ///
    /// It exists because the sleep card used to caption itself "vs your 7h 45m
    /// need" while still subtracting the 28-day AVERAGE — so the arrow and the
    /// figure under it read as sleep debt and were not. One of the two had to
    /// become true; the debt is the more useful of the pair.
    // No `Metric` argument: this card is drawn entirely from the stored
    // series, so taking the envelope only implied a cross-check that was
    // never made.
    Widget trend(String key, String label, String unit, Color col,
        {bool higherBetter = true, double? against, String? againstLabel}) {
      final pts = d.points(key);
      // Statistics off the STORED values; the painter gets the dense window.
      final s = valuesOf(pts);
      if (s.isEmpty) {
        return StatusCard(
          l?.healthNoTrendYet(label) ?? 'No $label trend yet',
          l?.healthZeroDaysStored ?? '0 days stored.',
          icon: LucideIcons.chartLine,
        );
      }
      final prior = s.length > 1
          ? s.sublist(s.length - 1 - (s.length - 1).clamp(0, 28), s.length - 1)
          : const <double>[];
      // "vs your 28-day average" printed from the SECOND stored value, over a
      // mean of one. The window has to say how many days it actually holds.
      final mean =
          prior.isEmpty ? null : prior.reduce((a, b) => a + b) / prior.length;
      final base = against ?? mean;
      final window = against != null
          ? (againstLabel ?? '')
          : (l?.healthVsDayAverage(prior.length) ??
              'vs your ${prior.length}-day average');
      final delta = base == null ? 0.0 : s.last - base;
      final win = denseDays(pts, 30);
      final metricKey = key == 'sleep' ? 'sleep' : key;
      // The hero number is the newest STORED point, which after a sync gap is
      // not today's. Say when it is from rather than let the card imply now.
      final behind = daysBehind(pts.last.t) ?? 0;
      final asOf = behind <= 0
          ? ''
          : (l?.healthAsOf(axisDay(pts.last.t)) ?? ' · as of ${axisDay(pts.last.t)}');
      return TrendCard(
        label,
        key == 'sleep' ? hm(s.last) : metricValue(unit, s.last),
        key == 'sleep' ? '' : unit,
        base == null
            ? (l?.healthNoBaseline ?? 'no baseline')
            : (key == 'sleep' ? hm(delta.abs()) : metricValue(unit, delta.abs())),
        '${base == null ? (l?.healthFirstReadings ?? 'first readings') : window}$asOf',
        win,
        col,
        up: delta >= 0,
        // Null with no baseline: an arrow and a good/bad hue about a
        // comparison the card has just said it cannot make.
        good: base == null ? null : (delta >= 0) == higherBetter,
        onTap: () => go(c, MetricDetail(metricKey)),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      trend('resting_hr', l?.healthRowRestingHr ?? 'Resting heart rate', 'bpm',
          C.red, higherBetter: false),
      const SizedBox(height: S.x3),
      trend('hrv', l?.healthRowHrv ?? 'HRV', 'ms', C.green),
      const SizedBox(height: S.x3),
      if (d.need.value == null)
        trend('sleep', l?.healthTimeAsleep ?? 'Time asleep', '', C.blue)
      else
        // `need` here is `crossday.sleep_coach.need` — the COMPUTED need. It is
        // never `sleep.need_min`, which is a hardcoded 480.
        trend('sleep', l?.healthTimeAsleep ?? 'Time asleep', '', C.blue,
            against: d.need.value!.toDouble(),
            againstLabel: l?.healthVsNeed(hm(d.need.value)) ??
                'vs your ${hm(d.need.value)} need'),

      // Chronotype, jetlag and regularity ALL come out of the cross-day
      // rollup. When it is withheld, the section says why rather than showing
      // the cold-start "it takes a few weeks" line, which would be a lie.
      if (stale != null)
        Section(l?.healthBodyClockTitle ?? 'Body clock', stale)
      else
        Section(
          l?.healthBodyClockTitle ?? 'Body clock',
          Surface(
            onTap: () => go(c, const CircadianDetail()),
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: Text(
                      l?.healthChronotypeJetlagRegularity ??
                          'Chronotype, jetlag and regularity',
                      style: F.cap.copyWith(color: p.ink2)),
                ),
                Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
              ]),
              if (chrono.isNotEmpty || sjlH != null || sri != null) ...[
                const SizedBox(height: S.x4),
                InlineMetrics([
                  if (chrono['type_label'] != null)
                    (l?.healthChronotypeLabel ?? 'CHRONOTYPE',
                        chrono['type_label'].toString(), C.indigo),
                  if (sjlH != null)
                    (l?.healthSocialJetlagLabel ?? 'SOCIAL JETLAG',
                        _hoursHm(sjlH), C.orange),
                  if (sri != null)
                    (l?.healthRegularityLabel ?? 'REGULARITY',
                        '${sri.round()} / 100', C.green),
                ]),
              ],
            ]),
          ),
          action: l?.healthTabExplore ?? 'Explore',
          onAction: () => go(c, const CircadianDetail()),
        ),

      Section(
        l?.healthConsistencyTitle ?? 'Consistency',
        Surface(
          child: Consistency(
            // Already windowed to the last 30 calendar days by `HealthData.load`
            // — the clamp is a floor for a bad count, not the window.
            d.daysWithData.clamp(0, 30),
            30,
            l?.healthDaysWithRecord ??
                'Days with a derived record in the last 30 days',
            C.domHealth,
          ),
        ),
      ),
    ]);
  }

  String _hoursHm(num h) {
    final m = (h * 60).round();
    return m < 60 ? '${m}m' : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  // ─────────────── VITALS ───────────────
  Widget _vitals(BuildContext c, HealthData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final v = _v;
    if (v == null) {
      return _vFailed
          ? _readFailed(l?.healthWhatVitals ?? 'vitals', () {
              setState(() => _vFailed = false);
              _loadVitals();
            })
          : const Padding(
              padding: EdgeInsets.only(top: S.x8),
              child: Center(child: CircularProgressIndicator()),
            );
    }

    // WHICH DAY this tab is showing. Every row here used to say "Today" for a
    // day the loader had fallen back to, which after a sync gap is days ago.
    final behind = _behind(v.day);
    final isToday = behind == null || behind <= 0;
    final dayWord = isToday ? (l?.healthToday ?? 'Today') : prettyDay(v.day);
    // Skin temperature comes off the latest OVERNIGHT bundle, not the day the
    // other three rows describe, so it gets its own night when they differ.
    final tempNight = heldOverNightOf(d.today);

    final highs = v.timeline['highs'];
    num? high(String k) {
      final e = highs is Map ? highs[k] : null;
      return e is Map ? e['v'] as num? : null;
    }

    final lo = high('low_hr'), hi = high('peak_hr');
    final respBlock = v.lungs['resp'];
    final resp = respBlock is Map ? respBlock['value'] as num? : null;
    final worn = v.wear['worn_min'] as num?;
    final coverage = v.wear['coverage_pct'] as num?;
    final skinTemp = metricOf(d.today['skin_temp']);
    final rmssd = v.hrv['rmssd'] as num?;
    // MetricRow, not a private copy of it. The one this screen used to grow
    // stacked the value over its qualifier in a shrink-wrapped column, so
    // 'bpm today' and 'SD from your own nights' set each row's width and no
    // two values landed on the same x. The qualifier is not a unit and does
    // not belong beside the number: it goes under the name, where every other
    // list in the app already puts it.
    final rows = <Widget>[
      if (lo != null && hi != null)
        MetricRow(LucideIcons.heart, C.red, l?.healthRowHeartRate ?? 'Heart rate',
            '${lo.round()} – ${hi.round()}',
            sub: dayWord, unit: 'bpm'),
      if (resp != null)
        MetricRow(LucideIcons.wind, C.teal, l?.healthRowRespRate ?? 'Respiratory rate',
            resp.toStringAsFixed(1),
            sub: l?.healthSubAsleep ?? 'Asleep', unit: 'br/min'),
      if (skinTemp.value != null)
        // NAME THE QUANTITY. This is `skin_temp_z` — standard deviations from
        // the user's own baseline. It printed signed and unitless beside a
        // heart rate in bpm, so it read as °C; and the sleep scrub's
        // "temperature" is a THIRD quantity again (raw ADC minus that day's
        // median), which is why neither may go unlabelled.
        MetricRow(LucideIcons.thermometer, C.orange,
            l?.healthRowSkinTemp ?? 'Skin temperature',
            '${skinTemp.value! >= 0 ? '+' : '−'}'
                '${skinTemp.value!.abs().toStringAsFixed(2)}',
            sub: tempNight == null
                ? (l?.healthVsOwnNights ?? 'vs your own nights')
                : (l?.healthVsOwnNightsOn(prettyDay(tempNight)) ??
                    'vs your own nights · ${prettyDay(tempNight)}'),
            unit: 'SD',
            // Both this row and the wear row below it carry a FULL, written,
            // cited spec in `metric_detail.dart` that no tap in the app opened.
            // The number was on screen and its method was unreachable.
            onTap: () => go(c, const MetricDetail('skin_temp'))),
      if (worn != null)
        MetricRow(LucideIcons.watch, C.green, l?.healthRowWearTime ?? 'Wear time',
            hm(worn),
            // `83.33333333333333% of the day` shipped. It is a percentage.
            sub: coverage == null
                ? dayWord
                : (l?.healthCoverageOf(coverage.round(),
                        isToday ? (l.healthTheDay) : dayWord) ??
                    '${coverage.round()}% of '
                        '${isToday ? 'the day' : dayWord}'),
            onTap: () => go(c, const MetricDetail('wear'))),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...dayNavRow(_vDay ?? v.day, v.days, _goVitalsDay),
      if (rows.isEmpty)
        StatusCard(
          l?.healthNothingMeasuredDay ?? 'Nothing measured for this day',
          l?.healthNoBandRecordings ?? 'No band recordings reached this day.',
          fix: syncOf(c) == null ? '' : (l?.healthSyncTheBand ?? 'Sync the band'),
          icon: LucideIcons.watch,
          onFix: syncOf(c),
        )
      else
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: p.line, height: 1),
              rows[i],
            ],
          ]),
        ),

      // No skin-temperature caveat card here. The row's own unit already says
      // the reading is relative, and `metric_detail` carries the method for
      // anyone who taps through — a whole card restating it on the way past is
      // the kind of explanation this screen was asked to stop giving.

      // No "Sleep architecture" deep dive either: Sleep is a tab of its own,
      // and a second door into it from Vitals is a duplicate entry point, not
      // a feature.
      if (rmssd != null)
        Section(
          l?.healthDeepDivesTitle ?? 'Deep dives',
          DeepDiveCard(
              l?.healthHeartRateVariability ?? 'Heart rate variability',
              '${rmssd.round()}',
              'ms',
              l?.healthTimeFrequencyNonLinear ?? 'Time, frequency and non-linear',
              C.green,
              preview: _hrvPreview(c, d),
              onTap: () => go(c, const Investigate('hrv'))),
        ),
    ]);
  }

  /// The HRV preview inside the deep-dive card. Framed like every other chart:
  /// what it is, what it is measured in, what the heights mean, and how far
  /// back it reaches — all read off the series actually drawn.
  Widget _hrvPreview(BuildContext c, HealthData d) {
    const days = 30;
    final pts = d.points('hrv');
    // The window is thirty CALENDAR nights, dense, ending last night. The list
    // used to be the newest thirty STORED nights, which after a sync gap could
    // span two months while both axis labels — counted off the array — claimed
    // it spanned thirty. Nights with no record are holes, not joined across.
    final win = denseDays(pts, days);
    final have = [for (final v in win) ?v];
    final axis = AxisSpec.of(have, ticks: 2);
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return ChartFrame(
      title: l?.healthRmssdOfLastNights(have.length, days) ??
          'RMSSD, ${have.length} of the last $days nights',
      unit: 'ms',
      height: 48,
      yAxis: axis,
      xLabels: have.length < 2
          ? const []
          : [
              l?.healthNightsAgo(days - 1) ?? '${days - 1} nights ago',
              l?.healthSubLastNight ?? 'Last night',
            ],
      empty: have.length < 2
          ? NoData(
              message: l?.healthOneNightNotTrend ?? 'One night is not a trend yet')
          : null,
      series: win,
      child: CustomPaint(
        size: Size.infinite,
        painter: LineChart(win, p.on(C.green), t: animate(c, 1), axis: axis),
      ),
    );
  }

  // ─────────────── EXPLORE ───────────────
  Widget _explore(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final e = _e;
    if (e == null) {
      return _eFailed
          ? _readFailed(l?.healthMeasuresUnit ?? 'measures', () {
              setState(() => _eFailed = false);
              _loadExplore();
            })
          : const Padding(
              padding: EdgeInsets.only(top: S.x8),
              child: Center(child: CircularProgressIndicator()),
            );
    }

    var have = 0, total = 0;
    for (final f in _catalogue) {
      for (final r in f.rows) {
        total++;
        if ((e.counts[r.series] ?? 0) > 0) have++;
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Surface(
        child: Consistency(have, total,
            l?.healthMeasuresWithHistory ??
                'Measures with stored history on this device',
            C.domHealth,
            unit: l?.healthMeasuresUnit ?? 'measures'),
      ),
      const SizedBox(height: S.x3),
      // Not a promise of insight — a statement of what a tap gets you. Every
      // row below opens the same drill-down: the chart, your own range, the
      // method in full, and the paper it came from.
      Text(
          l?.healthEachOneOpens ??
              'Each one opens its chart, your own range, and how it is worked out.',
          style: F.over.copyWith(color: p.ink3, height: 1.6)),
      for (final f in _catalogue) _family(c, p, f, e.counts),
    ]);
  }

  Widget _family(BuildContext c, P p, _Cat f, Map<String, int> counts) {
    final l = AppLocalizations.of(c);
    final have = [
      for (final r in f.rows)
        if ((counts[r.series] ?? 0) > 0) r,
    ];
    final none = [
      for (final r in f.rows)
        if ((counts[r.series] ?? 0) == 0) r,
    ];

    return Section(
      _catTitle(l, f.title),
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (have.isNotEmpty)
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Column(children: [
              for (var i = 0; i < have.length; i++) ...[
                if (i > 0) Divider(color: p.line, height: 1),
                Builder(builder: (c) {
                  final r = have[i];
                  final s = specOf(r.key);
                  // NO NUMBER IN THE VALUE SLOT, on purpose.
                  //
                  // This used to print the day count. It read as a score: nine
                  // days of breathing rate beside seventeen of resting HR looks
                  // like the app is worse at breathing, when what it means is
                  // that the estimator abstains more — which is the behaviour
                  // we want. It also collapsed three different causes into one
                  // number: genuinely rare, key shipped last week, substrate
                  // pruned. `midsleep_sec` is forward-only and can never be
                  // backfilled, so it would sit at 1 next to everything else's
                  // 17 and mean nothing of the sort.
                  //
                  // And it was redundant. Rows with history sort above rows
                  // without, and the empty ones are named in the StatusCard
                  // below. Has / hasn't is the only thing an index owes you,
                  // and the layout already says it.
                  return MetricRow(s.icon, s.color, s.title, '',
                      sub: _rowBlurb(l, r.key, r.blurb),
                      onTap: () => go(c, MetricDetail(r.key)));
                }),
              ],
            ]),
          ),
        if (none.isNotEmpty) ...[
          if (have.isNotEmpty) const SizedBox(height: S.x3),
          StatusCard(
            have.isEmpty
                ? (l?.healthNothingMeasuredHere ?? 'Nothing measured here yet')
                : (l?.healthNotMeasuredYet ?? 'Not measured yet'),
            // No cause is named, because none is known here: this screen reads
            // a row count, and a count of zero says the day never produced one
            // — never why. No `fix:` either; there is no button that makes a
            // derive happen for a night that has already been scored.
            '${none.map((r) => specOf(r.key).title).join(' · ')}. '
                '${l?.healthNoDayProduced ?? 'No day on this device has '
                    'produced one yet.'}',
            icon: LucideIcons.chartLine,
          ),
        ],
      ]),
    );
  }

  // ─────────────── LABS ───────────────
  Widget _labs(BuildContext c) {
    final p = P.of(c);
    final loc = AppLocalizations.of(c);
    final l = _l;
    if (l == null) {
      return _lFailed
          ? _readFailed(loc?.healthWhatLabResults ?? 'lab results', () {
              setState(() => _lFailed = false);
              _loadLabs();
            })
          : const Padding(
              padding: EdgeInsets.only(top: S.x8),
              child: Center(child: CircularProgressIndicator()),
            );
    }

    final sex = (_d?.profile['sex'])?.toString();
    // Newest draw per marker. `labResults` is already taken_on DESC.
    final latest = <String, Map<String, dynamic>>{};
    for (final r in l.results) {
      latest.putIfAbsent(r['marker'].toString(), () => r);
    }
    final byKey = {for (final m in l.markers) m.key: m};
    // A stored result with no number is not a measurement — it is dropped, the
    // way MonoTable drops an empty row. A bare em-dash in a lab column reads as
    // "the assay failed", which is a claim about your blood.
    final rows = latest.values.where((r) => r['value'] is num).toList()
      ..sort((a, b) => (byKey[a['marker']]?.label ?? '')
          .compareTo(byKey[b['marker']]?.label ?? ''));
    final lastDraw = l.results.isEmpty ? null : l.results.first['taken_on'];
    // Markers the user named themselves — the only ones whose DEFINITION is
    // theirs to remove. A catalogue marker is the app's and stays.
    final mine = l.markers.where((m) => m.custom).toList();
    final counts = <String, int>{};
    for (final r in l.results) {
      final k = r['marker'].toString();
      counts[k] = (counts[k] ?? 0) + 1;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (rows.isEmpty)
        StatusCard(
          loc?.healthNoLabResults ?? 'No lab results',
          loc?.healthNoLabResultsBody ??
              'Nothing logged. Anything you add here stays on this device, '
                  'and anything you remove is gone from it.',
          icon: LucideIcons.testTube,
        )
      else ...[
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: p.line, height: 1),
              _lab(p, byKey[rows[i]['marker'].toString()], rows[i], sex,
                  () => _removeResult(byKey[rows[i]['marker'].toString()],
                      rows[i], l)),
            ],
          ]),
        ),
        const SizedBox(height: S.x3),
        Text(
            loc?.healthLastPanel(lastDraw?.toString() ?? '') ??
                'Last panel ${lastDraw ?? ''} · logged by hand',
            style: F.over.copyWith(color: p.ink3)),
      ],
      if (mine.isNotEmpty) _myMarkers(p, mine, counts),
      const SizedBox(height: S.x4),
      BigButton(loc?.healthAddAResult ?? 'Add a result',
          icon: LucideIcons.plus,
          color: C.blue,
          soft: true,
          onTap: () => _addLab(c, l)),
      const SizedBox(height: S.x4),
      // The app never prints "abnormal" anywhere, so it does not need to say
      // it does not. What the user cannot know without being told is that the
      // range shown here is not the range their own lab used.
      Text(loc?.healthRangesDifferByLab ??
              'Ranges differ by lab. Use the one on your report.',
          style: F.over.copyWith(color: p.ink3, height: 1.6)),
    ]);
  }

  Widget _lab(P p, LabMarker? m, Map<String, dynamic> r, String? sex,
      VoidCallback onRemove) {
    final l = AppLocalizations.of(context);
    final v = (r['value'] as num?)?.toDouble();
    final unit = (r['unit'] ?? m?.unit ?? '').toString();
    final range = m?.rangeFor(sex);
    final inRange = v == null || m == null ? null : m.inRange(v, sex: sex);

    // The whole row is the control, with the bin as its affordance — the same
    // shape a logged meal takes, and it costs no width, which at 3x text is
    // the difference between a row that fits and one that overflows.
    return Pressable(
      onTap: onRemove,
      semanticLabel: l?.healthRemoveMarkerFrom(
              (m?.label ?? r['marker']).toString(), r['taken_on'].toString()) ??
          'Remove ${m?.label ?? r['marker']} from ${r['taken_on']}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              // No interval means NO OPINION — a grey dot, never a green one.
              color: inRange == null
                  ? p.ink3
                  : (inRange ? p.on(C.green) : p.on(C.orange)),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m?.label ?? r['marker'].toString(),
                  style: F.body.copyWith(color: p.ink)),
              Text(
                  range == null
                      ? (l?.healthNoReferenceInterval(r['taken_on'].toString()) ??
                          'No reference interval · ${r['taken_on']}')
                      : (l?.healthTypicalRange(_num(range.low), _num(range.high),
                              r['taken_on'].toString()) ??
                          'Typical ${_num(range.low)}–${_num(range.high)} · '
                              '${r['taken_on']}'),
                  style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          const SizedBox(width: S.x2),
          Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(v == null ? '' : (m?.format(v) ?? v.toString()),
                    style: F.n17.copyWith(
                        color: inRange == false ? p.on(C.orange) : p.ink)),
                const SizedBox(width: 3),
                Text(unit, style: F.over.copyWith(color: p.ink3)),
              ]),
          // This is the user's own blood work in an app that keeps it on their
          // phone; being able to take it back out is the premise, not a setting.
          const SizedBox(width: S.x2),
          Icon(LucideIcons.trash2, size: 16, color: p.ink3),
        ]),
      ),
    );
  }

  /// One reading of one marker on one date. Named in full before it goes:
  /// there is no undo here, and a generic "are you sure?" over a column of
  /// blood results is how the wrong one is lost.
  Future<void> _removeResult(
      LabMarker? m, Map<String, dynamic> r, LabsData l) async {
    final loc = AppLocalizations.of(context);
    final marker = r['marker'].toString();
    final takenOn = r['taken_on'].toString();
    final label = m?.label ?? marker;
    final v = (r['value'] as num).toDouble();
    final unit = (r['unit'] ?? m?.unit ?? '').toString();
    // The row on screen is the NEWEST draw of its marker, so an earlier one
    // takes its place rather than the marker disappearing — which without
    // being told reads as the delete having failed.
    final older = l.results.firstWhere(
      (o) => o['marker'] == marker && o['taken_on'] != takenOn,
      orElse: () => const <String, dynamic>{},
    )['taken_on'];

    final ok = await confirmRemove(
      context,
      title: loc?.healthRemoveLabelFrom(label, takenOn) ??
          'Remove $label from $takenOn?',
      body: (loc?.healthRemoveLabBody(m?.format(v) ?? _num(v), unit) ??
              'The ${m?.format(v) ?? _num(v)} $unit you logged for that draw. '
                  'It leaves this device and there is no undo.') +
          (older == null
              ? ''
              : (loc?.healthRemoveLabOlderNote(older) ??
                  ' Your $older draw stays, and shows here instead.')),
    );
    if (!ok || !mounted) return;
    await LocalDb.deleteLabResult(marker, takenOn);
    _l = null;
    await _loadLabs();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(older == null
          ? (loc?.healthRemovedNoneLeft(label, takenOn) ??
              'Removed $label from $takenOn. No $label results left.')
          : (loc?.healthRemovedShowingOlder(label, takenOn, older) ??
              'Removed $label from $takenOn. Showing your $older draw now.')),
    ));
  }

  /// Markers the user named. Only the DEFINITION is theirs to remove here —
  /// see [_removeMarker] for why one holding results is refused.
  Widget _myMarkers(P p, List<LabMarker> mine, Map<String, int> counts) {
    final l = AppLocalizations.of(context);
    return Section(
      l?.healthMarkersYouNamed ?? 'Markers you named',
      Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (var i = 0; i < mine.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            Pressable(
              semanticLabel: l?.healthRemoveTheMarker(mine[i].label) ??
                  'Remove the ${mine[i].label} marker',
              onTap: () => _removeMarker(mine[i], counts[mine[i].key] ?? 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(mine[i].label,
                              style: F.body.copyWith(color: p.ink)),
                          Text(
                              (counts[mine[i].key] ?? 0) == 0
                                  ? (l?.healthNothingLoggedUnderIt ??
                                      'Nothing logged under it')
                                  : (l?.healthResultsCount(
                                          counts[mine[i].key] ?? 0,
                                          mine[i].unit) ??
                                      '${counts[mine[i].key]} '
                                          '${(counts[mine[i].key] ?? 0) == 1 ? 'result' : 'results'} · '
                                          '${mine[i].unit}'),
                              style: F.over.copyWith(color: p.ink3)),
                        ]),
                  ),
                  const SizedBox(width: S.x2),
                  Icon(LucideIcons.trash2, size: 16, color: p.ink3),
                ]),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  /// Removing a marker DEFINITION, which is not the same act as removing its
  /// readings — `deleteLabMarkerDef` deliberately leaves those alone, because
  /// they were real draws and each row carries its own unit.
  ///
  /// But this screen labels a result THROUGH its marker, so a definition
  /// deleted out from under one leaves the reading rendering as its raw
  /// storage key with no interval. Both ways out of that are worse than this
  /// one: deleting the readings too destroys blood work nobody asked to
  /// destroy, and keeping them degrades a number this app calls absolute. So
  /// a marker that still holds results is refused, and says how to proceed —
  /// the results are one screen up, each removable on its own.
  Future<void> _removeMarker(LabMarker m, int results) async {
    final l = AppLocalizations.of(context);
    if (results > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l?.healthStillHoldsResults(results, m.label) ??
            '${m.label} still holds $results '
                '${results == 1 ? 'result' : 'results'}. Remove those first — '
                'the marker is what labels them.'),
      ));
      return;
    }
    final ok = await confirmRemove(
      context,
      title: l?.healthRemoveMarkerQ(m.label) ?? 'Remove ${m.label}?',
      body: l?.healthRemoveMarkerBody ??
          'It leaves the marker list, so you can no longer log it. Nothing '
              'measured goes with it — you have no results under it.',
    );
    if (!ok || !mounted) return;
    await LocalDb.deleteLabMarkerDef(m.key);
    _l = null;
    await _loadLabs();
  }

  String _num(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// Deliberately plain. Entering blood work is a rare, careful act; it does
  /// not need a designed flow, it needs the marker, the number and the date.
  Future<void> _addLab(BuildContext c, LabsData l) async {
    final loc = AppLocalizations.of(c);
    var marker = l.markers.first;
    final value = TextEditingController();
    final now = DateTime.now();
    final takenOn = TextEditingController(
        text: '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}');

    final ok = await showDialog<bool>(
      context: c,
      builder: (dc) => StatefulBuilder(
        builder: (dc, setLocal) => AlertDialog(
          title: Text(loc?.healthAddAResult ?? 'Add a result'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Unlabelled it announces only its current value — a marker
              // name, with no statement of what the field is.
              Semantics(
                label: loc?.healthMarkerLabel ?? 'Marker',
                child: DropdownButton<LabMarker>(
                  isExpanded: true,
                  value: marker,
                  items: [
                    for (final m in l.markers)
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: (m) => setLocal(() => marker = m ?? marker),
                ),
              ),
              TextField(
                controller: value,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText:
                        loc?.healthValueUnit(marker.unit) ?? 'Value (${marker.unit})'),
              ),
              TextField(
                controller: takenOn,
                decoration: InputDecoration(
                    labelText: loc?.healthDateDrawn ?? 'Date drawn (YYYY-MM-DD)'),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dc).pop(false),
                child: Text(loc?.actionCancel ?? 'Cancel')),
            TextButton(
                onPressed: () => Navigator.of(dc).pop(true),
                child: Text(loc?.actionSave ?? 'Save')),
          ],
        ),
      ),
    );

    if (ok != true || !mounted) return;
    // Blood work typed by hand is exactly the input nobody notices is missing,
    // so nothing here fails quietly: the dialog used to close on Save and the
    // result was dropped whenever the value carried its unit ("78 ng/mL") or
    // the date was written the other way round.
    final v = Typed.of(value.text);
    final date = takenOn.text.trim();
    if (v.value == null || DateTime.tryParse(date) == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(v.value == null
            ? (loc?.healthValueMustBeNumber ??
                'The value needs to be a number on its own, without the unit. '
                    'Nothing was saved.')
            : (loc?.healthDateFormatError ??
                'The date needs to be YYYY-MM-DD. Nothing was saved.')),
      ));
      return;
    }
    try {
      await LocalDb.putLabResult(
        marker: marker.key,
        takenOn: date,
        value: v.value!,
        unit: marker.unit,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                loc?.healthCouldNotSaveIt(e.toString()) ?? 'Could not save it: $e')));
      }
      return;
    }
    _l = null;
    await _loadLabs();
  }
}
