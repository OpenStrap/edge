// Today — the flagship: an orbit-score hero floating on the page, an AI
// briefing hero, and a true mixed-tone BENTO of vitals (masonry columns,
// paper/ink/accent tiles, domain accents, clean sparks — no glow anywhere).
//
// Numbers-first: every tile is a big tabular figure with a whispered label;
// explanations live behind long-press InfoSheets and tap-throughs. Sync is
// invisible: pull-to-refresh quietly asks the strap for fresh data — there is
// deliberately NO "stored to / syncs every / last data" copy on this screen.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/briefing.dart';
import '../../models/metric.dart';
import '../../models/payloads.dart';
import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../../theme/theme_switcher.dart';
import '../design/design.dart';
import '../widgets/screen_loader.dart';
import '../widgets/status_banner.dart';
import '../journal/journal_screen.dart';
import '../recap/recap_screen.dart';
import '../ai/ai_breakdown_screen.dart';
import '../coach/coach_screen.dart';
import '../profile/profile_screen.dart';
import '../screens/screens.dart';
import '../journey/journey_screen.dart';
import '../stress/stress_screen.dart';
import '../records/records_screen.dart';
import '../notifications/notifications_screen.dart';
import '../../widget/widget_service.dart';
import 'ai_summary_card.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});
  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen>
    with ScreenLoaderMixin<TodayScreen> {
  ChartSeries _hr = const ChartSeries([]);
  int _unread = 0;
  bool _storyDismissed = false;

  /// 7-day spark series per vital (nulls = gaps), best-effort.
  Map<String, List<double?>> _sparks = const {};

  /// This week's (Mon→Sun) daily step counts for the week-of-rings strip;
  /// null = no data that day (incl. future days), best-effort.
  List<double?> _stepsWeek = const [];

  /// Last night's stage minutes + hypnogram, best-effort (nulls hide them).
  ({int? awakeMin, int? remMin, int? lightMin, int? deepMin})? _stageMin;
  List<HypnoSeg> _hypno = const [];

  /// Show the once-a-morning recovery story: only with a real readiness score,
  /// and only if it hasn't already been shown for today's date.
  bool _showStory(TodayData t) {
    if (_storyDismissed || t.readiness.isEmpty) return false;
    return Prefs.getString('ui.recovery_story_date', '') != _todayStr();
  }

  void _dismissStory() {
    Prefs.setString('ui.recovery_story_date', _todayStr());
    if (mounted) setState(() => _storyDismissed = true);
  }

  @override
  String get cacheKey => 'today';

  @override
  Future<Object?> fetch(LocalRepository repo) async {
    final today = await repo.getToday();
    // Push a fresh snapshot to the home/lock-screen widget (best-effort).
    WidgetService.push(TodayData.fromJson(today));
    // HR chart + notifications + sparklines + last-night stages are all
    // best-effort — never fail the screen.
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
    try {
      final sparks = <String, List<double?>>{};
      for (final m in const ['hrv', 'resting_hr', 'strain', 'sleep']) {
        final trend = await repo.getTrend(m, scale: 'week');
        final buckets = (trend['buckets'] as List?) ?? const [];
        sparks[m] = [
          for (final b in buckets.whereType<Map>())
            b['has'] == true ? ((b['value'] as num?)?.toDouble()) : null,
        ];
      }
      if (mounted) setState(() => _sparks = sparks);
    } catch (_) {}
    try {
      // Steps week-of-rings: anchor the 7-day trend on this week's Sunday so
      // the buckets are the current Mon→Sun calendar week (the unanchored
      // default is a rolling window ending at the last data day).
      final now = DateTime.now();
      final sunday = DateTime(
        now.year,
        now.month,
        now.day + (DateTime.daysPerWeek - now.weekday),
      );
      final trend = await repo.getTrend(
        'steps',
        scale: 'week',
        anchor: dayLabelOf(sunday),
      );
      final buckets = (trend['buckets'] as List?) ?? const [];
      final week = <double?>[
        for (final b in buckets.whereType<Map>())
          b['has'] == true ? ((b['value'] as num?)?.toDouble()) : null,
      ];
      if (mounted) setState(() => _stepsWeek = week);
    } catch (_) {}
    try {
      final st = TodayData.fromJson(today).status;
      final s = await repo.getDaySleep(st?.overnightDay ?? _todayStr());
      if (s['has_sleep'] == true && mounted) {
        int? mi(Object? v) => (v as num?)?.toInt();
        setState(() {
          _stageMin = (
            awakeMin: mi(s['awake_min']),
            remMin: mi(s['rem_min']),
            lightMin: mi(s['light_min']),
            deepMin: mi(s['deep_min']),
          );
          _hypno = hypnoSegmentsFromPoints(
            (s['hypnogram'] as List?) ?? const [],
          );
        });
      }
    } catch (_) {}
    return today;
  }

  @override
  bool isEmpty(Object? d) => TodayData.fromJson(d).isEmpty;

  // ── formatting helpers ──────────────────────────────────────────────────────

  /// Today as 'YYYY-MM-DD' — the LOCAL day label the day model keys by.
  String _todayStr() => todayLabel();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = TodayData.fromJson(data);

    return AppScaffold(
      // Brand wordmark — a confident title, not a greeting.
      titleWidget: Text(
        'Edge',
        style: AppText.h1.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.9,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        _bellButton(),
        RoundIconButton(
          Ic.edit,
          osIcon: OsIcon.edit,
          onTap: () => _push(() => const JournalScreen()),
        ),
        // Profile / settings.
        RoundIconButton(
          Ic.profile,
          osIcon: OsIcon.profile,
          onTap: () => _push(() => const ProfileScreen()),
        ),
        // Recap: plain surface like its siblings — the full-colour art would
        // clash on the old coral fill.
        RoundIconButton(
          Ic.chart,
          osIcon: OsIcon.recap,
          onTap: () => _push(() => const RecapScreen()),
        ),
      ],
      body: RefreshIndicator(
        // Sync is invisible: the pull quietly asks the strap for fresh data
        // AND reloads the screen — no sync copy anywhere on Today.
        onRefresh: () async {
          try {
            context.read<AppState>().forceResync();
          } catch (_) {}
          await refresh();
        },
        color: AppColors.accent,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, 120),
          children: [
            // OTA update prompt + admin alert banner (self-hiding).
            const StatusBanner(),
            const SizedBox(height: Sp.x2),
            if (phase == LoadPhase.loading)
              ..._skeleton()
            else if (phase == LoadPhase.empty)
              _emptyOrProcessing(app)
            else if (phase == LoadPhase.error)
              StateCard(
                icon: Ic.cloud,
                title: "Couldn't load today",
                message: errorText ?? 'Pull down to retry.',
                actionLabel: 'Retry',
                onAction: () => refresh(),
              )
            else
              ..._content(t),
          ],
        ),
      ),
    );
  }

  // ── header actions ──────────────────────────────────────────────────────────

  /// Notifications bell with an unread badge; refreshes the count on return.
  Widget _bellButton() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        RoundIconButton(
          Ic.bell,
          osIcon: OsIcon.notifications,
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
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(R.pill),
                border: Border.all(color: AppColors.background, width: 1.5),
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

  // ── content ──────────────────────────────────────────────────────────────────

  List<Widget> _content(TodayData t) {
    final app = context.read<AppState>();
    final coach = t.coach;
    final alert = t.bodyAlert;
    final status = t.status;

    // Every substantive item below carries a stable Key. This list is
    // unkeyed-fragile otherwise: several conditions here (freshness banner,
    // alert chip, coach row) flip during exactly the moments AppState is
    // notifying most often (an active backfill/derive pass) — without keys,
    // inserting/removing an item shifts every widget below it by one slot in
    // the plain ListView, Flutter's positional (no-key) diff can't match old
    // vs new elements by identity, and it unmounts+remounts the mismatched
    // subtrees — replaying every dsEnter/dsPop entrance at once (the
    // "screen is glitching" symptom). Keys let it match by identity instead
    // of position, so a banner toggling on/off never disturbs its siblings.
    return [
      if (_showStory(t)) ...[
        KeyedSubtree(
          key: const ValueKey('today-story'),
          child: _RecoveryStory(
            recoveredPct: t.readiness.value!.round(),
            sleptMin: t.sleepDuration.isEmpty
                ? null
                : t.sleepDuration.value!.round(),
            needMin: t.sleepNeed.isEmpty ? null : t.sleepNeed.value!.round(),
            hrvRmssd: t.hrv?.rmssd,
            hrvDelta: (t.hrv?.baseline != null)
                ? (t.hrv!.rmssd - t.hrv!.baseline!)
                : null,
            planTitle: (coach?.plan.isNotEmpty ?? false)
                ? coach!.plan.first.title
                : null,
            planBody: (coach?.plan.isNotEmpty ?? false)
                ? coach!.plan.first.body
                : null,
            onDone: _dismissStory,
          ).dsEnter(),
        ),
        const SizedBox(height: Sp.x3),
      ],
      // Data-freshness note — only when the band data is genuinely stale or a
      // metrics pass is mid-flight (settling states also get the compact chip
      // inside TodayVitals).
      if (_shouldShowTodayStatus(app, status)) ...[
        KeyedSubtree(
          key: const ValueKey('today-freshness'),
          child: _todayStatusCard(app, status),
        ),
        const SizedBox(height: Sp.x3),
      ],
      // AI briefing hero — shows the cached one-liner for the current period;
      // tapping opens the shared breakdown screen. Reads the BriefingStore
      // synchronously at build; AppState.notifyListeners() repaints it when a
      // briefing is generated opportunistically on foreground.
      KeyedSubtree(
        key: const ValueKey('today-ai-summary'),
        child: Builder(builder: (_) {
          final period = currentBriefingPeriod(DateTime.now());
          final brief = BriefingStore.read(period);
          return AiSummaryCard(
            summary: brief?.oneLiner,
            onTap: () => _push(() => AiBreakdownScreen(period: period)),
          );
        }).dsEnter(index: 0),
      ),
      if (alert != null) ...[
        const SizedBox(height: Sp.x3),
        KeyedSubtree(
          key: const ValueKey('today-alert'),
          child: _alertChipRow(alert),
        ),
      ],
      KeyedSubtree(
        key: const ValueKey('today-vitals'),
        child: TodayVitals(
          t: t,
          sparks: _sparks,
          stepsWeek: _stepsWeek,
          liveSteps: context.read<AppState>().liveSteps,
          stageMin: _stageMin,
          hypno: _hypno,
          onOpen: _open,
        ),
      ),
      const SizedBox(height: Sp.x3),
      if (coach != null) ...[
        KeyedSubtree(
          key: const ValueKey('today-coach'),
          child: _coachRow(coach).dsEnter(index: 5),
        ),
        const SizedBox(height: Sp.x3),
      ],
      KeyedSubtree(
        key: const ValueKey('today-lookback'),
        child: _lookbackCard().dsEnter(index: 6),
      ),
    ];
  }

  void _open(String id) {
    switch (id) {
      case 'readiness':
        final coach = TodayData.fromJson(data).coach;
        if (coach != null) {
          _push(() => CoachScreen(coach: coach));
        } else {
          showInfoSheet(
            context,
            title: 'Readiness',
            body:
                'One 0–100 score blending overnight HRV, resting heart rate, '
                'sleep and recent strain against your own baselines.',
            methodNote: 'Composite z-score vs your rolling baselines',
          );
        }
      case 'sleep':
        _push(() => const SleepScreen());
      case 'heart':
        _push(() => const HeartScreen());
      case 'body':
        _push(() => const BodyScreen());
      case 'activity':
        _push(() => const ActivityScreen());
      case 'wear':
        _push(() => const WearScreen());
      case 'stress':
        _push(() => StressScreen(date: _todayStr()));
      case 'oxygen':
        _push(() => const OxygenScreen());
      case 'records':
        _push(() => const RecordsScreen());
    }
  }

  /// Illness / overtraining early-warning — one chip + the note behind (i).
  Widget _alertChipRow(Map<String, dynamic> a) {
    final kind = (a['kind'] ?? '').toString();
    final note = (a['note'] ?? 'Your body is showing strain signals.').toString();
    final title = kind == 'overtraining'
        ? 'High training load'
        : kind == 'both'
        ? 'Strain + high load'
        : 'Recovery signal';
    return Row(
      children: [
        StatusChip(title, icon: Icons.error_outline, tone: ChipTone.warn),
        InfoDot(
          title: title,
          body: note,
          methodNote: 'A signal from your own baselines — not a diagnosis',
        ),
        const Spacer(),
      ],
    ).dsPop();
  }

  /// Today's plan — one glanceable row; the full plan is a tap away.
  Widget _coachRow(CoachData coach) {
    final top = coach.plan.isNotEmpty ? coach.plan.first : null;
    final tgt = coach.strainTarget;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      child: ListRow(
        icon: Ic.recovery,
        osIcon: OsIcon.today,
        iconColor: AppColors.accent,
        title: "Today's plan",
        subtitle: top?.title ??
            (coach.summary.isEmpty ? "You're all set today." : coach.summary),
        trailing: tgt == null
            ? null
            : StatusChip(
                'strain ~${tgt.value.toStringAsFixed(0)}',
                tone: ChipTone.accent,
              ),
        onTap: () => _push(() => CoachScreen(coach: coach)),
      ),
    );
  }

  /// The entry point into "Your day" — the merged multi-vital lookback
  /// (heart rate, HRV, resp, skin temp). Deliberately NOT a live/current-bpm
  /// reading (that's the ambient "LIVE HEART RATE" tile on the Heart screen);
  /// this card is a portal, not a live gauge — so its hero is the day's
  /// peak/low HR chips + a preview curve, never an instantaneous number.
  Widget _lookbackCard() {
    final points = [
      for (final p in _hr.points) TimeSeriesPoint(p.t.toDouble(), p.v),
    ];
    final hasData = points.length >= 2;
    final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final peak = hasData ? points.reduce((a, b) => a.y >= b.y ? a : b) : null;
    final low = hasData ? points.reduce((a, b) => a.y <= b.y ? a : b) : null;
    return SurfaceCard(
      onTap: () => _push(() => JourneyScreen(date: _todayStr())),
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const OsAppIcon(OsIcon.heartRate, size: 34),
              const SizedBox(width: Sp.x2),
              Expanded(child: Text('LOOKBACK', style: AppText.overline)),
              AppIcon(Ic.arrowRight, size: 15, color: AppColors.onSurfaceFaint),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Text(
            hasData
                ? 'Heart rate, HRV, temp — your whole day'
                : 'No data yet today',
            style: AppText.body,
          ),
          if (hasData) ...[
            const SizedBox(height: Sp.x3),
            Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x1,
              children: [
                StatusChip('Peak ${peak!.y.round()}', tone: ChipTone.accent),
                StatusChip('Low ${low!.y.round()}'),
              ],
            ),
          ],
          if (hasData) ...[
            const SizedBox(height: Sp.x4),
            TimeSeriesChart(
              points: points,
              color: DomainAccent.heart,
              height: 180,
              maxX: nowSec,
              yUnit: ' bpm',
              tooltip: (p) {
                final dt = DateTime.fromMillisecondsSinceEpoch(
                  (p.x * 1000).round(),
                ).toLocal();
                final mm = dt.minute.toString().padLeft(2, '0');
                return '${dt.hour}:$mm\n${p.y.round()} bpm';
              },
            ),
          ],
        ],
      ),
    );
  }

  // ── states ───────────────────────────────────────────────────────────────────

  /// Honest empty/processing state. Three cases, never a blank-with-no-reason:
  ///   • analysis running  → "Processing… N/M days" with a spinner.
  ///   • decoded data collected, not yet derived → invite to analyze now.
  ///   • truly no data      → "Wear + sync to see today".
  Widget _emptyOrProcessing(AppState app) {
    final raw = app.dbCounts['decoded_onehz'] ?? app.dbCounts['raw'] ?? 0;
    if (app.reanalyzing) {
      return SurfaceCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: Column(
          children: [
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(height: Sp.x4),
            Text('Processing your data',
                style: AppText.h2, textAlign: TextAlign.center),
            const SizedBox(height: Sp.x2),
            Text(
              app.reanalyzeProgress.isEmpty
                  ? 'Analyzing your stored data…'
                  : '${app.reanalyzeProgress.replaceFirst('Analyzing', 'Processing')} days',
              style: AppText.bodySoft,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    if (raw > 0) {
      return StateCard(
        icon: Ic.history,
        title: 'Data collected — not analyzed yet',
        message:
            'Stored $raw raw record${raw == 1 ? '' : 's'} from your strap. '
            'Analysis runs automatically after a sync — or run it now.',
        actionLabel: 'Analyze now',
        onAction: () => app.reanalyzeAll(),
      );
    }
    return const StateCard(
      icon: Ic.watch,
      title: 'Wear + sync to see today',
      message:
          'Put your strap on and keep the app open. Your daily metrics '
          'appear after the next sync and analytics run.',
    );
  }

  bool _shouldShowTodayStatus(AppState app, TodayStatus? status) {
    final last = app.lastRecordAt;
    final stale =
        last == null || DateTime.now().difference(last).inMinutes >= 60;
    if (stale) return true;
    if (status == null) return false;
    return status.overnightBuilding ||
        status.activityBuilding ||
        status.showingPriorOvernight;
  }

  Widget _todayStatusCard(AppState app, TodayStatus? status) {
    final last = app.lastRecordAt;
    final stale =
        last == null || DateTime.now().difference(last).inMinutes >= 60;
    final capture = app.pipelineStatus['capture'] as Map<String, dynamic>?;
    final derive = app.pipelineStatus['derive'] as Map<String, dynamic>?;
    final captureActive = capture?['active'] == true;
    final deriveRunning = derive?['running'] == true;
    final pendingLight = derive?['pending_light'] == true;
    final pendingHeavy = derive?['pending_heavy'] == true;

    String label;
    if (stale &&
        (captureActive || deriveRunning || pendingLight || pendingHeavy)) {
      label =
          'Your latest band data is more than an hour behind. OpenStrap is catching up now and this page will refresh automatically when sleep and today\'s metrics are ready.';
    } else if (stale && app.isConnected) {
      label =
          'Your latest band data is more than an hour behind. OpenStrap is connected and waiting for the next data handoff.';
    } else if (stale) {
      label =
          'Your latest band data is more than an hour behind. Reconnect the band and this page will refresh automatically once new data is captured and computed.';
    } else if (status?.overnightBuilding == true &&
        status?.activityBuilding == true) {
      label =
          'Today\'s activity is landing and the overnight metrics are still settling.';
    } else if (status?.overnightBuilding == true) {
      label =
          'Today\'s overnight metrics are still computing. Sleep and readiness will fill when that pass finishes.';
    } else if (status?.activityBuilding == true) {
      label =
          'Fresh data is in for today, but the day metrics are still catching up.';
    } else {
      label =
          'Showing the last settled overnight while today\'s overnight metrics have not landed yet.';
    }
    final overnight = status?.overnightDay;
    final extra = status?.showingPriorOvernight == true && overnight != null
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
    Skeleton.hero(),
    const SizedBox(height: Sp.x3),
    Skeleton.tileRow(rows: 3),
    const SizedBox(height: Sp.x3),
    Skeleton.chart(height: 140),
  ];
}

/// TodayVitals — the pure, testable heart of the redesigned Today: the
/// OrbitScore readiness hero floating on the page with domain satellites,
/// then a mixed-tone bento (masonry columns of paper / ink / accent tiles —
/// HRV, RHR, Sleep with stages, Strain arc, Steps, Calories, Stress, O₂),
/// a week-of-rings consistency strip, and the wear/records rows. Absent
/// inputs render the honest em-dash; explanations live behind long-press.
class TodayVitals extends StatelessWidget {
  final TodayData t;

  /// 7-day series per vital ('hrv' | 'resting_hr' | 'strain' | 'sleep');
  /// missing keys just hide the sparkline.
  final Map<String, List<double?>> sparks;

  /// This week's (Mon→Sun) daily step counts for the week-of-rings strip;
  /// null = no data that day. Today's entry is superseded by the live figure.
  final List<double?> stepsWeek;

  /// Steps from the in-flight live session, not yet folded into the day metric.
  final int liveSteps;

  /// Last night's stage minutes (nulls hide the stage bar).
  final ({int? awakeMin, int? remMin, int? lightMin, int? deepMin})? stageMin;

  /// Last night's hypnogram segments (empty hides the mini timeline).
  final List<HypnoSeg> hypno;

  /// Tap-through router: readiness | sleep | heart | body | activity | wear |
  /// stress | oxygen | records.
  final void Function(String id) onOpen;

  const TodayVitals({
    super.key,
    required this.t,
    this.sparks = const {},
    this.stepsWeek = const [],
    this.liveSteps = 0,
    this.stageMin,
    this.hypno = const [],
    required this.onOpen,
  });

  /// "Hh Mm" from a minutes metric, or null when empty.
  String? _hm(Metric m) {
    if (m.isEmpty) return null;
    final mins = m.value!.toInt();
    return '${mins ~/ 60}h ${(mins % 60).toString().padLeft(2, '0')}m';
  }

  String? _int(Metric m) => m.isEmpty ? null : m.value!.round().toString();

  List<double?>? _spark(String key) {
    final s = sparks[key];
    return (s == null || s.length < 2) ? null : s;
  }

  /// have/need parsed from the `need_baseline:have=H,need=N` note.
  (int have, int need)? _baselineFill(Metric m) {
    final note = m.note;
    if (note == null) return null;
    final match = RegExp(r'have=(\d+),need=(\d+)').firstMatch(note);
    if (match == null) return null;
    final need = int.tryParse(match.group(2)!) ?? 0;
    if (need <= 0) return null;
    final have = (int.tryParse(match.group(1)!) ?? 0).clamp(0, need);
    return (have, need);
  }

  @override
  Widget build(BuildContext context) {
    final statusChip = _statusChip(t.status);
    final week = _weekRings();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (statusChip != null) ...[
          const SizedBox(height: Sp.x3),
          statusChip,
        ],
        // The hero floats directly on the page — no card chrome around it.
        _orbitHero().dsEnter(index: 1),
        const SizedBox(height: Sp.x2),
        BentoColumns(
          left: [
            _hrvTile(context),
            _sleepTile(),
            _caloriesTile(),
            _stressTile(),
          ],
          right: [
            _rhrTile(),
            _strainTile(),
            _stepsTile(),
            _oxygenTile(),
          ],
        ),
        if (week != null) ...[const SizedBox(height: Sp.x3), week],
        const SizedBox(height: Sp.x3),
        SurfaceCard(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x4,
            vertical: Sp.x2,
          ),
          child: Column(
            children: [
              ListRow(
                icon: Ic.watch,
                title: 'Wear time',
                value: _hm(t.wearTime) ?? '—',
                divider: true,
                onTap: () => onOpen('wear'),
              ),
              ListRow(
                icon: Ic.recovery,
                osIcon: OsIcon.records,
                title: 'Records & streaks',
                onTap: () => onOpen('records'),
              ),
            ],
          ),
        ).dsEnter(index: 8),
      ],
    );
  }

  /// One compact chip while today's numbers are still settling — the long
  /// explanation lives behind the (i).
  Widget? _statusChip(TodayStatus? status) {
    if (status == null) return null;
    final building = status.overnightBuilding || status.activityBuilding;
    if (!building && !status.showingPriorOvernight) return null;
    final label = status.overnightBuilding
        ? 'Overnight settling'
        : status.activityBuilding
        ? 'Day metrics catching up'
        : 'Showing last settled night';
    final body = status.overnightBuilding
        ? 'Sleep and readiness update after the overnight settle finishes.'
        : status.activityBuilding
        ? 'Fresh data is in for today; strain and steps are still building.'
        : 'Today\'s overnight has not landed yet, so the last settled night '
              'is shown${status.overnightDay != null ? ' (${status.overnightDay})' : ''}.';
    return Row(
      children: [
        StatusChip(label, icon: Icons.hourglass_top_rounded,
            tone: building ? ChipTone.warn : ChipTone.neutral),
        InfoDot(title: label, body: body),
        const Spacer(),
      ],
    );
  }

  // ── the orbit hero ──────────────────────────────────────────────────────────

  Widget _orbitHero() {
    final r = t.readiness;
    final score = r.isEmpty ? null : r.value!.round();
    final fill = _baselineFill(r);
    final accent = score == null
        ? AppColors.accent
        : AppColors.scoreColor(score / 100);
    final word = score == null
        ? null
        : score >= 66
        ? 'Primed'
        : score >= 40
        ? 'Steady'
        : 'Run easy';

    // Honest "still learning you" center: nights-to-go over a dashed
    // progress ring; plain em-dash center when there is nothing at all.
    Widget? center;
    if (score == null && fill != null) {
      final left = fill.$2 - fill.$1;
      center = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$left', style: AppText.display.copyWith(fontSize: 40)),
          Text(
            left == 1 ? 'NIGHT' : 'NIGHTS',
            style: AppText.overline.copyWith(fontSize: 9),
          ),
          const SizedBox(height: 2),
          Text(
            'Learning you',
            style: AppText.caption.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      );
    }

    return OrbitScore(
      score: score,
      label: 'Readiness',
      word: word,
      color: accent,
      confidence: score == null ? 0.3 : r.confidence,
      ringFill: (score == null && fill != null) ? fill.$1 / fill.$2 : null,
      center: center,
      onTap: () => onOpen('readiness'),
      // Each satellite carries its metric's number so the hero reads at a glance.
      satellites: [
        OrbitSatellite(
          icon: Ic.moon,
          osIcon: OsIcon.sleep,
          label: 'Sleep',
          value: t.sleepDuration.isEmpty ? null : _hm(t.sleepDuration),
          color: DomainAccent.sleep,
          onTap: () => onOpen('sleep'),
        ),
        OrbitSatellite(
          icon: Ic.heart,
          osIcon: OsIcon.heart,
          label: 'Heart',
          value: _int(t.restingHr),
          color: DomainAccent.heart,
          onTap: () => onOpen('heart'),
        ),
        OrbitSatellite(
          icon: Ic.strain,
          osIcon: OsIcon.bodyStrain,
          label: 'Strain',
          value: t.strain.isEmpty ? null : t.strain.value!.toStringAsFixed(1),
          color: DomainAccent.strain,
          onTap: () => onOpen('body'),
        ),
        OrbitSatellite(
          icon: Ic.pulse,
          osIcon: OsIcon.stress,
          label: 'Stress',
          value: t.stress?.score?.toString(),
          color: DomainAccent.stress,
          onTap: () => onOpen('stress'),
        ),
      ],
    );
  }

  // ── bento tiles ─────────────────────────────────────────────────────────────

  /// Shared floor for the short "just a number" tiles (Strain / Calories /
  /// Stress / O₂) so the bento keeps a steady rhythm and no figure ever feels
  /// cropped into a squat box. Tiles that carry their own tall content (HRV
  /// spark, Sleep stages, Steps progress) set their height naturally.
  static const double _statTileMinHeight = 116;

  void _info(
    BuildContext context, {
    required String title,
    required String body,
    String? methodNote,
  }) => showInfoSheet(context, title: title, body: body, methodNote: methodNote);

  Widget _hrvTile(BuildContext context) {
    final hrv = t.hrv;
    return BentoTile(
      accent: DomainAccent.recovery,
      minHeight: _statTileMinHeight,
      onTap: () => onOpen('heart'),
      onLongPress: () => _info(
        context,
        title: 'HRV (RMSSD)',
        body:
            'Beat-to-beat variability from last night\'s RR intervals. Higher '
            'than your own baseline generally means better recovery.',
        methodNote:
            'Lipponen–Tarvainen-corrected RR · nightly RMSSD · PRV at 1 Hz beat timing',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TileHeader(
            'HRV',
            icon: Ic.pulse,
            osIcon: OsIcon.hrv,
            trailing: hrv == null ? null : ConfDot(hrv.confidence),
          ),
          const SizedBox(height: Sp.x2),
          BigStat(value: hrv?.rmssd.toStringAsFixed(0), unit: 'ms'),
          if (hrv?.baseline != null) ...[
            const SizedBox(height: Sp.x2),
            Align(
              alignment: Alignment.centerLeft,
              child: BaselineDeltaChip(
                hrv!.rmssd - hrv.baseline!,
                unit: 'ms',
                showVsNormal: false,
              ),
            ),
          ],
          if (_spark('hrv') != null) ...[
            const SizedBox(height: Sp.x3),
            Sparkline(
              _spark('hrv')!,
              color: DomainAccent.recovery,
              height: 30,
              area: true,
              endDot: false,
            ),
          ],
        ],
      ),
    );
  }

  Widget _rhrTile() {
    final delta = t.rhrDelta;
    return BentoTile(
      tone: BentoTone.ink,
      accent: DomainAccent.heart,
      minHeight: _statTileMinHeight,
      onTap: () => onOpen('heart'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader('Resting HR',
              icon: Ic.heart, osIcon: OsIcon.restingHeartRate),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: _int(t.restingHr),
            unit: 'bpm',
            caption: delta.isEmpty
                ? null
                : '${delta.value! > 0 ? '+' : ''}${delta.value!.round()} vs normal',
            captionAccent: true,
          ),
          if (_spark('resting_hr') != null) ...[
            const SizedBox(height: Sp.x3),
            Sparkline(
              _spark('resting_hr')!,
              color: const Color(0xFFFF8E6B),
              height: 30,
              endDot: false,
            ),
          ],
        ],
      ),
    );
  }

  Widget _sleepTile() {
    final sm = stageMin;
    final hasStages =
        sm != null &&
        ((sm.remMin ?? 0) + (sm.lightMin ?? 0) + (sm.deepMin ?? 0)) > 0;
    return BentoTile(
      tone: BentoTone.soft,
      accent: DomainAccent.sleep,
      minHeight: _statTileMinHeight,
      onTap: () => onOpen('sleep'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader('Sleep', icon: Ic.moon, osIcon: OsIcon.sleep),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: _hm(t.sleepDuration),
            caption: t.sleepNeed.isEmpty
                ? null
                : 'of ${_hm(t.sleepNeed)} need',
          ),
          if (hypno.isNotEmpty) ...[
            const SizedBox(height: Sp.x3),
            Hypnogram(hypno, height: 64, labels: false),
          ],
          if (hasStages) ...[
            const SizedBox(height: Sp.x3),
            StageBars(
              awakeMin: sm.awakeMin,
              remMin: sm.remMin,
              lightMin: sm.lightMin,
              deepMin: sm.deepMin,
              legend: !(hypno.isNotEmpty), // timeline already tells the story
            ),
          ] else if (!t.sleepDuration.isEmpty && !t.sleepNeed.isEmpty) ...[
            const SizedBox(height: Sp.x3),
            ProgressPill(
              (t.sleepDuration.value! / t.sleepNeed.value!).clamp(0.0, 1.0),
              color: DomainAccent.sleep,
              height: 8,
            ),
          ],
        ],
      ),
    );
  }

  Widget _strainTile() {
    final v = t.strain;
    return BentoTile(
      accent: DomainAccent.strain,
      minHeight: _statTileMinHeight,
      onTap: () => onOpen('body'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader('Strain',
              icon: Ic.strain, osIcon: OsIcon.bodyStrain),
          const SizedBox(height: Sp.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: BigStat(
                  value: v.isEmpty ? null : v.value!.toStringAsFixed(1),
                  caption: 'of 21',
                ),
              ),
              ArcGauge(
                value: v.isEmpty
                    ? double.nan
                    : (v.value! / 21).clamp(0.0, 1.0),
                color: DomainAccent.strain,
                size: 52,
                stroke: 6,
                sweepFraction: 0.75,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepsTile() {
    final base = t.steps.isEmpty ? 0 : t.steps.value!.round();
    final steps = base + liveSteps;
    final goal = t.stepGoal ?? 10000;
    return BentoTile(
      tone: BentoTone.soft,
      accent: DomainAccent.steps,
      minHeight: _statTileMinHeight,
      onTap: () => onOpen('activity'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader('Steps',
              icon: Ic.run, osIcon: OsIcon.steps, trailing: Tag('est')),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: steps > 0 ? '$steps' : null,
            caption: steps > 0 ? 'goal $goal' : null,
          ),
          if (steps > 0) ...[
            const SizedBox(height: Sp.x3),
            ProgressPill(
              (steps / goal).clamp(0.0, 1.0),
              color: DomainAccent.steps,
              height: 8,
            ),
          ],
        ],
      ),
    );
  }

  Widget _caloriesTile() {
    return BentoTile(
      tone: BentoTone.accent,
      accent: DomainAccent.calories,
      minHeight: _statTileMinHeight,
      onTap: () => onOpen('body'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader('Calories', icon: Ic.fire, osIcon: OsIcon.calories),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: _int(t.calories),
            unit: 'kcal',
            caption: t.calories.isEmpty ? null : 'active burn · est',
          ),
        ],
      ),
    );
  }

  Widget _stressTile() {
    final stress = t.stress;
    return BentoTile(
      accent: DomainAccent.stress,
      minHeight: _statTileMinHeight,
      onTap: () => onOpen('stress'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader('Stress',
              icon: Ic.pulse, osIcon: OsIcon.stress, trailing: Tag('est')),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: stress?.score?.toString(),
            unit: '/100',
            caption: stress?.band,
            captionAccent: true,
          ),
        ],
      ),
    );
  }

  Widget _oxygenTile() {
    final spo2 = t.spo2;
    return BentoTile(
      accent: DomainAccent.oxygen,
      minHeight: _statTileMinHeight,
      onTap: () => onOpen('oxygen'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TileHeader(
            'O₂ dips',
            icon: Ic.droplet,
            trailing: Tag('rel', color: AppColors.loadDetraining),
          ),
          const SizedBox(height: Sp.x2),
          BigStat(value: spo2?.odiPerHour?.toStringAsFixed(1), unit: '/h'),
        ],
      ),
    );
  }

  /// Week-of-rings consistency strip: this week's (Mon→Sun) daily steps vs
  /// the daily goal. Today's ring mirrors the steps tile (day metric + live),
  /// so it fills even before today's series row exists.
  Widget? _weekRings() {
    final base = t.steps.isEmpty ? 0 : t.steps.value!.round();
    final ring = stepWeekRingData(
      weekSteps: stepsWeek,
      goal: (t.stepGoal ?? 10000).toDouble(),
      todayWeekday: DateTime.now().weekday,
      todaySteps: base + liveSteps,
    );
    if (ring.values.whereType<double>().isEmpty) return null;
    return BentoTile(
      accent: DomainAccent.steps,
      onTap: () => onOpen('activity'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TileHeader('Steps goal (week)'),
          const SizedBox(height: Sp.x3),
          RingWeek(
            values: ring.values,
            todayIndex: ring.todayIndex,
            color: DomainAccent.steps,
          ),
        ],
      ),
    ).dsEnter(index: 7);
  }
}

