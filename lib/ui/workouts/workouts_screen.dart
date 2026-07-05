// Workouts — the training log, on the NEW design language. A bento activity
// feed (numbers-first cards: big duration, strain dial, zone bar, inline PR
// badge; live sessions get the board's ink tile) grouped by week, an ink
// training-summary hero per timeframe, and a numbers-first detail screen
// (huge tabular BigStats bento → route + splits → HR chart with zone bands →
// zones → HRR). Manual start (▶ → pick type → live → end → finish card) and
// auto-detected efforts both land here. Depth comes from elevation and tone —
// no glow anywhere.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../../state/units_controller.dart';
import '../../models/payloads.dart';
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../activity/live_session_screen.dart';
import '../../theme/theme_switcher.dart';
import '../design/design.dart';
import '../kit/route_map.dart';
import '../screens/detail_cards.dart' show hm;
import '../../gps/route_models.dart';
import 'workout_types.dart';

const _ranges = ['Today', 'Week', 'Month', '3M'];
const _rangeKey = [
  'week',
  'week',
  'month',
  'quarter',
]; // Today filters week to today

String _dayLabel(int? startTs) {
  if (startTs == null || startTs == 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(startTs * 1000).toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const mon = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${mon[d.month - 1]} ${d.day}';
}

String _clockLabel(int? startTs) {
  if (startTs == null || startTs == 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(startTs * 1000).toLocal();
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.hour}:$mm';
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
  const mon = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${mon[d.month - 1]} ${d.day} · $time';
}

/// Bottom-sheet exercise picker → starts a workout → opens the live screen.
Future<void> startWorkoutFlow(BuildContext context) async {
  final type = await showModalBottomSheet<String>(
    context: context,
    builder: (_) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(Sp.x5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Start a workout', style: AppText.h2),
            const SizedBox(height: Sp.x4),
            Builder(builder: workoutTypeGrid),
            const SizedBox(height: Sp.x4),
          ],
        ),
      ),
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
    // Start the LOCAL live engine (live HR UI + iOS Live Activity + global
    // state) alongside the backend session, then open the interactive screen.
    app.startWorkout(workoutId: id, type: type);
    Navigator.of(
      context,
    ).push(themedRoute((_) => LiveSessionScreen(workoutId: id, type: type)));
  } catch (_) {
    /* surfaced as no-op; user can retry */
  }
}

