// Workouts — the training log. Manual start (▶ → pick type → live → end → breakdown)
// and auto-detected efforts both land here. Per timeframe we show an honest training
// summary (time/count/type/zones/calories — no fabricated distance or reps) + the
// list; tap a workout for its full breakdown. Reuses the existing kit.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import '../concern/detail_cards.dart' show hm;

const _exercises = [
  ('run', 'Run', Ic.run), ('cycle', 'Cycle', Ic.activity), ('strength', 'Strength', Ic.fire),
  ('walk', 'Walk', Ic.run), ('swim', 'Swim', Ic.activity), ('cardio', 'Cardio', Ic.pulse),
  ('yoga', 'Yoga', Ic.heart), ('other', 'Other', Ic.activity),
];
const _ranges = ['Today', 'Week', 'Month', '3M'];
const _rangeKey = ['week', 'week', 'month', 'quarter']; // Today filters week to today

/// Bottom-sheet exercise picker → starts a workout → opens the live screen.
Future<void> startWorkoutFlow(BuildContext context) async {
  final type = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(R.card))),
    builder: (_) => Padding(
      padding: const EdgeInsets.all(Sp.x5),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Start a workout', style: AppText.h2),
        const SizedBox(height: Sp.x4),
        Wrap(spacing: Sp.x3, runSpacing: Sp.x3, children: [
          for (final e in _exercises)
            GestureDetector(
              onTap: () => Navigator.pop(context, e.$1),
              child: Container(
                width: 96, padding: const EdgeInsets.symmetric(vertical: Sp.x4),
                decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(R.card)),
                child: Column(children: [
                  AppIcon(e.$3, size: 26, color: AppColors.coral),
                  const SizedBox(height: Sp.x2),
                  Text(e.$2, style: AppText.label),
                ]),
              ),
            ),
        ]),
        const SizedBox(height: Sp.x4),
      ]),
    ),
  );
  if (type == null || !context.mounted) return;
  final api = context.read<AppState>().api;
  if (api == null) return;
  try {
    final w = await api.startWorkout(type);
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LiveWorkoutScreen(workoutId: w['workout_id'] as String, type: type),
    ));
  } catch (_) {/* surfaced as no-op; user can retry */}
}

class WorkoutsScreen extends StatefulWidget {
  const WorkoutsScreen({super.key});
  @override
  State<WorkoutsScreen> createState() => _WorkoutsScreenState();
}

class _WorkoutsScreenState extends State<WorkoutsScreen> {
  int _range = 0;
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() => _loading = true);
    try {
      final d = await api.getWorkouts(range: _rangeKey[_range]);
      if (mounted) setState(() { _data = d; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isToday(int startTs) {
    final now = DateTime.now().toUtc();
    final d = DateTime.fromMillisecondsSinceEpoch(startTs * 1000, isUtc: true);
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    final all = (_data?['workouts'] as List?) ?? const [];
    final list = _range == 0 ? all.where((w) => _isToday((w as Map)['start_ts'] as int? ?? 0)).toList() : all;
    final summary = (_data?['summary'] as Map?)?.cast<String, dynamic>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.coral,
        onPressed: () => startWorkoutFlow(context).then((_) => _load()),
        icon: const AppIcon(Ic.run, size: 20, color: Colors.white),
        label: Text('Start', style: AppText.label.copyWith(color: Colors.white)),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x4, Sp.x4, Sp.x10),
            children: [
              Row(children: [
                if (Navigator.of(context).canPop()) ...[
                  RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: Sp.x3),
                ],
                Text('Workouts', style: AppText.h1),
              ]),
              const SizedBox(height: Sp.x3),
              Center(child: SegToggle(options: _ranges, index: _range, onChanged: (i) { setState(() => _range = i); _load(); })),
              const SizedBox(height: Sp.x4),
              if (_loading)
                const Padding(padding: EdgeInsets.symmetric(vertical: Sp.x6), child: Center(child: CircularProgressIndicator()))
              else ...[
                if (_range != 0 && summary != null) _summary(summary),
                if (_range != 0 && summary != null) const SizedBox(height: Sp.x4),
                if (list.isEmpty)
                  ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x6), child: Center(
                    child: Column(children: [
                      const AppIcon(Ic.run, size: 32, color: AppColors.inkMuted),
                      const SizedBox(height: Sp.x3),
                      Text('No workouts', style: AppText.label),
                      const SizedBox(height: Sp.x1),
                      Text('Tap Start, or an effort will be auto-detected.', style: AppText.captionMuted, textAlign: TextAlign.center),
                    ]),
                  )))
                else
                  for (final w in list) _WorkoutTile(w as Map<String, dynamic>),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary(Map<String, dynamic> s) {
    final byType = (s['by_type'] as Map?) ?? const {};
    final types = byType.entries.map((e) => '${(e.value as Map)['count']} ${e.key}').join(' · ');
    return ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _stat('${s['count'] ?? 0}', 'workouts'),
        const SizedBox(width: Sp.x5),
        _stat(hm(s['total_min'] as num?), 'active time'),
        const SizedBox(width: Sp.x5),
        _stat('${s['total_calories'] ?? 0}', 'kcal'),
      ]),
      if (types.isNotEmpty) ...[
        const SizedBox(height: Sp.x3),
        Text(types, style: AppText.captionMuted),
      ],
    ])));
  }

  Widget _stat(String v, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(v, style: AppText.h2),
    Text(label, style: AppText.captionMuted),
  ]);
}

