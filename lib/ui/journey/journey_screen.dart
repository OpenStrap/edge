// One day, hour by hour — on the bento design language: the 24h HR timeline
// (with the tap-to-replay overlay), peak/low HR stat tiles, movement, and a
// clean workout list. Backed by /day/timeline; presentation lives in
// [JourneyContent] (pure, render-testable).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

class JourneyScreen extends StatefulWidget {
  final String date; // 'YYYY-MM-DD'
  const JourneyScreen({super.key, required this.date});
  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

enum _Phase { loading, ready, empty, error }

class _JourneyScreenState extends State<JourneyScreen> {
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
        _error = 'Pair your strap first.';
      });
      return;
    }
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final res = await api.getDayTimeline(widget.date);
      if (!mounted) return;
      setState(() {
        _data = res;
        _phase = JourneyContent.isEmptyPayload(res)
            ? _Phase.empty
            : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  /// The DISPLAYED day: the timeline's bundle date (a partial "today" may fall
  /// back to the latest complete day — the header must follow the data
  /// actually shown, not the requested date). Falls back to widget.date.
  String get _displayDate {
    final d = _data['date'];
    return (d is String && d.isNotEmpty) ? d : widget.date;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Your day',
      subtitle: JourneyContent.prettyDate(_displayDate),
      children: [
        if (_phase == _Phase.loading) ...[
          Skeleton.chart(height: 260),
          const SizedBox(height: Sp.x4),
          Skeleton.tileRow(rows: 2),
          const SizedBox(height: Sp.x4),
          Skeleton.chart(height: 160),
        ] else if (_phase == _Phase.empty)
          StateCard(
            icon: Ic.calendar,
            title: 'Nothing recorded',
            message:
                'No heart rate or workouts were captured for this day. Wear '
                'your strap and sync to fill in your daily journey.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else if (_phase == _Phase.error)
          StateCard(
            icon: Ic.cloud,
            title: "Couldn't load your day",
            message: _error ?? 'Please try again.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else
          JourneyContent(data: _data, requestedDate: widget.date),
      ],
    );
  }
}

/// Pure presentation for the day-journey board (render-testable without a
/// repo): timeline tile + HR replay, peak/low bento, movement, workouts.
class JourneyContent extends StatelessWidget {
  final Map<String, dynamic> data;

  /// The originally-requested date — retention gating (minute detail exists
  /// only for recent days) keys off what the user ASKED for.
  final String requestedDate;

  const JourneyContent({
    super.key,
    required this.data,
    required this.requestedDate,
  });

  static bool isEmptyPayload(Map<String, dynamic> d) =>
      _pointsOf(d['hr']).isEmpty && _listOf(d['sessions']).isEmpty;

  // ── defensive parsing helpers ─────────────────────────────────────────────

  static Map<String, dynamic> _mapOf(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  static List<Map<String, dynamic>> _listOf(Object? v) => v is List
      ? [
          for (final e in v)
            if (e is Map) e.cast<String, dynamic>(),
        ]
      : const [];

  static num? _numOf(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  static String _str(Object? v) => v == null ? '' : v.toString();

  /// [{t, v}] → list of (epochSec, value) with both fields present.
  static List<({int t, double v})> _pointsOf(Object? raw) {
    final out = <({int t, double v})>[];
    for (final p in _listOf(raw)) {
      final t = _numOf(p['t'])?.toInt();
      final v = _numOf(p['v'])?.toDouble();
      if (t != null && v != null) out.add((t: t, v: v));
    }
    return out;
  }

  int get _dayStart => _numOf(data['day_start'])?.toInt() ?? 0;
  List<Map<String, dynamic>> get _sessions => _listOf(data['sessions']);
  List<Map<String, dynamic>> get _sleep => _listOf(data['sleep']);

  // ── formatting (no intl) ──────────────────────────────────────────────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// 'YYYY-MM-DD' → 'Wed, Jun 12'. Falls back to the raw string on parse fail.
  static String prettyDate(String iso) {
    final parts = iso.split('-');
    if (parts.length != 3) return iso;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null || m < 1 || m > 12) return iso;
    final dt = DateTime(y, m, d);
    return '${_weekdays[(dt.weekday - 1) % 7]}, ${_months[m - 1]} $d';
  }

  /// epoch sec → local 'H:MM' (24h).
  static String _hm(int? epochSec) {
    if (epochSec == null) return '--:--';
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000).toLocal();
    return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }

  static String _titleCase(String s) => s.isEmpty
      ? s
      : s
          .replaceAll('_', ' ')
          .split(' ')
          .where((w) => w.isNotEmpty)
          .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
          .join(' ');

  String get _displayDate {
    final d = _str(data['date']);
    return d.isNotEmpty ? d : requestedDate;
  }

  bool get _isToday {
    final now = DateTime.now();
    final local =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return _displayDate == local;
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final detailed = detailedAvailable(requestedDate);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: dsStaggered([
        // Minute-level 24h timeline + movement only for recent days; workouts
        // below come from permanent tables and always show.
        if (detailed) ...[
          _timelineTile(),
          const SizedBox(height: Sp.x3),
          _highsBento(),
          const SizedBox(height: Sp.x3),
          _movementTile(),
        ] else
          const DetailRetentionNote(what: '24-hour timeline'),
        ..._workoutsSection(),
      ]),
    );
  }

  // ── peak / low HR bento ───────────────────────────────────────────────────

  Widget _highsBento() {
    final highs = _mapOf(data['highs']);
    final peak = _mapOf(highs['peak_hr']);
    final low = _mapOf(highs['low_hr']);
    return BentoColumns(
      entrance: false,
      left: [
        _highTile(
          'Peak HR',
          Ic.pulse,
          OsIcon.maxHeartRate,
          DomainAccent.heart,
          _numOf(peak['v'])?.round(),
          _numOf(peak['t'])?.toInt(),
        ),
      ],
      right: [
        _highTile(
          'Lowest HR',
          Ic.heart,
          OsIcon.restingHeartRate,
          DomainAccent.oxygen,
          _numOf(low['v'])?.round(),
          _numOf(low['t'])?.toInt(),
        ),
      ],
    );
  }

  Widget _highTile(String label, IconData icon, OsIcon osIcon, Color accent,
      int? bpm, int? ts) {
    return BentoTile(
      tone: BentoTone.soft,
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TileHeader(label, icon: icon, osIcon: osIcon),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: bpm?.toString(),
            unit: 'bpm',
            caption: bpm == null ? 'No reading' : 'at ${_hm(ts)}',
          ),
        ],
      ),
    );
  }

  // ── the timeline (24h HR line + replay + context band) ────────────────────

  Widget _timelineTile() {
    final hr = _pointsOf(data['hr']);
    final points = [for (final p in hr) TimeSeriesPoint(p.t.toDouble(), p.v)];
    final endSec = _isToday
        ? DateTime.now().millisecondsSinceEpoch / 1000.0
        : _dayStart + 86400.0;
    final first = hr.isEmpty ? null : hr.first;
    final last = hr.isEmpty ? null : hr.last;
    // Match the chart's own auto y-range (min/max + 12% pad) so the replay dot
    // rides the drawn line.
    final ys = [for (final p in points) p.y];
    final minYRaw = ys.isEmpty ? 0.0 : ys.reduce((a, b) => a < b ? a : b);
    final maxYRaw = ys.isEmpty ? 1.0 : ys.reduce((a, b) => a > b ? a : b);
    final yPad = (maxYRaw - minYRaw) * 0.12 < 2.0
        ? 2.0
        : (maxYRaw - minYRaw) * 0.12;
    final chart = TimeSeriesChart(
      points: points,
      color: DomainAccent.heart,
      height: 260,
      minX: _dayStart.toDouble(),
      maxX: endSec,
      yUnit: ' bpm',
      tooltip: (p) {
        final dt = DateTime.fromMillisecondsSinceEpoch(
          (p.x * 1000).round(),
        ).toLocal();
        return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}'
            '\n${p.y.round()} bpm';
      },
    );
    return BentoTile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader(
            'The timeline',
            icon: Ic.pulse,
            trailing: InfoDot(
              title: 'Your 24-hour timeline',
              body:
                  'Minute-level heart rate across the day. Sleep and workout '
                  'context is drawn on the band under the chart. Tap the '
                  'chart to replay the day.',
            ),
          ),
          const SizedBox(height: Sp.x3),
          if (points.length >= 2)
            Stack(
              children: [
                chart,
                HrReplayOverlay(
                  points: points,
                  loX: _dayStart.toDouble(),
                  // Same SNAPPED bound the chart draws with, or the replay dot
                  // rides off the drawn curve.
                  hiX: TimeSeriesChart.stableTimeUpperBound(
                    _dayStart.toDouble(),
                    endSec,
                  ),
                  loY: minYRaw - yPad,
                  hiY: maxYRaw + yPad,
                  chartHeight: 260,
                  leftPad: 52,
                  topInset: 0,
                  color: DomainAccent.heart,
                ),
              ],
            )
          else
            chart,
          const SizedBox(height: Sp.x4),
          _contextBand(),
          if (first != null && last != null) ...[
            const SizedBox(height: Sp.x4),
            Row(
              children: [
                Expanded(
                  child: BigStat(
                    value: '${first.v.round()}',
                    unit: 'bpm',
                    label: 'Start',
                    size: BigStatSize.md,
                  ),
                ),
                Expanded(
                  child: BigStat(
                    value: '${last.v.round()}',
                    unit: 'bpm',
                    label: 'Latest',
                    size: BigStatSize.md,
                  ),
                ),
                Expanded(
                  child: BigStat(
                    value: ((last.t - first.t) / 3600).toStringAsFixed(1),
                    unit: 'h',
                    label: 'Span',
                    size: BigStatSize.md,
                  ),
                ),
              ],
            ),
          ],
          if (_sleep.isNotEmpty || _sessions.isNotEmpty) ...[
            const SizedBox(height: Sp.x3),
            Row(
              children: [
                if (_sleep.isNotEmpty)
                  _legendDot(DomainAccent.sleep, 'Sleep'),
                if (_sleep.isNotEmpty && _sessions.isNotEmpty)
                  const SizedBox(width: Sp.x4),
                if (_sessions.isNotEmpty)
                  _legendDot(DomainAccent.strain, 'Workout'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _legendDot(Color c, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: AppText.captionMuted),
    ],
  );

  /// 0..1 fraction of where an epoch falls in the day's 24h window.
  double _frac(int ts) {
    final start = _dayStart;
    if (start <= 0) return 0;
    return ((ts - start) / 86400.0).clamp(0.0, 1.0);
  }

  /// A thin band of positioned colored rects: sleep blocks under workout
  /// sessions, placed by (ts - day_start)/86400 fraction.
  Widget _contextBand() {
    const h = 14.0;
    final segments = <Widget>[];

    void addSeg(int? start, int? end, Color color, double opacity) {
      if (start == null || end == null || end <= start || _dayStart <= 0) {
        return;
      }
      final left = _frac(start);
      final right = _frac(end);
      final width = (right - left).clamp(0.0, 1.0);
      if (width <= 0) return;
      segments.add(
        Align(
          alignment: Alignment(left * 2 - 1, 0),
          child: FractionallySizedBox(
            widthFactor: width,
            alignment: Alignment.centerLeft,
            child: Container(
              height: h,
              decoration: BoxDecoration(
                color: color.withValues(alpha: opacity),
                borderRadius: BorderRadius.circular(R.pill),
              ),
            ),
          ),
        ),
      );
    }

    for (final s in _sleep) {
      addSeg(
        _numOf(s['onset_ts'])?.toInt(),
        _numOf(s['wake_ts'])?.toInt(),
        DomainAccent.sleep,
        0.7,
      );
    }
    for (final s in _sessions) {
      addSeg(
        _numOf(s['start_ts'])?.toInt(),
        _numOf(s['end_ts'])?.toInt(),
        DomainAccent.strain,
        0.85,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(R.pill),
      child: Container(
        height: h,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(R.pill),
        ),
        // The track is full width; segments are positioned within it. Align
        // uses the parent's full width so left/width fractions map to 24h.
        child: Stack(alignment: Alignment.centerLeft, children: segments),
      ),
    );
  }

  // ── movement ──────────────────────────────────────────────────────────────

  Widget _movementTile() {
    final act = _pointsOf(data['activity']);
    final points = [
      for (final p in act) TimeSeriesPoint(p.t.toDouble(), p.v * 100.0),
    ];
    final endSec = _isToday
        ? DateTime.now().millisecondsSinceEpoch / 1000.0
        : _dayStart + 86400.0;
    return BentoTile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader(
            'Movement',
            icon: Ic.activity,
            // Generic movement fraction, not steps — the activity art is the
            // honest match.
            osIcon: OsIcon.activity,
            trailing: InfoDot(
              title: 'Movement',
              body:
                  'The fraction of each 5-minute block that looked physically '
                  'active.',
              methodNote: 'A motion signal from the wrist — not steps.',
            ),
          ),
          const SizedBox(height: Sp.x3),
          TimeSeriesChart(
            points: points,
            color: DomainAccent.steps,
            height: 180,
            minX: _dayStart.toDouble(),
            maxX: endSec,
            fill: false,
            gapThresholdSec: 1800,
            yLabel: (v) => '${v.round()}%',
            tooltip: (p) {
              final dt = DateTime.fromMillisecondsSinceEpoch(
                (p.x * 1000).round(),
              ).toLocal();
              return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}'
                  '\n${p.y.round()}% movement';
            },
          ),
        ],
      ),
    );
  }

  // ── workouts: one clean list tile ─────────────────────────────────────────

  List<Widget> _workoutsSection() {
    final sessions = _sessions;
    if (sessions.isEmpty) return const [];
    return [
      const SizedBox(height: Sp.x3),
      BentoTile(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TileHeader('Workouts · ${sessions.length}',
                icon: Ic.run, osIcon: OsIcon.workouts),
            const SizedBox(height: Sp.x1),
            for (var i = 0; i < sessions.length; i++)
              _workoutRow(sessions[i], divider: i < sessions.length - 1),
          ],
        ),
      ),
    ];
  }

  Widget _workoutRow(Map<String, dynamic> s, {required bool divider}) {
    final type = _str(s['type']);
    final start = _numOf(s['start_ts'])?.toInt();
    final end = _numOf(s['end_ts'])?.toInt();
    final avg = _numOf(s['avg_hr'])?.round();
    final max = _numOf(s['max_hr'])?.round();
    final strain = _numOf(s['strain']);
    final meta = [
      '${_hm(start)} – ${_hm(end)}',
      if (avg != null) 'avg $avg',
      if (max != null) 'max $max bpm',
    ].join(' · ');
    return ListRow(
      icon: Ic.run,
      osIcon: OsIcon.workouts,
      iconColor: DomainAccent.strain,
      title: type.isEmpty ? 'Workout' : _titleCase(type),
      subtitle: meta,
      value: strain == null ? null : '${strain.toStringAsFixed(1)} strain',
      divider: divider,
    );
  }
}