/// Pure mapper for the Today week-of-rings: Mon→Sun raw step counts → exactly
/// seven goal-relative fills (0..1, null = no data / future day) plus today's
/// Monday-based index. [todaySteps] (the day metric + live session, i.e. the
/// same figure the steps tile shows) supersedes today's series entry when it
/// is larger, so the ring never lags the tile beside it.
@visibleForTesting
({List<double?> values, int todayIndex}) stepWeekRingData({
  required List<double?> weekSteps,
  required double goal,
  required int todayWeekday, // DateTime.weekday: Mon=1 … Sun=7
  int todaySteps = 0,
}) {
  final g = goal > 0 ? goal : 10000.0;
  final vals = List<double?>.filled(7, null);
  for (var i = 0; i < weekSteps.length && i < 7; i++) {
    final v = weekSteps[i];
    if (v != null) vals[i] = (v / g).clamp(0.0, 1.0).toDouble();
  }
  final todayIdx = (todayWeekday - 1).clamp(0, 6);
  if (todaySteps > 0) {
    final frac = (todaySteps / g).clamp(0.0, 1.0).toDouble();
    final cur = vals[todayIdx];
    vals[todayIdx] = (cur == null || frac > cur) ? frac : cur;
  }
  return (values: vals, todayIndex: todayIdx);
}

