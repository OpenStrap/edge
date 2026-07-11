// Stress — HRV-based sympathetic activation (Baevsky Stress Index + LF/HF),
// personal-relative, rebuilt on the design language: a rose ArcGauge hero with
// a calm/settled/elevated word, a bento of the measurement numbers, the day's
// rhythm for context, and every explanation behind (i).
//
// Backed by /day/stress, which returns:
//   { stress:{score,si,lf_hf,rmssd,level,drivers}, sleep_stress:{...}, drivers, hr:[{t,v}] }
// (The old HR-above-resting "arousal band" model was removed — this reads the
// real HRV stress. Nocturnal arousal lives under sleep_stress.)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';
import '../screens/metric_row.dart' show infoFor;
import '../../notify/notification_event.dart';
import '../../notify/notification_service.dart';
import 'calm_breathing_screen.dart';

class StressScreen extends StatefulWidget {
  final String date; // 'YYYY-MM-DD'
  const StressScreen({super.key, required this.date});
  @override
  State<StressScreen> createState() => _StressScreenState();
}

enum _Phase { loading, ready, empty, error }

class _StressScreenState extends State<StressScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic> _data = const {};
  Map<String, dynamic> _hrv = const {}; // /day/hrv (daytime ultradian HRV)

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
      final res = await api.getDayStress(widget.date);
      // Daytime HRV is best-effort — don't fail the whole screen if absent.
      Map<String, dynamic> hrv = const {};
      try {
        hrv = await api.getDayHrv(widget.date);
      } catch (_) {/* optional */}
      if (!mounted) return;
      setState(() {
        _data = res;
        _hrv = hrv;
        final stress = (res['stress'] is Map)
            ? (res['stress'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        final sleep = (res['sleep_stress'] is Map)
            ? (res['sleep_stress'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        final hasStress = stress['score'] is num;
        final hasSleep = sleep['score'] is num;
        _phase = (hasStress || hasSleep) ? _Phase.ready : _Phase.empty;

        if (hasStress) {
          final score = (stress['score'] as num).toInt();
          if (score > 70) {
            NotificationService.instance.presentEvent(
              NotificationEvent(
                dedupeKey: '${widget.date}:high_stress',
                category: NotifCategory.health,
                title: 'High Stress Detected',
                body: 'Your stress score is $score. Consider taking a moment to breathe.',
                date: widget.date,
              ),
            );
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String _prettyDate() {
    final p = widget.date.split('-');
    if (p.length != 3) return widget.date;
    final y = int.tryParse(p[0]), mo = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (y == null || mo == null || d == null || mo < 1 || mo > 12) {
      return widget.date;
    }
    final dt = DateTime(y, mo, d);
    return '${_weekdays[(dt.weekday - 1) % 7]}, ${_months[mo - 1]} $d';
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Stress',
      subtitle: _prettyDate(),
      children: [
        if (_phase == _Phase.loading) ...[
          Skeleton.hero(),
          const SizedBox(height: Sp.x3),
          Skeleton.tileRow(rows: 2),
        ] else if (_phase == _Phase.empty)
          StateCard(
            icon: OsIcon.heartRate,
            title: 'No stress reading for this day',
            message:
                'Stress is computed from your overnight HRV (beat-to-beat '
                'heart data). Wear your strap through the night and sync — it '
                'needs a few nights of baseline before it can score you '
                'against your own normal.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else if (_phase == _Phase.error)
          StateCard(
            icon: OsIcon.sync,
            title: "Couldn't load stress",
            message: _error ?? 'Please try again.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else
          StressDayContent(data: _data, hrv: _hrv, date: widget.date),
        const SizedBox(height: Sp.x8),
      ],
    );
  }
}

/// StressDayContent — the pure stress board (rose domain), testable with a
/// sample /day/stress payload: gauge hero + word, relief line, measurement
/// bento, day-rhythm context, overnight arousal, and drivers.
class StressDayContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final Map<String, dynamic> hrv; // /day/hrv payload (may be empty)
  final String date;
  const StressDayContent({
    super.key,
    required this.data,
    this.hrv = const {},
    required this.date,
  });

  // ── parsing (matches the HRV-stress response shape) ───────────────────────
  num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  Map<String, dynamic> get _stress => _map(data['stress']);
  Map<String, dynamic> get _sleepStress => _map(data['sleep_stress']);
  int? get _score => _num(_stress['score'])?.toInt();
  int? get _sleepScore => _num(_sleepStress['score'])?.toInt();
  List<double?> get _hr => [
    for (final e in ((data['hr'] as List?) ?? const []).whereType<Map>())
      () {
        final v = (_num(e['v']) ?? 0).toDouble();
        return v > 0 ? v : null;
      }(),
  ];
  List<Map> get _drivers => ((data['drivers'] as List?) ?? const [])
      .whereType<Map>()
      .where((d) => (d['label']?.toString() ?? '').isNotEmpty)
      .toList();

  /// Stress score → color (LOW stress is good; HIGH is warn/bad).
  Color _scoreColor(int v) {
    if (v < 25) return AppColors.good;
    if (v < 50) return DomainAccent.stress;
    if (v < 75) return AppColors.warn;
    return AppColors.bad;
  }

  String _word(int v) => v < 25
      ? 'Calm'
      : v < 50
          ? 'Settled'
          : v < 75
              ? 'Elevated'
              : 'High';

  /// The relief line — what to do with this number, one sentence.
  String _relief(int v) => v < 25
      ? 'Your system is settled — a good day to take on load.'
      : v < 50
          ? 'Normal daily activation. Nothing to manage here.'
          : v < 75
              ? 'Running warm — slow breaths, a walk or daylight all help it settle.'
              : 'High sympathetic load — favour easy movement and an early night.';

  String _hm(int m) {
    if (m <= 0) return '0m';
    final h = m ~/ 60, r = m % 60;
    if (h == 0) return '${r}m';
    if (r == 0) return '${h}h';
    return '${h}h ${r}m';
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final score = _score;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (score != null) ...[
          _hero(context, score).dsEnter(),
          const SizedBox(height: Sp.x2),
        ],
        _bento(context),
        ..._daySection(),
        ..._sleepSection(),
        ..._driversSection(),
      ],
    );
  }

  // ── hero — the gauge floats directly on the page, no card chrome ──────────
  Widget _hero(BuildContext context, int v) {
    final color = _scoreColor(v);
    final level = (_stress['level']?.toString().trim().isNotEmpty ?? false)
        ? _cap(_stress['level'].toString())
        : _word(v);
    return Column(
      children: [
        const SizedBox(height: Sp.x3),
        ArcGauge(
          value: (v / 100).clamp(0.0, 1.0),
          color: color,
          size: 180,
          stroke: 14,
          sweepFraction: 0.75,
          endDot: true,
          valueText: '$v',
          label: level.toLowerCase(),
        ),
        const SizedBox(height: Sp.x3),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            StatusChip(
              level,
              icon: OsIcon.recovery,
              tone: v < 50
                  ? ChipTone.positive
                  : v < 75
                      ? ChipTone.warn
                      : ChipTone.critical,
            ),
            InfoDot(
              title: 'Stress',
              body:
                  'Sympathetic "fight-or-flight" activation read from your '
                  'overnight HRV (Baevsky Stress Index), scored against your '
                  'own baseline — a body signal, not a mood. It needs a few '
                  'nights of HRV to be meaningful.',
              methodNote: 'Baevsky SI vs your rolling baseline · 0–100',
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x6),
          // The relief line — in the settled bands it carries the calm art so
          // the "nothing to manage" read lands at a glance.
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (v < 50) ...[
                const OsAppIcon(OsIcon.calm, size: 32),
                const SizedBox(width: Sp.x2),
              ],
              Flexible(
                child: Text(
                  _relief(v),
                  style: AppText.bodySoft,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x4),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x8),
            child: FilledButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CalmBreathingScreen(),
                  ),
                );
              },
              child: const Text('Calm yourself'),
            ),
          ),
        const SizedBox(height: Sp.x2),
      ],
    );
  }

  // ── the measurement bento ──────────────────────────────────────────────────
  Widget _bento(BuildContext context) {
    final si = _num(_stress['si']);
    final lfhf = _num(_stress['lf_hf']);
    final rmssd = _num(_stress['rmssd']);
    final day = _map(hrv['daytime_hrv']);
    final dayMed = _num(day['rmssd_median'])?.toInt();
    final dayN = _num(day['n_windows'])?.toInt() ?? 0;

    final left = <Widget>[
      BentoTile(
        tone: BentoTone.soft,
        accent: DomainAccent.stress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TileHeader(
              'Stress index',
              trailing: InfoDot(
                title: 'Stress index (Baevsky)',
                body:
                    'Baevsky SI from your HRV — higher means more sympathetic '
                    'activation. Scored vs your own baseline.',
              ),
            ),
            const SizedBox(height: Sp.x2),
            BigStat(value: si?.toString(), caption: 'Baevsky'),
          ],
        ),
      ),
      if (rmssd != null)
        BentoTile(
          accent: DomainAccent.recovery,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TileHeader(
                'RMSSD',
                trailing: InfoDot(title: 'RMSSD', body: infoFor('rmssd')!),
              ),
              const SizedBox(height: Sp.x2),
              BigStat(value: '$rmssd', unit: 'ms', caption: 'this read'),
            ],
          ),
        ),
    ];
    final right = <Widget>[
      if (lfhf != null)
        BentoTile(
          accent: DomainAccent.stress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TileHeader(
                'LF / HF',
                trailing: InfoDot(
                  title: 'Sympatho-vagal balance',
                  body: infoFor('lf_hf')!,
                ),
              ),
              const SizedBox(height: Sp.x2),
              BigStat(value: '$lfhf', caption: 'balance'),
            ],
          ),
        ),
      if (dayMed != null && dayN >= 3)
        BentoTile(
          tone: BentoTone.ink,
          accent: DomainAccent.recovery,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TileHeader(
                'Daytime HRV',
                trailing: InfoDot(
                  title: 'Daytime HRV',
                  body:
                      'Heart-rate variability across your waking hours '
                      '(ultradian rhythm), excluding your main sleep. Higher '
                      'generally means more recovered / parasympathetic.',
                  methodNote: '$dayN five-minute windows with enough beats',
                ),
              ),
              const SizedBox(height: Sp.x2),
              BigStat(
                value: '$dayMed',
                unit: 'ms',
                caption: 'median · $dayN windows',
              ),
            ],
          ),
        ),
    ];
    if (left.length == 1 && right.isEmpty) {
      // Lone SI tile → let it breathe full-width instead of a half column.
      return left.first;
    }
    return BentoColumns(left: left, right: right);
  }

  // ── the day's rhythm (context, not the score) ──────────────────────────────
  List<Widget> _daySection() {
    if (!detailedAvailable(date)) {
      return const [
        SizedBox(height: Sp.x3),
        DetailRetentionNote(what: 'the minute-by-minute heart rate'),
      ];
    }
    final hr = _hr;
    if (hr.whereType<double>().length < 2) return const [];
    return [
      const SizedBox(height: Sp.x3),
      SurfaceCard(
        padding: const EdgeInsets.all(Sp.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TileHeader(
              'Through the day',
              trailing: InfoDot(
                title: 'Through the day',
                body:
                    'Your heart rate across the day — shown as context for the '
                    'stress score, not what it is computed from.',
              ),
            ),
            const SizedBox(height: Sp.x3),
            Sparkline(
              hr,
              color: DomainAccent.stress,
              height: 90,
              area: true,
            ),
          ],
        ),
      ).dsEnter(index: 2),
    ];
  }

  // ── overnight arousal ──────────────────────────────────────────────────────
  List<Widget> _sleepSection() {
    final ss = _sleepStress;
    final sleepScore = _sleepScore;
    if (ss.isEmpty || sleepScore == null) return const [];
    final arousals = _num(ss['arousal_events'])?.toInt() ?? 0;
    final restless = _num(ss['restless_min'])?.toInt() ?? 0;
    // Richer movement-restlessness (calcRestlessness), distinct from HR-surge
    // arousal.
    final rest = _map(ss['restlessness']);
    final bouts = _num(rest['movement_bouts'])?.toInt();
    final stillMin = _num(rest['longest_still_min'])?.toInt();
    return [
      const SizedBox(height: Sp.x6),
      const SectionHeader('Overnight arousal'),
      BentoColumns(
        left: [
          BentoTile(
            tone: BentoTone.soft,
            accent: DomainAccent.sleep,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TileHeader(
                  'Sleep stress',
                  trailing: InfoDot(
                    title: 'Sleep stress',
                    body:
                        'Possible arousals overnight — brief heart-rate surges '
                        'with movement during sleep. Not nightmares.',
                  ),
                ),
                const SizedBox(height: Sp.x2),
                BigStat(
                  value: '$sleepScore',
                  unit: '/100',
                  caption: arousals > 0 || restless > 0
                      ? '$arousals events · ${_hm(restless)}'
                      : null,
                ),
              ],
            ),
          ),
        ],
        right: [
          if (bouts != null)
            BentoTile(
              accent: DomainAccent.sleep,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TileHeader(
                    'Restlessness',
                    trailing: InfoDot(
                      title: 'Restlessness',
                      body:
                          'How fragmented the night was — the number of times '
                          'you shifted, and your longest unbroken still '
                          'stretch.',
                    ),
                  ),
                  const SizedBox(height: Sp.x2),
                  BigStat(
                    value: '$bouts',
                    caption: stillMin != null
                        ? 'shifts · ${_hm(stillMin)} still'
                        : 'shifts',
                  ),
                ],
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _driversSection() {
    final d = _drivers;
    if (d.isEmpty) return const [];
    return [
      const SizedBox(height: Sp.x6),
      const SectionHeader('What affected this'),
      SurfaceCard(
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x4,
          vertical: Sp.x2,
        ),
        child: Column(
          children: [
            for (final dr in d)
              DetailRow(
                label: dr['label']?.toString() ?? '',
                value: dr['detail']?.toString() ?? '',
              ),
          ],
        ),
      ),
    ];
  }
}
