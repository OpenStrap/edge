// Your Timeline — every vital on ONE merged, normalized chart, on the bento
// design language: vital selector chips, the merged plot in a bento tile,
// peak/low BigStats for the active vital, and a clean event list.
//
// All vital curves share a single plot block on one time axis. Each is
// normalized to its own range so they coexist; the left Y-axis shows the ACTIVE
// vital's real units (tap a legend chip to switch — bpm → ms → br/min → rel).
// Colours are strong, mutually-opposite and match each signal's nature:
//   • Heart rate  → deep RED    (blood / pulse)
//   • HRV         → deep GREEN  (recovery / parasympathetic)
//   • Resp rate   → deep BLUE   (breath / air)
//   • Skin temp   → deep ORANGE (heat)
// Activity bands (sleep / nap / workout) are semi-transparent vertical spans
// with a glyph on top. The active vital's peak/low are annotated (↑/↓ value
// @time); scrubbing draws a crosshair with every vital's value.
//
// HONESTY: only continuously-recorded vitals are drawn — HR, HRV, resp (rolling
// RSA) and a RELATIVE skin-temp trend (no absolute °C). HRV/resp are movement-
// confounded by day (explained behind the (i)).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

// Strong, opposite, nature-matched vital colours (deliberately NOT the light
// theme accents — these must stay distinguishable when overlaid).
const Color _kHr = Color(0xFFD32F2F); // deep red — blood / pulse
const Color _kHrv = Color(0xFF2E7D32); // deep green — recovery
const Color _kResp = Color(0xFF1565C0); // deep blue — breath
const Color _kTemp = Color(0xFFE65100); // deep orange — heat

class _Vital {
  final String label;
  final String unit;
  final Color color;
  final List<({double t, double v})> pts; // raw (peaks + crosshair)
  // Per-bucket mean (v) + min/max (lo/hi) → the line + its range envelope.
  final List<({double t, double v, double lo, double hi})> avg;
  final int decimals;
  const _Vital(
    this.label,
    this.unit,
    this.color,
    this.pts,
    this.decimals,
    this.avg,
  );
  double? valueAt(double t) {
    double? best;
    var bestDt = double.infinity;
    for (final p in pts) {
      final dt = (p.t - t).abs();
      if (dt < bestDt) {
        bestDt = dt;
        best = p.v;
      }
    }
    return best;
  }
}

class _Band {
  final String label;
  final Color color;
  final double start;
  final double end;
  final IconData icon;
  const _Band(this.label, this.color, this.start, this.end, this.icon);
}

class TimelineScreen extends StatefulWidget {
  final String date;
  const TimelineScreen({super.key, required this.date});
  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

enum _Phase { loading, ready, empty, error }

class _TimelineScreenState extends State<TimelineScreen> {
  _Phase _phase = _Phase.loading;
  Map<String, dynamic> _data = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _phase = _Phase.loading);
    try {
      final LocalRepository? repo = context.read<AppState>().repo;
      final d = await repo?.getDayTimeline(widget.date);
      if (!mounted) return;
      setState(() {
        _data = d ?? const {};
        _phase = TimelineContent.hasVitals(_data)
            ? _Phase.ready
            : _Phase.empty;
      });
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Your timeline',
      subtitle: 'Every vital, one day',
      children: [
        if (_phase == _Phase.loading) ...[
          Skeleton.tileRow(rows: 1),
          const SizedBox(height: Sp.x4),
          Skeleton.chart(height: 280),
        ] else if (_phase == _Phase.empty)
          StateCard(
            icon: Ic.pulse,
            title: 'No timeline yet',
            message:
                'Wear the strap through the day and your merged vitals '
                'timeline will appear here.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else if (_phase == _Phase.error)
          StateCard(
            icon: Ic.cloud,
            title: "Couldn't load your timeline",
            message: 'Please try again.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else
          TimelineContent(data: _data),
      ],
    );
  }
}

/// Pure presentation for the merged-vitals board (render-testable without a
/// repo): selector chips, the merged normalized chart, peak/low BigStats for
/// the active vital, and the day's event list.
class TimelineContent extends StatefulWidget {
  final Map<String, dynamic> data;
  const TimelineContent({super.key, required this.data});

