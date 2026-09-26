// WORKOUT — the interaction domain. Not "here are your numbers", but "what do
// you want to do, and what did you do".
//
// Three tabs. There is deliberately no Programs tab: a training programme is a
// data model this app does not have (UI_WIRING §2c), and a tab of four fake
// plans with fake progress bars is the exact thing the absence contract
// exists to stop.
//
// Everything numeric here comes from `AppState.repo`. Where the repo has
// nothing — and for training load it very often has nothing, because CTL/ATL
// need fourteen days — the card is a StatusCard that says which, why and what
// fixes it.

import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../gps/gps_source.dart';
import '../../gps/route_models.dart';
import '../../health/health_import_state.dart';
import '../../health/auto_workout_import.dart';
import '../../health/health_workout_import.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart';
import '../../state/app_state.dart';
import '../../state/units_controller.dart';
import '../activity/catalogue.dart';
import '../activity/day_strain.dart';
import '../activity/live.dart';
import '../activity/picker.dart';
import '../activity/poster.dart' show PosterStatRow;
import '../activity/setup.dart';
import '../activity/summary.dart';
import '../charts.dart';
import '../profile/profile.dart' show openProfile;
import '../grammar.dart';
import '../revision.dart';
import '../theme.dart';
import '../../data/day_label.dart' show calendarDaysBetween;
import 'log_workout.dart';
import 'start_card.dart';

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key});

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> with RevisionReload {
  int tab = 0;
  List<String> _tabs(AppLocalizations? loc) => [
        loc?.workoutTabForYou ?? 'For you',
        loc?.workoutTabActivities ?? 'Activities',
        loc?.workoutTabHistory ?? 'History',
      ];

  Future<_WorkoutData>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `_load ??=` alone meant the screen read the database exactly once, for
    // the life of the widget — so a session you had just finished was absent
    // from History, "This week", "Tracked" and the weekly load until the app
    // was restarted. `RevisionReload` re-reads when the data moves: the manual
    // finish, the gesture path, the Live Activity and an import alike.
    _load ??= _loadWorkoutData(context.read<AppState>());
  }

  @override
  void reload() =>
      setState(() => _load = _loadWorkoutData(context.read<AppState>()));

  @override
  Widget build(BuildContext c) {
    return FutureBuilder<_WorkoutData>(
      future: _load,
      builder: (c, snap) {
        final loc = AppLocalizations.of(c);
        final d = snap.data ?? const _WorkoutData.empty();
        // THE LIST DROPS ITS SIDE PADDING and hands it to each child instead,
        // so the hero card can be the one child that does not get it and runs
        // edge to edge. Two earlier attempts had the CARD escape its parent —
        // a negative margin (which Flutter asserts against) and an OverflowBox
        // (which takes an unbounded height inside a scroll view and blanked
        // this whole tab on device). Padding the siblings is ordinary layout
        // and cannot do either.
        return ListView(
          padding: const EdgeInsets.fromLTRB(0, S.x2, 0, S.x16),
          children: [
            for (final w in <Widget>[
              ScreenTitle(loc?.workoutScreenTitle ?? 'Workout'),
              SubTabs(_tabs(loc), tab, (i) => setState(() => tab = i),
                  color: C.domMove),
              const SizedBox(height: S.x5),
              ...switch (tab) {
                0 => _forYou(c, d),
                1 => _activities(c, d),
                _ => _history(c, d),
              },
            ])
              if (w is StartCard)
                w
              else
                Padding(
                    padding: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: w),
          ],
        );
      },
    );
  }

  void _openPicker(BuildContext c, _WorkoutData d) =>
      Navigator.of(c).push(MaterialPageRoute(
          builder: (_) => ActivityPicker(
              weightKg: d.weightKg, host: _host(d), recent: d.recent)));

  ActivityHost _host(_WorkoutData d) =>
      activityHost(context.read<AppState>(), history: d.setHistory);

  // ─────────────── FOR YOU ───────────────
  List<Widget> _forYou(BuildContext c, _WorkoutData d) {
    final p = P.of(c);
    final loc = AppLocalizations.of(c);
    return [
      StartCard(
        label: loc?.workoutStartSessionLabel ?? 'START A SESSION',
        count: allActivities.length,
        noun: loc?.workoutActivitiesNoun ?? 'activities',
        asset: 'mascot_workout.png',
        accent: C.purple,
        deep: C.indigo,
        onTap: () => _openPicker(c, d),
      ),
      const SizedBox(height: S.x3),
      Row(children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: S.x3),
          Expanded(
            child: _QuickTile(
              quickStart[i],
              () => Navigator.of(c).push(MaterialPageRoute(
                  builder: (_) => ActivitySetup(quickStart[i],
                      weightKg: d.weightKg, host: _host(d)))),
            ),
          ),
        ],
      ]),
      Section(
        loc?.workoutThisWeek ?? 'This week',
        Surface(
          child: Row(
            children: List.generate(7, (i) {
              final days = [
                loc?.workoutWeekdayLetterMon ?? 'M',
                loc?.workoutWeekdayLetterTue ?? 'T',
                loc?.workoutWeekdayLetterWed ?? 'W',
                loc?.workoutWeekdayLetterThu ?? 'T',
                loc?.workoutWeekdayLetterFri ?? 'F',
                loc?.workoutWeekdayLetterSat ?? 'S',
                loc?.workoutWeekdayLetterSun ?? 'S',
              ];
              final today = DateTime.now().weekday - 1;
              final done = d.weekDays.contains(i);
              return Expanded(
                child: Column(children: [
                  Text(days[i], style: F.over.copyWith(color: p.ink3)),
                  const SizedBox(height: S.x2),
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: done
                            ? p.wash(C.green, strength: 1.5)
                            : (i == today ? p.fill(C.purple) : p.card2)),
                    child: Icon(
                        done
                            ? LucideIcons.check
                            : (i == today ? LucideIcons.play : null),
                        size: 14,
                        color: done ? p.on(C.green) : p.inkOnFill),
                  ),
                ]),
              );
            }),
          ),
        ),
      ),
      Section(
        loc?.workoutTrainingLoad ?? 'Training load',
        Column(children: [
          _loadCard(c, p, d),
          // TS-12 — two facts and no verb, directly under the card that holds
          // one of them. Rendered only on the coincidence; there is no "all
          // clear" variant, because the quiet state is the absence of a card
          // and not a reassurance we can make.
          if (d.overreach != null) ...[
            const SizedBox(height: S.x3),
            _overreachCard(c, d.overreach!),
          ],
          // TS-08 — a SECOND axis, beside the cardiovascular one and never
          // inside it. Its own card because that is what "not fused" means:
          // one bar is heartbeats over time, the other is kilos off the floor,
          // and they do not add up to anything. Drawn only when the week has
          // any, so a runner never sees an empty kilo chart.
          if (d.tonnage7.any((v) => v != null)) ...[
            const SizedBox(height: S.x3),
            _tonnageCard(c, p, d),
          ],
        ]),
        // TS-02 — the door onto the day's own strain trace. `getDayStrain` and
        // `series.strain_curve` were both fully implemented and read by no
        // screen. A link, not a card: this tab is about the fortnight, and the
        // shape of one day belongs behind a tap.
        action: loc?.workoutTodaysStrainAction ?? "Today's strain",
        onAction: () => Navigator.of(c)
            .push(MaterialPageRoute(builder: (_) => const DayStrainDetail())),
      ),
    ];
  }

  /// Kilos moved per day over the same seven slots the TRIMP chart uses.
  ///
  /// INCOMPLETE BY DESIGN, and the footnote says so: `load_kg` is deliberately
  /// nullable so a bodyweight set is not a zero-kilo set, which means a week of
  /// pull-ups contributes nothing here and must not be read as an easy week.
  /// No records, no bests, no comparison with last week.
  Widget _tonnageCard(BuildContext c, P p, _WorkoutData d) {
    final loc = AppLocalizations.of(c);
    final end = d.trimpEnd ?? DateTime.now();
    final axis = AxisSpec.of([for (final v in d.tonnage7) ?v], floor: 0);
    return Surface(
      child: ChartFrame(
        title: loc?.workoutMechanicalLoadTitle ?? 'MECHANICAL LOAD',
        unit: loc?.workoutKgLiftedUnit ?? 'kg lifted',
        height: 88,
        yAxis: axis,
        xLabels: [
          for (var i = 6; i >= 0; i--)
            _weekdayLetter(c, end.subtract(Motion.tick * 86400 * i)),
        ],
        footnote: (loc?.workoutTonnageFootnoteIntro ??
                'Reps × load over the sets you logged with a weight. ') +
            (d.tonnagePartial
                ? (loc?.workoutTonnageFootnotePartial ??
                    'Sets logged without one are not in it, so '
                        'this is a floor rather than a total. ')
                : '') +
            (loc?.workoutTonnageFootnoteOutro ??
                'Exact for what you typed and worthless across exercises — '
                    'kept out of strain and recovery for that reason.'),
        series: d.tonnage7,
        child: CustomPaint(
          size: Size.infinite,
          painter: Bars(d.tonnage7, p.on(C.orange),
              axis: axis, t: animate(context, 1)),
        ),
      ),
    );
  }

  /// TS-12 — the conjunction, as the two measurements it is made of.
  ///
  /// EVERY WORD HERE IS LOAD-BEARING. It is a coincidence detector, not a
  /// diagnosis: functional overreaching is defined by a performance decrement
  /// measured over weeks under controlled load, which no wrist can see. So no
  /// "you are overtraining", no score, no rest-day instruction, and no verb at
  /// all — the second sentence names the other things that produce this exact
  /// pair rather than pretending we ruled them out.
  ///
  /// In-app only, by construction: nothing here schedules a notification, and
  /// the pipeline deliberately keeps `overreaching` out of the keys
  /// `_runNotifications` reads.
  Widget _overreachCard(BuildContext c, Overreach o) {
    final loc = AppLocalizations.of(c);
    final ratio = o.ratio.toStringAsFixed(1);
    return InsightCard(
      loc?.workoutOverreachHeadline(
              ratio, o.nightsElevated, o.nightsConsidered) ??
          'Your last 7 days of load are '
              '$ratio× your usual six weeks, and your resting '
              'heart rate was above your usual on ${o.nightsElevated} of '
              '${o.nightsConsidered} nights.',
      loc?.workoutOverreachBody ??
          'Two measurements that happen to point the same way. Illness, travel, '
              'altitude, alcohol and a run of poor sleep all produce this same '
              'pair, and nothing here can tell them apart.',
      icon: LucideIcons.activity,
      color: C.orange,
    );
  }

  Widget _loadCard(BuildContext c, P p, _WorkoutData d) {
    final loc = AppLocalizations.of(c);
    if (d.load == null) {
      return StatusCard(
        loc?.workoutNoLoadTitle ?? 'No training load yet',
        d.loadNote ??
            (loc?.workoutNoLoadBody ??
                'Fitness and fatigue are 42-day and 7-day averages. They need '
                    'about two weeks of sessions.'),
        icon: LucideIcons.trendingUp,
      );
    }
    final ld = d.load!;
    final notYet = loc?.workoutNotYet ?? 'Not yet';
    return Surface(
      child: Column(children: [
        Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(ld.ctl.round().toString(),
                  style: F.n34.copyWith(color: p.ink)),
              const SizedBox(width: S.x2),
              Text(loc?.workoutFitnessLabel ?? 'fitness',
                  style: F.cap.copyWith(color: p.ink3)),
              const Spacer(),
              if (ld.tsb != null)
                Pill(_form(c, ld.tsb!), ld.tsb! >= 0 ? C.green : C.orange),
            ]),
        if (d.trimp7.any((v) => v != null)) ...[
          const SizedBox(height: S.x4),
          Builder(builder: (_) {
            final end = d.trimpEnd ?? DateTime.now();
            final axis = AxisSpec.of([for (final v in d.trimp7) ?v], floor: 0);
            final days = d.trimp7.where((v) => v != null).length;
            return ChartFrame(
              title: loc?.workoutDailyLoadTitle ?? 'DAILY LOAD',
              unit: loc?.workoutTrimpUnit ?? 'TRIMP',
              height: 88,
              yAxis: axis,
              // Seven slots, seven real dates. A day with nothing keeps its
              // place and its letter, and draws as the gap it is.
              xLabels: [
                for (var i = 6; i >= 0; i--)
                  _weekdayLetter(c, end.subtract(Motion.tick * 86400 * i)),
              ],
              footnote: (loc?.workoutDailyLoadFootnoteIntro ??
                      'Banister training impulse — minutes weighted by '
                          'heart-rate reserve. ') +
                  (days == 7
                      ? (loc?.workoutDailyLoadAllDays ?? 'Last seven days.')
                      : (loc?.workoutDailyLoadPartialDays(days) ??
                          '$days of the last '
                              'seven days produced a figure.')),
              series: d.trimp7,
              child: CustomPaint(
                  size: Size.infinite,
                  // Today is the last slot, always — not "the newest value".
                  painter: Bars(d.trimp7, p.on(C.purple),
                      highlight: d.trimp7.last == null ? -1 : 6,
                      axis: axis,
                      t: animate(context, 1))),
            );
          }),
        ],
        const SizedBox(height: S.x4),
        // Absent is absent. `?? 0` used to render "Fatigue 0" — a rest week —
        // for a pipeline that had simply not produced the number.
        //
        // No 'Fitness' entry: it is `ld.ctl`, which the headline two rows up is
        // already printing at 34 pt under the word "fitness". One number, once.
        InlineMetrics([
          (loc?.workoutFatigueLabel ?? 'Fatigue',
              ld.atl?.round().toString() ?? notYet, C.orange),
          (
            loc?.workoutFormLabel ?? 'Form',
            ld.tsb == null
                ? notYet
                : '${ld.tsb! >= 0 ? '+' : '−'}${ld.tsb!.abs().round()}',
            C.purple
          ),
        ]),
      ]),
    );
  }

  /// Coggan's form bands, named rather than numbered.
  String _form(BuildContext c, double tsb) {
    final loc = AppLocalizations.of(c);
    return tsb > 5
        ? (loc?.workoutFormFresh ?? 'Fresh')
        : tsb >= -10
            ? (loc?.workoutFormSteady ?? 'Steady')
            : tsb >= -30
                ? (loc?.workoutFormBuilding ?? 'Building')
                : (loc?.workoutFormOverreaching ?? 'Overreaching');
  }

  // ─────────────── ACTIVITIES ───────────────
  List<Widget> _activities(BuildContext c, _WorkoutData d) {
    final p = P.of(c);
    final loc = AppLocalizations.of(c);
    return [
      Pressable(
        onTap: () => _openPicker(c, d),
        semanticLabel: loc?.workoutSearchActivitiesLabel ?? 'Search activities',
        child: Container(
          constraints: const BoxConstraints(minHeight: S.tap),
          padding: const EdgeInsets.symmetric(horizontal: S.x4),
          decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
          child: Row(children: [
            Icon(LucideIcons.search, size: 17, color: p.ink3),
            const SizedBox(width: S.x2),
            Text(
                loc?.workoutSearchActivitiesCount(allActivities.length) ??
                    'Search ${allActivities.length} activities',
                style: F.body.copyWith(color: p.ink3)),
          ]),
        ),
      ),
      const SizedBox(height: S.x5),
      Text(loc?.workoutQuickStartHeader ?? 'QUICK START',
          style: F.over.copyWith(color: p.ink3)),
      const SizedBox(height: S.x3),
      for (var row = 0; row < 2; row++) ...[
        if (row > 0) const SizedBox(height: S.x3),
        Row(children: [
          for (var i = row * 3; i < row * 3 + 3; i++) ...[
            if (i % 3 > 0) const SizedBox(width: S.x3),
            Expanded(
              child: _QuickTile(
                quickStart[i],
                () => Navigator.of(c).push(MaterialPageRoute(
                    builder: (_) => ActivitySetup(quickStart[i],
                        weightKg: d.weightKg, host: _host(d)))),
              ),
            ),
          ],
        ]),
      ],
      for (final g in activityLibrary)
        Section(
          g.name,
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Column(children: [
              for (var i = 0; i < g.items.length; i++) ...[
                ActivityRow(g.items[i],
                    weightKg: d.weightKg,
                    onTap: () => Navigator.of(c).push(MaterialPageRoute(
                        builder: (_) => ActivitySetup(g.items[i],
                            weightKg: d.weightKg, host: _host(d))))),
                if (i < g.items.length - 1) Divider(color: p.line, height: 1),
              ],
            ]),
          ),
        ),
      // Title and action, no body. Losing the prose is right; losing the door
      // to the profile is not — without a weight there is no calorie estimate
      // at all, and this is the only place that says so and offers the fix.
      if (d.weightKg == null)
        StatusCard(
          loc?.workoutCalorieNeedWeightTitle ??
              'Calorie estimates need your weight',
          '',
          fix: loc?.workoutAddWeightFix ?? 'Add weight in profile',
          onFix: () => openProfile(c),
          icon: LucideIcons.flame,
        ),
      if (d.weightKg != null) ...[
        const SizedBox(height: S.x5),
        StatusCard(
          loc?.workoutCalorieEstimatesTitle ?? 'Calorie figures are estimates',
          kCalorieWhy,
          icon: LucideIcons.flame,
        ),
      ],
    ];
  }

  // ─────────────── HISTORY ───────────────

  /// Open a screen that can write a session, then re-read. Every write path on
  /// this tab goes through here: `RevisionReload` covers the writers that bump
  /// `AppState.insightsRevision`, and this covers the ones that do not.
  Future<void> _push(BuildContext c, Widget w) async {
    await Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => w));
    if (mounted) reload();
  }

  /// The detector's unreviewed bouts, at the top of History where the sessions
  /// they might become are listed.
  ///
  /// This is the surface that was missing, not a second copy of one: for the
  /// whole time the notification was emitted on the `recovery` channel it was
  /// dropped by `classOf` and never fired, so these rows accumulated unseen.
  /// It fires now (reminders channel, NotifClass.prompt) and lands on the one
  /// bout it is about — but only for a bout detected in the last ~2 h, so
  /// everything drained later still has to be reviewable here.
  List<Widget> _suggestionCards(BuildContext c, _WorkoutData d) {
    if (d.suggestions.isEmpty) return const [];
    final loc = AppLocalizations.of(c);
    final n = d.suggestions.length;
    return [
      StatusCard(
        loc?.workoutSuggestionsTitle(n) ??
            (n == 1
                ? '$n effort we spotted but did not log'
                : '$n efforts we spotted but did not log'),
        loc?.workoutSuggestionsBody ??
            'The band saw sustained work and nothing was started for it. Nothing '
                'is logged until you say so.',
        fix: loc?.workoutReviewFix(n) ?? 'Review ${n == 1 ? 'it' : 'them'}',
        icon: LucideIcons.radar,
        onFix: () =>
            _push(c, WorkoutSuggestionScreen(preloaded: d.suggestions)),
      ),
      const SizedBox(height: S.x5),
    ];
  }

  /// Back-log a session the band never saw, or never saw the whole of.
  Widget _logPastCard(BuildContext c) {
    final loc = AppLocalizations.of(c);
    return StatusCard(
      loc?.workoutLogPastTitle ?? 'Did something the band missed?',
      loc?.workoutLogPastBody ??
          'Enter the times yourself and it is scored from the heart rate '
              'recorded across them, like any other session.',
      fix: loc?.workoutLogPastFix ?? 'Log a past workout',
      icon: LucideIcons.calendarPlus,
      onFix: () => _push(c, const LogWorkout()),
    );
  }

  List<Widget> _history(BuildContext c, _WorkoutData d) {
    final p = P.of(c);
    final loc = AppLocalizations.of(c);
    if (d.workouts.isEmpty) {
      return [
        ..._suggestionCards(c, d),
        StatusCard(
          loc?.workoutNoSessionsTitle ?? 'No sessions recorded yet',
          loc?.workoutNoSessionsBody ?? 'Sessions appear here once you start one.',
          fix: loc?.workoutStartWorkoutFix ?? 'Start a workout',
          onFix: () => _openPicker(c, d),
          icon: LucideIcons.dumbbell,
        ),
        const SizedBox(height: S.x5),
        _logPastCard(c),
      ];
    }
    final importedThisWeek = d.weekImported;
    return [
      ..._suggestionCards(c, d),
      Row(children: [
        Expanded(child: _sum(p, '${d.workoutsTracked ?? d.workouts.length}',
            loc?.workoutTrackedLabel ?? 'Tracked')),
        const SizedBox(width: S.x3),
        Expanded(child: _sum(p, '${d.weekCount}',
            loc?.workoutThisWeek ?? 'This week')),
        const SizedBox(width: S.x3),
        Expanded(
            child: _sum(
                p,
                d.weekLoad == null
                    ? (loc?.workoutNoneLabel ?? 'None')
                    : d.weekLoad!.round().toString(),
                loc?.workoutWeeklyLoadLabel ?? 'Weekly load')),
      ]),
      // The seam, said where the two numbers sit next to each other. "This
      // week" counts every session you did; "Weekly load" counts only the ones
      // this band watched — and without this line the gap between them reads
      // as a bug rather than as the limit it is.
      if (importedThisWeek > 0) ...[
        const SizedBox(height: S.x3),
        Text(
          loc?.workoutImportedThisWeekNote(importedThisWeek, storeName) ??
              '$importedThisWeek of this week’s sessions came from $storeName. '
                  'They count here, and they are left out of weekly load — an '
                  'imported workout arrives with no heart-rate trace, and a load '
                  'number without one would be invented.',
          style: F.cap.copyWith(color: p.ink3, height: 1.5),
        ),
      ],
      // The import card lives UP HERE, under the numbers it feeds — at the
      // bottom of a long list nobody reached it without scrolling past every
      // session it exists to fill.
      const SizedBox(height: S.x3),
      ..._importCard(c, d),
      ..._morningAfter(c, p, d),
      const SizedBox(height: S.x5),
      for (final w in d.workouts) ...[
        _HistoryRow(w,
            weightKg: d.weightKg,
            onDelete: w.id.isEmpty
                ? null
                : () => _confirmDeleteWorkout(c, w),
            // A retime is a re-score over the new window, so it is offered
            // only where there is something of ours to re-score: an imported
            // row's times belong to the app that recorded it, and this band
            // measured nothing across them.
            onRetime: w.importedFrom == null && w.id.isNotEmpty
                ? () => _push(
                      c,
                      LogWorkout(
                        sessionId: w.id,
                        start: w.start,
                        end: w.start.add(w.duration),
                        activity: w.activity,
                        title: loc?.workoutFixTimes ?? 'Fix the times',
                      ),
                    )
                : null),
        const SizedBox(height: S.x3),
      ],
      const SizedBox(height: S.x3),
      _logPastCard(c),
    ];
  }

  /// Delete one session — recorded or imported. For an IMPORTED session the
  /// health-store uuid goes onto a tombstone list first, or the next import
  /// (manual, or the hourly auto path) would bring the very row the user just
  /// removed straight back. A copy in Apple Health / Health Connect itself is
  /// out of our reach by design and the confirm says so.
  Future<void> _confirmDeleteWorkout(BuildContext c, _PastWorkout w) async {
    final loc = AppLocalizations.of(c);
    final ok = await confirmRemove(
      c,
      title: loc?.workoutConfirmDeleteTitle(w.activity.name.toLowerCase()) ??
          'Delete this ${w.activity.name.toLowerCase()}?',
      body: w.importedFrom == null
          ? (loc?.workoutDeleteBodyOwn(storeName) ??
              'It disappears from OpenStrap. A copy in $storeName, if there is '
                  'one, stays where it is.')
          : (loc?.workoutDeleteBodyImported(storeName) ??
              'It disappears from OpenStrap and will not be re-imported. '
                  'The original in $storeName stays.'),
    );
    if (!ok || !mounted) return;
    if (w.importedFrom != null && w.id.isNotEmpty) {
      await rememberDeletedUuid(w.id);
      await LocalDb.deleteImportedWorkout(w.id);
    } else {
      await LocalDb.deleteSession(w.id);
    }
    if (!mounted) return;
    setState(() => _load = _loadWorkoutData(context.read<AppState>()));
  }

  /// Bring in what another app recorded. On History because that is the list
  /// it joins — it used to live three taps deep under More settings, next to a
  /// database export, which is not where anybody looks for their Sunday run.
  List<Widget> _importCard(BuildContext c, _WorkoutData d) {
    final p = P.of(c);
    final loc = AppLocalizations.of(c);
    return [
      Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ONE ROW in the parent card — no nested box: tick = hourly sweep,
          // ↻ = fetch NOW (only meaningful while the tick is on). The
          // refresh tap is the only thing that ever prompts for access.
          Row(
            children: [
              Pressable(
                semanticLabel: _autoImport
                    ? (loc?.workoutAutoImportOnLabel ??
                        'Auto-import on. Tap to turn off.')
                    : (loc?.workoutAutoImportOffLabel ??
                        'Auto-import off. Tap to turn on.'),
                onTap: () => _setAutoImport(!_autoImport),
                child: Icon(
                  _autoImport ? LucideIcons.circleCheckBig : LucideIcons.circle,
                  size: 22,
                  color: _autoImport ? p.on(C.domMove) : p.ink3,
                ),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Text(
                    loc?.workoutImportFromStore(storeName) ??
                        'Import from $storeName',
                    style: F.body.copyWith(
                        color: p.ink, fontWeight: FontWeight.w600)),
              ),
              Pressable(
                semanticLabel: loc?.workoutFetchNowLabel ?? 'Fetch workouts now',
                onTap: (!_autoImport || _importing)
                    ? null
                    : () => unawaited(_importWorkouts()),
                child: Padding(
                  padding: const EdgeInsets.all(S.x2),
                  child: _importing || !_autoImport
                      ? Icon(LucideIcons.refreshCw, size: 18, color: p.ink3)
                      : Icon(LucideIcons.refreshCw,
                          size: 18, color: p.on(C.domMove)),
                ),
              ),
            ],
          ),
          if (_importNote != null) ...[
            const SizedBox(height: S.x3),
            Text(
              _importNote!,
              style: F.cap.copyWith(
                  color: _importFailed ? p.on(C.red) : p.ink2, height: 1.5),
            ),
          ],
        ]),
      ),
    ];
  }

  bool _importing = false;
  bool _autoImport = false;
  String? _importNote;
  bool _importFailed = false;

  @override
  void initState() {
    super.initState();
    () async {
      final on = await AutoWorkoutImport.isEnabled();
      if (!mounted) return;
      setState(() => _autoImport = on);
      if (on) unawaited(AutoWorkoutImport.maybeRun());
    }();
  }

  Future<void> _setAutoImport(bool v) async {
    setState(() => _autoImport = v);
    await AutoWorkoutImport.setEnabled(v);
    // Silent by design: the tick only arms the hourly sweep. The refresh
    // icon beside it is what asks for access.
    if (v) unawaited(AutoWorkoutImport.maybeRun());
  }

  /// Read the store, then reload the tab so the new rows are in the list the
  /// user is looking at.
  ///
  /// Re-reading the WHOLE window every time rather than only what is new: the
  /// table is keyed on the health store's own uuid and the write replaces, so
  /// a second pass over the same run updates that one row instead of stacking
  /// a copy. It also picks up a workout the source app edited or back-dated
  /// after the fact, which a "since last time" cursor would miss forever.
  Future<void> _importWorkouts({bool silent = false}) async {
    if (_importing) return;
    setState(() {
      _importing = true;
      // The auto path shares this body but must not speak over it: no note
      // clearing, and its outcomes are silent by design.
      if (!silent) _importNote = null;
    });
    final importer = HealthWorkoutImporter();
    try {
      // Asked HERE, on the tap, and for WORKOUT alone. Nothing at launch and
      // nothing in onboarding — a sheet asking for data the user has not asked
      // us to read is how the whole set gets denied in one go.
      if (!await importer.requestPermission()) {
        if (!mounted) return;
        final loc = AppLocalizations.of(context);
        setState(() {
          _importNote = loc?.workoutImportDenied(storeName) ??
              '$storeName did not grant workouts. Nothing was read.';
          _importFailed = true;
        });
        return;
      }
      final res = await importer.sync();
      if (res.workouts == 0) {
        if (!mounted) return;
        final loc = AppLocalizations.of(context);
        setState(() {
          _importNote = loc?.workoutImportEmpty(storeName) ??
              'Nothing came back. $storeName holds no workouts '
                  'inside the window it will share.';
          _importFailed = false;
        });
        return;
      }
      // Only now. A denied read on iOS comes back as an empty list rather than
      // as an error, so marking a zero-row read as done would put "Refresh" on
      // the button for someone who said no.
      await markImported(HealthImport.workouts);
      if (!mounted) return;
      final loc = AppLocalizations.of(context);
      final route = !res.routesSupported
          // Said with the result rather than near it: this is the moment the
          // user is looking for their map.
          ? (loc?.workoutImportNoRoutes(storeName) ??
              ' $storeName will not share routes, so none have coordinates.')
          : res.withRoutes == 0
              ? (loc?.workoutImportNoneWithRoute ??
                  ' None of them had a route recorded.')
              : (loc?.workoutImportSomeWithRoute(res.withRoutes) ??
                  ' ${res.withRoutes} came with a route.');
      if (!mounted) return;
      setState(() {
        _importNote = (loc?.workoutImportBroughtIn(res.workouts) ??
                '${res.workouts} workout'
                    '${res.workouts == 1 ? '' : 's'} brought in.') +
            route;
        _importFailed = false;
      });
    } catch (e) {
      if (!mounted) return;
      final loc = AppLocalizations.of(context);
      setState(() {
        _importNote = loc?.workoutImportFailed(e.toString()) ?? 'Failed: $e';
        _importFailed = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _load = _loadWorkoutData(context.read<AppState>());
        });
      }
    }
  }

  /// TS-11 — what each session type actually cost you the next morning.
  ///
  /// A description of this user's own history and nothing else. The sample size
  /// sits under every row because a median over fourteen mornings and a median
  /// over eleven are different claims, and because the confounding is total:
  /// hard sessions cluster with late nights, alcohol, stress and travel, and no
  /// row here separates the session from the evening around it.
  ///
  /// The refusals are upstream and absolute — a day with more than one session
  /// is dropped rather than split, a morning after a half-observed night is
  /// dropped, and a type under ten mornings is refused outright rather than
  /// shown with a small n. So this section simply does not exist for months,
  /// which is the honest state and not an empty card.
  List<Widget> _morningAfter(BuildContext c, P p, _WorkoutData d) {
    if (d.morningAfter.isEmpty) return const [];
    final loc = AppLocalizations.of(c);
    return [
      Section(
        loc?.workoutMorningAfterTitle ?? 'The morning after',
        Surface(
          child: Column(children: [
            for (final e in d.morningAfter) _morningRow(c, e),
            const SizedBox(height: S.x3),
            Text(
              loc?.workoutMorningAfterBody ??
                  'Your own history, not a rule about the activity — these '
                      'mornings also had whatever evening came with them. Nothing '
                      'here is a reason to skip a session.',
              style: F.cap.copyWith(color: p.ink3, height: 1.5),
            ),
          ]),
        ),
      ),
    ];
  }

  Widget _morningRow(BuildContext c, MorningEffect e) {
    final loc = AppLocalizations.of(c);
    final a = activityByName(e.type);
    final rhr = e.metric == 'rhr';
    // Inside the metric's own minimal detectable change is not a finding, and
    // printing the number anyway would dress noise as an effect.
    final sign = e.delta >= 0 ? '+' : '−';
    return MetricRow(
      a?.icon ?? LucideIcons.activity,
      a?.color ?? C.purple,
      loc?.workoutAfterActivity(a?.name ?? e.type) ??
          'After ${a?.name ?? e.type}',
      e.exceedsMdc
          ? '$sign${e.delta.abs().toStringAsFixed(1)}'
          : (loc?.workoutUnchangedLabel ?? 'Unchanged'),
      unit: e.exceedsMdc ? (rhr ? 'bpm' : 'ms') : '',
      sub: () {
        final metricLabel = rhr
            ? (loc?.workoutRestingHeartRateLabel ?? 'Resting heart rate')
            : (loc?.workoutHrvLabel ?? 'HRV');
        final morningCount = loc?.workoutMorningCount(e.n) ??
            '${e.n} morning${e.n == 1 ? '' : 's'}';
        final insideRangeSuffix = e.exceedsMdc
            ? ''
            : (loc?.workoutInsideRangeSuffix ??
                ' · inside your night-to-night range');
        return '$metricLabel · $morningCount$insideRangeSuffix';
      }(),
    );
  }

  Widget _sum(P p, String v, String l) => Surface(
        pad: const EdgeInsets.symmetric(vertical: S.x4),
        child: Column(children: [
          Text(v, style: F.n24.copyWith(color: p.ink), maxLines: 1),
          const SizedBox(height: S.x1),
          Text(l,
              style: F.over.copyWith(color: p.ink3),
              textAlign: TextAlign.center),
        ]),
      );
}

