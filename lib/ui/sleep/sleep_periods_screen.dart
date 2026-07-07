// Sleep periods (v2) — every sleep of the day, one bento card each, on the NEW
// design language. A nap is not a special case: it's just a shorter sleep.
// Slept once → one card; napped twice → three cards. The day total is an ink
// hero tile; every period card carries its own mini hypnogram + StageBars on
// the ONE DomainAccent stage palette. Backed by /day/v2/sleep.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

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
    final api = context.read<AppState>().repo;
    if (api == null) {
      setState(() {
        _phase = _Phase.error;
        _error = 'Not signed in.';
      });
      return;
    }
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
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
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  // ── parsing ──────────────────────────────────────────────────────────────
  num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
  List<Map<String, dynamic>> get _periods {
    final p = _data['periods'];
    if (p is List) {
      return p.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  int get _needMin => (_num(_data['need_min'])?.toInt()) ?? 480;
  int get _totalAsleep => (_num(_data['total_asleep_min'])?.toInt()) ?? 0;
  bool get _beta => _data['stages_beta'] == true;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Sleep periods',
      subtitle: 'Every sleep, naps included',
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.accent,
        child: ListView(
          // AlwaysScrollable so pull-to-refresh fires even when content is
          // short (loading / empty / error).
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding:
              const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x10),
          children: [
            if (_phase == _Phase.loading) ...[
              Skeleton.hero(),
              const SizedBox(height: Sp.x3),
              Skeleton.tileRow(rows: 2),
            ] else if (_phase == _Phase.empty)
              const StateCard(
                icon: OsIcon.bedtime,
                title: 'No sleep detected',
                message:
                    'Wear your strap overnight (and through any naps) and sync '
                    'to see each sleep here.',
              )
            else if (_phase == _Phase.error)
              StateCard(
                icon: OsIcon.sync,
                title: "Couldn't load sleep",
                message: _error ?? 'Please try again.',
                actionLabel: 'Try again',
                onAction: _load,
              )
            else
              ...dsStaggered([
                _summary(),
                const SizedBox(height: Sp.x3),
                for (final p in _periods) ...[
                  _periodCard(p),
                  const SizedBox(height: Sp.x3),
                ],
              ]),
          ],
        ),
      ),
    );
  }

  // Day hero: total asleep across all periods vs need — the board's ink tile.
  Widget _summary() {
    final n = _periods.length;
    final t = _needMin <= 0
        ? double.nan
        : (_totalAsleep / _needMin).clamp(0.0, 1.0).toDouble();
    return BentoTile(
      tone: BentoTone.ink,
      accent: DomainAccent.sleep,
      padding: const EdgeInsets.all(Sp.x5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const TileHeader('Total sleep'),
                const SizedBox(height: Sp.x2),
                BigStat(
                  value: _hm(_totalAsleep),
                  size: BigStatSize.xl,
                  caption: 'need ${_hm(_needMin)} · $n sleep${n == 1 ? '' : 's'}',
                ),
              ],
            ),
          ),
          const SizedBox(width: Sp.x3),
          ArcGauge(
            value: t,
            color: DomainAccent.sleep,
            size: 96,
            stroke: 10,
            sweepFraction: 0.75,
            endDot: !t.isNaN,
            valueText: t.isNaN ? '—' : '${(t * 100).round()}%',
            label: 'of need',
          ),
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
    final stages = (p['stages'] is Map)
        ? (p['stages'] as Map).cast<String, dynamic>()
        : null;
    final hypno = hypnoSegmentsFromPoints(
        (p['hypnogram'] is List) ? p['hypnogram'] as List : const []);

    return BentoTile(
      tone: isMain ? BentoTone.paper : BentoTone.soft,
      accent: DomainAccent.sleep,
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TileHeader(
                  isMain ? 'Main sleep' : 'Nap',
                  icon: isMain ? OsIcon.sleep : OsIcon.bedtime,
                  trailing: _beta ? const Tag('est') : null,
                ),
              ),
              ConfDot(conf),
              InfoDot(
                title: isMain ? 'Main sleep' : 'Nap',
                body:
                    'Stages are a wrist estimate from heart rate + motion (no '
                    'EEG). The dot shows detection confidence for this window.',
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: BigStat(
                  value: _hm(dur),
                  caption: (onset != null && wake != null)
                      ? '${_clock(onset)} – ${_clock(wake)}'
                      : null,
                ),
              ),
              if (eff != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: StatusChip(
                    '${(eff * 100).round()}% efficient',
                    tone: ChipTone.positive,
                  ),
                ),
            ],
          ),
          if (hypno.isNotEmpty) ...[
            const SizedBox(height: Sp.x4),
            // Per-period stepped hypnogram — same component + palette as the
            // main Sleep screen, compact and unlabelled.
            Hypnogram(hypno, height: 56, labels: false),
          ],
          if (stages != null) ...[
            const SizedBox(height: Sp.x3),
            _stageBars(stages),
          ],
        ],
      ),
    );
  }

  /// StageBars from the period's stage minutes. Falls back to the legacy
  /// combined nrem_min (rendered as Light) when the light/deep split is absent.
  Widget _stageBars(Map<String, dynamic> s) {
    var light = (_num(s['light_min']) ?? 0).round();
    final deep = (_num(s['deep_min']) ?? 0).round();
    final rem = (_num(s['rem_min']) ?? 0).round();
    if (light <= 0 && deep <= 0) light = (_num(s['nrem_min']) ?? 0).round();
    if (light + deep + rem <= 0) return const SizedBox.shrink();
    return StageBars(
      lightMin: light,
      deepMin: deep,
      remMin: rem,
      height: 10,
    );
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
}
