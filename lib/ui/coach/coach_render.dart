// CoachRender — renders the AI coach's rich `render(spec)` figures natively.
//
// The model emits a typed spec map ({type, title?, ...payload}); this widget
// switches on `type` and draws an animated, theme-consistent figure. Tolerant of
// missing/loose fields (LLM output): every parser fails soft to an empty figure
// rather than throwing. Simple bar/line/area/multi_series reuse the existing
// CoachChart via a synthesized ChartSpec; the rest are self-contained painters.

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../coach/coach_engine.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import 'coach_chart.dart';

// ── loose parsing helpers (LLM output is liberal) ─────────────────────────────
List<dynamic> _list(dynamic v) {
  if (v is List) return v;
  if (v is Map && v['item'] is List) return v['item'] as List;
  if (v is Map && v['items'] is List) return v['items'] as List;
  return const [];
}

double? _num(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) {
    final d = double.tryParse(v.trim());
    if (d != null) return d;
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v);
    return m == null ? null : double.tryParse(m.group(0)!);
  }
  if (v is Map) return _num(v['value'] ?? v['y'] ?? v['v']);
  return null;
}

String _str(dynamic v) => v == null ? '' : v.toString();

final List<Color> _palette = [
  AppColors.coral,
  AppColors.good,
  AppColors.loadDetraining,
  AppColors.warn,
  AppColors.coralDeep,
];

/// Sleep-stage colors for the hypnogram band.
Color _stageColor(String stage) {
  switch (stage.toLowerCase()) {
    case 'deep':
      return AppColors.coralDeep;
    case 'rem':
      return AppColors.good;
    case 'light':
      return AppColors.coral;
    case 'wake':
    default:
      return AppColors.warn;
  }
}

class CoachRender extends StatelessWidget {
  final Map<String, dynamic> spec;
  const CoachRender({super.key, required this.spec});

  @override
  Widget build(BuildContext context) {
    final type = _str(spec['type']).toLowerCase();
    // Simple chart families reuse CoachChart via a synthesized ChartSpec.
    if (type == 'line' || type == 'area' || type == 'bar' || type == 'multi_series') {
      final cs = _chartSpecFrom(spec, type);
      if (cs != null) return CoachChart(spec: cs);
    }
    final title = _str(spec['title']);
    Widget body;
    switch (type) {
      case 'scatter':
        body = _Animated((t) => _ScatterPainter(spec, t), height: 200);
        break;
      case 'dual_axis':
        body = _Animated((t) => _DualAxisPainter(spec, t), height: 190);
        break;
      case 'stacked_zone_bar':
        body = _Animated((t) => _StackedBarPainter(spec, t), height: 190);
        break;
      case 'hypnogram':
        body = _Animated((t) => _HypnogramPainter(spec, t), height: 120);
        break;
      case 'gauge':
        body = _Animated((t) => _GaugePainter(spec, t), height: 170);
        break;
      case 'range_band':
        body = _RangeBand(spec);
        break;
      case 'kpi_grid':
        body = _KpiGrid(spec);
        break;
      case 'heatmap':
        body = _Heatmap(spec);
        break;
      case 'table':
        body = _MiniTable(spec);
        break;
      default:
        body = Text('Unsupported figure "$type".', style: AppText.captionMuted);
    }
    final note = _str(spec['note']);
    final legend = _legend(type);
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title.isNotEmpty) Text(title, style: AppText.title),
        if (title.isNotEmpty) const SizedBox(height: Sp.x4),
        body,
        if (legend != null) ...[const SizedBox(height: Sp.x3), legend],
        if (note.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          Text(note, style: AppText.captionMuted),
        ],
      ]),
    );
  }

  Widget? _legend(String type) {
    if (type == 'hypnogram') {
      return Wrap(spacing: Sp.x4, runSpacing: Sp.x2, children: [
        for (final s in const ['wake', 'rem', 'light', 'deep'])
          _dot(_stageColor(s), s),
      ]);
    }
    if (type == 'dual_axis') {
      final l = (spec['left'] as Map?)?.cast<String, dynamic>();
      final r = (spec['right'] as Map?)?.cast<String, dynamic>();
      return Wrap(spacing: Sp.x4, children: [
        _dot(_palette[0], _str(l?['name'] ?? 'left')),
        _dot(_palette[1], _str(r?['name'] ?? 'right')),
      ]);
    }
    if (type == 'stacked_zone_bar') {
      final zones = _list(spec['zones']);
      return Wrap(spacing: Sp.x4, runSpacing: Sp.x2, children: [
        for (int i = 0; i < zones.length; i++)
          _dot(_palette[i % _palette.length],
              _str((zones[i] as Map?)?['name'] ?? 'z$i')),
      ]);
    }
    return null;
  }

  Widget _dot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: Sp.x2),
        Text(label, style: AppText.caption),
      ]);

  ChartSpec? _chartSpecFrom(Map<String, dynamic> s, String type) {
    final j = <String, dynamic>{
      'type': type == 'multi_series' ? (_str(s['chart_type']).isEmpty ? 'line' : s['chart_type']) : type,
      'title': '', // title rendered by the outer card path below
      'x_labels': s['x_labels'] ?? s['labels'] ?? s['x'],
      'series': s['series'],
      'unit': s['unit'] ?? '',
      'note': s['note'],
    };
    final cs = ChartSpec.tryParse(j);
    if (cs == null) return null;
    // Carry the title onto the ChartSpec so CoachChart shows it.
    return ChartSpec(
      type: cs.type,
      title: _str(s['title']),
      xLabels: cs.xLabels,
      series: cs.series,
      unit: cs.unit,
      note: cs.note,
    );
  }
}

