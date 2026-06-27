// Workouts — the training log. Manual start (▶ → pick type → live → end → breakdown)
// and auto-detected efforts both land here. Per timeframe we show an honest training
// summary (time/count/type/zones/calories — no fabricated distance or reps) + the
// list; tap a workout for its full breakdown. Reuses the existing kit.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../activity/live_session_screen.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import '../screens/detail_cards.dart' show hm;

const _exercises = [
  ('run', 'Run', Ic.run), ('cycle', 'Cycle', Ic.activity), ('strength', 'Strength', Ic.fire),
  ('walk', 'Walk', Ic.run), ('swim', 'Swim', Ic.activity), ('cardio', 'Cardio', Ic.pulse),
  ('yoga', 'Yoga', Ic.heart), ('other', 'Other', Ic.activity),
];
const _ranges = ['Today', 'Week', 'Month', '3M'];
const _rangeKey = ['week', 'week', 'month', 'quarter']; // Today filters week to today

// Zone palette (Z1→Z5), shared by the bar + legend.
final _zoneColors = [AppColors.cool, AppColors.loadDetraining, AppColors.good, AppColors.warn, AppColors.coral];

IconData _typeIcon(String? type) {
  for (final e in _exercises) { if (e.$1 == type) return e.$3; }
  return Ic.run;
}

String _typeLabel(String? type) {
  if (type == null || type.isEmpty) return 'Workout';
  return type[0].toUpperCase() + type.substring(1);
}

// Relative-ish date for a session start (local).
String _whenLabel(int? startTs) {
  if (startTs == null || startTs == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(startTs * 1000).toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ap = d.hour < 12 ? 'AM' : 'PM';
  final time = '$h:${d.minute.toString().padLeft(2, '0')} $ap';
  if (diff == 0) return 'Today · $time';
  if (diff == 1) return 'Yesterday · $time';
  const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${mon[d.month - 1]} ${d.day} · $time';
}

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
  final app = context.read<AppState>();
  final api = app.repo;
  if (api == null) return;
  try {
    final w = await api.startWorkout(type);
    final id = w['workout_id'] as String?;
    if (!context.mounted) return;
    // Start the LOCAL live engine (live HR UI + iOS Live Activity + global state)
    // alongside the backend session, then open the interactive live screen.
    app.startWorkout(workoutId: id, type: type);
    Navigator.of(context).push(themedRoute((_) => LiveSessionScreen(workoutId: id, type: type),
    ));
  } catch (_) {/* surfaced as no-op; user can retry */}
}

/// Bottom-sheet type picker (no workout start) — used to confirm/correct an
/// auto-detected workout's type. Returns the chosen type, or null if dismissed.
Future<String?> pickWorkoutType(BuildContext context, {String title = 'Set workout type'}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(R.card))),
    builder: (_) => Padding(
      padding: const EdgeInsets.all(Sp.x5),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: AppText.h2),
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
}

class WorkoutsScreen extends StatefulWidget {
  const WorkoutsScreen({super.key});
  @override
  State<WorkoutsScreen> createState() => _WorkoutsScreenState();
}

