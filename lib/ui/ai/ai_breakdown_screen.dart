// AiBreakdownScreen — the ONE screen behind both the morning briefing and the
// evening recap (parameterized by period). Deep-linked from the scheduled
// notifications and from the Today AiSummaryCard.
//
// Generates-or-shows-cached: a cached briefing for today renders instantly;
// otherwise it generates on open via the shared BYOK plumbing. Honest states:
// no key → an "add your key" wall routing to the coach settings; generating →
// skeleton; provider/offline error → retry card. The "Based on" grid shows the
// EXACT inputs snapshot the model saw — nothing more, nothing less.

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';

import '../../ai/briefing.dart';
import '../../ai/briefing_engine.dart';
import '../../coach/coach_config.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart';
import '../coach/coach_settings_screen.dart';
import '../design/design.dart';

class AiBreakdownScreen extends StatefulWidget {
  final BriefingPeriod period;

  /// Test seam — production builds the engine from the ambient providers.
  final BriefingEngine? engineOverride;

  const AiBreakdownScreen(
      {super.key, required this.period, this.engineOverride});

  @override
  State<AiBreakdownScreen> createState() => _AiBreakdownScreenState();
}

enum _Phase { noKey, busy, ready, error }

class _AiBreakdownScreenState extends State<AiBreakdownScreen> {
  _Phase _phase = _Phase.busy;
  Briefing? _brief;
  String _error = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  BriefingEngine? _engine() {
    final override = widget.engineOverride;
    if (override != null) return override;
    final cfg = context.read<CoachConfig>();
    final repo = context.read<AppState>().repo;
    if (repo == null) return null;
    return BriefingEngine(config: cfg, repo: repo);
  }

  void _load() {
    if (!mounted) return;
    final cached = BriefingStore.read(widget.period);
    if (cached != null) {
      setState(() {
        _brief = cached;
        _phase = _Phase.ready;
      });
      return;
    }
    _generate();
  }

