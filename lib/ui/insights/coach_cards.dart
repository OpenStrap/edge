// Coach + fitness cards — surface the cross-day coaching/fitness analytics
// (Sleep Coach, Strain Coach, WHOOP-Age) and the journal correlation engine
// ("Performance Assessment"). All read the precomputed `crossday` bundle via
// repo.getInsights() (or getJournalInsights), so they do ZERO heavy compute on
// read. Honest: every value traces to a tested analytics Metric; absent → a
// gentle "keep wearing" state, never a fabricated number.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

String _hhmm(num minOfDay) {
  final m = (minOfDay.round() % 1440 + 1440) % 1440;
  final h = m ~/ 60, mm = m % 60;
  return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
}

String _dur(num sec) {
  final total = sec.round();
  final h = total ~/ 3600, m = (total % 3600) ~/ 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

Map<String, dynamic>? _val(Object? metric) {
  if (metric is! Map) return null;
  final v = metric['value'];
  return v is Map ? v.cast<String, dynamic>() : null;
}

// ── SLEEP COACH ──────────────────────────────────────────────────────────────

/// Tonight's sleep need + recommended bedtime / wake, last night's sleep
/// performance, and a one-tap "set band alarm" at the cycle-aligned wake time.
class SleepCoachCard extends StatefulWidget {
  const SleepCoachCard({super.key});
  @override
  State<SleepCoachCard> createState() => _SleepCoachCardState();
}

class _SleepCoachCardState extends State<SleepCoachCard> {
  Map<String, dynamic>? _coach;
  bool _loading = true;

  LocalRepository? get _repo => context.read<AppState>().repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cd = await _repo?.getInsights();
      if (!mounted) return;
      setState(() {
        _coach = (cd?['sleep_coach'] as Map?)?.cast<String, dynamic>();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setAlarm(double wakeMin) async {
    final app = context.read<AppState>();
    if (!app.isConnected) {
      _snack('Connect your strap to set the band alarm.');
      return;
    }
    // Next occurrence of the wake clock-time (today if still ahead, else tomorrow).
    final now = DateTime.now();
    final m = (wakeMin.round() % 1440);
    var when = DateTime(now.year, now.month, now.day, m ~/ 60, m % 60);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    try {
      await app.setAlarm(when);
      _snack('Band alarm set for ${_hhmm(wakeMin)}.');
    } catch (e) {
      _snack("Couldn't set alarm: $e");
    }
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final need = _val(_coach?['need']);
    if (need == null) {
      return _CoachEmpty(
        icon: Ic.moon,
        accent: AppColors.loadDetraining,
        title: 'Sleep Coach',
        body: 'A few more nights of sleep data and your personal sleep need, '
            'bedtime and wake time will appear here.',
      );
    }
    final needSec = (need['need_sec'] as num?) ?? 0;
    final perf = _val(_coach?['performance']);
    final bedtime = _val(_coach?['bedtime']);
    final wake = _val(_coach?['wake']);
    final num? bedMin = bedtime?['bedtime_min_of_day'] as num?;
    final num? wakeMin = wake?['wake_min_of_day'] as num?;
    final pct = (perf?['pct'] as num?)?.round();
    final accent = AppColors.loadDetraining;

    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIcon(Ic.moon, size: 16, color: accent),
          const SizedBox(width: Sp.x2),
          Text('SLEEP COACH', style: AppText.overline),
          const Spacer(),
          if (pct != null) Tag('$pct% of need', color: accent),
        ]),
        const SizedBox(height: Sp.x3),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Tonight you need', style: AppText.captionMuted),
              const SizedBox(height: 2),
              Text(_dur(needSec), style: AppText.h2.copyWith(color: accent)),
            ]),
          ),
          if (pct != null)
            RingStat(
              t: pct / 100.0,
              color: accent,
              size: 70,
              stroke: 9,
              center: Text('$pct%', style: AppText.label),
            ),
        ]),
        const SizedBox(height: Sp.x4),
        if (bedMin != null)
          _row(Ic.moon, accent, 'Recommended bedtime', _hhmm(bedMin)),
        if (wakeMin != null)
          _row(Ic.bell, AppColors.coral, 'Wake (cycle-aligned)', _hhmm(wakeMin)),
        if (wakeMin != null) ...[
          const SizedBox(height: Sp.x3),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _setAlarm(wakeMin.toDouble()),
              icon: const AppIcon(Ic.bell, size: 16, color: Colors.white),
              label: Text('Set band alarm for ${_hhmm(wakeMin)}'),
            ),
          ),
          const SizedBox(height: Sp.x2),
          Text(
              'Your strap buzzes at this time — set on the band, so it works even '
              'with the app closed. Aligned to a ~90-min cycle so it lands near '
              'light sleep.',
              style: AppText.captionMuted),
        ],
      ]),
    );
  }

  Widget _row(IconData icon, Color accent, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x2),
        child: Row(children: [
          AppIcon(icon, size: 15, color: accent),
          const SizedBox(width: Sp.x3),
          Expanded(child: Text(label, style: AppText.body)),
          Text(value, style: AppText.label),
        ]),
      );
}