class _WorkoutsScreenState extends State<WorkoutsScreen> {
  // Restore the last-selected timeframe (Today/Week/Month/3M) across launches.
  late int _range =
      Prefs.getInt(Prefs.workoutsRange, 0).clamp(0, _ranges.length - 1);
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().repo;
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
                const Spacer(),
                _StartButton(onTap: () => startWorkoutFlow(context).then((_) => _load())),
              ]),
              const SizedBox(height: Sp.x4),
              Align(
                alignment: Alignment.centerLeft,
                child: SegToggle(options: _ranges, index: _range, onChanged: (i) { setState(() => _range = i); Prefs.setInt(Prefs.workoutsRange, i); _load(); }),
              ),
              const SizedBox(height: Sp.x4),
              if (_loading)
                const Padding(padding: EdgeInsets.symmetric(vertical: Sp.x6), child: Center(child: CircularProgressIndicator()))
              else ...[
                if (_range != 0 && summary != null && (summary['count'] ?? 0) > 0) ...[
                  _SummaryHero(summary: summary, range: _ranges[_range], workouts: list),
                  const SizedBox(height: Sp.x4),
                ],
                if (list.isEmpty)
                  ProCard(child: Padding(padding: const EdgeInsets.all(Sp.x6), child: Center(
                    child: Column(children: [
                      AppIcon(Ic.run, size: 32, color: AppColors.inkMuted),
                      const SizedBox(height: Sp.x3),
                      Text('No workouts', style: AppText.label),
                      const SizedBox(height: Sp.x1),
                      Text('Tap Start, or an effort will be auto-detected.', style: AppText.captionMuted, textAlign: TextAlign.center),
                    ]),
                  )))
                else ...[
                  SectionHeader(_range == 0 ? 'Today' : 'Sessions'),
                  for (final w in list) _row(w as Map<String, dynamic>),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Swipe-to-delete wrapper. Live sessions aren't deletable (finish them first).
  // Confirm/correct an auto-detected workout's type → feeds the classifier calibration
  // ledger, and pins the type so re-derivation won't overwrite it.
  Future<void> _correctType(Map<String, dynamic> w) async {
    final id = w['id'] as String?;
    if (id == null) return;
    final t = await pickWorkoutType(context, title: 'Correct workout type');
    if (t == null || !mounted) return;
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try { await api.setWorkoutType(id, t); _load(); } catch (_) {/* retryable */}
  }

  Widget _row(Map<String, dynamic> w) {
    final tile = _WorkoutTile(w, onCorrect: () => _correctType(w));
    if (w['status'] == 'live') return tile;
    return Dismissible(
      key: ValueKey(w['id']),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: Sp.x3),
        padding: const EdgeInsets.only(right: Sp.x6),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(color: AppColors.badSoft, borderRadius: BorderRadius.circular(R.card)),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.delete_outline, size: 20, color: AppColors.bad),
          const SizedBox(width: Sp.x2),
          Text('Delete', style: TextStyle(color: AppColors.bad, fontWeight: FontWeight.w700)),
        ]),
      ),
      confirmDismiss: (_) => _confirmDelete(w['id'] as String),
      child: tile,
    );
  }

  Future<bool> _confirmDelete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete this workout?', style: AppText.title),
        content: Text('It will be removed for good. Auto-detected efforts won’t come back.',
            style: AppText.bodySoft),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete', style: TextStyle(color: AppColors.bad, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok != true || !mounted) return false;
    final api = context.read<AppState>().repo;
    if (api == null) return false;
    try { await api.deleteWorkout(id); _load(); return true; }
    catch (_) { return false; }
  }
}

/// Compact "blazing" Start pill — top-right of the Workouts header. Short, coral,
/// with a warm glow so it reads as the primary action without taking a whole row.
class _StartButton extends StatelessWidget {
  final VoidCallback onTap;
  const _StartButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.coral, AppColors.coralDeep],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(R.pill),
          boxShadow: [
            BoxShadow(color: AppColors.coral.withValues(alpha: 0.45), blurRadius: 16, offset: const Offset(0, 4)),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const AppIcon(Ic.fire, size: 16, color: Colors.white),
          const SizedBox(width: Sp.x2),
          Text('Start', style: AppText.label.copyWith(color: Colors.white)),
        ]),
      ),
    );
  }
}

/// Training-summary hero — total time + count/kcal/avg-strain + zone distribution.
class _SummaryHero extends StatelessWidget {
  final Map<String, dynamic> summary;
  final String range;
  final List<dynamic> workouts;
  const _SummaryHero({required this.summary, required this.range, required this.workouts});

