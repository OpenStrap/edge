// Sleep detail for one night — hypnogram, stage breakdown, efficiency, debt,
// consistency, and nocturnal heart. Backed by /day/sleep.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import '../screens/metric_row.dart';
import '../screens/trend_screen.dart';
import 'sleep_periods_screen.dart';

class SleepDetailScreen extends StatefulWidget {
  final String date; // 'YYYY-MM-DD'
  // When true, render just the section content (no Scaffold/back bar) so it can be
  // embedded inside the Sleep screen (Today/Week/Month/3M). This is the EXACT
  // same loved layout — only the chrome differs.
  final bool embedded;
  const SleepDetailScreen({super.key, required this.date, this.embedded = false});

  /// Convenience: a detail screen for today (local).
  factory SleepDetailScreen.today({Key? key}) {
    final d = DateTime.now();
    final s =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return SleepDetailScreen(key: key, date: s);
  }

  @override
  State<SleepDetailScreen> createState() => _SleepDetailScreenState();
}

enum _Phase { loading, ready, empty, error }

/// One compressed run of a stage in the hypnogram.
class _Seg {
  final String stage; // 'awake' | 'light' | 'deep' | 'rem'
  final int seconds;
  const _Seg(this.stage, this.seconds);
}

class _SleepDetailScreenState extends State<SleepDetailScreen> {
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
      final res = await api.getDaySleep(widget.date);
      if (!mounted) return;
      final hasSleep = _bool(res['has_sleep']) ?? false;
      setState(() {
        _data = res;
        _phase = hasSleep ? _Phase.ready : _Phase.empty;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  // ── defensive parsing ──────────────────────────────────────────────────────

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  bool? _bool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == 'true' || v == '1';
    return null;
  }

  num? get _durationMin => _num(_data['duration_min']);
  num? get _needMin => _num(_data['need_min']);
  num? get _inBedMin => _num(_data['in_bed_min']);
  num? get _awakeMin => _num(_data['awake_min']);
  num? get _debtMin => _num(_data['debt_min']);
  num? get _efficiency => _num(_data['efficiency']); // 0..1
  num? get _regularity => _num(_data['regularity']); // 0..100
  bool get _stagesBeta => _bool(_data['stages_beta']) ?? false;

  // Where this night's window came from: auto / auto_fallback / manual / confirmed
  // / none. Drives the confirm prompt + the manual-edit affordance.
  String get _sleepSource => (_data['sleep_source'] as String?) ?? 'auto';

  // 4-class wrist stager: Awake / Light / Deep / REM. Light+Deep is the legacy
  // combined "Core" (nrem_min). Deep is a LOW-CONFIDENCE overlay; the whole stage
  // block is badged as an estimate. All values come from the day-sleep payload.
  num? get _lightMin => _num(_data['light_min']);
  num? get _deepMin => _num(_data['deep_min']);
  num? get _remMin => _num(_data['rem_min']);

  // Sleep cycles (ultradian NREM↔REM, fractal-cycle method on HRV). Beta.
  List<Map<String, dynamic>> get _cycles {
    final raw = _data['cycles'];
    if (raw is! List) return const [];
    return raw.map((e) => _map(e)).where((m) => m.isNotEmpty).toList();
  }

  num? get _cyclesMean => _num(_data['cycles_mean_min']);

  List<MapEntry<int, double>> get _cycleSeries {
    final raw = _data['cycle_series'];
    if (raw is! List) return const [];
    final out = <MapEntry<int, double>>[];
    for (final p in raw) {
      final m = _map(p);
      final t = _num(m['t'])?.toInt();
      final z = _num(m['z'])?.toDouble();
      if (t != null && z != null) out.add(MapEntry(t, z));
    }
    out.sort((a, b) => a.key.compareTo(b.key));
    return out;
  }

  Map<String, dynamic> get _nocturnal => _map(_data['nocturnal']);
  Map<String, dynamic> get _resp => _map(_data['resp']);
  bool get _hasNocturnal => _num(_nocturnal['sleeping_hr_avg']) != null;

  // Parallel 4-class AASM read (Cole–Kripke/DoG stager). ESTIMATE; shown below
  // the single-source stages as a "beta" cross-check.
  Map<String, dynamic> get _advanced => _map(_data['advanced']);
  bool get _hasAdvanced => _advanced['present'] == true;

  // Low-confidence WRIST orientation (gravity-tilt) during sleep. A body-position
  // PROXY only — the wrist moves independently of the torso, so this is NOT the
  // sleeper's supine/side/prone body position.
  Map<String, dynamic> get _wristOri => _map(_data['wrist_orientation']);

  /// Compressed hypnogram: consecutive same-stage points merged into segments.
  List<_Seg> _segments() {
    final raw = _data['hypnogram'];
    if (raw is! List || raw.length < 2) return const [];
    final pts = <MapEntry<int, String>>[];
    for (final p in raw) {
      final m = _map(p);
      final t = _num(m['t'])?.toInt();
      final stage = m['stage'];
      if (t == null || stage is! String) continue;
      pts.add(MapEntry(t, stage));
    }
    if (pts.length < 2) return const [];
    pts.sort((a, b) => a.key.compareTo(b.key));

    final out = <_Seg>[];
    for (int i = 0; i < pts.length - 1; i++) {
      final dur = pts[i + 1].key - pts[i].key;
      if (dur <= 0) continue;
      final stage = pts[i].value;
      if (out.isNotEmpty && out.last.stage == stage) {
        out[out.length - 1] = _Seg(stage, out.last.seconds + dur);
      } else {
        out.add(_Seg(stage, dur));
      }
    }
    return out;
  }

  // ── formatting (no intl) ────────────────────────────────────────────────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static const _weekdays = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
  ];