// ── animation wrapper ─────────────────────────────────────────────────────────
class _Animated extends StatelessWidget {
  final CustomPainter Function(double t) make;
  final double height;
  const _Animated(this.make, {required this.height});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        tween: Tween(begin: 0, end: 1),
        builder: (_, t, _) => SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: make(t)),
        ),
      );
}

// ── scatter ───────────────────────────────────────────────────────────────────
class _ScatterPainter extends CustomPainter {
  final Map<String, dynamic> spec;
  final double t;
  _ScatterPainter(this.spec, this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final pts = _list(spec['points'])
        .whereType<Map>()
        .map((m) => Offset(_num(m['x']) ?? 0, _num(m['y']) ?? 0))
        .toList();
    if (pts.isEmpty) return;
    final xs = pts.map((p) => p.dx).toList(), ys = pts.map((p) => p.dy).toList();
    var xlo = xs.reduce(math.min), xhi = xs.reduce(math.max);
    var ylo = ys.reduce(math.min), yhi = ys.reduce(math.max);
    if (xlo == xhi) { xlo -= 1; xhi += 1; }
    if (ylo == yhi) { ylo -= 1; yhi += 1; }
    const pad = 22.0;
    final w = size.width - pad, h = size.height - pad;
    final grid = Paint()..color = AppColors.divider..strokeWidth = 1;
    for (var g = 0; g <= 2; g++) {
      final y = h * g / 2;
      canvas.drawLine(Offset(pad, y), Offset(size.width, y), grid);
    }
    final dot = Paint()..color = AppColors.coral..style = PaintingStyle.fill;
    for (final p in pts) {
      final dx = pad + w * (p.dx - xlo) / (xhi - xlo);
      final dy = h * (1 - (p.dy - ylo) / (yhi - ylo));
      canvas.drawCircle(Offset(dx, dy), 4 * t, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _ScatterPainter o) => o.t != t || o.spec != spec;
}

// ── dual axis (two y-scales) ──────────────────────────────────────────────────
class _DualAxisPainter extends CustomPainter {
  final Map<String, dynamic> spec;
  final double t;
  _DualAxisPainter(this.spec, this.t);
  List<double?> _vals(Map? m) => _list(m?['values']).map(_num).toList();
  @override
  void paint(Canvas canvas, Size size) {
    final left = (spec['left'] as Map?), right = (spec['right'] as Map?);
    final lv = _vals(left), rv = _vals(right);
    final n = math.max(lv.length, rv.length);
    if (n < 1) return;
    const pad = 16.0;
    final w = size.width, h = size.height - pad;
    double xAt(int i) => n == 1 ? w / 2 : w * i / (n - 1);
    void drawSeries(List<double?> vals, Color c) {
      final present = vals.whereType<double>().toList();
      if (present.isEmpty) return;
      var lo = present.reduce(math.min), hi = present.reduce(math.max);
      if (lo == hi) { lo -= 1; hi += 1; }
      final path = Path();
      final pts = <Offset>[];
      var started = false;
      for (var i = 0; i < vals.length; i++) {
        final v = vals[i];
        if (v == null) continue;
        final pt = Offset(xAt(i), h * (1 - (v - lo) / (hi - lo)));
        pts.add(pt);
        if (!started) { path.moveTo(pt.dx, pt.dy); started = true; }
        else { path.lineTo(pt.dx, pt.dy); }
      }
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, size.width * t, size.height));
      if (pts.length > 1) {
        canvas.drawPath(path, Paint()
          ..color = c..strokeWidth = 2.5..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round..strokeCap = StrokeCap.round);
      }
      final dot = Paint()..color = c;
      for (final p in pts) {
        canvas.drawCircle(p, pts.length == 1 ? 5 : 3, dot);
      }
      canvas.restore();
    }
    final grid = Paint()..color = AppColors.divider..strokeWidth = 1;
    for (var g = 0; g <= 2; g++) {
      final y = h * g / 2;
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }
    drawSeries(lv, _palette[0]);
    drawSeries(rv, _palette[1]);
  }

