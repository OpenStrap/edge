// Nutrition.
//
// Three things this screen refuses to do, and they shape everything else:
//
//   1. It never shows a total it cannot stand behind. A day where any occasion
//      has no energy attached is a FLOOR, labelled "at least", and it is
//      excluded from every average on the Week tab.
//   2. Partial days are detected, not declared. There is no "I logged
//      everything" checkbox, because nobody ticks it and every average then
//      quietly rots.
//   3. Daily is the detail view. The seven-day rolling average is the hero —
//      one day of intake is noise, seven is a habit.
//
// Water is NOT re-invented here: it is the existing `water_ml` journal field
// (`lib/data/journal_fields.dart`), read and written through the repo.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../data/db.dart';
import '../../data/day_label.dart';
import '../../data/nutrition_store.dart';
import '../../models/metric.dart';
import '../../data/journal_fields.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import '../onboarding/profile_setup.dart' show formatDay;
import 'journal_compose.dart' show OsTextField;
import 'log_food.dart';

class NutritionScreen extends StatefulWidget {
  const NutritionScreen({super.key});

  @override
  State<NutritionScreen> createState() => _NutritionScreenState();
}

class _NutritionScreenState extends State<NutritionScreen> with RevisionReload {
  int _tab = 0;
  static List<String> _tabs(BuildContext c) {
    final l = AppLocalizations.of(c);
    return [
      l?.nutritionTabToday ?? 'Today',
      l?.nutritionTabWeek ?? 'Week',
      l?.nutritionTabGoals ?? 'Goals',
    ];
  }

  /// Read on every use, never captured once: the shell keeps this tab alive in
  /// its IndexedStack, so a field initialiser would still be yesterday after
  /// midnight and an occasion logged at 00:05 would land on the wrong day.
  String get _date => todayLabel();
  NutritionWindow? _week;
  Metric? _burned;
  double? _waterMl;
  /// The day [_waterMl] was read for. Past midnight on a tab nobody reloaded
  /// it is still yesterday's, and a full yesterday disabled today's + button.
  String? _waterDate;
  bool _loading = true;

  /// The local profile map, read once per load. Targets live here rather than
  /// in a new table: they are two numbers the user typed, the same shape as
  /// `step_goal` next to them.
  Map<String, dynamic> _profile = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Burned calories and water come from the derived store and the journal,
  /// both of which are written from elsewhere in the app — an import, a derive
  /// after a sync, water logged on Wellness. This tab is never disposed, so
  /// without this it showed launch-time figures all day.
  @override
  void reload() => _load();

