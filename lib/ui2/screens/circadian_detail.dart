// BODY CLOCK — the highest-value thing the pipeline already knew and nothing
// ever asked it for.
//
// Chronotype, social jetlag and the sleep-regularity index are computed every
// cross-day rollup and, until this screen, were read by nothing. The actogram
// is built here from the per-night sleep windows: one column per night, noon
// to noon, so a night reads as one continuous block instead of being cut in
// half at midnight.
//
// The non-parametric rhythm family (interdaily stability, intradaily
// variability, relative amplitude, L5/M10) and the 24 h cosinor ARE computed —
// `crossday_pipeline.dart:_crossDayCircadian` emits `circadian_rhythm`,
// `circadian_cosinor` and `circadian_coverage` on every rollup. Their substrate
// is not the textbook one: the 1 Hz accelerometry is pruned at
// `rawRetentionDays`, so the battery runs on the per-day HOURLY HEART-RATE
// profile that `day_result` keeps forever. That makes M10/L5 the highest- and
// lowest-HR windows rather than step counts, and the card says so out loud
// rather than letting the numbers imply accelerometry.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart';
import '../ui2.dart';
import 'home_screen.dart';
import 'metric_detail.dart';

/// How many nights the actogram draws. Each night costs one day-bundle decode,
/// so this is a real cost, not a display choice.
// ponytail: N bundle reads per open. If this ever feels slow, the fix is a
// `sleepWindows({days})` repo method that reads onset/offset without the
// payload, not a smaller number here.
const _nights = 42;

class CircadianData {
  /// Newest last. One entry per night: 24 hourly fractions from local noon, or
  /// null when that night has no window.
  final List<List<double>?> actogram;
  final List<String> labels;
  final Metric jetlag, regularity;

  /// Chronotype is a CLASS, not a number — a label, never a value.
  final String chronotypeLabel;
  final num? midFreeH, midWorkH, nFree, nWork;

  /// The non-parametric battery, carried as the envelope's IS so the whole
  /// family has one presence gate and one `need_baseline:` note to render.
  final Metric rhythm;
  final Map<String, dynamic> rhythmV, cosinorV, coverage;

  /// CV-09 — daytime RMSSD by hour of day, one slot per hour, `null` for an
  /// hour with too few quiet stretches behind it to be a reading. The WEEKLY
  /// median, never a value for today: a single day's hour is two or three
  /// five-minute windows.
  final List<double?> hourly;

  /// How the hourly row was built: derived days walked, how many quiet
  /// 5-minute stretches EACH hour is made of (24 slots, parallel to [hourly]),
  /// and the estimator's own note when it refused — an unknown strap family has
  /// no ENMO cut we can stand behind, so it gets none rather than gen4's.
  final int hourlyDays;
  final List<int> hourlyN;
  final String? hourlyNote;

  /// SLP-08 — the adjacent-night pairs the regularity index was averaged over,
  /// WORST FIRST. Each entry is `{prev_date, date, sri, cases}`.
  ///
  /// The analytics never sees a date; `crossday_pipeline` resolves each pair's
  /// day index into the two nights it compared, and drops any pair the validity
  /// mask left too thin — so a half-unobserved weekend cannot top this list for
  /// having no data. Empty until the rollup carries pairs at all.
  final List<Map<String, dynamic>> sriPairs;

  /// MIND-11 — the shape of today, forecast from last night. Absent whenever
  /// the night is missing or was never judged; the analytics gate does that and
  /// this screen only draws what it published.
  final ana.Metric<ana.AlertnessForecast> alertness;

  const CircadianData({
    this.actogram = const [],
    this.labels = const [],
    this.jetlag = Metric.empty,
    this.regularity = Metric.empty,
    this.chronotypeLabel = '',
    this.midFreeH,
    this.midWorkH,
    this.nFree,
    this.nWork,
    this.rhythm = Metric.empty,
    this.rhythmV = const {},
    this.cosinorV = const {},
    this.coverage = const {},
    this.hourly = const [],
    this.hourlyDays = 0,
    this.hourlyN = const [],
    this.hourlyNote,
    this.sriPairs = const [],
    this.alertness = const ana.Metric<ana.AlertnessForecast>.absent(
      tier: ana.Tier.estimate,
      inputs_used: [],
      note: 'no night loaded',
    ),
  });