  @override
  bool shouldRepaint(covariant _DualAxisPainter o) => o.t != t || o.spec != spec;
}

// ── stacked zone bars ─────────────────────────────────────────────────────────
class _StackedBarPainter extends CustomPainter {
  final Map<String, dynamic> spec;
  final double t;
  _StackedBarPainter(this.spec, this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final zones = _list(spec['zones']).whereType<Map>().toList();
    if (zones.isEmpty) return;
    final cols = zones
        .map((z) => _list(z['values']).map((v) => _num(v) ?? 0).toList())
        .toList();
    final n = cols.fold<int>(0, (a, c) => math.max(a, c.length));
    if (n < 1) return;
    final totals = List<double>.filled(n, 0);
    for (final c in cols) {
      for (var i = 0; i < c.length; i++) {
        totals[i] += c[i];
      }
    }
    final maxTotal = totals.reduce(math.max);
    if (maxTotal <= 0) return;
    const bottom = 16.0;
    final h = size.height - bottom;
    final bw = size.width / n * 0.6;
    final gap = size.width / n;
    for (var i = 0; i < n; i++) {
      var y = h;
      final x = gap * i + (gap - bw) / 2;
      for (var zi = 0; zi < cols.length; zi++) {
        final v = i < cols[zi].length ? cols[zi][i] : 0.0;
        final segH = h * (v / maxTotal) * t;
        final rect = Rect.fromLTWH(x, y - segH, bw, segH);
        canvas.drawRect(rect, Paint()..color = _palette[zi % _palette.length]);
        y -= segH;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StackedBarPainter o) => o.t != t || o.spec != spec;
}

// ── hypnogram (sleep stage band) ──────────────────────────────────────────────
class _HypnogramPainter extends CustomPainter {
  final Map<String, dynamic> spec;
  final double t;
  _HypnogramPainter(this.spec, this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final segs = _list(spec['segments']).whereType<Map>().toList();
    if (segs.isEmpty) return;
    final starts = segs.map((s) => _num(s['start']) ?? 0).toList();
    final ends = segs.map((s) => _num(s['end']) ?? 0).toList();
    final lo = starts.reduce(math.min), hi = ends.reduce(math.max);
    if (hi <= lo) return;
    // Stage lanes (top→bottom): wake, rem, light, deep.
    const lanes = ['wake', 'rem', 'light', 'deep'];
    final laneH = size.height / lanes.length;
    final clipW = size.width * t;
    for (final s in segs) {
      final stage = _str(s['stage']).toLowerCase();
      final li = lanes.indexOf(stage);
      final lane = li < 0 ? lanes.length - 1 : li;
      final x0 = size.width * ((_num(s['start']) ?? 0) - lo) / (hi - lo);
      final x1 = size.width * ((_num(s['end']) ?? 0) - lo) / (hi - lo);
      if (x0 > clipW) continue;
      final rect = Rect.fromLTWH(x0, lane * laneH + 2,
          math.min(x1, clipW) - x0, laneH - 4);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          Paint()..color = _stageColor(stage));
    }
  }

  @override
  bool shouldRepaint(covariant _HypnogramPainter o) => o.t != t || o.spec != spec;
}

// ── gauge (0–100 ring) ────────────────────────────────────────────────────────
class _GaugePainter extends CustomPainter {
  final Map<String, dynamic> spec;
  final double t;
  _GaugePainter(this.spec, this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final value = _num(spec['value']) ?? 0;
    final min = _num(spec['min']) ?? 0, max = _num(spec['max']) ?? 100;
    final frac = ((value - min) / (max - min)).clamp(0.0, 1.0) * t;
    final center = Offset(size.width / 2, size.height * 0.62);
    final radius = math.min(size.width, size.height) * 0.42;
    final track = Paint()
      ..color = AppColors.divider..style = PaintingStyle.stroke..strokeWidth = 12
      ..strokeCap = StrokeCap.round;
    final arc = Paint()
      ..color = AppColors.coral..style = PaintingStyle.stroke..strokeWidth = 12
      ..strokeCap = StrokeCap.round;
    const start = math.pi * 0.8, sweep = math.pi * 1.4;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep, false, track);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep * frac, false, arc);
    final tp = TextPainter(
      text: TextSpan(text: value.round().toString(), style: AppText.display),
      textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _GaugePainter o) => o.t != t || o.spec != spec;
}