class _QuickTile extends StatelessWidget {
  final Activity a;
  final VoidCallback onTap;
  const _QuickTile(this.a, this.onTap);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Surface(
      pad: const EdgeInsets.symmetric(vertical: S.x4, horizontal: S.x2),
      onTap: onTap,
      semanticLabel: a.name,
      child: Column(children: [
        Container(
          width: 40,
          height: 40,
          decoration:
              BoxDecoration(color: p.wash(a.color), borderRadius: R.rMd),
          child: Icon(a.icon, size: 19, color: p.on(a.color)),
        ),
        const SizedBox(height: S.x2),
        Text(a.name,
            style: F.over.copyWith(color: p.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

/// One past session. Taps through to the same summary a live session lands
/// on, built from the stores rather than from the six columns in this row —
/// the heart-rate curve, the sets and the route are all read on open.
class _HistoryRow extends StatelessWidget {
  final _PastWorkout w;
  final double? weightKg;

  /// Widen or correct this session's window. Null for an imported row, and for
  /// a session with no id to retime.
  final VoidCallback? onRetime;

  /// Remove this session locally. Null hides the control (no id to delete).
  final VoidCallback? onDelete;

  const _HistoryRow(this.w,
      {this.weightKg, this.onRetime, this.onDelete});

  Future<void> _open(BuildContext c) async {
    final nav = Navigator.of(c);
    final r = await _detailOf(c.read<AppState>(), w);
    await nav.push(MaterialPageRoute(
        builder: (_) => ActivitySummary(r, weightKg: weightKg)));
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final loc = AppLocalizations.of(c);
    final a = w.activity;
    final stats = _stats(c);
    return Surface(
      // An imported row does not open. The summary screen behind this tap is
      // built to show a session THIS band measured — its rating control, its
      // heart-rate trace, its zone split — and it has nowhere to say whose
      // workout it is. A screen that presents an Apple Watch run exactly like
      // one of ours is the fabrication this whole table exists to avoid, so
      // the row stays a row until that screen can name its source.
      onTap: w.importedFrom == null ? () => _open(c) : null,
      child: Column(children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration:
                BoxDecoration(color: p.wash(a.color), borderRadius: R.rMd),
            child: Icon(a.icon, size: 19, color: p.on(a.color)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      // The store's own word for it when it is not ours: the
                      // catalogue knows the ~40 types this app can start, and
                      // "Workout" over a surf loses the one thing we were told.
                      child: Text(w.importedTitle ?? a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: F.body.copyWith(
                              color: p.ink, fontWeight: FontWeight.w600)),
                    ),
                    // The flag the setup screen promised, visible on the one
                    // list this session shows up in.
                    if (w.private) ...[
                      const SizedBox(width: S.x2),
                      Icon(LucideIcons.lock, size: 13, color: p.ink3),
                    ],
                  ]),
                  // "Apple Watch · Today, 07:12". The source is not decoration
                  // and it is not the word "imported": a band-measured session
                  // and an Apple Watch session are different measurements, and
                  // the name of the thing that took it is the difference.
                  Text(
                      w.importedFrom == null
                          ? w.when(loc)
                          : '${w.importedFrom} · ${w.when(loc)}',
                      style: F.over.copyWith(color: p.ink3)),
                ]),
          ),
          if (w.strain != null) ...[
            Text(w.strain!.toStringAsFixed(1),
                style: F.n17.copyWith(color: p.ink)),
            const SizedBox(width: S.x1),
            Padding(
              padding: const EdgeInsets.only(top: S.x1),
              // "strain", not "load". Training load is CTL/ATL over weeks;
              // this is one session's 0–21 strain, and the two were being
              // shown under the same word on the same screen.
              child: Text(loc?.workoutStrainLabel ?? 'strain',
                  style: F.over.copyWith(color: p.ink3)),
            ),
          ],
          if (onDelete != null) ...[
            const SizedBox(width: S.x2),
            Pressable(
              semanticLabel: loc?.workoutDeleteSessionLabel ?? 'Delete this session',
              onTap: onDelete,
              child: Padding(
                padding: const EdgeInsets.all(S.x1),
                child:
                    Icon(LucideIcons.trash2, size: 17, color: p.ink3),
              ),
            ),
          ],
        ]),
        if (w.zoneMinutes.length == 5) ...[
          const SizedBox(height: S.x4),
          ChartFrame(
            title: loc?.workoutTimeInZonesTitle ?? 'TIME IN ZONES',
            unit: loc?.workoutMinutesUnit ?? 'minutes',
            height: 8,
            legend: [
              for (var i = 0; i < 5; i++)
                ('Z${i + 1} · ${w.zoneMinutes[i].round()}m', ZoneBar.cols(p)[i]),
            ],
            child: CustomPaint(
                size: Size.infinite, painter: ZoneBar(w.zoneFractions, p)),
          ),
        ],
        const SizedBox(height: S.x4),
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0) Divider(color: p.line, height: S.x5),
          PosterStatRow(
            icon: statIcon(stats[i].$1),
            label: stats[i].$1,
            value: stats[i].$2,
            unit: stats[i].$3,
            accent: p.on(a.color),
          ),
        ],
        // The way to correct a window the detector clipped, or one a session
        // started late. Nested inside the card's own tap: the inner Pressable
        // wins, so the row still opens the summary everywhere else.
        if (onRetime != null) ...[
          Divider(color: p.line, height: S.x5),
          Pressable(
            onTap: onRetime,
            semanticLabel: loc?.workoutFixTimesOnSessionLabel ??
                'Fix the times on this session',
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(LucideIcons.clock, size: 14, color: p.on(C.blue)),
              const SizedBox(width: S.x2),
              Text(loc?.workoutFixTimes ?? 'Fix the times',
                  style: F.cap.copyWith(
                      color: p.on(C.blue), fontWeight: FontWeight.w600)),
            ]),
          ),
        ],
      ]),
    );
  }

  /// `(name, value, unit)`. Absence is a WORD here rather than a dropped row,
  /// which is the one place this differs from the summary's own stat block:
  /// this is a LIST of sessions read against each other, and a card that
  /// quietly loses its calorie line reads as a lighter session rather than an
  /// uncosted one. The unit is null in that case — 'Not costed kcal' is not a
  /// sentence.
  List<(String, String, String?)> _stats(BuildContext c) {
    final loc = AppLocalizations.of(c);
    final units = c.watch<UnitsController>();
    final timeLabel = loc?.workoutTimeStatLabel ?? 'Time';
    final caloriesLabel = loc?.workoutCaloriesStatLabel ?? 'Calories';
    return w.importedFrom != null
      ? [
          // An imported row prints only what the recording app actually
          // recorded, and drops the rest rather than saying "No reading": this
          // band was not on the wrist, so there is no reading it could have
          // taken and nothing was lost. The calories are the SOURCE's figure,
          // shown under the source's name a line above — never added to ours,
          // because two devices' calorie models summed is a number neither of
          // them would stand behind.
          (timeLabel, hms(w.duration), null),
          if (w.distanceM != null && w.distanceM! > 0)
            (loc?.workoutDistanceStatLabel ?? 'Distance',
                units.distanceValue(w.distanceM!).toStringAsFixed(2),
                units.distanceUnit),
          if (w.calories != null)
            (caloriesLabel, grouped(w.calories!), 'kcal'),
        ]
      : [
          (timeLabel, hms(w.duration), null),
          if (w.calories == null)
            (caloriesLabel, loc?.workoutNotCostedValue ?? 'Not costed', null)
          else
            (caloriesLabel, grouped(w.calories!), 'kcal'),
          if (w.maxHr == null)
            (loc?.workoutMaxHrStatLabel ?? 'Max HR',
                loc?.workoutNoReadingValue ?? 'No reading', null)
          else
            (loc?.workoutMaxHrStatLabel ?? 'Max HR', '${w.maxHr}', 'bpm'),
        ];
  }
}

