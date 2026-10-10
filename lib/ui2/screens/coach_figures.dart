// The coach's figures, drawn with the app's OWN charts.
//
// The model emits a typed spec map ({type, title, …payload}); this file turns
// it into a `ChartFrame` around a real painter from `charts.dart`. Nothing here
// draws pixels of its own — that was the point of the `render` tool, and the
// version this replaces carried six private painters that looked like the app
// and obeyed none of its rules (no axis, no legend, no spoken summary, raw
// pigment as text).
//
// Every parser fails SOFT: LLM output is liberal, and a figure that cannot be
// read renders as `NoData` inside its frame rather than throwing inside a
// ListView builder. A frame with no data keeps its title and its unit, which is
// the house form for "the number exists but the series behind the picture does
// not".

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../state/clock_format.dart' show formatClockOf;
import '../ui2.dart';

// ── loose parsing (the model is not a schema) ────────────────────────────────

List<dynamic> _list(dynamic v) {
  if (v is List) return v;
  if (v is Map && v['item'] is List) return v['item'] as List;
  if (v is Map && v['items'] is List) return v['items'] as List;
  return const [];
}

double? _num(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final d = double.tryParse(v.trim());
    if (d != null) return d;
    // '62 ms' — units glued on. Take the first number.
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v);
    return m == null ? null : double.tryParse(m.group(0)!);
  }
  if (v is Map) return _num(v['value'] ?? v['y'] ?? v['v']);
  return null;
}

String _str(dynamic v) => v == null ? '' : v.toString();

List<double?> _values(dynamic v) => [for (final e in _list(v)) _num(e)];

/// One named line of numbers.
typedef _Series = ({String name, List<double?> values});

List<_Series> _seriesOf(Map<String, dynamic> s) => [
  for (final e in _list(s['series'] ?? s['lanes']).whereType<Map>())
    (
      name: _str(e['name'] ?? e['label']),
      values: _values(e['values'] ?? e['data'] ?? e['y']),
    ),
];

/// Series colours, solved against the surface. Raw pigment is not legible as a
/// mark on a card — and the legend swatch is the mark's real colour because it
/// comes from the same list.
List<Color> _inks(P p) => [
  p.on(C.blue),
  p.on(C.orange),
  p.on(C.teal),
  p.on(C.purple),
  p.on(C.green),
];

/// First, middle and last — the three positions `ChartFrame` marks. More than
/// three labels under a 90-point series is a smear.
List<String> _xLabels(dynamic raw) {
  final all = [for (final e in _list(raw)) _str(e)];
  if (all.length <= 3) return all;
  return [all.first, all[all.length ~/ 2], all.last];
}

/// The axis every painter in one figure shares. Null when nothing is finite,
/// which is the signal to render the frame's empty state.
AxisSpec? _axisFor(Iterable<List<double?>> series) {
  final flat = [
    for (final s in series)
      for (final v in s)
        if (v != null && v.isFinite) v,
  ];
  return flat.isEmpty ? null : AxisSpec.of(flat, format: axisFixedOrInt);
}

// ── the figure ───────────────────────────────────────────────────────────────

/// One figure from the coach. [spec] is `{type, title, …}` — either a `render`
/// payload or `ChartSpec.toJson()`, which is the same shape.
class CoachFigure extends StatelessWidget {
  final Map<String, dynamic> spec;
  const CoachFigure({super.key, required this.spec});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final type = _str(spec['type']).toLowerCase();
    final title = _str(spec['title']);
    final unit = _str(spec['unit'] ?? spec['y_unit']);
    final note = _str(spec['note']);

    final body = switch (type) {
      'line' || 'area' || 'multi_series' => _lines(c, p, title, unit),
      'bar' || 'bars' => _bars(c, p, title, unit),
      'lanes' || 'dual_axis' => _lanes(c, p, title),
      'hypnogram' => _hypnogram(c, p, title),
      'zone_bar' || 'stacked_zone_bar' => _zones(c, p, title),
      'gauge' => _gauge(c, p, title, unit),
      'kpi_grid' => _kpis(c, p, title),
      'heatmap' => _heatmap(c, p, title, unit),
      'table' => _table(c, p, title),
      _ => _unsupported(c, title, type),
    };

