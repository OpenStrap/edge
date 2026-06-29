// Home — today's readiness, key stats, and heart rate.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/metric.dart';
import '../../models/payloads.dart';
import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/theme_switcher.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';
import '../widgets/screen_loader.dart';
import '../widgets/status_banner.dart';
import '../journal/journal_screen.dart';
import '../recap/recap_screen.dart';
import '../coach/coach_screen.dart';
import '../profile/profile_screen.dart';
import '../screens/screens.dart';
import '../journey/journey_screen.dart';
import '../stress/stress_screen.dart';
import '../records/records_screen.dart';
import '../notifications/notifications_screen.dart';
import '../../widget/widget_service.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});
  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen>
    with ScreenLoaderMixin<TodayScreen> {
  ChartSeries _hr = const ChartSeries([]);
  int _unread = 0;

  @override
  String get cacheKey => 'today';

  @override
  Future<Object?> fetch(LocalRepository repo) async {
    final today = await repo.getToday();
    // Push a fresh snapshot to the home/lock-screen widget (best-effort).
    // CLOUD EXCISED: the widget's cloud self-refresh (saveAuth) is gone — the
    // re-layer will push computed snapshots locally instead.
    WidgetService.push(TodayData.fromJson(today));
    // HR chart + notification count are best-effort — never fail the screen.
    try {
      final chart = await repo.getChart('hr');
      if (mounted) setState(() => _hr = ChartSeries.fromJson(chart));
    } catch (_) {}
    try {
      final n = await repo.getNotifications();
      if (mounted) {
        setState(() => _unread = (n['unread'] as num?)?.toInt() ?? 0);
      }
    } catch (_) {}
    return today;
  }

  @override
  bool isEmpty(Object? d) => TodayData.fromJson(d).isEmpty;

  // ── formatting helpers ──────────────────────────────────────────────────────

  String _greeting() {
    final h = DateTime.now().toLocal().hour;
    if (h < 12) return 'morning';
    if (h < 18) return 'afternoon';
    return 'evening';
  }

  String _dateLabel() {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final n = DateTime.now();
    return '${days[n.weekday - 1]}, ${months[n.month - 1]} ${n.day}';
  }

  /// "Hh Mm" from a minutes metric, or null when empty.
  String? _hm(Metric m) {
    if (m.isEmpty) return null;
    final mins = m.value!.toInt();
    return '${mins ~/ 60}h ${mins % 60}m';
  }

  /// Round a metric's value to an int string, or null when empty.
  String? _int(Metric m) => m.isEmpty ? null : m.value!.round().toString();

  Widget _oxygenQualityTag(Spo2Data? spo2) {
    if (spo2 == null) return Tag('beta', color: AppColors.coral);
    final trusted = spo2.trustedCoverage ?? spo2.signalCoverage ?? 0;
    if (trusted >= 0.85) {
      return Tag('clean', color: AppColors.good);
    }
    if (trusted >= 0.60) {
      return Tag('usable', color: AppColors.warn);
    }
    return Tag('low signal', color: AppColors.coral);
  }

  /// Today as 'YYYY-MM-DD' (UTC, matching the backend's day keys).
  String _todayStr() {
    final n = DateTime.now().toUtc();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = TodayData.fromJson(data);
    final name = (app.user?['name'] ?? '').toString().trim();

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: () => refresh(),
        color: AppColors.coral,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
          children: [
            const SizedBox(height: Sp.x4),
            _topBar(name),
            // OTA update prompt + admin alert banner (admin-controlled, best-effort).
            const StatusBanner(),
            if (freshnessLabel != null) ...[
              const SizedBox(height: Sp.x3),
              _freshness(freshnessLabel!),
            ],
            const SizedBox(height: Sp.x6),
            if (phase == LoadPhase.loading)
              ..._skeleton()
            else if (phase == LoadPhase.empty)
              _emptyOrProcessing(app)
            else if (phase == LoadPhase.error)
              _empty(
                title: "Couldn't load today",
                message: errorText ?? 'Pull down to retry.',
              )
            else
              ..._content(t),
            const SizedBox(height: 110),
          ],
        ),
      ),
    );
  }

  // ── top bar ────────────────────────────────────────────────────────────────

  Widget _topBar(String name) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Good ${_greeting()},',
                style: AppText.label.copyWith(color: AppColors.inkSoft),
              ),
              const SizedBox(height: Sp.x1),
              Text(
                'Hi, ${name.isEmpty ? 'there' : name}',
                style: AppText.h1,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(_dateLabel(), style: AppText.caption),
            ],
          ),
        ),
        const SizedBox(width: Sp.x3),
        _bellButton(),
        const SizedBox(width: Sp.x2),
        RoundIconButton(
          Ic.edit,
          onTap: () => _push(() => const JournalScreen()),
        ),
        const SizedBox(width: Sp.x2),
        // Profile / settings (the old "You" tab moved here). ProfileScreen is tab
        // content (no Scaffold of its own), so wrap it when pushing standalone —
        // otherwise it renders with no Material (black bg + yellow-underlined text).
        RoundIconButton(
          Ic.profile,
          onTap: () => _push(
            () => Scaffold(
              backgroundColor: AppColors.bg,
              body: const ProfileScreen(),
            ),
          ),
        ),
        const SizedBox(width: Sp.x2),
        RoundIconButton(
          Ic.chart,
          bg: AppColors.coral,
          fg: Colors.white,
          onTap: () => _push(() => const RecapScreen()),
        ),
      ],
    );
  }

  /// Notifications bell with an unread badge; refreshes the count on return.
  Widget _bellButton() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        RoundIconButton(
          Ic.bell,
          onTap: () async {
            await Navigator.of(
              context,
            ).push(themedRoute((_) => const NotificationsScreen()));
            if (!mounted) return;
            try {
              final n = await context.read<AppState>().repo?.getNotifications();
              if (mounted) {
                setState(() => _unread = (n?['unread'] as num?)?.toInt() ?? 0);
              }
            } catch (_) {}
          },
        ),
        if (_unread > 0)
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 16),
              decoration: BoxDecoration(
                color: AppColors.coral,
                borderRadius: BorderRadius.circular(R.pill),
                border: Border.all(color: AppColors.bg, width: 1.5),
              ),
              child: Text(
                _unread > 9 ? '9+' : '$_unread',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // Builder-based so themedRoute reconstructs the screen on a theme flip (a
  // prebuilt instance would be returned unchanged and never re-colour).
  void _push(Widget Function() build) =>
      Navigator.of(context).push(themedRoute((_) => build()));

  Widget _freshness(String label) {
    return Row(
      children: [
        AppIcon(Ic.cloud, size: 14, color: AppColors.inkMuted),
        const SizedBox(width: Sp.x2),
        Text('Showing cached • $label', style: AppText.captionMuted),
      ],
    );
  }

  // ── content ──────────────────────────────────────────────────────────────────

  List<Widget> _content(TodayData t) {
    final alert = t.bodyAlert;
    final coach = t.coach;
    final status = t.status;

    return [
      if (alert != null) ...[_bodyAlert(alert), const SizedBox(height: Sp.x4)],
      if (status != null &&
          (status.overnightBuilding ||
              status.activityBuilding ||
              status.showingPriorOvernight)) ...[
        _todayStatusCard(status),
        const SizedBox(height: Sp.x4),
      ],
      // Composite Readiness headline. Shows the score when present, or a
      // "Need N more nights" baseline-building state when the composite abstains
      // for lack of baseline (need_baseline note). Hidden only when there is
      // neither a score nor a baseline note (genuinely no signal yet).
      if (!t.readiness.isEmpty || t.readiness.needMoreNights != null) ...[
        _readinessHero(t),
        const SizedBox(height: Sp.x4),
      ],
      // At-a-glance gauges: Strain / Sleep / HRV.
      _dashboard(t),
      const SizedBox(height: Sp.x4),

      // Coach — Today's Plan (server-computed).
      if (coach != null) ...[_coachCard(coach), const SizedBox(height: Sp.x4)],

      // Stat grid. Strain lives on the Body tab now (tap the Strain gauge above) —
      // no duplicate Day-strain tile here.
      _statRow(
        StatTile(
          icon: Ic.heart,
          label: 'Resting HR',
          value: _int(t.restingHr),
          unit: 'bpm',
          deltaPct: t.rhrDelta.isEmpty ? null : t.rhrDelta.value,
          deltaGoodIsUp: false, // a lower resting HR is better
          accent: AppColors.coralDeep,
          confidence: t.restingHr.isEmpty ? null : t.restingHr.confidence,
        ),
        StatTile(
          icon: Ic.fire,
          label: 'Active calories',
          value: _int(t.calories),
          unit: 'kcal',
          accent: AppColors.warn,
          confidence: t.calories.isEmpty ? null : t.calories.confidence,
          tag: Tag.forMetric(t.calories),
        ),
      ),
      const SizedBox(height: Sp.x3),
      // Steps = real 100 Hz count (streamed time) + 1 Hz walking estimate for the
      // rest, from the derivation — plus the in-flight live session not yet folded
      // in. 1 Hz can't peak-count steps, so the uncovered part is an estimate.
      _statRow(
        () {
          final base = t.steps.isEmpty ? 0 : t.steps.value!.round();
          final steps = base + context.read<AppState>().liveSteps;
          return StatTile(
            icon: Ic.run,
            label: 'Steps',
            value: steps > 0 ? '$steps' : null,
            accent: AppColors.good,
            tag: Tag('est.', color: AppColors.coral),
            onTap: () => _push(() => const ActivityScreen()),
          );
        }(),
        StatTile(
          icon: Ic.watch,
          label: 'Wear time',
          value: _hm(t.wearTime),
          accent: AppColors.coralDeep,
          confidence: t.wearTime.isEmpty ? null : t.wearTime.confidence,
          onTap: () => _push(() => const WearScreen()),
        ),
      ),
      const SizedBox(height: Sp.x3),
      _statRow(
        StatTile(
          icon: Ic.pulse,
          label: 'Stress',
          value: t.stress?.score?.toString(),
          unit: '/100',
          accent: AppColors.warn,
          tag: Tag('est.', color: AppColors.coral),
          onTap: () => _push(() => StressScreen(date: _todayStr())),
        ),
        // HRV (measured, beat-to-beat). The real one now that we decode R-R intervals.
        StatTile(
          icon: Ic.pulse,
          label: 'HRV (RMSSD)',
          value: t.hrv?.rmssd.toStringAsFixed(0),
          unit: 'ms',
          accent: AppColors.good,
          confidence: t.hrv?.confidence,
          tag: Tag('beta', color: AppColors.coral),
        ),
      ),
      const SizedBox(height: Sp.x3),
      _statRow(
        StatTile(
          icon: Ic.heart,
          label: 'Oxygen dips',
          value: t.spo2?.odiPerHour?.toStringAsFixed(1),
          unit: '/h',
          accent: AppColors.coralDeep,
          tag: _oxygenQualityTag(t.spo2),
          confidence: t.spo2?.confidence,
          onTap: () => _push(() => const OxygenScreen()),
        ),
        _bodyOverTimeTile(),
      ),
      const SizedBox(height: Sp.x4),

      // Heart rate spark.
      _hrCard(),
    ];
  }

  /// Illness / overtraining early-warning banner (a signal, not a diagnosis).
  Widget _bodyAlert(Map<String, dynamic> a) {
    final kind = (a['kind'] ?? '').toString();
    final note = (a['note'] ?? 'Your body is showing strain signals.')
        .toString();
    final overtrain = kind == 'overtraining' || kind == 'both';
    final title = kind == 'overtraining'
        ? 'High training load'
        : kind == 'both'
        ? 'Strain + high load'
        : 'Recovery signal';
    return ProCard(
      color: AppColors.warnSoft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(
              overtrain ? Ic.strain : Ic.heart,
              size: 20,
              color: AppColors.warn,
            ),
          ),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.title),
                const SizedBox(height: Sp.x1),
                Text(note, style: AppText.bodySoft),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Today's Plan — top coach suggestion + strain target, opens the full plan.
  Widget _coachCard(CoachData coach) {
    final top = coach.plan.isNotEmpty ? coach.plan.first : null;
    final tgt = coach.strainTarget;
    return ProCard(
      onTap: () => _push(() => CoachScreen(coach: coach)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: AppColors.coralSoft,
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: AppIcon(
                  Ic.recovery,
                  size: 17,
                  color: AppColors.coralDeep,
                ),
              ),
              const SizedBox(width: Sp.x2),
              Expanded(child: Text("Today's plan", style: AppText.h2)),
              if (tgt != null)
                Text(
                  'strain ~${tgt.value.toStringAsFixed(0)}',
                  style: AppText.label.copyWith(color: AppColors.coralDeep),
                ),
              const SizedBox(width: 4),
              AppIcon(Ic.arrowRight, size: 16, color: AppColors.coralDeep),
            ],
          ),
          const SizedBox(height: Sp.x3),
          if (top != null) ...[
            Text(top.title, style: AppText.title),
            const SizedBox(height: 2),
            Text(
              top.body,
              style: AppText.bodySoft,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ] else
            Text(
              coach.summary.isEmpty ? 'You\'re all set today.' : coach.summary,
              style: AppText.bodySoft,
            ),
          if (coach.plan.length > 1) ...[
            const SizedBox(height: Sp.x3),
            Text(
              '+${coach.plan.length - 1} more in your plan',
              style: AppText.captionMuted,
            ),
          ],
        ],
      ),
    );
  }

  /// Composite Readiness hero — the day's headline. Ring + score + what it blends.
  Widget _readinessHero(TodayData t) {
    final r = t.readiness;
    final status = t.status;
    final score = r.isEmpty ? null : r.value!.round();
    // Baseline-building state: the composite abstains until it has enough nights.
    final needNights = score == null ? r.needMoreNights : null;
    final tcol = score == null
        ? AppColors.inkMuted
        : (score >= 66
              ? AppColors.good
              : score >= 40
              ? AppColors.coral
              : AppColors.coralDeep);
    // Headline glyph: the score, or a clean "N nights" count while building the
    // baseline (the subtitle carries the explanation — no bare "Need 3").
    final headline = score != null
        ? '$score'
        : (needNights != null
              ? '$needNights night${needNights == 1 ? '' : 's'}'
              : '—');
    final subtitle = status?.overnightBuilding == true
        ? 'Today\'s overnight metrics are still settling after your wake-up'
        : score != null
        ? 'HRV recovery + sleep, blended'
        : (needNights != null
              ? 'more overnight wear to unlock your readiness baseline'
              : 'Building baseline — needs nocturnal HRV');
    return GlowCard(
      padding: const EdgeInsets.all(Sp.x6),
      glow: tcol,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    AppIcon(Ic.recovery, size: 16, color: AppColors.coralDeep),
                    const SizedBox(width: Sp.x2),
                    Text('READINESS', style: AppText.overline),
                  ],
                ),
                const SizedBox(height: Sp.x3),
                Text(
                  headline,
                  style: (score != null ? AppText.display : AppText.metricSm)
                      .copyWith(color: tcol),
                ),
                const SizedBox(height: Sp.x2),
                Text(subtitle, style: AppText.bodySoft),
              ],
            ),
          ),
          if (score != null)
            RingStat(
              t: (score / 100).clamp(0.0, 1.0),
              color: tcol,
              size: 96,
              stroke: 11,
              center: Text(
                '$score',
                style: AppText.metricSm.copyWith(color: tcol),
              ),
            ),
        ],
      ),
    );
  }

  /// Three small gauges under the hero — the at-a-glance trio.
  Widget _dashboard(TodayData t) {
    final status = t.status;
    final strainT = t.strain.isEmpty ? double.nan : t.strain.normalized(21);
    final need = t.sleepNeed.isEmpty ? 480.0 : t.sleepNeed.value!;
    final sleepT = t.sleepDuration.isEmpty
        ? double.nan
        : (t.sleepDuration.value! / need).clamp(0.0, 1.0).toDouble();
    final hrv = t.hrv;
    final hrvT = hrv == null
        ? double.nan
        : (hrv.rmssd / 150).clamp(0.0, 1.0).toDouble();
    return ProCard(
      child: Column(
        children: [
          Row(
            children: [
              _gauge(
                'STRAIN',
                t.strain.isEmpty ? null : t.strain.value!.toStringAsFixed(1),
                null,
                strainT,
                AppColors.coral,
                onTap: () => _push(() => const BodyScreen()),
              ),
              _gauge(
                'SLEEP',
                t.sleepDuration.isEmpty
                    ? null
                    : (t.sleepDuration.value! / 60).toStringAsFixed(1),
                'h',
                sleepT,
                AppColors.loadDetraining,
                onTap: () => _push(() => const SleepScreen()),
              ),
              _gauge(
                'HRV',
                hrv?.rmssd.toStringAsFixed(0),
                'ms',
                hrvT,
                AppColors.good,
                onTap: () => _push(() => const HeartScreen()),
              ),
            ],
          ),
          if (status != null &&
              (status.activityBuilding ||
                  status.overnightBuilding ||
                  status.showingPriorOvernight)) ...[
            const SizedBox(height: Sp.x3),
            Text(
              status.overnightBuilding
                  ? 'Sleep and recovery update after the overnight settle finishes.'
                  : status.activityBuilding
                  ? 'Day strain and steps are still building from today\'s fresh data.'
                  : 'Showing your last settled overnight while today\'s night lands.',
              style: AppText.captionMuted,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _gauge(
    String label,
    String? value,
    String? unit,
    double t,
    Color color, {
    VoidCallback? onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RingStat(
              t: t,
              color: color,
              size: 80,
              stroke: 8,
              center: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value ?? '—',
                    style: AppText.metricSm.copyWith(
                      color: value == null ? AppColors.inkMuted : color,
                    ),
                  ),
                  if (unit != null && value != null)
                    Text(unit, style: AppText.overline),
                ],
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(label, style: AppText.overline),
          ],
        ),
      ),
    );
  }

  Widget _statRow(Widget a, [Widget? b]) => Row(
    children: [
      Expanded(child: a),
      const SizedBox(width: Sp.x3),
      Expanded(child: b ?? const SizedBox.shrink()),
    ],
  );

  /// Entry point to the "Your body over time" records/streaks screen.
  Widget _bodyOverTimeTile() => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 110),
    child: ProCard(
      onTap: () => _push(() => const RecordsScreen()),
      padding: const EdgeInsets.all(Sp.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.coralSoft,
                  borderRadius: BorderRadius.circular(R.chip),
                ),
                child: AppIcon(
                  Ic.recovery,
                  size: 16,
                  color: AppColors.coralDeep,
                ),
              ),
              const SizedBox(width: Sp.x2),
              Expanded(child: Text('Your body', style: AppText.label)),
              AppIcon(Ic.arrowRight, size: 15, color: AppColors.coralDeep),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Records & streaks',
                style: AppText.title.copyWith(fontSize: 16),
              ),
              const SizedBox(height: 2),
              Text('Over time', style: AppText.captionMuted),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _hrCard() {
    final points = [
      for (final p in _hr.points) TimeSeriesPoint(p.t.toDouble(), p.v),
    ];
    final hasData = points.length >= 2;
    final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final latest = hasData ? points.last : null;
    final peak = hasData ? points.reduce((a, b) => a.y >= b.y ? a : b) : null;
    final low = hasData ? points.reduce((a, b) => a.y <= b.y ? a : b) : null;
    return ProCard(
      onTap: () => _push(() => JourneyScreen(date: _todayStr())),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(Ic.pulse, size: 19, color: AppColors.coral),
              const SizedBox(width: Sp.x2),
              Expanded(child: Text("Today's heart rate", style: AppText.h2)),
              Text(
                'Your day',
                style: AppText.label.copyWith(color: AppColors.coralDeep),
              ),
              const SizedBox(width: 2),
              AppIcon(Ic.arrowRight, size: 15, color: AppColors.coralDeep),
            ],
          ),
          const SizedBox(height: Sp.x4),
          if (hasData)
            TimeSeriesChart(
              points: points,
              color: AppColors.coral,
              height: 210,
              maxX: nowSec,
              yUnit: ' bpm',
              tooltip: (p) {
                final dt = DateTime.fromMillisecondsSinceEpoch(
                  (p.x * 1000).round(),
                ).toLocal();
                final mm = dt.minute.toString().padLeft(2, '0');
                return '${dt.hour}:$mm\n${p.y.round()} bpm';
              },
            )
          else
            SizedBox(
              height: 210,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(Ic.heart, size: 26, color: AppColors.inkMuted),
                    const SizedBox(height: Sp.x2),
                    Text(
                      'No heart-rate data yet today',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
            ),
          if (hasData) ...[
            const SizedBox(height: Sp.x4),
            Row(
              children: [
                Expanded(child: _hrMetaCell('Latest', '${latest!.y.round()}')),
                const SizedBox(width: Sp.x2),
                Expanded(child: _hrMetaCell('Peak', '${peak!.y.round()}')),
                const SizedBox(width: Sp.x2),
                Expanded(child: _hrMetaCell('Low', '${low!.y.round()}')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _hrMetaCell(String label, String value) {
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
          Text('$value bpm', style: AppText.label),
        ],
      ),
    );
  }

  // ── states ───────────────────────────────────────────────────────────────────

  /// Honest empty/processing state. Three cases, never a blank-with-no-reason:
  ///   • analysis running  → "Processing… N/M days" with a spinner.
  ///   • raw collected, not yet derived → invite to analyze now (shows record count).
  ///   • truly no data      → "Wear + sync to see today".
  Widget _emptyOrProcessing(AppState app) {
    final raw = app.dbCounts['raw'] ?? 0;
    if (app.reanalyzing) {
      return _processing(
        app.reanalyzeProgress.isEmpty
            ? 'Analyzing your stored data…'
            : '${app.reanalyzeProgress.replaceFirst('Analyzing', 'Processing')} days',
      );
    }
    if (raw > 0) {
      return _processingPrompt(app, raw);
    }
    return _empty(
      title: 'Wear + sync to see today',
      message:
          'Put your strap on and keep the app open. Your daily metrics '
          'appear after the next sync and analytics run.',
    );
  }

  Widget _processing(String label) => ProCard(
    padding: const EdgeInsets.all(Sp.x6),
    child: Column(
      children: [
        SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppColors.coral,
          ),
        ),
        const SizedBox(height: Sp.x4),
        Text(
          'Processing your data',
          style: AppText.h2,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Sp.x2),
        Text(label, style: AppText.bodySoft, textAlign: TextAlign.center),
      ],
    ),
  );

  Widget _processingPrompt(AppState app, int raw) => ProCard(
    padding: const EdgeInsets.all(Sp.x6),
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(Sp.x4),
          decoration: BoxDecoration(
            color: AppColors.coralSoft,
            shape: BoxShape.circle,
          ),
          child: AppIcon(Ic.history, size: 30, color: AppColors.coralDeep),
        ),
        const SizedBox(height: Sp.x4),
        Text(
          'Data collected — not analyzed yet',
          style: AppText.h2,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Sp.x2),
        Text(
          'Stored $raw raw record${raw == 1 ? '' : 's'} from your strap. '
          'Analysis runs automatically after a sync — or run it now.',
          style: AppText.bodySoft,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Sp.x5),
        FilledButton(
          onPressed: () => app.reanalyzeAll(),
          child: const Text('Analyze now'),
        ),
      ],
    ),
  );

  Widget _empty({required String title, required String message}) {
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
            child: AppIcon(Ic.watch, size: 30, color: AppColors.coralDeep),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _todayStatusCard(TodayStatus status) {
    String label;
    if (status.overnightBuilding && status.activityBuilding) {
      label =
          'Today\'s activity is landing and the overnight metrics are still settling.';
    } else if (status.overnightBuilding) {
      label =
          'Today\'s overnight metrics are still computing. Sleep and readiness will fill when that pass finishes.';
    } else if (status.activityBuilding) {
      label =
          'Fresh data is in for today, but the day metrics are still catching up.';
    } else {
      label =
          'Showing the last settled overnight while today\'s overnight metrics have not landed yet.';
    }
    final overnight = status.overnightDay;
    final extra = status.showingPriorOvernight && overnight != null
        ? ' Last settled night: $overnight.'
        : '';
    return ProCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(Ic.info, size: 18, color: AppColors.coralDeep),
          const SizedBox(width: Sp.x3),
          Expanded(child: Text('$label$extra', style: AppText.bodySoft)),
        ],
      ),
    );
  }

  List<Widget> _skeleton() => [
    const ProCard(child: SizedBox(height: 96)),
    const SizedBox(height: Sp.x4),
    _statRow(_skelTile(), _skelTile()),
    const SizedBox(height: Sp.x3),
    _statRow(_skelTile(), _skelTile()),
    const SizedBox(height: Sp.x3),
    _statRow(_skelTile(), _skelTile()),
    const SizedBox(height: Sp.x4),
    const ProCard(child: SizedBox(height: 140)),
  ];

  Widget _skelTile() => const ProCard(
    padding: EdgeInsets.all(Sp.x4),
    child: SizedBox(height: 96),
  );
}