  Future<void> _generate() async {
    final engine = _engine();
    if (engine == null || !engine.configured) {
      setState(() => _phase = _Phase.noKey);
      return;
    }
    setState(() => _phase = _Phase.busy);
    try {
      final b = await engine.generate(widget.period);
      if (!mounted) return;
      setState(() {
        _brief = b;
        _phase = _Phase.ready;
      });
      // Repaint Today's card (best-effort — absent in isolated widget tests).
      try {
        context.read<AppState>().briefingUpdated();
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e.toString().replaceFirst('CoachException: ', '');
      });
    }
  }

  bool get _morning => widget.period == BriefingPeriod.morning;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: widget.period.title,
      actions: [
        if (_phase == _Phase.ready)
          RoundIconButton(OsIcon.activity, onTap: _generate),
      ],
      children: switch (_phase) {
        _Phase.noKey => _noKey(),
        _Phase.busy => _busy(),
        _Phase.error => _err(),
        _Phase.ready => _content(_brief!),
      },
    );
  }

  // ── states ───────────────────────────────────────────────────────────────────

  List<Widget> _noKey() => [
        const SizedBox(height: Sp.x6),
        StateCard(
          icon: OsIcon.ai,
          title: 'Bring your own AI',
          message:
              'Add your AI key to enable daily briefings. Your health data '
              'stays on this phone — the only network call is to your own '
              'provider, with your own key.',
          actionLabel: 'Add your AI key',
          onAction: () async {
            await Navigator.of(context).push(themedRoute(
                (_) => const CoachSettingsScreen(),
                name: 'CoachSettingsScreen'));
            if (mounted) _load(); // re-check on return
          },
        ).dsEnter(),
      ];

  List<Widget> _busy() => [
        SurfaceCard(
          level: 2,
          accentGlow: true,
          glowAlignment: const Alignment(1.1, -1.1),
          child: Row(children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.onAccentSoft,
              ),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Text(
                _morning
                    ? 'Reading last night and writing your briefing…'
                    : 'Reading your day and writing the recap…',
                style: AppText.bodySoft,
              ),
            ),
          ]),
        ).dsEnter(),
        const SizedBox(height: Sp.x3),
        Skeleton.tileRow(rows: 2),
      ];

  List<Widget> _err() => [
        const SizedBox(height: Sp.x6),
        StateCard(
          icon: OsIcon.cancel,
          title: 'Couldn\'t reach your AI provider',
          message: _error.isEmpty
              ? 'Check your connection and try again — nothing is lost, your '
                  'data never left the phone.'
              : _error,
          actionLabel: 'Try again',
          onAction: _generate,
        ).dsEnter(),
      ];

  // ── content ──────────────────────────────────────────────────────────────────

  List<Widget> _content(Briefing b) {
    final metrics = _metricTiles(b.inputs);
    final at = DateTime.fromMillisecondsSinceEpoch(b.generatedAtMs);
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final md = b.breakdownMd.trim();
    // Hide the breakdown when it is empty or merely restates the one-liner —
    // older cached briefings stored the one-liner back as a lone bullet, so the
    // hero sentence rendered a second time (issue #107).
    final breakdownBody = md.replaceFirst(RegExp(r'^[-*]\s*'), '').trim();
    final showBreakdown = md.isNotEmpty && breakdownBody != b.oneLiner.trim();
    return [
      // Hero — the one-liner, numbers-first tone, glow like the Today slot.
      SurfaceCard(
        level: 2,
        accentGlow: true,
        glowAlignment: const Alignment(1.1, -1.1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The AppScaffold title already names the screen ("Morning
            // briefing"), so no overline label here — it just repeated the
            // title (issue #107). The icon chip stays as the visual anchor.
            Container(
              // Art carries its own padding: 2 + 28 ≈ the old 8 + 17 chip.
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(R.chip),
              ),
              child: const OsAppIcon(OsIcon.ai, size: 28),
            ),
            const SizedBox(height: Sp.x4),
            Text(b.oneLiner, style: AppText.h2),
          ],
        ),
      ).dsEnter(index: 0),

      // The short structured breakdown (markdown bullets). Hidden when the
      // model returned only a one-liner (no distinct breakdown) — otherwise it
      // echoes the hero sentence a second time (issue #107).
      if (showBreakdown) ...[
        const SizedBox(height: Sp.x3),
        SurfaceCard(
          child: GptMarkdown(md, style: AppText.body),
        ).dsEnter(index: 1),
      ],
      const SizedBox(height: Sp.x5),

      // Exactly what the model saw — the inputs snapshot as glanceable tiles.
      if (metrics.isNotEmpty) ...[
        const SectionHeader('Based on'),
        BentoGrid(items: [for (final m in metrics) BentoItem(m)]),
        const SizedBox(height: Sp.x4),
      ],

      Center(
        child: Text(
          'Generated $hh:$mm · on-device data · your own AI key',
          style: AppText.captionMuted,
        ),
      ).dsEnter(index: 4),
      const SizedBox(height: Sp.x6),
    ];
  }

  /// Map the inputs snapshot to MetricCards. Only keys that exist render —
  /// same honesty as the prompt itself.
  List<Widget> _metricTiles(Map<String, dynamic> inputs) {
    Widget? tile(String key, String label, OsIcon icon,
        { String? unit, String Function(num)? fmt}) {
      final v = inputs[key];
      if (v is! num) return null;
      return MetricCard(
        label: label,
        icon: icon,
        value: fmt != null ? fmt(v) : _trim(v),
        unit: unit,
      );
    }

    Widget? textTile(String key, String label, OsIcon icon,
        ) {
      final v = inputs[key];
      if (v is! String || v.isEmpty) return null;
      return MetricCard(label: label, icon: icon, value: v);
    }

    String hm(num min) {
      final m = min.round();
      return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
    }

    final tiles = <Widget?>[
      tile('readiness', 'Readiness', OsIcon.recovery),
      tile('hrv_rmssd', 'HRV', OsIcon.hrv, unit: 'ms'),
      tile('resting_hr', 'Resting HR', OsIcon.restingHeartRate, unit: 'bpm'),
      tile('sleep_min', 'Sleep', OsIcon.sleep, fmt: hm),
      tile('sleep_efficiency_pct', 'Efficiency', OsIcon.bedtime, unit: '%'),
      tile('deep_min', 'Deep', OsIcon.deepSleep, fmt: hm),
      tile('rem_min', 'REM', OsIcon.sleep, fmt: hm),
      tile('sleep_debt_min', 'Sleep debt', OsIcon.history, fmt: hm),
      textTile('bedtime', 'Bedtime', OsIcon.bedtime),
      textTile('wake_time', 'Wake', OsIcon.awake),
      tile('strain_0_21', 'Strain', OsIcon.bodyStrain),
      tile('steps', 'Steps', OsIcon.steps),
      tile('calories_total_kcal', 'Calories', OsIcon.calories, unit: 'kcal'),
      tile('stress_0_100', 'Stress', OsIcon.stress),
      tile('wear_min', 'Wear time', OsIcon.wear, fmt: hm),
    ];
    final out = tiles.whereType<Widget>().toList();

    final w = inputs['workouts'];
    if (w is List && w.isNotEmpty) {
      out.add(MetricCard(
        label: 'Workouts',
        value: '${w.length}',
      ));
    }
    return out;
  }

  static String _trim(num v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
}