class _WorkoutTile extends StatelessWidget {
  final Map<String, dynamic> w;
  const _WorkoutTile(this.w);
  @override
  Widget build(BuildContext context) {
    final live = w['status'] == 'live';
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: ProCard(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => WorkoutDetailScreen(id: w['id'] as String))),
        padding: const EdgeInsets.all(Sp.x4),
        child: Row(children: [
          Container(padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.coral.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(R.chip)),
            child: const AppIcon(Ic.run, size: 18, color: AppColors.coral)),
          const SizedBox(width: Sp.x3),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${w['type']}'.toUpperCase(), style: AppText.label),
              if (w['source'] == 'auto') ...[const SizedBox(width: Sp.x2), const Tag('AUTO', color: AppColors.inkMuted)],
              if (live) ...[const SizedBox(width: Sp.x2), const Tag('LIVE', color: AppColors.coral)],
            ]),
            const SizedBox(height: 2),
            Text('${hm(w['duration_min'] as num?)} · ${w['avg_hr'] ?? '—'} bpm · strain ${w['strain'] ?? '—'}',
                style: AppText.captionMuted),
          ])),
          const AppIcon(Icons.chevron_right, size: 18, color: AppColors.inkMuted),
        ]),
      ),
    );
  }
}

/// Live workout — elapsed timer + recording state + Stop. The actual data records
/// via the existing background BLE keepalive (foreground service / iOS restoration),
/// so it keeps recording even if the app is backgrounded; the breakdown is computed
/// server-side on Stop regardless.
class LiveWorkoutScreen extends StatefulWidget {
  final String workoutId;
  final String type;
  const LiveWorkoutScreen({super.key, required this.workoutId, required this.type});
  @override
  State<LiveWorkoutScreen> createState() => _LiveWorkoutScreenState();
}

