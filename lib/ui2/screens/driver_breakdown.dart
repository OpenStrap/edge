// What charged and drained you — readiness taken apart, in plain words.
//
// This screen printed two words and stopped: "hrv", "rhr". Two separate things
// were wrong and only one of them was the rendering.
//
//   · IT READ THE WRONG ARRAY. `readiness_glassbox.drivers` is the list already
//     FILTERED to the inputs that cleared the smallest-worthwhile-change gate,
//     so an input that sat inside your usual spread was not "hidden", it was
//     never in the array. The screen therefore could not say "and your
//     breathing rate did nothing", which is half of what "what changed" means.
//     This reads `breakdown` instead — all four inputs, each carrying its own
//     `used` flag, weight, signed contribution and spread gate. It is the same
//     array `ReadinessDetail` renders, so the two screens describe one
//     computation in one vocabulary rather than two.
//
//   · NOTHING SAID WHAT THE NUMBER WAS. Not the reading, not the user's own
//     usual, not the direction, not the size of the move, not whether the move
//     was bigger than the noise. Every one of those was already being computed
//     and written on every derive, in the `baselines` block — value, baseline
//     centre, spread, delta, MDC — and no widget in the app had ever read it.
//
// So nothing here computes. It joins three stored things — the glass-box
// breakdown, the baselines block, and each input's own stored series — and
// says them out loud. The arithmetic of a score, never an account of a person:
// a driver is a term in a formula we control, and the footer says so.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../models/metric.dart' show whyFromNote;
import '../ui2.dart';
import 'home_screen.dart'
    show denseDays, driverLabel, metricValue, pointsOf, unitBeside;
import 'metric_detail.dart' show MetricSpec, specOf;

/// How many days of a driver's own history the expanded chart draws.
const int kDriverChartDays = 30;

/// The three stores spell the same four inputs three different ways: the
/// glass-box breakdown labels them `hrv/rhr/resp/temp`, the `baselines` block
/// keys them `hrv/resting_hr/resp/skin_temp`, and the `MetricSpec` registry
/// (title, unit, colour, chart alias) keys them `hrv/resting_hr/resp_rate/
/// skin_temp`. One map, so nothing downstream has to know that.
const _sources = <String, ({String baseline, String spec})>{
  'hrv': (baseline: 'hrv', spec: 'hrv'),
  'rhr': (baseline: 'resting_hr', spec: 'resting_hr'),
  'resp': (baseline: 'resp', spec: 'resp_rate'),
  'temp': (baseline: 'skin_temp', spec: 'skin_temp'),
};

/// The chart aliases [driverFacts] wants a series for, in breakdown-key order.
/// The caller fetches them — a widget does not touch the repository.
List<String> get driverChartKeys =>
    [for (final e in _sources.entries) specOf(e.value.spec).chartKey];

/// ONE readiness input, with everything that is known about it in one place.
///
/// Assembled, never derived. Each field names the store it came from, because
/// the moment one of these starts being computed here it stops agreeing with
/// the screen that shows the same number somewhere else.
class DriverFacts {
  /// `hrv` · `rhr` · `resp` · `temp` — the pipeline's own key.
  final String key;
  final MetricSpec spec;

  // ── from `readiness_glassbox.breakdown` ──
  /// Was the input present AND ranked against enough of your own history.
  final bool used;

  /// Signed, in score points: `weight × (percentile − 50)`. The same number
  /// `ReadinessDetail` prints, from the same field, so the two cannot disagree.
  final double? contribution;

  /// 0…1 of the weight that was ACTUALLY carried — renormalised over the
  /// inputs that were usable, not the catalogue weight.
  final double? weightShare;

  /// Did the raw change clear the smallest worthwhile change on your own
  /// history. Wire name `past_mdc`; it is the SWC gate.
  final bool beyondUsualSpread;

  /// Machine-readable reason the input was not used, e.g.
  /// `need_baseline:have=2,need=7`. Null when it WAS used.
  final String? note;

  // ── from the day bundle's `baselines` block ──
  /// Last night's reading in the metric's own unit.
  final double? value;

  /// Your own baseline centre — "usual".
  final double? usual;

  /// Half-width of the usual band: 1.253 × the mean-absolute spread, which is
  /// exactly the `|z| ≤ 1` the baselines block already reports as
  /// `in_normal_range`. Taken from the same numbers rather than re-derived, so
  /// the band drawn behind the chart is the band the pipeline means.
  final double? halfBand;

