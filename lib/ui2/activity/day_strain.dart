// DAY STRAIN — when the day's effort actually happened.
//
// `getDayStrain` was fully implemented and called by nothing. Everything drawn
// here was already computed and persisted: `series.strain_curve` (one point per
// WAKE MINUTE), the zone minutes, and `max_hr_used` — the ceiling the pipeline
// actually integrated against, printed rather than laundered into the score.
//
// The CURVE leads. The 0–21 is a summary of the curve, not the other way round:
// two days can land on the same number with completely different shapes, and
// the shape is the thing you can act on.
//
// What this screen deliberately does NOT draw:
//   * CTL/ATL/TSB. That is a fortnight of history and it already has a card one
//     tap away on the Workout tab. A day screen repeating it is noise.
//   * the resting heart rate TRIMP was anchored on. `getDayHeart`'s
//     `resting_hr` is now that same nocturnal number (`scalars.rhr` no longer
//     falls back to daytime HR), so it COULD be printed — it just does not earn
//     a line on a day screen whose subject is the curve. Naming the input in a
//     sentence is enough.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/date_text.dart';
import '../../models/metric.dart' show whyFromNote;
import '../screens/home_screen.dart' show repoOf;
import '../screens/metric_detail.dart' show detailScaffold;
import '../ui2.dart';
import 'catalogue.dart' show zonesWhy;
import 'zones.dart' show ZonesDetail;

/// Below this the day is not comparable to a full one and the screen says so.
/// Wear coverage is a percentage of the whole day, so a normal night off the
/// wrist already costs ~30 points — this is "most of the waking day", not
/// "nearly all of it".
const _lowCoveragePct = 60;

/// The trace, the score, and everything needed to say what the score is made
/// of. Every field is nullable: a day the band never saw renders its absence.
class DayStrainData {
  /// The local day the curve actually came from. `getDayStrain` falls back to
  /// the last settled bundle while today is still deriving, so this is read off
  /// the curve's own timestamps rather than off the label we asked for.
  final DateTime? day;

  /// One slot per minute of [day], null where nothing was recorded. A compacted
  /// curve under a 00:00–24:00 axis draws a sync gap as though it were measured.
  final List<double?> curve;

  final double? strain;

  /// Five zone minutes, or null when the day banked no split.
  final List<int>? zoneMin;

  /// The HR ceiling the pipeline integrated against — `max_hr_used`, the same
  /// number the maths saw.
  final num? maxHrUsed;

  /// TS-04 — which anchors THIS day's zone bars were binned on: 'karvonen'
  /// (observed ceiling + measured resting HR), 'observed' (measured ceiling
  /// only) or 'tanaka' (the age estimate). The bar's footnote states what the
  /// bar IS, rather than what it usually is.
  final String? zoneSource;
  final num? zoneMaxHr;

  final int? peakHr, wornMin, coveragePct;

  /// WHY the day has no strain, as the bundle said it — never a sentence
  /// written on this screen. Null means nothing came back with the absence, and
  /// the screen then says exactly that.
  final String? note;

  const DayStrainData({
    this.day,
    this.curve = const [],
    this.strain,
    this.zoneMin,
    this.maxHrUsed,
    this.zoneSource,
    this.zoneMaxHr,
    this.peakHr,
    this.wornMin,
    this.coveragePct,
    this.note,
  });

  bool get hasCurve => curve.any((v) => v != null);

  static Future<DayStrainData> load(LocalRepository repo) async {
    final asked = todayLabel();
    final s = await repo.getDayStrain(asked);
    if (s.isEmpty) return const DayStrainData();

    final pts = <(int, double)>[
      for (final e in (s['curve'] as List? ?? const []))
        if (e is Map && e['t'] is num && e['v'] is num)
          ((e['t'] as num).toInt(), (e['v'] as num).toDouble()),
    ];

    DateTime? day;
    var grid = const <double?>[];
    if (pts.isNotEmpty) {
      final first =
          DateTime.fromMillisecondsSinceEpoch(pts.first.$1 * 1000);
      day = DateTime(first.year, first.month, first.day);
      final dayStart = day.millisecondsSinceEpoch ~/ 1000;
      final out = List<double?>.filled(1440, null);
      for (final p in pts) {
        final i = (p.$1 - dayStart) ~/ 60;
        if (i >= 0 && i < 1440) out[i] = p.$2;
      }
      grid = out;
    }

    // Wear for THE DAY THE CURVE CAME FROM, not the day we asked for — both
    // reads fall back the same way, so asking for the resolved label is what
    // keeps the coverage figure and the trace describing one day.
    //
    // Read even when there is NO curve, which it did not used to be. Whether
    // the band saw the day is what decides if "wear the band through the day"
    // is an instruction or an insult, and a day with no strain is exactly the
    // day that question gets asked on.
    Map<String, dynamic> wear = const {};
    try {
      wear = await repo.getDayWear(day == null ? asked : dayLabelOf(day));
    } catch (_) {
      wear = const {};
    }

    final z = s['zones'];
    final zoneMin = z is Map &&
            [for (var i = 1; i <= 5; i++) z['z$i']].every((v) => v is num)
        ? [for (var i = 1; i <= 5; i++) (z['z$i'] as num).toInt()]
        : null;

    final hr = s['hr'];
    return DayStrainData(
      day: day,
      curve: grid,
      strain: (s['strain'] as num?)?.toDouble(),
      zoneMin: zoneMin,
      maxHrUsed: s['max_hr_used'] as num?,
      zoneSource: s['zone_source'] as String?,
      zoneMaxHr: s['zone_max_hr'] as num?,
      peakHr: hr is Map ? (hr['max'] as num?)?.toInt() : null,
      wornMin: (wear['worn_min'] as num?)?.toInt(),
      coveragePct: (wear['coverage_pct'] as num?)?.toInt(),
      // The headline absence's reason, at the top level of the payload — the
      // same string as `absent.strain`.
      note: s['note'] as String?,
    );
  }
}