/// One day's initial. Taken from the date the point carries — deriving it from
/// the point's position in the list is how a chart comes to name days its data
/// did not come from.
String _weekdayLetter(BuildContext c, DateTime d) {
  final loc = AppLocalizations.of(c);
  final letters = [
    loc?.workoutWeekdayLetterMon ?? 'M',
    loc?.workoutWeekdayLetterTue ?? 'T',
    loc?.workoutWeekdayLetterWed ?? 'W',
    loc?.workoutWeekdayLetterThu ?? 'T',
    loc?.workoutWeekdayLetterFri ?? 'F',
    loc?.workoutWeekdayLetterSat ?? 'S',
    loc?.workoutWeekdayLetterSun ?? 'S',
  ];
  return letters[d.weekday - 1];
}

/// Which of the seven slots [at] falls in — 6 being [end]'s own day — or null
/// when it is outside the window.
///
/// UTC midnights for the same reason [lastSevenDays] uses them: the day after a
/// spring-forward is 23 h long, and `inDays` floors that into the neighbouring
/// slot.
int? _daySlot(DateTime at, DateTime end) {
  final slot = 6 -
      DateTime.utc(end.year, end.month, end.day)
          .difference(DateTime.utc(at.year, at.month, at.day))
          .inDays;
  return slot < 0 || slot > 6 ? null : slot;
}