  /// `value − usual`, signed.
  final double? delta;

  /// `delta / MDC`, signed. Null when no honest noise estimate exists, and a
  /// null here is never rounded up into a claim.
  final double? mdcMultiples;

  // ── from `metric_series`, via `getChart` ──
  /// DENSE — one slot per calendar day, `null` where nothing was measured.
  final List<double?> series;

  const DriverFacts({
    required this.key,
    required this.spec,
    required this.used,
    required this.contribution,
    required this.weightShare,
    required this.beyondUsualSpread,
    required this.note,
    required this.value,
    required this.usual,
    required this.halfBand,
    required this.delta,
    required this.mdcMultiples,
    required this.series,
  });

  /// The plain name. `driverLabel`, not `spec.title` — this row says "Breathing
  /// rate", and its own chart must not be headed "Respiratory rate".
  String get label => driverLabel(key);

  /// Skin temperature is a raw uncalibrated ADC deviation. Its spec suppresses
  /// the chart for that reason, and the same flag suppresses the NUMBERS: a row
  /// reading "32411, 31 above your usual 32380" is arithmetic nobody can use,
  /// and printing it would dress a sensor count as a measurement.
  bool get numeric => spec.suppress == null;

  /// Is there a history worth opening.
  bool get chartable => numeric && series.any((v) => v != null);

  /// The usual band, low and high, or null when there is no spread to draw.
  (double, double)? get band => usual == null || halfBand == null || halfBand! <= 0
      ? null
      : (usual! - halfBand!, usual! + halfBand!);
}

/// Join the three stores into one list, in the breakdown's own order.
///
/// [breakdown] is `readiness_glassbox.value.breakdown`, [baselines] the day
/// bundle's `baselines` block, [charts] a chart alias → `getChart` result map.
/// Every one of them may be absent; an absent one costs its own fields and
/// nothing else, which is why each field is separately nullable.
List<DriverFacts> driverFacts({
  required List<Map<String, dynamic>> breakdown,
  Map<String, dynamic>? baselines,
  Map<String, Object?> charts = const {},
}) {
  // The weight ACTUALLY carried, over the usable inputs only — the same sum
  // `ReadinessDetail` takes. With skin temperature missing, HRV's catalogue
  // 40 % really carried 45.5 %, and printing the catalogue figure would be a
  // disclosed weight that was not the weight used.
  final wsum = breakdown
      .where((r) => r['used'] == true)
      .fold<double>(0, (a, r) => a + ((r['weight'] as num?)?.toDouble() ?? 0));

  final out = <DriverFacts>[];
  for (final r in breakdown) {
    final key = r['label']?.toString() ?? '';
    final src = _sources[key];
    // An input the pipeline grew that this map has not heard of still gets a
    // row: label, weight and contribution are all in the breakdown itself. It
    // simply has no baseline block and no chart.
    final spec = specOf(src?.spec ?? key);
    final b = baselines?[src?.baseline ?? key];
    final base = b is Map ? b : const {};
    final weight = (r['weight'] as num?)?.toDouble();
    final used = r['used'] == true;
    final spread = (base['spread'] as num?)?.toDouble();
    out.add(DriverFacts(
      key: key,
      spec: spec,
      used: used,
      contribution: (r['weighted_contribution'] as num?)?.toDouble(),
      weightShare:
          !used || weight == null || wsum <= 0 ? null : weight / wsum,
      beyondUsualSpread: r['past_mdc'] == true,
      note: r['note']?.toString(),
      value: (base['value'] as num?)?.toDouble(),
      usual: (base['baseline'] as num?)?.toDouble(),
      halfBand: spread == null ? null : 1.253 * spread,
      delta: (base['delta'] as num?)?.toDouble(),
      mdcMultiples: (base['mdc_multiples'] as num?)?.toDouble(),
      series: denseDays(pointsOf(charts[spec.chartKey]), kDriverChartDays),
    ));
  }
  return out;
}

