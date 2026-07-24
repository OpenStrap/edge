// Your day, every vital, one lookback — on the bento design language: the
// merged multi-vital timeline (heart rate, HRV, respiration, skin temp — one
// line per vital, each its own color, values hidden until you touch/scrub;
// see [TimelineContent]), movement, and a clean workout list. Backed by
// /day/timeline; presentation lives in [JourneyContent] (pure,
// render-testable).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';
import '../timeline/timeline_screen.dart' show TimelineContent;
import '../workouts/workout_types.dart';
import 'day_nav.dart';

class JourneyScreen extends StatefulWidget {
  /// The day to open on, 'YYYY-MM-DD'. The screen then lets the user step across
  /// PAST days (issue #112) — this is only the ENTRY date, not a fixed one.
  final String date;
  const JourneyScreen({super.key, required this.date});
  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

enum _Phase { loading, ready, empty, error }

class _JourneyScreenState extends State<JourneyScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic> _data = const {};

  /// The day currently being viewed ('YYYY-MM-DD'). Starts at [widget.date] and
  /// moves as the user navigates prev/next or picks a date; every change
  /// re-runs [_load] for that day. All existing per-date behaviour (retention
  /// gating, partial-today fallback, empty/error states) keys off THIS value.
  late String _currentDate;

  /// Days with any recorded data (newest first) — bounds the prev control and
  /// the date picker. Empty until [_loadDays] returns (nav then falls back to
  /// today-only bounds, which is safe).
  List<String> _availableDays = const [];

  @override
  void initState() {
    super.initState();
    _currentDate = widget.date;
    _load();
    _loadDays();
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
      final res = await api.getDayTimeline(_currentDate);
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

  /// Fetch the recorded-day range once (non-fatal on failure).
  Future<void> _loadDays() async {
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      final days = await api.availableDays();
      if (!mounted) return;
      setState(() => _availableDays = days);
    } catch (_) {
      // Navigation simply falls back to today-only bounds.
    }
  }

  /// Navigate to [date] and reload (no-op if already there).
  void _go(String date) {
    if (date == _currentDate) return;
    setState(() => _currentDate = date);
    _load();
  }

  /// The DISPLAYED day: the timeline's bundle date (a partial "today" may fall
  /// back to the latest complete day — the header must follow the data
  /// actually shown, not the requested date). Falls back to [_currentDate].
  String get _displayDate {
    final d = _data['date'];
    return (d is String && d.isNotEmpty) ? d : _currentDate;
  }

  String get _today => todayLabel();

  /// The set of days the user may land on, sorted ascending — recorded days
  /// plus today and wherever we currently are, capped at today.
  List<String> get _navigable =>
      DayNav.navigableDays(_availableDays, _today, current: _currentDate);

  // ── date parsing / picker ──────────────────────────────────────────────────

  static DateTime? _parseYmd(String ymd) {
    final p = ymd.split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]), m = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  /// Tap the date → jump to any RECORDED day, bounded to [earliest, today].
  /// Only recorded (renderable) days are choosable — empty gaps are greyed out
  /// in the calendar so a tap can never land on a blank screen.
  Future<void> _openPicker() async {
    final today = _parseYmd(_today);
    if (today == null) return;
    final navigable = _navigable;
    final earliestStr = DayNav.earliest(navigable);
    final first = (earliestStr == null ? null : _parseYmd(earliestStr)) ?? today;
    // The initial selection must itself be selectable, or showDatePicker
    // asserts — fall back to today (always renderable via the partial-today
    // fallback) when the displayed day somehow isn't in the set.
    var initial = _parseYmd(_displayDate) ?? today;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(today)) initial = today;
    if (!DayNav.isSelectable(dayLabelOf(initial), navigable)) initial = today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: today,
      helpText: 'Jump to a day',
      selectableDayPredicate: (d) =>
          DayNav.isSelectable(dayLabelOf(d), navigable),
    );
    if (picked == null || !mounted) return;
    _go(dayLabelOf(picked));
  }

  // ── build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Your day',
      header: _dayNavBar(),
      children: [
        if (_phase == _Phase.loading) ...[
          Skeleton.chart(height: 260),
          const SizedBox(height: Sp.x4),
          Skeleton.tileRow(rows: 2),
          const SizedBox(height: Sp.x4),
          Skeleton.chart(height: 160),
        ] else if (_phase == _Phase.empty)
          StateCard(
            icon: OsIcon.calendar,
            title: 'Nothing recorded',
            message:
                'No heart rate or workouts were captured for this day. Wear '
                'your strap and sync to fill in your daily journey.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else if (_phase == _Phase.error)
          StateCard(
            icon: OsIcon.sync,
            title: "Couldn't load your day",
            message: _error ?? 'Please try again.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else
          JourneyContent(data: _data, requestedDate: _currentDate),
      ],
    );
  }

  /// Prev / next chevrons flanking the (tappable) displayed date. Next is
  /// disabled at today (never into the future); prev is disabled at the
  /// earliest recorded day. Empty gaps between recorded days are skipped.
  Widget _dayNavBar() {
    final navigable = _navigable;
    final prevDay = DayNav.prev(_currentDate, navigable);
    final nextDay = DayNav.next(_currentDate, navigable);
    final isToday = _displayDate == _today;
    return Row(
      children: [
        _NavChevron(
          icon: OsIcon.arrowLeft,
          semanticLabel: 'Previous day',
          onTap: prevDay == null ? null : () => _go(prevDay),
        ),
        Expanded(
          child: Pressable(
            pressedScale: 0.97,
            onTap: _openPicker,
            child: Semantics(
              button: true,
              label: 'Choose a day',
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Sp.x2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const OsAppIcon(OsIcon.calendar, size: 20),
                    const SizedBox(width: Sp.x2),
                    Flexible(
                      child: Text(
                        JourneyContent.prettyDate(_displayDate),
                        style: AppText.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isToday) ...[
                      const SizedBox(width: Sp.x2),
                      const Tag('today'),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        _NavChevron(
          icon: OsIcon.arrowRight,
          semanticLabel: 'Next day',
          onTap: nextDay == null ? null : () => _go(nextDay),
        ),
      ],
    );
  }
}

/// A circular prev/next control that greys out (and stops responding) when
/// there's no day to move to in that direction.
class _NavChevron extends StatelessWidget {
  final OsIcon icon;
  final String semanticLabel;
  final VoidCallback? onTap;
  const _NavChevron({
    required this.icon,
    required this.semanticLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.3,
        child: RoundIconButton(icon, onTap: onTap),
      ),
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
            // Generic movement fraction, not steps — the activity art is the
            // honest match.

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
            TileHeader('Workouts · ${sessions.length}'),
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
      icon: workoutTypeOsIcon(type) ?? OsIcon.workouts,
      iconColor: DomainAccent.strain,
      title: type.isEmpty ? 'Workout' : _titleCase(type),
      subtitle: meta,
      value: strain == null ? null : '${strain.toStringAsFixed(1)} strain',
      divider: divider,
    );
  }
}