// ── STRAIN COACH ─────────────────────────────────────────────────────────────

/// Today's recovery-gated strain target (a band on the 0–21 scale) + rationale.
class StrainCoachCard extends StatefulWidget {
  const StrainCoachCard({super.key});
  @override
  State<StrainCoachCard> createState() => _StrainCoachCardState();
}

class _StrainCoachCardState extends State<StrainCoachCard> {
  Map<String, dynamic>? _t;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cd = await context.read<AppState>().repo?.getInsights();
      if (!mounted) return;
      setState(() {
        _t = _val(cd?['strain_coach']);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  static final _bandColor = <String, Color>{
    'recover': AppColors.good,
    'ease': AppColors.good,
    'maintain': AppColors.warn,
    'push': AppColors.coral,
  };
  static const _bandLabel = {
    'recover': 'Recover',
    'ease': 'Take it easy',
    'maintain': 'Maintain',
    'push': 'Push',
  };

  @override
  Widget build(BuildContext context) {
    if (_loading || _t == null) return const SizedBox.shrink();
    final lo = (_t!['target_min'] as num?)?.toStringAsFixed(0) ?? '—';
    final hi = (_t!['target_max'] as num?)?.toStringAsFixed(0) ?? '—';
    final band = _t!['band'] as String? ?? 'maintain';
    final rationale = _t!['rationale'] as String? ?? '';
    final accent = _bandColor[band] ?? AppColors.coral;

    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIcon(Ic.strain, size: 16, color: accent),
          const SizedBox(width: Sp.x2),
          Text('STRAIN COACH', style: AppText.overline),
          const Spacer(),
          Tag(_bandLabel[band] ?? band, color: accent),
        ]),
        const SizedBox(height: Sp.x3),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$lo–$hi', style: AppText.h1.copyWith(color: accent)),
          const SizedBox(width: Sp.x2),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('target strain today', style: AppText.captionMuted),
          ),
        ]),
        if (rationale.isNotEmpty) ...[
          const SizedBox(height: Sp.x2),
          Text(rationale, style: AppText.captionMuted),
        ],
      ]),
    );
  }
}

// ── WHOOP-AGE / fitness ──────────────────────────────────────────────────────

/// Physiological "age" vs chronological + VO₂max estimate.
class WhoopAgeCard extends StatefulWidget {
  const WhoopAgeCard({super.key});
  @override
  State<WhoopAgeCard> createState() => _WhoopAgeCardState();
}