/// `getChart` points → one slot per calendar day for the seven ending [end],
/// index 6 being [end] itself. A day with no point is null, which the painter
/// draws as a hole.
///
/// The alternative — "the last seven stored points" — is what made the axis
/// lie: `metric_series` only gains a row on a day that derives, so a sync gap
/// slid the whole week left and stamped today's letter on a week-old bar.
List<double?> lastSevenDays(Object? points, DateTime end) {
  final out = List<double?>.filled(7, null);
  if (points is! List) return out;
  for (final e in points) {
    if (e is! Map || e['v'] is! num || e['t'] is! num) continue;
    // `t` is noon local on the day the value belongs to.
    final at =
        DateTime.fromMillisecondsSinceEpoch((e['t'] as num).toInt() * 1000);
    // CALENDAR days, not elapsed hours: the day after a spring-forward is 23 h
    // long, `inDays` floored that to 0, and Sunday landed in Monday's slot
    // where Monday overwrote it. UTC midnights have no DST to floor.
    final slot = 6 -
        DateTime.utc(end.year, end.month, end.day)
            .difference(DateTime.utc(at.year, at.month, at.day))
            .inDays;
    if (slot < 0 || slot > 6) continue;
    out[slot] = (e['v'] as num).toDouble();
  }
  return out;
}

