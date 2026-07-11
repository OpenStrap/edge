// DesignGalleryScreen — the on-device design-system review: every token and
// component of lib/ui/design rendered live, with a light/dark toggle in the
// header so both themes can be audited in place.
//
// Reachable from Profile → Developer → Design gallery (debug affordance; it
// ships, but sits quietly at the bottom of Profile).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../gps/route_math.dart' as rmath;
import '../../theme/theme_controller.dart';
import '../../theme/theme_switcher.dart';
import '../activity/live_session_screen.dart'
    show GpsLiveMapView, WorkoutFinishScreen, WorkoutFinishSnapshot;
import 'design.dart';
import 'fake_route_fixture.dart';

class DesignGalleryScreen extends StatefulWidget {
  const DesignGalleryScreen({super.key});

  @override
  State<DesignGalleryScreen> createState() => _DesignGalleryScreenState();
}

class _DesignGalleryScreenState extends State<DesignGalleryScreen> {
  int _seg = 1;
  int _nav = 0;
  int _chip = 0;

  static const _spark = <double?>[
    62,
    58,
    61,
    55,
    57,
    52,
    null,
    54,
    51,
    49,
    53,
    50,
    48,
    51,
  ];

  void _toggleTheme(ThemeController ctrl) {
    final next = ctrl.isDark ? AppThemeChoice.light : AppThemeChoice.dark;
    final overlay = themeSwitchKey.currentState;
    if (overlay != null) {
      overlay.run(() => ctrl.setChoice(next));
    } else {
      ctrl.setChoice(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ThemeController?>();
    final dark = AppColors.isDark;

    return AppScaffold(
      title: 'Design system',
      subtitle: dark ? 'Ember on Char' : 'Ember on Paper',
      actions: [
        if (ctrl != null)
          RoundIconButton(
            dark ? OsIcon.calories : OsIcon.sleep,
            onTap: () => _toggleTheme(ctrl),
          ),
      ],
      children: [
        // ── Typography ────────────────────────────────────────────────
        const SectionHeader('Typography — Manrope'),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('48', style: AppText.hero),
              Text('7:42', style: AppText.display),
              Text('118 bpm', style: AppText.metric),
              Text('52 ms', style: AppText.metricSm),
              const SizedBox(height: Sp.x3),
              Text('Heading one', style: AppText.h1),
              Text('Heading two', style: AppText.h2),
              Text('Title', style: AppText.title),
              Text(
                'Body — the quick warm ember jumps over the char.',
                style: AppText.body,
              ),
              Text('Body soft — supporting copy.', style: AppText.bodySoft),
              Text('Label', style: AppText.label),
              Text('Caption', style: AppText.caption),
              Text('OVERLINE', style: AppText.overline),
              const SizedBox(height: Sp.x3),
              Text('Tabular: 111 111 vs 909 909', style: AppText.metricSm),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── Color tokens ──────────────────────────────────────────────
        const SectionHeader('Color tokens'),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  _swatch('background', AppColors.background),
                  _swatch('surface', AppColors.surface),
                  _swatch('surfaceElevated', AppColors.surfaceElevated),
                  _swatch('onSurface', AppColors.onSurface),
                  _swatch('onSurfaceMuted', AppColors.onSurfaceMuted),
                  _swatch('accent', AppColors.accent),
                  _swatch('accentSoft', AppColors.accentSoft),
                  _swatch('positive', AppColors.positive),
                  _swatch('warn', AppColors.warn),
                  _swatch('critical', AppColors.critical),
                ],
              ),
              const SizedBox(height: Sp.x4),
              Text('HR ZONES', style: AppText.overline),
              const SizedBox(height: Sp.x2),
              Row(
                children: [
                  for (var z = 0; z <= 5; z++)
                    Expanded(
                      child: Container(
                        height: 26,
                        margin: EdgeInsets.only(right: z == 5 ? 0 : 4),
                        decoration: BoxDecoration(
                          color: AppColors.zone(z),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            'Z$z',
                            style: AppText.caption.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── Elevation ─────────────────────────────────────────────────
        const SectionHeader('Elevation e0–e3'),
        Row(
          children: [
            for (var e = 0; e <= 3; e++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: e == 3 ? 0 : Sp.x3),
                  child: SurfaceCard(
                    level: e,
                    padding: const EdgeInsets.symmetric(vertical: Sp.x5),
                    child: Center(child: Text('e$e', style: AppText.metricSm)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: Sp.x6),

        // ── Domain accents ────────────────────────────────────────────
        const SectionHeader('Domain accents'),
        SurfaceCard(
          child: Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              _swatch('heart', DomainAccent.heart),
              _swatch('recovery', DomainAccent.recovery),
              _swatch('sleep', DomainAccent.sleep),
              _swatch('strain', DomainAccent.strain),
              _swatch('steps', DomainAccent.steps),
              _swatch('calories', DomainAccent.calories),
              _swatch('oxygen', DomainAccent.oxygen),
              _swatch('stress', DomainAccent.stress),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── OrbitScore hero ───────────────────────────────────────────
        const SectionHeader('OrbitScore'),
        OrbitScore(
          score: 82,
          label: 'Readiness',
          word: 'Primed',
          color: AppColors.scoreColor(0.82),
          onTap: () {},
          satellites: [
            OrbitSatellite(
              icon: OsIcon.sleep,
              label: 'Sleep',
              value: '7h 42m',
              color: DomainAccent.sleep,
              onTap: () {},
            ),
            OrbitSatellite(
              icon: OsIcon.heart,
              label: 'Heart',
              value: '48 ms',
              color: DomainAccent.heart,
              onTap: () {},
            ),
            OrbitSatellite(
              icon: OsIcon.bodyStrain,
              label: 'Strain',
              value: '12.4',
              color: DomainAccent.strain,
              onTap: () {},
            ),
            OrbitSatellite(
              icon: OsIcon.stress,
              label: 'Stress',
              value: '34',
              color: DomainAccent.stress,
              onTap: () {},
            ),
          ],
        ),
        const SizedBox(height: Sp.x6),

        // ── BentoTile tones + BigStat (masonry columns) ───────────────
        const SectionHeader('BentoTile tones · BigStat · BentoColumns'),
        BentoColumns(
          entrance: false,
          left: [
            BentoTile(
              accent: DomainAccent.recovery,
              onTap: () {},
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('HRV',
                      trailing: ConfDot(0.85)),
                  const SizedBox(height: Sp.x2),
                  const BigStat(value: '48', unit: 'ms'),
                  const SizedBox(height: Sp.x3),
                  Sparkline(
                    const [44.0, 46, 51, 47, 49, 45, 48],
                    color: DomainAccent.recovery,
                    height: 30,
                    area: true,
                    endDot: false,
                  ),
                ],
              ),
            ),
            BentoTile(
              tone: BentoTone.soft,
              accent: DomainAccent.sleep,
              onTap: () {},
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Sleep'),
                  const SizedBox(height: Sp.x2),
                  const BigStat(value: '7h 42m', caption: 'of 8h 00m need'),
                  const SizedBox(height: Sp.x3),
                  const StageBars(
                    awakeMin: 24,
                    remMin: 96,
                    lightMin: 258,
                    deepMin: 84,
                  ),
                ],
              ),
            ),
          ],
          right: [
            BentoTile(
              tone: BentoTone.ink,
              accent: DomainAccent.heart,
              onTap: () {},
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TileHeader('Resting HR'),
                  const SizedBox(height: Sp.x2),
                  const BigStat(
                    value: '52',
                    unit: 'bpm',
                    caption: '−2 vs normal',
                    captionAccent: true,
                  ),
                  const SizedBox(height: Sp.x3),
                  const Sparkline(
                    [54.0, 53, 55, 52, 51, 53, 52],
                    color: Color(0xFFFF8E6B),
                    height: 30,
                    endDot: false,
                  ),
                ],
              ),
            ),
            BentoTile(
              tone: BentoTone.accent,
              accent: DomainAccent.calories,
              onTap: () {},
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TileHeader('Calories'),
                  SizedBox(height: Sp.x2),
                  BigStat(value: '640', unit: 'kcal', caption: 'active burn'),
                ],
              ),
            ),
            BentoTile(
              accent: DomainAccent.oxygen,
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TileHeader('O₂ dips'),
                  SizedBox(height: Sp.x2),
                  BigStat.dash(), // honest em-dash
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x6),

        // ── Hypnogram ─────────────────────────────────────────────────
        const SectionHeader('Hypnogram'),
        SurfaceCard(
          child: Hypnogram(
            const [
              HypnoSeg(SleepStage.awake, 0.00, 0.04),
              HypnoSeg(SleepStage.light, 0.04, 0.18),
              HypnoSeg(SleepStage.deep, 0.18, 0.30),
              HypnoSeg(SleepStage.light, 0.30, 0.38),
              HypnoSeg(SleepStage.rem, 0.38, 0.50),
              HypnoSeg(SleepStage.light, 0.50, 0.62),
              HypnoSeg(SleepStage.deep, 0.62, 0.70),
              HypnoSeg(SleepStage.awake, 0.70, 0.73),
              HypnoSeg(SleepStage.light, 0.73, 0.84),
              HypnoSeg(SleepStage.rem, 0.84, 0.96),
              HypnoSeg(SleepStage.awake, 0.96, 1.00),
            ],
            startLabel: '11:24 pm',
            endLabel: '7:05 am',
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── RadialHeatmap ─────────────────────────────────────────────
        const SectionHeader('RadialHeatmap'),
        SurfaceCard(
          child: Column(
            children: [
              Text('STRAIN BY HOUR', style: AppText.overline),
              const SizedBox(height: Sp.x3),
              RadialHeatmap(
                values: const [
                  0.05, 0.02, 0.0, null, 0.0, 0.1, 0.35, 0.8,
                  0.95, 0.6, 0.3, 0.4, 0.5, 0.3, 0.2, 0.25,
                  0.45, 0.85, 0.7, 0.4, 0.2, 0.1, 0.05, 0.02,
                ],
                color: DomainAccent.strain,
                size: 190,
                labels: const ['12a', '6a', '12p', '6p'],
                startAngle: -1.5707963267948966,
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── RingWeek ──────────────────────────────────────────────────
        const SectionHeader('RingWeek'),
        SurfaceCard(
          child: RingWeek(
            values: const [0.9, 1.0, 0.55, null, 0.72, 0.3, 0.8],
            todayIndex: 6,
            color: DomainAccent.steps,
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── StateChips ────────────────────────────────────────────────
        const SectionHeader('StateChips'),
        StateChips(
          chips: const [
            StateChip('Energize', emoji: '⚡'),
            StateChip('Recover', emoji: '🛌'),
            StateChip('Focus', emoji: '🎯'),
            StateChip('Calm', emoji: '🫧'),
            StateChip('Push', emoji: '🔥'),
          ],
          selected: _chip,
          onSelect: (i) => setState(() => _chip = i),
        ),
        const SizedBox(height: Sp.x6),

        // ── RecapCard + MedalCard ─────────────────────────────────────
        const SectionHeader('RecapCard · MedalCard'),
        RecapCard(
          title: 'Weekly recap',
          highlight: 'You slept 40 min more than your usual this week.',
          value: '7h 12m',
          caption: 'daily average',
          bars: const [6.2, 7.5, 8.1, 6.9, 7.2, 8.4, 7.1],
          accent: DomainAccent.sleep,
          onTap: () {},
        ),
        const SizedBox(height: Sp.x3),
        MedalCard(
          medal: '5K',
          overline: 'Personal record',
          title: 'Fastest 5k — 24:31',
          subtitle: 'Tuesday morning run',
          onTap: () {},
        ),
        const SizedBox(height: Sp.x6),

        // ── AiHero ────────────────────────────────────────────────────
        const SectionHeader('AiHero'),
        AiHero(
          overline: 'Good morning',
          line: 'Solid recovery — a strong day to push your intervals.',
          hint: 'Ask about your day…',
          cta: 'Tap for the breakdown',
          onTap: () {},
          onAsk: () {},
        ),
        const SizedBox(height: Sp.x6),

        // ── MetricCard bento ──────────────────────────────────────────
        const SectionHeader('MetricCard · BentoGrid'),
        BentoGrid(
          items: [
            BentoItem.wide(
              MetricCard(
                hero: true,
                label: 'Readiness',
                value: '82',
                unit: '%',
                animateFrom: 82,
                accent: AppColors.positive,
                confidence: 0.9,
                delta: const BaselineDeltaChip(4, goodIsUp: true),
                spark: const [61.0, 70, 64, 72, 68, 75, 82],
                info: const MetricInfo(
                  title: 'Readiness',
                  body:
                      'One 0–100 score fusing overnight HRV, resting heart rate, '
                      'sleep debt and recent strain against your own baselines.',
                  bullets: [
                    'Above your baseline → primed for load',
                    'Persistently low → prioritise recovery',
                  ],
                  methodNote: 'Composite z-score vs your 30-day baselines',
                ),
                onTap: () {},
              ),
            ),
            BentoItem(
              MetricCard(
                label: 'Resting HR',
                value: '52',
                unit: 'bpm',
                animateFrom: 52,
                delta: const BaselineDeltaChip(
                  -2,
                  unit: 'bpm',
                  goodIsUp: false,
                  showVsNormal: false,
                ),
                spark: _spark,
                info: const MetricInfo(
                  title: 'Resting heart rate',
                  body: 'Your lowest stable overnight heart rate.',
                ),
                onTap: () {},
              ),
            ),
            BentoItem(
              MetricCard(
                label: 'HRV',
                value: '48',
                unit: 'ms',
                animateFrom: 48,
                confidence: 0.55,
                tag: const Tag('est'),
                gauge: const ArcGauge(
                  value: 0.62,
                  size: 56,
                  stroke: 7,
                  animate: false,
                ),
                onTap: () {},
              ),
            ),
            BentoItem(
              MetricCard(
                label: 'Sleep',
                value: '7:42',
                delta: const DeltaChip(6.5),
                onTap: () {},
              ),
            ),
            const BentoItem(
              MetricCard(
                label: 'Skin temp',
                value: null, // honest null → em-dash
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x6),

        // ── ArcGauge ──────────────────────────────────────────────────
        const SectionHeader('ArcGauge'),
        SurfaceCard(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  const ArcGauge(
                    value: 0.82,
                    size: 120,
                    stroke: 12,
                    valueText: '82',
                    label: 'ready',
                    endDot: true,
                  ),
                  ArcGauge(
                    value: 0.64,
                    size: 120,
                    stroke: 12,
                    sweepFraction: 0.75,
                    color: AppColors.warn,
                    valueText: '12.8',
                    label: 'strain',
                    target: 0.8,
                    endDot: true,
                  ),
                ],
              ),
              const SizedBox(height: Sp.x4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  const ArcGauge(
                    value: 0.45,
                    size: 88,
                    stroke: 9,
                    confidence: 0.3,
                    valueText: '45',
                    label: 'low conf',
                  ),
                  const ArcGauge(
                    value: 0.7,
                    size: 88,
                    stroke: 9,
                    zone: 4,
                    valueText: 'Z4',
                  ),
                  ArcGauge(
                    value: double.nan,
                    size: 88,
                    stroke: 9,
                    center: metricDash(22),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── Sparkline ─────────────────────────────────────────────────
        const SectionHeader('Sparkline'),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('LINE + GAP + END DOT', style: AppText.overline),
              const SizedBox(height: Sp.x2),
              const Sparkline(_spark, height: 44),
              const SizedBox(height: Sp.x4),
              Text('AREA + BASELINE', style: AppText.overline),
              const SizedBox(height: Sp.x2),
              const Sparkline(_spark, height: 44, area: true, baseline: 55),
              const SizedBox(height: Sp.x4),
              Text('ZONE GRADIENT', style: AppText.overline),
              const SizedBox(height: Sp.x2),
              Sparkline(
                const [88.0, 96, 112, 128, 141, 156, 149, 162, 158, 171],
                height: 44,
                gradient: [
                  AppColors.zone(1),
                  AppColors.zone(3),
                  AppColors.zone(5),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── Controls ──────────────────────────────────────────────────
        const SectionHeader('Controls'),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedControl(
                options: const ['Day', 'Week', 'Month', '6M'],
                index: _seg,
                expanded: true,
                onChanged: (i) => setState(() => _seg = i),
              ),
              const SizedBox(height: Sp.x4),
              const Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  StatusChip('Neutral'),
                  StatusChip('Synced', tone: ChipTone.positive),
                  StatusChip('In zone 3', tone: ChipTone.accent),
                  StatusChip('Low battery', tone: ChipTone.warn),
                  StatusChip('No signal', tone: ChipTone.critical),
                ],
              ),
              const SizedBox(height: Sp.x4),
              Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const PrBadge('PR · fastest 5k'),
                  const Tag('est'),
                  Tag('rel', color: AppColors.loadDetraining),
                  Tag('beta', color: AppColors.coral),
                  const ConfDot(0.9),
                  const ConfDot(0.5),
                  const ConfDot(0.2),
                  const DeltaChip(3.2),
                  const DeltaChip(-5.1, goodIsUp: false),
                ],
              ),
              const SizedBox(height: Sp.x4),
              const ProgressPill(0.7, label: 'Goal'),
              const SizedBox(height: Sp.x3),
              Row(
                children: [
                  const Expanded(child: ProgressPill(0.35, height: 8)),
                  const SizedBox(width: Sp.x3),
                  InfoDot(
                    title: 'The (i) affordance',
                    body:
                        'Every explanatory sentence in the app lives behind one '
                        'of these — the main view stays numbers-first.',
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── Rows ──────────────────────────────────────────────────────
        const SectionHeader('ListRow'),
        SurfaceCard(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x4,
            vertical: Sp.x2,
          ),
          child: Column(
            children: [
              ListRow(
                icon: OsIcon.wear,
                iconColor: AppColors.accent,
                title: 'WHOOP 4.0',
                subtitle: 'Connected · 74%',
                divider: true,
                onTap: () {},
              ),
              ListRow(
                icon: OsIcon.sleep,
                title: 'Sleep',
                value: '7 h 42 m',
                divider: true,
                onTap: () {},
              ),
              ListRow(
                icon: OsIcon.run,
                title: 'Morning run',
                subtitle: '5.2 km · 27:40',
                trailing: const StatusChip('Zone 4', tone: ChipTone.accent),
                onTap: () {},
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.x6),

        // ── States ────────────────────────────────────────────────────
        const SectionHeader('Skeleton · StateCard'),
        Skeleton.tileRow(rows: 1),
        const SizedBox(height: Sp.x3),
        StateCard(
          icon: OsIcon.bluetooth,
          title: 'Nothing yet',
          message: 'Wear your strap tonight and sync in the morning.',
          actionLabel: 'Sync now',
          onAction: () {},
        ),
        const SizedBox(height: Sp.x6),

        // ── Workout preview (GPS route) ──────────────────────────────
        // Full-screen previews of the GPS live-map layout + the finish
        // screen's route hero, fed with a deterministic FAKE route
        // (fake_route_fixture.dart) — for reviewing the map/BPM/zone
        // layout and the Strava-style hero-map redesign without a live
        // device, GPS fix, or BLE connection. Placed BEFORE FloatingNavPill
        // (not after) so FloatingNavPill stays the true last section —
        // design_system_test.dart's scroll-to-bottom regression asserts on
        // that.
        const SectionHeader('Workout preview (fake GPS route)'),
        const SizedBox(height: Sp.x2),
        Text(
          'Static fake run (~3.2 km, 20 min) — not a real recording. '
          'Reviews the live map + BPM/zone stat bar, and the finish '
          'screen’s route-hero layout. The Share button on the finish '
          'screen is the REAL share flow (opens the OS share sheet with '
          'this fake workout\'s card) — same as production, not a preview.',
          style: AppText.captionMuted,
        ),
        const SizedBox(height: Sp.x3),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _GpsLiveMapPreviewScreen(),
                  ),
                ),
                child: const Text('Live GPS map'),
              ),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WorkoutFinishScreen(
                      id: 'preview-run',
                      previewRoute: fakeRunRoute(),
                      previewMaxHr: 190,
                      snapshot: WorkoutFinishSnapshot(
                        type: 'run',
                        duration: const Duration(minutes: 20, seconds: 6),
                        peakHr: 166,
                        calories: 284,
                        strain: 11.6,
                        steps: 4312,
                      ),
                    ),
                  ),
                ),
                child: const Text('Finish screen'),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x6),

        // ── Nav pill ──────────────────────────────────────────────────
        // Mirrors the shipped shell: five even tabs, no center action.
        const SectionHeader('FloatingNavPill'),
        FloatingNavPill(
          items: const [
            NavPillItem(OsIcon.today, 'Today'),
            NavPillItem(OsIcon.sleep, 'Sleep'),
            NavPillItem(OsIcon.heart, 'Heart'),
            NavPillItem(OsIcon.bodyStrain, 'Body'),
            NavPillItem(OsIcon.workouts, 'Workouts'),
          ],
          index: _nav,
          onSelect: (i) => setState(() => _nav = i),
        ),
        const SizedBox(height: Sp.x8),
      ],
    );
  }

  Widget _swatch(String name, Color c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 36,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.divider),
          ),
        ),
        const SizedBox(height: 3),
        SizedBox(
          width: 64,
          child: Text(
            name,
            style: AppText.captionMuted.copyWith(fontSize: 9),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Static preview of the GPS live-map layout (map + unified distance/
/// duration/pace/BPM stat bar) — the same [GpsLiveMapView] the real live
/// session uses in map mode, fed with the deterministic fake route instead
/// of a live RouteTracker. No animation/growth — just the composed layout,
/// for reviewing spacing/z-order without a live device.
class _GpsLiveMapPreviewScreen extends StatelessWidget {
  const _GpsLiveMapPreviewScreen();

  static const _maxHr = 190;

  @override
  Widget build(BuildContext context) {
    final route = fakeRunRoute();
    final vertices = rmath.buildVertices(route.points, route.hr, _maxHr);
    final lastHr = route.hr.isEmpty ? 150 : route.hr.last.hr;
    return Scaffold(
      backgroundColor: AppColors.night,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GpsLiveMapView(
                vertices: vertices,
                current: vertices.isEmpty ? null : vertices.last.pos,
                distanceMeters: route.distanceMeters,
                currentSpeedMps: route.distanceMeters /
                    (route.movingSec == 0 ? 1 : route.movingSec),
                movingSeconds: route.movingSec,
                elapsed: Duration(seconds: route.movingSec),
                hr: lastHr,
                zoneIndex: rmath.zoneForHr(lastHr, _maxHr),
              ),
            ),
            Positioned(
              top: Sp.x2,
              left: Sp.x2,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
