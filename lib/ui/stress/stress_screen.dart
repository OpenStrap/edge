// Stress — HRV-based sympathetic activation (Baevsky Stress Index + LF/HF),
// personal-relative. Backed by /day/stress, which returns:
//   { stress:{score,si,lf_hf,rmssd,level,drivers}, sleep_stress:{...}, drivers, hr:[{t,v}] }
// (The old HR-above-resting "arousal band" model was removed — this reads the real
// HRV stress. Nocturnal arousal lives under sleep_stress.)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import '../screens/metric_row.dart';

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
      setState(() { _phase = _Phase.error; _error = 'Not signed in.'; });
      return;
    }
    setState(() { _phase = _Phase.loading; _error = null; });
    try {
      final res = await api.getDayStress(widget.date);
      // Daytime HRV is best-effort — don't fail the whole screen if it's absent.
      Map<String, dynamic> hrv = const {};
      try { hrv = await api.getDayHrv(widget.date); } catch (_) {/* optional */}
      if (!mounted) return;
      setState(() {
        _data = res;
        _hrv = hrv;
        final hasStress = _stress.isNotEmpty && _score != null;
        final hasSleep = _sleepStress.isNotEmpty && _sleepScore != null;
        _phase = (hasStress || hasSleep) ? _Phase.ready : _Phase.empty;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  // ── parsing (matches the HRV-stress response shape) ──────────────────────────
  num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
  Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

  Map<String, dynamic> get _stress => _map(_data['stress']);
  Map<String, dynamic> get _sleepStress => _map(_data['sleep_stress']);
  int? get _score => _num(_stress['score'])?.toInt();
  int? get _sleepScore => _num(_sleepStress['score'])?.toInt();
  List<double> get _hr => ((_data['hr'] as List?) ?? const [])
      .map((e) => (_num((e as Map)['v']) ?? 0).toDouble())
      .where((v) => v > 0)
      .toList();
  List<Map> get _drivers =>
      ((_data['drivers'] as List?) ?? const []).whereType<Map>()
          .where((d) => (d['label']?.toString() ?? '').isNotEmpty).toList();

  /// Stress score → color (LOW stress is good; HIGH is warn/bad).
  Color _scoreColor(int v) {
    if (v < 25) return AppColors.good;
    if (v < 50) return AppColors.coral;
    if (v < 75) return AppColors.warn;
    return AppColors.bad;
  }

  String _bandLabel(int v) =>
      v < 25 ? 'Low' : v < 50 ? 'Moderate' : v < 75 ? 'Elevated' : 'High';

  String _hm(int m) {
    if (m <= 0) return '0m';
    final h = m ~/ 60, r = m % 60;
    if (h == 0) return '${r}m';
    if (r == 0) return '${h}h';
    return '${h}h ${r}m';
  }

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static const _weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  String _prettyDate() {
    final p = widget.date.split('-');
    if (p.length != 3) return widget.date;
    final y = int.tryParse(p[0]), mo = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (y == null || mo == null || d == null || mo < 1 || mo > 12) return widget.date;
    final dt = DateTime(y, mo, d);
    return '${_weekdays[(dt.weekday - 1) % 7]}, ${_months[mo - 1]} $d';
  }

  // ── build ──────────────────────────────────────────────────────────────────
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
              _stateCard(Ic.pulse, 'No stress reading for this day',
                  'Stress is computed from your overnight HRV (beat-to-beat heart data). '
                  'Wear your strap through the night and sync — it needs a few nights of '
                  'baseline before it can score you against your own normal.')
            else if (_phase == _Phase.error)
              _stateCard(Ic.cloud, "Couldn't load stress", _error ?? 'Please try again.')
            else ...[
              if (_score != null) _hero(),
              ..._hrvSection(),
              ..._daytimeHrvSection(),
              ..._timelineSection(),
              ..._sleepStressSection(),
              ..._driversSection(),
              const SizedBox(height: Sp.x6),
              _honesty(),
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
            Text('Stress', style: AppText.h1),
            const SizedBox(height: 2),
            Text(_prettyDate(), style: AppText.caption),
          ],
        )),
      ]);

  Widget _hero() {
    final v = _score!;
    final color = _scoreColor(v);
    final level = (_stress['level']?.toString().trim().isNotEmpty ?? false)
        ? _cap(_stress['level'].toString())
        : _bandLabel(v);
    return GlowCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Row(children: [
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              AppIcon(Ic.pulse, size: 16, color: AppColors.coralDeep),
              const SizedBox(width: Sp.x2),
              Text('STRESS', style: AppText.overline),
              const SizedBox(width: Sp.x2),
              Tag('HRV', color: AppColors.good),
            ]),
            const SizedBox(height: Sp.x3),
            Text('$v', style: AppText.display.copyWith(color: color)),
            const SizedBox(height: Sp.x1),
            Text('$level · sympathetic activation from your HRV', style: AppText.bodySoft),
          ],
        )),
        const SizedBox(width: Sp.x4),
        RingStat(
          t: (v / 100).clamp(0.0, 1.0), color: color, size: 104, stroke: 11,
          center: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$v', style: AppText.metricSm.copyWith(fontSize: 20, color: color)),
            Text('/100', style: AppText.captionMuted),
          ]),
        ),
      ]),
    );
  }

  List<Widget> _hrvSection() {
    final si = _num(_stress['si']);
    final lfhf = _num(_stress['lf_hf']);
    final rmssd = _num(_stress['rmssd']);
    if (si == null && lfhf == null && rmssd == null) return const [];
    return [
      const SizedBox(height: Sp.x6),
      const SectionHeader('How it was measured'),
      MetricGroup([
        if (si != null)
          MetricRow(icon: Ic.strain, accent: AppColors.warn, label: 'Stress index (Baevsky)',
              info: 'Baevsky SI from your HRV — higher = more sympathetic activation. Scored vs your own baseline.',
              value: '$si'),
        if (lfhf != null)
          MetricRow(icon: Ic.pulse, accent: AppColors.warn, label: 'Sympatho-vagal balance',
              info: infoFor('lf_hf'), value: '$lfhf'),
        if (rmssd != null)
          MetricRow(icon: Ic.pulse, accent: AppColors.good, label: 'RMSSD (this read)',
              info: infoFor('rmssd'), value: '$rmssd', unit: 'ms'),
      ]),
    ];
  }

  List<Widget> _timelineSection() {
    if (!detailedAvailable(widget.date)) {
      return const [SizedBox(height: Sp.x6), DetailRetentionNote(what: 'the minute-by-minute heart rate')];
    }
    final hr = _hr;
    if (hr.length < 2) return const [];
    return [
      const SizedBox(height: Sp.x6),
      const SectionHeader('Heart rate (context)'),
      ProCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AreaSpark(hr, color: AppColors.coral, height: 90),
        const SizedBox(height: Sp.x2),
        Text('Your heart rate across the day — shown for context, not the stress score.',
            style: AppText.captionMuted),
      ])),
    ];
  }

  List<Widget> _sleepStressSection() {
    final ss = _sleepStress;
    if (ss.isEmpty || _sleepScore == null) return const [];
    final arousals = _num(ss['arousal_events'])?.toInt() ?? 0;
    final restless = _num(ss['restless_min'])?.toInt() ?? 0;
    // Richer movement-restlessness (calcRestlessness), distinct from HR-surge arousal.
    final rest = _map(ss['restlessness']);
    final bouts = _num(rest['movement_bouts'])?.toInt();
    final stillMin = _num(rest['longest_still_min'])?.toInt();
    return [
      const SizedBox(height: Sp.x6),
      const SectionHeader('Overnight arousal'),
      ProCard(child: Column(children: [
        MetricRow(icon: Ic.moon, accent: AppColors.loadDetraining, label: 'Sleep stress',
            info: 'Possible arousals overnight — brief heart-rate surges with movement during sleep.',
            value: '$_sleepScore', unit: '/100'),
        if (arousals > 0 || restless > 0)
          MetricRow(icon: Ic.activity, accent: AppColors.inkSoft, label: 'Disturbance',
              info: 'Count of possible arousals and total restless time.',
              value: '$arousals events · ${_hm(restless)}'),
        if (bouts != null)
          MetricRow(icon: Ic.activity, accent: AppColors.inkSoft, label: 'Restlessness',
              info: 'How fragmented the night was — number of times you shifted, and your longest unbroken still stretch.',
              value: stillMin != null ? '$bouts shifts · ${_hm(stillMin)} still' : '$bouts shifts'),
      ])),
    ];
  }

  // Daytime (waking) HRV — the ultradian RMSSD rhythm from /day/hrv. Complements the
  // nocturnal recovery score: a sense of autonomic state across the day.
  List<Widget> _daytimeHrvSection() {
    final h = _map(_hrv['daytime_hrv']);
    final med = _num(h['rmssd_median'])?.toInt();
    final n = _num(h['n_windows'])?.toInt() ?? 0;
    if (med == null || n < 3) return const [];
    return [
      const SizedBox(height: Sp.x6),
      const SectionHeader('Daytime HRV'),
      ProCard(child: Column(children: [
        MetricRow(icon: Ic.pulse, accent: AppColors.good, label: 'Median daytime RMSSD',
            info: 'Heart-rate variability across your waking hours (ultradian rhythm), excluding your main sleep. Higher generally means more recovered/parasympathetic.',
            value: '$med', unit: 'ms'),
        MetricRow(icon: Ic.activity, accent: AppColors.inkSoft, label: 'Coverage',
            info: 'Number of 5-minute windows with enough beat-to-beat data to measure.',
            value: '$n', unit: 'windows'),
      ])),
    ];
  }

  List<Widget> _driversSection() {
    final d = _drivers;
    if (d.isEmpty) return const [];
    return [
      const SizedBox(height: Sp.x6),
      const SectionHeader('What affected this'),
      ProCard(child: Column(children: [
        for (final dr in d)
          DetailRow(label: dr['label']?.toString() ?? '', value: dr['detail']?.toString() ?? ''),
      ])),
    ];
  }

  Widget _honesty() => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppIcon(Ic.info, size: 14, color: AppColors.inkMuted),
        const SizedBox(width: Sp.x2),
        Expanded(child: Text(
          'Daytime stress here is your nocturnal HRV (Baevsky Stress Index), scored '
          'against your own baseline — sympathetic "fight-or-flight" load, not a mood. '
          'Overnight arousal is brief heart-rate surges with movement during sleep, not '
          'nightmares. Both need a few nights of HRV to be meaningful.',
          style: AppText.captionMuted,
        )),
      ]);

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

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