// ── the app seam ───────────────────────────────────────────────────────────
// Top-level, not methods: the live-session bar in `app.dart` reopens a
// minimised workout from outside this screen, and it needs the same session
// lifecycle rather than a second copy of it.

/// Everything the activity screens need from the app.
///
/// [history] is the user's own previous/best per lift. Absent is honest — the
/// live screen says "First time on this lift" — so the resume path passes what
/// it has rather than blocking on a query.
ActivityHost activityHost(AppState app,
    {Map<String, SetHistory> history = const {}}) {
  // The id of the session this host opened, remembered across calls.
  //
  // `stopWorkout` clears `activeWorkout`, so a RETRY after a failed write —
  // the strength log throwing, say, which leaves the sessions row saved and
  // the sets lost — used to read a null id, return the draft untouched, throw
  // nothing, and be reported to the user as saved.
  String? sessionId;
  return ActivityHost(
    feed: () => _feedOf(app),
    onStart: (a) => _startSession(app, a),
    onFinish: (draft) {
      sessionId ??= app.activeWorkout?.workoutId;
      return _finishSession(app, draft, sessionId);
    },
    onSets: (sets) => _bankSets(app, sets),
    history: history,
    bandConnected: app.isConnected,
  );
}

/// The band, as the live screens see it. Read on every tick rather than
/// subscribed to: there is no stream on `AppState` — `AppState.liveHr` is a
/// getter over the field the engine writes and the UI pulls.
///
/// Six of these ten fields used to be left unset, which is why the zone
/// pill, the zone bar, the live distance and the session average heart rate
/// were all inert. They all have producers; none of them needed new science.
LiveFeed _feedOf(AppState app) {
  final w = app.activeWorkout;
  return LiveFeed(
    // The freshness-checked getter, not `device.liveHr`: the raw field keeps
    // its last value forever after an unintentional drop, which suppressed
    // LiveHeart's "The band is not connected" card exactly when it was true.
    hr: app.liveHr,
    maxHr: (w?.maxHrSeen ?? 0) > 0 ? w!.maxHrSeen : null,
    zone: app.liveZone,
    calories: w?.caloriesOrNull,
    strain: w?.strain,
    steps: app.workoutStepsMeasured,
    zoneMinutes: w?.zoneMinutes() ?? const [],
    // The SET those minutes were binned with, not a second resolution of the
    // anchors: `zoneSet` is pinned at session start precisely so a mid-session
    // anchor change cannot rebrand a split already on screen.
    zoneSource: w?.zoneSet?.source,
    zoneMaxHr: w?.zoneSet?.maxHr,
    // DENSE, not the hole-free variant: this feeds the summary's chart, whose
    // x axis is the session clock. `perMinuteHr()` is for statistics.
    hrCurve: _curveOverSession(w),
    distanceKm: app.liveDistanceKm,
    gpsActive: app.routeTracking,
    bandConnected: app.isConnected,
    // Both were implemented at the state layer and read by nothing, so a
    // location denial showed as an absent map and no sentence at all.
    routeIssue: app.routeLocationIssue,
    onFixRoute: () {
      final issue = app.routeLocationIssue;
      if (issue == null) return;
      // A plain denial can be asked again; the rest can only be fixed in
      // Settings, and re-asking there would do nothing.
      if (issue == GpsPermissionStatus.denied) {
        app.retryRouteTracking();
      } else {
        GpsSource.openSettingsFor(issue);
      }
    },
  );
}

/// The per-minute curve, padded out to the session's OWN length.
///
/// `perMinuteHrDense` can only pad up to a minute that has a sample in it, and
/// the 1 Hz tick skips `accrueHr` entirely while the band is silent — so a
/// band that dropped at minute 30 of a 45-minute run hands back 30 slots. The
/// summary labels that chart's x axis `Start … 45:00` and spreads whatever it
/// is given across the whole width, so the reading taken at minute 15 was
/// painted under 22:30 and the fifteen-minute dropout was invisible. The tail
/// has to be there as nulls, which is what the painter breaks its line on.
List<double?> _curveOverSession(LiveWorkoutState? w) {
  if (w == null) return const [];
  final out = w.perMinuteHrDense();
  if (out.isEmpty) return out;
  final minutes = w.elapsed.inMinutes + 1;
  // Same sanity bound `_denseMinutes` uses: a clock that is not what we think
  // it is must not allocate a nonsense array.
  if (minutes <= out.length || minutes > 24 * 60) return out;
  return [...out, ...List<double?>.filled(minutes - out.length, null)];
}

/// Open a real session. Until this existed the live screens ran their own
/// clock over an app that had recorded nothing: no `sessions` row, no zone
/// tally, no calorie scoring, no GPS.
Future<bool> _startSession(AppState app, Activity a) async {
  if (app.activeWorkout != null) return false;
  app.startWorkout(type: a.typeKey);
  return app.activeWorkout != null;
}

/// `strength_set` rows for one log. `set_index` counts per exercise; `seq` is
/// the position in the whole session and is [LocalDb.saveStrengthSets]'s own
/// key, which is why re-sending the same log is idempotent.
List<Map<String, Object?>> _setRows(List<LoggedSet> sets) {
  final perExercise = <String, int>{};
  return [
    for (final s in sets)
      {
        'exercise_key': s.exerciseKey,
        'set_index':
            perExercise[s.exerciseKey] = (perExercise[s.exerciseKey] ?? 0) + 1,
        'reps': s.reps,
        'load_kg': s.loadKg,
        'rpe': s.rpe,
        'rest_sec': s.restSec,
        'at_ts': s.at.millisecondsSinceEpoch ~/ 1000,
      },
  ];
}

/// Bank the sets logged so far against the OPEN session. Called on every set,
/// because a typed set is the one thing in a session no sensor can reproduce
/// and it used to live in widget state until the user pressed stop.
Future<void> _bankSets(AppState app, List<LoggedSet> sets) async {
  final id = app.activeWorkout?.workoutId;
  if (id == null || sets.isEmpty) return;
  try {
    await LocalDb.saveStrengthSets(id, _setRows(sets));
  } catch (_) {
    // The draft still holds them, and finish writes the whole log again.
  }
}

/// Close it: finalize the session, persist the sets the user typed and the
/// privacy flag against its id, then hand back the result with the recorded
/// route folded in.
///
/// [id] is passed rather than read here so a retry still has one — see
/// [activityHost].
Future<ActivityResult> _finishSession(
    AppState app, ActivityResult draft, String? id) async {
  // Idempotent: on a retry the session is already stopped and this is a no-op.
  await app.stopWorkout();
  if (id == null) return draft;
  // The row exists from here on, so the summary can carry its id — which is
  // what TS-09's rating is written against. A draft that never reached the
  // database keeps a null id and is never offered the prompt.
  draft = draft.copyWith(sessionId: id);

  // The privacy toggle, finally landing somewhere. `putSession` is
  // INSERT-OR-REPLACE over the whole row and does not carry the flag, so this
  // is its own narrow UPDATE and it has to run AFTER stopWorkout, not before.
  if (draft.private) {
    await app.repo?.setWorkoutPrivate(id, true);
  }

  // Written on every set already; written again here because the last one
  // may have landed while the app was being torn down.
  if (draft.strength.sets.isNotEmpty) {
    await LocalDb.saveStrengthSets(id, _setRows(draft.strength.sets));
  }

  // The GPS tail is flushed by stopWorkout before it returns, so the route
  // read here is the whole route.
  try {
    final route = await app.repo?.getWorkoutRoute(id);
    if (route != null && route.hasPath) return _withRoute(draft, route);
  } catch (_) {
    // A missing map is a missing map; the session itself is already banked.
  }
  return draft;
}