// ── range band (value vs target band) ─────────────────────────────────────────
class _RangeBand extends StatelessWidget {
  final Map<String, dynamic> spec;
  const _RangeBand(this.spec);
  @override
  Widget build(BuildContext context) {
    final value = _num(spec['value']) ?? 0;
    final min = _num(spec['min']) ?? 0, max = _num(spec['max']) ?? 100;
    final unit = _str(spec['unit']);
    final lo = math.min(min, value) - (max - min).abs() * 0.2;
    final hi = math.max(max, value) + (max - min).abs() * 0.2;
    final span = (hi - lo) == 0 ? 1 : (hi - lo);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${value.toStringAsFixed(value % 1 == 0 ? 0 : 1)}$unit',
          style: AppText.title.copyWith(color: AppColors.coral)),
      const SizedBox(height: Sp.x2),
      LayoutBuilder(builder: (_, c) {
        final w = c.maxWidth;
        double at(double v) => w * ((v - lo) / span);
        return SizedBox(height: 22, child: Stack(children: [
          Positioned(top: 9, left: 0, right: 0,
              child: Container(height: 4, color: AppColors.divider)),
          Positioned(top: 7, left: at(min), width: at(max) - at(min),
              child: Container(height: 8,
                  decoration: BoxDecoration(color: AppColors.good.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4)))),
          Positioned(left: (at(value) - 6).clamp(0, w - 12), top: 4,
              child: Container(width: 12, height: 12,
                  decoration: BoxDecoration(color: AppColors.coral, shape: BoxShape.circle))),
        ]));
      }),
      const SizedBox(height: Sp.x2),
      Text('target ${min.toStringAsFixed(0)}–${max.toStringAsFixed(0)}$unit',
          style: AppText.captionMuted),
    ]);
  }
}

// ── KPI grid ──────────────────────────────────────────────────────────────────
class _KpiGrid extends StatelessWidget {
  final Map<String, dynamic> spec;
  const _KpiGrid(this.spec);
  @override
  Widget build(BuildContext context) {
    final cards = _list(spec['cards']).whereType<Map>().toList();
    if (cards.isEmpty) return Text('No data.', style: AppText.captionMuted);
    return Wrap(spacing: Sp.x3, runSpacing: Sp.x3, children: [
      for (final c in cards) _kpi(c.cast<String, dynamic>()),
    ]);
  }

