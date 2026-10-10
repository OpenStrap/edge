// BEATS — the RR-derived family, as pictures.
//
// This app recovers beat-to-beat intervals from the band's 1 Hz records and
// computes a whole family off them: Poincaré geometry, per-bin nightly RMSSD,
// PRSA deceleration capacity, an irregular-rhythm screen. Until this screen
// existed all of it rendered as rows of numbers on Nerd stats, at a density
// most people never open. Nothing here is new arithmetic — every value on this
// screen was already computed and already persisted. What is new is that the
// three of them that are SHAPES are finally drawn as shapes.
//
// ── WHAT IS DELIBERATELY NOT HERE ────────────────────────────────────────────
//
// PRSA's averaged profile. The brief for this screen asked for deceleration
// capacity as a waveform, "which is what `prsa_dc_anchors` is for". It is not:
// `prsa_dc_anchors` is the ANCHOR COUNT, and `PrsaResult.profile` — the actual
// averaged waveform — is dropped by `toJson`, so nothing persists it. Even if
// it did, the pipeline runs PRSA at l = 2, so the profile is FOUR samples. Four
// points is not a waveform and drawing it as one would claim a resolved
// deceleration shape we do not have. DC is trended as a number instead.
//
// The apnea / cyclic-variation panel. It was asked for as "a visible
// oscillation in the tachogram" and it cannot be drawn honestly:
//   * no cycle TIMES are persisted — `CvhrResult` keeps counts, means and
//     quartiles, so there is no stretch of night to zoom to;
//   * at whole-night scale one horizontal pixel is ~80 s and a CVHR cycle is
//     10–120 s, so any curve here would be sub-pixel texture that a reader
//     would over-read as "the pattern";
//   * every summary that IS drawable is a per-night value, and a per-night
//     value is exactly what RESP-01 forbids on this surface.
// The honest form — the 30-night personal distribution — already exists on Nerd
// stats under Respiratory rate, and stays there. Four panels that are true.
//
// ── THE RULES THIS FILE IS UNDER ─────────────────────────────────────────────
//
// * Deceleration capacity gets no threshold, no colour and no reference range,
//   ever. See `_dc`.
// * The rhythm panel is a SCREEN, never AF detection. No percentage of
//   abnormal beats, no arrhythmia vocabulary, "not screened" visually distinct
//   from "clear", and a permanent line — not a tooltip — that a clear strip
//   means nothing. See `_rhythm`.
// * gen4 and gen5/MG nightly RMSSD are not comparable; nothing here presents
//   two families as one series without saying so.
// * `rr_ts_ms` is still `rec_ts * 1000`, so it is not a beat clock. There now
//   IS one beside it — `decoded_rr.beat_ts_ms`, anchored on the record's
//   measured `tsSubsec` — but it is NULL for every row banked before that
//   column existed, because nothing stored the sub-second and the frames are
//   pruned. Nothing on this screen is drawn against a beat-level clock either
//   way: the scatter is intervals against intervals, and the night curve is
//   binned at half an hour. Anything that starts using `beat_ts_ms` has to
//   carry the null era, which is most of this database.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/journal_fields.dart' show formatMinuteOfDay;
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart';
import '../ui2.dart';
import 'home_screen.dart';
import 'investigate.dart';
import 'metric_detail.dart';

// ═══════════════════ the data ═══════════════════

/// One bin of the night's HRV curve, as `hrv_night_shape` stored it.
typedef NightBin = ({int startSec, int nBeats, double? v, double? lo, double? hi});

class BeatsData {
  /// The day every panel on this screen describes. One day, stated once — a
  /// scatter from one night beside a curve from another is the failure this
  /// screen has most available to it.
  final String? day;

  /// Every derived day, newest first — what [DayNav] steers over.
  final List<String> days;

  /// Cleaned NN intervals for [day]'s sleep window, and what they cost.
  /// Empty once the raw records are pruned; that is a steady state, not a bug.
  final List<double> nn;
  final int rawBeats;
  final double cleanFraction;

  /// `clinical.irregular` — the SLEEP Poincaré screen, over the same beats.
  final Map<String, dynamic> poincare;

  /// `hrv_night_shape` — per-bin RMSSD with lo/hi bounds, holes preserved.
  final List<NightBin> bins;
  final double? firstThirdMs, lastThirdMs;
  final Metric shape;

