// THE SHARED TREND READING.
//
// Every trend chart answers the same two questions before it shows a single
// point: is this normal for you, and which way did it move. One range model,
// one band painter and one verdict line, so the Health cards, the metric
// screen, recovery history and the month grid cannot each invent a slightly
// different idea of "usual".
//
// Abstention is part of the model. Under [kUsualMinDays] days of your own
// history there is no range, nothing is shaded and the verdict is not drawn;
// the caller says so in one short line ([usualNeedsDaysText]).

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../compute/findings.dart' show kReadinessEasyBelow, kReadinessGoodFrom;
import '../l10n/app_localizations.dart';
import 'charts.dart';
import 'theme.dart';

/// Days of your own history before a usual range is drawn.
const int kUsualMinDays = 14;

/// Where a reading sits against a [UsualRange].
enum Side { below, inside, above }

/// Your usual range for one metric: low and high, in the metric's own unit.
@immutable
class UsualRange {
  const UsualRange(this.lo, this.hi);

  final double lo, hi;

  /// The centre. Both sources below are symmetric, so this is the baseline.
  double get usual => (lo + hi) / 2;

  Side side(double v) =>
      v < lo ? Side.below : (v > hi ? Side.above : Side.inside);

  /// The pipeline's own band from a day bundle `baselines` block: centre
  /// ± 1.253 × spread, which is exactly the `|z| ≤ 1` it reports as
  /// `in_normal_range`. Null under [kUsualMinDays] folded nights.
  static UsualRange? fromBaseline(Object? block) {
    if (block is! Map) return null;
    final c = (block['baseline'] as num?)?.toDouble();
    final s = (block['spread'] as num?)?.toDouble();
    final n = (block['n_valid'] as num?)?.toInt() ?? 0;
    if (c == null || s == null || !c.isFinite || !(s > 0) || n < kUsualMinDays) {
      return null;
    }
    return UsualRange(c - 1.253 * s, c + 1.253 * s);
  }

  /// For a metric the pipeline keeps no baseline for: the same convention
  /// (centre ± 1.253 × mean absolute deviation) over up to the [window] stored
  /// days BEFORE the newest, so today is judged against days that are not
  /// itself. Null under [kUsualMinDays] days or on a flat history.
  // ponytail: plain median/MAD, not the pipeline's winsorised EWMA. Swap in a
  // stored baseline per metric if the pipeline ever publishes one.
  static UsualRange? priorTo(List<double> stored, {int window = 60}) {
    if (stored.length < 2) return null;
    final end = stored.length - 1;
    final start = end - window < 0 ? 0 : end - window;
    final v = [
      for (final x in stored.sublist(start, end))
        if (x.isFinite) x,
    ]..sort();
    if (v.length < kUsualMinDays) return null;
    final med = v.length.isOdd
        ? v[v.length ~/ 2]
        : (v[v.length ~/ 2 - 1] + v[v.length ~/ 2]) / 2;
    final mad = v.fold<double>(0, (a, x) => a + (x - med).abs()) / v.length;
    if (!(mad > 0)) return null;
    return UsualRange(med - 1.253 * mad, med + 1.253 * mad);
  }