  @override
  Widget build(BuildContext context) {
    final count = (summary['count'] as num?)?.toInt() ?? 0;
    final totalMin = summary['total_min'] as num?;
    final kcal = (summary['total_calories'] as num?)?.toInt() ?? 0;
    final zoneMin = ((summary['zone_min'] as List?) ?? const [])
        .map((e) => (e as num).toDouble()).toList();
    // Average strain across done sessions in view.
    final strains = workouts
        .where((w) => (w as Map)['status'] != 'live')
        .map((w) => ((w as Map)['strain'] as num?)?.toDouble() ?? 0)
        .where((v) => v > 0).toList();
    final avgStrain = strains.isEmpty ? null : strains.reduce((a, b) => a + b) / strains.length;

    return GlowCard(
      padding: const EdgeInsets.all(Sp.x6),
      glow: AppColors.coral,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('TRAINING · ${range.toUpperCase()}', style: AppText.overline),
        const SizedBox(height: Sp.x4),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(hm(totalMin), style: AppText.display),
          const SizedBox(width: Sp.x2),
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('active', style: AppText.bodySoft)),
        ]),
        const SizedBox(height: Sp.x5),
        Row(children: [
          _miniStat('$count', 'workouts'),
          _miniStat('$kcal', 'kcal'),
          _miniStat(avgStrain == null ? '—' : avgStrain.toStringAsFixed(1), 'avg strain'),
        ]),
        // Classifier calibration: how often the auto-detected type matched what you
        // confirmed/corrected. Shown once you've reviewed at least one — tells us (and
        // you) when the activity model needs retraining.
        ...(() {
          final cls = (summary['classifier'] as Map?)?.cast<String, dynamic>();
          final acc = (cls?['accuracy'] as num?)?.toDouble();
          final reviewed = (cls?['reviewed'] as num?)?.toInt() ?? 0;
          if (acc == null || reviewed <= 0) return const <Widget>[];
          return [
            const SizedBox(height: Sp.x5),
            Row(children: [
              AppIcon(Icons.verified_outlined, size: 15, color: AppColors.inkMuted),
              const SizedBox(width: Sp.x2),
              Text('Type accuracy ${(acc * 100).round()}% · $reviewed reviewed', style: AppText.caption),
            ]),
          ];
        })(),
        if (zoneMin.length == 5 && zoneMin.any((v) => v > 0)) ...[
          const SizedBox(height: Sp.x5),
          Text('TIME IN ZONES', style: AppText.overline),
          const SizedBox(height: Sp.x3),
          SegmentBar(zoneMin, _zoneColors, height: 12),
          const SizedBox(height: Sp.x3),
          Wrap(spacing: Sp.x4, runSpacing: Sp.x2, children: [
            for (int i = 0; i < 5; i++)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 9, height: 9, decoration: BoxDecoration(color: _zoneColors[i], shape: BoxShape.circle)),
                const SizedBox(width: Sp.x2),
                Text('Z${i + 1} · ${zoneMin[i].round()}m', style: AppText.caption),
              ]),
          ]),
        ],
      ]),
    );
  }

  Widget _miniStat(String v, String label) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(v, style: AppText.h2),
    Text(label, style: AppText.captionMuted),
  ]));
}

class _WorkoutTile extends StatelessWidget {
  final Map<String, dynamic> w;
  final VoidCallback? onCorrect;
  const _WorkoutTile(this.w, {this.onCorrect});
  @override
  Widget build(BuildContext context) {
    final live = w['status'] == 'live';
    final detected = w['detected'] == true; // auto / auto_live
    final phases = (w['segments'] as List?)?.length ?? 0;
    final strain = (w['strain'] as num?);
    // No worn HR minutes in the window → avg_hr comes back 0 and strain 0. That's
    // not a zero-effort workout, it's missing data (band wasn't syncing). Show it
    // as such instead of a misleading "0.0 strain · 0 bpm".
    final noData = !live && (((w['avg_hr'] as num?) ?? 0) == 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: ProCard(
        onTap: () => Navigator.of(context).push(themedRoute((_) => WorkoutDetailScreen(id: w['id'] as String))),
        padding: const EdgeInsets.all(Sp.x4),
        child: Row(children: [
          Container(padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(color: AppColors.coral.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(R.chip)),
            child: AppIcon(_typeIcon(w['type'] as String?), size: 20, color: AppColors.coral)),
          const SizedBox(width: Sp.x3),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(_typeLabel(w['type'] as String?), style: AppText.label),
              if (live) ...[const SizedBox(width: Sp.x2), Tag('LIVE', color: AppColors.coral)]
              else if (detected) ...[const SizedBox(width: Sp.x2), Tag('DETECTED', color: AppColors.inkMuted)]
              else ...[const SizedBox(width: Sp.x2), Tag('LOGGED', color: AppColors.inkMuted)],
              if (phases > 1) ...[const SizedBox(width: Sp.x2), Text('· $phases phases', style: AppText.captionMuted)],
            ]),
            const SizedBox(height: 2),
            Text('${_whenLabel(w['start_ts'] as int?)} · ${hm(w['duration_min'] as num?)} · ${noData ? 'no HR' : '${w['avg_hr'] ?? '—'} bpm'}',
                style: AppText.captionMuted),
          ])),
          // Correct an auto-detected type (calibration). Manual workouts keep their type.
          if (!live && detected && onCorrect != null) ...[
            GestureDetector(
              onTap: onCorrect,
              behavior: HitTestBehavior.opaque,
              child: Padding(padding: const EdgeInsets.all(6),
                  child: AppIcon(Icons.edit_outlined, size: 16, color: AppColors.inkMuted)),
            ),
          ],
          if (!live) ...[
            noData
                ? Text('No data', style: AppText.captionMuted)
                : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(strain == null ? '—' : strain.toStringAsFixed(1), style: AppText.metricSm.copyWith(fontSize: 18)),
                    Text('strain', style: AppText.captionMuted),
                  ]),
            const SizedBox(width: Sp.x2),
          ],
          AppIcon(Icons.chevron_right, size: 18, color: AppColors.inkMuted),
        ]),
      ),
    );
  }
}


