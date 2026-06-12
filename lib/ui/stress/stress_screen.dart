// Stress — arousal estimated from heart rate above resting while you're still.
// Not HRV. Backed by /day/stress.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../net/api_client.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

class StressScreen extends StatefulWidget {
  final String date; // 'YYYY-MM-DD'
  const StressScreen({super.key, required this.date});
  @override
  State<StressScreen> createState() => _StressScreenState();
}

enum _Phase { loading, ready, empty, error }

class _StressScreenState extends State<StressScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic> _data = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) {
      setState(() { _phase = _Phase.error; _error = 'Not signed in.'; });
      return;
    }
    setState(() { _phase = _Phase.loading; _error = null; });
    try {
      final res = await api.getDayStress(widget.date);
      if (!mounted) return;
      setState(() {
        _data = res;
        _phase = (_score == null && _wornMin == 0) ? _Phase.empty : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is ApiException ? e.body : e.toString();
      });
    }
  }

  // ── parsing ──────────────────────────────────────────────────────────────────
  num? _num(Object? v) =>
      v is num ? v : (v is String ? num.tryParse(v) : null);
  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  int? get _score => _num(_data['score'])?.toInt();
  int get _wornMin => _num(_data['worn_min'])?.toInt() ?? 0;
  Map<String, dynamic> get _buckets => _map(_data['buckets']);
  int get _calm => _num(_buckets['calm'])?.toInt() ?? 0;
  int get _balanced => _num(_buckets['balanced'])?.toInt() ?? 0;
  int get _stressed => _num(_buckets['stressed'])?.toInt() ?? 0;
  int get _active => _num(_buckets['active'])?.toInt() ?? 0;

  /// epoch-seconds at UTC midnight of the displayed date (band positioning).
  int get _dayStart {
    final p = widget.date.split('-');
    if (p.length != 3) return 0;
    final y = int.tryParse(p[0]), mo = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (y == null || mo == null || d == null) return 0;
    return DateTime.utc(y, mo, d).millisecondsSinceEpoch ~/ 1000;
  }

  List<({double frac, Color color})> _bandPoints() {
    final raw = _data['band'];
    if (raw is! List) return const [];
    final out = <({double frac, Color color})>[];
    for (final p in raw) {
      final m = _map(p);
      final t = _num(m['t'])?.toInt();
      final b = m['b']?.toString() ?? 'none';
      if (t == null) continue;
      final frac = ((t - _dayStart) / 86400.0).clamp(0.0, 1.0);
      out.add((frac: frac, color: _bucketColor(b)));
    }
    out.sort((a, b) => a.frac.compareTo(b.frac));
    return out;
  }

  Color _bucketColor(String b) {
    switch (b) {
      case 'calm': return AppColors.good;
      case 'balanced': return AppColors.coral.withValues(alpha: 0.55);
      case 'stressed': return AppColors.warn;
      case 'active': return AppColors.loadDetraining; // moving (exertion, not stress)
      default: return AppColors.surfaceAlt;
    }
  }

  /// Day-stress score → color (LOW stress is good; HIGH is warn/bad).
  Color _scoreColor(int v) {
    if (v < 25) return AppColors.good;
    if (v < 50) return AppColors.coral;
    if (v < 75) return AppColors.warn;
    return AppColors.bad;
  }

  String _band(int v) => v < 25 ? 'Calm day'
      : v < 50 ? 'Balanced' : v < 75 ? 'Elevated' : 'High arousal';

  String _hm(int m) {
    if (m <= 0) return '0m';
    final h = m ~/ 60, r = m % 60;
    if (h == 0) return '${r}m';
    if (r == 0) return '${h}h';
    return '${h}h ${r}m';
  }

  String _clock(int? epochSec) {
    if (epochSec == null) return '—';
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000).toLocal();
    return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static const _weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  String _prettyDate() {
    final p = widget.date.split('-');
    if (p.length != 3) return widget.date;
    final y = int.tryParse(p[0]), mo = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (y == null || mo == null || d == null || mo < 1 || mo > 12) return widget.date;
    final dt = DateTime(y, mo, d);
    return '${_weekdays[(dt.weekday - 1) % 7]}, ${_months[mo - 1]} $d';
  }

  // ── build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            _topBar(),
            const SizedBox(height: Sp.x6),
            if (_phase == _Phase.loading)
              _loading()
            else if (_phase == _Phase.empty)
              _stateCard(Ic.pulse, 'No stress data for this day',
                  'Stress needs heart rate during still, sedentary minutes. Wear your '
                  'strap through the day and sync to see your arousal pattern.')
            else if (_phase == _Phase.error)
              _stateCard(Ic.cloud, "Couldn't load stress", _error ?? 'Please try again.')
            else ...[
              _hero(),
              const SizedBox(height: Sp.x6),
              const SectionHeader('Across the day'),
              _bandCard(),
              const SizedBox(height: Sp.x6),
              const SectionHeader('Time in each state'),
              _breakdownCard(),
              ..._peakSection(),
              const SizedBox(height: Sp.x6),
              _honesty(),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _topBar() => Row(children: [
        RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Stress', style: AppText.h1),
              const SizedBox(height: 2),
              Text(_prettyDate(), style: AppText.caption),
            ],
          ),
        ),
      ]);

  Widget _hero() {
    final v = _score ?? 0;
    final color = _scoreColor(v);
    return GlowCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                const AppIcon(Ic.pulse, size: 16, color: AppColors.coralDeep),
                const SizedBox(width: Sp.x2),
                Text('DAY STRESS', style: AppText.overline),
                const SizedBox(width: Sp.x2),
                const Tag('est.', color: AppColors.coral),
              ]),
              const SizedBox(height: Sp.x3),
              Text('$v', style: AppText.display.copyWith(color: color)),
              const SizedBox(height: Sp.x1),
              Text('${_band(v)} · ${_hm(_wornMin)} worn', style: AppText.bodySoft),
            ],
          ),
        ),
        const SizedBox(width: Sp.x4),
        RingStat(
          t: (v / 100).clamp(0.0, 1.0),
          color: color,
          size: 104,
          stroke: 11,
          center: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$v', style: AppText.metricSm.copyWith(fontSize: 20, color: color)),
            Text('/100', style: AppText.captionMuted),
          ]),
        ),
      ]),
    );
  }

  Widget _bandCard() {
    final pts = _bandPoints();
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (pts.isEmpty)
          SizedBox(height: 40, child: Center(
              child: Text('No minute data', style: AppText.captionMuted)))
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(R.pill),
            child: SizedBox(
              height: 30,
              child: CustomPaint(size: Size.infinite, painter: _BandPainter(pts)),
            ),
          ),
        const SizedBox(height: Sp.x2),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: const [
          Text('12a', style: TextStyle(fontSize: 10, color: AppColors.inkMuted)),
          Text('6a', style: TextStyle(fontSize: 10, color: AppColors.inkMuted)),
          Text('12p', style: TextStyle(fontSize: 10, color: AppColors.inkMuted)),
          Text('6p', style: TextStyle(fontSize: 10, color: AppColors.inkMuted)),
          Text('12a', style: TextStyle(fontSize: 10, color: AppColors.inkMuted)),
        ]),
        const SizedBox(height: Sp.x3),
        Wrap(spacing: Sp.x4, runSpacing: Sp.x2, children: [
          _legend(AppColors.good, 'Calm'),
          _legend(AppColors.coral.withValues(alpha: 0.55), 'Balanced'),
          _legend(AppColors.warn, 'Stressed'),
          _legend(AppColors.loadDetraining, 'Active'),
        ]),
      ]),
    );
  }

  Widget _legend(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 11, height: 11, decoration: BoxDecoration(
            color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(label, style: AppText.caption),
      ]);

  Widget _breakdownCard() {
    final total = _calm + _balanced + _stressed + _active;
    Widget row(String label, int min, Color c) {
      final pct = total > 0 ? min / total : 0.0;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: Sp.x3),
            Expanded(child: Text(label, style: AppText.title)),
            Text(_hm(min), style: AppText.metricSm.copyWith(fontSize: 17)),
            const SizedBox(width: Sp.x3),
            SizedBox(width: 42, child: Text('${(pct * 100).round()}%',
                textAlign: TextAlign.right, style: AppText.caption)),
          ]),
          const SizedBox(height: Sp.x2),
          ClipRRect(
            borderRadius: BorderRadius.circular(R.pill),
            child: SizedBox(height: 6, child: Row(children: [
              Expanded(flex: (pct * 1000).round().clamp(0, 1000), child: Container(color: c)),
              Expanded(flex: (1000 - (pct * 1000).round()).clamp(1, 1000),
                  child: Container(color: AppColors.surfaceAlt)),
            ])),
          ),
        ]),
      );
    }
    return ProCard(child: Column(children: [
      row('Calm', _calm, AppColors.good),
      row('Balanced', _balanced, AppColors.coral.withValues(alpha: 0.55)),
      row('Stressed', _stressed, AppColors.warn),
      row('Active (moving)', _active, AppColors.loadDetraining),
    ]));
  }

  List<Widget> _peakSection() {
    final p = _map(_data['peak']);
    final ts = _num(p['t'])?.toInt();
    final sc = _num(p['score'])?.toInt();
    if (ts == null || sc == null) return const [];
    return [
      const SizedBox(height: Sp.x6),
      const SectionHeader('Peak arousal'),
      ProCard(child: Row(children: [
        Container(
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
              color: AppColors.warnSoft, borderRadius: BorderRadius.circular(R.chip)),
          child: const AppIcon(Ic.pulse, size: 20, color: AppColors.warn),
        ),
        const SizedBox(width: Sp.x4),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Highest around ${_clock(ts)}', style: AppText.title),
            const SizedBox(height: 2),
            Text('Arousal hit $sc/100 — a stretch of elevated heart rate while still.',
                style: AppText.bodySoft),
          ],
        )),
      ])),
    ];
  }

  Widget _honesty() => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const AppIcon(Ic.info, size: 14, color: AppColors.inkMuted),
        const SizedBox(width: Sp.x2),
        Expanded(child: Text(
          'An arousal estimate — heart rate above your resting level while you\'re '
          'still — NOT HRV. It can\'t tell stress from caffeine, excitement or a '
          'warm room. Moving minutes are counted as activity, not stress.',
          style: AppText.captionMuted,
        )),
      ]);

  Widget _loading() => const ProCard(
        padding: EdgeInsets.all(Sp.x6),
        child: SizedBox(height: 320,
            child: Center(child: CircularProgressIndicator(color: AppColors.coral))),
      );

  Widget _stateCard(IconData icon, String title, String message) => ProCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: const BoxDecoration(color: AppColors.coralSoft, shape: BoxShape.circle),
            child: AppIcon(icon, size: 30, color: AppColors.coralDeep),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x5),
          OutlinedButton(onPressed: _load, child: const Text('Try again')),
        ]),
      );
}

/// Paints the 24h arousal band: each point colors the sliver from its frac to
/// the next point's frac (full-width = the day). Gaps render as the track color.
class _BandPainter extends CustomPainter {
  final List<({double frac, Color color})> pts;
  _BandPainter(this.pts);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.surfaceAlt);
    for (int i = 0; i < pts.length; i++) {
      final x0 = pts[i].frac * size.width;
      final x1 = (i + 1 < pts.length ? pts[i + 1].frac : pts[i].frac + 1 / 240) * size.width;
      final w = (x1 - x0).clamp(1.0, size.width);
      canvas.drawRect(Rect.fromLTWH(x0, 0, w, size.height), Paint()..color = pts[i].color);
    }
  }
  @override
  bool shouldRepaint(_BandPainter old) => old.pts != pts;
}
