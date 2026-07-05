// Shareable week/month recap on the bento design language — an inverted ink
// card in the spirit of the reference weekly-recap boards: hero average,
// highlight banner, sleep bars, calories, steps, top workout. The card is
// captured to a PNG via RepaintBoundary + share_plus (pipeline unchanged);
// the Week/Month toggle refetches /history.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../design/design.dart';
import '../workouts/workout_types.dart';

class RecapScreen extends StatefulWidget {
  const RecapScreen({super.key});
  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

enum _Phase { loading, ready, empty, error }

class _RecapScreenState extends State<RecapScreen> {
  final GlobalKey _cardKey = GlobalKey();

  // Restore the last-selected recap range ('7d' | '30d') across launches.
  String _range = Prefs.getString(Prefs.recapRange, '7d') == '30d'
      ? '30d'
      : '7d';
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic> _data = const {};
  List<double> _sleepBars = const [];
  Map<String, dynamic>? _topWorkout;
  bool _sharing = false;

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
        _error = 'Pair your strap first.';
      });
      return;
    }
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final res = await api.getHistory(range: _range);

      // Enrichments beyond /history (which has no sleep series or workout
      // list): nightly sleep bars from the trend buckets, top workout from
      // the sessions store. Both are best-effort.
      var sleepBars = const <double>[];
      Map<String, dynamic>? top;
      try {
        final trend = await api.getTrend(
          'sleep',
          scale: _range == '7d' ? 'week' : 'month',
        );
        sleepBars = [
          for (final b in (trend['buckets'] as List?) ?? const [])
            if (b is Map && b['has'] == true && b['value'] is num)
              (b['value'] as num).toDouble(),
        ];
      } catch (_) {}
      try {
        final w = await api.getWorkouts(
          range: _range == '7d' ? 'week' : 'month',
        );
        for (final s in (w['workouts'] as List?) ?? const []) {
          if (s is! Map || s['status'] == 'live') continue;
          final strain = (s['strain'] as num?)?.toDouble() ?? 0;
          if (top == null || strain > ((top['strain'] as num?) ?? 0)) {
            top = s.cast<String, dynamic>();
          }
        }
      } catch (_) {}

      if (!mounted) return;
      final empty = _isEmpty(res);
      setState(() {
        _data = res;
        _sleepBars = sleepBars;
        _topWorkout = top;
        _phase = empty ? _Phase.empty : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  bool _isEmpty(Map<String, dynamic> d) {
    final metrics = d['metrics'];
    final worn = (d['worn_days'] as num?)?.toInt() ?? 0;
    return metrics is! Map || metrics.isEmpty || worn <= 0;
  }

  void _onRange(int i) {
    final next = i == 0 ? '7d' : '30d';
    if (next == _range) return;
    _range = next;
    Prefs.setString(Prefs.recapRange, next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      // Illustrated headline — recap art leads the title.
      titleWidget: Row(
        children: [
          const OsAppIcon(OsIcon.recap, size: 36),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text('Recap',
                style: AppText.h1,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      header: SegmentedControl(
        options: const ['Week', 'Month'],
        index: _range == '7d' ? 0 : 1,
        onChanged: _onRange,
        expanded: true,
      ),
      children: [
        if (_phase == _Phase.loading) ...[
          Skeleton.hero(),
          const SizedBox(height: Sp.x4),
          Skeleton.chart(),
        ] else if (_phase == _Phase.empty)
          StateCard(
            icon: Ic.calendar,
            title: 'Not enough data yet',
            message:
                'Wear your strap for a few days. Your recap appears once '
                'there is a week of data to summarize.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else if (_phase == _Phase.error)
          StateCard(
            icon: Ic.cloud,
            title: "Couldn't load your recap",
            message: _error ?? 'Please try again.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else ...[
          // The captured share surface — everything inside this boundary
          // lands in the PNG.
          RepaintBoundary(
            key: _cardKey,
            child: RecapShareCard(
              data: _data,
              range: _range,
              sleepBars: _sleepBars,
              topWorkout: _topWorkout,
            ),
          ).dsEnter(),
          const SizedBox(height: Sp.x5),
          _shareButton().dsEnter(index: 2),
        ],
      ],
    );
  }

  // ── share button + capture (pipeline unchanged) ───────────────────────────

  Widget _shareButton() {
    return FilledButton.icon(
      onPressed: _sharing ? null : _share,
      icon: _sharing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const AppIcon(Ic.arrowRight, size: 20, color: Colors.white),
      label: Text(_sharing ? 'Preparing…' : 'Share my recap'),
    );
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      // iOS/iPad: the share sheet is a popover and REQUIRES an anchor rect, or
      // it throws PlatformException(sharePositionOrigin: argument must be set).
      // Capture it now, before any async gap, while layout is stable.
      final box = context.findRenderObject() as RenderBox?;
      final origin = (box != null && box.hasSize)
          ? (box.localToGlobal(Offset.zero) & box.size)
          : null;

      final boundary =
          _cardKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('Card not ready');

      final ui.Image image = await boundary.toImage(pixelRatio: 3);
      final ByteData? bytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (bytes == null) throw StateError('Failed to encode image');

      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/openstrap_recap_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes.buffer.asUint8List());

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'My OpenStrap recap',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't share recap: $e")),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}

/// The shareable recap card — pure presentation (render-testable), painted on
/// the invariant ink (near-black) surface so the exported PNG looks premium
/// out of both themes. Solid fill → the raster is never transparent.
class RecapShareCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String range; // '7d' | '30d'

  /// Nightly (week) / weekly-average (month) sleep minutes for the bar strip.
  final List<double> sleepBars;

  /// The window's highest-strain workout map ({type, strain, duration_min}).
  final Map<String, dynamic>? topWorkout;

  const RecapShareCard({
    super.key,
    required this.data,
    required this.range,
    this.sleepBars = const [],
    this.topWorkout,
  });

  // ── defensive parsing ──────────────────────────────────────────────────────

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  Map<String, dynamic> _metric(String key) => _map(_map(data['metrics'])[key]);
  num? _mAvg(String key) => _num(_metric(key)['avg']);
  num? _mTotal(String key) => _num(_metric(key)['total']);
  num? _mDelta(String key) => _num(_metric(key)['delta_pct']);

  List<double> _series(String key) {
    final raw = _map(data['series'])[key];
    if (raw is! List) return const [];
    return [
      for (final p in raw)
        if (_num(_map(p)['v']) != null) _num(_map(p)['v'])!.toDouble(),
    ];
  }

  // ── formatting (no intl) ───────────────────────────────────────────────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _fmtDay(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000).toLocal();
    return '${_months[d.month - 1]} ${d.day}';
  }

  String _periodLabel() {
    final from = _num(data['from_epoch'])?.toInt();
    final to = _num(data['to_epoch'])?.toInt();
    if (from != null && to != null && to > 0) {
      return '${_fmtDay(from)} – ${_fmtDay(to)}';
    }
    return range == '7d' ? 'This week' : 'This month';
  }

  static String? _hm(num? minutes) {
    if (minutes == null) return null;
    final m = minutes.round();
    return '${m ~/ 60}h ${m % 60}m';
  }

  static String _compact(num? v) {
    if (v == null) return '—';
    final n = v.round();
    if (n >= 1000) {
      final k = n / 1000.0;
      return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
    }
    return '$n';
  }

  static String _titleCase(String s) => s.isEmpty
      ? s
      : s
          .replaceAll('_', ' ')
          .split(' ')
          .where((w) => w.isNotEmpty)
          .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');

  /// One highlight sentence for the banner — best available story.
  String? _highlight(num? strainAvg, num? sleepAvgMin, int worn) {
    final sleep = _hm(sleepAvgMin);
    if (sleep != null) return 'You averaged $sleep of sleep a night.';
    if (strainAvg != null) {
      return 'Average strain ${strainAvg.toStringAsFixed(1)} across '
          '$worn worn day${worn == 1 ? '' : 's'}.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final strainAvg = _mAvg('strain');
    final strainDelta = _mDelta('strain');
    final rhrAvg = _mAvg('resting_hr');
    final rhrDelta = _mDelta('resting_hr');
    final sleepAvg = _mAvg('sleep_duration');
    final calories = _mTotal('calories');
    final stepsSeries = _series('steps');
    final stepsTotal = stepsSeries.isEmpty
        ? null
        : stepsSeries.reduce((a, b) => a + b);
    final strainSeries = _series('strain');
    final worn = _num(data['worn_days'])?.toInt() ?? 0;
    final highlight = _highlight(strainAvg, sleepAvg, worn);
    final top = topWorkout;

    return BentoTile(
      tone: BentoTone.ink,
      padding: const EdgeInsets.all(Sp.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: wordmark + period.
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: const AppIcon(Ic.strain, size: 14, color: Colors.white),
              ),
              const SizedBox(width: Sp.x2),
              Text(
                'OpenStrap',
                style: AppText.title.copyWith(color: AppColors.onNight),
              ),
              const Spacer(),
              Text(
                _periodLabel(),
                style: AppText.caption.copyWith(color: AppColors.onNightSoft),
              ),
            ],
          ),
          const SizedBox(height: Sp.x5),

          // Hero: average strain + the window's daily bars beside it.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: BigStat(
                  value: strainAvg?.toStringAsFixed(1),
                  label: 'Avg strain',
                  size: BigStatSize.xl,
                ),
              ),
              if (strainDelta != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x2),
                  child: DeltaChip(strainDelta),
                ),
              if (strainSeries.length >= 2) ...[
                const SizedBox(width: Sp.x3),
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x1),
                  child: SizedBox(
                    width: 104,
                    child: MiniBars(
                      strainSeries,
                      color: DomainAccent.strain,
                      height: 40,
                    ),
                  ),
                ),
              ],
            ],
          ),

          if (highlight != null) ...[
            const SizedBox(height: Sp.x4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x3,
                vertical: Sp.x2 + 2,
              ),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(R.chip),
              ),
              child: Text(
                highlight,
                style: AppText.caption.copyWith(
                  color: AppColors.onNight,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const SizedBox(height: Sp.x4),

          // 2×2 stat bento inside the card.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _cell(
                  label: 'Resting HR',
                  value: rhrAvg == null ? null : '${rhrAvg.round()}',
                  unit: 'bpm',
                  extra: rhrDelta == null
                      ? null
                      : DeltaChip(rhrDelta, goodIsUp: false),
                ),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: _cell(
                  label: 'Sleep / night',
                  value: _hm(sleepAvg),
                  extra: sleepBars.length >= 2
                      ? MiniBars(
                          sleepBars,
                          color: DomainAccent.sleep,
                          height: 26,
                        )
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _cell(
                  label: 'Calories',
                  value: _compact(calories),
                  unit: 'kcal',
                ),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: _cell(
                  label: 'Steps',
                  value: _compact(stepsTotal),
                  extra: stepsSeries.length >= 2
                      ? MiniBars(
                          stepsSeries,
                          color: DomainAccent.steps,
                          height: 26,
                        )
                      : null,
                ),
              ),
            ],
          ),

          // Top workout of the window.
          if (top != null) ...[
            const SizedBox(height: Sp.x3),
            Container(
              padding: const EdgeInsets.all(Sp.x3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(R.cardSm),
              ),
              child: Row(
                children: [
                  workoutTypeOsIcon(top['type']?.toString()) != null
                      ? OsAppIcon(
                          workoutTypeOsIcon(top['type']?.toString())!,
                          size: 20,
                        )
                      : AppIcon(Ic.run, size: 16, color: DomainAccent.strain),
                  const SizedBox(width: Sp.x2),
                  Expanded(
                    child: Text(
                      'Top workout — '
                      '${_titleCase((top['type'] ?? 'workout').toString())}',
                      style: AppText.caption.copyWith(
                        color: AppColors.onNight,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    [
                      if (_num(top['strain']) != null)
                        '${_num(top['strain'])!.toStringAsFixed(1)} strain',
                      if (_num(top['duration_min']) != null)
                        '${_num(top['duration_min'])!.round()} min',
                    ].join(' · '),
                    style: AppText.caption.copyWith(
                      color: AppColors.onNightSoft,
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: Sp.x4),
          // Footer.
          Row(
            children: [
              AppIcon(Ic.shield, size: 13, color: AppColors.onNightSoft),
              const SizedBox(width: 6),
              Text(
                'your data · your device · openstrap',
                style: AppText.caption.copyWith(color: AppColors.onNightSoft),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One quiet stat cell of the inner bento.
  Widget _cell({
    required String label,
    required String? value,
    String? unit,
    Widget? extra,
  }) {
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(R.cardSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          BigStat(value: value, unit: unit, label: label, size: BigStatSize.md),
          if (extra != null) ...[const SizedBox(height: Sp.x2), extra],
        ],
      ),
    );
  }
}