  /// The wall clock the bins' second offsets are counted from — the first beat
  /// of the night. Null when there were no beats to place, which is the only
  /// case the x axis may not be dated in.
  final int? originMs;

  /// Deceleration capacity: the stored per-day series, plus last night's
  /// anchor count — which never leaves the number's side.
  final List<ChartPoint> dcPoints;
  final int? dcAnchors;
  final Metric dc;

  /// `irregular_rhythm_flag` — 1/0 per DERIVED day. A day with no row and a day
  /// the screen abstained on are the same absence here, and this screen says so
  /// rather than guessing which.
  final List<ChartPoint> rhythmPoints;

  /// Last night's whole-day screen envelope, for its abstention reason.
  final Object? rhythm24h;

  /// Which strap measured [day], when the bundle recorded one.
  final String? deviceFamily;

  const BeatsData({
    this.day,
    this.days = const [],
    this.nn = const [],
    this.rawBeats = 0,
    this.cleanFraction = 0,
    this.poincare = const {},
    this.bins = const [],
    this.firstThirdMs,
    this.lastThirdMs,
    this.shape = const Metric(),
    this.originMs,
    this.dcPoints = const [],
    this.dcAnchors,
    this.dc = const Metric(),
    this.rhythmPoints = const [],
    this.rhythm24h,
    this.deviceFamily,
  });

  static Future<BeatsData> load(LocalRepository repo, {String? want}) async {
    final today = await repo.getToday();
    final days = await repo.availableDays();
    final day = pickDay(
        days, want, (today['status'] as Map?)?['today_day']?.toString());
    if (day == null) return BeatsData(days: days);

    final hrv = await repo.getDayHrv(day);
    final heart = await repo.getDayHeart(day);
    final beats = await repo.getNightBeats(day);
    final dcEnv = hrv['prsa_dc'];
    final shapeEnv = hrv['night_shape'];

    return BeatsData(
      day: day,
      days: days,
      nn: beats.nn,
      rawBeats: beats.rawBeats,
      cleanFraction: beats.cleanFraction,
      poincare: hrv['irregular'] is Map
          ? (hrv['irregular'] as Map).cast<String, dynamic>()
          : const {},
      bins: _bins(shapeEnv),
      firstThirdMs: (envValue(shapeEnv)?['first_third_ms'] as num?)?.toDouble(),
      lastThirdMs: (envValue(shapeEnv)?['last_third_ms'] as num?)?.toDouble(),
      shape: metricOf(shapeEnv),
      originMs: shapeEnv is Map ? (shapeEnv['origin_ms'] as num?)?.toInt() : null,
      dcPoints: pointsOf(await repo.getChart('prsa_dc')),
      dcAnchors: (envValue(dcEnv)?['anchors'] as num?)?.toInt(),
      dc: metricOf(dcEnv),
      rhythmPoints: pointsOf(await repo.getChart('irregular_rhythm_flag')),
      rhythm24h: heart['irregular_24h'],
      deviceFamily: hrv['device_family']?.toString(),
    );
  }

  /// The stored bins, in order, holes intact. A bin with no `rmssd_ms` keeps
  /// its slot and its beat count — "we had 40 beats here" is the reason it
  /// abstained, and it is not a bare dash.
  static List<NightBin> _bins(Object? env) {
    final raw = envValue(env)?['bins'];
    if (raw is! List) return const [];
    return [
      for (final b in raw)
        if (b is Map)
          (
            startSec: (b['t'] as num?)?.toInt() ?? 0,
            nBeats: (b['n_beats'] as num?)?.toInt() ?? 0,
            v: (b['rmssd_ms'] as num?)?.toDouble(),
            lo: (b['lo_ms'] as num?)?.toDouble(),
            hi: (b['hi_ms'] as num?)?.toDouble(),
          ),
    ];
  }
}

// ═══════════════════ the screen ═══════════════════

/// The beat-interval screen. Reached from HRV, never from a tab — it is a
/// place you walk to, and there is no sixth tab.
class Beats extends StatefulWidget {
  final BeatsData? data;

  /// The night to open. Null means the newest derived one.
  final String? day;

  const Beats({super.key, this.data, this.day});

  @override
  State<Beats> createState() => _BeatsState();
}

class _BeatsState extends State<Beats> {
  BeatsData? _d;
  bool _loading = true;
  String? _day;
  // A quick second tap on the day stepper starts a second load; the first
  // can finish last and must not paint the old day under the new label.
  int _loadToken = 0;

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