/// Bottom-sheet type picker (no workout start) — used to confirm/correct an
/// auto-detected workout's type. Returns the chosen type, or null if dismissed.
Future<String?> pickWorkoutType(
  BuildContext context, {
  String title = 'Set workout type',
}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (_) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(Sp.x5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppText.h2),
            const SizedBox(height: Sp.x4),
            Builder(builder: workoutTypeGrid),
            const SizedBox(height: Sp.x4),
          ],
        ),
      ),
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
  late int _range = Prefs.getInt(
    Prefs.workoutsRange,
    0,
  ).clamp(0, _ranges.length - 1);
  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _suggestions = const [];
  RecordsData? _records; // for inline PR badges in the feed
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
      List<Map<String, dynamic>> sug = const [];
      try {
        sug = await LocalDb.activeWorkoutSuggestions();
      } catch (_) {}
      RecordsData? recs;
      try {
        recs = RecordsData.fromJson(await api.getRecords());
      } catch (_) {}
      if (mounted) {
        setState(() {
          _data = d;
          _suggestions = sug;
          _records = recs;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// Confirm an auto-detected suggestion → create a completed session, then
  /// drop the suggestion and refresh.
  Future<void> _confirmSuggestion(Map<String, dynamic> s) async {
    final start = (s['start_ts'] as num?)?.toInt() ?? 0;
    await LocalDb.putSession({
      'id': 'auto:$start',
      'start_ts': start,
      'end_ts': (s['end_ts'] as num?)?.toInt(),
      'type': (s['sport'] as String?) ?? 'cardio',
      'status': 'done',
      'duration_min': (s['duration_min'] as num?)?.toInt(),
      'max_hr': (s['peak_bpm'] as num?)?.toInt(),
      'source': 'auto',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await LocalDb.dismissWorkoutSuggestion(s['id'] as String);
    await _load();
  }

  Future<void> _dismissSuggestion(Map<String, dynamic> s) async {
    await LocalDb.dismissWorkoutSuggestion(s['id'] as String);
    await _load();
  }

  // LOCAL calendar day — "today's workouts" must match the local day model
  // (a UTC comparison shifted early-morning sessions into yesterday's bucket).
  bool _isToday(int startTs) =>
      dayLabelOf(DateTime.fromMillisecondsSinceEpoch(startTs * 1000)) ==
      todayLabel();

  @override
  Widget build(BuildContext context) {
    final all = (_data?['workouts'] as List?) ?? const [];
    final list = _range == 0
        ? all
              .where((w) => _isToday((w as Map)['start_ts'] as int? ?? 0))
              .toList()
        : all;
    final summary = (_data?['summary'] as Map?)?.cast<String, dynamic>();

    return AppScaffold(
      title: 'Workouts',
      actions: [_StartButton(onTap: () => startWorkoutFlow(context).then((_) => _load()))],
      header: SegmentedControl(
        options: _ranges,
        index: _range,
        expanded: true,
        onChanged: (i) {
          setState(() => _range = i);
          Prefs.setInt(Prefs.workoutsRange, i);
          _load();
        },
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.accent,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, 120),
          children: [
            if (!_loading && _suggestions.isNotEmpty) ...[
              const SectionHeader('Suggested workouts'),
              for (final s in _suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x3),
                  child: _SuggestionCard(
                    s: s,
                    onConfirm: () => _confirmSuggestion(s),
                    onDismiss: () => _dismissSuggestion(s),
                  ),
                ),
              const SizedBox(height: Sp.x3),
            ],
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Sp.x4),
                child: Skeleton.tileRow(rows: 3),
              )
            else ...[
              if (_range != 0 &&
                  summary != null &&
                  (summary['count'] ?? 0) > 0) ...[
                TrainingSummaryCard(
                  summary: summary,
                  range: _ranges[_range],
                  workouts: list,
                ).dsEnter(),
                const SizedBox(height: Sp.x4),
              ],
              if (list.isEmpty)
                StateCard(
                  icon: Ic.run,
                  title: 'No workouts',
                  message: 'Tap Start, or an effort will be auto-detected.',
                  actionLabel: 'Start a workout',
                  onAction: () => startWorkoutFlow(context).then((_) => _load()),
                )
              else
                ..._feed(list.cast<Map<String, dynamic>>()),
            ],
          ],
        ),
      ),
    );
  }

  /// The activity feed — grouped by week (a [SectionHeader] per group), each
  /// session a [WorkoutFeedCard]. Today's filter shows one "Today" group.
  List<Widget> _feed(List<Map<String, dynamic>> list) {
    final topWorkout = _records?.record('top_workout')?.value;
    final mostSteps = _records?.record('most_steps')?.value;

    // Ordered week groups (newest first). "Today" filter → one group.
    final groups = <String, List<Map<String, dynamic>>>{};
    final order = <String>[];
    void add(String label, Map<String, dynamic> w) {
      (groups[label] ??= (order..add(label), <Map<String, dynamic>>[]).$2)
          .add(w);
    }

    if (_range == 0) {
      for (final w in list) {
        add('Today', w);
      }
    } else {
      for (final w in list) {
        add(_weekLabel(w['start_ts'] as int?), w);
      }
    }

    final out = <Widget>[];
    var idx = 0;
    for (final label in order) {
      out.add(SectionHeader(label));
      for (final w in groups[label]!) {
        out.add(_row(w, idx++, topWorkout: topWorkout, mostSteps: mostSteps));
      }
      out.add(const SizedBox(height: Sp.x3));
    }
    return out;
  }

  /// Week bucket label for a session start (epoch seconds).
  String _weekLabel(int? startTs) {
    if (startTs == null || startTs == 0) return 'Earlier';
    final d = DateTime.fromMillisecondsSinceEpoch(startTs * 1000).toLocal();
    final now = DateTime.now();
    DateTime weekStart(DateTime x) {
      final day = DateTime(x.year, x.month, x.day);
      return day.subtract(Duration(days: (day.weekday + 6) % 7)); // Monday
    }

    final thisWeek = weekStart(now);
    final wk = weekStart(d);
    final diffWeeks = thisWeek.difference(wk).inDays ~/ 7;
    if (diffWeeks <= 0) return 'This week';
    if (diffWeeks == 1) return 'Last week';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return 'Week of ${months[wk.month - 1]} ${wk.day}';
  }

  Widget _row(
    Map<String, dynamic> w,
    int index, {
    num? topWorkout,
    num? mostSteps,
  }) {
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: WorkoutFeedCard(
        w,
        topWorkout: topWorkout,
        mostSteps: mostSteps,
        entranceIndex: index,
        onTap: () => Navigator.of(context).push(
          themedRoute((_) => WorkoutDetailScreen(id: w['id'] as String)),
        ),
        onLongPress: w['status'] == 'live' ? null : () => _exportCard(w),
      ),
    );
    if (w['status'] == 'live') return tile;
    return Dismissible(
      key: ValueKey(w['id']),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: Sp.x3),
        padding: const EdgeInsets.only(right: Sp.x6),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: AppColors.criticalSoft,
          borderRadius: BorderRadius.circular(R.card),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, size: 20, color: AppColors.critical),
            const SizedBox(width: Sp.x2),
            Text(
              'Delete',
              style: TextStyle(
                color: AppColors.critical,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(w['id'] as String),
      child: tile,
    );
  }

  /// Long-press → the shareable finish card for a past session.
  void _exportCard(Map<String, dynamic> w) {
    final snap = WorkoutFinishSnapshot(
      type: (w['type'] as String?) ?? 'other',
      duration: Duration(minutes: (w['duration_min'] as num?)?.toInt() ?? 0),
      peakHr: (w['max_hr'] as num?)?.toInt() ?? 0,
      calories: ((w['calories'] as num?) ?? 0).toDouble(),
      strain: ((w['strain'] as num?) ?? 0).toDouble(),
      steps: (w['steps'] as num?)?.toInt() ?? 0,
    );
    Navigator.of(context).push(
      themedRoute(
        (_) => WorkoutFinishScreen(id: w['id'] as String, snapshot: snap),
      ),
    );
  }

  Future<bool> _confirmDelete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete this workout?', style: AppText.title),
        content: Text(
          'It will be removed for good. Auto-detected efforts won’t come back.',
          style: AppText.bodySoft,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete',
              style: TextStyle(
                color: AppColors.critical,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return false;
    final api = context.read<AppState>().repo;
    if (api == null) return false;
    try {
      await api.deleteWorkout(id);
      _load();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Solid ember Start pill — top-right of the Workouts header. Restrained:
/// brand accent + standard elevation, no gradient/glow.
class _StartButton extends StatelessWidget {
  final VoidCallback onTap;
  const _StartButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Pressable(
      pressedScale: 0.94,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(R.pill),
          boxShadow: Elevation.shadows(1, dark: AppColors.isDark),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_arrow_rounded, size: 18, color: Colors.white),
            const SizedBox(width: Sp.x1),
            Text('Start', style: AppText.label.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// An opt-in auto-detected workout the user can confirm (→ logs a session) or
/// dismiss. We never auto-log: this is "did you work out?", not a silent write.
class _SuggestionCard extends StatelessWidget {
  final Map<String, dynamic> s;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;
  const _SuggestionCard({
    required this.s,
    required this.onConfirm,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final start = (s['start_ts'] as num?)?.toInt();
    final dur = (s['duration_min'] as num?)?.toInt();
    final avg = (s['avg_bpm'] as num?)?.toInt();
    final peak = (s['peak_bpm'] as num?)?.toInt();
    final sport = (s['sport'] as String?) ?? 'cardio';
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            workoutTypeOsIcon(sport) != null
                ? OsAppIcon(workoutTypeOsIcon(sport)!, size: 28)
                : AppIcon(workoutTypeIcon(sport), size: 18, color: AppColors.accent),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Did you work out?', style: AppText.title),
                  const SizedBox(height: 1),
                  Text(
                    '${_whenLabel(start)} · ${dur ?? '—'} min'
                    '${avg != null ? ' · avg $avg' : ''}'
                    '${peak != null ? ' · peak $peak bpm' : ''}',
                    style: AppText.captionMuted,
                  ),
                ],
              ),
            ),
            InfoDot(
              title: 'Auto-detected effort',
              body:
                  'We spotted a stretch of elevated heart rate that looks like '
                  'a workout. Confirm to log it — we never log one silently.',
            ),
          ]),
          const SizedBox(height: Sp.x3),
          Row(children: [
            Expanded(
              child: FilledButton(onPressed: onConfirm, child: const Text('Log it')),
            ),
            const SizedBox(width: Sp.x3),
            TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
          ]),
        ],
      ),
    );
  }
}

