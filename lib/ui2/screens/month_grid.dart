import '../../l10n/display_text.dart';
// THE MONTH AS THREE STRIPS — sleep, recovery, strain, one cell per day.
//
// A shade is not a score. Every cell is the day's place in THIS PERSON'S OWN
// range — the 10th to 90th percentile of every day they have stored for that
// metric — and nothing here is compared to a population, a target, or anybody
// else. A darker strain cell is a bigger day, not a better one; a darker sleep
// cell is a longer night, not a healthier one. The footnote says so, because a
// grid is the surface a reader is most likely to read a verdict into.
//
// ABSENCE IS AN OUTLINE, and that rule was already solved: `HeatMap` draws a
// null as a stroked cell rather than a faint fill, because a faint fill and a
// genuinely low value measured 1.00:1 against each other. A day the band was
// off must never look like a bad day.
//
// A METRIC WITH NO RANGE IS NOT SHADED AT ALL. Placing a day inside a
// distribution built from nine other days is a shade with nothing behind it, so
// a metric under [kGridMinHistory] days is left out of the picture entirely and
// says why in words. It does not get a paler version of the same claim.
//
// AND THERE IS NO STREAK IN HERE. A month grid is the classic place one gets
// in — a run of filled cells is exactly the shape a streak wants to be — so
// the only count on the page is "N of 30 days", which cannot reset to zero and
// does not pay more for consecutive days than for scattered ones.

import 'package:flutter/material.dart';

import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'home_screen.dart' show ChartPoint, denseDays, pointsOf;
import 'metric_detail.dart' show MetricSpec, specOf;

/// Days on screen. One month, and the same window every trend card uses.
const int kGridDays = 30;

/// Days of the user's OWN history needed before a cell may be shaded. Below
/// this there is no personal range to place a day inside, and inventing one is
/// the thing this file exists to not do.
const int kGridMinHistory = 14;

/// The three domains, in the order a day is lived: the night, what it left you
/// with, what you spent. Keys are `specOf`'s, so the colour, the title and the
/// chart alias all come from the one place that already owns them.
const List<String> kGridMetrics = ['sleep', 'readiness', 'strain'];

/// One domain's month: the 30 cells, and whether they may be shaded at all.
@immutable
class GridRow {
  const GridRow({
    required this.spec,
    required this.cells,
    required this.have,
    required this.historyDays,
  });

  final MetricSpec spec;

  /// 0…1 per day, oldest first, null for a day with no stored value. Already
  /// mapped through [shadeCells] — a painter never sees a raw value.
  final List<double?> cells;

  /// Days in the window that have a value. NOT a streak: see the file header.
  final int have;

  /// Days of stored history the shading was built from.
  final int historyDays;

  bool get shaded => historyDays >= kGridMinHistory;
}

/// Percentile by nearest rank over a sorted list. The same reduction the
/// nightly sweep reads its "usually X–Y" band off, so the two surfaces cannot
/// disagree about what this person's ordinary looks like.
double _percentile(List<double> sorted, double q) =>
    sorted[((sorted.length - 1) * q).round()];

/// The day → shade map. PURE.
///
/// [history] is every value this person has stored for the metric — not just
/// the window, because a month shaded against itself makes the best day of a
/// bad month look like a good one. Returns nulls unchanged: a day with no
/// value has no place in a distribution.
///
/// Clamped at the 10th and 90th percentile rather than min and max, so one
/// four-hour night does not compress every other night into the same shade.
List<double?> shadeCells(List<double?> window, List<double> history) {
  if (history.length < kGridMinHistory) return List<double?>.filled(window.length, null);
  final sorted = [...history]..sort();
  final lo = _percentile(sorted, .1), hi = _percentile(sorted, .9);
  // A flat history has no inside to place a day in. Everything measured reads
  // as the middle, which is true: none of these days differ from each other.
  if (!(hi > lo)) {
    return [for (final v in window) v == null ? null : .5];
  }
  return [
    for (final v in window)
      if (v == null) null else ((v - lo) / (hi - lo)).clamp(0.0, 1.0),
  ];
}