  Future<void> _load() async {
    final token = ++_loadToken;
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final d = await BeatsData.load(repo, want: _day);
      if (mounted && token == _loadToken) {
        setState(() => (_d = d, _loading = false));
      }
    } catch (_) {
      if (mounted && token == _loadToken) setState(() => _loading = false);
    }
  }

  void _goDay(String day) {
    setState(() {
      _day = day;
      _loading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final d = _d ?? const BeatsData();
    return detailScaffold(
      c,
      l?.beatsTitle ?? 'Beats',
      [
        ...dayNavRow(_day ?? d.day, d.days, _goDay),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: S.x8),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (d.day == null)
          StatusCard(
            l?.beatsNoNightTitle ?? 'No night to draw yet',
            l?.beatsNoNightBody ??
                'No night has been scored on this phone yet, so there are no heartbeats to plot.',
            fix: l?.beatsNoNightFix ?? 'Wear the band overnight, then sync',
            icon: LucideIcons.heartPulse,
          )
        else ...[
          _poincare(c, d),
          const SizedBox(height: S.x5),
          _nightCurve(c, d),
          const SizedBox(height: S.x5),
          _dc(c, d),
          const SizedBox(height: S.x5),
          _rhythm(c, d),
          const SizedBox(height: S.x5),
          investigateRow(c,
              () => go(c, Investigate('hrv', day: _day ?? d.day))),
        ],
      ],
      // WHICH NIGHT, in the app's one day format. Every panel below describes
      // this one night; saying so once at the top is what lets them sit
      // together without each having to date itself.
      sub: d.day == null
          ? ''
          : (l?.beatsNightOf(prettyDay(d.day, l)) ??
              'Night of ${prettyDay(d.day, l)}'),
    );
  }

  // ── 1 · POINCARÉ ───────────────────────────────────────────────────────────
  //
  // The iconic HRV picture, and the one the app came closest to already having:
  // SD1 and SD2 are the two axes of this cloud and both were computed, stored
  // and printed as bare integers. The scatter IS the two numbers.
  Widget _poincare(BuildContext c, BeatsData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final sd1 = (d.poincare['sd1'] as num?)?.toDouble();
    final sd2 = (d.poincare['sd2'] as num?)?.toDouble();

    if (d.nn.length < 2) {
      return Section(
        l?.beatsPoincareSection ?? 'Every beat against the one before it',
        StatusCard(
          l?.beatsBeatsGoneTitle ??
              'The beats for this night are no longer on this phone',
          // The metric's own reason first, but there rarely is one: this is
          // not an abstention, it is retention. The raw records are deleted a
          // few days after the night is scored, and everything computed FROM
          // them survives — which is why SD1 and SD2 can still be printed on
          // Nerd stats for a night whose cloud can no longer be drawn.
          '${l?.beatsBeatsGoneBody ?? 'Individual beat intervals are kept '
              'for a few days after the night is scored, then deleted. The '
              'numbers taken from them are kept for good'}'
              // NEVER `sd2 ?? 0`: a missing long-term axis printed as "SD2
              // 0 ms" is a fabricated measurement, and 0 is the one value that
              // reads as a finding.
              '${sd1 == null || sd2 == null ? '' : (l?.beatsBeatsGoneMeasured(
                      metricValue('ms', sd1), metricValue('ms', sd2)) ??
                  ' — this night measured '
                      'SD1 ${metricValue('ms', sd1)} ms, '
                      'SD2 ${metricValue('ms', sd2)} ms')}.',
          icon: LucideIcons.scatterChart,
        ),
      );
    }

    final axis = AxisSpec.of(d.nn, ticks: 4)!;
    final dropped = d.rawBeats - d.nn.length;
    return Section(
      l?.beatsPoincareSection ?? 'Every beat against the one before it',
      Surface(
        child: Column(children: [
          ChartFrame(
            title: l?.beatsScatterTitle ??
                'Each interval, plotted against the previous one',
            unit: 'ms',
            height: 260,
            yAxis: axis,
            // No `series:` — the spoken form of 26 000 intervals is
            // "up 4 ms across 26 747 readings", which is a sentence about a
            // trend this picture does not draw. The footnote below carries the
            // meaning instead, and the frame speaks it.
            footnote: l?.beatsScatterFootnote ??
                'The diagonal is where a beat came out the same length '
                    'as the one before it. Spread across that line is SD1, '
                    'beat to beat; spread along it is SD2, the slower drift.',
            child: CustomPaint(
              size: Size.infinite,
              painter: Poincare(d.nn, p.on(C.green), axis: axis, grid: p.line),
            ),
          ),
          const SizedBox(height: S.x4),
          InlineMetrics([
            if (sd1 != null)
              (l?.beatsSd1Label ?? 'SD1', '${metricValue('ms', sd1)} ms',
                  C.green),
            if (sd2 != null)
              (l?.beatsSd2Label ?? 'SD2', '${metricValue('ms', sd2)} ms',
                  C.green),
            (l?.beatsIntervalsLabel ?? 'Intervals', thousands(d.nn.length),
                C.green),
          ]),
          const SizedBox(height: S.x4),
          _note(
            p,
            // The denominator, and the honesty about what the wrist sees.
            '${l?.beatsIntervalsSurvived(d.nn.length) ?? '${thousands(d.nn.length)} intervals survived correction'}'
            '${dropped <= 0 ? '' : (l?.beatsDroppedArtifact(dropped) ?? ' — $dropped were rejected as artifact and '
                'are not in the cloud')}. '
            '${l?.beatsPulseNotEcg ?? 'Pulse, not ECG — real and yours, but '
                'not the picture an ECG draws.'}'
            '${d.deviceFamily == null ? '' : ' ${l?.beatsMeasuredOn(d.deviceFamily!) ?? 'Measured on ${d.deviceFamily}; '
                'straps do not read the same numbers as each other.'}'}',
          ),
        ]),
      ),
    );
  }

  // ── 2 · THE NIGHT'S HRV CURVE ──────────────────────────────────────────────
  //
  // A BAND, never a line. Every bin ships lo/hi because RMSSD from a few
  // hundred beats has real sampling spread, and a single line drawn through the
  // points claims a precision the beats do not carry. Bins under the beat floor
  // abstain and stay in the series as HOLES, so a charging gap breaks the shape
  // instead of being drawn through.
  //
  // It describes. It never says why: a suppressed first third is consistent
  // with alcohol, a late meal, late training, a hot room, illness onset, or
  // nothing at all, and nothing in this path can tell those apart.
  Widget _nightCurve(BuildContext c, BeatsData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final present = [for (final b in d.bins) if (b.v != null) b];
    if (present.isEmpty) {
      return Section(
        l?.beatsVariabilitySection ?? 'Variability across the night',
        StatusCard.forMetric(
                l?.beatsVariabilitySection ?? 'Variability across the night',
                d.shape,
                unit: l?.beatsUnitNights ?? 'nights',
                why: l?.beatsVariabilityWhy ??
                    'No half-hour block of this night had enough clean beats to show HRV.') ??
            StatusCard(
                l?.beatsVariabilitySection ?? 'Variability across the night',
                l?.beatsNoBinsStored ?? 'No bins were stored for this night.'),
      );
    }

    final axis = AxisSpec.of(
      [for (final b in present) ...[b.lo ?? b.v!, b.hi ?? b.v!]],
      ticks: 3,
    )!;
    final holes = d.bins.length - present.length;

    return Section(
      l?.beatsVariabilitySection ?? 'Variability across the night',
      Surface(
        child: Column(children: [
          ChartFrame(
            title: l?.beatsRmssdTitle ?? 'HRV in half-hour blocks',
            unit: 'ms',
            height: 150,
            yAxis: axis,
            // The real clock, off `origin_ms` — which is stored for exactly
            // this and had no reader. Falls back to elapsed hours when the
            // night had no beats to place an origin on, and never to a
            // hardcoded pair: an x axis that does not describe the range
            // actually drawn is worse than none.
            xLabels: _nightHours(c, d),
            series: [for (final b in d.bins) b.v],
            footnote:
                '${l?.beatsBandFootnote ?? 'The bar is how sure we are of '
                    'the bin, not a range your body passed through. The '
                    'mark inside it is the value.'}'
                '${holes == 0 ? '' : (l?.beatsHolesFootnote(holes) ?? ' $holes ${holes == 1 ? 'bin holds' : 'bins hold'} '
                    'too few clean beats to publish one, and '
                    '${holes == 1 ? 'is' : 'are'} left empty rather than '
                    'joined across.')}',
            child: _NightBand(d.bins, axis,
                color: p.on(C.green), empty: p.line),
          ),
          if (d.firstThirdMs != null && d.lastThirdMs != null) ...[
            const SizedBox(height: S.x4),
            InlineMetrics([
              (l?.beatsFirstThird ?? 'First third',
                  '${metricValue('ms', d.firstThirdMs!)} ms', C.green),
              (l?.beatsLastThird ?? 'Last third',
                  '${metricValue('ms', d.lastThirdMs!)} ms', C.green),
            ]),
          ],
          // The estimator's own note is NOT rendered here. A present
          // `nightHrvShape` note is method text addressed to whoever is
          // drawing it — it ends "Render each bin as a band, not a point" —
          // and verbatim pipeline strings are what Nerd stats is for. Its
          // ABSTENTION reason does get shown, by `StatusCard.forMetric` in the
          // branch above, which is the case a reason is actually an answer.
        ]),
      ),
    );
  }

  // ── 3 · DECELERATION CAPACITY ──────────────────────────────────────────────
  //
  // NO THRESHOLD, NO COLOUR, NO REFERENCE RANGE, EVER. Bauer's strata are
  // 24 h Holter ECG in post-MI patients; every wrist-PPG night we have measured
  // sits below that whole table, so the tier printed "low risk" or worse for a
  // healthy person forever, and on one subject across three straps inside nine
  // days it was decided by which band he happened to be wearing.
  //
  // Worse for a chart specifically: PRSA anchors on decelerations, and
  // pulse-arrival jitter ATTENUATES DC by a factor that varies with signal
  // quality — so a rising line can be a cleaner-signal line. The artifact gate
  // and the anchor count go beside it, always, and the ink is neutral: an
  // accent colour on this series would be a verdict.
  Widget _dc(BuildContext c, BeatsData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    if (d.dcPoints.isEmpty) {
      return Section(
        l?.beatsDcSection ?? 'Deceleration capacity',
        StatusCard.forMetric(
                l?.beatsDcSection ?? 'Deceleration capacity', d.dc,
                unit: l?.beatsUnitNights ?? 'nights',
                why: l?.beatsDcWhy ??
                    'No stored night has produced one yet.') ??
            StatusCard(l?.beatsDcSection ?? 'Deceleration capacity',
                l?.beatsDcNoData ?? 'No night has produced one yet.'),
      );
    }

    const win = 30;
    final series = denseDays(d.dcPoints, win);
    final vals = [for (final v in series) ?v];
    final axis = AxisSpec.of(vals, ticks: 3, format: axisFixed);

    return Section(
      l?.beatsDcSection ?? 'Deceleration capacity',
      Surface(
        child: Column(children: [
          ChartFrame(
            title: l?.beatsDcChartTitle ?? 'Your own nights, in order',
            unit: 'ms',
            height: 130,
            yAxis: axis,
            xLabels: [
              l?.beatsDaysAgo(win - 1) ?? '${win - 1} days ago',
              l?.beatsTodayLabel ?? 'Today',
            ],
            series: series,
            empty: axis == null ? const NoData() : null,
            child: CustomPaint(
              size: Size.infinite,
              // Neutral ink and no fill, on purpose. A green line is a verdict,
              // and a filled area is a quantity measured from a baseline this
              // number does not have.
              painter: LineChart(series, p.ink2,
                  fill: false, dots: true, t: animate(c, 1), dotInk: p.card,
                  axis: axis),
            ),
          ),
          const SizedBox(height: S.x4),
          InlineMetrics([
            if (d.dcAnchors != null)
              (l?.beatsAnchorsLastNight ?? 'Anchors last night',
                  thousands(d.dcAnchors), C.indigo),
            if (d.cleanFraction > 0)
              (l?.beatsCleanBeats ?? 'Clean beats',
                  '${(d.cleanFraction * 100).toStringAsFixed(1)}%', C.indigo),
          ]),
          const SizedBox(height: S.x4),
          _note(
            p,
            l?.beatsDcNote ??
                'Yours only. Compare it against your own other nights and '
                    'nothing else — there is no reference band for a '
                    'wrist.\n\n'
                    'It averages the beats around each moment your heart '
                    'slowed. A rising line can be a cleaner signal rather '
                    'than a different heart, so read it beside the anchor '
                    'count and clean-beat share above. If you changed straps '
                    'inside this window, the two halves do not compare.',
          ),
        ]),
      ),
    );
  }

  // ── 4 · THE RHYTHM STRIP ───────────────────────────────────────────────────
  //
  // A SCREEN. Never AF detection, never a diagnosis, no percentage of abnormal
  // beats, and no arrhythmia vocabulary anywhere on the card. The two things
  // this panel exists to keep apart are "the screen ran and did not fire" and
  // "the screen never ran" — so those are drawn as a fill and an outline, not
  // as two shades of the same mark.
  //
  // The line saying a clear strip means nothing is PERMANENT and on the card.
  // Not a tooltip, not a detail screen: an absent flag is not a negative
  // result, and the only place that can be said is beside the marks.
  Widget _rhythm(BuildContext c, BeatsData d) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    const win = 30;
    final flags = denseDays(d.rhythmPoints, win);
    final screened = flags.where((v) => v != null).length;
    final fired = flags.where((v) => v != null && v >= 1).length;
    // The ABSTENTION REASON only — "why last night was not screened" — never
    // the note a successful screen carries. That one ends "Discuss with a
    // clinician only if you have symptoms", and "you have" is the grammar of a
    // diagnosis: banned on this surface, greppable, and it would have been
    // rendered straight onto the card.
    // `envValue`, NOT `Metric.isEmpty`: this envelope's `value` is a MAP, and
    // `Metric.parse` reads any non-num value as absent — so `isEmpty` is true
    // for a screen that ran perfectly well, and gating on it published the
    // note in exactly the case it must not.
    final note = envValue(d.rhythm24h) == null
        ? metricOf(d.rhythm24h).note
        : null;

    return Section(
      l?.beatsRhythmSection ?? 'Rhythm screen',
      Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ChartFrame(
            title: l?.beatsRhythmChartTitle ?? 'One cell per day',
            unit: l?.beatsUnitScreenedNotScreened ?? 'screened / not screened',
            height: 44,
            xLabels: [
              l?.beatsDaysAgo(win - 1) ?? '${win - 1} days ago',
              l?.beatsTodayLabel ?? 'Today',
            ],
            legend: [
              (l?.beatsScreenNotFired ?? 'Screen did not fire', p.ink3),
              (l?.beatsScreenFired ?? 'Screen fired', p.on(C.orange)),
              (l?.beatsNotScreened ?? 'Not screened', p.line),
            ],
            empty: screened == 0
                ? NoData(
                    message: l?.beatsNoDayScreened ??
                        'No day in this window was screened')
                : null,
            child: _RhythmStrip(flags,
                clear: p.ink3, fired: p.on(C.orange), absent: p.ink3),
          ),
          const SizedBox(height: S.x4),
          _note(
            p,
            l?.beatsScreenNote ??
                'A screen, not a test.\n\n'
                    'A day the screen did not fire is not a day you were '
                    'cleared — it cannot rule anything out, and it never '
                    'could. Outlined days were not screened at all: too few '
                    'clean beats, or too much movement.\n\n'
                    // "a clinician can test that properly" is the project's
                    // settled termination for this whole surface — the same
                    // sentence the CVHR card ends on. It ends in a person,
                    // never in a number. The symptom clause is phrased to
                    // keep the string "you have" off the screen entirely:
                    // that is the grammar of a diagnosis, and the wiring
                    // test greps for it on the neighbouring card.
                    'Wrist pulse is not an ECG. If symptoms are what brought '
                    'you here, a clinician can test that properly.',
          ),
          const SizedBox(height: S.x3),
          _note(
            p,
            '${l?.beatsScreenedSummary(screened, win) ?? '$screened of the last $win days were screened'}'
            '${fired == 0 ? '' : (l?.beatsFiredSummary(fired) ?? '; the screen fired on $fired')}.'
            '${note == null ? '' : (l?.beatsNotScreenedNote(note) ?? ' Last night was not screened: $note')}',
          ),
        ]),
      ),
    );
  }

  /// The two ends of the binned night, as wall-clock times when the bundle
  /// recorded where the first beat sat, and as elapsed time when it did not.
  /// A bin is half an hour wide, so the last bin ENDS 30 min after it starts.
  List<String> _nightHours(BuildContext c, BeatsData d) {
    if (d.bins.isEmpty) return const [];
    final endSec = d.bins.last.startSec + 1800;
    final origin = d.originMs;
    if (origin == null) {
      return [
        AppLocalizations.of(c)?.beatsStart ?? 'Start',
        metricValue('min', endSec / 60),
      ];
    }
    // Added in ms rather than with a `Duration`: `Duration(` is banned inside
    // lib/ui2 (it is how animation timings escape `Motion`), and this is a
    // wall-clock offset, not a timing.
    final a = DateTime.fromMillisecondsSinceEpoch(origin);
    final b = DateTime.fromMillisecondsSinceEpoch(origin + endSec * 1000);
    return [
      formatMinuteOfDay(a.hour * 60 + a.minute),
      formatMinuteOfDay(b.hour * 60 + b.minute),
    ];
  }

  Widget _note(P p, String s) => Align(
        alignment: Alignment.centerLeft,
        child: Text(s, style: F.cap.copyWith(color: p.ink3, height: 1.55)),
      );
}