/// The three groups, each ranked by how much it moved the score.
///
/// This is PRESENTATION, not inference: the contributions are already signed,
/// so which half of the screen a driver lands on is arithmetic. `neither` holds
/// the inputs that could not be used at all AND the ones that were used and
/// moved the score by exactly nothing — a row under "what helped" showing
/// `+0.0` is a small lie, and a row that is absent is not a row that helped.
({List<DriverFacts> helped, List<DriverFacts> held, List<DriverFacts> neither})
    splitDrivers(List<DriverFacts> f) {
  final helped = <DriverFacts>[], held = <DriverFacts>[], neither = <DriverFacts>[];
  for (final d in f) {
    final c = d.used ? d.contribution : null;
    if (c == null || c == 0) {
      neither.add(d);
    } else if (c > 0) {
      helped.add(d);
    } else {
      held.add(d);
    }
  }
  int byWeight(DriverFacts a, DriverFacts b) =>
      (b.contribution ?? 0).abs().compareTo((a.contribution ?? 0).abs());
  helped.sort(byWeight);
  held.sort(byWeight);
  return (helped: helped, held: held, neither: neither);
}

/// The reading, the usual, the direction and the size of the move — one line.
///
/// Null when the numbers are not there, or are not in units a person can read
/// (see [DriverFacts.numeric]). Never a partial sentence with a blank in it.
String? driverValueLine(BuildContext c, DriverFacts f) {
  final l = AppLocalizations.of(c);
  final unit = unitBeside(f.spec.unit);
  final suffix = unit.isEmpty ? '' : ' $unit';
  if (!f.numeric) {
    // Direction only, and only when a direction was measured. "Higher than
    // usual" is the whole honest content of a raw ADC deviation.
    final d = f.delta;
    if (d == null || d == 0) return null;
    return d > 0
        ? (l?.driverBreakdownHigherThanUsual ?? 'Higher than your usual')
        : (l?.driverBreakdownLowerThanUsual ?? 'Lower than your usual');
  }
  final v = f.value, u = f.usual, d = f.delta;
  if (v == null) return null;
  final now = '${metricValue(f.spec.unit, v)}$suffix';
  if (u == null || d == null) return now;
  if (metricValue(f.spec.unit, d.abs()) == metricValue(f.spec.unit, 0)) {
    return l?.driverBreakdownRightOnUsual(now) ?? '$now · right on your usual';
  }
  final deltaStr = '${metricValue(f.spec.unit, d.abs())}$suffix';
  final usualStr = '${metricValue(f.spec.unit, u)}$suffix';
  return d > 0
      ? (l?.driverBreakdownAboveUsual(now, deltaStr, usualStr) ??
          '$now · $deltaStr above your usual $usualStr')
      : (l?.driverBreakdownBelowUsual(now, deltaStr, usualStr) ??
          '$now · $deltaStr below your usual $usualStr');
}

/// The qualifiers, in `ReadinessDetail`'s own words so the two screens agree.
///
/// The noise statement is a LADDER and says exactly one rung, because two bars
/// stated at once is not a stronger claim, it is an unreadable one:
///
///   1. not usable at all,
///   2. inside your usual spread — the smallest-worthwhile-change gate, the
///      same gate that decides whether the glass box names a driver,
///   3. outside it, and bigger than measurement noise (|delta| ≥ MDC),
///   4. outside it, but still inside measurement noise,
///   5. outside it, with no honest noise estimate — which says nothing rather
///      than rounding a missing MDC up into a claim.
List<String> driverQualifiers(BuildContext c, DriverFacts f) {
  final l = AppLocalizations.of(c);
  final share = f.weightShare;
  final m = f.mdcMultiples;
  return [
    if (share != null)
      l?.driverBreakdownWeightPct((share * 100).round()) ??
          '${(share * 100).round()}% weight',
    if (!f.used) l?.driverBreakdownNotAvailable ?? 'not available',
    if (f.used && f.contribution == null)
      l?.driverBreakdownContributionNotReported ?? 'contribution not reported',
    // A raw sensor deviation says so, every time it appears.
    if (!f.numeric)
      l?.driverBreakdownRelativeUncalibrated ?? 'relative, uncalibrated',
    if (f.used && !f.beyondUsualSpread)
      l?.driverBreakdownWithinUsualSpread ?? 'within your usual spread'
    else if (f.used && m != null)
      m.abs() >= 1
          ? (l?.driverBreakdownBiggerThanNoise ?? 'bigger than measurement noise')
          : (l?.driverBreakdownSmallerThanNoise ??
              'outside your usual spread, but small enough to be measurement '
                  'noise'),
  ];
}