/// Post-workout breakdown (also the tap target from the list).
class WorkoutDetailScreen extends StatelessWidget {
  final String id;
  const WorkoutDetailScreen({super.key, required this.id});
  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete this workout?', style: AppText.title),
        content: Text('It will be removed for good. Auto-detected efforts won’t come back.', style: AppText.bodySoft),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete', style: TextStyle(color: AppColors.bad, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try { await api.deleteWorkout(id); if (context.mounted) Navigator.of(context).pop(); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg, elevation: 0, title: Text('Workout', style: AppText.title),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_outline, color: AppColors.inkMuted),
            tooltip: 'Delete workout',
            onPressed: () => _delete(context),
          ),
        ],
      ),
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
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try { final d = await api.getWorkout(widget.id); if (mounted) setState(() { _d = d; _loading = false; }); }
    catch (_) { if (mounted) setState(() => _loading = false); }
  }

  num? _n(Object? v) => v is num ? v : null;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final d = _d;
    if (d == null) return Center(child: Text('Not found', style: AppText.captionMuted));

    final hr = (d['hr'] as List?)?.map((e) => ((e as Map)['v'] as num?)?.toDouble() ?? 0).where((v) => v > 0).toList() ?? <double>[];
    final bands = (d['zone_bands'] as List?)?.whereType<Map>().toList() ?? const [];
    final curve = (d['recovery_curve'] as List?)?.whereType<Map>().toList() ?? const [];
    final live = d['status'] == 'live';
    final strain = _n(d['strain']);
    // Window had no worn HR minutes → avg_hr 0, strain 0. Missing data, not zero
    // effort: show "no HR recorded" rather than a misleading 0.0 ring.
    final noData = !live && (((d['avg_hr'] as num?) ?? 0) == 0);
    final drift = _n(d['hr_drift_pct']);
    final ttp = _n(d['time_to_peak_min']);
    // Minute-level HR curve only for recent workouts; the summary (avg/max/zones/
    // strain) is permanent in the sessions table and always shows.
    final startTs = d['start_ts'] as int?;
    final workoutRecent = startTs == null ||
        startTs > (DateTime.now().millisecondsSinceEpoch ~/ 1000) - kDetailWindowDays * 86400;

    return ListView(padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x4, Sp.x4, Sp.x10), children: [
      // ── HERO ──
      GlowCard(
        padding: const EdgeInsets.all(Sp.x6),
        glow: AppColors.coral,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppColors.coral.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(R.chip)),
              child: AppIcon(_typeIcon(d['type'] as String?), size: 20, color: AppColors.coral)),
            const SizedBox(width: Sp.x3),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_typeLabel(d['type'] as String?).toUpperCase(), style: AppText.overline),
              Text(_whenLabel(d['start_ts'] as int?), style: AppText.captionMuted),
            ])),
            if (d['source'] == 'auto') Tag('AUTO', color: AppColors.inkMuted),
            if (live) Tag('LIVE', color: AppColors.coral),
          ]),
          const SizedBox(height: Sp.x5),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(hm(d['duration_min'] as num?), style: AppText.display),
              const SizedBox(height: Sp.x1),
              Text('duration', style: AppText.bodySoft),
            ])),
            if (strain != null && !noData)
              RingStat(
                t: (strain / 21).clamp(0.0, 1.0), color: AppColors.coral, size: 92, stroke: 11,
                center: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(strain.toStringAsFixed(1), style: AppText.metricSm),
                  Text('strain', style: AppText.captionMuted),
                ]),
              ),
          ]),
          if (noData) ...[
            const SizedBox(height: Sp.x4),
            Text("No heart-rate data was recorded during this workout — the band wasn't syncing for this window, so strain and zones can't be computed.",
                style: AppText.captionMuted),
          ],
          const SizedBox(height: Sp.x5),
          Row(children: [
            _heroStat(noData ? '—' : '${d['avg_hr'] ?? '—'}', 'avg bpm'),
            _heroStat(noData ? '—' : '${d['max_hr'] ?? '—'}', 'max bpm'),
            _heroStat(noData ? '—' : '${d['min_hr'] ?? '—'}', 'min bpm'),
            _heroStat('${d['calories'] ?? 0}', 'kcal'),
            // Steps are recorded only for manual workouts ridden by the live
            // 100 Hz stream; older/auto sessions have none.
            if ((d['steps'] as num?) != null && (d['steps'] as num) > 0)
              _heroStat('${d['steps']}', 'steps'),
          ]),
        ]),
      ),

      // ── HEART RATE ── (minute curve, recent workouts only)
      if (!workoutRecent) ...[
        const SizedBox(height: Sp.x4),
        const DetailRetentionNote(what: 'minute-by-minute heart rate'),
      ] else if (hr.length > 1) ...[
        const SizedBox(height: Sp.x4),
        ProCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Heart rate', style: AppText.label),
          const SizedBox(height: Sp.x3),
          AreaSpark(hr, color: AppColors.coral, height: 110),
          if (drift != null || ttp != null) ...[
            const SizedBox(height: Sp.x4),
            Divider(height: 1, color: AppColors.divider),
            const SizedBox(height: Sp.x2),
            if (ttp != null)
              DetailRow(label: 'Time to peak HR', value: '${ttp.toInt()} min'),
            if (drift != null)
              DetailRow(
                label: 'Cardiac drift',
                value: '${drift > 0 ? '+' : ''}${drift.toStringAsFixed(1)}%',
                trailing: AppIcon(drift > 3 ? Ic.up : Ic.down, size: 15,
                    color: drift > 3 ? AppColors.warn : AppColors.good),
              ),
          ],
        ])),
      ],

      // ── ZONES (bar + legend with bpm ranges + %) ──
      if (bands.isNotEmpty && bands.any((b) => (b['min'] as num? ?? 0) > 0)) ...[
        const SizedBox(height: Sp.x4),
        ProCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Time in heart-rate zones', style: AppText.label),
          const SizedBox(height: Sp.x3),
          SegmentBar([for (final b in bands) (b['min'] as num?)?.toDouble() ?? 0], _zoneColors, height: 16),
          const SizedBox(height: Sp.x4),
          for (int i = 0; i < bands.length; i++) ...[
            if (i > 0) const SizedBox(height: Sp.x3),
            Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(
                color: _zoneColors[i], borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: Sp.x3),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Z${bands[i]['zone']} · ${bands[i]['name']}', style: AppText.body),
                Text('${bands[i]['lo']}–${bands[i]['hi']} bpm', style: AppText.captionMuted),
              ])),
              Text('${(bands[i]['min'] as num?)?.round() ?? 0}m', style: AppText.label),
              const SizedBox(width: Sp.x3),
              SizedBox(width: 38, child: Text('${bands[i]['pct'] ?? 0}%',
                  textAlign: TextAlign.right, style: AppText.captionMuted)),
            ]),
          ],
        ])),
      ],

      // ── RECOVERY CURVE ──
      if (curve.isNotEmpty) ...[
        const SizedBox(height: Sp.x4),
        ProCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Heart-rate recovery', style: AppText.label),
          const SizedBox(height: Sp.x1),
          Text('How fast your heart rate dropped after the effort — faster is fitter.',
              style: AppText.captionMuted),
          const SizedBox(height: Sp.x4),
          Row(children: [
            for (final c in curve)
              _heroStat('−${(c['drop'] as num?)?.round() ?? 0}', '${((c['sec'] as num?)?.toInt() ?? 0) ~/ 60} min'),
          ]),
        ])),
      ] else if (d['hrr60'] != null) ...[
        const SizedBox(height: Sp.x4),
        ProCard(child: DetailRow(label: 'HR recovery (60s)', value: '−${d['hrr60']} bpm')),
      ],

      // ── OUTPUT ──
      if (_hasOutput(d)) ...[
        const SizedBox(height: Sp.x4),
        ProCard(child: Column(children: [
          if (d['steps'] != null && (d['steps'] as num) > 0)
            DetailRow(label: 'Steps', value: '${d['steps']}'),
          if (d['cadence_spm'] != null)
            DetailRow(label: 'Cadence', value: '${d['cadence_spm']} spm'),
          DetailRow(label: 'Active calories', value: '${d['calories'] ?? 0} kcal'),
          if (d['coverage_pct'] != null)
            DetailRow(label: 'Wrist coverage', value: '${d['coverage_pct']}%'),
        ])),
      ],
    ]);
  }

  bool _hasOutput(Map<String, dynamic> d) =>
      (d['steps'] != null && (d['steps'] as num) > 0) || d['cadence_spm'] != null ||
      d['coverage_pct'] != null || d['calories'] != null;

  Widget _heroStat(String v, String label) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(v, style: AppText.metricSm.copyWith(fontSize: 18)),
    Text(label, style: AppText.captionMuted),
  ]));
}
