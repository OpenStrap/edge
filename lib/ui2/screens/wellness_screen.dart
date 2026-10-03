// Wellness — softer than Health, same system.
//
// Health tells you what your body did. Wellness is where you tell it back, and
// where the app explains itself. Five sub-tabs: Mind, Recovery, Habits,
// Medication, Cycle. Cycle is a SUB-TAB and not a sixth shell tab — see
// `app_shell.dart`; anything that feels like a sixth domain belongs inside the
// domain that owns it.
//
// Three rules this screen exists to hold:
//   · Habits are a CONSISTENCY, never a streak. "5 of 7 days" cannot reset to
//     zero, so a missed day costs a day rather than costing everything.
//   · Adherence is a COUNT with its window stated, and a dose still ahead of
//     you today is in no denominator.
//   · There is no drug-interaction checking. The screen does not carry a card
//     saying so either — a disclaimer for a feature that was never offered is
//     still an advert for it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' show journalFieldLagDays;
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../data/day_label.dart';
import '../../data/journal_fields.dart';
import '../../data/med_store.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart' show whyFromNote;
import '../../state/app_state.dart';
import '../../stress/breath_phases.dart';
import '../ui2.dart';
import 'calm_breathing.dart';
import 'driver_breakdown.dart';
import 'cycle_screen.dart';
import 'home_screen.dart' show envValue, metricOf, weekdayShortName;
import 'journal_compose.dart';
import 'start_card.dart';
import 'metric_detail.dart' show detailScaffold;
import 'sleep_detail.dart';

class WellnessScreen extends StatefulWidget {
  const WellnessScreen({super.key});

  /// A deep link asking for one of the sub-tabs — [medsTab] from the dose
  /// reminder. -1 for the ordinary case: open where the screen opens.
  ///
  /// NOT A CONSTRUCTOR ARGUMENT, and it cannot be one. This screen is built by
  /// the shell's IndexedStack, which keeps it alive; a tap that lands on a
  /// Wellness already on screen rebuilds nothing, so there is no constructor
  /// call to carry the index. A request the screen listens for reaches it in
  /// BOTH cases — the live state's listener when Wellness is already up, and
  /// the fresh state's `initState` when the shell re-keys to switch domain.
  ///
  /// The shell CLEARS it a frame later rather than the screen consuming it on
  /// read: on the re-key path the outgoing state's listener fires first, and a
  /// consume-on-read would eat the request before the incoming one existed.
  static final ValueNotifier<int> tabRequest = ValueNotifier<int>(-1);

  /// Cycle is LAST on purpose: it is the one tab that can be switched off
  /// (Profile → Preferences → Cycle tracking, off by default), and dropping a
  /// trailing tab leaves every other tab's index where it was.
  ///
  /// On the widget rather than the state so [medsTab] can be checked against
  /// it — a deep link that lands on the wrong tab because the list was
  /// reordered is not a failure anything else would catch.
  ///
  /// Fallback labels only — index bookkeeping uses `.length`, and the actual
  /// display labels are localized in `build`.
  static const tabs = ['Mind', 'Recovery', 'Habits', 'Medication', 'Cycle'];

  static const int medsTab = 3;

  @override
  State<WellnessScreen> createState() => _WellnessScreenState();
}

class _WellnessScreenState extends State<WellnessScreen> with RevisionReload {
  int _tab = 0;
  static const _tabs = WellnessScreen.tabs;

  /// Habit consistency is read over a fortnight: long enough that one bad week
  /// does not read as collapse, short enough to still be about now.
  static const _habitDays = 14;

  /// Read on every use, never captured once: the shell keeps this tab alive in
  /// its IndexedStack, so a field initialiser would still be yesterday after
  /// midnight and habit ticks would land on yesterday's date.
  String get _date => todayLabel();
  bool _loading = true;

  /// One journal write at a time. `putJournalMetrics` deletes the day and
  /// re-inserts it, so two quick taps both read the same day and the second
  /// erased the first.
  bool _writingField = false;

  Map<String, dynamic> _stress = const {};
  Map<String, dynamic> _insights = const {};

  /// The four readiness inputs, each already carrying its reading, this user's
  /// own centre and spread, the signed contribution and the MDC gate. Assembled
  /// by [driverFacts] from three stored things; nothing here computes.
  List<DriverFacts> _drivers = const [];
  Map<String, JournalMetricValue> _todayFields = {};
  List<JournalFieldSpec> _habits = const [];
  List<JournalFieldSpec> _fields = const [];
  Map<String, Map<String, JournalMetricValue>> _habitHistory = const {};
  List<Map<String, dynamic>> _breathing = const [];
  List<MedDef> _meds = const [];
  List<MedSlot> _slots = const [];
  ({int taken, int of}) _adherence = (taken: 0, of: 0);

  @override
  void initState() {
    super.initState();
    final t = WellnessScreen.tabRequest.value;
    if (t >= 0 && t < _tabs.length) _tab = t;
    WellnessScreen.tabRequest.addListener(_onTabRequest);
    _load();
  }

  /// A dose reminder tapped while Wellness was already the open domain.
  void _onTabRequest() {
    final t = WellnessScreen.tabRequest.value;
    if (t < 0 || t >= _tabs.length || t == _tab || !mounted) return;
    setState(() => _tab = t);
  }

  @override
  void dispose() {
    WellnessScreen.tabRequest.removeListener(_onTabRequest);
    super.dispose();
  }

  /// Readiness drivers, insights and journal metrics all move under this tab
  /// when a derive or an import runs — and it is one of the three the shell
  /// keeps alive forever, so it read them once and stopped.
  @override
  void reload() => _load();

  /// After a medication or journal write. The dose reminders, the strap buzz
  /// and the check-in are armed ahead of time and never look at the dose or
  /// the day when they fire — so a dose ticked at 07:56 still buzzed at 08:00
  /// until the next resume re-armed them.
  Future<void> _wrote() async {
    if (!mounted) return;
    unawaited(context.read<AppState>().refreshAiReminders());
    await _load();
  }