class _LiveWorkoutScreenState extends State<LiveWorkoutScreen> {
  late final DateTime _start = DateTime.now();
  Timer? _t;
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  String get _elapsed {
    final s = DateTime.now().difference(_start).inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}'
                 : '$m:${sec.toString().padLeft(2, '0')}';
  }

  Future<void> _stop() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() => _ending = true);
    try {
      await api.endWorkout(widget.workoutId);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => WorkoutDetailScreen(id: widget.workoutId)));
    } catch (_) {
      if (mounted) setState(() => _ending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.night,
      body: SafeArea(child: Padding(padding: const EdgeInsets.all(Sp.x5), child: Column(children: [
        const Spacer(),
        Text(widget.type.toUpperCase(), style: AppText.overline.copyWith(color: AppColors.onNightSoft)),
        const SizedBox(height: Sp.x3),
        Text(_elapsed, style: AppText.hero.copyWith(color: AppColors.onNight)),
        const SizedBox(height: Sp.x3),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.coral, shape: BoxShape.circle)),
          const SizedBox(width: Sp.x2),
          Text('Recording', style: AppText.body.copyWith(color: AppColors.onNightSoft)),
        ]),
        const SizedBox(height: Sp.x4),
        Text('Keeps recording in the background — your data is safe even if you leave the app.',
            textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppColors.onNightSoft)),
        const Spacer(),
        SizedBox(width: double.infinity, child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.coral, padding: const EdgeInsets.symmetric(vertical: Sp.x4)),
          onPressed: _ending ? null : _stop,
          child: Text(_ending ? 'Finishing…' : 'Stop workout', style: AppText.label.copyWith(color: Colors.white)),
        )),
        const SizedBox(height: Sp.x4),
      ]))),
    );
  }
}

/// Post-workout breakdown (also the tap target from the list).
class WorkoutDetailScreen extends StatelessWidget {
  final String id;
  const WorkoutDetailScreen({super.key, required this.id});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.bg, elevation: 0, title: Text('Workout', style: AppText.title)),
      body: _WorkoutDetailBody(id: id),
    );
  }
}

class _WorkoutDetailBody extends StatefulWidget {
  final String id;
  const _WorkoutDetailBody({required this.id});
  @override
  State<_WorkoutDetailBody> createState() => _WorkoutDetailBodyState();
}

class _WorkoutDetailBodyState extends State<_WorkoutDetailBody> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  @override
  void initState() { super.initState(); _go(); }
  Future<void> _go() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try { final d = await api.getWorkout(widget.id); if (mounted) setState(() { _d = d; _loading = false; }); }
    catch (_) { if (mounted) setState(() => _loading = false); }
  }
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final d = _d;
    if (d == null) return Center(child: Text('Not found', style: AppText.captionMuted));
    final hr = (d['hr'] as List?)?.map((e) => ((e as Map)['v'] as num?)?.toDouble() ?? 0).where((v) => v > 0).toList() ?? <double>[];
    final z = (d['zones'] as Map?);
    return ListView(padding: const EdgeInsets.all(Sp.x4), children: [
      ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${d['type']}'.toUpperCase(), style: AppText.overline),
        const SizedBox(height: Sp.x2),
        Text(hm(d['duration_min'] as num?), style: AppText.metric),
        const SizedBox(height: Sp.x2),
        Text('avg ${d['avg_hr'] ?? '—'} · max ${d['max_hr'] ?? '—'} bpm · strain ${d['strain'] ?? '—'} · ${d['calories'] ?? 0} kcal',
            style: AppText.captionMuted),
      ]))),
      if (hr.length > 1) ...[
        const SizedBox(height: Sp.x3),
        ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Heart rate', style: AppText.label),
          const SizedBox(height: Sp.x2),
          AreaSpark(hr, color: AppColors.coral, height: 100),
        ]))),
      ],
      if (z != null) ...[
        const SizedBox(height: Sp.x3),
        ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('HR zones', style: AppText.label),
          const SizedBox(height: Sp.x3),
          SegmentBar([
            (z['zone1_min'] as num?)?.toDouble() ?? 0, (z['zone2_min'] as num?)?.toDouble() ?? 0,
            (z['zone3_min'] as num?)?.toDouble() ?? 0, (z['zone4_min'] as num?)?.toDouble() ?? 0,
            (z['zone5_min'] as num?)?.toDouble() ?? 0,
          ], const [AppColors.cool, AppColors.loadDetraining, AppColors.good, AppColors.warn, AppColors.coral], height: 14),
        ]))),
      ],
      if (d['hrr60'] != null) ...[
        const SizedBox(height: Sp.x3),
        ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x2), child: DetailRow(label: 'HR recovery (60s)', value: '${d['hrr60']} bpm'))),
      ],
    ]);
  }
}