  /// 'Wed, Jun 11' from the 'YYYY-MM-DD' param (no intl).
  String _prettyDate() {
    final parts = widget.date.split('-');
    if (parts.length != 3) return widget.date;
    final y = int.tryParse(parts[0]);
    final mo = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || mo == null || d == null) return widget.date;
    final dt = DateTime(y, mo, d);
    final wd = _weekdays[(dt.weekday - 1) % 7];
    final mname = (mo >= 1 && mo <= 12) ? _months[mo - 1] : '';
    return '$wd, $mname $d';
  }

  /// HH:MM (local) from an epoch-seconds value.
  String _clock(num? epochSec) {
    if (epochSec == null) return '—';
    final dt =
        DateTime.fromMillisecondsSinceEpoch(epochSec.toInt() * 1000).toLocal();
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// 'Hh Mm' from minutes.
  String _hm(num? minutes) {
    if (minutes == null) return '—';
    final m = minutes.round();
    if (m <= 0) return '0m';
    final h = m ~/ 60;
    final r = m % 60;
    if (h == 0) return '${r}m';
    if (r == 0) return '${h}h';
    return '${h}h ${r}m';
  }

  /// Whole hours (for the "of Nh need" line).
  String _hours(num? minutes) {
    if (minutes == null) return '—';
    return (minutes / 60).toStringAsFixed(1);
  }

  // ── stage colors / labels ─────────────────────────────────────────────────

  // Four stage colors: Awake (muted) / Light (light orange) / Deep (deep coral) /
  // REM (coral). 'nrem' maps to Light for any legacy combined-Core data.
  Color _stageColor(String stage) {
    switch (stage) {
      case 'awake':
        return AppColors.inkMuted;
      case 'rem':
        return AppColors.coral;
      case 'deep':
        return AppColors.coralDeep;
      case 'light':
      case 'nrem': // legacy combined Core → render as Light
        return kLightStageColor;
      default:
        return AppColors.inkMuted;
    }
  }

  // 4-class labels: Awake / Light / Deep / REM. Deep is a low-confidence overlay;
  // the surrounding card carries the "estimated, low confidence" badge.
  String _stageLabel(String stage) {
    switch (stage) {
      case 'awake':
        return 'Awake';
      case 'rem':
        return 'REM';
      case 'deep':
        return 'Deep';
      case 'light':
      case 'nrem':
        return 'Light';
      default:
        return stage;
    }
  }

  // ── build ──────────────────────────────────────────────────────────────────

  /// The night's sections (phase-aware). Shared by the standalone screen and the
  /// embedded mode so the layout is identical.
  List<Widget> _sections() {
    if (_phase == _Phase.loading) return [_loading()];
    if (_phase == _Phase.empty) {
      return [
        _stateCard(Ic.moon, 'No sleep recorded for this night',
            'Wear your strap overnight and sync. Your sleep breakdown will '
                'appear here once a night has been recorded.'),
        const SizedBox(height: Sp.x4),
        // Approach 1: let the user enter the window so we can still stage it.
        _manualEntryCard(),
      ];
    }
    if (_phase == _Phase.error) {
      return [_stateCard(Ic.cloud, "Couldn't load this night", _error ?? 'Please try again.')];
    }
    return [
      // Provenance: when this night was rescued by the HR-led fallback, ask the
      // user to confirm/correct it; for any night, allow an edit.
      if (_sleepSource == 'auto_fallback') ...[
        _fallbackConfirmBanner(),
        const SizedBox(height: Sp.x4),
      ] else if (_sleepSource == 'manual' || _sleepSource == 'confirmed') ...[
        _manualBadge(),
        const SizedBox(height: Sp.x4),
      ],
      // ── TRUSTWORTHY BLOCK FIRST ──────────────────────────────────────────
      // Lead with the figures we stand behind: duration, efficiency, and the
      // onset/wake timing. These come straight from the van Hees window +
      // asleep/awake accounting (not the stage model), so they head the screen.
      _hero(),
      const SizedBox(height: Sp.x4),
      _timingCard(),
      const SizedBox(height: Sp.x6),
      SectionHeader('Efficiency'),
      _efficiencyCard(),
      const SizedBox(height: Sp.x6),
      SectionHeader('Sleep debt'),
      _debtCard(),
      const SizedBox(height: Sp.x6),
      SectionHeader('Consistency'),
      _consistencyCard(),
      // ── ESTIMATED STAGE BLOCK (below the trustworthy numbers) ────────────
      const SizedBox(height: Sp.x6),
      SectionHeader('Sleep stages'),
      _stagesEstimateBadge(),
      const SizedBox(height: Sp.x3),
      // Minute-level hypnogram only for recent nights; older nights keep the
      // stage breakdown below (that is permanent).
      detailedAvailable(widget.date)
          ? _hypnogramCard()
          : const DetailRetentionNote(what: 'sleep hypnogram'),
      const SizedBox(height: Sp.x4),
      _stageBreakdown(),
      // Cycles sit directly under Stages (same block — not a separate section).
      if (detailedAvailable(widget.date) && _cycles.isNotEmpty) ...[
        const SizedBox(height: Sp.x3),
        _cyclesCard(),
      ],
      if (_hasAdvanced) ...[
        const SizedBox(height: Sp.x6),
        const SectionHeader('Advanced stages (beta)'),
        _advancedCard(),
      ],
      if (_hasNocturnal) ...[
        const SizedBox(height: Sp.x6),
        SectionHeader('Nocturnal heart'),
        _nocturnalCard(),
      ],
      if (_wristOri['dominant'] is String) ...[
        const SizedBox(height: Sp.x6),
        const SectionHeader('Wrist orientation (low confidence)'),
        _wristOrientationCard(),
      ],
      // Tap any of these into its Week/Month/3M trend.
      const SizedBox(height: Sp.x6),
      const SectionHeader('Trends'),
      MetricGroup([
        TrendMetricRow(icon: Ic.moon, accent: AppColors.coral, label: 'Time asleep',
            info: infoFor('sleep'), value: _hm(_durationMin), metric: 'sleep', trendTitle: 'Sleep',
            valueFmt: (v) => v == 0 ? '' : (v / 60).toStringAsFixed(1)),
        if (_efficiency != null)
          TrendMetricRow(icon: Ic.chart, accent: AppColors.good, label: 'Efficiency',
              info: infoFor('efficiency'), value: '${(_efficiency! * 100).round()}', unit: '%',
              metric: 'efficiency', trendTitle: 'Sleep efficiency'),
        if (_lightMin != null)
          TrendMetricRow(icon: Ic.pulse, accent: kLightStageColor, label: 'Light sleep',
              info: infoFor('light'), value: _hm(_lightMin), metric: 'light', trendTitle: 'Light sleep'),
        if (_deepMin != null)
          TrendMetricRow(icon: Ic.pulse, accent: AppColors.coralDeep, label: 'Deep sleep',
              info: infoFor('deep'), value: _hm(_deepMin), metric: 'deep', trendTitle: 'Deep sleep'),
        if (_remMin != null)
          TrendMetricRow(icon: Ic.pulse, accent: AppColors.coralSoft, label: 'REM sleep',
              info: infoFor('rem'), value: _hm(_remMin), metric: 'rem', trendTitle: 'REM sleep'),
        if (_regularity != null)
          TrendMetricRow(icon: Ic.calendar, accent: AppColors.good, label: 'Consistency',
              info: infoFor('regularity'), value: '${_regularity!.round()}', metric: 'regularity',
              trendTitle: 'Sleep consistency')
        else
          // Honest gated state: SRI needs several nights of sleep timing.
          MetricRow(icon: Ic.calendar, accent: AppColors.inkSoft, label: 'Consistency',
              info: infoFor('regularity'), value: 'Need a few more nights'),
      ]),
      // Any night can be corrected by hand.
      const SizedBox(height: Sp.x6),
      _editTimesFooter(),
    ];
  }

  // ── manual sleep entry + fallback confirm (Approaches 1 & 2) ────────────────

  /// Small pill action used by the sleep-source widgets.
  Widget _pill(String label, Color bg, Color fg, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(R.pill),
        ),
        child: Text(label, style: AppText.label.copyWith(color: fg)),
      ),
    );
  }

  /// No-sleep night → offer to enter the window manually so we can still stage it.
  Widget _manualEntryCard() {
    return ProCard(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Slept but nothing showed up?', style: AppText.title),
            const SizedBox(height: Sp.x2),
            Text(
              'A restless night or a loose band can hide sleep from auto-detection. '
              'Enter when you slept and we’ll work out the rest from your data.',
              style: AppText.captionMuted,
            ),
            const SizedBox(height: Sp.x4),
            _pill('Add sleep times', AppColors.coral, Colors.white,
                _editSleepTimes),
          ],
        ),
      ),
    );
  }

  /// Fallback night → "estimated from heart rate, is this right?"
  Widget _fallbackConfirmBanner() {
    return ProCard(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Estimated from your heart rate', style: AppText.title),
            const SizedBox(height: Sp.x2),
            Text(
              'We couldn’t detect this night from movement, so we estimated it from '
              'your heart-rate dip. Does the timing look right?',
              style: AppText.captionMuted,
            ),
            const SizedBox(height: Sp.x4),
            Row(children: [
              _pill('Looks right', AppColors.coral, Colors.white,
                  _confirmFallback),
              const SizedBox(width: Sp.x3),
              _pill('Edit', AppColors.surfaceAlt, AppColors.inkMuted,
                  _editSleepTimes),
            ]),
          ],
        ),
      ),
    );
  }

  /// Manual / confirmed night → small badge + edit / revert.
  Widget _manualBadge() {
    final confirmed = _sleepSource == 'confirmed';
    return ProCard(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x4),
        child: Row(children: [
          AppIcon(Ic.check, size: 16, color: AppColors.good),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Text(
              confirmed ? 'You confirmed these times' : 'You set these times',
              style: AppText.caption,
            ),
          ),
          _pill('Edit', AppColors.surfaceAlt, AppColors.inkMuted,
              _editSleepTimes),
          const SizedBox(width: Sp.x2),
          _pill('Use auto', AppColors.surfaceAlt, AppColors.inkMuted,
              _clearOverride),
        ]),
      ),
    );
  }

  /// Subtle "fix it" affordance shown under an auto-detected night.
  Widget _editTimesFooter() {
    if (_sleepSource != 'auto') return const SizedBox.shrink();
    return Center(
      child: TextButton(
        onPressed: _editSleepTimes,
        child: Text('Sleep times look off? Fix them',
            style: AppText.caption.copyWith(color: AppColors.inkMuted)),
      ),
    );
  }

  /// Two time pickers (onset, wake) → store the window + restage the day.
  Future<void> _editSleepTimes() async {
    final existingOnset = _num(_data['onset_ts']);
    final existingWake = _num(_data['wake_ts']);
    TimeOfDay todFrom(num? sec, TimeOfDay fallback) => sec == null
        ? fallback
        : TimeOfDay.fromDateTime(
            DateTime.fromMillisecondsSinceEpoch(sec.toInt() * 1000).toLocal());

    final onset = await showTimePicker(
      context: context,
      initialTime: todFrom(existingOnset, const TimeOfDay(hour: 23, minute: 0)),
      helpText: 'When did you fall asleep?',
    );
    if (onset == null || !mounted) return;
    final wake = await showTimePicker(
      context: context,
      initialTime: todFrom(existingWake, const TimeOfDay(hour: 7, minute: 0)),
      helpText: 'When did you wake up?',
    );
    if (wake == null || !mounted) return;

    final parts = widget.date.split('-').map(int.tryParse).toList();
    if (parts.length != 3 || parts.any((e) => e == null)) return;
    final wakeDay = DateTime(parts[0]!, parts[1]!, parts[2]!);
    // An evening onset (≥ noon) belongs to the PREVIOUS calendar day.
    final onsetDay = onset.hour >= 12
        ? wakeDay.subtract(const Duration(days: 1))
        : wakeDay;
    var onsetDt = DateTime(
        onsetDay.year, onsetDay.month, onsetDay.day, onset.hour, onset.minute);
    var wakeDt = DateTime(
        wakeDay.year, wakeDay.month, wakeDay.day, wake.hour, wake.minute);
    if (!wakeDt.isAfter(onsetDt)) {
      wakeDt = wakeDt.add(const Duration(days: 1));
    }

    final app = context.read<AppState>();
    await _runOverride(() => app.setSleepOverride(widget.date, onsetDt, wakeDt));
  }

  Future<void> _confirmFallback() async {
    final app = context.read<AppState>();
    await _runOverride(() => app.confirmSleep(widget.date));
  }

  Future<void> _clearOverride() async {
    final app = context.read<AppState>();
    await _runOverride(() => app.clearSleepOverride(widget.date));
  }

  /// Run a sleep-override change with a busy overlay, then reload this night.
  Future<void> _runOverride(Future<void> Function() action) async {
    setState(() => _phase = _Phase.loading);
    try {
      await action();
    } catch (_) {
      // fall through to reload; _load surfaces any real error
    }
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    // Embedded in the Sleep screen: just the sections (its ListView scrolls).
    if (widget.embedded) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: _sections());
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          color: AppColors.coral,
          child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            _topBar(),
            const SizedBox(height: Sp.x6),
            ..._sections(),
            const SizedBox(height: 40),
          ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        RoundIconButton(Ic.arrowLeft,
            onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sleep', style: AppText.h1),
              const SizedBox(height: 2),
              Text(_prettyDate(), style: AppText.caption),
            ],
          ),
        ),
        // All sleeps of the day (naps included) — the v2 multi-period view.
        RoundIconButton(Ic.bed, onTap: () => Navigator.of(context).push(
              themedRoute((_) => SleepPeriodsScreen(date: widget.date),
              ),
            )),
      ],
    );
  }

  // ── 2. HERO ────────────────────────────────────────────────────────────────

  Widget _hero() {
    final dur = _durationMin;
    final need = _needMin;
    final t = (dur != null && need != null && need > 0)
        ? (dur / need).toDouble()
        : double.nan;

    return GlowCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    AppIcon(Ic.moon, size: 16, color: AppColors.coralDeep),
                    const SizedBox(width: Sp.x2),
                    Text('TIME ASLEEP', style: AppText.overline),
                    if (_stagesBeta) ...[
                      const SizedBox(width: Sp.x2),
                      Tag('beta', color: AppColors.coral),
                    ],
                  ],
                ),
                const SizedBox(height: Sp.x3),
                if (dur == null)
                  metricDash(44)
                else
                  Text(_hm(dur), style: AppText.display),
                const SizedBox(height: Sp.x2),
                Text(
                  need == null
                      ? 'No sleep need set'
                      : 'of ${_hours(need)}h need',
                  style: AppText.bodySoft,
                ),
              ],
            ),
          ),
          const SizedBox(width: Sp.x4),
          RingStat(
            t: t,
            color: AppColors.coral,
            size: 104,
            stroke: 11,
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.isNaN ? '—' : '${(t.clamp(0, 1) * 100).round()}%',
                  style: AppText.metricSm,
                ),
                Text('of need', style: AppText.captionMuted),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── timing (onset → wake) — part of the trustworthy lead block ──────────────

  Widget _timingCard() {
    final onset = _num(_data['onset_ts']);
    final wake = _num(_data['wake_ts']);
    if (onset == null && wake == null) return const SizedBox.shrink();
    return ProCard(
      child: Row(
        children: [
          Expanded(child: _timingStat('TO BED', _clock(onset), Ic.moon)),
          Container(width: 1, height: 34, color: AppColors.surfaceAlt),
          Expanded(child: _timingStat('WOKE', _clock(wake), Ic.clock)),
        ],
      ),
    );
  }

  Widget _timingStat(String label, String value, IconData icon) => Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(icon, size: 14, color: AppColors.coralDeep),
            const SizedBox(width: Sp.x2),
            Text(label, style: AppText.overline),
          ]),
          const SizedBox(height: Sp.x2),
          Text(value, style: AppText.metricSm.copyWith(fontSize: 22)),
        ],
      );

  // ── estimate badge for the whole stage block ────────────────────────────────

  Widget _stagesEstimateBadge() {
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: AppColors.warnSoft,
        borderRadius: BorderRadius.circular(R.cardSm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppIcon(Ic.info, size: 16, color: AppColors.warn),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: Text(
            'Estimated — wrist staging, low confidence. Stages are inferred from '
            'heart rate + motion (no EEG). REM may read high, and Deep is an '
            'experimental overlay. Trust the duration and efficiency above.',
            style: AppText.captionMuted,
          ),
        ),
      ]),
    );
  }

  // ── hypnogram ──────────────────────────────────────────────

  Widget _hypnogramCard() {
    final segs = _segments();
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Sleep stages', style: AppText.h2),
              const Spacer(),
              AppIcon(Ic.clock, size: 16, color: AppColors.inkMuted),
            ],
          ),
          const SizedBox(height: Sp.x4),
          if (segs.isEmpty)
            SizedBox(
              height: 64,
              child: Center(
                child: Text('No hypnogram for this night',
                    style: AppText.captionMuted),
              ),
            )
          else ...[
            SizedBox(
              height: 56,
              child: CustomPaint(
                size: Size.infinite,
                painter: _HypnogramPainter(
                  segs: segs,
                  colorOf: _stageColor,
                ),
              ),
            ),
            const SizedBox(height: Sp.x2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_clock(_num(_data['onset_ts'])),
                    style: AppText.captionMuted),
                Text(_clock(_num(_data['wake_ts'])),
                    style: AppText.captionMuted),
              ],
            ),
          ],
          const SizedBox(height: Sp.x4),
          _legend(),
        ],
      ),
    );
  }

  // ── sleep cycles (fractal-cycle method on HRV) ─────────────────────────────

  Widget _cyclesCard() {
    final series = _cycleSeries;
    final cycles = _cycles;
    final onset = _num(_data['onset_ts'])?.toInt();
    final wake = _num(_data['wake_ts'])?.toInt();
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Cycles', style: AppText.h2),
              const SizedBox(width: Sp.x2),
              Tag('beta', color: AppColors.coral),
              const Spacer(),
              Text('${cycles.length} cycle${cycles.length == 1 ? '' : 's'}',
                  style: AppText.metricSm.copyWith(fontSize: 18)),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Text(
            _cyclesMean == null
                ? 'Ultradian NREM–REM cycles'
                : 'Average ${_hm(_cyclesMean)} per cycle',
            style: AppText.captionMuted,
          ),
          const SizedBox(height: Sp.x4),
          if (series.length >= 4 && onset != null && wake != null && wake > onset) ...[
            SizedBox(
              height: 76,
              child: CustomPaint(
                size: Size.infinite,
                painter: _CyclePainter(
                  series: series,
                  cycles: cycles,
                  onset: onset,
                  wake: wake,
                  line: AppColors.coral,
                  marker: AppColors.coralDeep,
                  grid: AppColors.surfaceAlt,
                ),
              ),
            ),
            const SizedBox(height: Sp.x2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_clock(onset), style: AppText.captionMuted),
                Text(_clock(wake), style: AppText.captionMuted),
              ],
            ),
          ] else
            SizedBox(
              height: 48,
              child: Center(
                child: Text('Not enough overnight HRV to resolve cycles',
                    style: AppText.captionMuted),
              ),
            ),
          const SizedBox(height: Sp.x3),
          Text(
            'Each rise-and-fall of your overnight heart-rate variability is one sleep '
            'cycle (~90 min). Diamonds mark the boundaries between cycles.',
            style: AppText.captionMuted,
          ),
        ],
      ),
    );
  }

  Widget _legend() {
    Widget swatch(String stage) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: _stageColor(stage),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 6),
            Text(_stageLabel(stage), style: AppText.caption),
          ],
        );
    return Wrap(
      spacing: Sp.x4,
      runSpacing: Sp.x2,
      children: [
        swatch('deep'),
        swatch('light'),
        swatch('rem'),
        swatch('awake'),
      ],
    );
  }

  // ── 4b. ADVANCED STAGES (beta) ──────────────────────────────────────────────
  // AASM figures from the parallel Cole–Kripke/DoG stager. ESTIMATE — a cross-
  // check beside the single-source stages above, not a replacement.
  Widget _advancedCard() {
    final m = _map(_advanced['metrics']);
    String mins(String key) {
      final s = _num(m[key]);
      return s == null ? '—' : '${(s / 60).round()} min';
    }

    String minsFromMin(String key) {
      final v = _num(m[key]);
      return v == null ? '—' : '${v.round()} min';
    }

    final remLat = _num(m['rem_latency_s']);
    final dist = _num(m['disturbances']);
    final eff = _num(_advanced['efficiency']); // 0..1
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'A second, independent 4-class estimate (Cole–Kripke + HR-variability). '
            'Wrist autonomic — not PSG. Use it as a sanity check on the stages above.',
            style: AppText.captionMuted),
        const SizedBox(height: Sp.x3),
        DetailRow(label: 'Sleep onset latency', value: mins('sol_s')),
        DetailRow(
            label: 'REM latency',
            value: remLat == null ? '—' : '${(remLat / 60).round()} min'),
        DetailRow(
            label: 'Disturbances',
            value: dist == null ? '—' : '${dist.round()}'),
        DetailRow(label: 'Deep', value: minsFromMin('deep_min')),
        DetailRow(label: 'Light', value: minsFromMin('light_min')),
        DetailRow(label: 'REM', value: minsFromMin('rem_min')),
        if (eff != null)
          DetailRow(
              label: 'Efficiency', value: '${(eff * 100).round()}%'),
      ]),
    );
  }

  // ── 4. STAGE BREAKDOWN ──────────────────────────────────────────────────────

  Widget _stageBreakdown() {
    final inBed = _inBedMin;
    // 4-class breakdown: Deep / Light / REM / Awake. Deep first (deepest), then
    // Light, REM, Awake — depth order, matching the hypnogram lanes.
    return ProCard(
      child: Column(
        children: [
          _stageRow('deep', _deepMin, inBed),
          const SizedBox(height: Sp.x4),
          _stageRow('light', _lightMin, inBed),
          const SizedBox(height: Sp.x4),
          _stageRow('rem', _remMin, inBed),
          const SizedBox(height: Sp.x4),
          _stageRow('awake', _awakeMin, inBed),
        ],
      ),
    );
  }

  Widget _stageRow(String stage, num? minutes, num? inBed) {
    final color = _stageColor(stage);
    final pct = (minutes != null && inBed != null && inBed > 0)
        ? (minutes / inBed).clamp(0.0, 1.0).toDouble()
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(child: Text(_stageLabel(stage), style: AppText.title)),
            Text(_hm(minutes),
                style: AppText.metricSm.copyWith(fontSize: 18)),
            const SizedBox(width: Sp.x3),
            SizedBox(
              width: 44,
              child: Text(
                pct == null ? '—' : '${(pct * 100).round()}%',
                textAlign: TextAlign.right,
                style: AppText.caption,
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        ClipRRect(
          borderRadius: BorderRadius.circular(R.pill),
          child: SizedBox(
            height: 6,
            child: Row(
              children: [
                Expanded(
                  flex: ((pct ?? 0) * 1000).round().clamp(0, 1000),
                  child: Container(color: color),
                ),
                Expanded(
                  flex: (1000 - ((pct ?? 0) * 1000).round()).clamp(1, 1000),
                  child: Container(color: AppColors.surfaceAlt),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 5. EFFICIENCY ───────────────────────────────────────────────────────────

  Widget _efficiencyCard() {
    final eff = _efficiency;
    final inBed = _inBedMin;
    final asleep = _durationMin;
    final awake = _awakeMin;
    return ProCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('SLEEP EFFICIENCY', style: AppText.overline),
              const SizedBox(height: Sp.x2),
              if (eff == null)
                metricDash(30)
              else
                Text('${(eff.clamp(0, 1) * 100).round()}%',
                    style: AppText.metric),
            ],
          ),
          const Spacer(),
          Flexible(
            child: Text(
              '${_hm(inBed)} in bed · ${_hm(asleep)} asleep · ${_hm(awake)} awake',
              textAlign: TextAlign.right,
              style: AppText.bodySoft,
            ),
          ),
        ],
      ),
    );
  }

  // ── 6. SLEEP DEBT ───────────────────────────────────────────────────────────

  Widget _debtCard() {
    final debt = _debtMin;
    final none = debt == null || debt.round() <= 0;
    return ProCard(
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              color: none ? AppColors.goodSoft : AppColors.coralSoft,
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(
              none ? Ic.check : Ic.bed,
              size: 20,
              color: none ? AppColors.good : AppColors.coralDeep,
            ),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: none
                ? Text('No sleep debt — nice.', style: AppText.title)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${_hm(debt)} sleep debt',
                          style: AppText.title),
                      const SizedBox(height: 2),
                      Text('Carried over from prior nights',
                          style: AppText.captionMuted),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ── 7. CONSISTENCY ──────────────────────────────────────────────────────────

  Widget _consistencyCard() {
    final reg = _regularity;
    final t = reg == null ? double.nan : (reg / 100).clamp(0.0, 1.0).toDouble();
    return ProCard(
      child: Row(
        children: [
          RingStat(
            t: t,
            color: AppColors.coral,
            size: 76,
            stroke: 9,
            center: Text(
              reg == null ? '—' : '${reg.round()}',
              style: AppText.metricSm.copyWith(fontSize: 18),
            ),
          ),
          const SizedBox(width: Sp.x5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Regularity ${reg == null ? '—' : '${reg.round()}/100'}',
                    style: AppText.title),
                const SizedBox(height: 4),
                Text('Higher = steadier bedtime and wake time',
                    style: AppText.bodySoft),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 8. NOCTURNAL HEART ──────────────────────────────────────────────────────

  String _prettyOrientation(String pos) {
    switch (pos) {
      case 'supine':
        return 'Wrist facing up';
      case 'prone':
        return 'Wrist facing down';
      case 'lateral_left':
        return 'Wrist tilted left';
      case 'lateral_right':
        return 'Wrist tilted right';
      case 'upright':
        return 'Arm raised';
      default:
        return 'Mixed / unknown';
    }
  }

  Widget _wristOrientationCard() {
    final dominant = _wristOri['dominant']?.toString() ?? 'unknown';
    final changes = _num(_wristOri['changes'])?.toInt() ?? 0;
    final minsRaw = _map(_wristOri['minutes']);
    final entries = <MapEntry<String, double>>[
      for (final e in minsRaw.entries)
        MapEntry(e.key, (_num(e.value) ?? 0).toDouble())
    ]..sort((a, b) => b.value.compareTo(a.value));
    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIcon(Ic.watch, size: 18, color: AppColors.inkMuted),
          const SizedBox(width: Sp.x3),
          Expanded(
              child: Text(_prettyOrientation(dominant),
                  style: AppText.label)),
          Tag('proxy', color: AppColors.inkSoft),
        ]),
        const SizedBox(height: Sp.x3),
        Text(
          'Wrist tilt from the band\'s motion sensor — a position PROXY, NOT your '
          'body position. Your arm moves independently of your torso, so this '
          'can\'t tell back from side sleeping.',
          style: AppText.captionMuted,
        ),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          for (final e in entries.take(4))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Expanded(child: Text(_prettyOrientation(e.key),
                    style: AppText.captionMuted)),
                Text(_hm(e.value.round()), style: AppText.captionMuted),
              ]),
            ),
        ],
        const SizedBox(height: 2),
        Text('$changes orientation changes', style: AppText.captionMuted),
      ]),
    );
  }

  Widget _nocturnalCard() {
    final avg = _num(_nocturnal['sleeping_hr_avg'])?.round();
    final nadir = _num(_nocturnal['sleeping_hr_min'])?.round();
    final nadirTs = _num(_nocturnal['nadir_ts'])?.toInt();
    final dayHr = _num(_nocturnal['day_hr_avg'])?.round();
    final dip = _num(_nocturnal['dip_pct'])?.toDouble();
    final vsBase = _num(_nocturnal['vs_baseline_bpm'])?.toDouble();
    final elevated = _nocturnal['elevated'] == true;
    final respVal = _num(_resp['value'])?.toDouble();

    return ProCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              color: elevated ? AppColors.warnSoft : AppColors.coralSoft,
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(Ic.heart, size: 20,
                color: elevated ? AppColors.warn : AppColors.coralDeep),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(avg == null ? '—' : '$avg bpm asleep', style: AppText.title),
              const SizedBox(height: 2),
              Text(
                dip != null
                    ? 'Dipped ${(dip * 100).round()}% below your waking heart rate'
                    : 'Sleeping heart rate',
                style: AppText.captionMuted,
              ),
            ],
          )),
        ]),
        const SizedBox(height: Sp.x4),
        Row(children: [
          _nStat('NADIR', nadir == null ? '—' : '$nadir',
              nadir == null ? '' : 'bpm @ ${_clock(nadirTs)}'),
          _nStat('WAKING', dayHr == null ? '—' : '$dayHr', dayHr == null ? '' : 'bpm avg'),
          _nStat('VS BASE', vsBase == null ? '—' : '${vsBase > 0 ? '+' : ''}${vsBase.toStringAsFixed(1)}',
              vsBase == null ? 'building' : 'bpm'),
        ]),
        if (respVal != null) ...[
          const SizedBox(height: Sp.x4),
          Row(children: [
            AppIcon(Ic.activity, size: 16, color: AppColors.coralDeep),
            const SizedBox(width: Sp.x2),
            Text('${respVal.toStringAsFixed(1)} breaths/min',
                style: AppText.title),
            const SizedBox(width: Sp.x2),
            Tag('beta', color: AppColors.coral),
          ]),
        ],
        if (elevated) ...[
          const SizedBox(height: Sp.x4),
          Container(
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
                color: AppColors.warnSoft, borderRadius: BorderRadius.circular(R.cardSm)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppIcon(Ic.info, size: 16, color: AppColors.warn),
              const SizedBox(width: Sp.x2),
              Expanded(child: Text(
                'Overnight heart rate ran above your baseline — often an early cue of '
                'fighting something off or under-recovery. A signal, not a diagnosis.',
                style: AppText.captionMuted,
              )),
            ]),
          ),
        ],
        const SizedBox(height: Sp.x3),
        Text(
          respVal == null
              ? 'A bigger overnight dip generally means better autonomic recovery. '
                'Breaths/min appears here when optical PPG was captured.'
              : 'A bigger overnight dip generally means better autonomic recovery.',
          style: AppText.captionMuted,
        ),
      ]),
    );
  }

  Widget _nStat(String label, String value, String sub) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: AppText.overline),
          const SizedBox(height: 2),
          Text(value, style: AppText.metricSm.copyWith(fontSize: 19)),
          if (sub.isNotEmpty) Text(sub, style: AppText.captionMuted),
        ]),
      );

  // ── states ───────────────────────────────────────────────────────────────────

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