// ═══════════════════ the two shapes that are layout, not painting ═══════════
//
// Neither of these is a painter. `charts.dart` gained exactly one new painter
// for this screen — the scatter, which genuinely had no equivalent — and these
// two are a stack of rectangles each, which is layout. Adding them to the
// painter library would be two more public painters nobody else can use.

/// The night's HRV band: one column per bin, drawn from `lo` to `hi` with the
/// value marked inside it. A bin that abstained is an OUTLINE — the slot is
/// there and it is empty, which is a different fact from a low reading and
/// survives any palette and any colour vision.
class _NightBand extends StatelessWidget {
  final List<NightBin> bins;
  final AxisSpec axis;
  final Color color, empty;
  const _NightBand(this.bins, this.axis,
      {required this.color, required this.empty});

  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (c, box) {
        if (bins.isEmpty || box.maxWidth <= 0) return const SizedBox.shrink();
        final h = box.maxHeight, w = box.maxWidth / bins.length;
        double y(double v) => h - axis.t(v) * h;
        // ONE flat stack, two positioned rects per drawn bin. It used to nest
        // a second `Stack` inside each bin so the tick could sit in the band's
        // own coordinates — and a childless `DecoratedBox` inside a `Stack` is
        // laid out LOOSE, so it collapsed to 0x0 and every band vanished. Only
        // the 2 pt tick survived, which turned the whole panel back into the
        // line of points it exists not to be.
        return Stack(children: [
          for (var i = 0; i < bins.length; i++)
            ...() {
              final b = bins[i];
              final left = i * w + w * .18, width = (w * .64).clamp(1.0, w);
              if (b.v == null) {
                return [
                  Positioned(
                    left: left,
                    width: width,
                    top: 0,
                    height: h,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: empty),
                        borderRadius: R.rSm,
                      ),
                    ),
                  ),
                ];
              }
              // A band thinner than 3 pt is not a band; grown DOWN from its own
              // top so it never hangs below the plot floor.
              final top = y(b.hi ?? b.v!).clamp(0.0, h - 3);
              final height = (y(b.lo ?? b.v!) - top).clamp(3.0, h - top);
              return [
                Positioned(
                  left: left,
                  width: width,
                  top: top,
                  height: height,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .35),
                      borderRadius: R.rSm,
                    ),
                  ),
                ),
                // The point estimate, inside its own band. Without it the bar
                // reads as a range the value moved through rather than as the
                // spread on one estimate.
                Positioned(
                  left: left,
                  width: width,
                  top: (y(b.v!) - 1).clamp(0.0, h - 2),
                  height: 2,
                  child: ColoredBox(color: color),
                ),
              ];
            }(),
        ]);
      });
}

/// One cell per day, three states that differ by FILL and by SHAPE, never by
/// hue alone: fired is a full-height block, the screen running and not firing
/// is a short block, and a day that was never screened is an outline.
class _RhythmStrip extends StatelessWidget {
  final List<double?> days;
  final Color clear, fired, absent;
  const _RhythmStrip(this.days,
      {required this.clear, required this.fired, required this.absent});

  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (c, box) {
        if (days.isEmpty || box.maxWidth <= 0) return const SizedBox.shrink();
        final h = box.maxHeight, w = box.maxWidth / days.length;
        return Stack(children: [
          for (var i = 0; i < days.length; i++)
            () {
              final v = days[i];
              final on = v != null && v >= 1;
              final height = v == null ? h : (on ? h : h * .45);
              return Positioned(
                left: i * w + 1,
                width: (w - 2).clamp(1.0, w),
                top: h - height,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: v == null ? null : (on ? fired : clear),
                    border: v == null ? Border.all(color: absent) : null,
                    borderRadius: R.rSm,
                  ),
                ),
              );
            }(),
        ]);
      });
}