  Future<void> _load() async {
    final t = beginRead(#nutrition);
    final app = context.read<AppState>();
    final db = await LocalDb.instance;
    final week = await NutritionDb.window(db, days: 7);
    Metric? burned;
    double? water;
    final date = _date;
    final repo = app.repo;
    if (repo != null) {
      final today = await repo.getToday();
      final daily = today['daily'];
      if (daily is Map) burned = Metric.parse(daily['calories_total']);
      water = (await repo.getJournalMetrics(date))['water_ml']?.value;
    }
    if (!stillNewest(#nutrition, t)) return;
    setState(() {
      _week = week;
      _burned = burned;
      _waterMl = water;
      _waterDate = date;
      _profile = {...?app.user};
      _loading = false;
    });
  }

  NutritionDay? get _today {
    final w = _week;
    if (w == null) return null;
    for (final d in w.days) {
      if (d.date == _date) return d;
    }
    return null;
  }

  Future<void> _logFood({String meal = 'snack'}) async {
    final ok = await LogFoodSheet.show(context, date: _date, meal: meal);
    if (ok == true) await _load();
  }

  /// One tap's worth of water, from the field spec that performs the tap.
  static JournalFieldSpec get _waterSpec => kJournalFieldsByKey['water_ml']!;

  /// Step the day's water up or down, in place.
  ///
  /// This row used to be add-only: every tap wrote `+250 ml` and nothing on the
  /// screen could take one back. Same ladder as the journal's own stepper — a
  /// step down off the last glass lands on a logged ZERO ("none today"), and a
  /// step down from zero clears the field, because absence and zero are
  /// different answers.
  /// One write at a time. `_stepWater` reads the day, then awaits, then writes
  /// it back — and `postJournalMetrics` replaces the whole day — so two taps
  /// during that await both read the same map and the second write silently
  /// eats the first tap. Same guard the wellness screen already uses for its
  /// journal fields.
  bool _writingWater = false;

  Future<void> _stepWater(int dir) async {
    final repo = context.read<AppState>().repo;
    if (repo == null || _writingWater) return;
    _writingWater = true;
    try {
      // Inside the try, not before it: the READ can throw too, and with the
      // guard already set that left both buttons dead until the screen was
      // rebuilt — the flag outliving the operation it was protecting.
      //
      // Step from what is stored for today, not from `_waterMl`: that is the
      // last load's figure, and on a tab left open past midnight it is still
      // yesterday's total, so the first tap wrote yesterday + 250 ml to today.
      //
      // Drop the key rather than omitting it from a spread: `putJournalMetrics`
      // clears the day and re-inserts what it is handed, so leaving `water_ml`
      // out is what "no answer today" looks like on disk — and spreading the
      // old map back in is exactly what made this un-clearable.
      final date = _date;
      final fields = {...await repo.getJournalMetrics(date)};
      final v = fields.remove('water_ml')?.value;
      final spec = _waterSpec;
      double? next;
      if (dir > 0) {
        next = ((v ?? 0) + spec.step).clamp(0, spec.max).toDouble();
      } else {
        final down = (v ?? 0) - spec.step;
        next = down <= 0 ? (v == null || v == 0 ? null : 0.0) : down;
      }
      if (mounted) {
        setState(() {
          _waterMl = next;
          _waterDate = date;
        });
      }
      if (next != null) fields['water_ml'] = JournalMetricValue(next);
      await repo.postJournalMetrics(date, fields);
      await _load();
    } finally {
      // Cleared unconditionally; the setState is only for the repaint. Gating
      // the assignment on `mounted` would strand it again on the path where
      // the screen goes away mid-write.
      _writingWater = false;
      if (mounted) setState(() {});
    }
  }

  /// Edit an entry — amount, meal, time — or remove it from the same sheet.
  Future<void> _editFood(FoodEntry e) async {
    final ok = await LogFoodSheet.show(context, entry: e);
    if (ok == true) await _load();
  }

  /// Today's protein against the typed target. The Goals tab compares the
  /// seven-day mean; this is the number to act on before the day ends. A
  /// floor says "at least", and no figure at all is said, never drawn as 0 g.
  Widget? _proteinToday(BuildContext c, NutritionDay? day) {
    final target = _target('protein_target');
    if (target == null || target <= 0 || day == null || !day.logged) {
      return null;
    }
    final l = AppLocalizations.of(c);
    final label = l?.nutritionProteinToday ?? 'Protein today';
    final goal = '${target.round()} g';
    final v = day.protein.value;
    if (v == null) {
      return GoalTrajectory(label, l?.nutritionNotRecorded ?? 'Not recorded',
          goal, l?.nutritionAddNumbersFix ?? 'Add the numbers to an occasion',
          0, C.red, rateDown: false);
    }
    // Rounded up: 99.6 of 100 g is still 1 g to go, never "reached".
    final left = (target - v).ceil();
    return GoalTrajectory(
      label,
      '${day.protein.isFloor ? (l?.nutritionAtLeastPrefix ?? 'at least ') : ''}'
          '${v.round()} g',
      goal,
      left > 0
          ? (l?.nutritionProteinToGo(left) ?? '$left g to go')
          : (l?.nutritionTargetReached ?? 'Target reached'),
      (v / target).clamp(0, 1).toDouble(),
      C.red,
      rateDown: false,
    );
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return ListView(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x16),
      children: [
        ScreenTitle(
          l?.nutritionTitle ?? 'Nutrition',
          trailing: Pressable(
            semanticLabel: l?.nutritionLogFood ?? 'Log food',
            onTap: _logFood,
            child: Icon(
              LucideIcons.circlePlus,
              size: 22,
              color: P.of(c).on(C.domFood),
            ),
          ),
        ),
        SubTabs(_tabs(c), _tab, (i) => setState(() => _tab = i), color: C.domFood),
        const SizedBox(height: S.x5),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          [_todayTab, _weekTab, _goalsTab][_tab](c),
      ],
    );
  }

  // ── TODAY ────────────────────────────────────────────────────────────────

  Widget _todayTab(BuildContext c) {
    final l = AppLocalizations.of(c);
    final day = _today;
    final w = _week;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (day == null || !day.logged)
          StatusCard(
            l?.nutritionEmptyTodayTitle ?? 'Nothing logged today',
            l?.nutritionEmptyTodayBody ?? 'One tap is a complete log.',
            fix: l?.nutritionLogOccasionFix ?? 'Log an eating occasion',
            icon: LucideIcons.utensils,
            onFix: _logFood,
          )
        else
          DayEnergyCard(day: day, burned: _burned),
        if (_proteinToday(c, day) case final protein?) ...[
          const SizedBox(height: S.x4),
          protein,
        ],
        Section(
          l?.nutritionOccasionsSection ?? 'Occasions',
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Column(
              children: [
                for (final m in kMeals) ...[
                  MealRow(
                    meal: m,
                    entries: day?.mealEntries(m) ?? const [],
                    onTap: () => _logFood(meal: m),
                  ),
                  // The individual entries, indented under the occasion they
                  // belong to, each one editable and removable. A mistyped
                  // 2,000 kcal used to be permanent and it silently poisoned
                  // every seven-day mean it fell into.
                  for (final e in day?.mealEntries(m) ?? const <FoodEntry>[])
                    Padding(
                      padding: const EdgeInsets.only(left: S.x8),
                      child: FoodRow(
                        entry: e,
                        trailing: LucideIcons.pencil,
                        onTap: () => _editFood(e),
                      ),
                    ),
                ],
              ],
            ),
          ),
          action: l?.nutritionAddAction ?? 'Add',
          onAction: _logFood,
        ),
        const SizedBox(height: S.x4),
        // Gated on the repository too: with no repo `_stepWater` returns at
        // its first line, so an enabled + button was a control that did
        // nothing — worse than a disabled one, which at least says so.
        Builder(builder: (bc) {
          final live = bc.select<AppState, bool>((a) => a.repo != null) &&
              !_writingWater;
          final ml = _waterDate == _date ? _waterMl : null;
          return _WaterRow(
            ml: ml,
            onDown: (!live || ml == null) ? null : () => _stepWater(-1),
            onUp: (!live || (ml ?? 0) >= _waterSpec.max)
                ? null
                : () => _stepWater(1),
          );
        }),
        if (day != null && day.logged && day.kcal.isFloor) ...[
          const SizedBox(height: S.x4),
          StatusCard(
            l?.nutritionFloorTitle ?? 'Today\'s energy is a floor, not a total',
            l?.nutritionFloorBody(day.kcal.unknown, day.entries.length) ??
                '${day.kcal.unknown} of ${day.entries.length} occasions were '
                    'logged without an energy figure, so the number above is '
                    'the least you ate rather than what you ate.',
            fix: l?.nutritionAddNumbersFix ?? 'Add the numbers to an occasion',
            icon: LucideIcons.circleDashed,
            onFix: _logFood,
          ),
        ],
        if (w != null && w.daysExcluded > 0) ...[
          const SizedBox(height: S.x4),
          Observation(
            l?.nutritionDaysNotCounted(w.daysExcluded, w.span) ??
                '${w.daysExcluded} of the last ${w.span} days could not be '
                    'counted',
            l?.nutritionDayCountsRule ??
                'A day counts once every occasion carries an energy figure.',
          ),
        ],
      ],
    );
  }

  // ── WEEK ─────────────────────────────────────────────────────────────────

  Widget _weekTab(BuildContext c) {
    final l = AppLocalizations.of(c);
    final w = _week;
    if (w == null) return const SizedBox.shrink();
    final counted = w.counted.length;
    // PARTIAL, not "excluded": today is excluded from the averages too, and it
    // is not partial — a day cannot be judged incomplete while it is still
    // happening (see `DayLogState.inProgress`).
    final partial = _partialDays(w);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Surface(
          child: Consistency(
            w.daysLogged,
            w.span,
            partial == 0
                ? (l?.nutritionDaysLoggedLabel ?? 'Days with something logged')
                : (l?.nutritionPartialExcluded(partial) ??
                    '$partial logged but partial, so excluded from '
                        'every average below'),
            C.domFood,
          ),
        ),
        Section(l?.nutritionEnergyByDay ?? 'Energy, day by day', _weekChart(c, w)),
        Section(
          l?.nutritionSevenDayAvg ?? 'Seven-day average',
          counted == 0
              ? StatusCard(
                  l?.nutritionNoCompleteDayTitle ?? 'No complete day to average yet',
                  l?.nutritionNoCompleteDayBody ?? 'You have none.',
                  icon: LucideIcons.chartNoAxesColumn,
                )
              : Surface(
                  child: Column(
                    children: [
                      _Mean(l?.nutritionLabelEnergy ?? 'Energy', w.meanKcal,
                          'kcal', C.domFood),
                      _Mean(l?.nutritionLabelProtein ?? 'Protein',
                          w.meanProtein, 'g', C.red),
                      _Mean(l?.nutritionLabelCarbs ?? 'Carbs', w.meanCarbs,
                          'g', C.orange),
                      _Mean(l?.nutritionLabelFat ?? 'Fat', w.meanFat, 'g',
                          C.yellow),
                      _Mean(l?.nutritionLabelFibre ?? 'Fibre', w.meanFibre,
                          'g', C.green),
                    ],
                  ),
                ),
        ),
        if (counted > 0 && w.meanKcal.value != null && _burned?.value != null)
          Section(
            l?.nutritionEnergyBalance ?? 'Energy balance',
            Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InlineMetrics([
                    (l?.nutritionLabelEaten ?? 'EATEN',
                        '${w.meanKcal.value!.round()} kcal', C.domFood),
                    (l?.nutritionLabelBurned ?? 'BURNED',
                        '${_burned!.value!.round()} kcal', C.purple),
                    (
                      l?.nutritionLabelBalance ?? 'BALANCE',
                      '${(w.meanKcal.value! - _burned!.value!).round()} kcal',
                      C.teal,
                    ),
                  ]),
                  const SizedBox(height: S.x3),
                  Text(
                    l?.nutritionEatenMeanNote(w.meanKcal.days) ??
                        'Eaten is the mean of ${w.meanKcal.days} complete '
                            'days. Burned is today only.',
                    style: F.cap.copyWith(color: P.of(c).ink3, height: 1.45),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Logged days that are genuinely partial. Today is deliberately not one of
  /// them — it is unfinished, not incomplete.
  static int _partialDays(NutritionWindow w) =>
      w.days.where((d) => d.state == DayLogState.partial).length;

  /// Seven bars of logged energy, today highlighted. A day with nothing logged
  /// draws no bar rather than a zero — zero kcal is a claim, and an unlogged
  /// day is an absence. A PARTIAL day still draws, because its total is a real
  /// floor; the footnote says it is one and that the mean below excluded it.
  Widget _weekChart(BuildContext c, NutritionWindow w) {
    final l = AppLocalizations.of(c);
    // `?? 0.0` here was the whole absence-versus-zero bug in one operator: an
    // unlogged day became a real zero, and `Bars`' 2 pt visibility floor drew
    // it as a measured day with almost nothing in it. Null is a hole.
    final vals = [for (final d in w.days) d.kcal.value?.toDouble()];
    final real = vals.whereType<double>().where((v) => v > 0).toList();
    final drawn = real.length;
    final axis = drawn == 0 ? null : AxisSpec.of(real, floor: 0);
    return Surface(
      child: ChartFrame(
        title: l?.nutritionEnergyLoggedTitle ?? 'Energy logged',
        unit: 'kcal',
        height: 120,
        yAxis: axis,
        // The window is built oldest-first ending today, so these labels are
        // the range actually drawn rather than a hardcoded guess.
        xLabels: drawn == 0
            ? const []
            : [
                _dayShort(w.days.first.date, l),
                l?.nutritionTabToday ?? 'Today',
              ],
        footnote: _partialDays(w) == 0
            ? null
            : l?.nutritionPartialFootnote(_partialDays(w)) ??
                '${_partialDays(w)} partial, left out of the averages below.',
        // The bars are ENERGY. A week of one-tap occasions is a fully logged
        // week with no energy in it, and "Nothing logged yet" called the user
        // a liar directly under a card counting those same days.
        empty: axis == null
            ? NoData(
                message: w.daysLogged == 0
                    ? (l?.nutritionNothingLoggedYet ?? 'Nothing logged yet')
                    : (l?.nutritionNoEnergyFiguresYet ?? 'No energy figures yet'))
            : null,
        series: vals,
        child: axis == null
            ? const SizedBox.shrink()
            : CustomPaint(
                size: Size.infinite,
                painter: Bars(vals, C.domFood,
                    highlight: vals.length - 1, t: animate(c, 1), axis: axis),
              ),
      ),
    );
  }

  // ── GOALS ────────────────────────────────────────────────────────────────

  /// A target the user TYPES. Adaptive targets need weight history and ~21
  /// complete days and stay deferred; a typed one needs no science at all, and
  /// the tab is named Goals.
  static List<(String, String, String, Color)> _goalSpecs(BuildContext c) {
    final l = AppLocalizations.of(c);
    return [
      ('kcal_target', l?.nutritionDailyEnergy ?? 'Daily energy', 'kcal', C.domFood),
      ('protein_target', l?.nutritionDailyProtein ?? 'Daily protein', 'g', C.red),
    ];
  }

  double? _target(String key) => (_profile[key] as num?)?.toDouble();

  /// The same gated mean the Week tab prints, so goal progress and the average
  /// can never disagree — including about how many days went into it.
  NutrientMean? _meanFor(String key) =>
      key == 'kcal_target' ? _week?.meanKcal : _week?.meanProtein;

  Future<void> _editTargets() async {
    final specs = _goalSpecs(context);
    final ctrls = {
      for (final g in specs)
        g.$1: TextEditingController(text: _target(g.$1)?.round().toString() ?? ''),
    };
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: sheetMotion(context),
      backgroundColor: P.of(context).card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.xxl)),
      ),
      builder: (s) {
        final l = AppLocalizations.of(s);
        return Padding(
          padding: EdgeInsets.only(
              left: S.x5,
              right: S.x5,
              top: S.x5,
              bottom: MediaQuery.of(s).viewInsets.bottom + S.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l?.nutritionYourTargetsSection ?? 'Your targets',
                  style: F.head.copyWith(color: P.of(s).ink)),
              const SizedBox(height: S.x4),
              for (final g in specs) ...[
                OsTextField(
                  controller: ctrls[g.$1]!,
                  label: '${g.$2} (${g.$3})',
                  hint: l?.nutritionHintNone ?? 'none',
                  keyboard: const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: S.x3),
              ],
              const SizedBox(height: S.x2),
              BigButton(l?.actionSave ?? 'Save',
                  color: C.domFood, onTap: () => Navigator.of(s).pop(true)),
            ],
          ),
        );
      },
    );
    // Blank clears the target; a typo does NOT. "2,000" used to clear it and
    // the sheet closed as if it had saved.
    final typed = {
      for (final g in specs) g.$1: Typed.of(ctrls[g.$1]!.text),
    };
    final fields = {
      for (final g in specs) g.$1: typed[g.$1]!.value,
    };
    for (final ctrl in ctrls.values) {
      ctrl.dispose();
    }
    if (saved != true || !mounted) return;
    final bad = [for (final g in specs) if (typed[g.$1]!.bad) g.$2];
    if (bad.isNotEmpty) {
      sayUnreadable(context, bad);
      return;
    }
    await context.read<AppState>().updateProfile(fields);
    await _load();
  }

  Widget _goalsTab(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final specs = _goalSpecs(c);
    final set = [for (final g in specs) if (_target(g.$1) != null) g];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (set.isEmpty)
          StatusCard(
            l?.nutritionNoTargetsTitle ?? 'No targets set',
            l?.nutritionNoTargetsBody ?? 'A target here is one you type.',
            fix: l?.nutritionSetTargetFix ?? 'Set a target',
            icon: LucideIcons.target,
            onFix: _editTargets,
          )
        else
          Section(
            l?.nutritionYourTargetsSection ?? 'Your targets',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final g in set) ...[
                  _goalCard(c, g),
                  const SizedBox(height: S.x3),
                ],
              ],
            ),
            action: l?.nutritionEditAction ?? 'Edit',
            onAction: _editTargets,
          ),
        const SizedBox(height: S.x4),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.cpu, size: 16, color: p.on(C.purple)),
                  const SizedBox(width: S.x2),
                  Expanded(
                    child: Text(
                      l?.nutritionBodySpentToday ?? 'What your body spent today',
                      style: F.body.copyWith(
                        color: p.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: S.x4),
              MetricRow(
                LucideIcons.flame,
                C.purple,
                l?.nutritionEstimatedExpenditure ?? 'Estimated expenditure',
                _burned?.value == null
                    ? (l?.nutritionNotMeasured ?? 'Not measured')
                    : '${_burned!.value!.round()}',
                unit: _burned?.value == null ? '' : 'kcal',
                sub: l?.nutritionExpenditureSub ?? 'TODAY, FROM HEART RATE AND YOUR PROFILE',
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Current → target → the rate between them. The "current" is the mean of
  /// COMPLETE days only, the same denominator the Week tab uses, so the goal
  /// and the average can never disagree about what was counted.
  Widget _goalCard(BuildContext c, (String, String, String, Color) g) {
    final l = AppLocalizations.of(c);
    final target = _target(g.$1)!;
    final m = _meanFor(g.$1);
    final mean = m?.value;
    // A stable per-goal noun, not `g.$2`'s last word: the label is a full
    // localized phrase ("Énergie quotidienne" in French puts the adjective
    // AFTER the noun), so slicing it grabs "quotidienne", not "énergie".
    final nutrient = g.$1 == 'kcal_target'
        ? (l?.nutritionEnergyWord ?? 'energy')
        : (l?.nutritionProteinWord ?? 'protein');
    if (mean == null || target <= 0) {
      return StatusCard(
        l?.nutritionNothingToMeasure(nutrient) ??
            'Nothing to measure $nutrient against yet',
        // Two different absences, and the difference matters: the day never
        // qualified, or it qualified on energy while this nutrient was only a
        // floor. Progress against a floor would read low every single day.
        // Three, actually — the third is a day that DID qualify while this
        // nutrient was never typed at all, and blaming that on day
        // completeness is a sentence the user can see is false.
        (m?.floorDays ?? 0) > 0
            ? (l?.nutritionFloorAverageBody(nutrient) ??
                'Every complete day had an occasion logged without a '
                    '$nutrient figure, so the average would only be a lower '
                    'bound.')
            : (_week?.counted.length ?? 0) > 0
                ? (l?.nutritionCountedNoFigureBody(
                        _week!.counted.length, _week!.span, nutrient) ??
                    '${_week!.counted.length} of the last ${_week!.span} days '
                        'counted, but none of them carried a $nutrient '
                        'figure.')
                : (l?.nutritionDayCountsRuleFull(_week?.span ?? 7) ??
                    'A day counts once every occasion carries a figure and '
                        'the log reaches the evening. None of the last '
                        '${_week?.span ?? 7} days has.'),
        fix: (m?.floorDays ?? 0) > 0 || (_week?.counted.length ?? 0) > 0
            ? (l?.nutritionAddNumbersFix ?? 'Add the numbers to an occasion')
            : (l?.nutritionLogOccasionFix ?? 'Log an eating occasion'),
        icon: LucideIcons.target,
        onFix: _logFood,
      );
    }
    // The nutrient's OWN denominator, not the window's count of complete days:
    // protein can be measured on fewer days than energy was.
    final days = m!.days;
    final diff = mean - target;
    final rate = diff.abs() < 1
        ? (l?.nutritionOnTarget ?? 'On target')
        : (diff > 0
            ? (l?.nutritionRateAbove(diff.abs().round(), g.$3) ??
                '${diff.abs().round()} ${g.$3}/day above')
            : (l?.nutritionRateBelow(diff.abs().round(), g.$3) ??
                '${diff.abs().round()} ${g.$3}/day below'));
    final meanNote = l?.nutritionMeanOfDays(days) ??
        'mean of $days complete day${days == 1 ? '' : 's'}';
    return GoalTrajectory(
      g.$2,
      '${mean.round()} ${g.$3}',
      '${target.round()} ${g.$3}',
      '$rate · $meanNote',
      (mean / target).clamp(0, 1).toDouble(),
      g.$4,
      rateDown: diff > 0,
    );
  }
}

/// "Thu 4 Sep" from a `YYYY-MM-DD` day label, for an axis end-label.
String _dayShort(String ymd, [AppLocalizations? l]) {
  final d = DateTime.tryParse(ymd);
  return d == null ? ymd : formatDay(d, l);
}

// ── components ─────────────────────────────────────────────────────────────

/// Today's energy, with its honesty state on the face of it. `at least` is not
/// a hedge — it is arithmetic: a total that summed past unknown values is a
/// lower bound and nothing more.
class DayEnergyCard extends StatelessWidget {
  const DayEnergyCard({super.key, required this.day, this.burned});

  final NutritionDay day;
  final Metric? burned;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final k = day.kcal;
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  k.value == null
                      ? (l?.nutritionLoggedToday ?? 'LOGGED TODAY')
                      : (l?.nutritionEatenToday ?? 'EATEN TODAY'),
                  style: F.over.copyWith(color: p.ink3),
                ),
              ),
              if (k.isFloor)
                Flexible(child: Pill(l?.nutritionAtLeast ?? 'At least', C.yellow)),
            ],
          ),
          const SizedBox(height: S.x2),
          // With no energy anywhere in the day, the occasion count IS the
          // measurement. A dash here would read as a failure to record when
          // the day was in fact recorded exactly as designed.
          // A Wrap rather than a Row with a Spacer: `2,310 kcal` beside the
          // occasion count overflowed by 168 px at 3.1x, which is a day's
          // energy pushed off the card for the people who chose that size.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: S.x1,
            runSpacing: S.x1,
            children: [
              Text(
                k.value == null
                    ? day.entries.length.toString()
                    : k.value!.round().toString(),
                style: F.n34.copyWith(color: p.ink),
              ),
              Text(
                k.value == null
                    ? (l?.nutritionOccasionsUnit(day.entries.length) ??
                        'occasion${day.entries.length == 1 ? '' : 's'}')
                    : 'kcal',
                style: F.cap.copyWith(color: p.ink3),
              ),
              if (k.value != null)
                Text(
                  '· ${l?.nutritionOccasionsCount(day.entries.length) ??
                      '${day.entries.length} occasion'
                          '${day.entries.length == 1 ? '' : 's'}'}',
                  style: F.cap.copyWith(color: p.ink2),
                ),
            ],
          ),
          if (burned?.value != null) ...[
            const SizedBox(height: S.x4),
            InlineMetrics([
              (l?.nutritionLabelBurned ?? 'BURNED',
                  '${burned!.value!.round()} kcal', C.purple),
              if (k.value != null)
                (
                  // Eaten is a FLOOR when occasions were logged without an
                  // energy figure, so eaten minus burned is a floor too: the
                  // balance is AT LEAST this, never at most. The pill on this
                  // same card says "At least".
                  k.isFloor
                      ? (l?.nutritionLabelBalanceAtLeast ?? 'BALANCE AT LEAST')
                      : (l?.nutritionLabelBalance ?? 'BALANCE'),
                  '${(k.value! - burned!.value!).round()} kcal',
                  C.teal,
                ),
            ]),
          ],
        ],
      ),
    );
  }
}

