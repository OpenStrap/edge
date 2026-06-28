// One day, hour by hour — heart rate, sleep/workout bands, movement, peak/low
// HR, workouts, and device events. Backed by /day/timeline.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

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
        _error = 'Not signed in.';
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
        _phase = _isEmpty(res) ? _Phase.empty : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  bool _isEmpty(Map<String, dynamic> d) =>
      _points(d['hr']).isEmpty && _sessions().isEmpty;

  // ── defensive parsing helpers ───────────────────────────────────────────────

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  List<Map<String, dynamic>> _list(Object? v) => v is List
      ? [
          for (final e in v)
            if (e is Map) e.cast<String, dynamic>(),
        ]
      : const [];

  num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  String _str(Object? v) => v == null ? '' : v.toString();

  int get _dayStart => _num(_data['day_start'])?.toInt() ?? 0;

  /// [{t, v}] → list of (epochSec, value) with both fields present.
  List<({int t, double v})> _points(Object? raw) {
    final out = <({int t, double v})>[];
    for (final p in _list(raw)) {
      final t = _num(p['t'])?.toInt();
      final v = _num(p['v'])?.toDouble();
      if (t != null && v != null) out.add((t: t, v: v));
    }
    return out;
  }

  List<Map<String, dynamic>> _sessions() => _list(_data['sessions']);
  List<Map<String, dynamic>> _sleep() => _list(_data['sleep']);

  // ── formatting (no intl) ─────────────────────────────────────────────────────

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// 'YYYY-MM-DD' → 'Wed, Jun 12'. Falls back to the raw string on parse fail.
  String _prettyDate(String iso) {
    final parts = iso.split('-');
    if (parts.length != 3) return iso;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null || m < 1 || m > 12) return iso;
    final dt = DateTime(y, m, d);
    final wd = _weekdays[(dt.weekday - 1) % 7];
    return '$wd, ${_months[m - 1]} $d';
  }

  /// epoch sec → local 'H:MM' (24h).
  String _hm(int? epochSec) {
    if (epochSec == null) return '--:--';
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000).toLocal();
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.hour}:$mm';
  }

  String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s
        .replaceAll('_', ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }

  bool get _isToday {
    final now = DateTime.now();
    final local =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return widget.date == local;
  }

  // ── build ────────────────────────────────────────────────────────────────────

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
              _stateCard(
                Ic.calendar,
                'Nothing recorded',
                'No heart rate or workouts were captured for this day. Wear your '
                    'strap and sync to fill in your daily journey.',
              )
            else if (_phase == _Phase.error)
              _stateCard(
                Ic.cloud,
                "Couldn't load your day",
                _error ?? 'Please try again.',
              )
            else
              ..._story(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        RoundIconButton(
          Ic.arrowLeft,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Your day', style: AppText.h1),
              const SizedBox(height: 2),
              Text(_prettyDate(widget.date), style: AppText.caption),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _story() {
    final detailed = detailedAvailable(widget.date);
    return [
      // Minute-level 24h timeline + movement only for recent days; workouts and
      // events below come from permanent tables and always show.
      if (detailed) ...[
        const SectionHeader('The timeline'),
        _timelineCard(),
        const SizedBox(height: Sp.x6),
        _highsStrip(),
        const SizedBox(height: Sp.x6),
        const SectionHeader('Movement'),
        _movementCard(),
      ] else
        const DetailRetentionNote(what: '24-hour timeline'),
      ..._workoutsSection(),
    ];
  }

  // ── 2. highs strip (peak / lowest HR) ─────────────────────────────────────────

  Widget _highsStrip() {
    final highs = _map(_data['highs']);
    final peak = _map(highs['peak_hr']);
    final low = _map(highs['low_hr']);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _highCard(
            Ic.pulse,
            'PEAK HR',
            _num(peak['v'])?.round(),
            _num(peak['t'])?.toInt(),
            AppColors.coral,
          ),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: _highCard(
            Ic.heart,
            'LOWEST HR',
            _num(low['v'])?.round(),
            _num(low['t'])?.toInt(),
            AppColors.loadDetraining,
          ),
        ),
      ],
    );
  }

  Widget _highCard(
    IconData icon,
    String label,
    int? bpm,
    int? ts,
    Color accent,
  ) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: AppIcon(icon, size: 16, color: accent),
              ),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Text(
                  label,
                  style: AppText.overline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (bpm == null)
                metricDash(22)
              else ...[
                Text('$bpm', style: AppText.metric.copyWith(fontSize: 26)),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    'bpm',
                    style: AppText.caption.copyWith(
                      color: AppColors.inkMuted,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Sp.x1),
          Text(
            bpm == null ? 'No reading' : 'at ${_hm(ts)}',
            style: AppText.captionMuted,
          ),
        ],
      ),
    );
  }

  // ── 3. the timeline (24h HR line + context band + hour ticks) ──────────────────

  Widget _timelineCard() {
    final hr = _points(_data['hr']);
    final points = [for (final p in hr) TimeSeriesPoint(p.t.toDouble(), p.v)];
    final endSec = _isToday
        ? DateTime.now().millisecondsSinceEpoch / 1000.0
        : _dayStart + 86400.0;
    final first = hr.isEmpty ? null : hr.first;
    final last = hr.isEmpty ? null : hr.last;
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TimeSeriesChart(
            points: points,
            color: AppColors.coral,
            height: 260,
            minX: _dayStart.toDouble(),
            maxX: endSec,
            yUnit: ' bpm',
            tooltip: (p) {
              final dt = DateTime.fromMillisecondsSinceEpoch(
                (p.x * 1000).round(),
              ).toLocal();
              final mm = dt.minute.toString().padLeft(2, '0');
              return '${dt.hour}:$mm\n${p.y.round()} bpm';
            },
          ),
          const SizedBox(height: Sp.x4),
          _contextBand(),
          if (first != null && last != null) ...[
            const SizedBox(height: Sp.x3),
            Row(
              children: [
                Expanded(child: _metaCell('Start', '${first.v.round()} bpm')),
                const SizedBox(width: Sp.x2),
                Expanded(child: _metaCell('Latest', '${last.v.round()} bpm')),
                const SizedBox(width: Sp.x2),
                Expanded(
                  child: _metaCell(
                    'Span',
                    '${((last.t - first.t) / 3600).toStringAsFixed(1)} h',
                  ),
                ),
              ],
            ),
          ],
          if (_sleep().isNotEmpty || _sessions().isNotEmpty) ...[
            const SizedBox(height: Sp.x3),
            Row(
              children: [
                if (_sleep().isNotEmpty)
                  _legendDot(AppColors.loadDetraining, 'Sleep'),
                if (_sleep().isNotEmpty && _sessions().isNotEmpty)
                  const SizedBox(width: Sp.x4),
                if (_sessions().isNotEmpty)
                  _legendDot(AppColors.coral, 'Workout'),
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

  Widget _metaCell(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: AppText.overline),
          const SizedBox(height: 2),
          Text(value, style: AppText.label),
        ],
      ),
    );
  }

  /// 0..1 fraction of where an epoch falls in the day's 24h window.
  double _frac(int ts) {
    final start = _dayStart;
    if (start <= 0) return 0;
    return ((ts - start) / 86400.0).clamp(0.0, 1.0);
  }

  /// A thin band of positioned colored rects: sleep blocks (blue) under
  /// workout sessions (coral), placed by (ts - day_start)/86400 fraction.
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
      if (width <= 0) {
        return;
      }
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

    for (final s in _sleep()) {
      addSeg(
        _num(s['onset_ts'])?.toInt(),
        _num(s['wake_ts'])?.toInt(),
        AppColors.loadDetraining,
        0.7,
      );
    }
    for (final s in _sessions()) {
      addSeg(
        _num(s['start_ts'])?.toInt(),
        _num(s['end_ts'])?.toInt(),
        AppColors.coral,
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
        // The track is full width; segments are positioned within it. Align uses
        // the parent's full width so left/width fractions map to the 24h span.
        child: Stack(alignment: Alignment.centerLeft, children: segments),
      ),
    );
  }

  // ── 4. movement ────────────────────────────────────────────────────────────────

  Widget _movementCard() {
    final act = _points(_data['activity']);
    final points = [
      for (final p in act) TimeSeriesPoint(p.t.toDouble(), p.v * 100.0),
    ];
    final endSec = _isToday
        ? DateTime.now().millisecondsSinceEpoch / 1000.0
        : _dayStart + 86400.0;
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TimeSeriesChart(
            points: points,
            color: AppColors.coralDeep,
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
              final mm = dt.minute.toString().padLeft(2, '0');
              return '${dt.hour}:$mm\n${p.y.round()}% movement';
            },
          ),
          const SizedBox(height: Sp.x3),
          Text(
            'Movement is the fraction of each 5-minute block that looked physically active. '
            'It is a motion signal, not steps.',
            style: AppText.caption,
          ),
        ],
      ),
    );
  }

  // ── 5. workouts ────────────────────────────────────────────────────────────────

  List<Widget> _workoutsSection() {
    final sessions = _sessions();
    if (sessions.isEmpty) return const [];
    return [
      const SizedBox(height: Sp.x6),
      SectionHeader('Workouts · ${sessions.length}'),
      for (int i = 0; i < sessions.length; i++) ...[
        if (i > 0) const SizedBox(height: Sp.x3),
        _workoutTile(sessions[i]),
      ],
    ];
  }

  Widget _workoutTile(Map<String, dynamic> s) {
    final type = _str(s['type']);
    final start = _num(s['start_ts'])?.toInt();
    final end = _num(s['end_ts'])?.toInt();
    final avg = _num(s['avg_hr'])?.round();
    final max = _num(s['max_hr'])?.round();
    final strain = _num(s['strain']);
    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.coralSoft,
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: AppIcon(Ic.run, size: 18, color: AppColors.coralDeep),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      type.isEmpty ? 'Workout' : _titleCase(type),
                      style: AppText.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_hm(start)} – ${_hm(end)}',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
              if (strain != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      strain.toStringAsFixed(1),
                      style: AppText.metricSm.copyWith(color: AppColors.coral),
                    ),
                    Text('strain', style: AppText.captionMuted),
                  ],
                ),
            ],
          ),
          if (avg != null || max != null) ...[
            const SizedBox(height: Sp.x3),
            Row(
              children: [
                if (avg != null) _miniStat('AVG HR', '$avg bpm'),
                if (avg != null && max != null) const SizedBox(width: Sp.x6),
                if (max != null) _miniStat('MAX HR', '$max bpm'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: AppText.overline),
      const SizedBox(height: 2),
      Text(value, style: AppText.body),
    ],
  );

  // ── states ─────────────────────────────────────────────────────────────────────

  Widget _loading() => ProCard(
    padding: const EdgeInsets.all(Sp.x6),
    child: SizedBox(
      height: 360,
      child: Center(child: CircularProgressIndicator(color: AppColors.coral)),
    ),
  );

  Widget _stateCard(IconData icon, String title, String message) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: BoxDecoration(
              color: AppColors.coralSoft,
              shape: BoxShape.circle,
            ),
            child: AppIcon(icon, size: 30, color: AppColors.coralDeep),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x5),
          OutlinedButton(onPressed: _load, child: const Text('Try again')),
        ],
      ),
    );
  }
}