/// Draws the night as a horizontal banded timeline, left→right, segments
/// weighted by duration. Each band is vertically centered around its stage
/// "depth" (awake = top, deep = bottom) so the shape reads like a hypnogram,
/// with a soft rounded fill per segment.
class _HypnogramPainter extends CustomPainter {
  final List<_Seg> segs;
  final Color Function(String) colorOf;
  _HypnogramPainter({required this.segs, required this.colorOf});

  // Vertical lane (0 = top .. 1 = bottom) per stage — 4-class hypnogram:
  // Awake (top) → REM → Light → Deep (bottom). 'nrem' (legacy combined Core)
  // sits at the Light lane.
  static const _depth = {
    'awake': 0.0,
    'rem': 0.30,
    'light': 0.62,
    'nrem': 0.62, // legacy combined Core → Light lane
    'deep': 0.92,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final total = segs.fold<int>(0, (s, e) => s + e.seconds);
    if (total <= 0) return;

    const bandH = 14.0;
    final usableTop = bandH / 2;
    final usableH = size.height - bandH;

    double x = 0;
    const gap = 1.0;
    for (final seg in segs) {
      final w = (seg.seconds / total) * size.width;
      if (w <= 0) continue;
      final lane = _depth[seg.stage] ?? 0.5;
      final cy = usableTop + lane * usableH;
      final rect = Rect.fromLTWH(
        x + gap / 2,
        cy - bandH / 2,
        (w - gap).clamp(0.5, size.width),
        bandH,
      );
      final paint = Paint()..color = colorOf(seg.stage);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        paint,
      );
      x += w;
    }
  }

  @override
  bool shouldRepaint(_HypnogramPainter old) => old.segs != segs;
}

