// Sleep periods (v2) — every sleep of the day, one card each. A nap is not a
// special case: it's just a shorter sleep. Slept once → one card; napped twice →
// three cards. Backed by /day/v2/sleep (additive; the single-night /day/sleep
// screen is untouched). "Ember on Paper" design.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../net/api_client.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class SleepPeriodsScreen extends StatefulWidget {
  final String date; // 'YYYY-MM-DD'
  const SleepPeriodsScreen({super.key, required this.date});

  @override
  State<SleepPeriodsScreen> createState() => _SleepPeriodsScreenState();
}

enum _Phase { loading, ready, empty, error }

class _SleepPeriodsScreenState extends State<SleepPeriodsScreen> {
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
      final res = await api.getDaySleepV2(widget.date);
      if (!mounted) return;
      setState(() {
        _data = res;
        _phase = _periods.isEmpty ? _Phase.empty : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is ApiException ? e.body : e.toString();
      });
    }
  }

  // ── parsing ──────────────────────────────────────────────────────────────
  num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
  List<Map<String, dynamic>> get _periods {
    final p = _data['periods'];
    if (p is List) return p.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    return const [];
  }

  int get _needMin => (_num(_data['need_min'])?.toInt()) ?? 480;
  int get _totalAsleep => (_num(_data['total_asleep_min'])?.toInt()) ?? 0;
  bool get _beta => _data['stages_beta'] == true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          color: AppColors.coral,
          child: ListView(
          // AlwaysScrollable so pull-to-refresh fires even when content is short
          // (loading / empty / error) — the common "refresh doesn't work" cause.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            _topBar(),
            const SizedBox(height: Sp.x6),
            if (_phase == _Phase.loading)
              _stateCard(Ic.moon, 'Loading…', 'Fetching your sleep periods.')
            else if (_phase == _Phase.empty)
              _stateCard(Ic.bed, 'No sleep detected',
                  'Wear your strap overnight (and through any naps) and sync to '
                  'see each sleep here.')
            else if (_phase == _Phase.error)
              _stateCard(Ic.cloud, "Couldn't load sleep", _error ?? 'Please try again.')
            else ...[
              _summary(),
              const SizedBox(height: Sp.x6),
              for (final p in _periods) ...[
                _periodCard(p),
                const SizedBox(height: Sp.x4),
              ],
              const SizedBox(height: Sp.x2),
              Text(
                'Stages are a beta estimate from heart rate + motion (no EEG). A '
                'nap is scored the same way as a full night — just shorter.',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
            ],
            const SizedBox(height: 40),
          ],
          ),
        ),
      ),
    );
  }

  // Day summary: total asleep across all periods vs need.
  Widget _summary() {
    final n = _periods.length;
    return GlowCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Total sleep', style: AppText.label.copyWith(color: AppColors.inkSoft)),
                const SizedBox(height: Sp.x2),
                Text(_hm(_totalAsleep), style: AppText.metric.copyWith(fontSize: 40)),
                const SizedBox(height: 2),
                Text('need ${_hm(_needMin)} · $n sleep${n == 1 ? '' : 's'}',
                    style: AppText.caption.copyWith(color: AppColors.inkSoft)),
              ],
            ),
          ),
          AppIcon(Ic.moon, size: 30, color: AppColors.coral),
        ],
      ),
    );
  }

  Widget _periodCard(Map<String, dynamic> p) {
    final isMain = p['is_main'] == true;
    final onset = _num(p['onset_ts'])?.toInt();
    final wake = _num(p['wake_ts'])?.toInt();
    final dur = _num(p['duration_min'])?.toInt() ?? 0;
    final eff = _num(p['efficiency'])?.toDouble();
    final conf = _num(p['confidence'])?.toDouble() ?? 0;
    final stages = (p['stages'] is Map) ? (p['stages'] as Map).cast<String, dynamic>() : null;

    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(isMain ? Ic.moon : Ic.bed,
                  size: 20, color: isMain ? AppColors.coral : AppColors.inkSoft),
              const SizedBox(width: Sp.x2),
              Text(isMain ? 'Main sleep' : 'Nap', style: AppText.h2),
              const SizedBox(width: Sp.x2),
              if (_beta) Tag('beta', color: AppColors.coral),
              const Spacer(),
              ConfDot(conf),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_hm(dur), style: AppText.metric.copyWith(fontSize: 32)),
              const SizedBox(width: Sp.x3),
              if (eff != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('${(eff * 100).round()}% efficiency',
                      style: AppText.caption.copyWith(color: AppColors.inkSoft)),
                ),
            ],
          ),
          if (onset != null && wake != null) ...[
            const SizedBox(height: 2),
            Text('${_clock(onset)} – ${_clock(wake)}',
                style: AppText.label.copyWith(color: AppColors.inkSoft)),
          ],
          if (stages != null) ...[
            const SizedBox(height: Sp.x4),
            _stageBar(stages),
            const SizedBox(height: Sp.x3),
            _stageLegend(stages),
          ],
        ],
      ),
    );
  }

  Widget _stageBar(Map<String, dynamic> s) {
    final deep = (_num(s['deep_min']) ?? 0).toDouble();
    final rem = (_num(s['rem_min']) ?? 0).toDouble();
    final light = (_num(s['light_min']) ?? 0).toDouble();
    final total = deep + rem + light;
    if (total <= 0) return const SizedBox.shrink();
    Widget seg(double v, Color c) =>
        v <= 0 ? const SizedBox.shrink() : Expanded(flex: (v * 100).round(), child: Container(color: c));
    return ClipRRect(
      borderRadius: BorderRadius.circular(R.chip),
      child: SizedBox(
        height: 14,
        child: Row(children: [
          seg(deep, _stageColor('deep')),
          seg(light, _stageColor('light')),
          seg(rem, _stageColor('rem')),
        ]),
      ),
    );
  }

  Widget _stageLegend(Map<String, dynamic> s) {
    Widget item(String label, String key, Color c) {
      final v = _num(s['${key}_min'])?.toInt() ?? 0;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text('$label ${_hm(v)}', style: AppText.caption.copyWith(color: AppColors.inkSoft)),
      ]);
    }
    return Wrap(spacing: Sp.x4, runSpacing: Sp.x2, children: [
      item('Deep', 'deep', _stageColor('deep')),
      item('Light', 'light', _stageColor('light')),
      item('REM', 'rem', _stageColor('rem')),
    ]);
  }

  // Same stage palette as the single-night detail screen.
  Color _stageColor(String stage) {
    switch (stage) {
      case 'light':
        return AppColors.coral.withValues(alpha: 0.35);
      case 'rem':
        return AppColors.coral;
      case 'deep':
        return AppColors.coralDeep;
      default:
        return AppColors.inkMuted;
    }
  }

  String _hm(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _clock(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    final h24 = d.hour;
    final ampm = h24 < 12 ? 'AM' : 'PM';
    var h = h24 % 12;
    if (h == 0) h = 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} $ampm';
  }

  Widget _stateCard(IconData icon, String title, String body) => ProCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AppIcon(icon, size: 26, color: AppColors.inkSoft),
          const SizedBox(height: Sp.x3),
          Text(title, style: AppText.h2),
          const SizedBox(height: Sp.x2),
          Text(body, style: AppText.body.copyWith(color: AppColors.inkSoft)),
        ]),
      );

  Widget _topBar() => Row(children: [
        RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sleep periods', style: AppText.h1),
              Text('Every sleep, naps included',
                  style: AppText.caption.copyWith(color: AppColors.inkSoft)),
            ],
          ),
        ),
      ]);
}