  /// The middle value of [xs], which must be non-empty. A median, not a mean:
  /// one bin of a stairwell would drag an hour's average and nothing about the
  /// motion gate catches a slow climb.
  static double _median(List<double> xs) {
    final s = [...xs]..sort();
    return s[s.length ~/ 2];
  }

  static Future<CircadianData> load(LocalRepository repo) async {
    final cd = await repo.getInsights();
    final chrono = cd['chronotype'];
    final sjl = cd['social_jetlag'];
    final reg = cd['regularity'];
    final chronoV = envValue(chrono) ?? const {};
    final sjlV = envValue(sjl) ?? const {};
    final regV = envValue(reg) ?? const {};
    final np = cd['circadian_rhythm'];
    final cos = cd['circadian_cosinor'];
    final npV = envValue(np) ?? const {};

    // One column per CALENDAR night, not per derived day. `availableDays`
    // returns only the days that produced a result, so walking it directly
    // packed a 42-night actogram out of whatever 42 days happened to exist —
    // a fortnight of no records closed up, and every column left of it moved.
    // An actogram is a picture of when things happen; the x spacing IS the
    // measurement.
    final days = await repo.availableDays(); // newest first
    final have = days.toSet();
    final cols = <List<double>?>[];
    final labels = <String>[];
    // The newest night that actually has a window, picked up as the actogram
    // walks past it. MIND-11 needs exactly this and nothing else, so it costs no
    // read of its own — the loop below is already decoding every one of them.
    Map<String, dynamic>? latestNight;
    if (days.isNotEmpty) {
      final a = DateTime.parse(days.first);
      for (var back = _nights - 1; back >= 0; back--) {
        final day = dayLabelOf(DateTime(a.year, a.month, a.day - back));
        labels.add(day);
        if (!have.contains(day)) {
          cols.add(null);
          continue;
        }
        final n = await repo.getDaySleepV2(day);
        cols.add(_column(n['onset_ts'] as num?, n['wake_ts'] as num?));
        if (n['wake_ts'] is num) latestNight = n;
      }
    }

    // The rolling week, TODAY EXCLUDED — today's daytime bins are a handful of
    // five-minute windows and this row is only honest as a weekly median.
    final today = dayLabelOf(DateTime.now());
    // ponytail: 7 more bundle decodes on a screen that already does 42. If
    // this screen ever feels slow the fix is one repo method that reads
    // `daytime_hrv` without the payload, not a smaller week.
    final week = days.where((d) => d != today).take(7).toList();
    final byHour = List.generate(24, (_) => <double>[]);
    String? hourlyNote;
    for (final day in week) {
      final dh = (await repo.getDayHeart(day))['daytime_hrv'];
      if (dh is! Map) continue;
      hourlyNote ??= dh['note']?.toString();
      final tl = dh['timeline'];
      for (final e in (tl is List ? tl : const [])) {
        if (e is! Map) continue;
        final t = e['t'], v = e['rmssd'];
        if (t is! num || v is! num) continue;
        final h = DateTime.fromMillisecondsSinceEpoch(t.round() * 1000).hour;
        byHour[h].add(v.toDouble());
      }
    }
    // An hour built from one or two stretches is not an hour. It goes absent
    // rather than being drawn faintly or averaged with its neighbours.
    final hourly = [
      for (final xs in byHour) xs.length < 3 ? null : _median(xs),
    ];

    final cosV = envValue(cos) ?? const {};
    // MIND-11. Both inputs are REQUIRED by the analytics gate and neither has a
    // default here: a missing night abstains rather than assuming eight hours,
    // which is the gate the item says gets quietly removed later if it is not
    // pinned. Naps are not passed — the forecast is for today and today's naps
    // have not happened; the card says it only knows last night.
    final wake = (latestNight?['wake_ts'] as num?)?.round();
    final wakeAt = wake == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(wake * 1000);
    // Last night only. `latestNight` is just the newest night in the window,
    // which is weeks old when the band sat on the charger; a forecast for
    // today built from that wake time is a fabricated one.
    final wakeLocal =
        wakeAt != null && dayLabelOf(wakeAt) == today ? wakeAt : null;
    final tstMin = wakeLocal == null
        ? null
        : (latestNight?['duration_min'] as num?)?.toDouble();

    return CircadianData(
      actogram: cols,
      labels: labels,
      alertness: ana.alertnessForecast(
        wakeLocalHour:
            wakeLocal == null ? null : wakeLocal.hour + wakeLocal.minute / 60.0,
        sleepDurationHours: tstMin == null ? null : tstMin / 60.0,
        circadianAcrophaseHours: (cosV['acrophase_hours'] as num?)?.toDouble(),
      ),
      hourly: hourly,
      hourlyDays: week.length,
      hourlyN: [for (final xs in byHour) xs.length],
      hourlyNote: hourlyNote,
      chronotypeLabel: (chronoV['type_label'] ?? '').toString(),
      jetlag: envMetric(sjl, sjlV['abs_hours'] as num?),
      regularity: envMetric(reg, regV['sri'] as num?),
      // SLP-08. Worst first — the one row this can support is "these two
      // agreed least", so the list is sorted for that and nothing else reads
      // past the head of it.
      sriPairs: <Map<String, dynamic>>[
        for (final e in (regV['pairs'] as List? ?? const []))
          if (e is Map && e['sri'] is num && e['date'] != null &&
              e['prev_date'] != null)
            e.cast<String, dynamic>(),
      ]..sort((a, b) => (a['sri'] as num).compareTo(b['sri'] as num)),
      midFreeH: sjlV['mid_sleep_free_h'] as num?,
      midWorkH: sjlV['mid_sleep_work_h'] as num?,
      nFree: sjlV['n_free'] as num?,
      nWork: sjlV['n_work'] as num?,
      rhythm: envMetric(np, npV['IS'] as num?),
      rhythmV: npV,
      cosinorV: cosV,
      coverage: (cd['circadian_coverage'] as Map?)?.cast<String, dynamic>() ??
          const {},
    );
  }