/// One meal slot. An empty slot is an invitation, not a gap — the row never
/// implies you failed to log something you may simply not have eaten.
class MealRow extends StatelessWidget {
  const MealRow({
    super.key,
    required this.meal,
    required this.entries,
    this.onTap,
  });

  final String meal;
  final List<FoodEntry> entries;
  final VoidCallback? onTap;

  static const _icons = {
    'breakfast': LucideIcons.eggFried,
    'lunch': LucideIcons.salad,
    'dinner': LucideIcons.beef,
    'snack': LucideIcons.apple,
  };

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final known = [
      for (final e in entries)
        if (e.kcal != null) e.kcal!,
    ];
    final total = known.isEmpty ? null : known.reduce((a, b) => a + b);
    final anyUnknown = entries.any((e) => e.kcal == null);
    return Pressable(
      onTap: onTap,
      semanticLabel: _mealLabel(c, meal),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: p.card2, borderRadius: R.rSm),
              child: Icon(
                _icons[meal] ?? LucideIcons.utensils,
                size: 17,
                color: p.ink2,
              ),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _mealLabel(c, meal),
                    style: F.body.copyWith(color: p.ink),
                  ),
                  Text(
                    entries.isEmpty
                        ? (l?.nutritionNotLogged ?? 'Not logged')
                        : total == null
                        ? (l?.nutritionLoggedNoEnergy(entries.length) ??
                            '${entries.length} logged · energy not recorded')
                        : '${anyUnknown ? (l?.nutritionAtLeastPrefix ?? 'at least ') : ''}'
                              '${total.round()} kcal',
                    style: F.over.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
            Icon(
              entries.isEmpty
                  ? LucideIcons.circlePlus
                  : LucideIcons.circleCheck,
              size: 20,
              color: entries.isEmpty ? p.ink3 : p.on(C.green),
            ),
          ],
        ),
      ),
    );
  }
}

