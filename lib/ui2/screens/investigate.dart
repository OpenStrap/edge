import '../../l10n/date_text.dart';
// NERD STATS — density 3 of 3. (File and classes keep the old `Investigate`
// name on purpose: renaming them churns every import, the gallery keys and
// twelve golden files for zero user benefit. The user-facing string is the
// only thing that was ever "Investigate".)
//
// THE NUMBERS BEHIND THE PICTURE. The visual screens — Beats above all — are
// where the RR-derived family is now shown; this is the companion that prints
// what those pictures were drawn from: the figures, the beat counts, the
// coverage, the abstention notes, the algorithm version, in fixed pitch, with
// the method and its citation underneath. It is no longer where the good
// stuff hides. It is where you check the good stuff's arithmetic.
//
// Nothing here is styled to reassure: a number that is absent is absent, a
// number that is relative says so on its own row, and an estimator that
// abstained gets to state its own reason VERBATIM — a raw diagnostic string
// belongs on exactly this surface and nowhere else.
//
// There is no "advanced mode" toggle anywhere in this app and this screen is
// not gated by one. Density 3 here means "one tap from the picture", not
// "locked" — Beats, Vitals, Sleep, Readiness and every metric drill-down each
// carry a plain row down to it.

import '../../l10n/display_text.dart';
import 'dart:convert' show jsonDecode;
import 'dart:math' show sqrt;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'day_timeline.dart';
import 'home_screen.dart';
import 'metric_detail.dart';

class InvestigateData {
  final String? day;

  /// Every derived day, newest first — what [DayNav] steers over.
  final List<String> days;

  final int? algoVersion;

  /// Where this day came from — `null` when the bundle was derived on this
  /// device from band records, otherwise the importer that wrote it.
  final String? importedFrom;
  final Map<String, dynamic> hrv; // getDayHrv
  final Map<String, dynamic> heart; // getDayHeart

  /// `respiration.cvhr_apnea` — the whole envelope, because the note is the
  /// difference between a screen that abstained and a screen that ran and
  /// counted nothing.
  final Object? cvhr;

  /// RESP-01 — the 30-night personal distribution the per-night index above is
  /// only allowed to be read through. Null on every key but `resp_rate`.
  final ana.Metric<ana.CvhrDistribution>? cvhrDist;

  /// The night `getDaySleepV2` served, for the exact stage counts. SLP-13 shows
  /// ranges everywhere a normal user goes; the counts behind them live here and
  /// nowhere else. Empty on every key but `sleep`.
  final Map<String, dynamic> night;

  /// The day's `steps` envelope, for the per-sensor split. Empty on every key
  /// but `steps`, because it costs a bundle decode.
  final Map<String, dynamic> steps;

  /// RESP-05 — the day's all-day lines (`getDayTimeline`). Only `resp` is read
  /// from it, and only outside the sleep window. Empty on every key but
  /// `resp_rate`, because it is a second bundle decode.
  final Map<String, dynamic> timeline;

  /// The stored `prsa_dc` series, dated. Deceleration capacity is the one
  /// HRV-family number with hard outcome evidence behind it and its only
  /// reader was a single row in the table below.
  final List<ChartPoint> dcPoints;

  /// The stored `irregular_rhythm_flag` series (1/0 per DERIVED day). A day
  /// with no row and a day the screen abstained are the same absence here, and
  /// nothing downstream guesses which.
  final List<ChartPoint> rhythmPoints;
  final int? coveragePct;
  final int? windowStart, windowEnd;
  final List<double> series;

  const InvestigateData({
    this.day,
    this.days = const [],
    this.algoVersion,
    this.importedFrom,
    this.hrv = const {},
    this.heart = const {},
    this.cvhr,
    this.cvhrDist,
    this.night = const {},
    this.steps = const {},
    this.timeline = const {},
    this.dcPoints = const [],
    this.rhythmPoints = const [],
    this.coveragePct,
    this.windowStart,
    this.windowEnd,
    this.series = const [],
  });

  static Future<InvestigateData> load(LocalRepository repo, String key,
      {String? want}) async {
    final today = await repo.getToday();
    final days = await repo.availableDays();
    final day = pickDay(
        days, want, (today['status'] as Map?)?['today_day']?.toString());
    if (day == null) return InvestigateData(days: days);

    final spec = specOf(key);
    final hrv = await repo.getDayHrv(day);
    final heart = await repo.getDayHeart(day);
    final wear = await repo.getDayWear(day);
    final lungs = await repo.getDayLungs(day);
    final row = await LocalDb.dayResult(day);
    final win = lungs['sleep_window'];
    final series =
        spec.suppress != null ? const <double>[] : seriesOf(await repo.getChart(spec.chartKey));
    final hrvish = key == 'hrv';
    final dc = hrvish
        ? pointsOf(await repo.getChart('prsa_dc'))
        : const <ChartPoint>[];
    final rhythm = hrvish
        ? pointsOf(await repo.getChart('irregular_rhythm_flag'))
        : const <ChartPoint>[];

    // An imported day says so. `imported`/`source` are written by the importers
    // onto the bundle itself; a day derived here has neither.
    String? importedFrom;
    var steps = const <String, dynamic>{};
    final payload = row?['payload_json'];
    // The `contains` guard is what keeps every other key off the decode; the
    // steps split needs the bundle, so that key pays for it deliberately.
    if (payload is String &&
        (key == 'steps' || payload.contains('"imported"'))) {
      final b = jsonDecode(payload);
      if (b is Map) {
        if (b['imported'] == true) {
          importedFrom = b['source']?.toString() ?? 'an import';
        }
        if (b['steps'] is Map) {
          steps = (b['steps'] as Map).cast<String, dynamic>();
        }
      }
    }

    return InvestigateData(
      day: day,
      days: days,
      algoVersion: (row?['algo_version'] as num?)?.toInt(),
      importedFrom: importedFrom,
      hrv: hrv,
      heart: heart,
      cvhr: lungs['cvhr'],
      cvhrDist: key == 'resp_rate' ? await _cvhrHistory(repo, days) : null,
      night: key == 'sleep' ? await repo.getDaySleepV2(day) : const {},
      steps: steps,
      timeline: key == 'resp_rate' ? await repo.getDayTimeline(day) : const {},
      dcPoints: dc,
      rhythmPoints: rhythm,
      coveragePct: (wear['coverage_pct'] as num?)?.toInt(),
      windowStart: win is Map ? (win['start'] as num?)?.toInt() : null,
      windowEnd: win is Map ? (win['end'] as num?)?.toInt() : null,
      series: series,
    );
  }