/// Previous and best per lift, from this user's own log. The store returns two
/// candidate sets over exercises actually used; catalogue size does not turn
/// into one SQL query per definition.
Future<Map<String, SetHistory>> loadSetHistory() async {
  final history = <String, SetHistory>{};
  try {
    final candidates = await LocalDb.strengthHistoryCandidates();
    final previous = <String, LoggedSet>{};
    final best = <String, LoggedSet>{};
    for (final row in candidates.previous) {
      final key = row['exercise_key'] as String?;
      if (key == null || previous.containsKey(key)) continue;
      previous[key] = _logFrom([row]).sets.single;
    }
    for (final row in candidates.best) {
      final key = row['exercise_key'] as String?;
      if (key == null || best.containsKey(key)) continue;
      best[key] = _logFrom([row]).sets.single;
    }
    for (final key in {...previous.keys, ...best.keys}) {
      history[key] = SetHistory(previous: previous[key], best: best[key]);
    }
  } catch (_) {
    // No history is the normal state on day one.
  }
  return history;
}

// ── the route seam ─────────────────────────────────────────────────────────

/// Fold a recorded route into a session: the line, the distance, the climb
/// and the per-kilometre splits. All of this already sat in `workout_route`
/// and `getWorkoutRoute`; none of it had ever reached the summary screen.
ActivityResult _withRoute(ActivityResult r, WorkoutRoute route) {
  final pts = route.points;
  final alt = [for (final p in pts) p.alt];
  final haveAlt = alt.every((a) => a != null) && alt.length > 1;
  double? gain, loss;
  if (haveAlt) {
    var up = 0.0, down = 0.0;
    for (var i = 1; i < alt.length; i++) {
      final d = alt[i]! - alt[i - 1]!;
      // A one-metre deadband: GPS altitude jitters by about that standing
      // still, and summing the jitter over an hour invents a mountain.
      if (d > 1) {
        up += d;
      } else if (d < -1) {
        down -= d;
      }
    }
    gain = up;
    loss = down;
  }
  final speeds = [for (final p in pts) p.speed];
  final haveSpeed = speeds.every((s) => s != null && s >= 0);
  return r.copyWith(
    route: _normalise(pts),
    geo: [for (final p in pts) (p.lat, p.lng)],
    routePace: haveSpeed ? _spread([for (final s in speeds) s!]) : null,
    distanceKm: route.distanceMeters / 1000,
    elevationM: haveAlt ? [for (final a in alt) a!] : const [],
    gainM: gain,
    lossM: loss,
    splits: [
      for (final s in route.splitsKm)
        KmSplit(s.meters / 1000, s.durationSec, avgHr: s.avgHr?.round()),
    ],
  );
}

/// Latitude/longitude → the 0…1 box `RouteMap` draws in, origin top-left.
/// One shared span for both axes so the shape is the shape you ran, and a
/// cosine on longitude because a degree of it is not a degree of latitude.
List<Offset> _normalise(List<RoutePoint> pts) {
  if (pts.length < 2) return const [];
  var loLat = pts.first.lat, hiLat = loLat;
  var loLng = pts.first.lng, hiLng = loLng;
  for (final p in pts) {
    loLat = math.min(loLat, p.lat);
    hiLat = math.max(hiLat, p.lat);
    loLng = math.min(loLng, p.lng);
    hiLng = math.max(hiLng, p.lng);
  }
  final k = math.cos((loLat + hiLat) / 2 * math.pi / 180).abs().clamp(.01, 1.0);
  final w = (hiLng - loLng) * k, h = hiLat - loLat;
  final span = math.max(w, h);
  if (span <= 0) return const [];
  final dx = (1 - w / span) / 2, dy = (1 - h / span) / 2;
  return [
    for (final p in pts)
      Offset(dx + (p.lng - loLng) * k / span, dy + (hiLat - p.lat) / span),
  ];
}

/// Spread a series across 0…1 for a colour ramp. A flat series lands in the
/// middle rather than at an extreme it never reached.
List<double> _spread(List<double> v) {
  final lo = v.reduce(math.min), hi = v.reduce(math.max);
  if (hi - lo < 1e-9) return [for (var i = 0; i < v.length; i++) .5];
  return [for (final x in v) (x - lo) / (hi - lo)];
}

/// The stored `[{t, v}]` heart-rate curve as one slot per MINUTE of the
/// session, `null` where nothing was recorded.
///
/// The store emits a point only for minutes that had samples, so dropping `t`
/// and keeping the values closed every dropout up: a band that lost the link
/// for ten minutes drew a trace that ran straight across them, under an axis
/// labelled `Start … 47:20`. The x position of a sample is its index, so the
/// index has to be the minute.
/// [session] pads the TAIL out to the session's own length, for the same
/// reason [_curveOverSession] does on the live path: the store's last point is
/// the last minute that had samples, so a band that dropped at minute 30 of a
/// 45-minute session ends the line there and the chart stretches it across an
/// axis that says 45:00.
List<double?> _denseMinutes(Object? hr, [Duration? session]) {
  final pts = <(int, double)>[
    for (final e in (hr as List? ?? const []))
      if (e is Map && e['t'] is num && e['v'] is num)
        ((e['t'] as num).toInt(), (e['v'] as num).toDouble()),
  ];
  if (pts.isEmpty) return const [];
  final t0 = pts.first.$1;
  final n = (pts.last.$1 - t0) ~/ 60 + 1;
  // A session longer than a day, or timestamps that are not what we think they
  // are: fall back to the values rather than allocating a nonsense array.
  if (n < 1 || n > 24 * 60) return [for (final p in pts) p.$2];
  final want = session == null ? n : session.inMinutes + 1;
  final out = List<double?>.filled(
      want > n && want <= 24 * 60 ? want : n, null);
  for (final p in pts) {
    final i = (p.$1 - t0) ~/ 60;
    if (i >= 0 && i < n) out[i] = p.$2;
  }
  return out;
}

/// Zone 5 of a persisted `zone_bands` list — the row carrying the set's own
/// `source` stamp and, as its `hi`, the ceiling the whole set is a percentage
/// of. Null for a session that banked no split, and then the footnote says the
/// estimate: the one claim that stands with no ceiling to name.
Map<String, dynamic>? _topBand(Object? bands) {
  if (bands is! List || bands.length != 5) return null;
  final top = bands.last;
  return top is Map ? top.cast<String, dynamic>() : null;
}

/// `zone_min` comes back from the repo as raw decoded JSON — guard the type
/// once here so a non-`List` value (or a non-numeric entry) never throws in
/// either read path.
List<double> _decodeZoneMinutes(Object? raw) => [
      for (final z in (raw is List ? raw : const []))
        if (z is num) z.toDouble(),
    ];

/// One past session, opened from history — built from what the stores hold
/// rather than from the six columns the list row carries.
Future<ActivityResult> _detailOf(AppState app, _PastWorkout w) async {
  var out = w.toResult();
  final repo = app.repo;
  if (repo == null) return out;
  try {
    final b = await repo.getWorkout(w.id);
    final band = _topBand(b['zone_bands']);
    // The bundle's own split — and whether it is the one that ends up on
    // screen. A short or absent `zone_min` falls back to the list row's split
    // rather than blanking the bars, but that is a different read from a
    // different moment, so it is one more case where the bands beside it
    // describe a different set.
    final decoded = _decodeZoneMinutes(b['zone_min']);
    final usedBundleSplit = decoded.length == 5;
    // …and whether that split was binned by the pass that produced the bands.
    final rebinned = usedBundleSplit && b['zone_min_rebinned'] != false;
    out = out.copyWith(
      hr: _denseMinutes(b['hr'], w.duration),
      // The session's own mean, computed over its heart-rate stream.
      avgHr: (b['avg_hr'] as num?)?.round(),
      maxHr: (b['max_hr'] as num?)?.round(),
      // How much of the window the trace behind those numbers actually covers.
      // Sessions past `rawRetentionDays` are served from the frozen trace, and
      // one frozen mid-dropout has to read as partial rather than draw a
      // confident line across the gap.
      traceCoveragePct: (b['trace_coverage_pct'] as num?)?.toInt(),
      // TS-04 — the anchors the bands on this card were binned against, read
      // off the bands themselves. `_zoneBands` stamps every row with the set's
      // `source`, and zone 5's `hi` IS the ceiling (both `zonesFromMaxHr` and
      // `reserveZones` put 100 % of the anchor there), so the footnote needs no
      // second read and cannot describe a different set from the bars.
      //
      // …EXCEPT WHEN IT WOULD. The bands are recomputed from the current
      // anchors on every open, while the minutes below can be a KEPT LIVE
      // split: a session the band only partly handed over keeps whichever side
      // saw more minutes, and that side was binned against whatever ceiling was
      // current when it was written. `zone_min_rebinned` is false exactly
      // there, and then this card has no ceiling it can name for these bars —
      // so it names none, and the footnote falls back to the estimate, the one
      // claim that stands without one. Understating the bars to match the
      // bands instead would put them at odds with the strain, calories and
      // duration beside them, which are the kept values too.
      // `band?['source'] as String?` / `as num?` would THROW on a
      // wrong-typed (not just missing) field, and the catch below is
      // best-effort for the WHOLE enrichment — one bad band field must not
      // also blank the hr/avgHr/zoneMinutes reads beside it. `is`-checks
      // degrade to null instead of throwing.
      zoneSource:
          rebinned && band?['source'] is String ? band!['source'] as String : null,
      zoneMaxHr: rebinned && band?['hi'] is num ? band!['hi'] as num : null,
      // …and the MINUTES from the same read, not from the list row. Opening a
      // session rescores it (`_rescoreSessionFromSubstrate`), so the row loaded
      // with the month list can be a split binned before that correction — and
      // pairing those bars with the provenance of the bands just recomputed
      // beside them is the exact mismatch this card is being fixed for.
      //
      // The list row is still the fallback for a split this read could not
      // produce: five zones or nothing, because a partial vector would draw
      // bars for the zones it has and silently drop the rest. When it fires,
      // `rebinned` is false above and no ceiling is named — which is what the
      // objection to falling back here was actually about.
      zoneMinutes: usedBundleSplit ? decoded : out.zoneMinutes,
    );
  } catch (_) {
    // Enrichment is best-effort; the scalars on the row still render.
  }
  // TS-09 — the session's own rating. `getWorkout` is the derived bundle and
  // does not carry the column, so this is one primary-key read of the row.
  try {
    final rpe = (await LocalDb.session(w.id))?['rpe'] as num?;
    if (rpe != null) out = out.copyWith(rpe: rpe.toDouble());
  } catch (_) {
    // An unrated session and an unreadable row both render as unrated.
  }
  try {
    final sets = await LocalDb.strengthSets(w.id);
    if (sets.isNotEmpty) out = out.copyWith(strength: _logFrom(sets));
  } catch (_) {
    /* no sets is a normal session */
  }
  try {
    final route = await repo.getWorkoutRoute(w.id);
    if (route != null && route.hasPath) out = _withRoute(out, route);
  } catch (_) {
    /* no route is a normal session */
  }
  return out;
}