  /// One night as 24 hourly asleep-fractions on a noon-anchored axis.
  static List<double>? _column(num? onsetTs, num? wakeTs) {
    if (onsetTs == null || wakeTs == null || wakeTs <= onsetTs) return null;
    final onset = DateTime.fromMillisecondsSinceEpoch(onsetTs.round() * 1000);
    // Anchor at the noon BEFORE sleep onset, so a 23:40 start and a 01:10 start
    // land in the same column rather than a day apart.
    final anchor = onset.hour < 12
        ? DateTime(onset.year, onset.month, onset.day - 1, 12)
        : DateTime(onset.year, onset.month, onset.day, 12);
    final a = anchor.millisecondsSinceEpoch / 1000;
    final lo = (onsetTs - a) / 3600, hi = (wakeTs - a) / 3600;
    if (hi <= 0 || lo >= 24) return null;
    return [
      for (var h = 0; h < 24; h++)
        ((hi < h + 1 ? hi : h + 1) - (lo > h ? lo : h)).clamp(0.0, 1.0).toDouble(),
    ];
  }
}

/// Hours past midnight → a wall clock, in the app's one clock format.
String _hourClock(num? h) => h == null ? '' : clock(((h % 24) * 60).round());

/// `'YYYY-MM-DD'` → `'9 Aug'`. Built off [prettyDay] rather than a second month
/// table: two dates spelled "Saturday, 9 August" do not fit one table row, and
/// this screen's own actogram axis already prints bare dates.
String _shortDay(Object? day) {
  final parts = prettyDay(day?.toString()).split(', ');
  if (parts.length < 2) return '';
  final dm = parts.last.split(' ');
  return dm.length < 2 ? parts.last : '${dm[0]} ${dm[1].substring(0, 3)}';
}

class CircadianDetail extends StatefulWidget {
  final CircadianData? data;
  const CircadianDetail({super.key, this.data});

  @override
  State<CircadianDetail> createState() => _CircadianDetailState();
}

class _CircadianDetailState extends State<CircadianDetail> {
  CircadianData? _d;
  bool _loading = true;

  /// Whether the non-parametric battery is unfolded. Off by default.
  bool _showStrength = false;

  /// SLP-08 — whether the two rows naming the least-alike pair of nights are
  /// unfolded. Off by default: the regularity index is one row today, and the
  /// decomposition of it is two more that nobody asked for until they did.
  bool _showNights = false;

