// Home — today's readiness, key stats, and heart rate.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/metric.dart';
import '../../models/payloads.dart';
import '../../net/api_client.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
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
  Future<Object?> fetch(ApiClient api) async {
    final today = await api.getToday();
    // Push a fresh snapshot + auth to the home/lock-screen widget (best-effort).
    // Auth lets the widget self-refresh /today ~hourly even when the app is closed.
    WidgetService.saveAuth(api.config.url, api.session.accessJwt);
    WidgetService.push(TodayData.fromJson(today));
    // HR chart + notification count are best-effort — never fail the screen.
    try {
      final chart = await api.getChart('hr');
      if (mounted) setState(() => _hr = ChartSeries.fromJson(chart));
    } catch (_) {}
    try {
      final n = await api.getNotifications();
      if (mounted) setState(() => _unread = (n['unread'] as num?)?.toInt() ?? 0);
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
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    const days = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
      'Sunday'
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
              _empty(
                title: 'Wear + sync to see today',
                message:
                    'Put your strap on and keep the app open. Your daily metrics '
                    'appear after the next sync and analytics run.',
              )
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
        RoundIconButton(Ic.edit, onTap: () => _push(const JournalScreen())),
        const SizedBox(width: Sp.x2),
        // Profile / settings (the old "You" tab moved here). ProfileScreen is tab
        // content (no Scaffold of its own), so wrap it when pushing standalone —
        // otherwise it renders with no Material (black bg + yellow-underlined text).
        RoundIconButton(Ic.profile, onTap: () => _push(
            const Scaffold(backgroundColor: AppColors.bg, body: ProfileScreen()))),
        const SizedBox(width: Sp.x2),
        RoundIconButton(Ic.chart,
            bg: AppColors.coral,
            fg: Colors.white,
            onTap: () => _push(const RecapScreen())),
      ],
    );
  }

  /// Notifications bell with an unread badge; refreshes the count on return.
  Widget _bellButton() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        RoundIconButton(Ic.bell, onTap: () async {
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationsScreen()));
          if (!mounted) return;
          try {
            final n = await context.read<AppState>().api?.getNotifications();
            if (mounted) setState(() => _unread = (n?['unread'] as num?)?.toInt() ?? 0);
          } catch (_) {}
        }),
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
                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }

  void _push(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  Widget _freshness(String label) {
    return Row(
      children: [
        const AppIcon(Ic.cloud, size: 14, color: AppColors.inkMuted),
        const SizedBox(width: Sp.x2),
        Text('Showing cached • $label',
            style: AppText.captionMuted),
      ],
    );
  }

  // ── content ──────────────────────────────────────────────────────────────────

  List<Widget> _content(TodayData t) {
    final alert = t.bodyAlert;
    final coach = t.coach;
    final date = _todayStr();

    return [
      if (alert != null) ...[
        _bodyAlert(alert),
        const SizedBox(height: Sp.x4),
      ],
      // Composite Readiness headline (abstains until HRV exists).
      if (!t.readiness.isEmpty) ...[
        _readinessHero(t),
        const SizedBox(height: Sp.x4),
      ],
      // At-a-glance gauges: Strain / Sleep / HRV.
      _dashboard(t),
      const SizedBox(height: Sp.x4),

      // Coach — Today's Plan (server-computed).
      if (coach != null) ...[
        _coachCard(coach),
        const SizedBox(height: Sp.x4),
      ],

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
      _statRow(
        StatTile(
          icon: Ic.run,
          label: 'Steps',
          value: _int(t.steps),
          accent: AppColors.good,
          confidence: t.steps.isEmpty ? null : t.steps.confidence,
          tag: Tag.forMetric(t.steps),
        ),
        StatTile(
          icon: Ic.watch,
          label: 'Wear time',
          value: _hm(t.wearTime),
          accent: AppColors.coralDeep,
          confidence: t.wearTime.isEmpty ? null : t.wearTime.confidence,
          onTap: () => _push(const WearScreen()),
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
          tag: const Tag('est.', color: AppColors.coral),
          onTap: () => _push(StressScreen(date: date)),
        ),
        // HRV (measured, beat-to-beat). The real one now that we decode R-R intervals.
        StatTile(
          icon: Ic.pulse,
          label: 'HRV (RMSSD)',
          value: t.hrv == null ? null : t.hrv!.rmssd.toStringAsFixed(0),
          unit: 'ms',
          accent: AppColors.good,
          confidence: t.hrv?.confidence,
          tag: const Tag('beta', color: AppColors.coral),
        ),
      ),
      const SizedBox(height: Sp.x3),
      _statRow(
        StatTile(
          icon: Ic.heart,
          label: 'Blood O₂ (rel.)',
          value: t.spo2Idx == null
              ? null
              : (t.spo2Idx! >= 0 ? '+' : '') + t.spo2Idx!.toStringAsFixed(0),
          unit: 'Δ',
          accent: AppColors.coralDeep,
          tag: const Tag('beta', color: AppColors.coral),
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
    final note = (a['note'] ?? 'Your body is showing strain signals.').toString();
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
              color: Colors.white.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(R.chip),
            ),
            child: AppIcon(overtrain ? Ic.strain : Ic.heart,
                size: 20, color: AppColors.warn),
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
      onTap: () => _push(CoachScreen(coach: coach)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                  color: AppColors.coralSoft, borderRadius: BorderRadius.circular(R.chip)),
              child: const AppIcon(Ic.recovery, size: 17, color: AppColors.coralDeep),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(child: Text("Today's plan", style: AppText.h2)),
            if (tgt != null)
              Text('strain ~${tgt.value.toStringAsFixed(0)}',
                  style: AppText.label.copyWith(color: AppColors.coralDeep)),
            const SizedBox(width: 4),
            const AppIcon(Ic.arrowRight, size: 16, color: AppColors.coralDeep),
          ]),
          const SizedBox(height: Sp.x3),
          if (top != null) ...[
            Text(top.title, style: AppText.title),
            const SizedBox(height: 2),
            Text(top.body, style: AppText.bodySoft,
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ] else
            Text(coach.summary.isEmpty ? 'You\'re all set today.' : coach.summary,
                style: AppText.bodySoft),
          if (coach.plan.length > 1) ...[
            const SizedBox(height: Sp.x3),
            Text('+${coach.plan.length - 1} more in your plan',
                style: AppText.captionMuted),
          ],
        ],
      ),
    );
  }

  /// Composite Readiness hero — the day's headline. Ring + score + what it blends.
  Widget _readinessHero(TodayData t) {
    final r = t.readiness;
    final score = r.isEmpty ? null : r.value!.round();
    final tcol = score == null
        ? AppColors.inkMuted
        : (score >= 66 ? AppColors.good : score >= 40 ? AppColors.coral : AppColors.coralDeep);
    return GlowCard(
      padding: const EdgeInsets.all(Sp.x6),
      glow: tcol,
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const AppIcon(Ic.recovery, size: 16, color: AppColors.coralDeep),
            const SizedBox(width: Sp.x2),
            Text('READINESS', style: AppText.overline),
          ]),
          const SizedBox(height: Sp.x3),
          Text(score == null ? '—' : '$score', style: AppText.display.copyWith(color: tcol)),
          const SizedBox(height: Sp.x2),
          Text(score == null
              ? 'Building baseline — needs nocturnal HRV'
              : 'HRV recovery + sleep, blended', style: AppText.bodySoft),
        ])),
        if (score != null)
          RingStat(t: (score / 100).clamp(0.0, 1.0), color: tcol, size: 96, stroke: 11,
              center: Text('$score', style: AppText.metricSm.copyWith(color: tcol))),
      ]),
    );
  }

  /// Three small gauges under the hero — the at-a-glance trio.
  Widget _dashboard(TodayData t) {
    final strainT = t.strain.isEmpty ? double.nan : t.strain.normalized(21);
    final need = t.sleepNeed.isEmpty ? 480.0 : t.sleepNeed.value!;
    final sleepT = t.sleepDuration.isEmpty
        ? double.nan
        : (t.sleepDuration.value! / need).clamp(0.0, 1.0).toDouble();
    final hrv = t.hrv;
    final hrvT = hrv == null ? double.nan : (hrv.rmssd / 150).clamp(0.0, 1.0).toDouble();
    return ProCard(
      child: Row(
        children: [
          _gauge('STRAIN', t.strain.isEmpty ? null : t.strain.value!.toStringAsFixed(1),
              null, strainT, AppColors.coral,
              onTap: () => _push(const BodyScreen())),
          _gauge('SLEEP', t.sleepDuration.isEmpty ? null : (t.sleepDuration.value! / 60).toStringAsFixed(1),
              'h', sleepT, AppColors.loadDetraining,
              onTap: () => _push(const SleepScreen())),
          _gauge('HRV', hrv == null ? null : hrv.rmssd.toStringAsFixed(0),
              'ms', hrvT, AppColors.good,
              onTap: () => _push(const HeartScreen())),
        ],
      ),
    );
  }

  Widget _gauge(String label, String? value, String? unit, double t, Color color,
      {VoidCallback? onTap}) {
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
                Text(value ?? '—',
                    style: AppText.metricSm
                        .copyWith(color: value == null ? AppColors.inkMuted : color)),
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

  Widget _statRow(Widget a, Widget b) => Row(
        children: [
          Expanded(child: a),
          const SizedBox(width: Sp.x3),
          Expanded(child: b),
        ],
      );

  /// Entry point to the "Your body over time" records/streaks screen.
  Widget _bodyOverTimeTile() => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 110),
        child: ProCard(
          onTap: () => _push(const RecordsScreen()),
          padding: const EdgeInsets.all(Sp.x3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                      color: AppColors.coralSoft, borderRadius: BorderRadius.circular(R.chip)),
                  child: const AppIcon(Ic.recovery, size: 16, color: AppColors.coralDeep),
                ),
                const SizedBox(width: Sp.x2),
                Expanded(child: Text('Your body', style: AppText.label)),
                const AppIcon(Ic.arrowRight, size: 15, color: AppColors.coralDeep),
              ]),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Records & streaks',
                      style: AppText.title.copyWith(fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('Over time', style: AppText.captionMuted),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _hrCard() {
    final values = _hr.points.map((p) => p.v).toList();
    final hasData = values.length >= 2;
    return ProCard(
      onTap: () => _push(JourneyScreen(date: _todayStr())),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppIcon(Ic.pulse, size: 19, color: AppColors.coral),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Text("Today's heart rate", style: AppText.h2),
              ),
              Text('Your day', style: AppText.label.copyWith(color: AppColors.coralDeep)),
              const SizedBox(width: 2),
              const AppIcon(Ic.arrowRight, size: 15, color: AppColors.coralDeep),
            ],
          ),
          const SizedBox(height: Sp.x4),
          if (hasData)
            AreaSpark(values, color: AppColors.coral, height: 96)
          else
            SizedBox(
              height: 96,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIcon(Ic.heart, size: 26, color: AppColors.inkMuted),
                    const SizedBox(height: Sp.x2),
                    Text('No heart-rate data yet today',
                        style: AppText.captionMuted),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── states ───────────────────────────────────────────────────────────────────

  Widget _empty({required String title, required String message}) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: const BoxDecoration(
              color: AppColors.coralSoft,
              shape: BoxShape.circle,
            ),
            child: const AppIcon(Ic.watch, size: 30, color: AppColors.coralDeep),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message,
              style: AppText.bodySoft, textAlign: TextAlign.center),
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
