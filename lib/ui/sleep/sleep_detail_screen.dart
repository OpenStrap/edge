// Sleep detail for one night, on the NEW design language — a floating sleep
// hero (huge duration + asleep-vs-need arc), a mixed-tone bento of
// timing/efficiency/WASO/debt/consistency BigStat tiles, the full-width
// stepped Hypnogram with labelled stage rows (the ONE stage palette from
// DomainAccent), a StageBars breakdown with honest per-stage rows, cycles,
// nocturnal heart and trends. Numbers first; every definition lives behind a
// long-press or (i). Backed by /day/sleep.
//
// Staging honesty: the 4-class stages are a wrist ESTIMATE (badged `est`), and
// Deep is a LOW-CONFIDENCE HR-depth overlay — when Deep is genuinely absent
// the row says so in words instead of leaving an invisible gap.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart';
import '../design/design.dart';
import '../screens/metric_row.dart';
import '../screens/trend_screen.dart';
import 'sleep_periods_screen.dart';

class SleepDetailScreen extends StatefulWidget {
  final String date; // 'YYYY-MM-DD'
  // When true, render just the section content (no Scaffold/back bar) so it can
  // be embedded inside the Sleep screen (Today/Week/Month/3M).
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

class _SleepDetailScreenState extends State<SleepDetailScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic> _data = const {};
  // same fix as HeartDayCard/OxygenDayCard/WearDayCard's shared _Fetch widget
  // (detail_cards.dart) - this screen fetched once at mount and never again,
  // so it'd keep showing a stale night if a background derive finished
  // while it was open.
  AppState? _app;
  VoidCallback? _insightsListener;
  int _lastInsightsRevision = -1;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _lastInsightsRevision = _app!.insightsRevision.value;
    _insightsListener = () {
      final app = _app;
      if (!mounted || app == null) return;
      final next = app.insightsRevision.value;
      if (next == _lastInsightsRevision) return;
      _lastInsightsRevision = next;
      _load(background: true);
    };
    _app!.insightsRevision.addListener(_insightsListener!);
    _load();
  }

  @override
  void dispose() {
    final listener = _insightsListener;
    final app = _app;
    if (listener != null && app != null) {
      app.insightsRevision.removeListener(listener);
    }
    super.dispose();
  }

  Future<void> _load({bool background = false}) async {
    final api = context.read<AppState>().repo;
    if (api == null) {
      setState(() {
        _phase = _Phase.error;
        _error = 'Not signed in.';
      });
      return;
    }
    // a background (insightsRevision-triggered) refresh keeps showing the
    // current data while it re-fetches, instead of flashing back to the
    // loading skeleton like the initial mount does.
    if (!background) {
      setState(() {
        _phase = _Phase.loading;
        _error = null;
      });
    }
    try {
      final res = await api.getDaySleep(widget.date);
      if (!mounted) return;
      final hasSleep = res['has_sleep'] == true || res['has_sleep'] == 1;
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

  // ── formatting (no intl) ────────────────────────────────────────────────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

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

  // ── sleep-window overrides ──────────────────────────────────────────────────

  /// Two time pickers (onset, wake) → store the window + restage the day.
  Future<void> _editSleepTimes() async {
    num? n(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
    final existingOnset = n(_data['onset_ts']);
    final existingWake = n(_data['wake_ts']);
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

  /// Run a sleep-override change with a busy state, then reload this night.
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

  // ── build ──────────────────────────────────────────────────────────────────

  List<Widget> _sections() {
    if (_phase == _Phase.loading) return [_loading()];
    if (_phase == _Phase.empty) {
      return [
        StateCard(
          icon: OsIcon.sleep,
          title: 'No sleep recorded for this night',
          message: 'Wear your strap overnight and sync — your breakdown '
              'appears once a night has been recorded.',
          actionLabel: 'Add sleep times',
          onAction: _editSleepTimes,
        ),
      ];
    }
    if (_phase == _Phase.error) {
      return [
        StateCard(
          icon: OsIcon.sync,
          title: "Couldn't load this night",
          message: _error ?? 'Please try again.',
          actionLabel: 'Try again',
          onAction: _load,
        ),
      ];
    }
    return [
      SleepNightContent(
        data: _data,
        date: widget.date,
        onEditTimes: _editSleepTimes,
        onConfirmFallback: _confirmFallback,
        onClearOverride: _clearOverride,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Embedded in the Sleep screen: just the sections (its ListView scrolls).
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _sections(),
      );
    }
    return AppScaffold(
      title: 'Sleep',
      subtitle: _prettyDate(),
      actions: [
        // All sleeps of the day (naps included) — the multi-period view.
        RoundIconButton(
          OsIcon.bedtime,
          onTap: () => Navigator.of(context).push(
            themedRoute((_) => SleepPeriodsScreen(date: widget.date)),
          ),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.accent,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x10),
          children: _sections(),
        ),
      ),
    );
  }

  Widget _loading() => Column(
        children: [
          Skeleton.hero(),
          const SizedBox(height: Sp.x4),
          Skeleton.chart(height: 180),
          const SizedBox(height: Sp.x4),
          Skeleton.tileRow(rows: 2),
        ],
      );
}

/// SleepNightContent — the pure, testable night breakdown on the new design
/// language. Everything comes in via the /day/sleep payload map; the override
/// actions come in as callbacks so this renders without AppState (tests pass a
/// sample map + no-ops).
class SleepNightContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final String date; // 'YYYY-MM-DD' (drives the detail-retention window)
  final VoidCallback onEditTimes;
  final VoidCallback onConfirmFallback;
  final VoidCallback onClearOverride;

  const SleepNightContent({
    super.key,
    required this.data,
    required this.date,
    required this.onEditTimes,
    required this.onConfirmFallback,
    required this.onClearOverride,
  });

  // ── defensive parsing ──────────────────────────────────────────────────────

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  num? get _durationMin => _num(data['duration_min']);
  num? get _needMin => _num(data['need_min']);
  num? get _inBedMin => _num(data['in_bed_min']);
  num? get _awakeMin => _num(data['awake_min']);
  num? get _debtMin => _num(data['debt_min']);
  num? get _efficiency => _num(data['efficiency']); // 0..1
  num? get _regularity => _num(data['regularity']); // 0..100
  bool get _stagesBeta => data['stages_beta'] == true;

  // Where this night's window came from: auto / auto_fallback / manual /
  // confirmed / none. Drives the confirm prompt + the manual-edit affordance.
  String get _sleepSource => (data['sleep_source'] as String?) ?? 'auto';

  // 4-class wrist stager: Awake / Light / Deep / REM. Deep is a LOW-CONFIDENCE
  // overlay; the stage block is badged as an estimate.
  num? get _lightMin => _num(data['light_min']);
  num? get _deepMin => _num(data['deep_min']);
  num? get _remMin => _num(data['rem_min']);

  // Sleep cycles (ultradian NREM↔REM, fractal-cycle method on HRV). Beta.
  List<Map<String, dynamic>> get _cycles {
    final raw = data['cycles'];
    if (raw is! List) return const [];
    return raw.map((e) => _map(e)).where((m) => m.isNotEmpty).toList();
  }

  num? get _cyclesMean => _num(data['cycles_mean_min']);

  List<MapEntry<int, double>> get _cycleSeries {
    final raw = data['cycle_series'];
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

  Map<String, dynamic> get _nocturnal => _map(data['nocturnal']);
  Map<String, dynamic> get _resp => _map(data['resp']);
  bool get _hasNocturnal => _num(_nocturnal['sleeping_hr_avg']) != null;

  // Parallel 4-class AASM read (Cole–Kripke/DoG stager). ESTIMATE; shown below
  // the single-source stages as a "beta" cross-check.
  Map<String, dynamic> get _advanced => _map(data['advanced']);
  bool get _hasAdvanced => _advanced['present'] == true;

  // Low-confidence WRIST orientation (gravity-tilt) during sleep — a body-
  // position PROXY only.
  Map<String, dynamic> get _wristOri => _map(data['wrist_orientation']);

  /// Hypnogram points → normalized design-system segments (handles the live
  /// 'wake' vocabulary plus legacy 'awake'/'nrem'/'core').
  List<HypnoSeg> _segments() =>
      hypnoSegmentsFromPoints((data['hypnogram'] as List?) ?? const []);

  // ── formatting ─────────────────────────────────────────────────────────────

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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: dsStaggered([
        // Provenance: a fallback night asks for confirmation; a manual/
        // confirmed night can be edited or reverted.
        if (_sleepSource == 'auto_fallback') ...[
          _fallbackConfirmBanner(),
          const SizedBox(height: Sp.x3),
        ] else if (_sleepSource == 'manual' || _sleepSource == 'confirmed') ...[
          _manualBadge(),
          const SizedBox(height: Sp.x3),
        ],
        // ── TRUSTWORTHY BLOCK FIRST: the floating hero + the timing/
        //    efficiency bento — straight from the van Hees window (not the
        //    stage model). ──
        _hero(context),
        const SizedBox(height: Sp.x4),
        _summaryBento(context),
        // ── ESTIMATED STAGE BLOCK (below the trustworthy numbers) ──
        const SizedBox(height: Sp.x6),
        _stagesHeader(),
        const SizedBox(height: Sp.x2),
        detailedAvailable(date)
            ? _hypnogramTile()
            : const DetailRetentionNote(what: 'sleep hypnogram'),
        const SizedBox(height: Sp.x3),
        _stageBreakdown(),
        if (detailedAvailable(date) && _cycles.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          _cyclesCard(),
        ],
        if (_hasAdvanced) ...[
          const SizedBox(height: Sp.x5),
          _advancedCard(),
        ],
        if (_hasNocturnal) ...[
          const SizedBox(height: Sp.x5),
          const SectionHeader('Nocturnal heart'),
          _nocturnalTile(),
        ],
        if (_wristOri['dominant'] is String) ...[
          const SizedBox(height: Sp.x5),
          _wristOrientationCard(),
        ],
        // Tap any of these into its Week/Month/3M trend.
        const SizedBox(height: Sp.x5),
        const SectionHeader('Trends'),
        _trends(),
        // Any night can be corrected by hand.
        const SizedBox(height: Sp.x4),
        _editTimesFooter(),
      ]),
    );
  }

  // ── provenance ──────────────────────────────────────────────────────────────

  /// Fallback night → "estimated from heart rate, is this right?"
  Widget _fallbackConfirmBanner() {
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Estimated from your heart rate',
                    style: AppText.title),
              ),
              InfoDot(
                title: 'Estimated night',
                body:
                    'We couldn\'t detect this night from movement, so we '
                    'estimated it from your heart-rate dip. Confirm or correct '
                    'the timing.',
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: onConfirmFallback,
                child: const Text('Looks right'),
              ),
            ),
            const SizedBox(width: Sp.x3),
            TextButton(onPressed: onEditTimes, child: const Text('Edit')),
          ]),
        ],
      ),
    );
  }

  /// Manual / confirmed night → small badge + edit / revert.
  Widget _manualBadge() {
    final confirmed = _sleepSource == 'confirmed';
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      child: Row(children: [
        AppIcon(OsIcon.check, size: 16, color: AppColors.positive),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Text(
            confirmed ? 'You confirmed these times' : 'You set these times',
            style: AppText.caption,
          ),
        ),
        TextButton(onPressed: onEditTimes, child: const Text('Edit')),
        TextButton(onPressed: onClearOverride, child: const Text('Use auto')),
      ]),
    );
  }

  /// Subtle "fix it" affordance shown under an auto-detected night.
  Widget _editTimesFooter() {
    if (_sleepSource != 'auto') return const SizedBox.shrink();
    return Center(
      child: TextButton(
        onPressed: onEditTimes,
        child: Text('Sleep times look off? Fix them',
            style: AppText.caption.copyWith(color: AppColors.inkMuted)),
      ),
    );
  }

  // ── hero — floats directly on the page, no card chrome ─────────────────────

  Widget _hero(BuildContext context) {
    final dur = _durationMin;
    final need = _needMin;
    final t = (dur != null && need != null && need > 0)
        ? (dur / need).toDouble()
        : double.nan;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: Sp.x2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const OsAppIcon(OsIcon.sleep, size: 34),
                    const SizedBox(width: Sp.x2),
                    Flexible(
                      child: Text(
                        'TIME ASLEEP',
                        style: AppText.overline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InfoDot(
                      title: 'Time asleep',
                      body:
                          'Actual sleep inside your night window — awake time '
                          'is excluded. The ring shows it against your need.',
                      methodNote:
                          'van Hees z-angle sleep window · asleep/awake accounting',
                    ),
                  ],
                ),
                const SizedBox(height: Sp.x1),
                if (dur == null)
                  metricDash(44)
                else
                  Text(
                    _hm(dur),
                    style: AppText.hero.copyWith(fontSize: 54),
                    maxLines: 1,
                  ),
                const SizedBox(height: Sp.x1),
                Text(
                  need == null ? 'No sleep need set' : 'of ${_hours(need)}h need',
                  style: AppText.bodySoft,
                ),
              ],
            ),
          ),
          const SizedBox(width: Sp.x4),
          ArcGauge(
            value: t.isNaN ? double.nan : t.clamp(0.0, 1.0).toDouble(),
            color: DomainAccent.sleep,
            size: 112,
            stroke: 12,
            sweepFraction: 0.75,
            endDot: !t.isNaN,
            valueText: t.isNaN ? '—' : '${(t.clamp(0, 1) * 100).round()}%',
            label: 'of need',
          ),
        ],
      ),
    );
  }

  // ── timing / efficiency / debt / consistency bento (BigStat tiles) ─────────

  Widget _summaryBento(BuildContext context) {
    final onset = _num(data['onset_ts']);
    final wake = _num(data['wake_ts']);
    final eff = _efficiency;
    final debt = _debtMin;
    final noDebt = debt == null || debt.round() <= 0;
    final reg = _regularity;

    void info(String title, String body, [String? method]) =>
        showInfoSheet(context, title: title, body: body, methodNote: method);

    // Mostly paper, ONE ink (efficiency — the night's headline quality) and
    // ONE soft sleep tile (debt) — the refs' tonal rhythm.
    return BentoColumns(
      entrance: false,
      left: [
        BentoTile(
          accent: DomainAccent.sleep,
          onLongPress: () => info('To bed',
              'When you fell asleep — the start of the detected window.'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('To bed'),
              const SizedBox(height: Sp.x2),
              BigStat(value: onset == null ? null : _clock(onset)),
            ],
          ),
        ),
        BentoTile(
          tone: BentoTone.ink,
          accent: DomainAccent.recovery,
          onLongPress: () => info(
            'Sleep efficiency',
            'Time asleep as a share of time in bed.',
            '${_hm(_inBedMin)} in bed · ${_hm(_durationMin)} asleep · ${_hm(_awakeMin)} awake',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('Efficiency'),
              const SizedBox(height: Sp.x2),
              Row(
                children: [
                  Expanded(
                    child: BigStat(
                      value: eff == null
                          ? null
                          : '${(eff.clamp(0, 1) * 100).round()}',
                      unit: '%',
                    ),
                  ),
                  if (eff != null)
                    ArcGauge(
                      value: eff.clamp(0, 1).toDouble(),
                      color: AppColors.good,
                      size: 46,
                      stroke: 5,
                    ),
                ],
              ),
            ],
          ),
        ),
        BentoTile(
          tone: noDebt ? BentoTone.paper : BentoTone.soft,
          accent: DomainAccent.sleep,
          onLongPress: () => info('Sleep debt',
              'Sleep owed from recent short nights. It decays as you catch up.'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('Sleep debt'),
              const SizedBox(height: Sp.x2),
              BigStat(
                value: debt == null ? null : (noDebt ? 'None' : _hm(debt)),
                caption: debt == null
                    ? null
                    : (noDebt ? 'all caught up' : 'carried over'),
                captionAccent: !noDebt,
              ),
            ],
          ),
        ),
      ],
      right: [
        BentoTile(
          onLongPress: () => info(
              'Woke', 'When you woke for the day — the end of the window.'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('Woke'),
              const SizedBox(height: Sp.x2),
              BigStat(value: wake == null ? null : _clock(wake)),
            ],
          ),
        ),
        BentoTile(
          accent: DomainAccent.stress,
          onLongPress: () => info(
              'Awake (WASO)',
              'Time awake after first falling asleep — brief wake-ups are '
                  'normal; long stretches drag efficiency down.'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('Awake'),
              const SizedBox(height: Sp.x2),
              BigStat(value: _awakeMin == null ? null : _hm(_awakeMin)),
            ],
          ),
        ),
        BentoTile(
          accent: DomainAccent.recovery,
          onLongPress: () => info(
            'Sleep consistency',
            'How steady your bed and wake times have been. Higher is steadier.',
            'Sleep Regularity Index over recent nights — needs several nights to unlock',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('Consistency'),
              const SizedBox(height: Sp.x2),
              BigStat(
                value: reg == null ? null : '${reg.round()}',
                unit: reg == null ? null : '/100',
                caption: reg == null ? 'need a few more nights' : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── stages ──────────────────────────────────────────────────────────────────

  /// Header row for the estimated stage block — the honesty copy is behind (i).
  Widget _stagesHeader() {
    return Row(
      children: [
        const OsAppIcon(OsIcon.sleepHypnogram, size: 34),
        const SizedBox(width: Sp.x2),
        Text('Stages', style: AppText.h2),
        const SizedBox(width: Sp.x2),
        if (_stagesBeta) const Tag('est'),
        InfoDot(
          title: 'Estimated stages',
          body:
              'Stages are inferred from heart rate and motion at the wrist — '
              'no EEG. Trust the duration and efficiency above first.',
          bullets: const [
            'REM can read high on wrist data',
            'Deep is an experimental low-confidence overlay',
          ],
          methodNote: 'Wrist actigraphy + HR staging · low confidence',
        ),
        const Spacer(),
      ],
    );
  }

  /// The full-width stepped hypnogram — labelled Awake/REM/Light/Deep rows on
  /// the ONE stage palette, start/end clocks under the plot.
  Widget _hypnogramTile() {
    final segs = _segments();
    return BentoTile(
      accent: DomainAccent.sleep,
      padding: const EdgeInsets.all(Sp.x4),
      child: segs.isEmpty
          ? SizedBox(
              height: 64,
              child: Center(
                child: Text('No hypnogram for this night',
                    style: AppText.captionMuted),
              ),
            )
          : Hypnogram(
              segs,
              height: 108,
              startLabel: _clock(_num(data['onset_ts'])),
              endLabel: _clock(_num(data['wake_ts'])),
            ),
    );
  }

  /// Stage distribution: the rounded StageBars strip + one honest row per
  /// stage. A stage that is genuinely absent renders a labelled row with an
  /// em-dash and says WHY (Deep: low-confidence overlay) — never an invisible
  /// gap the user reads as broken.
  Widget _stageBreakdown() {
    int? mi(num? v) => v?.round();
    return BentoTile(
      accent: DomainAccent.sleep,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StageBars(
            awakeMin: mi(_awakeMin),
            remMin: mi(_remMin),
            lightMin: mi(_lightMin),
            deepMin: mi(_deepMin),
            height: 12,
            legend: false,
          ),
        ],
      ),
    );
  }



  // ── sleep cycles (fractal-cycle method on HRV) ─────────────────────────────

  Widget _cyclesCard() {
    final series = _cycleSeries;
    final cycles = _cycles;
    final onset = _num(data['onset_ts'])?.toInt();
    final wake = _num(data['wake_ts'])?.toInt();
    return BentoTile(
      accent: DomainAccent.sleep,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TileHeader('Cycles',
                    trailing: Tag('beta', color: AppColors.coral)),
              ),
              InfoDot(
                title: 'Sleep cycles',
                body:
                    'Each rise-and-fall of your overnight heart-rate '
                    'variability is one sleep cycle (~90 min). Diamonds mark '
                    'the boundaries between cycles.',
                methodNote: 'Fractal-cycle method on nocturnal HRV',
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              BigStat(
                value: '${cycles.length}',
                caption: _cyclesMean == null
                    ? 'ultradian NREM–REM cycles'
                    : '~${_hm(_cyclesMean)} per cycle',
                size: BigStatSize.md,
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          if (series.length >= 4 && onset != null && wake != null && wake > onset) ...[
            RepaintBoundary(
              child: SizedBox(
                height: 76,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _CyclePainter(
                    series: series,
                    cycles: cycles,
                    onset: onset,
                    wake: wake,
                    line: DomainAccent.sleep,
                    marker: DomainAccent.stageDeep,
                    grid: AppColors.surfaceAlt,
                  ),
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
        ],
      ),
    );
  }

  // ── advanced stages (beta) — a parallel Cole–Kripke/DoG cross-check ────────

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
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Advanced stages', style: AppText.h2),
              const SizedBox(width: Sp.x2),
              Tag('beta', color: AppColors.coral),
              InfoDot(
                title: 'Advanced stages',
                body:
                    'A second, independent 4-class estimate (Cole–Kripke + '
                    'HR variability). Wrist autonomic — not PSG. Use it as a '
                    'sanity check on the stages above.',
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: Sp.x2),
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
            DetailRow(label: 'Efficiency', value: '${(eff * 100).round()}%'),
        ],
      ),
    );
  }

  // ── nocturnal heart — the board's INK tile ─────────────────────────────────

  Widget _nocturnalTile() {
    final avg = _num(_nocturnal['sleeping_hr_avg'])?.round();
    final nadir = _num(_nocturnal['sleeping_hr_min'])?.round();
    final nadirTs = _num(_nocturnal['nadir_ts'])?.toInt();
    final dayHr = _num(_nocturnal['day_hr_avg'])?.round();
    final dip = _num(_nocturnal['dip_pct'])?.toDouble();
    final vsBase = _num(_nocturnal['vs_baseline_bpm'])?.toDouble();
    final elevated = _nocturnal['elevated'] == true;
    final respVal = _num(_resp['value'])?.toDouble();

    return BentoTile(
      tone: BentoTone.ink,
      accent: DomainAccent.heart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                  child: TileHeader('Sleeping HR')),
              if (dip != null)
                StatusChip('dip ${(dip * 100).round()}%',
                    tone: ChipTone.positive),
            ],
          ),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: avg == null ? null : '$avg',
            unit: 'bpm',
            caption: elevated ? 'above your baseline tonight' : null,
            captionAccent: elevated,
          ),
          const SizedBox(height: Sp.x4),
          Row(children: [
            _nStat('NADIR', nadir == null ? '—' : '$nadir',
                nadir == null ? '' : 'bpm @ ${_clock(nadirTs)}'),
            _nStat('WAKING', dayHr == null ? '—' : '$dayHr',
                dayHr == null ? '' : 'bpm avg'),
            _nStat(
                'VS BASE',
                vsBase == null
                    ? '—'
                    : '${vsBase > 0 ? '+' : ''}${vsBase.toStringAsFixed(1)}',
                vsBase == null ? 'building' : 'bpm'),
            if (respVal != null)
              _nStat('BREATH', respVal.toStringAsFixed(1), '/min · beta'),
          ]),
          if (elevated) ...[
            const SizedBox(height: Sp.x3),
            Row(
              children: [
                const StatusChip('Above baseline overnight',
                    icon: OsIcon.activity, tone: ChipTone.warn),
                InfoDot(
                  title: 'Elevated overnight HR',
                  body:
                      'Overnight heart rate ran above your baseline — often an '
                      'early cue of fighting something off or under-recovery. '
                      'A signal, not a diagnosis.',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _nStat(String label, String value, String sub) => Expanded(
        child: Builder(builder: (context) {
          final tone = ToneScope.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: AppText.overline.copyWith(color: tone.fgFaint)),
              const SizedBox(height: 2),
              Text(value,
                  style: AppText.metricSm
                      .copyWith(fontSize: 19, color: tone.fg)),
              if (sub.isNotEmpty)
                Text(sub,
                    style: AppText.captionMuted.copyWith(color: tone.fgMuted)),
            ],
          );
        }),
      );

  // ── wrist orientation (proxy) ──────────────────────────────────────────────

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
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            AppIcon(OsIcon.wear, size: 18, color: AppColors.inkMuted),
            const SizedBox(width: Sp.x3),
            Expanded(
                child: Text(_prettyOrientation(dominant), style: AppText.title)),
            Tag('proxy', color: AppColors.inkSoft),
            InfoDot(
              title: 'Wrist orientation',
              body:
                  'Wrist tilt from the band\'s motion sensor — a position '
                  'PROXY, not your body position. Your arm moves independently '
                  'of your torso, so this can\'t tell back from side sleeping.',
            ),
          ]),
          if (entries.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            for (final e in entries.take(4))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Expanded(
                      child: Text(_prettyOrientation(e.key),
                          style: AppText.captionMuted)),
                  Text(_hm(e.value.round()), style: AppText.captionMuted),
                ]),
              ),
          ],
          const SizedBox(height: 2),
          Text('$changes orientation changes', style: AppText.captionMuted),
        ],
      ),
    );
  }

  // ── trends ──────────────────────────────────────────────────────────────────

  Widget _trends() {
    return MetricGroup([
      TrendMetricRow(
          icon: OsIcon.sleep,
          accent: DomainAccent.sleep,
          label: 'Time asleep',
          info: infoFor('sleep'),
          value: _hm(_durationMin),
          metric: 'sleep',
          trendTitle: 'Sleep',
          valueFmt: (v) => v == 0 ? '' : (v / 60).toStringAsFixed(1)),
      if (_efficiency != null)
        TrendMetricRow(
            icon: OsIcon.activity,
            accent: AppColors.good,
            label: 'Efficiency',
            info: infoFor('efficiency'),
            value: '${(_efficiency! * 100).round()}',
            unit: '%',
            metric: 'efficiency',
            trendTitle: 'Sleep efficiency'),
      if (_lightMin != null)
        TrendMetricRow(
            icon: OsIcon.lightSleep,
            accent: DomainAccent.stageLight,
            label: 'Light sleep',
            info: infoFor('light'),
            value: _hm(_lightMin),
            metric: 'light',
            trendTitle: 'Light sleep'),
      if (_deepMin != null)
        TrendMetricRow(
            icon: OsIcon.deepSleep,
            accent: DomainAccent.stageDeep,
            label: 'Deep sleep',
            info: infoFor('deep'),
            value: _hm(_deepMin),
            metric: 'deep',
            trendTitle: 'Deep sleep'),
      if (_remMin != null)
        TrendMetricRow(
            icon: OsIcon.heartRate,
            accent: DomainAccent.stageRem,
            label: 'REM sleep',
            info: infoFor('rem'),
            value: _hm(_remMin),
            metric: 'rem',
            trendTitle: 'REM sleep'),
      if (_regularity != null)
        TrendMetricRow(
            icon: OsIcon.calendar,
            accent: AppColors.good,
            label: 'Consistency',
            info: infoFor('regularity'),
            value: '${_regularity!.round()}',
            metric: 'regularity',
            trendTitle: 'Sleep consistency')
      else
        // Honest gated state: SRI needs several nights of sleep timing.
        MetricRow(
            icon: OsIcon.calendar,
            accent: AppColors.inkSoft,
            label: 'Consistency',
            info: infoFor('regularity'),
            value: 'Need a few more nights'),
    ]);
  }
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
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
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