  /// True when at least one continuously-recorded vital has points.
  static bool hasVitals(Map<String, dynamic> d) =>
      _parseSeries(d['hr']).isNotEmpty ||
      _parseSeries(d['hrv']).isNotEmpty ||
      _parseSeries(d['resp']).isNotEmpty ||
      _parseSeries(d['skin_temp'], allowNonPositive: true).isNotEmpty;

  static List<({double t, double v})> _parseSeries(
    Object? raw, {
    bool allowNonPositive = false,
  }) {
    final out = <({double t, double v})>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final t = (e['t'] as num?)?.toDouble();
        final v = (e['v'] as num?)?.toDouble();
        if (t != null && v != null && (allowNonPositive || v > 0)) {
          out.add((t: t, v: v));
        }
      }
    }
    out.sort((a, b) => a.t.compareTo(b.t));
    return out;
  }

  @override
  State<TimelineContent> createState() => _TimelineContentState();
}

class _TimelineContentState extends State<TimelineContent>
    with SingleTickerProviderStateMixin {
  int _active = 0;
  double? _scrubT;
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  List<_Vital> _vitals = const [];
  List<_Band> _bands = const [];
  double _t0 = 0, _t1 = 0;

  static const double _leftPad = 36;

  @override
  void initState() {
    super.initState();
    _build(widget.data);
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// Bucket a series into fixed windows (default 15 min): mean (the line) plus
  /// min/max (the range envelope) per bucket — so the smoothed line stays clean
  /// while the band still reaches the true peak/low. Raw series kept separately.
  List<({double t, double v, double lo, double hi})> _bucketAvg(
    List<({double t, double v})> pts, [
    double bucketSec = 900,
  ]) {
    final byBucket = <int, List<double>>{};
    for (final p in pts) {
      (byBucket[(p.t / bucketSec).floor()] ??= []).add(p.v);
    }
    final keys = byBucket.keys.toList()..sort();
    final out = <({double t, double v, double lo, double hi})>[];
    for (final k in keys) {
      final vs = byBucket[k]!;
      var s = 0.0, lo = vs.first, hi = vs.first;
      for (final x in vs) {
        s += x;
        if (x < lo) lo = x;
        if (x > hi) hi = x;
      }
      out.add((t: (k + 0.5) * bucketSec, v: s / vs.length, lo: lo, hi: hi));
    }
    return out;
  }

  static IconData _sportIcon(String type) {
    if (type.contains('run') || type.contains('walk')) return Ic.run;
    if (type.contains('cycl') ||
        type.contains('bike') ||
        type.contains('ride')) {
      return Ic.activity;
    }
    return Ic.strain;
  }

  void _build(Map<String, dynamic> d) {
    final hr = TimelineContent._parseSeries(d['hr']);
    final hrv = TimelineContent._parseSeries(d['hrv']);
    final resp = TimelineContent._parseSeries(d['resp']);
    final temp = TimelineContent._parseSeries(
      d['skin_temp'],
      allowNonPositive: true,
    );
    // Average into ~15-min buckets → clean curves instead of per-minute jitter.
    _vitals = [
      if (hr.isNotEmpty)
        _Vital('Heart rate', 'bpm', _kHr, hr, 0, _bucketAvg(hr)),
      if (hrv.isNotEmpty) _Vital('HRV', 'ms', _kHrv, hrv, 0, _bucketAvg(hrv)),
      if (resp.isNotEmpty)
        _Vital('Resp', 'br/min', _kResp, resp, 0, _bucketAvg(resp)),
      if (temp.isNotEmpty)
        _Vital('Skin temp', 'rel', _kTemp, temp, 1, _bucketAvg(temp)),
    ];

    final bands = <_Band>[];
    for (final s in (d['sleep'] as List?) ?? const []) {
      if (s is Map) {
        final on = (s['onset_ts'] as num?)?.toDouble();
        final off = (s['wake_ts'] as num?)?.toDouble();
        if (on != null && off != null) {
          bands.add(_Band('Sleep', DomainAccent.sleep, on, off, Ic.moon));
        }
      }
    }
    for (final n in (d['naps'] as List?) ?? const []) {
      if (n is Map) {
        final st = (n['start'] as num?)?.toDouble();
        final en = (n['end'] as num?)?.toDouble();
        if (st != null && en != null) {
          bands.add(_Band('Nap', AppColors.cool, st, en, Ic.moon));
        }
      }
    }
    for (final w in (d['sessions'] as List?) ?? const []) {
      if (w is Map) {
        final st = ((w['start'] ?? w['start_ts']) as num?)?.toDouble();
        final en = ((w['end'] ?? w['end_ts']) as num?)?.toDouble();
        if (st != null && en != null) {
          final type = (w['sport'] ?? w['type'] ?? w['detected_type'] ?? '')
              .toString()
              .toLowerCase();
          final label = type.isEmpty
              ? 'Workout'
              : type[0].toUpperCase() + type.substring(1).replaceAll('_', ' ');
          bands.add(
            _Band(label, DomainAccent.strain, st, en, _sportIcon(type)),
          );
        }
      }
    }
    _bands = bands;

    var lo = double.infinity, hi = -double.infinity;
    for (final v in _vitals) {
      for (final p in v.pts) {
        if (p.t < lo) lo = p.t;
        if (p.t > hi) hi = p.t;
      }
    }
    for (final b in _bands) {
      if (b.start < lo) lo = b.start;
      if (b.end > hi) hi = b.end;
    }
    if (lo.isFinite && hi > lo) {
      _t0 = lo;
      _t1 = hi;
    }
  }

  static String _clock(double epochSec) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec.round() * 1000);
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_vitals.isEmpty || _t1 <= _t0) {
      return const StateCard(
        icon: Ic.pulse,
        title: 'No timeline yet',
        message:
            'Wear the strap through the day and your merged vitals timeline '
            'will appear here.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: dsStaggered([
        // Legend / selector chips (the strong vital colours).
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [for (var i = 0; i < _vitals.length; i++) _chip(i)],
        ),
        const SizedBox(height: Sp.x3),
        _chartTile(),
        const SizedBox(height: Sp.x3),
        _peakLowBento(),
        ..._eventsSection(),
      ]),
    );
  }

  // ── vital selector chips ────────────────────────────────────────────────

  Widget _chip(int i) {
    final v = _vitals[i];
    final on = i == _active;
    return Pressable(
      pressedScale: 0.94,
      onTap: () => setState(() => _active = i),
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x3 + 2,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: on
              ? v.color.withValues(alpha: AppColors.isDark ? 0.24 : 0.14)
              : Elevation.surfaceAt(1),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
            color: on ? v.color.withValues(alpha: 0.6) : AppColors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: v.color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              v.label,
              style: AppText.caption.copyWith(
                color: on ? v.color : AppColors.inkSoft,
                fontWeight: on ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── the merged chart tile ───────────────────────────────────────────────

  Widget _chartTile() {
    final active = _vitals[_active];
    return BentoTile(
      padding: const EdgeInsets.fromLTRB(Sp.x2, Sp.x4, Sp.x3, Sp.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: Sp.x2),
            child: TileHeader(
              '${active.label} · ${active.unit}',
              trailing: const InfoDot(
                title: 'Every vital, one chart',
                body:
                    'All vitals are drawn together on one time axis, each '
                    'normalized to its own range. The axis shows the selected '
                    'vital in its real units — tap a chip to switch. Scrub '
                    'the chart to read every vital at a moment.',
                methodNote:
                    'Only continuously-recorded vitals are shown. Daytime HRV '
                    'and respiration are movement-confounded; skin temp is a '
                    'relative trend, not °C.',
              ),
            ),
          ),
          const SizedBox(height: Sp.x3),
          LayoutBuilder(
            builder: (ctx, c) {
              final w = c.maxWidth;
              return GestureDetector(
                onHorizontalDragStart: (e) => _scrub(e.localPosition.dx, w),
                onHorizontalDragUpdate: (e) => _scrub(e.localPosition.dx, w),
                onHorizontalDragEnd: (_) => setState(() => _scrubT = null),
                onTapDown: (e) => _scrub(e.localPosition.dx, w),
                onTapUp: (_) => setState(() => _scrubT = null),
                child: SizedBox(
                  height: 280,
                  width: w,
                  child: AnimatedBuilder(
                    animation: _anim,
                    builder: (_, _) => CustomPaint(
                      size: Size(w, 280),
                      painter: _ChartPainter(
                        vitals: _vitals,
                        bands: _bands,
                        active: _active,
                        t0: _t0,
                        t1: _t1,
                        progress: _anim.value,
                        scrubT: _scrubT,
                        leftPad: _leftPad,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (_scrubT != null) ...[
            const SizedBox(height: Sp.x3),
            _crosshairReadout(),
          ],
        ],
      ),
    );
  }

  Widget _crosshairReadout() {
    final t = _scrubT!;
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(R.chip),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_clock(t), style: AppText.label),
          const SizedBox(height: Sp.x2),
          for (final v in _vitals)
            Builder(
              builder: (_) {
                final val = v.valueAt(t);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: v.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: Sp.x2),
                      Expanded(
                        child: Text(v.label, style: AppText.captionMuted),
                      ),
                      Text(
                        val == null
                            ? '—'
                            : '${val.toStringAsFixed(v.decimals)} ${v.unit}',
                        style: AppText.caption.copyWith(color: v.color),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  void _scrub(double dx, double width) {
    final x = (dx - _leftPad).clamp(0.0, width - _leftPad);
    final frac = (width - _leftPad) <= 0 ? 0.0 : x / (width - _leftPad);
    setState(() => _scrubT = _t0 + frac * (_t1 - _t0));
  }

  // ── peak / low of the ACTIVE vital, numbers-first ───────────────────────

  Widget _peakLowBento() {
    final act = _vitals[_active];
    if (act.pts.isEmpty) return const SizedBox.shrink();
    var pk = act.pts.first, lw = act.pts.first;
    for (final p in act.pts) {
      if (p.v > pk.v) pk = p;
      if (p.v < lw.v) lw = p;
    }
    Widget tile(String label, ({double t, double v}) p) => BentoTile(
      tone: BentoTone.soft,
      accent: act.color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TileHeader('$label · ${act.label}'),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: p.v.toStringAsFixed(act.decimals),
            unit: act.unit,
            caption: 'at ${_clock(p.t)}',
            size: BigStatSize.md,
          ),
        ],
      ),
    );
    return BentoColumns(
      entrance: false,
      left: [tile('Peak', pk)],
      right: [tile('Low', lw)],
    );
  }

  // ── the day's events: one clean list tile ───────────────────────────────

  List<Widget> _eventsSection() {
    if (_bands.isEmpty) return const [];
    return [
      const SizedBox(height: Sp.x3),
      BentoTile(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const TileHeader('Events', icon: Ic.calendar),
            const SizedBox(height: Sp.x1),
            for (var i = 0; i < _bands.length; i++)
              ListRow(
                icon: _bands[i].icon,
                iconColor: _bands[i].color,
                title: _bands[i].label,
                value:
                    '${_clock(_bands[i].start)} → ${_clock(_bands[i].end)}'
                    ' · ${((_bands[i].end - _bands[i].start) / 60).round()}m',
                divider: i < _bands.length - 1,
              ),
          ],
        ),
      ),
    ];
  }
}

/// Single merged plot: all vitals normalized into one block, active vital bold +
/// its real Y-axis, activity bands across the block, active peak/low @time.
class _ChartPainter extends CustomPainter {
  final List<_Vital> vitals;
  final List<_Band> bands;
  final int active;
  final double t0, t1, progress, leftPad;
  final double? scrubT;
  _ChartPainter({
    required this.vitals,
    required this.bands,
    required this.active,
    required this.t0,
    required this.t1,
    required this.progress,
    required this.scrubT,
    required this.leftPad,
  });

  static const double _topPad = 18;
  static const double _bottomPad = 22;

  @override
  void paint(Canvas canvas, Size size) {
    if (t1 <= t0) return;
    final chartW = size.width - leftPad;
    final plotTop = _topPad;
    final plotBot = size.height - _bottomPad;
    final plotH = plotBot - plotTop;
    double x(double t) =>
        leftPad + ((t - t0) / (t1 - t0)).clamp(0.0, 1.0) * chartW;
    double yNorm(double v, double lo, double hi) =>
        plotBot - (v - lo) / (hi - lo) * plotH;

    // ── activity bands across the block + glyph on top ──
    for (final b in bands) {
      final x0 = x(b.start), x1 = x(b.end);
      canvas.drawRect(
        Rect.fromLTRB(x0, plotTop, x1.clamp(x0 + 1, size.width), plotBot),
        Paint()..color = b.color.withValues(alpha: 0.10 * progress),
      );
      canvas.drawLine(Offset(x0, plotTop), Offset(x1, plotTop),
          Paint()..color = b.color.withValues(alpha: 0.7)..strokeWidth = 2);
      if (progress > 0.6) {
        final cx = ((x0 + x1) / 2).clamp(leftPad + 8, size.width - 8);
        _icon(canvas, b.icon, Offset(cx - 7, plotTop - 15), b.color, 14);
      }
    }

    // ── active vital scale → Y-axis ticks (real units) ──
    // HONESTY: no numbers shown until the chart is touched — a bare line
    // invites eyeballing a false-precise value off an unlabeled axis. Only
    // draw the grid + tick labels while actively scrubbing; the crosshair
    // readout below is the source of truth for values.
    final act = vitals[active];
    final (alo, ahi) = _range(act);
    if (scrubT != null) {
      final grid = Paint()
        ..color = AppColors.divider.withValues(alpha: 0.45)
        ..strokeWidth = 1;
      for (var i = 0; i <= 3; i++) {
        final v = alo + (ahi - alo) * i / 3;
        final yy = yNorm(v, alo, ahi);
        canvas.drawLine(Offset(leftPad, yy), Offset(size.width, yy), grid);
        _text(canvas, v.toStringAsFixed(act.decimals), Offset(0, yy - 6),
            act.color.withValues(alpha: 0.8), 9);
      }
    }

    // ── X time axis ──
    for (final f in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final t = t0 + (t1 - t0) * f;
      final tx = leftPad + chartW * f;
      _text(canvas, _hhmm(t),
          Offset((tx - 14).clamp(leftPad, size.width - 28), plotBot + 5),
          AppColors.inkMuted, 9);
    }

    // ── averaged vital lines, normalized, overlaid. Inactive lines FADE so the
    //    selected one stands out. The active one also gets a min/max range band
    //    so its true peak/low sit on the visible envelope (not lost to the mean).
    for (var i = 0; i < vitals.length; i++) {
      if (i == active) continue;
      _drawLine(canvas, vitals[i], x, yNorm, chartW, 1.6, 0.16);
    }
    _drawEnvelope(canvas, act, x, yNorm, chartW);
    _drawLine(canvas, act, x, yNorm, chartW, 2.8, 1.0);

    // ── active vital peak (↑ value @time) + low (↓ value @time) ──
    if (act.pts.isNotEmpty) {
      var pk = act.pts.first, lw = act.pts.first;
      for (final p in act.pts) {
        if (p.v > pk.v) pk = p;
        if (p.v < lw.v) lw = p;
      }
      _peak(canvas, x(pk.t), yNorm(pk.v, alo, ahi), pk, act, size.width,
          up: true);
      _peak(canvas, x(lw.t), yNorm(lw.v, alo, ahi), lw, act, size.width,
          up: false);
    }

    // ── crosshair (dots on every line) ──
    if (scrubT != null) {
      final cx = x(scrubT!);
      canvas.drawLine(Offset(cx, plotTop), Offset(cx, plotBot),
          Paint()
            ..color = AppColors.inkMuted.withValues(alpha: 0.6)
            ..strokeWidth = 1);
      for (final v in vitals) {
        final (lo, hi) = _range(v);
        final val = v.valueAt(scrubT!);
        if (val == null) continue;
        canvas.drawCircle(
            Offset(cx, yNorm(val, lo, hi)), 3.5, Paint()..color = v.color);
      }
    }
  }

  (double, double) _range(_Vital v) {
    var lo = double.infinity, hi = -double.infinity;
    for (final p in v.pts) {
      if (p.v < lo) lo = p.v;
      if (p.v > hi) hi = p.v;
    }
    if (!lo.isFinite || hi <= lo) {
      return (lo.isFinite ? lo - 1 : 0, lo.isFinite ? lo + 1 : 1);
    }
    final pad = (hi - lo) * 0.12;
    return (lo - pad, hi + pad);
  }

  /// Filled min–max range band for the active vital, so the peak/low markers sit
  /// on a visible edge instead of floating above the averaged mean line.
  void _drawEnvelope(Canvas canvas, _Vital v, double Function(double) x,
      double Function(double, double, double) yNorm, double chartW) {
    final a = v.avg;
    if (a.length < 2) return;
    final (lo, hi) = _range(v);
    final cutoff = leftPad + chartW * progress;
    final top = <Offset>[], bot = <Offset>[];
    for (final b in a) {
      final px = x(b.t);
      if (px > cutoff) break;
      top.add(Offset(px, yNorm(b.hi, lo, hi)));
      bot.add(Offset(px, yNorm(b.lo, lo, hi)));
    }
    if (top.length < 2) return;
    final path = Path()..moveTo(top.first.dx, top.first.dy);
    for (final o in top.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    for (final o in bot.reversed) {
      path.lineTo(o.dx, o.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = v.color.withValues(alpha: 0.14));
  }

  void _drawLine(Canvas canvas, _Vital v, double Function(double) x,
      double Function(double, double, double) yNorm, double chartW,
      double width, double alpha) {
    final pts = v.avg; // pre-averaged → already smooth
    final n = pts.length;
    if (n < 2) return;
    final (lo, hi) = _range(v); // range over RAW so the axis matches the data
    final cutoff = leftPad + chartW * progress;
    final path = Path();
    var started = false;
    for (var i = 0; i < n; i++) {
      final px = x(pts[i].t);
      if (px > cutoff) break;
      final yy = yNorm(pts[i].v, lo, hi);
      if (!started) {
        path.moveTo(px, yy);
        started = true;
      } else {
        path.lineTo(px, yy);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = v.color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
  }

  void _peak(Canvas canvas, double px, double py, ({double t, double v}) p,
      _Vital v, double maxW, {required bool up}) {
    canvas.drawCircle(Offset(px, py), 3.5, Paint()..color = v.color);
    final label =
        '${up ? '↑' : '↓'} ${p.v.toStringAsFixed(v.decimals)} @${_hhmm(p.t)}';
    _text(canvas, label,
        Offset((px + 4).clamp(leftPad, maxW - 78), py + (up ? -14 : 5)),
        v.color, 9);
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  void _icon(Canvas canvas, IconData ic, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(ic.codePoint),
        style: TextStyle(
            fontFamily: ic.fontFamily,
            package: ic.fontPackage,
            fontSize: size,
            color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  static String _hhmm(double epochSec) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec.round() * 1000);
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.progress != progress || old.active != active || old.scrubT != scrubT;
}