/// `strength_set` rows → the log the summary renders. `load_kg` stays null
/// when it was null: a bodyweight set is not a zero-kilo set.
StrengthLog _logFrom(List<Map<String, Object?>> rows) => StrengthLog([
      for (final r in rows)
        LoggedSet(
          (r['exercise_key'] as String?) ?? '',
          (r['reps'] as num?)?.toInt() ?? 0,
          loadKg: (r['load_kg'] as num?)?.toDouble(),
          rpe: (r['rpe'] as num?)?.toInt(),
          restSec: (r['rest_sec'] as num?)?.toInt(),
          at: DateTime.fromMillisecondsSinceEpoch(
              ((r['at_ts'] as num?)?.toInt() ?? 0) * 1000),
        ),
    ]);

// ── the data this screen reads ─────────────────────────────────────────────

class _Load {
  final double ctl;

  /// Nullable: the pipeline can produce fitness without fatigue and form, and
  /// zero is a real training state that must not stand in for "not computed".
  final double? atl, tsb;
  const _Load(this.ctl, this.atl, this.tsb);
}

/// TS-12 — the two facts, carried only when they point the same way.
///
/// There is deliberately no combined number and no severity: the analytics
/// emits `both_point_same_way` and the screen either says both sentences or
/// says nothing. A quiet week is the normal state.
class Overreach {
  /// Acute (7-day EWMA) over chronic (42-day EWMA) training load. The IDEAS
  /// wording said "your last 28" — `ctlAtlTsb`'s chronic constant is 42 days,
  /// so the copy says six weeks.
  final double ratio;
  final int nightsElevated, nightsConsidered;
  const Overreach(this.ratio, this.nightsElevated, this.nightsConsidered);
}

/// TS-11 — one session type's typical next-morning move on one daily metric.
///
/// `n` is not optional decoration: it is the difference between a description
/// of fourteen mornings and a claim about football. The analytics already
/// refuses under ten mornings, drops multi-session days and drops thin nights,
/// so every row that arrives here has survived those; the screen's job is to
/// print the count beside the number and never turn it into a verb.
class MorningEffect {
  final String type, metric;
  final int n;
  final double delta;
  final bool exceedsMdc;
  const MorningEffect(
      this.type, this.metric, this.n, this.delta, this.exceedsMdc);
}

/// TS-12 — read ONLY the conjunction the analytics already decided.
///
/// The thresholds (1.5× load, 4 of 5 elevated nights, and the MDC gate under
/// "elevated") live beside the maths in `overreachingConjunction`. A screen
/// that re-derived the verdict from `load_ratio` would be a second copy of them
/// that drifts the first time either moves — so the only question asked here is
/// `both_point_same_way`, and false means render nothing.
@visibleForTesting
Overreach? overreachFrom(Map<String, dynamic> insights) {
  final ov = insights['overreaching'];
  if (ov is! Map) return null;
  final v = ov['value'];
  if (v is! Map) return null; // absent metric — no load history, or quiet
  if (v['both_point_same_way'] != true || v['load_ratio'] is! num) return null;
  return Overreach(
    (v['load_ratio'] as num).toDouble(),
    (v['nights_elevated'] as num?)?.toInt() ?? 0,
    (v['nights_considered'] as num?)?.toInt() ?? 0,
  );
}

/// TS-11 — `session_cost.<metric>` is a Metric whose value is a list of
/// per-type rows. Absent (the state for months, and after every refusal) leaves
/// the list empty and the section unrendered.
@visibleForTesting
List<MorningEffect> morningEffectsFrom(Map<String, dynamic> insights) {
  final out = <MorningEffect>[];
  final cost = insights['session_cost'];
  if (cost is! Map) return out;
  for (final metric in const ['rhr', 'rmssd']) {
    final m = cost[metric];
    final rows = m is Map ? m['value'] : null;
    if (rows is! List) continue;
    for (final r in rows) {
      if (r is! Map) continue;
      final t = r['session_type']?.toString();
      final n = (r['n'] as num?)?.toInt();
      final d = (r['median_delta'] as num?)?.toDouble();
      // No n, no row. A claim without its sample size is the one shape this
      // item exists to prevent, so an unparseable count drops the row rather
      // than printing the median on its own.
      if (t == null || t.isEmpty || n == null || d == null) continue;
      out.add(MorningEffect(t, metric, n, d, r['exceeds_mdc'] == true));
    }
  }
  // Biggest sample first: the best-evidenced description of this user's own
  // history leads. It is a sample size, not a ranking of severity.
  out.sort((a, b) => b.n.compareTo(a.n));
  return out;
}

class _PastWorkout {
  final String id;
  final Activity activity;
  final DateTime start;
  final Duration duration;
  final double? strain;
  final int? calories, avgHr, maxHr;

  /// `sessions.hrr_bpm` — the bpm drop in the 60 s after the session. Carried
  /// from the list row because that is where the repository already serves it.
  final int? hrr60;

  /// `sessions.vo2max_estimate` — submax estimate from one completed km route
  /// split. Carried for the same reason [hrr60] is: opening the detail screen
  /// converts this row straight to an `ActivityResult`.
  final double? vo2max;

  /// `sessions.steps` — banked at finish from the live 100 Hz pedometer and
  /// never recomputed. It is a COLUMN, so unlike the trace it does not depend
  /// on the 1 Hz substrate and does not go blank when that is pruned; a session
  /// that never measured one reads NULL forever, which is the truth for it.
  final int? steps;
  final List<double> zoneMinutes;

  /// The user's "keep this one off the shared surfaces" flag, read back from
  /// `sessions.private`.
  final bool private;

  /// The app or watch that recorded this, when it was not us — "Apple Watch",
  /// "Strava". Null for a session this band measured, and that null is the ONE
  /// test everything below reads: what a row may be counted in, whether it
  /// opens, and what is printed under its name all come off this field.
  final String? importedFrom;

  /// The health store's own name for the activity, already prettified.
  ///
  /// Carried because `activityByName` only resolves the types this app's own
  /// catalogue has, and printing "Workout" over a HealthKit `SURFING` throws
  /// away the one thing the store did tell us.
  final String? importedTitle;

  /// Metres, from the recording app. Only imported rows carry it — a band
  /// session's distance is read on open with its route.
  final double? distanceM;

  const _PastWorkout(this.id, this.activity, this.start, this.duration,
      {this.strain,
      this.calories,
      this.avgHr,
      this.maxHr,
      this.hrr60,
      this.vo2max,
      this.steps,
      this.zoneMinutes = const [],
      this.private = false,
      this.importedFrom,
      this.importedTitle,
      this.distanceM});

  List<double> get zoneFractions {
    final total = zoneMinutes.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return const [0, 0, 0, 0, 0];
    return [for (final z in zoneMinutes) z / total];
  }

  String when(AppLocalizations? loc) {
    final days = calendarDaysBetween(start, DateTime.now());
    final names = [
      loc?.workoutWeekdayAbbrMon ?? 'Mon',
      loc?.workoutWeekdayAbbrTue ?? 'Tue',
      loc?.workoutWeekdayAbbrWed ?? 'Wed',
      loc?.workoutWeekdayAbbrThu ?? 'Thu',
      loc?.workoutWeekdayAbbrFri ?? 'Fri',
      loc?.workoutWeekdayAbbrSat ?? 'Sat',
      loc?.workoutWeekdayAbbrSun ?? 'Sun',
    ];
    final t = '${start.hour.toString().padLeft(2, '0')}:'
        '${start.minute.toString().padLeft(2, '0')}';
    if (days == 0) return loc?.workoutWhenToday(t) ?? 'Today, $t';
    if (days == 1) return loc?.workoutWhenYesterday(t) ?? 'Yesterday, $t';
    if (days < 7) return '${names[start.weekday - 1]}, $t';
    return '${start.day}/${start.month}, $t';
  }

  ActivityResult toResult() => ActivityResult(
        activity,
        start: start,
        duration: duration,
        private: private,
        // TS-09 — the id travels so the summary can write a rating against
        // it; the rating itself is read on open by `_detailOf`, not carried on
        // this row (the list does not show it).
        sessionId: id,
        strain: strain,
        calories: calories,
        avgHr: avgHr,
        maxHr: maxHr,
        hrr60: hrr60,
        vo2max: vo2max,
        steps: steps,
        zoneMinutes: zoneMinutes,
      );
}

class _WorkoutData {
  final double? weightKg;
  final _Load? load;
  final String? loadNote;

  /// Daily TRIMP, one slot per calendar day for the seven ending [trimpEnd].
  /// Null is a day that derived nothing — a hole the painter draws as a hole,
  /// rather than a value that silently shifts the whole week along.
  final List<double?> trimp7;

  /// The day slot 6 belongs to. Carried so the x labels are read off the same
  /// anchor the buckets were built with, not off a second `DateTime.now()`.
  final DateTime? trimpEnd;

  /// Kilos moved per day over the SAME seven slots as [trimp7]. Null is a day
  /// with nothing logged; a bodyweight-only day is also null, because a set
  /// with no `load_kg` has a volume nobody measured — not a volume of zero.
  final List<double?> tonnage7;

  /// Whether any set in that week was logged without a load, which makes every
  /// bar above a floor rather than a total.
  final bool tonnagePartial;
  final List<_PastWorkout> workouts;
  final Set<int> weekDays; // 0 = Monday
  final int weekCount;

  /// How many of [weekCount] came from the phone's health store. Carried so
  /// the gap between "This week" and "Weekly load" can be explained where the
  /// two sit side by side, rather than left to look like a bug.
  final int weekImported;
  final double? weekLoad;
  final int? workoutsTracked;

  /// The activities this user actually started, most recent first, deduped.
  final List<Activity> recent;

  /// Previous and best set per exercise, from this user's own log.
  final Map<String, SetHistory> setHistory;

  /// TS-12. Null whenever the two facts do NOT coincide — including every day
  /// the load history is too short to have an opinion. Silence is the output.
  final Overreach? overreach;