String _mealLabel(BuildContext c, String m) {
  final l = AppLocalizations.of(c);
  return switch (m) {
    'breakfast' => l?.nutritionMealBreakfast ?? 'Breakfast',
    'lunch' => l?.nutritionMealLunch ?? 'Lunch',
    'dinner' => l?.nutritionMealDinner ?? 'Dinner',
    _ => l?.nutritionMealSnacks ?? 'Snacks',
  };
}

/// One nutrient's seven-day mean, with its own denominator.
///
/// The denominator is the nutrient's, not the window's: a day counts toward the
/// ENERGY average on complete kcal alone, so protein can be a floor on a day
/// that qualified. Those days are excluded and NAMED here — a mean built on
/// floors is understated, and printing it beside the energy mean as though both
/// were measured the same way is the failure this row exists to prevent. There
/// is deliberately no "at least" pill: the gated mean is not a floor, so a floor
/// marker would be as wrong as the understatement it replaced.
class _Mean extends StatelessWidget {
  const _Mean(this.label, this.mean, this.unit, this.color);
  final String label;
  final NutrientMean mean;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final n = mean.days;
    final floors = mean.floorDays;
    return MetricRow(
      LucideIcons.chartNoAxesColumn,
      color,
      label,
      mean.value == null
          ? (floors > 0
              ? (l?.nutritionNotCounted ?? 'Not counted')
              : (l?.nutritionNotRecorded ?? 'Not recorded'))
          : mean.value!.round().toString(),
      unit: mean.value == null ? '' : unit,
      sub: mean.value == null
          ? (floors > 0
                ? (l?.nutritionEveryDayNoFigure(label.toUpperCase()) ??
                    'EVERY COMPLETE DAY HAD AN OCCASION WITH NO '
                        '${label.toUpperCase()} FIGURE')
                : (l?.nutritionNoDayRecorded(label.toUpperCase()) ??
                    'NO COMPLETE DAY RECORDED ${label.toUpperCase()}'))
          : (l?.nutritionMeanOfCompleteDaysCaps(n) ??
                  'MEAN OF $n COMPLETE DAY${n == 1 ? '' : 'S'}') +
              (floors == 0
                  ? ''
                  : (l?.nutritionLeftOutAsFloor(floors) ??
                      ' · $floors LEFT OUT AS A FLOOR')),
    );
  }
}