class DayStrainDetail extends StatefulWidget {
  /// Preloaded, for goldens. Null means read the repo on open.
  final DayStrainData? data;
  const DayStrainDetail({super.key, this.data});

  @override
  State<DayStrainDetail> createState() => _DayStrainDetailState();
}

class _DayStrainDetailState extends State<DayStrainDetail> {
  DayStrainData? _d;
  bool _loading = true;

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
      final d = await DayStrainData.load(repo);
      if (mounted) setState(() => (_d = d, _loading = false));
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final d = _d ?? const DayStrainData();
    final day = d.day;
    // The date the drawn day IS. `getDayStrain` serves the last settled bundle
    // while today is still deriving, and a screen headed "Today" over
    // yesterday's trace is the whole reason this is read off the curve.
    final sub = day == null
        ? ''
        : dayLabelOf(day) == todayLabel()
        ? (l?.dayStrainToday ?? 'TODAY')
        : localizedDate(day, l?.localeName ?? 'en', pattern: 'd MMMM');

    return detailScaffold(
      c,
      l?.dayStrainTitle ?? 'Day strain',
      [
        if (_loading && _d == null) ...[
          const SizedBox(height: S.x8),
          const Center(child: CircularProgressIndicator()),
        ] else ...[
          ..._trace(p, l, d),
          ..._zones(p, l, d),
          Section(l?.dayStrainInputsSection ?? 'What this is made of',
              _inputs(p, l, d)),
        ],
      ],
      sub: sub,
    );
  }

  // ── the curve, and only then the number ────────────────────────────────────
  List<Widget> _trace(P p, AppLocalizations? l, DayStrainData d) {
    if (!d.hasCurve) {
      // THE BUNDLE'S REASON, or none. This card used to state one — "it needs a
      // resting heart rate from a scored night and a day the band was on your
      // wrist" — and it printed that on a day with a scored night (RHR 56.8)
      // and 89 % wear, because the sentence was written here rather than
      // handed over. A cause the screen did not receive is a guess.
      final why = whyFromNote(d.note, unit: 'days');
      // And "wear the band" is only an instruction on a day the band did not
      // see. Offered on a day it was on the wrist all along it is worse than
      // no button, because the user spends trust doing it.
      final saw = (d.wornMin ?? 0) > 0 || (d.coveragePct ?? 0) > 0;
      // A day CAN carry a strain with no trace behind it: `backfillStrainScale`
      // rescales the stored headline onto the current scale and DROPS the
      // per-minute curve, which cannot be rescaled with it. Measured on
      // whoop-4, that is 6 of 17 days — and on every one of them this card said
      // "this day produced no strain" directly above a day that produced 10.8.
      // The absence is the TRACE, so that is what the card is allowed to name;
      // why the trace is not stored is not something this screen was told.
      final s = d.strain;
      return [
        StatusCard(
          s == null
              ? (l?.dayStrainNoTraceTitle ?? 'No strain trace for this day')
              : (l?.dayStrainNoMinuteTraceTitle ??
                  'No minute-by-minute trace for this day'),
          s == null
              ? why ??
                  (l?.dayStrainNoReasonBody ??
                      'Nothing recorded says why this day produced no strain.')
              : (l?.dayStrainScoredNoTraceBody(s.toStringAsFixed(1)) ??
                  'The day strain is ${s.toStringAsFixed(1)}. The waking minutes '
                      'it was built from are not stored for this day.'),
          fix: (s == null && !saw)
              ? (l?.dayStrainWearBandFix ?? 'Wear the band through the day')
              : '',
          icon: LucideIcons.trendingUp,
        ),
      ];
    }
    final axis = AxisSpec.of(d.curve.whereType<double>(), floor: 0)!;
    final drawn = d.curve.where((v) => v != null).length;
    return [
      Surface(
        child: Column(children: [
          ChartFrame(
            title: l?.dayStrainChartTitle ?? 'STRAIN THROUGH THE DAY',
            unit: '0–21',
            height: 170,
            yAxis: axis,
            xLabels: const ['00:00', '12:00', '24:00'],
            series: d.curve,
            footnote: l?.dayStrainChartFootnote(drawn) ??
                'Effort banked above your usual waking pace — it can ease '
                    'later in the day if intensity drops back toward that '
                    'pace, even though the STEEP parts already happened. '
                    'Built from $drawn recorded waking minutes.',
            child: CustomPaint(
              size: Size.infinite,
              painter: LineChart(d.curve, p.on(C.purple),
                  axis: axis, t: animate(context, 1)),
            ),
          ),
          if (d.strain != null || d.peakHr != null || d.wornMin != null) ...[
            const SizedBox(height: S.x4),
            InlineMetrics([
              if (d.strain != null)
                (l?.dayStrainTitle ?? 'Day strain', d.strain!.toStringAsFixed(1),
                    C.purple),
              if (d.peakHr != null)
                (l?.dayStrainPeakHr ?? 'Peak HR', '${d.peakHr} bpm', C.red),
              if (d.wornMin != null)
                (l?.dayStrainWorn ?? 'Worn', '${d.wornMin} min', C.teal),
            ]),
          ],
        ]),
      ),
      if (d.coveragePct != null && d.coveragePct! < _lowCoveragePct)
        Padding(
          padding: const EdgeInsets.only(top: S.x4),
          child: StatusCard(
            l?.dayStrainLowCoverageTitle(d.coveragePct!) ??
                'The band saw ${d.coveragePct}% of this day',
            l?.dayStrainLowCoverageBody ??
                'Strain is a total over the minutes that were recorded, so a '
                    'partly-worn day reads lower than a full one and the two are '
                    'not comparable.',
            icon: LucideIcons.watch,
          ),
        ),
    ];
  }

  // ── where the effort sat ───────────────────────────────────────────────────
  List<Widget> _zones(P p, AppLocalizations? l, DayStrainData d) {
    final z = d.zoneMin;
    if (z == null) return const [];
    final total = z.fold<int>(0, (a, b) => a + b);
    if (total <= 0) return const [];
    return [
      Section(
        l?.dayStrainTimeInZonesSection ?? 'Time in zones',
        Surface(
          child: ChartFrame(
            title: l?.dayStrainZonesChartTitle ?? 'TIME IN ZONES',
            unit: 'minutes',
            height: 10,
            legend: [
              for (var i = 0; i < 5; i++)
                ('Z${i + 1} · ${z[i]}m', ZoneBar.cols(p)[i]),
            ],
            // TS-03/TS-04 — the edges, and where THIS day's came from. Stated
            // per day, not as a standing hedge: the same screen tomorrow can be
            // banded on a measured ceiling, and a footnote that still said
            // "estimated from your age" would then be false. The 28-day
            // distribution is NOT here — it lives one tap away and is gated on
            // the same anchors (TS-05).
            footnote: zonesWhy(d.zoneSource, d.zoneMaxHr, l),
            child: CustomPaint(
              size: Size.infinite,
              painter: ZoneBar([for (final v in z) v / total], p),
            ),
          ),
        ),
        // Progressive disclosure: this day screen gains a LINK, not a row. The
        // ceiling, the edges in bpm and the 28-day distribution are all one tap
        // behind it.
        action: l?.dayStrainHowSet ?? 'How these are set',
        onAction: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ZonesDetail())),
      ),
    ];
  }

  // ── the inputs, named ──────────────────────────────────────────────────────
  Widget _inputs(P p, AppLocalizations? l, DayStrainData d) {
    final max = d.maxHrUsed;
    return Surface(
      elevation: 0,
      color: p.card2,
      child: Text(
        [
          l?.dayStrainInputsBase ??
              'Banister TRIMP over your waking heart rate, scaled to 0–21.',
          if (max != null)
            l?.dayStrainInputsMaxHr(max.round()) ??
                'It was integrated against an assumed maximum of '
                    '${max.round()} bpm — estimated from your age and your strap, '
                    'not measured.',
          // Said out loud because the zone bar above can now be banded on a
          // MEASURED ceiling while this number is still the age estimate, and
          // two different ceilings on one screen with nothing saying so is
          // exactly the defect TS-03a removed.
          if (max != null && d.zoneSource != null && d.zoneSource != 'tanaka')
            l?.dayStrainInputsMeasuredCeilingNote ??
                'The zone bar above uses the measured ceiling instead; strain has '
                    'not been moved onto it, because that would rewrite every '
                    'strain score you have ever seen.',
          l?.dayStrainInputsRhrAnchor ??
              'The other anchor is your resting heart rate from the night before, '
                  'so a night the band missed moves the whole day.',
        ].join(' '),
        style: F.cap.copyWith(color: p.ink3, height: 1.5),
      ),
    );
  }
}