  Widget _kpi(Map<String, dynamic> c) {
    final delta = _num(c['delta']);
    final spark = _list(c['spark']).map(_num).whereType<double>().toList();
    return Container(
      width: 150,
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
          color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(R.card)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_str(c['label']), style: AppText.captionMuted),
        const SizedBox(height: 2),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic, children: [
          Text(_str(c['value']), style: AppText.title),
          if (_str(c['unit']).isNotEmpty) ...[
            const SizedBox(width: 3),
            Text(_str(c['unit']), style: AppText.captionMuted),
          ],
        ]),
        if (delta != null) Text(
            '${delta >= 0 ? '▲' : '▼'} ${delta.abs().toStringAsFixed(delta % 1 == 0 ? 0 : 1)}',
            style: AppText.caption.copyWith(
                color: delta >= 0 ? AppColors.good : AppColors.warn)),
        if (spark.length > 1) ...[
          const SizedBox(height: Sp.x2),
          SizedBox(height: 24, width: double.infinity,
              child: CustomPaint(painter: _SparkPainter(spark))),
        ],
      ]),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> vals;
  _SparkPainter(this.vals);
  @override
  void paint(Canvas canvas, Size size) {
    if (vals.length < 2) return;
    var lo = vals.reduce(math.min), hi = vals.reduce(math.max);
    if (lo == hi) { lo -= 1; hi += 1; }
    final path = Path();
    for (var i = 0; i < vals.length; i++) {
      final x = size.width * i / (vals.length - 1);
      final y = size.height * (1 - (vals[i] - lo) / (hi - lo));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, Paint()
      ..color = AppColors.coral..strokeWidth = 1.8..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter o) => o.vals != vals;
}

// ── heatmap ───────────────────────────────────────────────────────────────────
class _Heatmap extends StatelessWidget {
  final Map<String, dynamic> spec;
  const _Heatmap(this.spec);
  @override
  Widget build(BuildContext context) {
    final rows = _list(spec['rows']).map(_str).toList();
    final cols = _list(spec['cols']).map(_str).toList();
    final values = _list(spec['values'])
        .map((r) => _list(r).map((v) => _num(v) ?? 0).toList())
        .toList();
    if (values.isEmpty) return Text('No data.', style: AppText.captionMuted);
    final flat = [for (final r in values) ...r];
    var lo = flat.reduce(math.min), hi = flat.reduce(math.max);
    if (lo == hi) hi = lo + 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var ri = 0; ri < values.length; ri++)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(children: [
            if (rows.isNotEmpty)
              SizedBox(width: 34, child: Text(ri < rows.length ? rows[ri] : '',
                  style: AppText.captionMuted)),
            for (var ci = 0; ci < values[ri].length; ci++)
              Expanded(child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: AspectRatio(aspectRatio: 1, child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.coral.withValues(
                        alpha: 0.12 + 0.78 * ((values[ri][ci] - lo) / (hi - lo))),
                    borderRadius: BorderRadius.circular(3),
                  ),
                )),
              )),
          ]),
        ),
      if (cols.isNotEmpty) ...[
        const SizedBox(height: 2),
        Row(children: [
          if (rows.isNotEmpty) const SizedBox(width: 34),
          for (final c in cols)
            Expanded(child: Text(c, textAlign: TextAlign.center, style: AppText.captionMuted)),
        ]),
      ],
    ]);
  }
}

// ── mini table ────────────────────────────────────────────────────────────────
class _MiniTable extends StatelessWidget {
  final Map<String, dynamic> spec;
  const _MiniTable(this.spec);
  @override
  Widget build(BuildContext context) {
    final cols = _list(spec['columns']).map(_str).toList();
    final rows = _list(spec['rows']).map((r) => _list(r).map(_str).toList()).toList();
    if (rows.isEmpty) return Text('No data.', style: AppText.captionMuted);
    return Table(
      border: TableBorder(horizontalInside: BorderSide(color: AppColors.divider)),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        if (cols.isNotEmpty)
          TableRow(children: [
            for (final c in cols)
              Padding(padding: const EdgeInsets.all(Sp.x2),
                  child: Text(c, style: AppText.caption)),
          ]),
        for (final r in rows)
          TableRow(children: [
            for (final cell in r)
              Padding(padding: const EdgeInsets.all(Sp.x2),
                  child: Text(cell, style: AppText.body)),
          ]),
      ],
    );
  }
}