    if (note.isEmpty) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        const SizedBox(height: S.x2),
        Text(note, style: F.cap.copyWith(color: p.ink3, height: 1.4)),
      ],
    );
  }

  Widget _unsupported(BuildContext c, String title, String type) {
    final l = AppLocalizations.of(c);
    return StatusCard(
      title.isEmpty
          ? (l?.coachFiguresCouldNotBeDrawn ?? 'A figure could not be drawn')
          : title,
      type.isEmpty
          ? (l?.coachFiguresNoType ?? 'The coach sent a figure with no type.')
          : (l?.coachFiguresUnsupportedType(type) ??
              'The coach asked for a "$type" figure, which this app does not draw.'),
      icon: LucideIcons.chartNoAxesColumn,
    );
  }

  Widget _frame(
    BuildContext c,
    String title,
    String unit,
    Widget child, {
    AxisSpec? yAxis,
    List<String> xLabels = const [],
    List<(String, Color)> legend = const [],
    List<double?> series = const [],
    double height = 140,
    Widget? empty,
    String? footnote,
  }) => ChartFrame(
    title: title.isEmpty ? (AppLocalizations.of(c)?.coachFiguresFigure ?? 'Figure') : title,
    unit: unit,
    height: height,
    yAxis: yAxis,
    xLabels: xLabels,
    legend: legend,
    series: series,
    empty: empty,
    footnote: footnote,
    child: child,
  );

  // ── line / area / multi-series ─────────────────────────────────────────────
  //
  // One shared axis for every series in the figure. Two curves on two invisible
  // scales is the classic chart lie, and it is the default a painter falls back
  // to when nobody gives it an axis.
  Widget _lines(BuildContext c, P p, String title, String unit) {
    final series = _seriesOf(spec);
    final axis = _axisFor(series.map((s) => s.values));
    if (axis == null) {
      return _frame(c, title, unit, const SizedBox.shrink(), empty: const NoData());
    }
    final l = AppLocalizations.of(c);
    final inks = _inks(p);
    return _frame(
      c,
      title,
      unit,
      Stack(
        children: [
          for (var i = 0; i < series.length; i++)
            Positioned.fill(
              child: CustomPaint(
                size: Size.infinite,
                painter: LineChart(
                  series[i].values,
                  inks[i % inks.length],
                  // A filled area reads as a quantity from a baseline, so it is
                  // only honest for ONE series against a stated axis.
                  fill: series.length == 1 &&
                      _str(spec['type']).toLowerCase() == 'area',
                  axis: axis,
                ),
              ),
            ),
        ],
      ),
      yAxis: axis,
      xLabels: _xLabels(spec['x_labels'] ?? spec['labels'] ?? spec['x']),
      legend: series.length < 2
          ? const []
          : [
              for (var i = 0; i < series.length; i++)
                (
                  series[i].name.isEmpty
                      ? (l?.coachFiguresSeriesN(i + 1) ?? 'Series ${i + 1}')
                      : series[i].name,
                  inks[i % inks.length],
                ),
            ],
      series: series.length == 1 ? series.first.values : const [],
    );
  }

  // ── bars ───────────────────────────────────────────────────────────────────
  Widget _bars(BuildContext c, P p, String title, String unit) {
    final series = _seriesOf(spec);
    final d = series.isEmpty ? _values(spec['values']) : series.first.values;
    // Bars are measured from a baseline; a bar axis that does not include zero
    // is the truncated-axis lie with the truncation hidden.
    final finite = [
      for (final v in d)
        if (v != null && v.isFinite) v,
    ];
    final axis = finite.isEmpty
        ? null
        : AxisSpec.of(finite, floor: 0, format: axisFixedOrInt);
    if (axis == null) {
      return _frame(c, title, unit, const SizedBox.shrink(), empty: const NoData());
    }
    return _frame(
      c,
      title,
      unit,
      CustomPaint(
        size: Size.infinite,
        painter: Bars(d, p.on(C.blue), axis: axis),
      ),
      yAxis: axis,
      xLabels: _xLabels(spec['x_labels'] ?? spec['labels'] ?? spec['x']),
      series: d,
    );
  }

  // ── lanes (was dual_axis) ──────────────────────────────────────────────────
  //
  // Two units never share a y scale here. `NightStack` gives each its own lane
  // and its own axis, which is the app's answer to a second y axis — a right
  // axis is read as if it were the left one about as often as not.
  Widget _lanes(BuildContext c, P p, String title) {
    var series = _seriesOf(spec);
    if (series.isEmpty) {
      // `dual_axis` shape: {left:{name,values,unit}, right:{…}}.
      series = [
        for (final k in const ['left', 'right'])
          if (spec[k] is Map)
            (
              name: _str((spec[k] as Map)['name']),
              values: _values((spec[k] as Map)['values']),
            ),
      ];
    }
    // DENSE, holes intact. `NightStack` drops any lane whose length differs
    // from the longest one — they are on different clocks — so compacting the
    // nulls out of a lane with one missing reading would make the whole lane
    // silently disappear.
    final lanes = [
      for (final s in series)
        if (s.values.any((v) => v != null && v.isFinite)) s.values,
    ];
    if (lanes.isEmpty) {
      return _frame(c, title, '', const SizedBox.shrink(), empty: const NoData());
    }
    final loc = AppLocalizations.of(c);
    final inks = _inks(p);
    final units = [
      for (final k in const ['left', 'right'])
        if (spec[k] is Map) _str((spec[k] as Map)['unit']),
    ];
    return _frame(
      c,
      title,
      units.where((u) => u.isNotEmpty).join(' · '),
      CustomPaint(
        size: Size.infinite,
        painter: NightStack(lanes, [
          for (var i = 0; i < lanes.length; i++) inks[i % inks.length],
        ], axes: [
          for (final l in lanes)
            AxisSpec.of([
              for (final v in l)
                if (v != null && v.isFinite) v,
            ], ticks: 2),
        ]),
      ),
      height: 60.0 * lanes.length + 40,
      xLabels: _xLabels(spec['x_labels'] ?? spec['labels'] ?? spec['x']),
      legend: [
        for (var i = 0; i < series.length && i < lanes.length; i++)
          (
            series[i].name.isEmpty
                ? (loc?.coachFiguresLaneN(i + 1) ?? 'Lane ${i + 1}')
                : series[i].name,
            inks[i % inks.length],
          ),
      ],
    );
  }

  // ── hypnogram ──────────────────────────────────────────────────────────────
  Widget _hypnogram(BuildContext c, P p, String title) {
    final l = AppLocalizations.of(c);
    final noSegs =
        NoData(message: l?.coachFiguresNoSleepSegments ?? 'No sleep segments');
    final segs = _list(spec['segments']).whereType<Map>().toList();
    // The painter takes one entry per EPOCH, in order — it has no opinion about
    // time. Expand the segments onto a fixed grid so a 20-minute REM block and
    // a 20-minute deep block are the same width.
    const slots = 480; // one per minute of an eight-hour night
    final lo = [for (final s in segs) ?_num(s['start'])];
    final hi = [for (final s in segs) ?_num(s['end'])];
    if (lo.isEmpty || hi.isEmpty) {
      return _frame(c, title, 'stage', const SizedBox.shrink(), empty: noSegs);
    }
    final t0 = lo.reduce((a, b) => a < b ? a : b);
    final t1 = hi.reduce((a, b) => a > b ? a : b);
    if (t1 <= t0) {
      return _frame(c, title, 'stage', const SizedBox.shrink(), empty: noSegs);
    }
    final grid = List<SleepStage>.filled(slots, SleepStage.awake);
    for (final s in segs) {
      final a = _num(s['start']), b = _num(s['end']);
      if (a == null || b == null || b <= a) continue;
      final stage = switch (_str(s['stage']).toLowerCase()) {
        'deep' => SleepStage.deep,
        'rem' => SleepStage.rem,
        'light' => SleepStage.light,
        _ => SleepStage.awake,
      };
      final i0 = ((a - t0) / (t1 - t0) * slots).floor().clamp(0, slots - 1);
      final i1 = ((b - t0) / (t1 - t0) * slots).ceil().clamp(0, slots);
      for (var i = i0; i < i1; i++) {
        grid[i] = stage;
      }
    }
    String hhmm(double epochSec) {
      final d = DateTime.fromMillisecondsSinceEpoch(
        (epochSec * 1000).round(),
      ).toLocal();
      return formatClockOf(d);
    }

    return _frame(
      c,
      title,
      'stage',
      CustomPaint(size: Size.infinite, painter: Hypnogram(grid, p)),
      height: 130,
      xLabels: [hhmm(t0), hhmm(t1)],
      legend: Hypnogram.legend(p, AppLocalizations.of(c)),
    );
  }

  // ── zone bar ───────────────────────────────────────────────────────────────
  //
  // Five labelled rows, the same component every zone split in the app uses.
  // No bpm ranges: a figure spec carries minutes, not the edges they were cut at.
  Widget _zones(BuildContext c, P p, String title) {
    final l = AppLocalizations.of(c);
    var z = [
      for (final v in _values(spec['zones'] ?? spec['values']))
        if (v != null && v.isFinite && v >= 0) v,
    ];
    // {zones:[{name, values:[…]}]} — sum each zone across the window.
    if (z.isEmpty) {
      z = [
        for (final s in _seriesOf(spec))
          s.values.fold<double>(0, (a, v) => a + (v ?? 0)),
      ];
    }
    final total = z.fold<double>(0, (a, v) => a + v);
    if (z.length < 2 || total <= 0) {
      return _frame(
        c,
        title,
        'min',
        const SizedBox.shrink(),
        empty: NoData(
            message: l?.coachFiguresNoTimeInZone ?? 'No time in zone'),
      );
    }
    return ZoneRows(
      [...z.take(5)],
      title: title.isEmpty ? (l?.coachFiguresFigure ?? 'Figure') : title,
      footnote: l?.coachFiguresMinTotal(total.round()) ??
          '${total.round()} min total',
    );
  }

  // ── gauge ──────────────────────────────────────────────────────────────────
  Widget _gauge(BuildContext c, P p, String title, String unit) {
    final l = AppLocalizations.of(c);
    final v = _num(spec['value']);
    final lo = _num(spec['min']) ?? 0, hi = _num(spec['max']) ?? 100;
    if (v == null || hi <= lo) {
      return StatusCard(
        title.isEmpty ? (l?.coachFiguresGauge ?? 'Gauge') : title,
        l?.coachFiguresGaugeNoValue ?? 'The coach sent a gauge with no value.',
        icon: LucideIcons.gauge,
      );
    }
    final frac = ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    final label = _str(spec['label']);
    return Surface(
      child: Row(
        children: [
          SizedBox(
            width: 84,
            height: 84,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size.square(84),
                  painter: Ring(frac, p.on(C.blue), p.track, stroke: 8),
                ),
                Text(
                  v == v.roundToDouble()
                      ? v.round().toString()
                      : v.toStringAsFixed(1),
                  style: F.n24.copyWith(color: p.ink),
                ),
              ],
            ),
          ),
          const SizedBox(width: S.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isEmpty
                      ? (label.isEmpty ? (l?.coachFiguresGauge ?? 'Gauge') : label)
                      : title,
                  style: F.head.copyWith(color: p.ink),
                ),
                const SizedBox(height: S.x1),
                Text(
                  '${lo.round()}–${hi.round()}'
                  '${unit.isEmpty ? '' : ' $unit'}',
                  style: F.cap.copyWith(color: p.ink3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── KPI grid ───────────────────────────────────────────────────────────────
  //
  // Real `SignalCard`s — card job A, the one the app uses for a glanceable
  // number. No sparkline: `SignalCard` has no slot for one, and a second
  // number-and-a-picture card invented here would be a card job nobody else
  // spends.
  Widget _kpis(BuildContext c, P p, String title) {
    final l = AppLocalizations.of(c);
    final cards = _list(spec['cards']).whereType<Map>().toList();
    if (cards.isEmpty) {
      return StatusCard(
        title.isEmpty ? (l?.coachFiguresSummary ?? 'Summary') : title,
        l?.coachFiguresEmptySummary ?? 'The coach sent an empty summary.',
        icon: LucideIcons.layoutGrid,
      );
    }
    final inks = [C.blue, C.orange, C.teal, C.purple, C.green];
    final grid = LayoutBuilder(
      builder: (_, box) {
        final w = (box.maxWidth - S.x3) / 2;
        return Wrap(
          spacing: S.x3,
          runSpacing: S.x3,
          children: [
            for (var i = 0; i < cards.length; i++)
              SizedBox(
                width: cards.length == 1 ? box.maxWidth : w,
                child: SignalCard(
                  LucideIcons.activity,
                  inks[i % inks.length],
                  _str(cards[i]['label']),
                  _str(cards[i]['value']),
                  unit: _str(cards[i]['unit']),
                  sub: _str(cards[i]['baseline'] ?? cards[i]['sub']),
                ),
              ),
          ],
        );
      },
    );
    if (title.isEmpty) return grid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: F.head.copyWith(color: p.ink)),
        const SizedBox(height: S.x3),
        grid,
      ],
    );
  }

  // ── heatmap ────────────────────────────────────────────────────────────────
  //
  // The app's heatmap is a CALENDAR: weeks across, Mon→Sun down. That shape is
  // what the painter draws and what the prompt asks for.
  Widget _heatmap(BuildContext c, P p, String title, String unit) {
    final weeks = [
      for (final r in _list(spec['weeks'] ?? spec['values']))
        [for (final v in _list(r)) _num(v)],
    ];
    if (weeks.isEmpty || weeks.every((w) => w.every((v) => v == null))) {
      return _frame(c, title, unit, const SizedBox.shrink(), empty: const NoData());
    }
    return _frame(
      c,
      title,
      unit,
      CustomPaint(
        size: Size.infinite,
        painter: HeatMap(weeks, p.on(C.blue), p.track),
      ),
      height: 110,
      xLabels: _xLabels(spec['x_labels'] ?? spec['labels']),
      series: [for (final w in weeks) ...w],
    );
  }

  // ── table ──────────────────────────────────────────────────────────────────
  Widget _table(BuildContext c, P p, String title) {
    final l = AppLocalizations.of(c);
    final cols = [for (final e in _list(spec['columns'])) _str(e)];
    final rows = [
      for (final r in _list(spec['rows'])) [for (final e in _list(r)) _str(e)],
    ];
    if (rows.isEmpty) {
      return StatusCard(
        title.isEmpty ? (l?.coachFiguresTable ?? 'Table') : title,
        l?.coachFiguresTableNoRows ?? 'The coach sent a table with no rows.',
        icon: LucideIcons.table,
      );
    }
    final n = rows.fold<int>(cols.length, (a, r) => r.length > a ? r.length : a);
    Widget cell(String s, TextStyle st) => Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2, horizontal: S.x2),
      child: Text(s, style: st),
    );
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Text(title, style: F.head.copyWith(color: p.ink)),
            const SizedBox(height: S.x2),
          ],
          // A wide table scrolls inside itself rather than overflowing the
          // page; a narrow one still fills the card. The width comes from the
          // LAYOUT, not from the screen — `MediaQuery.size` minus a padding
          // constant goes negative in any frame narrower than the padding, and
          // a negative minWidth is an assertion, not a squeeze.
          LayoutBuilder(
            builder: (_, box) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: box.maxWidth),
                child: Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                border: TableBorder(horizontalInside: BorderSide(color: p.line)),
                children: [
                  if (cols.isNotEmpty)
                    TableRow(
                      children: [
                        for (var i = 0; i < n; i++)
                          cell(
                            i < cols.length ? cols[i] : '',
                            F.over.copyWith(color: p.ink3),
                          ),
                      ],
                    ),
                  for (final r in rows)
                    TableRow(
                      children: [
                        for (var i = 0; i < n; i++)
                          cell(
                            i < r.length ? r[i] : '',
                            F.cap.copyWith(color: p.ink),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