/// Draws the overnight HRV (z-RMSSD) wave across [onset, wake] with vertical
/// boundary lines + diamonds at each detected sleep-cycle edge — the cardiac
/// analog of the paper's fractal-slope cycle figure.
class _CyclePainter extends CustomPainter {
  final List<MapEntry<int, double>> series;
  final List<Map<String, dynamic>> cycles;
  final int onset;
  final int wake;
  final Color line;
  final Color marker;
  final Color grid;
  _CyclePainter({
    required this.series,
    required this.cycles,
    required this.onset,
    required this.wake,
    required this.line,
    required this.marker,
    required this.grid,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final span = (wake - onset).toDouble();
    if (span <= 0 || series.isEmpty) return;

    double zmin = double.infinity, zmax = -double.infinity;
    for (final e in series) {
      if (e.value < zmin) zmin = e.value;
      if (e.value > zmax) zmax = e.value;
    }
    if (!(zmax > zmin)) zmax = zmin + 1;

    double xOf(int t) => (((t - onset) / span).clamp(0.0, 1.0)) * size.width;
    double yOf(double z) {
      final n = (z - zmin) / (zmax - zmin); // 0..1
      return size.height - n * size.height * 0.80 - size.height * 0.10;
    }

    // cycle boundary verticals
    final bounds = <int>{};
    for (final c in cycles) {
      final s = (c['start_ts'] as num?)?.toInt();
      final e = (c['end_ts'] as num?)?.toInt();
      if (s != null) bounds.add(s);
      if (e != null) bounds.add(e);
    }
    final gp = Paint()..color = grid..strokeWidth = 1;
    for (final t in bounds) {
      final x = xOf(t);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gp);
    }

    // the HRV curve
    final path = Path();
    bool started = false;
    for (final e in series) {
      final x = xOf(e.key);
      final y = yOf(e.value);
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );

    // diamonds at each boundary, snapped to the curve's nearest z
    final mp = Paint()..color = marker;
    for (final t in bounds) {
      double bestD = double.infinity, by = size.height / 2;
      for (final e in series) {
        final d = (e.key - t).abs().toDouble();
        if (d < bestD) {
          bestD = d;
          by = yOf(e.value);
        }
      }
      final x = xOf(t);
      const r = 4.0;
      final dia = Path()
        ..moveTo(x, by - r)
        ..lineTo(x + r, by)
        ..lineTo(x, by + r)
        ..lineTo(x - r, by)
        ..close();
      canvas.drawPath(dia, mp);
    }
  }

  @override
  bool shouldRepaint(_CyclePainter old) =>
      old.series != series || old.cycles != cycles;
}
