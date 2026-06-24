// Records, streaks, and resting-HR trend over time. Backed by /records.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/payloads.dart';
import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});
  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

enum _Phase { loading, ready, empty, error }

class _RecordsScreenState extends State<RecordsScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  RecordsData _r = RecordsData.fromJson(null);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().repo;
    if (api == null) {
      setState(() { _phase = _Phase.error; _error = 'Not signed in.'; });
      return;
    }
    setState(() { _phase = _Phase.loading; _error = null; });
    try {
      final res = await api.getRecords();
      if (!mounted) return;
      final r = RecordsData.fromJson(res);
      setState(() { _r = r; _phase = r.isEmpty ? _Phase.empty : _Phase.ready; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  // ── formatting ──────────────────────────────────────────────────────────────
  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  String _prettyDate(String iso) {
    final p = iso.split('-');
    if (p.length != 3) return iso;
    final mo = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (mo == null || d == null || mo < 1 || mo > 12) return iso;
    return '${_months[mo - 1]} $d';
  }

  String _hm(num m) {
    final mm = m.round();
    final h = mm ~/ 60, r = mm % 60;
    if (h == 0) return '${r}m';
    if (r == 0) return '${h}h';
    return '${h}h ${r}m';
  }

  /// Format a record value per its key.
  String _fmt(String key, num v, String? type) {
    switch (key) {
      case 'lowest_rhr':
      case 'lowest_sleeping_hr':
        return '${v.round()} bpm';
      case 'top_strain':
      case 'top_workout':
        return v.toStringAsFixed(1);
      case 'top_readiness':
      case 'most_steps':
        return '${v.round()}';
      case 'longest_sleep':
        return _hm(v);
      case 'best_efficiency':
        return '${(v * 100).round()}%';
      default:
        return v.toString();
    }
  }

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
              _stateCard(Ic.recovery, 'Nothing logged yet',
                  'Wear and sync for a few days. Your records, streaks and trends '
                  'build up here over time.')
            else if (_phase == _Phase.error)
              _stateCard(Ic.cloud, "Couldn't load your records", _error ?? 'Please try again.')
            else ...[
              _summaryStrip(),
              const SizedBox(height: Sp.x6),
              const SectionHeader('Streaks'),
              _streaks(),
              const SizedBox(height: Sp.x6),
              const SectionHeader('Resting heart rate trend'),
              _driftCard(),
              const SizedBox(height: Sp.x6),
              const SectionHeader('Personal records'),
              _records(),
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
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Your body', style: AppText.h1),
            const SizedBox(height: 2),
            Text('Over time', style: AppText.caption),
          ],
        )),
      ]);

  Widget _summaryStrip() => Row(children: [
        Expanded(child: _miniStat('${_r.daysTracked}', 'days tracked')),
        const SizedBox(width: Sp.x3),
        Expanded(child: _miniStat('${_r.nightsTracked}', 'nights')),
        const SizedBox(width: Sp.x3),
        Expanded(child: _miniStat('${_r.workoutsTracked}', 'workouts')),
      ]);

  Widget _miniStat(String v, String label) => ProCard(
        padding: const EdgeInsets.symmetric(vertical: Sp.x4, horizontal: Sp.x3),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(v, style: AppText.metricSm.copyWith(fontSize: 22)),
          const SizedBox(height: 2),
          Text(label, style: AppText.captionMuted, textAlign: TextAlign.center),
        ]),
      );

  Widget _streaks() {
    final items = [
      ('wear', Ic.watch),
      ('sleep', Ic.moon),
      ('strain_target', Ic.strain),
    ];
    final cards = <Widget>[];
    for (final (key, icon) in items) {
      final s = _r.streak(key);
      if (s == null) continue;
      cards.add(_streakCard(icon, s.current, s.label));
    }
    if (cards.isEmpty) {
      return ProCard(child: Text('No streaks yet — keep wearing it.',
          style: AppText.bodySoft));
    }
    return Column(children: [
      for (int i = 0; i < cards.length; i++) ...[
        if (i > 0) const SizedBox(height: Sp.x3),
        cards[i],
      ],
    ]);
  }

  Widget _streakCard(IconData icon, int current, String label) {
    final active = current > 0;
    return ProCard(child: Row(children: [
      Container(
        padding: const EdgeInsets.all(Sp.x3),
        decoration: BoxDecoration(
          color: active ? AppColors.coralSoft : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(R.chip),
        ),
        child: AppIcon(active ? Ic.fire : icon, size: 20,
            color: active ? AppColors.coralDeep : AppColors.inkMuted),
      ),
      const SizedBox(width: Sp.x4),
      Expanded(child: Text(label, style: AppText.title)),
      Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        Text('$current', style: AppText.metricSm.copyWith(
            fontSize: 24, color: active ? AppColors.coral : AppColors.inkMuted)),
        Text(current == 1 ? 'day' : 'days', style: AppText.captionMuted),
      ]),
    ]));
  }

  Widget _driftCard() {
    final d = _r.rhrDrift;
    if (d == null) {
      return ProCard(child: Text('Not enough history yet to show a resting-HR trend.',
          style: AppText.bodySoft));
    }
    final improving = d.direction == 'improving';
    final flat = d.direction == 'flat';
    final color = improving ? AppColors.good : (flat ? AppColors.inkMuted : AppColors.warn);
    final arrow = improving ? Ic.down : (flat ? Ic.activity : Ic.up);
    final headline = flat
        ? 'Holding steady'
        : improving
            ? 'Trending down ${d.delta.abs().toStringAsFixed(1)} bpm'
            : 'Up ${d.delta.abs().toStringAsFixed(1)} bpm';
    return ProCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(R.chip)),
          child: AppIcon(arrow, size: 20, color: color),
        ),
        const SizedBox(width: Sp.x4),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(headline, style: AppText.title),
            const SizedBox(height: 2),
            Text('${d.then.toStringAsFixed(0)} → ${d.now.toStringAsFixed(0)} bpm over ${d.days} days',
                style: AppText.captionMuted),
          ],
        )),
      ]),
      const SizedBox(height: Sp.x3),
      Text(improving
          ? 'A falling resting heart rate usually means your fitness is improving.'
          : flat
              ? 'Your resting heart rate has been stable.'
              : 'A rising resting heart rate can mean fatigue, stress or illness — '
                'worth keeping an eye on.',
          style: AppText.bodySoft),
    ]));
  }

  Widget _records() {
    final defs = <(String, String, IconData)>[
      ('lowest_rhr', 'Lowest resting HR', Ic.heart),
      ('lowest_sleeping_hr', 'Lowest sleeping HR', Ic.moon),
      ('top_strain', 'Biggest day strain', Ic.strain),
      ('top_workout', 'Top workout strain', Ic.run),
      ('longest_sleep', 'Longest sleep', Ic.bed),
      ('best_efficiency', 'Best sleep efficiency', Ic.sleep),
      ('most_steps', 'Most steps', Ic.run),
      ('top_readiness', 'Top readiness', Ic.recovery),
    ];
    final tiles = <Widget>[];
    for (final (key, label, icon) in defs) {
      final rec = _r.record(key);
      if (rec == null) continue;
      tiles.add(_recordTile(icon, label, _fmt(key, rec.value, rec.type),
          _prettyDate(rec.date), rec.type));
    }
    if (tiles.isEmpty) {
      return ProCard(child: Text('No records yet.', style: AppText.bodySoft));
    }
    // 2-column grid.
    final rows = <Widget>[];
    for (int i = 0; i < tiles.length; i += 2) {
      rows.add(Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: tiles[i]),
        const SizedBox(width: Sp.x3),
        Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox()),
      ]));
      if (i + 2 < tiles.length) rows.add(const SizedBox(height: Sp.x3));
    }
    return Column(children: rows);
  }

  Widget _recordTile(IconData icon, String label, String value, String date, String? type) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: AppColors.coralSoft, borderRadius: BorderRadius.circular(R.chip)),
            child: AppIcon(icon, size: 15, color: AppColors.coralDeep),
          ),
          const SizedBox(width: Sp.x2),
          Expanded(child: Text(label, style: AppText.overline, maxLines: 2, overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: Sp.x3),
        Text(value, style: AppText.metric.copyWith(fontSize: 22), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(type != null && type.isNotEmpty ? '${_titleCase(type)} · $date' : date,
            style: AppText.captionMuted, maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  String _titleCase(String s) => s.isEmpty ? s
      : s.split(RegExp(r'[ _/]')).where((w) => w.isNotEmpty)
          .map((w) => '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  Widget _loading() => ProCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: SizedBox(height: 320,
            child: Center(child: CircularProgressIndicator(color: AppColors.coral))),
      );

  Widget _stateCard(IconData icon, String title, String message) => ProCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: BoxDecoration(color: AppColors.coralSoft, shape: BoxShape.circle),
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