  @override
  void initState() {
    super.initState();
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final d = await CircadianData.load(repo);
      if (mounted) setState(() => (_d = d, _loading = false));
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final d = _d ?? const CircadianData();
    final drawn = d.actogram.where((e) => e != null).length;

    return detailScaffold(c, l?.circadianDetailTitle ?? 'Body clock', [
      if (_loading && _d == null) ...[
        const SizedBox(height: S.x8),
        const Center(child: CircularProgressIndicator()),
      ] else ...[
        if (drawn == 0)
          StatusCard(
            l?.circadianDetailNoNightsTitle ?? 'No nights to plot yet',
            l?.circadianDetailNoNightsBody ?? '0 nights scored.',
            fix: l?.circadianDetailNoNightsFix ?? 'Wear the band overnight',
            icon: LucideIcons.calendarClock,
          )
        else
          Surface(
            child: ChartFrame(
              title: l?.circadianDetailSleepTitle ?? 'Sleep, night by night',
              // Hour of day is what the vertical axis IS. The old card replaced
              // the axis with a sentence describing it.
              unit: 'hour of day',
              height: 190,
              yAxis: AxisSpec(
                  min: 0,
                  max: 24,
                  ticks: 3,
                  // Rows run noon → noon, so 0 and 24 are both midday and 12 is
                  // midnight — read straight off the anchor the columns use.
                  format: (v) => clock(((12 + v) * 60).round())),
              xLabels: d.labels.isEmpty
                  ? const []
                  : [d.labels.first, d.labels.last],
              legend: [(l?.circadianDetailAsleep ?? 'Asleep', C.indigo)],
              footnote: l?.circadianDetailSleepFootnote(drawn) ??
                  '$drawn night${drawn == 1 ? '' : 's'}, one column each. '
                      'Darker is more of that hour asleep.',
              child: CustomPaint(
                size: Size.infinite,
                painter: Actogram(d.actogram, p.on(C.indigo)),
              ),
            ),
          ),

        // SLP-08 rides in this section's action, so the screen gains a tap
        // rather than two permanent rows.
        Section(
          l?.circadianDetailYourRhythm ?? 'Your rhythm',
          _rhythm(c, p, d),
          action: d.sriPairs.isEmpty || d.regularity.value == null
              ? null
              : (_showNights
                  ? (l?.circadianDetailHide ?? 'Hide')
                  : (l?.circadianDetailWhichNights ?? 'Which nights')),
          onAction: d.sriPairs.isEmpty || d.regularity.value == null
              ? null
              : () => setState(() => _showNights = !_showNights),
        ),

        // MIND-11 sits directly under the measured rhythm because it is built
        // on it — and directly above the battery it borrows the acrophase from.
        if (_forecast(c, p, d) case final f?)
          Section(l?.circadianDetailTodayPredicted ?? 'Today, predicted', f),

        // COLLAPSED BY DEFAULT, and that is how the screen paid for the card
        // above. Interdaily stability, intradaily variability, relative
        // amplitude and an adjusted R² are density-3 numbers that were sitting
        // at density 2 with eight rows and no tap between them and the reader.
        // Nothing is lost: the section, its title and its own empty state are
        // unchanged one tap away.
        Section(
          l?.circadianDetailRhythmStrength ?? 'Rhythm strength',
          _showStrength ? _strength(c, p, d) : const SizedBox.shrink(),
          action: _showStrength
              ? (l?.circadianDetailHide ?? 'Hide')
              : (l?.circadianDetailShow ?? 'Show'),
          onAction: () => setState(() => _showStrength = !_showStrength),
        ),

        // The social-jetlag InsightCard that used to sit here restated three
        // rows of the table above it as a sentence. Its one extra fact — the
        // DIRECTION, which is the sign of free minus work and not the unsigned
        // magnitude the card used to assert "later" from — is on the Social
        // jetlag row itself now, and the night counts are beside it. One card
        // off, so the hourly row below can go on.
        Section(l?.circadianDetailWhenStill ?? 'When you are still',
            _stillness(c, p, d)),
      ],
    ]);
  }

