// Your day, every vital, one lookback — on the bento design language: the
// merged multi-vital timeline (heart rate, HRV, respiration, skin temp — one
// line per vital, each its own color, values hidden until you touch/scrub;
// see [TimelineContent]), movement, and a clean workout list. Backed by
// /day/timeline; presentation lives in [JourneyContent] (pure,
// render-testable).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';
import '../timeline/timeline_screen.dart' show TimelineContent;
import '../workouts/workout_types.dart';

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
/// repo): the merged multi-vital lookback (heart rate, HRV, resp, skin temp),
/// movement, workouts.
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
      !TimelineContent.hasVitals(d) && _listOf(d['sessions']).isEmpty;

  // ── defensive parsing helpers ─────────────────────────────────────────────

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
        // The merged multi-vital lookback + movement only for recent days;
        // workouts below come from permanent tables and always show.
        if (detailed) ...[
          TimelineContent(data: data),
          const SizedBox(height: Sp.x3),
          _movementTile(),
        ] else
          const DetailRetentionNote(what: 'the day lookback'),
        ..._workoutsSection(),
      ]),
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
      icon: workoutTypeIcon(type),
      osIcon: workoutTypeOsIcon(type) ?? OsIcon.workouts,
      iconColor: DomainAccent.strain,
      title: type.isEmpty ? 'Workout' : _titleCase(type),
      subtitle: meta,
      value: strain == null ? null : '${strain.toStringAsFixed(1)} strain',
      divider: divider,
    );
  }
}