  /// TS-11. Empty until some session type has ten clean mornings behind it,
  /// which takes months, and that is the honest state until then.
  final List<MorningEffect> morningAfter;

  /// The detector's active bouts — every "did you work out?" that has neither
  /// been logged nor dismissed. Empty when auto-detection is switched off.
  ///
  /// These rows have been written on every derive since the detector shipped
  /// and read by nothing, so a detected effort was invisible unless a
  /// notification happened to catch you — and until the emit moved off the
  /// dropped `recovery` channel, no notification ever did.
  final List<Suggestion> suggestions;

  /// When the phone's health store last handed us a workout, or null for
  /// never. It is the whole difference between an Import button and a Refresh
  /// one — see health_import_state.dart for why the store cannot be asked.
  final DateTime? importedLast;

  const _WorkoutData({
    this.weightKg,
    this.load,
    this.loadNote,
    this.trimp7 = const [],
    this.trimpEnd,
    this.tonnage7 = const [],
    this.tonnagePartial = false,
    this.workouts = const [],
    this.weekDays = const {},
    this.weekCount = 0,
    this.weekImported = 0,
    this.weekLoad,
    this.workoutsTracked,
    this.recent = const [],
    this.setHistory = const {},
    this.overreach,
    this.morningAfter = const [],
    this.suggestions = const [],
    this.importedLast,
  });

  const _WorkoutData.empty() : this();
}

/// One pass over the repo. Every call is defensive: this screen must render on
/// a device that has never synced, and a throw in any one of them must not
/// take the whole tab down.
Future<_WorkoutData> _loadWorkoutData(AppState app) async {
    final repo = app.repo;
    if (repo == null) return const _WorkoutData.empty();

    double? weight;
    try {
      weight = (await repo.getProfile())['weight_kg'] as double?;
    } catch (_) {
      weight = null;
    }

    // ONE crossday read for the three blocks that come out of it: `load`
    // (CTL/ATL/TSB), `overreaching` (TS-12) and `session_cost` (TS-11). The
    // repo already gates it for staleness and returns `{stale: …}` instead of
    // the artifact, in which case every key below is simply absent.
    Map<String, dynamic> insights = const {};
    try {
      insights = await repo.getInsights();
    } catch (_) {
      insights = const {};
    }

    _Load? load;
    String? note;
    final raw = insights['load'];
    if (raw is Map) {
      note = needMessageFromNote(raw['note'] as String?, unit: 'days');
      final v = raw['value'];
      if (v is Map && v['ctl'] is num) {
        load = _Load(
          (v['ctl'] as num).toDouble(),
          (v['atl'] as num?)?.toDouble(),
          (v['tsb'] as num?)?.toDouble(),
        );
      }
    }

    final overreach = overreachFrom(insights);
    final morningAfter = morningEffectsFrom(insights);

    // One slot per calendar day for the last seven, ending today. A day that
    // derived nothing is a hole, not a shifted neighbour: taking the last
    // seven STORED points stamped `M T W T F S S` on whatever was there, and
    // `metric_series` only gains a row on a day that derives — so after a sync
    // gap the letters named days the data did not come from, and the bar drawn
    // as "today" could be a week old.
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    var trimp = List<double?>.filled(7, null);
    try {
      trimp = lastSevenDays((await repo.getChart('trimp'))['points'], end);
    } catch (_) {
      trimp = List<double?>.filled(7, null);
    }

    final past = <_PastWorkout>[];
    try {
      final rows = (await repo.getWorkouts(range: 'month'))['workouts'];
      if (rows is List) {
        for (final r in rows) {
          if (r is! Map) continue;
          final ts = (r['start_ts'] as num?)?.toInt();
          if (ts == null) continue;
          final a = activityByName(r['type'] as String?) ??
              const Activity('Workout', LucideIcons.activity, C.purple,
                  Track.duration, 5.0);
          past.add(_PastWorkout(
            (r['id'] as String?) ?? '',
            a,
            DateTime.fromMillisecondsSinceEpoch(ts * 1000),
            // duration_min is minutes; Motion.tick × 60 × n keeps the one
            // Duration literal in theme.dart.
            Motion.tick * 60 * ((r['duration_min'] as num?)?.toInt() ?? 0),
            strain: (r['strain'] as num?)?.toDouble(),
            calories: (r['calories'] as num?)?.round(),
            // The session's mean over its own HR stream, computed by the repo
            // — not the last sample anybody happened to see.
            avgHr: (r['avg_hr'] as num?)?.round(),
            maxHr: (r['max_hr'] as num?)?.toInt(),
            hrr60: (r['hrr60'] as num?)?.round(),
            vo2max: (r['vo2max_estimate'] as num?)?.toDouble(),
            steps: (r['steps'] as num?)?.toInt(),
            zoneMinutes: _decodeZoneMinutes(r['zone_min']),
            private: r['private'] == true,
          ));
        }
      }
    } catch (_) {
      // leave `past` as-is
    }
    // Workouts another app recorded, on the SAME window the band's own list
    // uses. The store is read 90 days back (30 on Android) because that is the
    // most history worth carrying, but showing three months of imports beside
    // one month of sessions would read as a band that stopped measuring.
    try {
      final since = end.subtract(Motion.tick * 86400 * 31);
      for (final r in await LocalDb.importedWorkouts(limit: 200)) {
        final ts = (r['start_ts'] as num?)?.toInt();
        final endTs = (r['end_ts'] as num?)?.toInt();
        final src = (r['source'] as String?)?.trim();
        // `source` is NOT NULL in the table for exactly this reason: a workout
        // shown without the app that recorded it is a workout this app is
        // implicitly claiming. No source, no row.
        if (ts == null || endTs == null || endTs <= ts) continue;
        if (src == null || src.isEmpty) continue;
        final at = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
        if (at.isBefore(since)) continue;
        final title = importedWorkoutTitle(r['kind']);
        past.add(_PastWorkout(
          (r['uuid'] as String?) ?? '',
          // The icon and colour only, when the catalogue happens to know the
          // type. The NAME always comes from the store — `activityByName`
          // resolves the ~40 types this app can start, and the fallback would
          // print "Workout" over a surf.
          activityByName(title) ??
              const Activity('Workout', LucideIcons.activity, C.purple,
                  Track.duration, 5.0),
          at,
          Motion.tick * (endTs - ts),
          // No strain, ever. It is not omitted pending a better idea — there
          // is no heart-rate series behind this row to score one from, so
          // every load surface reads null and leaves it out on its own.
          calories: (r['energy_kcal'] as num?)?.round(),
          steps: (r['steps'] as num?)?.toInt(),
          importedFrom: src,
          importedTitle: title,
          distanceM: (r['distance_m'] as num?)?.toDouble(),
        ));
      }
    } catch (_) {
      // Nothing imported is the normal state, and an unreadable table must not
      // take the band's own history down with it.
    }

    past.sort((a, b) => b.start.compareTo(a.start));

    // TS-08 — mechanical load, on the same seven slots the TRIMP chart uses.
    // One indexed read per session in the window, in parallel, and only for the
    // window: `strength_set` has no per-week aggregate and this is a handful of
    // rows either way.
    // ponytail: N queries per screen load. If a lifter with a session every day
    // ever feels it, the fix is a SUM(reps*load_kg) GROUP BY in LocalDb, not a
    // cache here.
    final tonnage7 = List<double?>.filled(7, null);
    var tonnagePartial = false;
    final tonnageJobs = <Future<void>>[];
    for (final w in past) {
      final slot = _daySlot(w.start, end);
      if (slot == null || w.id.isEmpty || w.importedFrom != null) continue;
      tonnageJobs.add(LocalDb.strengthSets(w.id).then((rows) {
        if (rows.isEmpty) return;
        final log = _logFrom(rows);
        if (log.hasUnloadedSets) tonnagePartial = true;
        final v = log.volumeKg;
        if (v == null) return; // bodyweight-only session: no kilos to add
        tonnage7[slot] = (tonnage7[slot] ?? 0) + v;
      }));
    }
    try {
      await Future.wait(tonnageJobs);
    } catch (_) {
      // Nobody lifting is the normal case; a partial sum is still honest.
    }

    final weekStart = end.subtract(Motion.tick * 86400 * (end.weekday - 1));
    final thisWeek = [for (final w in past) if (w.start.isAfter(weekStart)) w];

    int? tracked;
    try {
      tracked = ((await repo.getRecords())['workouts_tracked'] as num?)
          ?.toInt();
    } catch (_) {
      tracked = null;
    }

    // Imported sessions fall out here on their own: they carry no strain,
    // because there is no heart-rate series behind them to score one from.
    // Nothing filters them — there is nothing to add.
    final weekLoad = thisWeek
        .where((w) => w.strain != null)
        .fold<double?>(null, (a, w) => (a ?? 0) + w.strain!);

    // Real recency, deduped, newest first — six tiles like the constant it
    // replaces, so the picker's row is the same shape either way.
    //
    // Band sessions only. These tiles START a session, and most imported types
    // land on the generic fallback activity — a row of "Workout" tiles that
    // begin a five-MET nothing is worse than the six real ones.
    final recent = <Activity>[];
    for (final w in past) {
      if (w.importedFrom != null) continue;
      if (!recent.any((x) => x.name == w.activity.name)) {
        recent.add(w.activity);
      }
      if (recent.length == 6) break;
    }

    // The live screen has to have previous/best in hand before the first set;
    // "First time on this lift" was showing forever because nothing loaded
    // them.
    final history = await loadSetHistory();

    return _WorkoutData(
      weightKg: weight,
      load: load,
      loadNote: note,
      trimp7: trimp,
      trimpEnd: end,
      tonnage7: tonnage7,
      tonnagePartial: tonnagePartial,
      workouts: past,
      // Imported days light a dot too. This strip says "you trained", not
      // "this band measured you", and a Sunday run left dark because the watch
      // recorded it instead of the band is wrong in a way the user can see.
      weekDays: {for (final w in thisWeek) w.start.weekday - 1},
      weekCount: thisWeek.length,
      weekImported: thisWeek.where((w) => w.importedFrom != null).length,
      weekLoad: weekLoad,
      workoutsTracked: tracked,
      recent: recent,
      setHistory: history,
      overreach: overreach,
      morningAfter: morningAfter,
      suggestions: await activeSuggestions(),
      importedLast: await lastImportAt(HealthImport.workouts),
    );
}