  Future<void> _load() async {
    final t = beginRead(#wellness);
    final app = context.read<AppState>();
    final repo = app.repo;
    final db = await LocalDb.instance;

    final meds = await MedDb.defs(db);
    final doses = await MedDb.dosesForDay(db, _date);
    final adherence = await MedDb.adherenceWindow(db, days: 7);
    final breathing = await app.breathingHistory(limit: 5);

    var stress = const <String, dynamic>{};
    var insights = const <String, dynamic>{};
    var fields = <String, JournalMetricValue>{};
    var driverRows = const <DriverFacts>[];
    var specs = const <JournalFieldSpec>[];
    if (repo != null) {
      stress = await repo.getDayStress(_date);
      insights = await repo.getInsights();
      // `readiness_glassbox.breakdown`, NOT `.drivers` — drivers is already
      // filtered to the inputs that cleared the smallest-worthwhile-change
      // gate, so an input that sat inside its usual spread was never in it and
      // the screen could not say "and this one did nothing". Same array
      // ReadinessDetail renders, so the two agree by construction.
      final gb = envValue(insights['readiness_glassbox']);
      final bd = gb?['breakdown'];
      // The baselines block: centre, spread, delta and MDC per input. Written
      // on every derive since long before anything read it.
      final heart = await repo.getDayHeart(_date);
      final charts = <String, Object?>{};
      for (final k in driverChartKeys) {
        charts[k] = await repo.getChart(k);
      }
      driverRows = driverFacts(
        breakdown: [
          for (final r in (bd is List ? bd : const []))
            if (r is Map) r.cast<String, dynamic>(),
        ],
        baselines: heart['baselines'] is Map
            ? (heart['baselines'] as Map).cast<String, dynamic>()
            : null,
        charts: charts,
      );
      fields = await repo.getJournalMetrics(_date);
      specs = await repo.getJournalFields();
    }
    // Day arithmetic, not a subtracted duration: a DST day is 23 or 25 hours
    // long and `now - 13 days` lands on the wrong calendar date across one.
    final now = DateTime.now();
    final since = dayLabelOf(
      DateTime(now.year, now.month, now.day - (_habitDays - 1)),
    );
    final history = await LocalDb.journalMetricsByDay(sinceDaysEpoch: since);

    if (!stillNewest(#wellness, t)) return;
    setState(() {
      _meds = meds;
      _slots = slotsForDay(meds, _date, doses, now: DateTime.now());
      _adherence = adherence;
      _breathing = breathing;
      _stress = stress;
      _insights = insights;
      _drivers = driverRows;
      _todayFields = {...fields};
      // A habit is a custom field with a ceiling of one — a per-day yes/no.
      // That is exactly what journal_field_def already stores, which is why
      // there is no habit table.
      _habits = [
        for (final s in specs)
          if (s.custom && s.max == 1) s,
      ];
      _fields = specs;
      _habitHistory = history;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final last = _breathing.isEmpty ? null : _breathing.first;
    // `select`, not `watch`: this screen lives in the shell's IndexedStack and
    // stays mounted, so a plain watch would rebuild it on every unrelated
    // AppState notification for the life of the app.
    final showCycle =
        c.select<AppState, bool>((a) => a.cycleTrackingEnabled);
    final labels = [
      l?.wellnessTabMind ?? 'Mind',
      l?.wellnessTabRecovery ?? 'Recovery',
      l?.wellnessTabHabits ?? 'Habits',
      l?.wellnessTabMedication ?? 'Medication',
      l?.wellnessTabCycle ?? 'Cycle',
    ];
    final tabs = showCycle ? labels : labels.take(labels.length - 1).toList();
    // Clamped rather than reset: switching Cycle off while standing on it
    // lands on Medication, not back at Mind.
    final tab = _tab.clamp(0, tabs.length - 1);
    // Same rule as Workout: the LIST drops its side padding and hands it to
    // every child except the hero, which is how that one runs edge to edge.
    // The card cannot escape its own parent — a negative margin asserts and an
    // OverflowBox takes an unbounded height in a scroll view and blanks the
    // whole tab. Padding the siblings is ordinary layout and does neither.
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, S.x4, 0, S.x16),
      children: [
        for (final w in <Widget>[
          ScreenTitle(l?.wellnessTitle ?? 'Wellness'),
          SubTabs(tabs, tab, (i) => setState(() => _tab = i),
              color: C.domMind),
          const SizedBox(height: S.x5),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else ...[
            // Mind is the only tab here with something to START. The other
            // four are logs and reviews, and a "begin" card over a medication
            // list would be an invitation to nothing.
            if (tab == 0) ...[
              StartCard(
                label: l?.wellnessStartASitting ?? 'START A SITTING',
                // What the picker actually offers. Three, not the number of
                // things on this tab.
                count: kBreathPatterns.length,
                noun: l?.wellnessExercisesNoun ?? 'exercises',
                sub: last == null
                    ? (l?.wellnessPickOneAndGo ?? 'Pick one and go')
                    : (l?.wellnessLastMinutes(
                            (_reading(last['seconds']) ?? 0) ~/ 60) ??
                        'Last: ${(_reading(last['seconds']) ?? 0) ~/ 60} min'),
                asset: 'mascot_wellness.png',
                accent: C.domMind,
                deep: C.teal,
                // Sized so the CHARACTER matches Workout's, not the frame.
                // Two corrections got us here: the asset carried ~30%
                // transparent padding (cropped away), and what is left still
                // has a soft halo above the head, so the figure is 87% of the
                // frame height where the workout mascot is 100% of its own.
                // 145 x 0.87 puts the character at ~126, the same as Workout.
                // Not cropped tighter than this on purpose — the halo is nearly
                // opaque, so trimming it slices a hard arc through the artwork.
                // The 118 here was originally compensating for
                // ~30% transparent padding baked into the asset, which made
                // the art render a third smaller than the workout one at the
                // same height. The asset is cropped to its own alpha bounds,
                // so the height is the art's height and the two mascots read
                // as the same size. Still slightly wider than tall (1.03 vs
                // 0.93), and at 126 that is 130 px — narrower than the padded
                // asset was, so the copy has more room than before, not less.
                mascotHeight: 145,
                onTap: () async {
                  await Navigator.of(c).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const CalmBreathing()),
                  );
                  await _load();
                },
              ),
              const SizedBox(height: S.x4),
            ],
            [_mind, _recovery, _habitsTab, _medication, _cycle][tab](c),
          ],
        ])
          if (w is StartCard)
            w
          else
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x4),
                child: w),
      ],
    );
  }

  // ── MIND ─────────────────────────────────────────────────────────────────

  Widget _mind(BuildContext c) {
    final l = AppLocalizations.of(c);
    // Same rule as `_recovery`'s coach block, and for the same reason: this
    // runs inside `build`, so a leaf of the wrong type here costs the whole
    // screen rather than this one card. See [_reading].
    final stress = _stress['stress'];
    final score = _reading(stress is Map ? stress['score'] : null);
    final level = stress is Map && stress['level'] is String
        ? _stressLevelLabel(l, stress['level'] as String)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The "Paced breathing / Begin" ActionCard used to sit here. It is the
        // hero card above now — same destination, same last-sitting line, one
        // door instead of two.
        MoodPicker(
          value: _todayFields['mood']?.value.round(),
          onChanged: (v) => _setField('mood', v?.toDouble()),
        ),
        const SizedBox(height: S.x4),
        ActionCard(
          l?.wellnessWriteTheDayDown ?? 'Write the day down',
          // Named from the field specs the journal actually holds. The old
          // literal listed four fields and went stale the moment a custom one
          // was added.
          _journalSubtitle(l),
          l?.wellnessOpen ?? 'Open',
          LucideIcons.notebookPen,
          C.blue,
          onTap: () async {
            await Navigator.of(c).push(
              MaterialPageRoute<void>(builder: (_) => const JournalCompose()),
            );
            await _load();
          },
        ),
        Section(
          l?.wellnessStressLastNight ?? 'Stress last night',
          score == null
              // "Last night had none" was a claim about a gate this screen
              // never read — the stress payload carries no reason, so the card
              // states what stress IS and stops there.
              ? StatusCard(
                  l?.wellnessNoStressTitle ?? 'No stress reading last night',
                  l?.wellnessNoStressBody ??
                      'Stress is read from beat timing while you were resting '
                          'overnight, and last night produced no reading.',
                  icon: LucideIcons.activity,
                )
              : SignalCard(
                  LucideIcons.activity,
                  C.purple,
                  l?.wellnessAutonomicTension ?? 'Autonomic tension',
                  score.round().toString(),
                  unit: '/100',
                  sub: (level ?? '').toUpperCase(),
                ),
        ),
      ],
    );
  }

  /// What the journal will actually ask you, read off its own field specs.
  String _journalSubtitle(AppLocalizations? l) {
    // Not `.toLowerCase()`: these are user-entered/localized field labels
    // (acronyms like HRV, or nouns a language capitalizes) — lowercasing
    // them here would corrupt content the join has no business rewriting.
    final names = [for (final f in _fields) f.label];
    if (names.isEmpty) {
      return l?.wellnessJournalDefaultSubtitle ??
          'Anything you want to remember about today';
    }
    if (names.length <= 4) {
      final joined = names.join(', ');
      return l?.wellnessJournalSubtitleShort(joined) ?? '$joined and a note';
    }
    final joined = names.take(4).join(', ');
    final more = names.length - 4;
    return l?.wellnessJournalSubtitleLong(joined, more) ??
        '$joined and $more more, plus a note';
  }

  Future<void> _setField(String key, double? v) async {
    final repo = context.read<AppState>().repo;
    if (repo == null || _writingField) return;
    setState(() => _writingField = true);
    try {
      // RE-READ THE DAY, do not write from the snapshot this tab loaded with.
      //
      // `postJournalMetrics` -> `putJournalMetrics` DELETES the whole day and
      // re-inserts what it is handed, so writing a merge of `_todayFields` — a
      // copy taken when the tab last loaded — silently deleted every journal
      // field written since. Open Wellness, go and write your journal from the
      // compose screen, come back without the tab reloading, tick one habit,
      // and the journal entry was gone.
      final next = {...await repo.getJournalMetrics(_date)};
      if (v == null) {
        next.remove(key);
      } else {
        next[key] = JournalMetricValue(v);
      }
      await repo.postJournalMetrics(_date, next);
      await _wrote();
    } finally {
      if (mounted) setState(() => _writingField = false);
    }
  }

  // ── RECOVERY ─────────────────────────────────────────────────────────────

  Widget _recovery(BuildContext c) {
    final l = AppLocalizations.of(c);
    final coach = _insights['sleep_coach'];
    final coachMap = coach is Map ? coach.cast<String, dynamic>() : null;
    final needSec = _nested(coachMap, 'need', 'need_sec');
    final bedMin = _nested(coachMap, 'bedtime', 'bedtime_min_of_day');
    final wakeMin = _nested(coachMap, 'wake', 'wake_min_of_day');
    final napMin = _reading(coachMap?['nap_credit_min']);
    final strainMin = _reading(coachMap?['strain_bonus_min']);
    final debtH = _nested(_insights, 'sleep_debt', 'debt_hours');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The one recommendation on this screen, and only when all three of
        // its inputs are real: a measured debt worth acting on, a learned need,
        // and a target bedtime to name. No debt, no card — the widget does not
        // get an invented reason so that it can appear.
        if (debtH != null && debtH >= .75 && needSec != null && bedMin != null)
          Padding(
            padding: const EdgeInsets.only(bottom: S.x5),
            child: Recommendation(
              l?.wellnessTurnInBy(formatMinuteOfDay(bedMin.round())) ??
                  'Turn in by ${formatMinuteOfDay(bedMin.round())}',
              l?.wellnessDebtBody(_hm(debtH * 60), _hm(needSec / 60)) ??
                  'You are ${_hm(debtH * 60)} down against your own need, and '
                      'tonight\'s is ${_hm(needSec / 60)}.',
              l?.wellnessSeeWhatLastNightCost ?? 'See what last night cost you',
              color: C.indigo,
              onTap: () => Navigator.of(c).push(
                MaterialPageRoute<void>(builder: (_) => const SleepDetail()),
              ),
            ),
          ),
        Section(
          l?.wellnessWhatChargedAndDrained ?? 'What charged and drained you',
          // Two words and a full stop, before: "hrv", "rhr". No reading, no
          // usual, no direction, no size, and no way to tell a move that
          // mattered from one inside the noise — all of which were already
          // being written on every derive and read by nothing.
          _drivers.isEmpty
              ? StatusCard(
                  l?.wellnessNoDriversTitle ?? 'No readiness drivers yet',
                  whyFromNote(metricOf(_stress['readiness']).note) ??
                      (l?.wellnessNoDriversBody ??
                          'Needs enough nights to know what normal looks like '
                              'for you.'),
                  icon: LucideIcons.sparkles,
                )
              : DriverBreakdown(_drivers),
        ),
        Section(
          l?.wellnessSleepNeedTonight ?? 'Sleep need tonight',
          needSec == null
              // The coach's own reason for the absent need — it names the
              // input that is actually missing. "Not enough of them yet" named
              // nothing, and was printed for every cause the estimator has.
              ? StatusCard(
                  l?.wellnessNoSleepNeedTitle ?? 'No sleep need yet',
                  whyFromNote(_noteOf(coachMap?['need'])) ??
                      (l?.wellnessNoSleepNeedBody ??
                          'Nothing recorded says why there is no need for '
                              'tonight.'),
                  icon: LucideIcons.bedDouble,
                )
              : Surface(
                  child: Column(
                    children: [
                      MetricRow(
                        LucideIcons.bedDouble,
                        C.blue,
                        l?.wellnessTonightsNeed ?? 'Tonight\'s need',
                        _hm(needSec / 60),
                      ),
                      // Null here means "we do not know", which is why it is a
                      // missing row rather than "+0 min".
                      if (debtH != null)
                        MetricRow(
                          LucideIcons.trendingDown,
                          C.orange,
                          l?.wellnessSleepDebt ?? 'Sleep debt',
                          _hm(debtH * 60),
                        ),
                      if (strainMin != null)
                        MetricRow(
                          LucideIcons.flame,
                          C.purple,
                          l?.wellnessAddedForStrain ?? 'Added for strain',
                          '${strainMin.round()}',
                          unit: 'min',
                        ),
                      if (napMin != null)
                        MetricRow(
                          LucideIcons.sun,
                          C.yellow,
                          l?.wellnessCreditedFromNaps ?? 'Credited from naps',
                          '${napMin.round()}',
                          unit: 'min',
                        ),
                      if (bedMin != null)
                        MetricRow(
                          LucideIcons.moon,
                          C.indigo,
                          l?.wellnessTargetBedtime ?? 'Target bedtime',
                          formatMinuteOfDay(bedMin.round()),
                        ),
                      if (wakeMin != null)
                        MetricRow(
                          LucideIcons.sunrise,
                          C.orange,
                          l?.wellnessTargetWake ?? 'Target wake',
                          formatMinuteOfDay(wakeMin.round()),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // ── CYCLE ────────────────────────────────────────────────────────────────

  /// Owns its own load: the tab is off for most users and its query touches two
  /// tables plus 120 derived days, which nobody should pay for by opening Mind.
  Widget _cycle(BuildContext c) => const CycleTab();

  // ── HABITS ───────────────────────────────────────────────────────────────

  Widget _habitsTab(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final h in _habits)
          Padding(
            padding: const EdgeInsets.only(bottom: S.x3),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          h.label,
                          style: F.body.copyWith(
                            color: p.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // A habit you typed had no way out short of "Delete
                      // everything": the delete path existed end to end and
                      // nothing reached it.
                      Pressable(
                        semanticLabel:
                            l?.wellnessRemoveHabitSemantic(h.label) ??
                                'Remove ${h.label}',
                        onTap: () => _confirmRemoveHabit(h),
                        child: Padding(
                          padding: const EdgeInsets.only(right: S.x3),
                          child: Icon(
                            LucideIcons.trash2,
                            size: 18,
                            color: p.ink3,
                          ),
                        ),
                      ),
                      _Check(
                        on: (_todayFields[h.key]?.value ?? 0) >= 1,
                        // Null while a write is in flight: the tick is a
                        // read-modify-write of the whole day, and a second tap
                        // during the first one used to erase it.
                        onTap: _writingField
                            ? null
                            : () => _setField(
                                h.key,
                                (_todayFields[h.key]?.value ?? 0) >= 1
                                    ? null
                                    : 1,
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: S.x3),
                  Consistency(
                    _habitDaysDone(h.key),
                    _habitDays,
                    l?.wellnessDaysYouDidIt ?? 'Days you did it',
                    C.domMind,
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: S.x4),
        BigButton(
          l?.wellnessAddAHabit ?? 'Add a habit',
          icon: LucideIcons.plus,
          color: C.domMind,
          soft: true,
          onTap: () => _addHabit(c),
        ),
        // MIND-01/04/12 — the whole dose-response and habit-difference half of
        // journal analysis, plus the weekday test, behind ONE door. It has
        // lived here computed-and-discarded for months; putting the rows on
        // this tab would bury the thing the tab is for, which is ticking.
        const SizedBox(height: S.x5),
        ActionCard(
          l?.wellnessWhatYouLogTitle ?? 'What you log, against your numbers',
          l?.wellnessWhatYouLogSubtitle ??
              'Dose, habit difference, and the day of the week',
          l?.wellnessOpen ?? 'Open',
          LucideIcons.scatterChart,
          C.domMind,
          onTap: () => Navigator.of(c).push(
            MaterialPageRoute<void>(builder: (_) => const JournalFindings()),
          ),
        ),
      ],
    );
  }

  int _habitDaysDone(String key) {
    var n = 0;
    for (final day in _habitHistory.values) {
      if ((day[key]?.value ?? 0) >= 1) n++;
    }
    return n;
  }

  /// Remove the habit, keep its history.
  ///
  /// `journal_field_def` deliberately keeps a deleted field's recorded values
  /// (see db.dart's note on the table) — they were real answers. A "delete"
  /// that quietly keeps data is as much of a surprise as one that quietly loses
  /// it, so the confirm says which this is.
  Future<void> _confirmRemoveHabit(JournalFieldSpec h) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmRemove(
      context,
      title: l?.wellnessRemoveHabitConfirmTitle(h.label) ??
          'Remove ${h.label}?',
      body: l?.wellnessRemoveHabitConfirmBody ??
          'It stops being asked. The days you already recorded stay.',
    );
    if (!ok || !mounted) return;
    final repo = context.read<AppState>().repo;
    if (repo == null) return;
    await repo.deleteCustomJournalField(h.key);
    await _load();
  }

  Future<void> _addHabit(BuildContext c) async {
    final l = AppLocalizations.of(c);
    final name = await _askName(
      c,
      l?.wellnessAddAHabit ?? 'Add a habit',
      l?.wellnessHabitHint ?? 'Walk after lunch',
    );
    if (name == null || name.isEmpty || !mounted) return;
    final repo = context.read<AppState>().repo;
    if (repo == null) return;
    try {
      await repo.postCustomJournalField(
        JournalFieldSpec(
          key: customJournalFieldKey(name),
          label: name,
          kind: JournalFieldKind.rating,
          unit: '',
          max: 1,
          step: 1,
          custom: true,
        ),
      );
    } on StateError catch (_) {
      // putJournalFieldDef is create-only now — a duplicate lands here
      // instead of silently rewriting the first one's definition.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)?.wellnessAlreadyTrack(name) ??
                  'You already track "$name".',
            ),
          ),
        );
        return;
      }
    }
    await _load();
  }

  // ── MEDICATION ───────────────────────────────────────────────────────────

  Widget _medication(BuildContext c) {
    final l = AppLocalizations.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_meds.isEmpty)
          StatusCard(
            l?.wellnessNothingScheduledTitle ?? 'Nothing scheduled',
            l?.wellnessNothingScheduledBody ?? 'Add what you take and when.',
            fix: l?.wellnessAddAMedication ?? 'Add a medication',
            icon: LucideIcons.pill,
            onFix: () => _addMed(c),
          )
        else ...[
          // A medication with no slot TODAY is not an empty screen. It happens
          // for ordinary reasons — the days exclude today, the time had already
          // passed when it was added (`slotsForDay` will not invent a slot
          // behind you), or the day being viewed is not today — and every one
          // of them used to render an empty `Surface`: added a medication, no
          // tracker, nothing said. Absence states its reason, and the schedule
          // itself is the reason, so it is what gets printed.
          if (_slots.isEmpty) ...[
            StatusCard(
              l?.wellnessNothingDueTodayTitle ?? 'Nothing due today',
              l?.wellnessNothingDueTodayBody ??
                  'What you take is scheduled for other days or times.',
              icon: LucideIcons.pill,
            ),
            const SizedBox(height: S.x3),
            Surface(
              pad: const EdgeInsets.symmetric(vertical: S.x2),
              child: Column(
                children: [
                  for (final d in _meds)
                    for (final sch in d.schedule) _scheduleRow(c, d, sch),
                ],
              ),
            ),
          ] else
            Surface(
              pad: const EdgeInsets.symmetric(horizontal: S.x4),
              child: Column(
                children: [
                  for (final s in _slots)
                    MedRow(
                      slot: s,
                      onTap: () => _markDose(s),
                      // Everything that is not "I took it" lives behind here:
                      // skipping a dose on purpose, fixing the days it is due,
                      // and the exit for a course you finished — which used to
                      // keep coming due every day with nothing but "Delete
                      // everything" to stop it.
                      onMore: () => _medActions(c, s),
                    ),
                ],
              ),
            ),
          Section(
            l?.wellnessAdherence ?? 'Adherence',
            // An empty denominator is not an adherence of nothing. Consistency
            // would print "0 of 0 days" with an empty bar under it, which reads
            // as a failure; the reason is the honest answer until a dose has
            // actually come due.
            _adherence.of == 0
                ? StatusCard(
                    l?.wellnessNothingToScoreTitle ?? 'Nothing to score yet',
                    l?.wellnessNothingToScoreBody ??
                        'No scheduled doses have come due yet.',
                    icon: LucideIcons.pill,
                  )
                : Surface(
                    child: Consistency(
                      _adherence.taken,
                      _adherence.of,
                      l?.wellnessTakenOfScheduled ??
                          'Taken, of those scheduled in the last seven days.',
                      C.blue,
                      // Doses, not days — three a day over a week is 21 of
                      // them inside a seven-day window.
                      unit: l?.wellnessDosesUnit ?? 'doses',
                    ),
                  ),
          ),
          const SizedBox(height: S.x4),
          BigButton(
            l?.wellnessAddAMedication ?? 'Add a medication',
            icon: LucideIcons.plus,
            color: C.domMind,
            soft: true,
            onTap: () => _addMed(c),
          ),
        ],
      ],
    );
  }

  /// One scheduled time that is not due today: what it is, and when it is due.
  ///
  /// Tapping goes straight to the schedule and NOT to `_medActions` — a slot
  /// that is not due cannot be taken or skipped, and offering either would
  /// write a dose row for a day the medication was never scheduled on.
  /// Changing when it is due is the only honest action here, and it is also
  /// the one that brings the tracker back.
  Widget _scheduleRow(BuildContext c, MedDef d, MedSchedule sch) {
    final slot = MedSlot(
      def: d,
      date: _date,
      slotMin: sch.minuteOfDay,
      state: DoseState.upcoming,
    );
    return _SheetAction(
      LucideIcons.pill,
      d.label,
      // `timeLabel`, so the two halves of this tab print a time the same way.
      sub: '${_daysLabel(c, sch.days)} · ${slot.timeLabel}',
      onTap: () => _editSchedule(c, slot),
    );
  }

  Future<void> _markDose(MedSlot s) async {
    final db = await LocalDb.instance;
    await MedDb.mark(
      db,
      medKey: s.def.key,
      date: s.date,
      slotMin: s.slotMin,
      taken: s.state != DoseState.taken,
    );
    await _wrote();
  }

  /// A dose deliberately NOT taken.
  ///
  /// `DoseState.skipped` has been in the enum, the schema and the row label
  /// since the store was written and nothing could ever enter it: `mark`'s only
  /// caller never passed `skipped`, so every untaken dose read back as
  /// `missed`. The count does not change — `adherence()` counts by decided, and
  /// both are decided-and-not-taken — but "I chose not to" and "I forgot" are
  /// not the same fact about a medication, and the user could not record the
  /// difference or correct it afterwards.
  Future<void> _skipDose(MedSlot s) async {
    final db = await LocalDb.instance;
    await MedDb.mark(
      db,
      medKey: s.def.key,
      date: s.date,
      slotMin: s.slotMin,
      taken: false,
      skipped: s.state != DoseState.skipped,
    );
    await _wrote();
  }

  Future<void> _medActions(BuildContext c, MedSlot s) async {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final skipped = s.state == DoseState.skipped;
    await showModalBottomSheet<void>(
      context: c,
      backgroundColor: p.card,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(S.x5, 0, S.x5, S.x3),
              child: Text(
                '${s.def.label} · ${s.timeLabel}',
                style: F.head.copyWith(color: p.ink),
              ),
            ),
            _SheetAction(
              LucideIcons.circleSlash,
              skipped
                  ? (l?.wellnessUndoSkipped ?? 'Undo skipped')
                  : (l?.wellnessSkippedOnPurpose ?? 'Skipped on purpose'),
              sub: skipped
                  ? (l?.wellnessBackToNotTaken ?? 'Back to not taken.')
                  : (l?.wellnessRecordedAsDecision ??
                      'Recorded as a decision, not a miss.'),
              onTap: () {
                Navigator.of(sheet).pop();
                _skipDose(s);
              },
            ),
            _SheetAction(
              LucideIcons.calendarDays,
              l?.wellnessWhichDaysDue ?? 'Which days it is due',
              sub: _daysLabel(c, _daysFor(s)),
              onTap: () {
                Navigator.of(sheet).pop();
                _editSchedule(c, s);
              },
            ),
            _SheetAction(
              LucideIcons.trash2,
              l?.wellnessRemoveMedTitle(s.def.label) ??
                  'Remove ${s.def.label}',
              sub: l?.wellnessRemoveMedBody ??
                  'It stops being scheduled. Marked doses stay.',
              onTap: () {
                Navigator.of(sheet).pop();
                _confirmRemoveMed(s.def);
              },
            ),
            const SizedBox(height: S.x4),
          ],
        ),
      ),
    );
  }

  /// The weekdays THIS slot is due on. An empty list means every day — that is
  /// `MedSchedule.onDay`'s own rule, not a guess made here.
  List<int> _daysFor(MedSlot s) {
    for (final sch in s.def.schedule) {
      if (sch.minuteOfDay == s.slotMin) {
        return sch.days.isEmpty ? const [1, 2, 3, 4, 5, 6, 7] : sch.days;
      }
    }
    return const [1, 2, 3, 4, 5, 6, 7];
  }

  Future<void> _editSchedule(BuildContext c, MedSlot s) async {
    final picked = await pickMedSchedule(
      c,
      minuteOfDay: s.slotMin,
      days: _daysFor(s),
    );
    if (picked == null || !mounted) return;
    // Only THIS slot is rewritten. A medication with a morning and an evening
    // dose keeps the other one exactly as it was.
    final rest = [
      for (final sch in s.def.schedule)
        if (sch.minuteOfDay != s.slotMin) sch,
    ];
    await MedDb.putDef(
      await LocalDb.instance,
      MedDef(
        key: s.def.key,
        label: s.def.label,
        doseValue: s.def.doseValue,
        doseUnit: s.def.doseUnit,
        kind: s.def.kind,
        note: s.def.note,
        active: s.def.active,
        createdAt: s.def.createdAt,
        schedule: [...rest, MedSchedule(picked.minuteOfDay, picked.days)],
      ),
    );
    await _wrote();
  }

  /// Remove the medication, keep the doses.
  ///
  /// `MedDb.deleteDef` keeps `med_dose` on purpose (see its note): those doses
  /// were taken, and the CSV export still carries them. What stops is the
  /// schedule — and with it the empty denominator that was dragging adherence
  /// down every day after the course ended.
  Future<void> _confirmRemoveMed(MedDef d) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmRemove(
      context,
      title: l?.wellnessRemoveMedConfirmTitle(d.label) ??
          'Remove ${d.label}?',
      body: l?.wellnessRemoveMedConfirmBody ??
          'It stops being scheduled and stops counting towards adherence. '
              'The doses you already marked stay.',
    );
    if (!ok || !mounted) return;
    await MedDb.deleteDef(await LocalDb.instance, d.key);
    await _wrote();
  }

  Future<void> _addMed(BuildContext c) async {
    final l = AppLocalizations.of(c);
    final name = await _askName(
      c,
      l?.wellnessAddAMedication ?? 'Add a medication',
      l?.wellnessMedHint ?? 'Vitamin D',
    );
    if (name == null || name.isEmpty) return;
    if (!c.mounted) return;
    // The weekdays used to be hardcoded to all seven with no way back in, so a
    // Monday-and-Thursday drug generated five phantom slots a week that
    // resolved as missed and went into adherence's denominator — a wrong number
    // on screen, produced by the app rather than by the person.
    final picked = await pickMedSchedule(c);
    if (picked == null || !mounted) return;
    await MedDb.putDef(
      await LocalDb.instance,
      MedDef(
        key: MedDb.keyFor(name),
        label: name,
        // Dose is left null — "as directed" is a real answer, and demanding a
        // number to get a reminder is how a checklist stops being used.
        schedule: [MedSchedule(picked.minuteOfDay, picked.days)],
      ),
    );
    await _wrote();
  }

  Future<String?> _askName(BuildContext c, String title, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: c,
      builder: (d) {
        final l = AppLocalizations.of(d);
        return AlertDialog(
          backgroundColor: P.of(d).card,
          title: Text(title, style: F.head.copyWith(color: P.of(d).ink)),
          content: OsTextField(
            controller: ctrl,
            label: l?.wellnessNameLabel ?? 'Name',
            hint: hint,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(d).pop(),
              child: Text(
                l?.actionCancel ?? 'Cancel',
                style: F.body.copyWith(color: P.of(d).ink2),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(d).pop(ctrl.text.trim()),
              child: Text(
                l?.wellnessAdd ?? 'Add',
                style: F.body.copyWith(color: P.of(d).on(C.domMind)),
              ),
            ),
          ],
        );
      },
    ).whenComplete(ctrl.dispose);
  }
}