/// The drivers list: what helped, what held you back, and what did neither.
///
/// [initialOpen] exists so the gallery can photograph an expanded row. Nothing
/// in the app passes it.
class DriverBreakdown extends StatefulWidget {
  const DriverBreakdown(this.facts, {super.key, this.initialOpen});

  final List<DriverFacts> facts;
  final String? initialOpen;

  @override
  State<DriverBreakdown> createState() => _DriverBreakdownState();
}

class _DriverBreakdownState extends State<DriverBreakdown> {
  /// The one open row. This screen was already long before it grew a chart per
  /// input, so the histories are behind a tap and only one is out at a time.
  String? _open;

  @override
  void initState() {
    super.initState();
    _open = widget.initialOpen;
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final g = splitDrivers(widget.facts);
    final rows = <Widget>[];

    void group(String title, List<DriverFacts> items) {
      if (items.isEmpty) return;
      if (rows.isNotEmpty) rows.add(Divider(color: p.line, height: 1));
      rows.add(Padding(
        padding: const EdgeInsets.only(top: S.x3, bottom: S.x1),
        child: Text(title, style: F.cap.copyWith(color: p.ink3)),
      ));
      for (final f in items) {
        rows.add(_DriverTile(
          f,
          open: _open == f.key,
          onTap: !f.chartable
              ? null
              : () => setState(() => _open = _open == f.key ? null : f.key),
        ));
      }
    }

    group(l?.driverBreakdownWhatHelped ?? 'What helped', g.helped);
    group(l?.driverBreakdownWhatHeldYouBack ?? 'What held you back', g.held);
    // Deliberately last and deliberately not called "what did nothing": an
    // input that was never measured did not fail to move your score, it was
    // absent, and the row underneath says which.
    group(l?.driverBreakdownNeither ?? 'Neither', g.neither);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Surface(
        pad: const EdgeInsets.symmetric(horizontal: S.x4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
      ),
      const SizedBox(height: S.x4),
      Surface(
        elevation: 0,
        color: p.card2,
        child: Text(
          l?.driverBreakdownFooter ??
              'Each input is compared with your own history, beside the score rather than part of it. "Measurement noise" is how far a reading moves on its own.',
          style: F.cap.copyWith(color: p.ink3, height: 1.5),
        ),
      ),
    ]);
  }
}

class _DriverTile extends StatelessWidget {
  const _DriverTile(this.f, {required this.open, this.onTap});

  final DriverFacts f;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final contribution = f.used ? f.contribution : null;
    final value = driverValueLine(c, f);
    final quals = driverQualifiers(c, f).join(' · ');
    // The pipeline's own reason, never a written-here one. `need_baseline:
    // have=2,need=7` becomes "Need 5 more nights"; anything it cannot read
    // comes back null and the row simply says "not available" above.
    final why = f.used ? null : whyFromNote(f.note);

    final head = Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(f.label, style: F.body.copyWith(color: p.ink)),
            if (value != null)
              Text(value, style: F.cap.copyWith(color: p.ink2, height: 1.4)),
            if (quals.isNotEmpty)
              Text(quals, style: F.over.copyWith(color: p.ink3, height: 1.4)),
            if (why != null)
              Text(why, style: F.over.copyWith(color: p.ink3, height: 1.4)),
          ]),
        ),
        // No contribution number means no number — never a bare em-dash. The
        // qualifier line above says which case it is.
        if (contribution != null) ...[
          const SizedBox(width: S.x3),
          Text(
            '${contribution >= 0 ? '+' : '−'}'
            '${contribution.abs().toStringAsFixed(1)}',
            style: F.n17
                .copyWith(color: p.on(contribution >= 0 ? C.green : C.orange)),
          ),
        ],
        if (onTap != null) ...[
          const SizedBox(width: S.x2),
          Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
              size: 16, color: p.ink3),
        ],
      ]),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (onTap == null)
        head
      else
        Pressable(
          onTap: onTap,
          semanticLabel: open
              ? (l?.driverBreakdownHideHistory(f.label) ??
                  '${f.label}, hide its history')
              : (l?.driverBreakdownShowHistory(f.label) ??
                  '${f.label}, show its history'),
          child: head,
        ),
      if (open) ...[
        _chart(c, p, f),
        const SizedBox(height: S.x3),
      ],
    ]);
  }
}