class _WhoopAgeCardState extends State<WhoopAgeCard> {
  Map<String, dynamic>? _age;
  num? _vo2;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cd = await context.read<AppState>().repo?.getInsights();
      if (!mounted) return;
      setState(() {
        _age = _val(cd?['whoop_age']);
        final v = cd?['vo2max'];
        _vo2 = v is Map ? v['value'] as num? : null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_age == null && _vo2 == null) {
      return _CoachEmpty(
        icon: Ic.pulse,
        accent: AppColors.good,
        title: 'Fitness age',
        body: 'Your VO₂max and physiological age build from resting heart rate, '
            'HRV, sleep and activity — keep wearing the strap.',
      );
    }
    final pa = (_age?['physio_age'] as num?)?.round();
    final delta = (_age?['delta_years'] as num?)?.toDouble();
    final younger = delta != null && delta < 0;
    final accent = younger ? AppColors.good : AppColors.warn;

    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIcon(Ic.pulse, size: 16, color: accent),
          const SizedBox(width: Sp.x2),
          Text('FITNESS AGE', style: AppText.overline),
        ]),
        const SizedBox(height: Sp.x3),
        Row(children: [
          if (pa != null)
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$pa', style: AppText.h1.copyWith(color: accent)),
                Text('physiological age', style: AppText.captionMuted),
                if (delta != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    delta == 0
                        ? 'on par with your age'
                        : '${delta.abs().toStringAsFixed(1)} years '
                            '${younger ? 'younger' : 'older'} than your age',
                    style: AppText.caption.copyWith(color: accent),
                  ),
                ],
              ]),
            ),
          if (_vo2 != null)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_vo2!.toStringAsFixed(0),
                  style: AppText.h2.copyWith(color: AppColors.coral)),
              Text('VO₂max', style: AppText.captionMuted),
              Text('ml/kg/min', style: AppText.captionMuted),
            ]),
        ]),
        const SizedBox(height: Sp.x2),
        Text('An estimate from your own data — directional, not a lab test.',
            style: AppText.captionMuted),
      ]),
    );
  }
}

// ── PERFORMANCE ASSESSMENT (journal correlations) ────────────────────────────

/// WHOOP-style "your behaviours vs your outcomes" — strongest journal-tag
/// correlations (e.g. "alcohol → −12% recovery"), from the correlation engine.
class PerformanceAssessmentCard extends StatefulWidget {
  const PerformanceAssessmentCard({super.key});
  @override
  State<PerformanceAssessmentCard> createState() =>
      _PerformanceAssessmentCardState();
}

class _PerformanceAssessmentCardState
    extends State<PerformanceAssessmentCard> {
  List<Map<String, dynamic>> _insights = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().repo?.getJournalInsights();
      final list = (r?['insights'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _insights = [for (final e in list) (e as Map).cast<String, dynamic>()];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _pretty(String tag) =>
      tag.isEmpty ? tag : tag[0].toUpperCase() + tag.substring(1).replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) {
    if (_loading || _insights.isEmpty) return const SizedBox.shrink();
    final top = _insights.take(5).toList();
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIcon(Ic.chart, size: 16, color: AppColors.coral),
          const SizedBox(width: Sp.x2),
          Text('PERFORMANCE ASSESSMENT', style: AppText.overline),
        ]),
        const SizedBox(height: Sp.x2),
        Text('How your logged behaviours move your numbers', style: AppText.captionMuted),
        const SizedBox(height: Sp.x3),
        for (final i in top) _insightRow(i),
        const SizedBox(height: Sp.x2),
        Text('Association from your journal, not proof of cause. The more you log, '
            'the sharper this gets.', style: AppText.captionMuted),
      ]),
    );
  }

  Widget _insightRow(Map<String, dynamic> i) {
    final helped = i['helped'] == true;
    final accent = helped ? AppColors.good : AppColors.coral;
    final pct = (i['delta_pct'] as num?)?.abs().toStringAsFixed(0) ?? '—';
    final dir = helped ? Ic.up : Ic.down;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x2),
      child: Row(children: [
        AppIcon(dir, size: 15, color: accent),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Text('${_pretty(i['tag'] as String? ?? '')} · '
              '${i['outcome_label'] ?? ''}', style: AppText.body),
        ),
        Text('${helped ? '+' : '−'}$pct%',
            style: AppText.label.copyWith(color: accent)),
      ]),
    );
  }
}

// ── shared empty state ───────────────────────────────────────────────────────

class _CoachEmpty extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String body;
  const _CoachEmpty(
      {required this.icon,
      required this.accent,
      required this.title,
      required this.body});
  @override
  Widget build(BuildContext context) => ProCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppIcon(icon, size: 16, color: accent),
            const SizedBox(width: Sp.x2),
            Text(title.toUpperCase(), style: AppText.overline),
          ]),
          const SizedBox(height: Sp.x2),
          Text(body, style: AppText.captionMuted),
        ]),
      );
}