  /// RESP-01 — assemble the stored nights and hand them to the analytics screen.
  ///
  /// One bundle decode per night. That is the cost of a screen whose whole point
  /// is that no single night may be shown, and it is paid once, on a density-3
  /// screen the user walked to.
  // ponytail: N bundle reads per open, same shape as the actogram's. If this
  // ever feels slow the fix is a repo method that reads `cvhr_per_hour` and
  // `analyzed_hours` without the payload, not a shorter window — the window is
  // the gate.
  static Future<ana.Metric<ana.CvhrDistribution>> _cvhrHistory(
      LocalRepository repo, List<String> daysNewestFirst) async {
    // RESP-02's cross-gate. The flag is stored one value per derived day,
    // stamped at local noon, so the day LABEL is what matches a night — never
    // the raw epoch, which is a different day either side of the stamp.
    final flags = <String, double>{
      for (final p in pointsOf(await repo.getChart('irregular_rhythm_flag')))
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(p.t * 1000)): p.v,
    };
    final nights = <ana.CvhrNight>[];
    for (final day in daysNewestFirst.take(ana.cvhrDistributionWindowNights)) {
      final v = envValue((await repo.getDayLungs(day))['cvhr']);
      final rate = v?['cvhr_per_hour'] as num?;
      final hours = v?['analyzed_hours'] as num?;
      // A night the screen abstained on is not a night with a zero. It is not
      // a night at all, and it never enters the denominator.
      if (rate == null || hours == null) continue;
      nights.add(ana.CvhrNight(
        dayKey: day,
        cvhrPerHour: rate.toDouble(),
        analyzedHours: hours.toDouble(),
        irregularRhythm: (flags[day] ?? 0) >= 1,
      ));
    }
    return ana.cvhrPersonalDistribution(nights);
  }
}

class Investigate extends StatefulWidget {
  final String metricKey;
  final InvestigateData? data;

  /// The day to open. Null means the newest derived one — which is what every
  /// caller did before a day could be asked for.
  final String? day;

  const Investigate(this.metricKey, {super.key, this.data, this.day});

  @override
  State<Investigate> createState() => _InvestigateState();
}

class _InvestigateState extends State<Investigate> {
  InvestigateData? _d;
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
      final d =
          await InvestigateData.load(repo, widget.metricKey, want: _day);
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
    final spec = specOf(widget.metricKey);
    final d = _d ?? const InvestigateData();
    final hrvish = widget.metricKey == 'hrv';