/// The driver's own recent history with the user's usual range behind it.
///
/// The band is the point of the picture. "Your HRV dropped" is an assertion;
/// a line leaving a shaded band is the same claim with its evidence attached,
/// and the band is the pipeline's own `|z| ≤ 1` — not a second definition of
/// normal invented for a chart.
Widget _chart(BuildContext c, P p, DriverFacts f) {
  final l = AppLocalizations.of(c);
  final win = _window(f.series);
  final band = f.band;
  final ink = p.on(f.spec.color);
  final fmt = f.spec.unit == 'br/min' || f.spec.unit == '°' ? axisFixed : axisInt;
  // The band is part of the scale. Left out of the axis it could sit off the
  // top of the plot, and a usual range you cannot see is not a usual range.
  final axis = AxisSpec.of(
    [
      for (final v in win) ?v,
      if (band != null) ...[band.$1, band.$2],
    ],
    format: fmt,
  );
  final unit = unitBeside(f.spec.unit);

  return ChartFrame(
    title: f.label,
    unit: f.spec.unit,
    height: 110,
    yAxis: axis,
    xLabels: win.length < 2
        ? const []
        : [
            l?.driverBreakdownDaysAgo(win.length - 1) ??
                '${win.length - 1} day${win.length == 2 ? '' : 's'} ago',
            l?.driverBreakdownToday ?? 'Today',
          ],
    series: win,
    footnote: band == null
        ? null
        : (l?.driverBreakdownUsualRange(
                metricValue(f.spec.unit, band.$1),
                metricValue(f.spec.unit, band.$2),
                unit.isEmpty ? '' : ' $unit') ??
            'Your usual range ${metricValue(f.spec.unit, band.$1)}–'
                '${metricValue(f.spec.unit, band.$2)}'
                '${unit.isEmpty ? '' : ' $unit'}'),
    empty: axis == null ? const NoData() : null,
    band: band == null ? null : UsualRange(band.$1, band.$2),
    bandColor: p.wash(f.spec.color),
    child: axis == null
        ? const SizedBox.shrink()
        : CustomPaint(
            size: Size.infinite,
            // No fill. A gradient under the line and a tinted band behind it
            // are two washes of the same colour arguing about which one the
            // eye should read as "normal".
            painter: LineChart(win, ink,
                fill: false, dots: true, dotInk: p.card, t: animate(c, 1),
                axis: axis),
          ),
  );
}

/// Leading empty days trimmed, so the x labels span days that exist. A
/// thirty-slot window on a five-day-old install drew twenty-five blanks under
/// the label "29 days ago".
List<double?> _window(List<double?> s) {
  final first = s.indexWhere((v) => v != null);
  return first <= 0 ? s : s.sublist(first);
}

/// A day with no readiness at all.
///
/// It never guesses. The rollup is withheld with a reason, or the glass box
/// carries its own note, or nothing recorded says why — and the third case
/// says exactly that instead of borrowing the cold-start sentence, which is a
/// wrong answer to "the numbers exist and we will not stand behind them".
StatusCard driverAbsenceCard(
  BuildContext c, {
  Map<String, dynamic>? stale,
  String? note,
  VoidCallback? onSync,
}) {
  final l = AppLocalizations.of(c);
  if (stale != null) {
    return StatusCard(
      l?.driverBreakdownAbsenceTitle ?? 'No breakdown to show',
      switch (stale['kind']) {
        'algo_version' => l?.driverBreakdownAbsenceAlgoVersion ??
            'The way recovery is worked out changed in the last update. Your days are being recalculated.',
        'stale' => l?.driverBreakdownAbsenceStale ??
            'Your trends are out of date. Sync the band to update them.',
        _ => l?.driverBreakdownAbsenceNoVersion ??
            'Your trends are being updated. This takes a minute after a sync.',
      },
      fix: onSync == null ? '' : (l?.driverBreakdownSyncTheBand ?? 'Sync the band'),
      onFix: onSync,
      icon: LucideIcons.refreshCw,
    );
  }
  return StatusCard(
    l?.driverBreakdownAbsenceTitle ?? 'No breakdown to show',
    whyFromNote(note) ??
        (l?.driverBreakdownAbsenceNoReason ??
            'Nothing recorded says why last night has no breakdown.'),
    icon: LucideIcons.listTree,
  );
}