/// RecoveryStory — an Instagram-stories-style morning recap shown once per day
/// above the vitals: 2–4 auto-advancing panels with top progress bars,
/// tap left/right to navigate, tap the ✕ to dismiss. Always-dark by design
/// (an invariant hero moment, like the live screen).
class _RecoveryStory extends StatefulWidget {
  final int recoveredPct;
  final int? sleptMin;
  final int? needMin;
  final double? hrvRmssd;
  final double? hrvDelta;
  final String? planTitle;
  final String? planBody;
  final VoidCallback onDone;
  const _RecoveryStory({
    required this.recoveredPct,
    required this.sleptMin,
    required this.needMin,
    required this.hrvRmssd,
    required this.hrvDelta,
    required this.planTitle,
    required this.planBody,
    required this.onDone,
  });
  @override
  State<_RecoveryStory> createState() => _RecoveryStoryState();
}

class _RecoveryStoryState extends State<_RecoveryStory>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4600),
  );
  late final List<Widget Function()> _panels = _buildPanels();
  int _idx = 0;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _advance();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _advance() {
    if (_idx < _panels.length - 1) {
      setState(() => _idx++);
      _c.forward(from: 0);
    } else {
      widget.onDone();
    }
  }

  void _prev() {
    if (_idx > 0) {
      setState(() => _idx--);
      _c.forward(from: 0);
    }
  }

  List<Widget Function()> _buildPanels() {
    final panels = <Widget Function()>[];
    // 1. Recovered.
    panels.add(() => _panel(
          overline: 'RECOVERED',
          gauge: ArcGauge(
            value: (widget.recoveredPct / 100).clamp(0.0, 1.0),
            color: AppColors.glow1,
            size: 132,
            stroke: 12,
            endDot: true,
            center: Text('${widget.recoveredPct}',
                style: AppText.display.copyWith(color: Colors.white)),
          ),
          line: widget.recoveredPct >= 66
              ? 'You’re primed — a strong day to push.'
              : widget.recoveredPct >= 40
                  ? 'Moderately recovered — train to feel.'
                  : 'Run low today — favour easy movement.',
        ));
    // 2. Sleep.
    if (widget.sleptMin != null && widget.needMin != null) {
      final slept = widget.sleptMin!, need = widget.needMin!;
      String hm(int m) => '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
      panels.add(() => _panel(
            overline: 'SLEEP',
            gauge: ArcGauge(
              value: need == 0 ? 0 : (slept / need).clamp(0.0, 1.0),
              color: AppColors.loadDetraining,
              size: 132,
              stroke: 12,
              center: Text(hm(slept),
                  style: AppText.metricSm.copyWith(color: Colors.white)),
            ),
            line: 'of your ${hm(need)} need',
          ));
    }
    // 3. HRV.
    if (widget.hrvRmssd != null) {
      panels.add(() => _panel(
            overline: 'HRV (RMSSD)',
            gauge: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${widget.hrvRmssd!.round()}',
                    style: AppText.display.copyWith(color: Colors.white)),
                Text('ms',
                    style: AppText.caption.copyWith(color: Colors.white54)),
              ],
            ),
            trailing: widget.hrvDelta == null
                ? null
                : BaselineDeltaChip(widget.hrvDelta, unit: 'ms'),
            line: widget.hrvDelta == null
                ? 'Beat-to-beat variability last night'
                : 'vs your normal',
          ));
    }
    // 4. Today's plan.
    if (widget.planTitle != null) {
      panels.add(() => _panel(
            overline: 'TODAY’S PLAN',
            gauge: const AppIcon(Ic.ai, size: 56, color: Colors.white),
            line: widget.planTitle!,
            sub: widget.planBody,
          ));
    }
    return panels;
  }

  Widget _panel({
    required String overline,
    required Widget gauge,
    required String line,
    String? sub,
    Widget? trailing,
  }) {
    return Column(
      key: ValueKey(overline),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(overline, style: AppText.overline.copyWith(color: Colors.white54)),
        const SizedBox(height: Sp.x4),
        gauge,
        if (trailing != null) ...[
          const SizedBox(height: Sp.x3),
          trailing,
        ],
        const SizedBox(height: Sp.x4),
        Text(line,
            style: AppText.title.copyWith(color: Colors.white),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        if (sub != null) ...[
          const SizedBox(height: Sp.x2),
          Text(sub,
              style: AppText.bodySoft.copyWith(color: Colors.white60),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(R.card),
      child: Container(
        height: 300,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.coralDeep, AppColors.night],
          ),
        ),
        child: Stack(
          children: [
            // Tap zones: left third = back, right = forward.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (e) {
                  final w = context.size?.width ?? 0;
                  if (e.localPosition.dx < w / 3) {
                    _prev();
                  } else {
                    _advance();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x7, Sp.x6, Sp.x6),
                  child: AnimatedSwitcher(
                    duration: Motion.med,
                    child: _panels[_idx](),
                  ),
                ),
              ),
            ),
            // Top progress segments.
            Positioned(
              left: Sp.x4,
              right: Sp.x4,
              top: Sp.x3,
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => Row(
                  children: [
                    for (int i = 0; i < _panels.length; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(R.pill),
                          child: LinearProgressIndicator(
                            value: i < _idx
                                ? 1.0
                                : i == _idx
                                    ? _c.value
                                    : 0.0,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            valueColor:
                                const AlwaysStoppedAnimation(Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Close.
            Positioned(
              right: Sp.x2,
              top: Sp.x5,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                onPressed: widget.onDone,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