// ── helpers ────────────────────────────────────────────────────────────────

/// Pull a number out of a nested `Metric` envelope whose `value` is itself an
/// object — `{value: {need_sec: …}}`. Returns null rather than parsing the
/// envelope as a scalar, which would read a real value object as an absence.
double? _nested(Map<String, dynamic>? blk, String key, String field) {
  final m = blk?[key];
  if (m is! Map) return null;
  final v = m['value'];
  return _reading(v is Map ? v[field] : v);
}

/// A stored leaf as a number this screen can print, or null.
///
/// TESTED, NEVER CAST, and the finite check is not belt-and-braces. Every
/// caller of this is evaluated inside `_recovery`, which `build` CALLS — so a
/// throw here is not a broken card, it is `WellnessScreen.build` failing, the
/// whole domain replaced by an `ErrorWidget`, and `RenderErrorBox` painting
/// `0xF0C0C0C0` over the page. On a release build that is a flat grey screen
/// with a working nav bar beside it and nothing anywhere that says why.
///
/// Two ways in, and neither is hypothetical enough to leave open:
///   · `x as num?` tolerates null and NOTHING ELSE, so one leaf stored as a
///     String — an older artifact, a hand-edited backup, an import — throws.
///   · `.round()` throws `UnsupportedError` on NaN and infinity, and every
///     number here is rounded a few lines later (`_hm`, `formatMinuteOfDay`,
///     the strain and nap rows). `1e999` in JSON decodes to `Infinity`.
///
/// The write seam already learned this: `sanitizeForJson` nulls a non-finite
/// leaf rather than letting `jsonEncode` throw, because "the artifact is a bag
/// of independent metrics, so it must degrade one field at a time". Same rule,
/// read side. A leaf we cannot read is ABSENT — which every branch below
/// already renders honestly — instead of costing the screen.
double? _reading(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

/// The `note` off a metric envelope, when there is one and it is prose.
///
/// `(x as Map?)?['note'] as String?` was two unguarded casts on the ABSENCE
/// branch — the one that renders for every account that has no learned sleep
/// need yet, which is the widest audience this screen has.
String? _noteOf(Object? envelope) {
  if (envelope is! Map) return null;
  final note = envelope['note'];
  return note is String ? note : null;
}

String _hm(double minutes) {
  final sign = minutes < 0 ? '−' : '';
  final t = minutes.abs().round();
  return t < 60 ? '$sign${t}m' : '$sign${t ~/ 60}h ${t % 60}m';
}

/// A label and a sentence. Used by journal findings and habit effects, both of
/// which genuinely have only those two things.
///
/// It is NOT the readiness driver row any more — that claim ("the glass box
/// does not emit per-driver point contributions") was wrong, and it is what
/// kept "What charged and drained you" printing two bare words. The breakdown
/// carries a weight, a signed contribution and a spread gate per input, and
/// the baselines block carries the reading, the centre, the spread and the MDC.
/// See [DriverBreakdown].
class DriverRow extends StatelessWidget {
  const DriverRow({super.key, required this.label, required this.detail});

  final String label, detail;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.dot, size: 18, color: p.on(C.domMind)),
          const SizedBox(width: S.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: F.body.copyWith(color: p.ink)),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: F.over.copyWith(color: p.ink3, height: 1.4),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The pinned analytics package returns 'low'/'normal'/'elevated'/'high' —
/// English regardless of locale. Map to the localized word before display.
String? _stressLevelLabel(AppLocalizations? l, String raw) {
  switch (raw) {
    case 'low':
      return l?.wellnessStressLevelLow ?? raw;
    case 'normal':
      return l?.wellnessStressLevelNormal ?? raw;
    case 'elevated':
      return l?.wellnessStressLevelElevated ?? raw;
    case 'high':
      return l?.wellnessStressLevelHigh ?? raw;
    default:
      return raw;
  }
}

/// The days a dose is due, in the words a person would use. `DateTime.weekday`
/// values, 1 = Monday; empty means every day.
String _daysLabel(BuildContext c, List<int> days) {
  final l = AppLocalizations.of(c);
  final set = days.toSet();
  if (set.isEmpty || set.length == 7) return l?.wellnessEveryDay ?? 'Every day';
  if (set.length == 5 && !set.contains(6) && !set.contains(7)) {
    return l?.wellnessWeekdays ?? 'Weekdays';
  }
  if (set.length == 2 && set.contains(6) && set.contains(7)) {
    return l?.wellnessWeekends ?? 'Weekends';
  }
  final sorted = set.toList()..sort();
  return [for (final d in sorted) weekdayShortName(d, l)].join(', ');
}

/// Pick a time and the weekdays it repeats on. Returns null if dismissed.
///
/// One sheet for BOTH the add flow and the edit path, because a schedule the
/// user can enter but not correct is the shape of bug this replaced: the app
/// wrote seven days a week whatever the drug was, and then counted the days it
/// invented against the person taking it.
Future<MedSchedule?> pickMedSchedule(
  BuildContext c, {
  int minuteOfDay = 8 * 60,
  List<int> days = const [1, 2, 3, 4, 5, 6, 7],
}) async {
  var minute = minuteOfDay;
  var picked = days.toSet();
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  return showModalBottomSheet<MedSchedule>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: StatefulBuilder(
        builder: (sheet, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(S.x5, 0, S.x5, S.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l?.wellnessWhenYouTakeIt ?? 'When you take it',
                style: F.head.copyWith(color: p.ink),
              ),
              const SizedBox(height: S.x4),
              Pressable(
                semanticLabel: l?.wellnessChangeTheTime ?? 'Change the time',
                onTap: () async {
                  final at = await showTimePicker(
                    context: sheet,
                    initialTime: TimeOfDay(
                      hour: (minute ~/ 60) % 24,
                      minute: minute % 60,
                    ),
                  );
                  if (at != null) {
                    setSheet(() => minute = at.hour * 60 + at.minute);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(S.x4),
                  decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
                  child: Row(
                    children: [
                      Icon(LucideIcons.clock, size: 17, color: p.ink3),
                      const SizedBox(width: S.x3),
                      Expanded(
                        child: Text(
                          '${(minute ~/ 60).toString().padLeft(2, '0')}:'
                          '${(minute % 60).toString().padLeft(2, '0')}',
                          style: F.n17.copyWith(color: p.ink),
                        ),
                      ),
                      Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: S.x4),
              Text(
                l?.wellnessWhichDays ?? 'WHICH DAYS',
                style: F.over.copyWith(color: p.ink3),
              ),
              const SizedBox(height: S.x2),
              Wrap(
                spacing: S.x2,
                runSpacing: S.x2,
                children: [
                  for (var d = 1; d <= 7; d++)
                    Pressable(
                      semanticLabel: weekdayShortName(d, l),
                      onTap: () => setSheet(() {
                        picked.contains(d) ? picked.remove(d) : picked.add(d);
                      }),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                          horizontal: S.x4,
                          vertical: S.x2,
                        ),
                        decoration: BoxDecoration(
                          color: picked.contains(d)
                              ? p.wash(C.domMind)
                              : p.card2,
                          borderRadius: R.rPill,
                          border: Border.all(
                            color: picked.contains(d)
                                ? p.on(C.domMind)
                                : p.line,
                          ),
                        ),
                        child: Text(
                          weekdayShortName(d, l),
                          style: F.cap.copyWith(
                            color: picked.contains(d)
                                ? p.on(C.domMind)
                                : p.ink2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: S.x3),
              // A schedule with no days is not a schedule. Saying so beats
              // saving one that can never come due.
              Text(
                picked.isEmpty
                    ? (l?.wellnessPickAtLeastOneDay ?? 'Pick at least one day.')
                    : (l?.wellnessDueDays(_daysLabel(c, picked.toList())) ??
                        'Due ${_daysLabel(c, picked.toList()).toLowerCase()}.'),
                style: F.cap.copyWith(color: p.ink3),
              ),
              const SizedBox(height: S.x4),
              BigButton(
                l?.actionSave ?? 'Save',
                color: C.domMind,
                onTap: picked.isEmpty
                    ? null
                    : () => Navigator.of(sheet).pop(
                        MedSchedule(minute, picked.toList()..sort()),
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SheetAction extends StatelessWidget {
  const _SheetAction(this.icon, this.title, {this.sub = '', this.onTap});
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.x5, vertical: S.x3),
        child: Row(
          children: [
            Icon(icon, size: 17, color: p.ink3),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: F.body.copyWith(color: p.ink)),
                  if (sub.isNotEmpty)
                    Text(sub, style: F.cap.copyWith(color: p.ink3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One scheduled dose. A slot still ahead of you reads as upcoming, never as a
/// miss — that distinction is the whole reason `taken_ts` is nullable.
class MedRow extends StatelessWidget {
  const MedRow({super.key, required this.slot, this.onTap, this.onMore});

  final MedSlot slot;
  final VoidCallback? onTap;

  /// Everything that is not "I took it": skip, reschedule, remove. Null hides
  /// the control. There is no long-press or swipe here on purpose — `Pressable`
  /// is the app's only gesture, so a second action needs a second target.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final taken = slot.state == DoseState.taken;
    return Pressable(
      onTap: onTap,
      semanticLabel: l?.wellnessMedAtTime(slot.def.label, slot.timeLabel) ??
          '${slot.def.label} at ${slot.timeLabel}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: p.wash(C.blue),
                borderRadius: R.rMd,
              ),
              child: Icon(LucideIcons.pill, size: 17, color: p.on(C.blue)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    slot.def.label,
                    style: F.body.copyWith(color: taken ? p.ink3 : p.ink),
                  ),
                  Text(
                    '${slot.def.doseLabel} · ${slot.timeLabel} · '
                    '${_stateLabel(l, slot.state)}',
                    style: F.over.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
            if (onMore != null)
              Pressable(
                semanticLabel:
                    l?.wellnessMoreForMed(slot.def.label) ??
                        'More for ${slot.def.label}',
                onTap: onMore,
                child: Padding(
                  padding: const EdgeInsets.only(right: S.x3),
                  child: Icon(LucideIcons.ellipsis, size: 18, color: p.ink3),
                ),
              ),
            _Check(on: taken, onTap: null),
          ],
        ),
      ),
    );
  }

  static String _stateLabel(AppLocalizations? l, DoseState s) => switch (s) {
    DoseState.taken => l?.wellnessStateTaken ?? 'taken',
    DoseState.skipped => l?.wellnessStateSkipped ?? 'skipped',
    DoseState.missed => l?.wellnessStateNotTaken ?? 'not taken',
    DoseState.upcoming => l?.wellnessStateDueLater ?? 'due later',
  };
}

class _Check extends StatelessWidget {
  const _Check({required this.on, required this.onTap});
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final box = AnimatedContainer(
      duration: motion(c, Motion.base),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? p.fill(C.green) : p.card2,
        border: on ? null : Border.all(color: p.line, width: 1.6),
      ),
      child: on
          ? Icon(LucideIcons.check, size: 15, color: p.inkOnFill)
          : const SizedBox.shrink(),
    );
    if (onTap == null) return box;
    final l = AppLocalizations.of(c);
    return Pressable(
      semanticLabel: on
          ? (l?.actionDone ?? 'Done')
          : (l?.wellnessMarkDone ?? 'Mark done'),
      onTap: onTap,
      child: box,
    );
  }
}

// ══════════════════ WHAT YOU LOG, AGAINST YOUR NUMBERS ══════════════════
//
// MIND-01 (dose response), MIND-04 (habits), MT-06 (caffeine timing),
// MT-07 (alcohol phrasing) and MIND-12 (weekday) all answer the same question
// from the same place, so they are one screen behind one tap rather than five
// cards competing on the Habits tab.
//
// EVERYTHING HERE IS ASSOCIATION ON YOUR OWN DAYS. Never cause, never a
// recommendation, never a nudge. The confound is total and stated: the days you
// do a thing are days you were already that kind of day.
//
// The empty state is the DEFAULT outcome, not an error. 9 built-in numeric
// fields × 4 outcomes is 36 simultaneous tests, so a per-test gate manufactures
// about two findings per user out of pure noise; analytics corrects the whole
// grid with Benjamini-Hochberg and most people will see nothing. A screen that
// cannot say "nothing separated itself" is a screen that will invent something.

class JournalFindings extends StatefulWidget {
  /// Non-null skips the repository, the way every other detail screen here
  /// takes its fixture.
  final List<Map<String, dynamic>>? rows;
  final Map<String, dynamic>? weekday;

  const JournalFindings({super.key, this.rows, this.weekday});

  @override
  State<JournalFindings> createState() => _JournalFindingsState();
}

class _JournalFindingsState extends State<JournalFindings> {
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _weekday = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.rows != null) {
      _rows = widget.rows!;
      _weekday = widget.weekday ?? const {};
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final repo = context.read<AppState>().repo;
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final j = await repo.getJournalInsights(range: '90d');
      final w = await repo.getWeekdayEffect();
      if (!mounted) return;
      setState(() {
        _rows = [
          for (final e in (j['numeric_insights'] as List? ?? const []))
            if (e is Map) e.cast<String, dynamic>(),
        ];
        _weekday = w;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final title = l?.wellnessWhatYouLogScreenTitle ?? 'What you log';
    if (_loading) {
      return detailScaffold(c, title, const [
        SizedBox(height: S.x8),
        Center(child: CircularProgressIndicator()),
      ]);
    }
    final p = P.of(c);
    final doses = [
      for (final r in _rows)
        if (r['binary'] != true) r,
    ];
    final habits = [
      for (final r in _rows)
        if (r['binary'] == true) r,
    ];
    return detailScaffold(c, title, [
      const SizedBox(height: S.x2),
      if (_rows.isEmpty)
        StatusCard(
          l?.wellnessNothingSeparatedTitle ?? 'Nothing separated itself yet',
          l?.wellnessNothingSeparatedBody ??
              'Everything you log is tested against your recovery, HRV, '
                  'resting heart rate and sleep efficiency. Nothing has '
                  'cleared the bar yet.',
          icon: LucideIcons.scatterChart,
        )
      else ...[
        if (habits.isNotEmpty)
          Section(
            l?.wellnessTheDaysYouDidIt ?? 'The days you did it',
            _list(c, habits),
          ),
        if (doses.isNotEmpty)
          Section(
            l?.wellnessHowMuchAndWhatFollowed ?? 'How much, and what followed',
            _list(c, doses),
          ),
        const SizedBox(height: S.x2),
        Text(
          l?.wellnessLinkNeverCause ??
              'A link on your own days — never a cause. The days you do a '
                  'thing are days you were already that kind of day.',
          style: F.over.copyWith(color: p.ink3, height: 1.5),
        ),
      ],
      Section(
        l?.wellnessWhichDayOfWeek ?? 'Which day of the week',
        _weekdayCard(c),
      ),
    ]);
  }

  Widget _list(BuildContext c, List<Map<String, dynamic>> rows) {
    final l = AppLocalizations.of(c);
    return Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4),
      child: Column(
        children: [
          for (final r in rows)
            DriverRow(label: _headline(l, r), detail: _detail(l, r)),
        ],
      ),
    );
  }

  // ── copy ────────────────────────────────────────────────────────────────

  /// MT-07's whole change: the outcome's own units on the days she logged it,
  /// not a rank correlation read out loud. "On the 11 nights you logged
  /// alcohol, your resting HR ran 6 bpm higher" is the same finding the rho
  /// carried and a sentence a person can check against their own memory.
  String _headline(AppLocalizations? l, Map<String, dynamic> r) {
    final field = (r['field_label'] ?? '').toString();
    final outcome = (r['outcome_label'] ?? '').toString();
    final unit = (r['unit'] ?? '').toString();
    if (r['binary'] == true) {
      final delta = (r['delta'] as num?)?.toDouble() ?? 0;
      final direction = delta > 0
          ? (l?.wellnessHigher ?? 'higher')
          : (l?.wellnessLower ?? 'lower');
      final n = '${r['n_with']}';
      final amount = _amount(delta.abs(), unit);
      return l?.wellnessHeadlineBinary(n, field, outcome, amount, direction) ??
          'On the $n days you logged $field, $outcome ran $amount $direction';
    }
    final n = '${r['n']}';
    final slope = (r['slope_per_unit'] as num?)?.toDouble();
    final rho = (r['rho'] as num?)?.toDouble() ?? 0;
    if (slope == null) {
      final direction = rho > 0
          ? (l?.wellnessHigher ?? 'higher')
          : (l?.wellnessLower ?? 'lower');
      return l?.wellnessHeadlineNoSlope(n, field, direction, outcome) ??
          'On the $n days you logged $field, more of it went with '
              '$direction $outcome';
    }
    final (per, step) = _perUnit(l, r);
    final direction = slope > 0
        ? (l?.wellnessHigher ?? 'higher')
        : (l?.wellnessLower ?? 'lower');
    final amount = _amount((slope * per).abs(), unit);
    return l?.wellnessHeadlineSlope(n, field, outcome, amount, direction, step) ??
        'On the $n days you logged $field, $outcome ran '
            '$amount $direction per $step';
  }

  /// MIND-02 — WHICH NIGHT this row is about.
  ///
  /// Outcomes labelled with a date come from the night that ENDED on that
  /// morning, while the journal row is written at bedtime and describes the
  /// daytime. So analytics pairs each field at its own lag: behaviour (coffee,
  /// alcohol, water, steps) lands on the night that FOLLOWS, and a
  /// retrospective self-report (mood, sleep quality, soreness) already
  /// describes the night that just finished. It is never a blanket shift — the
  /// two kinds point in opposite directions and one constant breaks half of
  /// them.
  ///
  /// Said out loud on every row, because the alignment changed underneath
  /// findings people had already read, and a finding that quietly means a
  /// different night is a different finding.
  String _alignment(AppLocalizations? l, Map<String, dynamic> r) {
    // Read from the same constant analytics paired on, so the sentence cannot
    // drift away from the arithmetic.
    final field = (r['field'] ?? '').toString();
    // The two derived caffeine-timing keys carry caffeine's own lag.
    final lag =
        journalFieldLagDays[field] ??
        (field.startsWith('caffeine') ? journalFieldLagDays['caffeine'] : null);
    if (lag == null) {
      return l?.wellnessMatchedSameDay ?? 'Matched against the same day\'s numbers.';
    }
    return lag > 0
        ? (l?.wellnessMatchedNightFollowed ??
            'Matched against the night that followed.')
        : (l?.wellnessMatchedNightEnded ??
            'Matched against the night that ended that morning.');
  }

  String _detail(AppLocalizations? l, Map<String, dynamic> r) {
    final when = _alignment(l, r);
    if (r['binary'] == true) {
      final d = (r['cohens_d'] as num?)?.toDouble();
      final n = '${r['n_without']}';
      final against = l?.wellnessAgainstDaysYouDidNot(n) ??
          'Against the $n days you did not';
      return '$against'
          '${d == null ? '' : ' · d ${d.abs().toStringAsFixed(1)}'}. $when';
    }
    final lo = (r['rho_low'] as num?)?.toDouble();
    final hi = (r['rho_high'] as num?)?.toDouble();
    final rho = (r['rho'] as num?)?.toDouble();
    final ci = (lo == null || hi == null)
        ? ''
        : ' (${l?.wellnessRangeTo(lo.toStringAsFixed(2), hi.toStringAsFixed(2)) ?? '${lo.toStringAsFixed(2)} to ${hi.toStringAsFixed(2)}'})';
    final base = rho == null
        ? ''
        : (l?.wellnessRankCorrelation(rho.toStringAsFixed(2), ci) ??
            'Rank correlation ${rho.toStringAsFixed(2)}$ci. ');
    // MT-06's own ceiling, said where the finding is: `at_min` is the LAST
    // occurrence, so timing cannot tell two coffees from five, and a late
    // stressful day produces both the late coffee and the bad night.
    if (r['field'] == 'caffeine_last_min') {
      return '$base$when ${l?.wellnessCaffeineCaveat ?? 'This is your last '
          'caffeine of the day only — two cups and five look identical '
          'here, so "later" can quietly mean "more". A long, stressful day '
          'produces both the late coffee and the poor night.'}';
    }
    return '$base$when'.trim();
  }

  /// How to say one step of this field. Minutes-past-midnight is unreadable per
  /// minute, so caffeine timing is stated per HOUR later — a slope, never a
  /// cutoff time, which is a threshold read off a dozen self-reported points.
  (double, String) _perUnit(AppLocalizations? l, Map<String, dynamic> r) {
    if (r['field'] == 'caffeine_last_min') {
      return (60.0, l?.wellnessHourLater ?? 'hour later');
    }
    final u = (r['field_unit'] ?? '').toString();
    // Singular: the phrase is "per unit", "per mg", "per point".
    final one = u.isEmpty
        ? (l?.wellnessPointUnit ?? 'point')
        : (u.endsWith('s') ? u.substring(0, u.length - 1) : u);
    return (1.0, one);
  }

  String _amount(double v, String unit) {
    final n = v >= 10 ? v.round().toString() : v.toStringAsFixed(1);
    return unit.isEmpty ? n : '$n $unit';
  }

  // ── MIND-12 ─────────────────────────────────────────────────────────────

  /// Two gates, and both of them refusing is the normal answer. Kruskal-Wallis
  /// across the seven groups, then a permutation test on the biggest gap — the
  /// second one is what pays for having looked at seven days and reported the
  /// worst. Without it this is a machine for manufacturing weekday
  /// superstitions.
  Widget _weekdayCard(BuildContext c) {
    final l = AppLocalizations.of(c);
    if (_weekday['present'] != true) {
      return StatusCard(
        l?.wellnessNotEnoughWeeksTitle ?? 'Not enough weeks yet',
        l?.wellnessNotEnoughWeeksBody ??
            'Comparing seven weekdays needs at least eight weeks of days, '
                'with five of every weekday in them.',
        icon: LucideIcons.calendarDays,
      );
    }
    if (_weekday['meaningful'] != true) {
      return StatusCard(
        l?.wellnessNoDayStandsOutTitle ?? 'No day of the week stands out',
        l?.wellnessNoDayStandsOutBody ??
            'No day stands apart from the other six once we account for '
                'having checked all seven.',
        icon: LucideIcons.calendarDays,
      );
    }
    final day = (_weekday['peak_weekday'] as num?)?.toInt() ?? 1;
    final delta = (_weekday['peak_delta'] as num?)?.toDouble() ?? 0;
    final n = (_weekday['n_by_weekday'] as Map?)?['$day'];
    final direction = delta > 0
        ? (l?.wellnessHigher ?? 'higher')
        : (l?.wellnessLower ?? 'lower');
    final weekdayPlural = _weekdayPlural(l, day);
    return Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4),
      child: DriverRow(
        label: l?.wellnessWeekdayHeadline(
              weekdayPlural,
              '${delta.abs().round()}',
              direction,
            ) ??
            '${_weekdayName(day)}s: readiness runs '
                '${delta.abs().round()} $direction than your overall median',
        detail: l?.wellnessWeekdayDetail('$n') ??
            'From $n of them. A weekday is not a cause — it is a container '
                'for what you do on it. Nothing here is advice.',
      ),
    );
  }
}

/// The localized plural weekday name ("Mondays"), for [weekday] 1 = Monday.
String _weekdayPlural(AppLocalizations? l, int weekday) {
  final fallback = '${_weekdayName(weekday)}s';
  return switch (weekday) {
    1 => l?.wellnessPluralMonday ?? fallback,
    2 => l?.wellnessPluralTuesday ?? fallback,
    3 => l?.wellnessPluralWednesday ?? fallback,
    4 => l?.wellnessPluralThursday ?? fallback,
    5 => l?.wellnessPluralFriday ?? fallback,
    6 => l?.wellnessPluralSaturday ?? fallback,
    _ => l?.wellnessPluralSunday ?? fallback,
  };
}

const _kWeekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String _weekdayName(int weekday) => _kWeekdayNames[(weekday - 1).clamp(0, 6)];