/// Build one domain's row from its stored points.
GridRow gridRow(String key, List<ChartPoint> points) {
  final window = denseDays(points, kGridDays);
  final history = [for (final p in points) p.v];
  return GridRow(
    spec: specOf(key),
    cells: shadeCells(window, history),
    have: window.where((v) => v != null).length,
    historyDays: history.length,
  );
}

/// Every row, loaded. One `getChart` per domain — the same read the trend
/// cards already do.
Future<List<GridRow>> loadGridRows(LocalRepository repo) async {
  final out = <GridRow>[];
  for (final key in kGridMetrics) {
    try {
      out.add(gridRow(key, pointsOf(await repo.getChart(specOf(key).chartKey))));
    } catch (_) {/* a series we cannot read is a row we do not draw */}
  }
  return out;
}

/// The picture. Three strips, each labelled above itself rather than beside
/// itself: a label column has to agree with the row height, and at 3.1x text
/// it cannot.
class MonthGrid extends StatelessWidget {
  const MonthGrid(this.rows, {super.key});

  final List<GridRow> rows;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final shaded = [for (final r in rows) if (r.shaded) r];
    final waiting = [for (final r in rows) if (!r.shaded) r];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shaded.isNotEmpty)
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in shaded) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: S.x1),
                    child: bigText(c)
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                uiText(c, r.spec.title),
                                style: F.over.copyWith(color: p.ink2),
                              ),
                              Text(
                                l?.monthGridCoverage(r.have, kGridDays) ??
                                    '${r.have} of $kGridDays days',
                                style: F.over.copyWith(color: p.ink3),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(
                                child: Text(
                                  uiText(c, r.spec.title),
                                  style: F.over.copyWith(color: p.ink2),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: S.x2),
                              // Coverage, never a run. "23 of 30" costs a missed day
                              // one day; a streak costs it everything.
                              Text(
                                l?.monthGridCoverage(r.have, kGridDays) ??
                                    '${r.have} of $kGridDays days',
                                style: F.over.copyWith(color: p.ink3),
                              ),
                            ],
                          ),
                  ),
                  Semantics(
                    label:
                        l?.monthGridSemanticsLabel(
                          uiText(c, r.spec.title),
                          r.have,
                          kGridDays,
                        ) ??
                        '${r.spec.title}: ${r.have} of $kGridDays days have '
                            'a value. Shaded against your own range.',
                    child: SizedBox(
                      height: 22,
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: HeatMap(
                          [for (final v in r.cells) [v]],
                          p.on(r.spec.color),
                          p.line,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: S.x4),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      flex: 2,
                      child: Text(
                        l?.monthGridDaysAgo(kGridDays - 1) ??
                            '${kGridDays - 1} days ago',
                        style: F.over.copyWith(color: p.ink3)),
                    ),
                    const SizedBox(width: S.x2),
                    Flexible(
                      child: Text(
                        l?.monthGridToday ?? 'Today',
                        textAlign: TextAlign.end,
                        style: F.over.copyWith(color: p.ink3),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: S.x3),
                Text(
                  l?.monthGridFootnote ??
                      'One cell per day. Darker is further up YOUR own range — the '
                      '10th to 90th percentile of every day you have stored — and '
                      'an outlined cell is a day with no value, not a low one. '
                      'More strain is not better strain and longer sleep is not '
                      'healthier sleep; this says where a day sat, not how it went.',
                  style: F.over.copyWith(color: p.ink3, height: 1.5),
                ),
              ],
            ),
          ),
        for (final r in waiting)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: StatusCard(
              l?.monthGridNotShadedYetTitle(uiText(c, r.spec.title)) ??
                  '${r.spec.title} is not shaded yet',
              l?.monthGridNotShadedYetBody(r.historyDays, kGridMinHistory) ??
                  'A shade is where a day sits in your own range, and '
                      '${r.historyDays} day${r.historyDays == 1 ? '' : 's'} is not '
                      'a range. It appears at $kGridMinHistory.',
            ),
          ),
      ],
    );
  }
}