    return detailScaffold(
      c,
      uiText(context, spec.title),
      sub: l?.investigateNerdStatsLabel ?? 'NERD STATS',
      [
        ...dayNavRow(_day ?? d.day, d.days, _goDay),
        if (_loading) ...[
        const SizedBox(height: S.x8),
        const Center(child: CircularProgressIndicator()),
      ] else ...[
          if (hrvish) ..._hrvPanels(c, d) else ..._genericPanels(c, spec, d),
          if (widget.metricKey == 'resp_rate') ..._restingBreathPanels(d),
          if (widget.metricKey == 'resp_rate') ..._cvhrPanels(d),
          if (widget.metricKey == 'sleep') ..._stagePanels(d),
          if (widget.metricKey == 'steps') ..._stepSourcePanels(d),
          const SizedBox(height: S.x3),
          MonoTable(l?.investigateProvenanceLabel ?? 'Provenance', [
            (
              l?.investigateDayLabel ?? 'Day',
              d.day == null ? '—' : displayDay(d.day, l),
            ),
          (l?.investigateCoverageLabel ?? 'Coverage',
              d.coveragePct == null ? '—' : '${d.coveragePct} %'),
          if (d.windowStart != null)
            (l?.investigateSleepWindowLabel ?? 'Sleep window',
                '${clockOfTs(d.windowStart)} – ${clockOfTs(d.windowEnd)}'),
            // Asserted as "wrist optical · this device" for every day, including
            // days that were read out of somebody else's export.
          (l?.investigateSourceLabel ?? 'Source',
              d.importedFrom == null
                  ? (l?.investigateSourceOnDevice ??
                      'Band records · derived on this phone')
                  : (l?.investigateSourceImported(d.importedFrom!) ??
                      'Imported · ${d.importedFrom}')),
          (l?.investigateAlgoVersionLabel ?? 'Algorithm version',
              d.algoVersion == null ? '—' : 'v${d.algoVersion}'),
        ]),
        // The arithmetic is above; this is the other question a person has in
        // front of a number they do not like — what else was going on. Placed
        // here because the day is already resolved and already steerable, so
        // the door opens onto the SAME day rather than onto "the newest one".
        if (d.day != null) ...[
          const SizedBox(height: S.x3),
          detailLinkRow(
            c,
            LucideIcons.listOrdered,
            l?.investigateWhatHappenedTitle ?? 'What happened that day',
            l?.investigateWhatHappenedSub ??
                'Sleep, sessions, meals and logs in time order',
            () => go(c, DayTimelineScreen(day: d.day)),
          ),
        ],
          const SizedBox(height: S.x5),
          _method(c, spec),
        ],
      ],
    );
  }

  // ── STEPS: which sensor counted which part of the day ──
  //
  // The card upstairs names the dominant sensor in one word. This is the split
  // behind it, and it is the only place the strap's two counters are told
  // apart: the 100 Hz pedometer runs our own algorithm on raw wrist accel and
  // only exists while the strap is streaming, while the on-chip counter is
  // vendor hardware reporting a whole-day cumulative total with no window
  // behind it — which is why it is the last resort rather than the first.
  //
  // The chip's own reading is shown whether or not it was used. A gen5 day the
  // phone won still gets to say what the wrist thought, and a gen4 day drops
  // the row entirely because that hardware cannot count steps at all.
  List<Widget> _stepSourcePanels(InvestigateData d) {
    final l = AppLocalizations.of(context);
    final by = d.steps['by_source'];
    final split = by is Map ? by : const {};
    String n(Object? v) => v is num ? thousands(v) : '—';
    return [
      MonoTable(l?.investigateWhichSensorCounted ?? 'Which sensor counted', [
        (l?.investigateStrapPedometer ?? 'strap · 100 Hz pedometer',
            n(split['strap'])),
        (l?.investigateStrapOnChipCounter ?? 'strap · on-chip counter',
            n(split['strap_counter'])),
        if (d.steps['counter_calibration'] case {'factor': final num f})
          (l?.investigateStrapCounterFactor ?? 'on-chip counter · phone factor',
              '× ${f.toStringAsFixed(2)}'),
        (l?.investigatePhonePedometer ?? 'phone · pedometer', n(split['phone'])),
        (l?.investigateDayTotal ?? 'day total', n(d.steps['value'])),
        (l?.investigateStrapChipReported ?? 'strap chip reported',
            n(d.steps['band_measured'])),
      ]),
      const SizedBox(height: S.x3),
    ];
  }

  // ── HRV: time, frequency, non-linear ──
  List<Widget> _hrvPanels(BuildContext c, InvestigateData d) {
    final l = AppLocalizations.of(c);
    final time = envValue(d.hrv['hrv_time']) ?? const {};
    final freq = envValue(d.hrv['hrv_freq']) ?? const {};
    final freqNote = metricOf(d.hrv['hrv_freq']).note;
    // TWO DIFFERENT SHAPES, and this file read both as the same one. The
    // sleep-window screen is a PLAIN map (`sd1`, `sd2`, `flag`, `confidence`);
    // the 24-hour screen is an envelope whose `.value` carries the full set
    // (`sd1_ms`, `sd2_ms`, `sd1_sd2`, `pnn_pct`, `n_beats`). Reading the first
    // through `envValue` returned nothing, so every Poincaré row on this
    // screen has been silently empty.
    final irr = d.heart['irregular'] is Map
        ? (d.heart['irregular'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final irr24 = envValue(d.heart['irregular_24h']) ?? const {};
    final dc = envValue(d.hrv['prsa_dc']) ?? const {};
    final ac = envValue(d.hrv['prsa_ac']) ?? const {};
    final hrvBlock = d.heart['hrv'];
    final cv = hrvBlock is Map ? metricOf(hrvBlock['cv']).value : null;

    // A real minus sign, not a hyphen: acceleration capacity is negative by
    // definition and a hyphen in a numeric column reads as a dash.
    String fx(num v, int dp) => v.toStringAsFixed(dp).replaceFirst('-', '\u2212');
    String ms(Object? v) => v is num ? '${fx(v, 1)} ms' : '—';
    String ms2(Object? v) => v is num ? '${fx(v, 1)} ms\u00b2' : '—';
    String pct(Object? v) => v is num ? '${fx(v, 1)} %' : '—';
    String plain(Object? v) => v is num ? fx(v, 2) : '—';

    final beats = time['n_beats'] ?? irr['n_beats'] ?? irr24['n_beats'];

    return [
      MonoTable(l?.investigateTimeDomain ?? 'Time domain', [
        // Whole-night RMSSD, from the same `hrv_time` envelope as the rest of
        // this table. Absent (refused) drops the row; it never borrows the
        // nightly headline, which is a different statistic.
        (l?.investigateRmssd ?? 'RMSSD', ms(time['rmssd_ms'])),
        // The nightly headline, labelled by the estimator that produced it:
        // the session mean when its envelope holds a value. A bundle derived
        // before `rmssd` became that single estimator stores an earlier
        // fallback (NREM median or whole-night) beside an absent envelope, and
        // must not be passed off as the 5-min-window mean.
        (
          rmssdFromSessionEstimator(d.hrv['rmssd_sleep_session'])
              ? (l?.investigateRmssdNightly ??
                  'RMSSD, nightly (mean of 5-min windows)')
              : (l?.investigateRmssdStored ??
                  'RMSSD, nightly (earlier estimate)'),
          ms(d.hrv['rmssd'])
        ),
        (l?.investigateSdnn ?? 'SDNN', ms(time['sdnn_ms'] ?? d.hrv['sdnn'])),
        (l?.investigateSdann ?? 'SDANN', ms(time['sdann_ms'])),
        (l?.investigateSdnnIndex ?? 'SDNN index', ms(time['sdnn_index_ms'])),
        (l?.investigatePnn50 ?? 'pNN50', pct(time['pnn50_pct'])),
        (l?.investigateLnRmssd ?? 'ln RMSSD', plain(d.hrv['ln_rmssd'])),
        (l?.investigateBaselineRmssd ?? 'Your baseline RMSSD',
            ms(d.hrv['baseline'])),
        (l?.investigateStabilityCv ?? 'Stability (CV)', pct(cv)),
      ]),
      const SizedBox(height: S.x3),
      // ms² is correct AGAIN: `lombScargle` now returns physical PSD (ms²/Hz)
      // and the bands are Welch-averaged, verified against a synthetic at
      // total 652.1 vs SDNN² 651.0. It previously returned variance-normalised
      // power, so the same label sat over numbers three orders of magnitude
      // small. Every row here self-drops when its key is absent — ULF and a
      // too-short session now return null rather than a fabricated zero, and
      // MonoTable removes the row rather than dashing it.
      MonoTable(l?.investigateFrequencyDomain ?? 'Frequency domain', [
        (l?.investigateUlfPower ?? 'ULF power', ms2(freq['ulf'])),
        (l?.investigateVlfPower ?? 'VLF power', ms2(freq['vlf'])),
        (l?.investigateLfPower ?? 'LF power', ms2(freq['lf'])),
        (l?.investigateHfPower ?? 'HF power', ms2(freq['hf'])),
        (l?.investigateTotalPower ?? 'Total power', ms2(freq['total'])),
        (l?.investigateLfHf ?? 'LF / HF', plain(freq['lf_hf'])),
        (l?.investigateLfNormalised ?? 'LF, normalised', plain(freq['nu_lf'])),
        (l?.investigateHfNormalised ?? 'HF, normalised', plain(freq['nu_hf'])),
        // An ABSENT spectrum is not an ungated one. `envValue` returns null for
        // an absent envelope, so `== true ? : 'no'` collapsed "never computed"
        // into a confident negative — and it left a one-row table reading
        // "HF gated no" directly above the card saying there is no spectrum.
        (l?.investigateHfGated ?? 'HF gated', freq['hf_gated'] == null
            ? '—'
            : (freq['hf_gated'] == true
                ? (l?.investigateYes ?? 'yes')
                : (l?.investigateNo ?? 'no'))),
      ]),
      const SizedBox(height: S.x3),
      if (freq['total'] == null)
        StatusCard(
          l?.investigateNoFrequencySpectrum ??
              'No frequency-domain spectrum for this night',
          // THE ESTIMATOR'S OWN REASON. `total` goes null for three different
          // reasons and the envelope note distinguishes them; "too short" was
          // printed for all three, so a full 8 h night that failed the artifact
          // gate sent the user to look at their sleep duration instead of
          // their strap fit — contradicting the "HF gated yes" row above it.
          freqNote?.isNotEmpty == true
              ? freqNote!
              : (l?.investigateRecordingTooShort ??
                  'The recording was too short to resolve the bands.'),
        ),
      const SizedBox(height: S.x3),
      MonoTable(l?.investigateNonLinear ?? 'Non-linear', [
        (l?.investigateSd1Sleep ?? 'SD1, sleep', ms(irr['sd1'])),
        (l?.investigateSd2Sleep ?? 'SD2, sleep', ms(irr['sd2'])),
        (l?.investigateSd124h ?? 'SD1, 24 h', ms(irr24['sd1_ms'])),
        (l?.investigateSd224h ?? 'SD2, 24 h', ms(irr24['sd2_ms'])),
        (l?.investigateSd1Sd224h ?? 'SD1 / SD2, 24 h',
            plain(irr24['sd1_sd2'])),
        // The screen's own threshold, stated rather than baked into a label
        // the stored key cannot confirm.
        (l?.investigateSuccessiveIntervalsOver70ms ??
            'Successive intervals over 70 ms', pct(irr24['pnn_pct'])),
        // A screen that never RAN is not a screen that ran and found nothing.
        // `irregularBeatScreen` abstains below 500 clean beats or over 30%
        // artifact — the common case for a barely-worn day — and both rows
        // printed "clear" for it, i.e. a negative arrhythmia screen for a day
        // the screen was explicitly suppressed. MonoTable drops the em-dash.
        (l?.investigateIrregularRhythmFlagSleep ??
            'Irregular-rhythm flag, sleep',
            irr['flag'] == null
                ? '—'
                : (irr['flag'] == true
                    ? (l?.investigateFlagRaised ?? 'raised')
                    : (l?.investigateFlagClear ?? 'clear'))),
        (l?.investigateIrregularRhythmFlag24h ?? 'Irregular-rhythm flag, 24 h',
            irr24['flag'] == null
                ? '—'
                : (irr24['flag'] == true
                    ? (l?.investigateFlagRaised ?? 'raised')
                    : (l?.investigateFlagClear ?? 'clear'))),
        (l?.investigateDecelerationCapacity ?? 'Deceleration capacity',
            ms(dc['capacity_ms'])),
        (l?.investigateAccelerationCapacity ?? 'Acceleration capacity',
            ms(ac['capacity_ms'])),
        (l?.investigateDcAnchors ?? 'DC anchors',
            dc['anchors'] == null ? '—' : thousands(dc['anchors'] as num)),
      ]),
      if (d.dcPoints.isNotEmpty) ...[
        const SizedBox(height: S.x3),
        _dcTrend(c, d, beats),
      ],
      if (d.rhythmPoints.isNotEmpty) ...[
        const SizedBox(height: S.x3),
        _rhythmStrip(c, d),
      ],
      const SizedBox(height: S.x3),
      // Beats analysed is the only MEASURED row this table ever had; the other
      // three were constants sitting under a heading that made them look
      // measured. They are in the method note at the bottom of the screen.
      MonoTable(l?.investigateSignalQuality ?? 'Signal quality', [
        (l?.investigateBeatsAnalysed ?? 'Beats analysed',
            beats == null ? '—' : thousands(beats as num)),
        (l?.investigateBeatsAnalysed24h ?? 'Beats analysed, 24 h',
            irr24['n_beats'] == null
                ? '—'
                : thousands(irr24['n_beats'] as num)),
      ]),
      ..._shapePanels(c, d),
    ];
  }

  /// CV-06 — the shape of the night. Per-bin RMSSD across the sleep window.
  ///
  /// A BAND, NOT A LINE, and that is structural rather than styling. RMSSD off
  /// a few hundred successive differences has real sampling spread, so the
  /// analytics ships every bin as lo/point/hi and the chart draws the corridor:
  /// three polylines on ONE shared axis — the two edges in `p.ink3` and the
  /// estimate between them. A single line through the points would claim a
  /// precision the beats do not carry, which is the whole reason the estimator
  /// bothered to publish an interval.
  ///
  /// A bin under the beat floor is a HOLE in the series, not a dropped point:
  /// `LineChart` breaks on a null, so a charging gap reads as a gap instead of
  /// a flat stretch of low variability.
  ///
  /// IT DESCRIBES, IT NEVER ATTRIBUTES. A suppressed first third is equally
  /// consistent with alcohol, a late meal, late training, a warm room, illness
  /// onset, or nothing at all, and nothing in this pipeline can tell those
  /// apart — so the footnote names all of them and the screen names none.
  ///
  /// Deliberately NOT here: "time to the first bin within 10% of the night's
  /// max". It anchors on the noisiest statistic in the series and jumps by
  /// hours between adjacent nights on identical physiology. The analytics
  /// refuses to compute it; this refuses to ask.
  List<Widget> _shapePanels(BuildContext c, InvestigateData d) {
    final l = AppLocalizations.of(c);
    final raw = d.hrv['night_shape'];
    // No key at all: a bundle derived before the pipeline emitted this. Silence
    // is right — there is nothing to explain about a night nobody measured it
    // for.
    if (raw is! Map) return const [];
    final p = P.of(c);
    final v = envValue(raw);
    if (v == null) {
      // The estimator's own reason, VERBATIM — too few beats and a night too
      // short for three bins are different nights and it distinguishes them.
      // This used to be run through a prettifier that stripped the machine
      // prefix and reworded the counts; on a nerd-stats screen that is lost
      // information, not politeness. The raw string is the point.
      final note = metricOf(raw).note;
      return [
        const SizedBox(height: S.x3),
        StatusCard(
          l?.investigateNoShapeForNight ?? 'No shape for this night',
          note?.isNotEmpty == true
              ? note!
              : (l?.investigateTooFewBeatsToBin ??
                  'The night carried too few clean beats to bin.'),
          icon: LucideIcons.activity,
        ),
      ];
    }

    final bins = [
      for (final e in (v['bins'] as List? ?? const []))
        if (e is Map) e,
    ];
    if (bins.length < 3) return const [];
    List<double?> col(String k) =>
        [for (final b in bins) (b[k] as num?)?.toDouble()];
    final mid = col('rmssd_ms'), lo = col('lo_ms'), hi = col('hi_ms');
    final drawn = mid.where((e) => e != null).length;
    // Two bins is not a shape. The analytics already abstains per bin; this is
    // the whole-night version of the same floor.
    if (drawn < 3) return const [];
    // ONE axis for all three polylines, spanning the band and not just the
    // estimate — an edge drawn off an axis fitted to the middle is clipped.
    final axis = AxisSpec.of([...lo, ...hi].whereType<double>(),
        ticks: 3, floor: 0, format: axisInt);
    if (axis == null) return const [];

    // Bin width, MEASURED off the bins rather than assumed to be 30 min: the
    // analytics takes it as a parameter and the IDEAS entry says to widen it if
    // real nights look wobbly.
    final t0 = (bins.first['t'] as num?)?.toDouble();
    final t1 = (bins[1]['t'] as num?)?.toDouble();
    final widthMin = (t0 == null || t1 == null) ? null : (t1 - t0) / 60;
    // `t` is seconds from the FIRST BEAT; `origin_ms` is the wall clock that
    // second zero sits at. Without it there is no clock to label, so the axis
    // goes unlabelled rather than counting hours from an unstated start.
    final origin = (raw['origin_ms'] as num?)?.toDouble();
    String at(int i) {
      final s = (bins[i]['t'] as num?)?.toDouble();
      return (origin == null || s == null) ? '' : clockOfTs(origin / 1000 + s);
    }

    String ms(Object? x) => x is num ? '${x.toStringAsFixed(1)} ms' : '—';
    final ratio = v['last_over_first'];

    return [
      const SizedBox(height: S.x3),
      Surface(
        child: ChartFrame(
          title: l?.investigateShapeOfTheNight ?? 'Shape of the night',
          unit: 'ms',
          height: 130,
          yAxis: axis,
          xLabels: origin == null ? const [] : [at(0), at(bins.length - 1)],
          legend: [
            (l?.investigateBinRmssd ?? 'Bin RMSSD', p.on(C.green)),
            (l?.investigateSamplingRange ?? 'Sampling range', p.ink3),
          ],
          series: mid,
          footnote: l?.investigateShapeFootnote(drawn, bins.length) ??
              '$drawn of ${bins.length} bins carried enough beats to '
              'read; the rest are gaps, not zeroes. The outer pair is the '
              "estimator's own sampling spread, not a range you were in. This "
              'describes the night and cannot explain it — a low first third '
              'is equally consistent with alcohol, a late meal, late training, '
              'a warm room, an illness starting, or nothing at all.',
          child: Stack(children: [
            Positioned.fill(
              child: CustomPaint(
                painter: LineChart(lo, p.ink3, fill: false, axis: axis),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: LineChart(hi, p.ink3, fill: false, axis: axis),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: LineChart(mid, p.on(C.green),
                    fill: false, t: animate(c, 1), axis: axis),
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: S.x3),
      MonoTable(l?.investigateNightShape ?? 'Night shape', [
        (l?.investigateBinWidth ?? 'Bin width',
            widthMin == null ? '—' : '${widthMin.round()} min'),
        (l?.investigateBinsRead ?? 'Bins read', '$drawn of ${bins.length}'),
        (l?.investigateFirstThird ?? 'First third', ms(v['first_third_ms'])),
        (l?.investigateLastThird ?? 'Last third', ms(v['last_third_ms'])),
        // A ratio, printed as a ratio. No adjective, no direction word, no
        // colour: "1.32" is the fact and "recovered well" is not one.
        (l?.investigateLastThirdOverFirst ?? 'Last third ÷ first',
            ratio is num ? ratio.toStringAsFixed(2) : '—'),
      ]),
    ];
  }

  /// CV-03 — deceleration capacity as a trend. UNCOLOURED, and that is the
  /// whole design: DC has real outcome evidence behind it (Bauer 2006) and the
  /// strata are ECG post-MI, while our beats are pulse arrivals. PRSA anchors
  /// on decelerations, and pulse-arrival jitter attenuates DC by an amount that
  /// varies with signal quality night to night — so a rising line can be a
  /// cleaner-signal line. No colour, no threshold, no reference range, ever.
  /// The beat count goes on the card because the artifact gate is load-bearing.
  Widget _dcTrend(BuildContext c, InvestigateData d, Object? beats) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final win = denseDays(d.dcPoints, 30);
    final vals = [for (final v in win) ?v];
    final axis = AxisSpec.of(vals, ticks: 3, format: axisFixed);
    return Surface(
      child: ChartFrame(
        title: l?.investigateDecelerationCapacity ?? 'Deceleration capacity',
        unit: 'ms',
        height: 110,
        yAxis: axis,
        xLabels: [
          l?.investigate29DaysAgo ?? '29 days ago',
          l?.investigateToday ?? 'Today',
        ],
        series: win,
        footnote: beats is num
            ? (l?.investigateDcFootnoteWithBeats(thousands(beats)) ??
                'Your own nights only — no reference range, and none exists '
                    'for pulse arrivals. Night-to-night signal quality moves '
                    'this line on its own, and last night was '
                    '${thousands(beats)} beats.')
            : (l?.investigateDcFootnote ??
                'Your own nights only — no reference range, and none exists '
                    'for pulse arrivals. Night-to-night signal quality moves '
                    'this line on its own.'),
        child: CustomPaint(
          size: Size.infinite,
          // p.ink3, not an accent. A colour here would be a verdict.
          painter: LineChart(win, p.ink3,
              fill: false, dots: true, dotInk: p.card, t: animate(c, 1),
              axis: axis),
        ),
      ),
    );
  }

  /// CV-10 — the irregular-rhythm SCREEN, night by night.
  ///
  /// Three states and they must look like three states: a filled square is a
  /// day the screen ran, darker when it raised its flag, and an OUTLINE is a
  /// day it did not run at all. `metric_series` stores one value per day, so a
  /// day with no record and a day the screen abstained on are the same absence
  /// — the copy says "did not run" and does not guess which.
  ///
  /// Screening, not detection. Wrist optical cannot separate an ectopic beat
  /// from a dropped beat from a motion artifact, so there is no percentage of
  /// abnormal beats here and no AF, PVC or ectopy vocabulary anywhere near it.
  /// The footnote is permanent, not a tooltip: a clear strip means nothing.
  Widget _rhythmStrip(BuildContext c, InvestigateData d) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    const weeks = 12;
    final grid = _weekGrid(d.rhythmPoints, weeks);
    final ran = d.rhythmPoints.length;
    final raised = d.rhythmPoints.where((e) => e.v >= 1).length;
    return Surface(
      child: ChartFrame(
        title: l?.investigateIrregularRhythmScreen ?? 'Irregular-rhythm screen',
        unit: l?.investigateOneSquarePerDay ?? 'one square per day',
        height: 96,
        xLabels: [
          l?.investigate12WeeksAgo ?? '12 weeks ago',
          l?.investigateThisWeek ?? 'This week',
        ],
        legend: [(l?.investigateScreenRan ?? 'Screen ran', p.on(C.purple))],
        footnote: l?.investigateRhythmStripFootnote(ran, raised) ??
            'Ran on $ran day${ran == 1 ? '' : 's'}, raised its flag on '
            '$raised. An outlined square is a day it did not run. A clear '
            'strip is not a negative result: this is a screen on pulse '
            'timing, and it cannot tell an ectopic beat from a dropped beat '
            'from the band moving on your wrist.',
        child: CustomPaint(
          size: Size.infinite,
          painter: HeatMap(grid, p.on(C.purple), p.line),
        ),
      ),
    );
  }

  /// [pts] as calendar weeks — one column per week, Monday at the top, the last
  /// column being the week that contains today. `null` is a day with no stored
  /// value, which [HeatMap] draws as an outline rather than a fainter fill.
  static List<List<double?>> _weekGrid(List<ChartPoint> pts, int weeks) {
    final tail = 7 - DateTime.now().weekday; // days left in the current week
    final all = [
      ...denseDays(pts, weeks * 7 - tail),
      ...List<double?>.filled(tail, null),
    ];
    return [for (var w = 0; w < weeks; w++) all.sublist(w * 7, w * 7 + 7)];
  }

  // ── RESP-05 · the resting floor of the day ─────────────────────────────────
  //
  // THE EMPTY STATE IS THE COMMON CASE and it is written first, because it is
  // what most days produce. `resp_day` is swept as 3-minute windows at a
  // 5-minute cadence, and the pipeline rejects any window that was not almost
  // entirely still — RSA amplitude collapses under motion and the tachogram's
  // Nyquist falls with heart rate, so a moving window physically cannot resolve
  // a breathing rate, it just returns a confident wrong one. A day that
  // produces nothing here is a day you moved, not a day with a problem.
  //
  // ONLY THE FLOOR. Never "your breathing rate today", never a value during
  // activity, never an average over the day — the surviving windows are not a
  // sample of the day, they are the stillest slices of it, and the only honest
  // reduction of a set like that is its bottom.
  //
  // The sleep window is subtracted, and a day with NO sleep window abstains
  // entirely rather than counting the night's own windows as daytime rest. The
  // nocturnal breathing rate has its own row on Vitals and its own trend; this
  // one exists to answer the same question without waiting for a night.
  List<Widget> _restingBreathPanels(InvestigateData d) {
    final l = AppLocalizations.of(context);
    final line = d.timeline['resp'];
    if (line is! List || line.isEmpty) return const [];
    final t0 = d.windowStart, t1 = d.windowEnd;
    final empty = <Widget>[
      const SizedBox(height: S.x3),
      StatusCard(
        l?.investigateNoRestingBreathingRate ??
            'No resting breathing rate away from sleep',
        l?.investigateNoRestingBreathingRateBody ??
            'This reads breathing only from three-minute stretches where the '
                'band saw you almost completely still, outside the sleep '
                'window. Most days have none — a day with none is a day you '
                'were moving, not a day anything went wrong.',
        icon: LucideIcons.wind,
      ),
    ];
    // No sleep window means nothing can be excluded, and the night's own
    // windows are exactly the ones that would survive a stillness gate.
    if (t0 == null || t1 == null || t1 <= t0) return empty;

    final awake = <double>[
      for (final e in line)
        if (e is Map && e['t'] is num && e['v'] is num)
          if ((e['t'] as num) < t0 || (e['t'] as num) > t1)
            (e['v'] as num).toDouble(),
    ]..sort();
    // Three windows is the floor for calling anything a floor. Below it the
    // minimum is one estimate wearing a superlative.
    if (awake.length < 3) return empty;

    return [
      const SizedBox(height: S.x3),
      MonoTable(l?.investigateBreathingAtRestAwake ?? 'Breathing at rest, awake', [
        (l?.investigateStillStretchesOutsideSleep ??
            'Still stretches outside sleep', '${awake.length}'),
        (l?.investigateLowest ?? 'Lowest',
            '${awake.first.toStringAsFixed(1)} br/min'),
        // The next one up, so the lowest is readable as one of several rather
        // than as a lone reading. Not a median of the day — these windows are
        // the stillest slices of it, not a sample of it.
        (l?.investigateNextLowest ?? 'Next lowest',
            '${awake[1].toStringAsFixed(1)} br/min'),
        (l?.investigateHighestOfThem ?? 'Highest of them',
            '${awake.last.toStringAsFixed(1)} br/min'),
      ]),
      const SizedBox(height: S.x3),
      Surface(
        color: P.of(context).card2,
        elevation: 0,
        child: Text(
          l?.investigateFloorNotRateBody ??
              'A floor, not a rate for the day. Only stretches where you were '
              'almost completely still can be read at all, so these are the '
              'stillest few minutes the band saw outside your sleep — nothing '
              'here describes the rest of your day, and breathing while you '
              'move cannot be recovered from beat timing.',
          style: F.cap.copyWith(color: P.of(context).ink2, height: 1.6),
        ),
      ),
    ];
  }

  // ── breathing-disturbance texture ──
  //
  // The screen already counted the cycles; it accumulated each one's depth and
  // width and threw everything but the two means away. The quartiles are the
  // shape those means hide: a night of a few deep dips and a night of many
  // shallow ones share a mean.
  //
  // Numbers, no adjectives, no interpretation, no category — and Nerd stats
  // only. Nothing here is a sleep-apnea finding and no copy anywhere near it
  // names a breathing disorder or a mechanism.
  List<Widget> _cvhrPanels(InvestigateData d) {
    final l = AppLocalizations.of(context);
    final v = envValue(d.cvhr);
    final note = metricOf(d.cvhr).note;
    if (v == null) {
      // ABSTAINED, not "nothing found". The screen hard-gates on beat count and
      // artifact fraction, and zero cycles over six observed hours is a
      // different night from a screen that never ran.
      return [
        const SizedBox(height: S.x3),
        StatusCard(
          l?.investigateCycleScreenDidNotRun ??
              'The cycle screen did not run for this night',
          note?.isNotEmpty == true
              ? note!
              : (l?.investigateNotEnoughCleanBeats ??
                  'Not enough clean beats to run it.'),
          icon: LucideIcons.wind,
        ),
        // The across-nights view survives a night that abstained — that is the
        // whole reason it is an aggregate. Dropping it here would have made the
        // screen go quiet on exactly the nights it is least about.
        ..._cvhrDistribution(d),
      ];
    }

    String q(Object? qs, String unit, int dp) {
      if (qs is! List || qs.length < 3) return '—';
      final xs = [for (final e in qs) if (e is num) e];
      if (xs.length < 3) return '—';
      return '${xs.map((e) => e.toStringAsFixed(dp)).join(' · ')} $unit';
    }

    final hours = v['analyzed_hours'] as num?;
    return [
      const SizedBox(height: S.x3),
      MonoTable(l?.investigateHeartRateCycles ?? 'Heart-rate cycles', [
        (l?.investigateCyclesCounted ?? 'Cycles counted',
            v['cycle_count'] == null ? '—' : thousands(v['cycle_count'] as num)),
        (l?.investigateObservedHoursAnalysed ?? 'Observed hours analysed',
            hours == null ? '—' : '${hours.toStringAsFixed(2)} h'),
        (l?.investigateCyclesPerObservedHour ?? 'Cycles per observed hour',
            v['cvhr_per_hour'] == null
                ? '—'
                : (v['cvhr_per_hour'] as num).toStringAsFixed(2)),
        (l?.investigateMeanCycleLength ?? 'Mean cycle length',
            v['mean_width_sec'] == null
                ? '—'
                : '${(v['mean_width_sec'] as num).toStringAsFixed(1)} s'),
        (l?.investigateMeanDipDepth ?? 'Mean dip depth',
            v['mean_depth_ms'] == null
                ? '—'
                : '${(v['mean_depth_ms'] as num).toStringAsFixed(1)} ms'),
        // p25 · p50 · p75 of the SAME per-cycle lists the means come from.
        (l?.investigateCycleLengthQuartiles ?? 'Cycle length, quartiles',
            q(v['width_quartiles_sec'], 's', 1)),
        (l?.investigateDipDepthQuartiles ?? 'Dip depth, quartiles',
            q(v['depth_quartiles_ms'], 'ms', 1)),
      ]),
      ..._cvhrDistribution(d),
    ];
  }

  // ── RESP-01 · the 30-night screen ───────────────────────────────────────────
  //
  // THE COPY IS THE PRODUCT and it was written before this widget existed. It
  // has to survive an adversarial reader trying to get a diagnosis out of it, so
  // four things are structural rather than editorial:
  //
  //   * NO CONDITION IS NAMED. Not in the headline, not in the body, not as a
  //     hedge ("this is not X" still teaches the reader that X is the subject).
  //     The card names the pattern it counted and what a clinician does.
  //   * NO NUMBER. No index, no rate, no severity, no per-night value, no count
  //     of anything that could be read as events. `nights_used` is provenance —
  //     how much of the user's own record is behind the sentence — and it is the
  //     only figure allowed.
  //   * IT MAY NOT REASSURE. The refusal to clear anything is a paragraph in the
  //     body, present in BOTH states, and never a footnote or a tooltip. An
  //     absent flag is not a negative result: this screen is blunted by
  //     beta-blockers, autonomic neuropathy and diabetes and misses real cases.
  //   * IT TERMINATES IN A CLINICIAN, never in a number and never in an action
  //     the app can take.
  //
  // It sits BELOW the per-night table on purpose. The table is one night's raw
  // counts, which is what the whole aggregate exists to stop anyone reading as a
  // finding — so the card that says "across nights, never on one" has to come
  // after the night it is talking about, not before it.
  //
  // And it lives on Nerd stats, density 3, reached by walking here. On the
  // Sleep screen the same words become a headline, and a headline is how a
  // screen that fires on atrial fibrillation, on altitude and on any broken-up
  // night turns into a diagnosis in somebody's head.
  List<Widget> _cvhrDistribution(InvestigateData d) {
    final l = AppLocalizations.of(context);
    final m = d.cvhrDist;
    if (m == null) return const [];
    final p = P.of(context);
    final v = m.value;

    if (v == null) {
      return [
        const SizedBox(height: S.x3),
        StatusCard(
          l?.investigateNotEnoughNightsAcross ??
              'Not enough nights for the across-nights view',
          // The screen's OWN reason, VERBATIM, including which gate dropped
          // which night. `need_baseline:` and `nights=A/B` are the pipeline's
          // machine spellings and they stay: this is the surface where the
          // exact string the estimator emitted is more useful than a smoothed
          // paraphrase of it, and the owner asked for it that way.
          m.note?.isNotEmpty == true
              ? m.note!
              : (l?.investigateNeedsSeveralNights ??
                  'This needs several nights with a few observed hours each.'),
          icon: LucideIcons.wind,
        ),
      ];
    }

    final n = v.nightsUsed;
    final dropped = [
      if (v.nightsExcludedIrregular > 0)
        l?.investigateDroppedIrregular(v.nightsExcludedIrregular) ??
            '${v.nightsExcludedIrregular} left out because the '
                'irregular-rhythm screen flagged them',
      if (v.nightsExcludedThin > 0)
        l?.investigateDroppedThin(v.nightsExcludedThin) ??
            '${v.nightsExcludedThin} left out for too few observed hours',
    ];

    return [
      const SizedBox(height: S.x3),
      Surface(
        color: p.card2,
        elevation: 0,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l?.investigateAcrossNOwnNights(n) ?? 'ACROSS $n OF YOUR OWN NIGHTS',
              style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: S.x3),
          Text(
            v.aboveOwnUsual
                ? (l?.investigateCvhrAboveUsual(n) ??
                    'Over your most recent nights, the heart-rate cycling '
                        'this screen counts has been running higher than '
                        'across the $n nights behind it.')
                : (l?.investigateCvhrInsideUsual(n) ??
                    'Over your most recent nights, the heart-rate cycling '
                        'this screen counts has stayed inside the range of '
                        'the $n nights behind it.'),
            style: F.body.copyWith(color: p.ink, height: 1.5),
          ),
          const SizedBox(height: S.x3),
          Text(
            l?.investigateCvhrExplainer ??
                'It is a pattern in your pulse, not a measurement of your '
                'breathing, and it is not a test for anything. The same '
                'cycling comes from an irregular rhythm, from being at '
                'altitude, and from any broken-up night — and beta-blockers, '
                'diabetes and nerve conditions flatten it, so genuinely '
                'disturbed breathing often leaves nothing here at all.',
            style: F.cap.copyWith(color: p.ink2, height: 1.6),
          ),
          const SizedBox(height: S.x3),
          Text(
            l?.investigateCvhrNotNegativeResult ??
                'So nothing here is a negative result and nothing here '
                'clears anything, and none of it says anything about any one '
                'night — a single night’s count moves for a dozen reasons on '
                'its own.',
            style: F.cap.copyWith(color: p.ink2, height: 1.6),
          ),
          const SizedBox(height: S.x3),
          Text(
            l?.investigateCvhrSeeClinicianIfSymptoms ??
                'If you snore, wake unrefreshed, or someone has seen you '
                'stop breathing in your sleep, a clinician can test that '
                'properly.',
            style: F.cap.copyWith(color: p.ink2, height: 1.6),
          ),
          if (dropped.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            Text('${dropped.join('; ')}.',
                style: F.over.copyWith(color: p.ink3, height: 1.5)),
          ],
        ]),
      ),
    ];
  }

  // ── SLP-13 · the counts the ranges are made of ──────────────────────────────
  //
  // Every user-facing surface shows stage minutes as intervals now. The exact
  // figures the segmenter counted still exist and belong somewhere; this is the
  // somewhere the item names. Both are on the row, so the width is legible as a
  // property of the night rather than as a house style.
  List<Widget> _stagePanels(InvestigateData d) {
    final l = AppLocalizations.of(context);
    final n = d.night;
    int? min(String k) => (n[k] as num?)?.round();
    final light = min('light_min'), dp = min('deep_min'), r = min('rem_min');
    final tst = min('duration_min');
    // A night with no REM figure (a band that folds REM into light) still
    // has its light/deep split; only the REM row is left out.
    if (light == null || dp == null || tst == null) return const [];
    final conf = (n['stages_confidence'] as num?)?.toDouble();
    final iv = ana.stageIntervals(
      lightSec: light * 60,
      deepSec: dp * 60,
      remSec: (r ?? 0) * 60,
      tstSec: tst * 60,
      confidence: conf ?? 0.0,
    );
    String row(int exact, ana.StageInterval i) =>
        '$exact min · shown as ${(i.loSec / 60).round()}–'
        '${(i.hiSec / 60).round()} min';
    return [
      const SizedBox(height: S.x3),
      MonoTable(l?.investigateStageMinutesAsCounted ?? 'Stage minutes, as counted', [
        (l?.investigateLight ?? 'Light', row(light, iv.light)),
        (l?.investigateDeep ?? 'Deep', row(dp, iv.deep)),
        if (r != null) (l?.investigateRem ?? 'REM', row(r, iv.rem)),
        (l?.investigateAwake ?? 'Awake',
            min('awake_min') == null ? '—' : '${min('awake_min')} min'),
        (l?.investigateTotalSleep ?? 'Total sleep', '$tst min'),
        // The width of every interval above is a function of this one number
        // and nothing else, so it goes on the same table.
        (l?.investigateSegmentationConfidence ?? 'Segmentation confidence',
            conf == null
                ? (l?.investigateNotPublished ?? 'not published')
                : conf.toStringAsFixed(2)),
      ]),
    ];
  }

  // ── anything else: what the series itself looks like ──
  List<Widget> _genericPanels(
      BuildContext c, MetricSpec spec, InvestigateData d) {
    final l = AppLocalizations.of(c);
    if (spec.suppress != null) {
      return [
        StatusCard(
            l?.investigateNothingComputedForKey ?? 'Nothing computed for this key',
          uiText(c, spec.suppress!),
          icon: spec.icon,
        ),
      ];
    }
    final s = d.series;
    if (s.isEmpty) {
      return [
        StatusCard(
          l?.investigateNoStoredSeries ?? 'No stored series',
          l?.investigateNothingStoredYet(
                uiText(context, spec.title).toLowerCase(),
              ) ??
              'Nothing stored for ${uiText(context, spec.title).toLowerCase()} yet.',
          icon: spec.icon,
        ),
      ];
    }
    final sorted = [...s]..sort();
    final mean = s.reduce((a, b) => a + b) / s.length;
    final sd = s.length < 2
        ? 0.0
        : sqrt(s.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
            (s.length - 1));
    String n(double v) => v.abs() >= 100
        ? v.round().toString()
        : v.toStringAsFixed(2);

    return [
      MonoTable(l?.investigateSeries ?? 'Series', [
        // DERIVED days, not calendar days. `metric_series` gets a row only on a
        // day that derives, so "Days stored 40" under "one value per calendar
        // day" read as 40 days of continuous coverage.
        (l?.investigateDaysDerived ?? 'Days derived', '${s.length}'),
        (l?.investigateLatest ?? 'Latest', n(s.last)),
        (l?.investigateMean ?? 'Mean', n(mean)),
        (l?.investigateMedian ?? 'Median', n(sorted[sorted.length ~/ 2])),
        (l?.investigateSd ?? 'SD', n(sd)),
        (l?.investigateMin ?? 'Min', n(sorted.first)),
        (l?.investigateMax ?? 'Max', n(sorted.last)),
        (
          l?.investigateUnit ?? 'Unit',
          spec.unit.isEmpty
              ? (l?.investigateUnitless ?? 'unitless')
              : uiText(c, spec.unit),
        ),
        (l?.investigateStorage ?? 'Storage',
            l?.investigateOneValuePerDerivedDay ?? 'one value per derived day'),
      ]),
    ];
  }

  Widget _method(BuildContext c, MetricSpec spec) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    return Surface(
      elevation: 0,
      color: p.card2,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l?.investigateMethodLabel ?? 'METHOD', style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x2),
        Text(
            spec.method.isEmpty
                ? (l?.investigateNotDocumented ?? 'Not documented.')
                : uiText(c, spec.method),
            style: F.cap.copyWith(color: p.ink2, height: 1.6),
          ),
          if (spec.citation.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            Text(
              uiText(c, spec.citation),
              style: F.over.copyWith(color: p.ink3, fontFamily: 'Menlo'),
            ),
          ],
        ],
      ),
    );
  }
}