  /// An axis that holds the data AND the band with one band-width of room on
  /// each side, so a calm week sits calmly inside the band instead of filling
  /// the card. A band that starts at or above zero never pushes the axis
  /// below it.
  AxisSpec? axis(
    Iterable<double> data, {
    int ticks = 3,
    String Function(double) format = axisInt,
    double? floor,
  }) {
    final w = hi - lo;
    var bottom = lo - w;
    if (lo >= 0 && bottom < 0) bottom = 0;
    return AxisSpec.of(
      [...data, bottom, hi + w],
      ticks: ticks,
      format: format,
      floor: floor,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UsualRange && other.lo == lo && other.hi == hi;

  @override
  int get hashCode => Object.hash(lo, hi);
}

/// "Normal for you" / "Above usual" / "Below usual".
String usualWord(AppLocalizations? l, Side s) => switch (s) {
      Side.inside => l?.trendNormalForYou ?? 'Normal for you',
      Side.above => l?.trendAboveUsual ?? 'Above usual',
      Side.below => l?.trendBelowUsual ?? 'Below usual',
    };

/// "Usual range 52–60 bpm" — the band in words, for footnotes and speech.
String usualRangeText(AppLocalizations? l, String lo, String hi, String unit) {
  final u = unit.isEmpty ? '' : ' $unit';
  return l?.trendUsualRange(lo, hi, u) ?? 'Usual range $lo–$hi$u';
}

/// The short abstain note: no band yet, and when there will be one.
String usualNeedsDaysText(AppLocalizations? l, int have) =>
    l?.trendNeedsDays(kUsualMinDays, have) ??
    'Your usual range appears after $kUsualMinDays days. $have so far.';

/// Is landing on [s] good news? Null when the metric has no better direction
/// or the reading is inside the range.
bool? sideIsGood(Side s, {required bool? higherBetter}) =>
    s == Side.inside || higherBetter == null
        ? null
        : (s == Side.above) == higherBetter;

/// The usual range drawn behind a curve on the SAME [AxisSpec] the line and
/// the gridlines use; a band solved against its own scale is decoration.
class BandLayer extends StatelessWidget {
  const BandLayer(this.band, this.axis, this.color, {super.key});

  final UsualRange band;
  final AxisSpec axis;
  final Color color;

  @override
  Widget build(BuildContext c) => LayoutBuilder(
        builder: (_, box) {
          final h = box.maxHeight;
          final top = h * (1 - axis.t(band.hi));
          final height = h * (axis.t(band.hi) - axis.t(band.lo));
          if (!(height > 0)) return const SizedBox.shrink();
          return Stack(children: [
            Positioned(
              left: 0,
              right: 0,
              top: top,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(color: color, borderRadius: R.rSm),
              ),
            ),
          ]);
        },
      );
}

/// The verdict line of a trend header: arrow, word, and the difference from
/// usual ("Below usual · −6 ms from your usual 54").
///
/// The arrow says which way, the colour says whether that is good news, and
/// the word says both in text, so hue is never the only channel. Inside the
/// range there is no arrow and no judgement colour.
class ReadingVerdict extends StatelessWidget {
  const ReadingVerdict({
    super.key,
    required this.side,
    required this.detail,
    this.higherBetter = true,
  });

  final Side side;

  /// "−6 ms from your usual 54". Empty draws the word alone.
  final String detail;

  /// Null for a metric with no better direction (strain, say).
  final bool? higherBetter;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final good = sideIsGood(side, higherBetter: higherBetter);
    final ink = good == null ? p.ink2 : p.on(good ? C.green : C.orange);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: S.x1,
      runSpacing: 2,
      children: [
        if (side != Side.inside)
          Icon(
            side == Side.above
                ? LucideIcons.arrowUpRight
                : LucideIcons.arrowDownRight,
            size: 14,
            color: ink,
          ),
        Text(
          usualWord(l, side),
          style: F.cap.copyWith(color: ink, fontWeight: FontWeight.w600),
        ),
        if (detail.isNotEmpty)
          Text('· $detail', style: F.cap.copyWith(color: p.ink3)),
      ],
    );
  }
}

/// "+3 bpm from your usual 57" — [diff] and [usual] already formatted.
String vsUsualText(AppLocalizations? l, String diff, String usual) =>
    l?.trendVsUsual(diff, usual) ?? '$diff from your usual $usual';

/// A signed difference, "+3" / "−3", with the minus a real minus sign.
String signed(double d, String abs) => '${d < 0 ? '−' : '+'}$abs';

/// Metric keys the pipeline publishes a personal baseline for, mapped to their
/// key in a day bundle's `baselines` block. Spelled the `MetricSpec` way.
const kBaselineKeyOf = <String, String>{
  'resting_hr': 'resting_hr',
  'hrv': 'hrv',
  'resp_rate': 'resp',
};

/// THE usual range for a metric, from one place so every chart of it agrees.
///
/// A metric the pipeline keeps a baseline for uses that baseline and nothing
/// else (its absence is an abstention, never a second definition filled in
/// from the chart). Every other metric uses [UsualRange.priorTo] over its
/// [stored] values, oldest first.
UsualRange? usualRangeFor(
  String key,
  List<double> stored,
  Map<String, dynamic>? baselines,
) {
  final b = kBaselineKeyOf[key];
  if (b != null) return UsualRange.fromBaseline(baselines?[b]);
  // Recovery is already a percentile of your own history (50 is your median
  // night), and its ring bands say what usual is: "Steady". The chart band is
  // that band, so the history and the ring cannot disagree.
  if (key == 'readiness') {
    return stored.length - 1 < kUsualMinDays
        ? null
        : const UsualRange(kReadinessEasyBelow, kReadinessGoodFrom);
  }
  return UsualRange.priorTo(stored);
}

/// Metrics where neither direction is good news: more load is not better load,
/// and a ratio or an uncalibrated deviation has no better side. Their verdict
/// and their month-grid cells carry no good/bad colour.
const kNoBetterDirection = {'strain', 'trimp', 'lf_hf', 'skin_temp'};

/// The better direction for [key], or null when there is none.
bool? betterDirection(String key, {required bool higherBetter}) =>
    kNoBetterDirection.contains(key) ? null : higherBetter;