  String _hm(num hours) {
    final m = (hours * 60).round();
    return m < 60 ? '${m}m' : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  /// CV-09 — daytime HRV by hour of day, motion-gated.
  ///
  /// THE GATE IS THE FEATURE. The estimator pairs only beats whose own second
  /// was still — a real gravity vector, ENMO under that strap family's quiet
  /// cut — so a bin of walking cannot enter as low variability. An unknown
  /// strap family has no cut we can stand behind and the whole block refuses
  /// rather than borrowing gen4's.
  ///
  /// IT IS NOT STRESS, and the copy has to survive being read by someone who
  /// wants it to be: posture, digestion, temperature, talking, caffeine and a
  /// warm room move this as much as anything psychological. So: a weekly
  /// median and never today's, no colour, no band, no verdict, and an hour
  /// with too few quiet stretches behind it is absent rather than drawn faint.
  Widget _stillness(BuildContext c, P p, CircadianData d) {
    final l = AppLocalizations.of(c);
    final have = [for (final v in d.hourly) ?v];
    if (have.isEmpty) {
      return StatusCard(
        l?.circadianDetailNoStillTitle ?? 'No still moments to read yet',
        d.hourlyNote?.isNotEmpty == true
            ? d.hourlyNote!
            : (l?.circadianDetailNoStillBody(d.hourlyDays) ??
                'This needs seconds when you were still, and the last '
                    '${d.hourlyDays} day${d.hourlyDays == 1 ? '' : 's'} had '
                    'too few to fill an hour.'),
        icon: LucideIcons.activity,
      );
    }
    final axis = AxisSpec.of(have, ticks: 3, floor: 0, format: axisInt);
    final drawn = d.hourly.where((v) => v != null).length;
    // The per-hour depth, as a range. A bar chart has nowhere to print 24
    // counts and "how many quiet stretches is this hour?" is the question that
    // decides whether an hour means anything.
    final counts = [
      for (var h = 0; h < d.hourly.length && h < d.hourlyN.length; h++)
        if (d.hourly[h] != null) d.hourlyN[h],
    ]..sort();
    final lo = counts.isEmpty ? 0 : counts.first;
    final hi = counts.isEmpty ? 0 : counts.last;
    return Surface(
      child: ChartFrame(
        title: l?.circadianDetailStillnessTitle ??
            'Beat-to-beat variability while still',
        unit: 'ms',
        height: 120,
        yAxis: axis,
        // The row is 24 hours of the local clock, so both edges and the middle
        // are wall-clock times rather than positions in an array.
        xLabels: [clock(0), clock(12 * 60), clock(23 * 60)],
        series: d.hourly,
        footnote: l?.circadianDetailStillnessFootnote(lo, hi, d.hourlyDays, drawn) ??
            'Each hour is the middle of $lo–$hi still five-minute '
                'stretches over the last '
                '${d.hourlyDays} day${d.hourlyDays == 1 ? '' : 's'}. $drawn of '
                '24 hours had enough. Not a stress score.',
        child: CustomPaint(
          size: Size.infinite,
          // Uncoloured. A hue here would be a verdict about an hour of your
          // day, and there is no verdict available.
          painter: Bars(d.hourly, p.ink3, axis: axis, t: animate(c, 1)),
        ),
      ),
    );
  }

  /// MIND-11 — the shape of today, and the window it bottoms out in.
  ///
  /// NO NUMBER LEAVES THIS CARD. Not a score, not a percentage, not an axis
  /// tick: the chart is drawn without a y axis and the frame is handed no series
  /// to read aloud, because the only quantity here is a unitless curve
  /// normalised inside its own day and any figure taken off it would be the
  /// thing that gets screenshotted and quoted back. What the card publishes is a
  /// shape and a named two-hour window, which is the resolution a group model
  /// fitted to laboratory sleep restriction actually supports.
  ///
  /// The safety refusal is COPY ON THE CARD, not a note in a file. And the card
  /// is absent — not empty, not a placeholder — whenever the night was missing
  /// or unjudged: the analytics gate refuses rather than assuming eight hours,
  /// and this returns null rather than explaining an absence nobody asked about.
  Widget? _forecast(BuildContext c, P p, CircadianData d) {
    final l = AppLocalizations.of(c);
    final v = d.alertness.value;
    if (v == null) return null;
    final assumedPhase = d.cosinorV['acrophase_hours'] == null;
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ChartFrame(
          title: l?.circadianDetailForecastTitle ??
              'How today is likely to run',
          // There is no unit. Saying so is more honest than borrowing one, and
          // the frame renders it in the slot a unit would have occupied.
          unit: 'shape only',
          height: 96,
          xLabels: [
            _hourClock(v.startHour),
            _hourClock(v.startHour + 9),
            _hourClock(v.startHour + 18),
          ],
          // No `series:`. A shape has no reading; handing the frame one would
          // have it speak numbers off a curve that deliberately has none.
          footnote: l?.circadianDetailForecastFootnote ??
              'No scale — the shape is the whole output.',
          child: CustomPaint(
            size: Size.infinite,
            // p.ink3, like every other mark on this screen that is not a
            // verdict. A colour would make the trough a warning.
            painter: LineChart(v.shape, p.ink3,
                fill: false, t: animate(c, 1)),
          ),
        ),
        const SizedBox(height: S.x3),
        Text(
          l?.circadianDetailTroughText(
                v.troughLabel,
                _hourClock(v.troughStartHour),
                _hourClock(v.troughEndHour),
              ) ??
              'The flattest stretch lands in ${v.troughLabel}, around '
                  '${_hourClock(v.troughStartHour)}–${_hourClock(v.troughEndHour)}.',
          style: F.body.copyWith(color: p.ink, height: 1.5),
        ),
        const SizedBox(height: S.x3),
        Text(
          '${l?.circadianDetailPredictionDisclaimer ?? 'A prediction, not a reading. It only knows last night; a nap, coffee or anything else today won’t change it.'}'
          '${assumedPhase ? ' ${l?.circadianDetailAssumedPhaseNote ?? 'Your own clock peak is not worked out yet, so this uses an average one.'}' : ''}',
          style: F.cap.copyWith(color: p.ink2, height: 1.6),
        ),
        const SizedBox(height: S.x3),
        Text(
          l?.circadianDetailNotADrivingCheck ??
              'It is not a fitness-to-drive check and not a shift-safety '
                  'tool, and it does not say you are impaired.',
          style: F.cap.copyWith(color: p.ink2, height: 1.6),
        ),
      ]),
    );
  }

  Widget _rhythm(BuildContext c, P p, CircadianData d) {
    final l = AppLocalizations.of(c);
    final worst = d.sriPairs.isEmpty ? null : d.sriPairs.first;
    final showNights = _showNights && worst != null;
    final rows = <(String, String)>[
      if (d.chronotypeLabel.isNotEmpty)
        (l?.circadianDetailChronotype ?? 'Natural bedtime', d.chronotypeLabel),
      if (d.midFreeH != null)
        (l?.circadianDetailMidSleepFree ?? 'Mid-sleep, free days',
            _hourClock(d.midFreeH)),
      if (d.midWorkH != null)
        (l?.circadianDetailMidSleepWork ?? 'Mid-sleep, working days',
            _hourClock(d.midWorkH)),
      // `abs_hours` is UNSIGNED. Whether the free-day clock runs later or
      // earlier is the sign of free minus work; the card that used to say
      // "later" read it off the magnitude.
      if (d.jetlag.value != null)
        (
          l?.circadianDetailSocialJetlag ?? 'Weekend shift',
          '${_hm(d.jetlag.value!)}'
              '${d.midFreeH == null || d.midWorkH == null ? '' : (d.midFreeH! >= d.midWorkH! ? ' ${l?.circadianDetailLater ?? 'later'}' : ' ${l?.circadianDetailEarlier ?? 'earlier'}')}',
        ),
      if (d.nFree != null && d.nWork != null)
        (l?.circadianDetailNightsCompared ?? 'Free / working nights compared',
            '${d.nFree!.round()} / ${d.nWork!.round()}'),
      if (d.regularity.value != null)
        (l?.circadianDetailRegularityIndex ?? 'Regularity index',
            '${d.regularity.value!.round()} / 100'),
      // SLP-08 — the same arithmetic, one level down. The index above is the
      // average agreement across every adjacent pair of nights; these two rows
      // name the pair that agreed least and print it on the same scale.
      if (showNights)
        (l?.circadianDetailNightsLeastAlike ?? 'Nights least alike',
            '${_shortDay(worst['prev_date'])} → ${_shortDay(worst['date'])}'),
      if (showNights)
        (l?.circadianDetailSamePairScale ?? 'That pair, same scale',
            '${(worst['sri'] as num).round()} / 100'),
    ];

    if (rows.isEmpty) {
      // No `why:`. "Takes a few weeks of both" is one reason SRI abstains and
      // it is not the one the measured run hit — `no valid epoch pairs` was,
      // on both gen5 databases, and that note was being overwritten here.
      return StatusCard.forMetric(
              l?.circadianDetailRhythmNotEstablished ??
                  'Your rhythm is not established yet',
              d.regularity) ??
          const SizedBox.shrink();
    }

    if (!showNights) return _table(p, rows);
    // The caption is not decoration. SRI's evidence is a population-level
    // mortality association; it does not license telling one person that their
    // Saturday is harming them, and two dates in a table are exactly the shape
    // that gets read as a verdict unless the card says otherwise.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _table(p, rows),
      const SizedBox(height: S.x3),
      Text(
        l?.circadianDetailPairFootnote(d.sriPairs.length) ??
            'The least alike pair, out of ${d.sriPairs.length}. A late weekend is a different schedule, not a worse night. Days with too little recording are left out.',
        style: F.over.copyWith(color: p.ink3, height: 1.5),
      ),
    ]);
  }

  /// The non-parametric battery and the cosinor fit, with what they were
  /// computed FROM on the same card. Hourly heart-rate means are a legitimate
  /// input to this battery, but they are not accelerometry, and the numbers
  /// mean something different because of it — so the footnote is not optional
  /// decoration, it is the unit.
  Widget _strength(BuildContext c, P p, CircadianData d) {
    final l = AppLocalizations.of(c);
    final np = d.rhythmV, cos = d.cosinorV;
    num? n(Map<String, dynamic> m, String k) => m[k] as num?;

    final rows = <(String, String)>[
      if (n(np, 'IS') != null)
        (l?.circadianDetailStability ?? 'Day-to-day stability',
            n(np, 'IS')!.toStringAsFixed(2)),
      if (n(np, 'IV') != null)
        (l?.circadianDetailFragmentation ?? 'Hour-to-hour fragmentation',
            n(np, 'IV')!.toStringAsFixed(2)),
      if (n(np, 'RA') != null)
        (l?.circadianDetailAmplitude ?? 'Relative amplitude',
            n(np, 'RA')!.toStringAsFixed(2)),
      if (n(np, 'm10_start_epoch') != null)
        (l?.circadianDetailM10Start ?? 'Highest-HR 10 hours start',
            _hourClock(n(np, 'm10_start_epoch'))),
      if (n(np, 'l5_start_epoch') != null)
        (l?.circadianDetailL5Start ?? 'Lowest-HR 5 hours start',
            _hourClock(n(np, 'l5_start_epoch'))),
      if (n(cos, 'acrophase_hours') != null)
        (l?.circadianDetailRhythmPeak ?? 'Rhythm peak',
            _hourClock(n(cos, 'acrophase_hours'))),
      if (n(cos, 'amplitude') != null)
        (l?.circadianDetailPeakSwing ?? 'Peak-to-mean swing',
            '${n(cos, 'amplitude')!.toStringAsFixed(1)} bpm'),
      if (n(cos, 'r2_adj') != null)
        (l?.circadianDetailFitCurve ?? 'Fit to a 24 h curve',
            n(cos, 'r2_adj')!.toStringAsFixed(2)),
    ];

    if (rows.isEmpty) {
      return StatusCard.forMetric(
              l?.circadianDetailStrengthNotMeasured ??
                  'Rhythm strength is not measured yet',
              d.rhythm,
              unit: 'days',
              why: l?.circadianDetailStrengthWhy ??
                  'Needs consecutive days with all 24 hours recorded.') ??
          const SizedBox.shrink();
    }

    final used = (d.coverage['days_used'] as num?)?.round();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _table(p, rows),
      const SizedBox(height: S.x3),
      Text(
        used == null
            ? (l?.circadianDetailStrengthFootnoteUnknown ??
                'From a run of fully-recorded days of heart rate. These are '
                    'your highest and lowest heart-rate hours, not your '
                    'busiest.')
            : (l?.circadianDetailStrengthFootnoteKnown(used) ??
                'From $used fully recorded day${used == 1 ? '' : 's'}. Your '
                    'highest and lowest heart-rate hours, not your busiest.'),
        style: F.over.copyWith(color: p.ink3, height: 1.5),
      ),
    ]);
  }

  Widget _table(P p, List<(String, String)> rows) => Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: Row(children: [
                Expanded(
                    child:
                        Text(rows[i].$1, style: F.body.copyWith(color: p.ink))),
                const SizedBox(width: S.x3),
                // Flexible, like every other two-column row in the app: at 3.1x
                // text the label wraps inside its Expanded and the value's
                // natural width then runs 400 pt off the right edge. This
                // overflowed on the rows that were already here — "Regularity
                // index / 62 / 100" is enough on its own — so it is not the
                // SLP-08 rows that need it, it is the table.
                Flexible(
                  child: Text(rows[i].$2,
                      textAlign: TextAlign.right,
                      style: F.body
                          .copyWith(color: p.ink2, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ],
        ]),
      );
}