/// TrainingSummaryCard — the timeframe hero as the board's INK tile: total
/// active time as a huge tabular figure, count / kcal / avg bpm / avg strain
/// as tone-aware mini stats, then the zone-distribution bar + legend.
/// Pure + testable: everything comes in via the summary map. The explanation
/// lives behind the (i).
class TrainingSummaryCard extends StatelessWidget {
  final Map<String, dynamic> summary;
  final String range;
  final List<dynamic> workouts;
  const TrainingSummaryCard({
    super.key,
    required this.summary,
    required this.range,
    required this.workouts,
  });

  @override
  Widget build(BuildContext context) {
    final count = (summary['count'] as num?)?.toInt() ?? 0;
    final totalMin = summary['total_min'] as num?;
    final kcal = (summary['total_calories'] as num?)?.toInt() ?? 0;
    final zoneMin = ((summary['zone_min'] as List?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList();
    final zoneColors = [for (var i = 0; i < zoneMin.length; i++) AppColors.zone(i)];
    // Average strain / HR across done sessions in view.
    final strains = workouts
        .where((w) => (w as Map)['status'] != 'live')
        .map((w) => ((w as Map)['strain'] as num?)?.toDouble() ?? 0)
        .where((v) => v > 0)
        .toList();
    final avgStrain = strains.isEmpty
        ? null
        : strains.reduce((a, b) => a + b) / strains.length;
    final avgBpms = workouts
        .where((w) => (w as Map)['status'] != 'live')
        .map((w) => ((w as Map)['avg_hr'] as num?)?.toDouble() ?? 0)
        .where((v) => v > 0)
        .toList();
    final avgBpm = avgBpms.isEmpty
        ? null
        : (avgBpms.reduce((a, b) => a + b) / avgBpms.length).round();
    final cls = (summary['classifier'] as Map?)?.cast<String, dynamic>();
    final acc = (cls?['accuracy'] as num?)?.toDouble();
    final reviewed = (cls?['reviewed'] as num?)?.toInt() ?? 0;

    return BentoTile(
      tone: BentoTone.ink,
      accent: DomainAccent.strain,
      padding: const EdgeInsets.all(Sp.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: TileHeader('Training · $range',
                      icon: Ic.strain, osIcon: OsIcon.workouts)),
              InfoDot(
                title: 'Training summary',
                body:
                    'Everything you logged this ${range.toLowerCase()}: total '
                    'active time, calories, average heart rate and strain, and '
                    'how the time split across your heart-rate zones.',
                methodNote: acc != null && reviewed > 0
                    ? 'Auto-type accuracy ${(acc * 100).round()}% over $reviewed reviewed'
                    : null,
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: hm(totalMin),
            size: BigStatSize.xl,
            caption: 'active this ${range.toLowerCase()}',
          ),
          const SizedBox(height: Sp.x4),
          Row(
            children: [
              _miniStat(context, '$count', 'workouts'),
              _miniStat(context, '$kcal', 'kcal'),
              _miniStat(context, avgBpm == null ? '—' : '$avgBpm', 'avg bpm'),
              _miniStat(
                context,
                avgStrain == null ? '—' : avgStrain.toStringAsFixed(1),
                'avg strain',
              ),
            ],
          ),
          if (zoneMin.length == 5 && zoneMin.any((v) => v > 0)) ...[
            const SizedBox(height: Sp.x4),
            SegmentBar(zoneMin, zoneColors, height: 12),
            const SizedBox(height: Sp.x3),
            Builder(builder: (context) {
              final tone = ToneScope.of(context);
              return Wrap(
                spacing: Sp.x4,
                runSpacing: Sp.x2,
                children: [
                  for (int i = 0; i < 5; i++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: zoneColors[i],
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: Sp.x2),
                        Text(
                          'Z${i + 1} · ${zoneMin[i].round()}m',
                          style: AppText.caption.copyWith(color: tone.fgMuted),
                        ),
                      ],
                    ),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _miniStat(BuildContext context, String v, String label) => Expanded(
    child: Builder(builder: (context) {
      final tone = ToneScope.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(v, style: AppText.metricSm.copyWith(fontSize: 20, color: tone.fg)),
          Text(label, style: AppText.captionMuted.copyWith(color: tone.fgMuted)),
        ],
      );
    }),
  );
}

/// WorkoutFeedCard — one session in the bento activity feed. Numbers-first:
/// the duration is the big tabular figure, the strain dial sits beside it,
/// the meta line whispers, the zone bar closes the card, and a PR pill pops
/// inline when this session set a record. A LIVE session becomes the board's
/// ink tile so it reads as the one hot card in the feed. Pure + testable.
class WorkoutFeedCard extends StatelessWidget {
  final Map<String, dynamic> w;
  final num? topWorkout; // record strain, for the inline PR badge
  final num? mostSteps; // record steps
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final int? entranceIndex;
  const WorkoutFeedCard(
    this.w, {
    super.key,
    this.topWorkout,
    this.mostSteps,
    this.onTap,
    this.onLongPress,
    this.entranceIndex,
  });

  bool get _isTopWorkout {
    final s = (w['strain'] as num?);
    return s != null &&
        topWorkout != null &&
        s > 0 &&
        (s - topWorkout!).abs() < 0.15;
  }

  bool get _isMostSteps {
    final s = (w['steps'] as num?) ?? 0;
    return mostSteps != null && s > 0 && (s - mostSteps!).abs() < 1.5;
  }

  @override
  Widget build(BuildContext context) {
    final live = w['status'] == 'live';
    final detected = w['detected'] == true; // auto / auto_live
    final strain = (w['strain'] as num?);
    // Missing data = the joined 1 Hz HR is empty AND no strain was recorded
    // live (avg_hr alone also fires for pruned-but-real old workouts).
    final noData = !live &&
        (((w['avg_hr'] as num?) ?? 0) == 0) &&
        (((w['strain'] as num?) ?? 0) == 0);
    final zoneMin = [
      for (final z in ((w['zone_min'] as List?) ?? const []))
        (z as num?)?.toDouble() ?? 0.0,
    ];
    final zoneColors = [
      for (int i = 0; i < zoneMin.length; i++) AppColors.zone(i),
    ];
    final hasZones = zoneMin.any((v) => v > 0);
    final pr = !live && (_isTopWorkout || _isMostSteps);
    final avgHr = (w['avg_hr'] as num?)?.round();
    final kcal = (w['calories'] as num?)?.round() ?? 0;

    final card = BentoTile(
      tone: live ? BentoTone.ink : BentoTone.paper,
      accent: DomainAccent.strain,
      padding: const EdgeInsets.all(Sp.x4),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Builder(builder: (context) {
        final tone = ToneScope.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  // Glyph: 10 + 18 + 10; art: 2 + 34 + 2 — same 38px chip.
                  padding: EdgeInsets.all(
                      workoutTypeOsIcon(w['type'] as String?) != null ? 2 : 10),
                  decoration: BoxDecoration(
                    color: tone.accent.withValues(alpha: live ? 0.22 : 0.12),
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child: workoutTypeOsIcon(w['type'] as String?) != null
                      ? OsAppIcon(workoutTypeOsIcon(w['type'] as String?)!, size: 34)
                      : AppIcon(
                          workoutTypeIcon(w['type'] as String?),
                          size: 18,
                          color: tone.accent,
                        ),
                ),
                const SizedBox(width: Sp.x3),
                Flexible(
                  child: Text(
                    workoutTypeLabel(w['type'] as String?),
                    style: AppText.title.copyWith(color: tone.fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (live) ...[
                  const SizedBox(width: Sp.x2),
                  const StatusChip('LIVE', tone: ChipTone.accent),
                ] else if (detected) ...[
                  const SizedBox(width: Sp.x2),
                  const Tag('auto'),
                ],
                const Spacer(),
                AppIcon(Ic.arrowRight, size: 15, color: tone.fgFaint),
              ],
            ),
            const SizedBox(height: Sp.x3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: BigStat(
                    value: hm(w['duration_min'] as num?),
                    caption:
                        '${_dayLabel(w['start_ts'] as int?)} · ${_clockLabel(w['start_ts'] as int?)}'
                        '${avgHr != null && avgHr > 0 ? ' · $avgHr bpm' : ''}'
                        '${kcal > 0 ? ' · $kcal kcal' : ''}',
                  ),
                ),
                const SizedBox(width: Sp.x3),
                if (!live && !detected)
                  (noData
                      ? Text('No data',
                          style: AppText.captionMuted
                              .copyWith(color: tone.fgMuted))
                      : ArcGauge(
                          value: strain == null
                              ? double.nan
                              : (strain / 21).clamp(0.0, 1.0).toDouble(),
                          color: tone.accent,
                          size: 54,
                          stroke: 6,
                          sweepFraction: 0.75,
                          animate: false,
                          center: Text(
                            strain == null ? '—' : strain.toStringAsFixed(1),
                            style: AppText.metricSm
                                .copyWith(fontSize: 13, color: tone.fg),
                          ),
                        )),
              ],
            ),
            if (hasZones) ...[
              const SizedBox(height: Sp.x3),
              SegmentBar(zoneMin, zoneColors, height: 8),
            ],
            if (pr) ...[
              const SizedBox(height: Sp.x3),
              Row(
                children: [
                  PrBadge(_isTopWorkout ? 'PR · top workout' : 'PR · most steps'),
                ],
              ),
            ],
          ],
        );
      }),
    );
    if (entranceIndex == null) return card;
    return card.dsEnter(index: entranceIndex!);
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
        content: Text(
          'It will be removed for good. Auto-detected efforts won’t come back.',
          style: AppText.bodySoft,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete',
              style: TextStyle(
                color: AppColors.critical,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      await api.deleteWorkout(id);
      if (context.mounted) Navigator.of(context).pop();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Workout',
      largeTitle: false,
      actions: [
        RoundIconButton(Ic.trash, onTap: () => _delete(context)),
      ],
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
  WorkoutRoute? _route;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      final d = await api.getWorkout(widget.id);
      WorkoutRoute? route;
      try {
        route = await api.getWorkoutRoute(widget.id);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _d = d;
          _route = route;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _correctType() async {
    final d = _d;
    if (d == null) return;
    final id = d['id'] as String?;
    if (id == null) return;
    final t = await pickWorkoutType(context, title: 'Correct workout type');
    if (t == null || !mounted) return;
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      await api.setWorkoutType(id, t);
      await _go();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x10),
        children: [
          Skeleton.hero(),
          const SizedBox(height: Sp.x4),
          Skeleton.chart(),
          const SizedBox(height: Sp.x4),
          Skeleton.tileRow(rows: 2),
        ],
      );
    }
    final d = _d;
    if (d == null || d.isEmpty) {
      return Center(child: Text('Not found', style: AppText.captionMuted));
    }
    final units = context.watch<UnitsController>();
    final route = _route;
    return WorkoutDetailContent(
      d: d,
      route: route,
      maxHr: context.read<AppState>().maxHr,
      distanceLabel: route != null && route.hasPath
          ? units.distance(route.distanceMeters)
          : null,
      onCorrectType: d['source'] == 'auto' ? _correctType : null,
    );
  }
}

/// WorkoutDetailContent — the pure breakdown body: glanceable hero (duration +
/// strain gauge + stat row), route + splits, the HR chart with zone bands and
/// replay, the zones table, and the recovery curve. Testable without AppState
/// (pass route: null to skip the map).
class WorkoutDetailContent extends StatelessWidget {
  final Map<String, dynamic> d;
  final WorkoutRoute? route;
  final int maxHr;

  /// Preformatted distance (unit-aware), or null when there is no route.
  final String? distanceLabel;

  /// Non-null only for auto-detected sessions (shows the "fix type" affordance).
  final VoidCallback? onCorrectType;

  const WorkoutDetailContent({
    super.key,
    required this.d,
    this.route,
    required this.maxHr,
    this.distanceLabel,
    this.onCorrectType,
  });

  num? _n(Object? v) => v is num ? v : null;

  @override
  Widget build(BuildContext context) {
    final hrSeries = (d['hr'] as List?)?.whereType<Map>().toList() ?? const [];
    final hr = hrSeries
        .map((e) => (e['v'] as num?)?.toDouble() ?? 0)
        .where((v) => v > 0)
        .toList();
    final hrPoints = [
      for (final e in hrSeries)
        if (((e['t'] as num?)?.toDouble() != null) &&
            ((e['v'] as num?)?.toDouble() != null) &&
            ((e['v'] as num?)?.toDouble() ?? 0) > 0)
          TimeSeriesPoint(
            (e['t'] as num).toDouble(),
            (e['v'] as num).toDouble(),
          ),
    ];
    final bands =
        (d['zone_bands'] as List?)?.whereType<Map>().toList() ?? const [];
    final curve =
        (d['recovery_curve'] as List?)?.whereType<Map>().toList() ?? const [];
    final live = d['status'] == 'live';
    final strain = _n(d['strain']);
    final noData = !live &&
        hrPoints.isEmpty &&
        (((d['avg_hr'] as num?) ?? 0) == 0) &&
        ((strain ?? 0) == 0);
    final startTs = d['start_ts'] as int?;
    final endTs = d['end_ts'] as int?;
    // Minute-level HR curve only for recent workouts; the summary is permanent.
    final workoutRecent = startTs == null ||
        startTs >
            (DateTime.now().millisecondsSinceEpoch ~/ 1000) -
                kDetailWindowDays * 86400;

    final r = route;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x10),
      children: dsStaggered([
        _hero(live: live, strain: strain, noData: noData),

        // ── ROUTE ── (run/ride/walk with recorded GPS)
        if (r != null && r.hasPath) ...[
          const SizedBox(height: Sp.x3),
          RouteCard(route: r, maxHr: maxHr),
          const SizedBox(height: Sp.x3),
          SplitsTable(route: r, maxHr: maxHr),
        ],

        // ── HEART RATE ── (minute curve, recent workouts only)
        if (!workoutRecent) ...[
          const SizedBox(height: Sp.x3),
          const DetailRetentionNote(what: 'minute-by-minute heart rate'),
        ] else if (hrPoints.length > 1) ...[
          const SizedBox(height: Sp.x3),
          _hrChartCard(hrPoints, hr, bands, startTs, endTs),
        ],

        // ── ZONES ──
        if (bands.isNotEmpty &&
            bands.any((b) => (b['min'] as num? ?? 0) > 0)) ...[
          const SizedBox(height: Sp.x3),
          _zonesCard(bands),
        ],

        // ── RECOVERY CURVE ──
        if (curve.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          _hrrCard(curve),
        ] else if (d['hrr60'] != null) ...[
          const SizedBox(height: Sp.x3),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x2,
            ),
            child: ListRow(
              icon: Ic.heart,
              osIcon: OsIcon.heartRateRecovery,
              title: 'HR recovery (60s)',
              value: '−${d['hrr60']} bpm',
            ),
          ),
        ],
      ]),
    );
  }

  /// The detail hero — the board's INK tile: huge tabular duration beside the
  /// strain dial, then a row of tone-aware hero stats (avg/max bpm, kcal,
  /// distance or steps). Depth via tone + elevation, no glow.
  Widget _hero({required bool live, num? strain, required bool noData}) {
    final steps = (d['steps'] as num?)?.toInt() ?? 0;
    return BentoTile(
      tone: BentoTone.ink,
      accent: DomainAccent.strain,
      padding: const EdgeInsets.all(Sp.x5),
      child: Builder(builder: (context) {
        final tone = ToneScope.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  // Glyph: 10 + 20 + 10; art: 2 + 36 + 2 — same 40px chip.
                  padding: EdgeInsets.all(
                      workoutTypeOsIcon(d['type'] as String?) != null ? 2 : 10),
                  decoration: BoxDecoration(
                    color: tone.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(R.chip),
                  ),
                  child: workoutTypeOsIcon(d['type'] as String?) != null
                      ? OsAppIcon(workoutTypeOsIcon(d['type'] as String?)!, size: 36)
                      : AppIcon(
                          workoutTypeIcon(d['type'] as String?),
                          size: 20,
                          color: tone.accent,
                        ),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        workoutTypeLabel(d['type'] as String?).toUpperCase(),
                        style: AppText.overline.copyWith(color: tone.fgFaint),
                      ),
                      Text(
                        _whenLabel(d['start_ts'] as int?),
                        style: AppText.captionMuted.copyWith(color: tone.fgMuted),
                      ),
                    ],
                  ),
                ),
                if (d['source'] == 'auto') const Tag('auto'),
                if (live) ...[
                  const SizedBox(width: Sp.x2),
                  const StatusChip('LIVE', tone: ChipTone.accent),
                ],
                if (onCorrectType != null) ...[
                  const SizedBox(width: Sp.x2),
                  Pressable(
                    pressedScale: 0.9,
                    onTap: onCorrectType,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: AppIcon(Ic.edit, size: 16, color: tone.fgMuted),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: Sp.x5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hm(d['duration_min'] as num?),
                        style: AppText.hero
                            .copyWith(fontSize: 48, color: tone.fg),
                        maxLines: 1,
                      ),
                      const SizedBox(height: Sp.x1),
                      Row(
                        children: [
                          Text('DURATION',
                              style: AppText.overline
                                  .copyWith(color: tone.fgFaint)),
                          InfoDot(
                            title: 'Strain',
                            body:
                                'Cardiovascular load for this session on a 0–21 '
                                'scale, from time spent in your heart-rate zones.',
                            methodNote:
                                'Banister/Edwards TRIMP, squashed to 0–21',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (strain != null && !noData)
                  ArcGauge(
                    value: (strain / 21).clamp(0.0, 1.0).toDouble(),
                    color: tone.accent,
                    size: 96,
                    stroke: 10,
                    sweepFraction: 0.75,
                    endDot: true,
                    center: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(strain.toStringAsFixed(1),
                            style: AppText.metricSm
                                .copyWith(fontSize: 20, color: tone.fg)),
                        Text('STRAIN',
                            style: AppText.overline.copyWith(
                                fontSize: 8, color: tone.fgFaint)),
                      ],
                    ),
                  ),
              ],
            ),
            if (noData) ...[
              const SizedBox(height: Sp.x3),
              Row(
                children: [
                  const StatusChip('No heart-rate data', tone: ChipTone.warn),
                  InfoDot(
                    title: 'No heart-rate data',
                    body:
                        'The band wasn\'t syncing during this window, so strain '
                        'and zones can\'t be computed for this workout.',
                  ),
                ],
              ),
            ],
            const SizedBox(height: Sp.x4),
            Row(
              children: [
                _toneStat(tone, noData ? '—' : '${d['avg_hr'] ?? '—'}', 'avg bpm'),
                _toneStat(tone, noData ? '—' : '${d['max_hr'] ?? '—'}', 'max bpm'),
                _toneStat(tone, '${d['calories'] ?? 0}', 'kcal'),
                if (distanceLabel != null)
                  _toneStat(tone, distanceLabel!, 'distance')
                // Steps are recorded only for manual workouts ridden by the live
                // 100 Hz stream; older/auto sessions have none.
                else if (steps > 0)
                  _toneStat(tone, '$steps', 'steps'),
              ],
            ),
          ],
        );
      }),
    );
  }

  Widget _toneStat(ToneColors tone, String v, String label) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          v,
          style: AppText.metricSm.copyWith(fontSize: 19, color: tone.fg),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(label, style: AppText.captionMuted.copyWith(color: tone.fgMuted)),
      ],
    ),
  );

  Widget _hrChartCard(
    List<TimeSeriesPoint> hrPoints,
    List<double> hr,
    List<Map> bands,
    int? startTs,
    int? endTs,
  ) {
    final drift = _n(d['hr_drift_pct']);
    final ttp = _n(d['time_to_peak_min']);
    String hrTooltip(TimeSeriesPoint p) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        (p.x * 1000).round(),
      ).toLocal();
      final mm = dt.minute.toString().padLeft(2, '0');
      return '${dt.hour}:$mm\n${p.y.round()} bpm';
    }

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Heart rate', style: AppText.h2)),
              InfoDot(
                title: 'Heart rate',
                body:
                    'Your minute-by-minute heart rate through the session, '
                    'shaded by your zones. Drag to read a point; ▶ replays it.',
                bullets: const [
                  'Cardiac drift: how much HR crept up at the same effort — '
                      'heat, dehydration or fatigue push it above ~3%',
                  'Time to peak: minutes until your highest heart rate',
                ],
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          LayoutBuilder(
            builder: (context, constraints) {
              const leftPad = 28.0;
              const topInset = 8.0;
              final loX = hrPoints.first.x;
              // Same SNAPPED bound the chart draws with — a raw hiX put the
              // replay dot/markers on a slightly different x scale.
              final hiX = TimeSeriesChart.stableTimeUpperBound(
                loX,
                hrPoints.last.x <= loX ? loX + 1 : hrPoints.last.x,
              );
              final chartW = (constraints.maxWidth - leftPad).clamp(
                1.0,
                double.infinity,
              );
              double markerLeft(int ts) =>
                  leftPad +
                  (((ts - loX) / (hiX - loX)).clamp(0.0, 1.0) * chartW);
              return Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: topInset),
                    child: TimeSeriesChart(
                      points: hrPoints,
                      color: AppColors.accent,
                      height: 190,
                      leftPad: leftPad,
                      yUnit: ' bpm',
                      minY: hr.reduce((a, b) => a < b ? a : b) - 4,
                      maxY: hr.reduce((a, b) => a > b ? a : b) + 4,
                      tooltip: hrTooltip,
                      bands: [
                        for (int i = 0; i < bands.length; i++)
                          if ((bands[i]['lo'] as num?) != null &&
                              (bands[i]['hi'] as num?) != null)
                            HorizontalBand(
                              (bands[i]['lo'] as num).toDouble(),
                              (bands[i]['hi'] as num).toDouble(),
                              AppColors.zone(i).withValues(alpha: 0.08),
                            ),
                      ],
                    ),
                  ),
                  if (startTs != null && endTs != null)
                    for (final ts in [startTs, endTs])
                      Positioned(
                        left: markerLeft(ts) - 1,
                        top: topInset,
                        bottom: 30,
                        child: IgnorePointer(
                          child: Container(
                            width: 2,
                            color: AppColors.positive.withValues(alpha: 0.95),
                          ),
                        ),
                      ),
                  HrReplayOverlay(
                    points: hrPoints,
                    loX: loX,
                    hiX: hiX,
                    loY: hr.reduce((a, b) => a < b ? a : b) - 4,
                    hiY: hr.reduce((a, b) => a > b ? a : b) + 4,
                    chartHeight: 190,
                    leftPad: leftPad,
                    topInset: topInset,
                    color: AppColors.accent,
                  ),
                ],
              );
            },
          ),
          if (drift != null || ttp != null) ...[
            const SizedBox(height: Sp.x3),
            Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                if (ttp != null) StatusChip('Peak in ${ttp.toInt()} min'),
                if (drift != null)
                  StatusChip(
                    'Drift ${drift > 0 ? '+' : ''}${drift.toStringAsFixed(1)}%',
                    tone: drift > 3 ? ChipTone.warn : ChipTone.positive,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _zonesCard(List<Map> bands) {
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Time in zones', style: AppText.h2)),
              InfoDot(
                title: 'Heart-rate zones',
                body:
                    'Zones are % of your max heart rate: Z1 warm-up → Z5 max '
                    'effort. Ranges below are your personal bpm bands.',
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          SegmentBar(
            [for (final b in bands) (b['min'] as num?)?.toDouble() ?? 0],
            [for (int i = 0; i < bands.length; i++) AppColors.zone(i)],
            height: 14,
          ),
          const SizedBox(height: Sp.x4),
          for (int i = 0; i < bands.length; i++) ...[
            if (i > 0) const SizedBox(height: Sp.x3),
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: AppColors.zone(i),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Z${bands[i]['zone']} · ${bands[i]['name']}',
                        style: AppText.body,
                      ),
                      Text(
                        '${bands[i]['lo']}–${bands[i]['hi']} bpm',
                        style: AppText.captionMuted,
                      ),
                    ],
                  ),
                ),
                Text(
                  '${(bands[i]['min'] as num?)?.round() ?? 0}m',
                  style: AppText.metricSm.copyWith(fontSize: 16),
                ),
                const SizedBox(width: Sp.x3),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${bands[i]['pct'] ?? 0}%',
                    textAlign: TextAlign.right,
                    style: AppText.captionMuted,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _hrrCard(List<Map> curve) {
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Heart-rate recovery', style: AppText.h2)),
              InfoDot(
                title: 'Heart-rate recovery',
                body:
                    'How many bpm your heart rate dropped in the minutes after '
                    'the effort — a faster drop generally means better fitness.',
              ),
            ],
          ),
          const SizedBox(height: Sp.x4),
          Row(
            children: [
              for (final c in curve)
                _heroStat(
                  '−${(c['drop'] as num?)?.round() ?? 0}',
                  '${((c['sec'] as num?)?.toInt() ?? 0) ~/ 60} min',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroStat(String v, String label) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          v,
          style: AppText.metricSm.copyWith(fontSize: 19),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(label, style: AppText.captionMuted),
      ],
    ),
  );
}
