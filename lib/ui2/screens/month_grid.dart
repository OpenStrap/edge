import '../../l10n/display_text.dart';
// THE MONTH AS THREE STRIPS — sleep, recovery, strain, one cell per day.
//
// A cell says where a day sat against THIS PERSON'S OWN usual range: inside
// it, below it or above it. It is the same range the trend charts draw as a
// band (`usualRangeFor`), so a day "above usual" on the metric screen is above
// usual here too. Nothing is compared to a population, a target or anybody
// else.
//
// DIRECTION IS PER METRIC. A short night is worse than usual, a low recovery is
// worse than usual, and a big strain day is neither: strain has no better side,
// so its outside days take the metric's own colour and no verdict. Colour is
// never the only channel: an above-range cell carries a bar on its top edge and
// a below-range cell on its bottom edge.
//
// ABSENCE IS AN OUTLINE. A day the band was off must never look like a bad day.
//
// A METRIC WITH NO RANGE IS NOT COLOURED AT ALL. Under [kGridMinHistory] days
// there is no usual range to place a day against, so the row is left out of
// the picture and says why in words.
//
// AND THERE IS NO STREAK IN HERE. The only count on the page is "N of 30
// days", which cannot reset to zero and does not pay more for consecutive days
// than for scattered ones.

import 'package:flutter/material.dart';

import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'home_screen.dart' show ChartPoint, denseDays, pointsOf;
import 'metric_detail.dart' show MetricSpec, specOf;

/// Days on screen. One month, and the same window every trend card uses.
const int kGridDays = 30;

/// Days of the user's OWN history needed before a cell may be coloured: the
/// newest day plus the [kUsualMinDays] before it that the range is built on.
const int kGridMinHistory = kUsualMinDays + 1;

/// The three domains, in the order a day is lived: the night, what it left you
/// with, what you spent. Keys are `specOf`'s, so the colour, the title and the
/// chart alias all come from the one place that already owns them.
const List<String> kGridMetrics = ['sleep', 'readiness', 'strain'];

/// One domain's month: the 30 cells, and whether they may be coloured at all.
@immutable
class GridRow {
  const GridRow({
    required this.spec,
    required this.key,
    required this.cells,
    required this.have,
    required this.historyDays,
  });

  final MetricSpec spec;
  final String key;

  /// Per day, oldest first: where the day sat against the usual range, or null
  /// for a day with no value or a row with no range.
  final List<Side?> cells;

  /// Days in the window that have a value. NOT a streak: see the file header.
  final int have;

  /// Days of stored history the range was built from.
  final int historyDays;

  bool get shaded => cells.any((c) => c != null);

  /// Null for a metric with no better side.
  bool? get higherBetter =>
      betterDirection(key, higherBetter: spec.higherBetter);
}

/// The day → side map. PURE. No range, no sides.
List<Side?> sideCells(List<double?> window, UsualRange? band) => [
      for (final v in window) band == null || v == null ? null : band.side(v),
    ];

/// Build one domain's row from its stored points.
GridRow gridRow(String key, List<ChartPoint> points) {
  final window = denseDays(points, kGridDays);
  final history = [for (final p in points) p.v];
  return GridRow(
    spec: specOf(key),
    key: key,
    cells: sideCells(window, usualRangeFor(key, history, null)),
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

/// A cell's fill: usual is a quiet neutral, outside is good/bad by the row's
/// direction, or the metric's own colour when it has none.
Color _cellInk(P p, GridRow r, Side s) {
  if (s == Side.inside) return p.ink3.withValues(alpha: .35);
  final good = sideIsGood(s, higherBetter: r.higherBetter);
  return p.on(good == null ? r.spec.color : (good ? C.green : C.orange));
}

/// One row of cells. Above-range cells carry a bar on the top edge and
/// below-range cells on the bottom edge, so the direction survives any
/// palette and any colour vision.
class _SideStrip extends CustomPainter {
  _SideStrip(this.cells, this.ink, this.track, this.mark);

  final List<Side?> cells;
  final Color Function(Side) ink;
  final Color track, mark;

  @override
  void paint(Canvas cv, Size s) {
    if (cells.isEmpty) return;
    final cw = s.width / cells.length;
    for (var i = 0; i < cells.length; i++) {
      final v = cells[i];
      final r = Rect.fromLTWH(i * cw + 1, 1, cw - 2.5, s.height - 2.5);
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(2));
      if (v == null) {
        cv.drawRRect(
            rr,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = track);
        continue;
      }
      cv.drawRRect(rr, Paint()..color = ink(v));
      if (v != Side.inside) {
        final y = v == Side.above ? r.top : r.bottom - 3;
        cv.drawRect(Rect.fromLTWH(r.left, y, r.width, 3), Paint()..color = mark);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SideStrip o) =>
      o.cells != cells || o.track != track || o.mark != mark;
}

/// The picture. Three strips, each labelled above itself rather than beside
/// itself: a label column has to agree with the row height, and at 3.1x text
/// it cannot.
class MonthGrid extends StatelessWidget {
  const MonthGrid(this.rows, {super.key});

  final List<GridRow> rows;

  Widget _key(P p, Color ink, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: ink,
              border: Border.all(color: p.line, width: .5),
            ),
          ),
          const SizedBox(width: S.x1),
          Flexible(child: Text(label, style: F.over.copyWith(color: p.ink2))),
        ],
      );

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
                    label: l?.monthGridRowSemantics(
                          uiText(c, r.spec.title),
                          r.have,
                          kGridDays,
                          r.cells.where((s) => s == Side.below).length,
                          r.cells.where((s) => s == Side.above).length,
                        ) ??
                        '${r.spec.title}: ${r.have} of $kGridDays days have a '
                            'value. ${r.cells.where((s) => s == Side.below).length} '
                            'below and ${r.cells.where((s) => s == Side.above).length} '
                            'above your usual range.',
                    child: SizedBox(
                      height: 22,
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _SideStrip(
                          r.cells,
                          (s) => _cellInk(p, r, s),
                          p.line,
                          p.ink,
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
                ExcludeSemantics(
                  child: Wrap(
                    spacing: S.x3,
                    runSpacing: S.x1,
                    children: [
                      _key(p, p.ink3.withValues(alpha: .35),
                          l?.monthGridLegendUsual ?? 'Usual for you'),
                      if (shaded.any((r) => r.higherBetter != null)) ...[
                        _key(p, p.on(C.green),
                            l?.monthGridLegendBetter ?? 'Better than usual'),
                        _key(p, p.on(C.orange),
                            l?.monthGridLegendWorse ?? 'Worse than usual'),
                      ],
                      for (final r in shaded)
                        if (r.higherBetter == null)
                          _key(p, p.on(r.spec.color),
                              '${uiText(c, r.spec.title)}: ${l?.monthGridLegendOutside ?? 'Outside your usual range'}'),
                    ],
                  ),
                ),
                const SizedBox(height: S.x2),
                Text(
                  l?.monthGridRangeFootnote ??
                      'One cell per day. A bar at the top means above your usual range, at the bottom below it. An outlined cell has no value.',
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