/// Water, with the plus and minus ON the tile — `− 1.8 L +`.
///
/// A separate widget only because the shared [MetricRow] carries one tap for
/// the whole row, and water needs two targets pointing opposite ways. Nothing
/// else about it departs from that row's shape.
class _WaterRow extends StatelessWidget {
  const _WaterRow({required this.ml, this.onDown, this.onUp});

  /// Null is NOT logged, which is a different answer from a logged zero and
  /// reads differently here: "Not logged" against "0.0 L".
  final double? ml;
  final VoidCallback? onDown, onUp;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    return Surface(
      child: Row(children: [
        Icon(LucideIcons.glassWater, size: 18, color: p.on(C.blue)),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l?.nutritionWaterLabel ?? 'Water', style: F.body.copyWith(color: p.ink)),
            Text(
              ml == null
                  ? (l?.nutritionNotLogged ?? 'Not logged')
                  : (l?.nutritionTapToChange ?? 'Tap − or + to change'),
              style: F.over.copyWith(color: p.ink3),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        _WaterStep(LucideIcons.minus, onDown),
        // Fixed width so the number does not shove the buttons sideways as it
        // steps through 0.8 → 1.0 → 1.2.
        SizedBox(
          width: 78,
          child: Text(
            // NEVER a bare em-dash. An absent value says the word; a dash is a
            // shrug the reader has to interpret, and the suite pins this.
            ml == null
                ? (l?.nutritionNoneYet ?? 'None yet')
                : '${(ml! / 1000).toStringAsFixed(1)} L',
            textAlign: TextAlign.center,
            style: ml == null
                ? F.cap.copyWith(color: p.ink3)
                : F.n24.copyWith(color: p.ink),
            maxLines: 1,
          ),
        ),
        _WaterStep(LucideIcons.plus, onUp),
      ]),
    );
  }
}

class _WaterStep extends StatelessWidget {
  const _WaterStep(this.icon, this.onTap);
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final on = onTap != null;
    return Pressable(
      onTap: onTap,
      semanticLabel: icon == LucideIcons.plus
          ? (l?.nutritionAddWater ?? 'Add water')
          : (l?.nutritionRemoveWater ?? 'Remove water'),
      child: Container(
        width: S.tap,
        height: S.tap,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? p.wash(C.blue) : p.card2,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: on ? p.on(C.blue) : p.ink3),
      ),
    );
  }
}
