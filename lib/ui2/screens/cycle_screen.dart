// CYCLE — the domain that was fully built in the data layer and dark in the UI.
//
// Three rules shape every line of it:
//
//   1. Everything on this screen is COUNTED from days you logged. The phase
//      and the prediction are arithmetic over your own dates — no threshold,
//      no population norm, no diagnosis. THERE IS NO FERTILE WINDOW: it was
//      `(median − 14) ± 2`, a textbook population constant printed as her own
//      dates, and WH-09 deleted it. The one thing the repo derives from a
//      sensor (`ovulation_est`, a temperature coverline) is deliberately NOT
//      rendered either: it compares an ADC-count threshold against a z-score
//      series, a live unit mismatch.
//   2. A prediction states its evidence and never hardens into a promise. It
//      is a RANGE — the median gap ± the MAD of her own gaps — with the number
//      of measured gaps behind it on the same row. It is often very wide, and
//      that width is the finding. It disappears entirely below two logged
//      starts, and below THREE it can only give the point and say why it has
//      no width.
//   3. The biometric overlay is descriptive and comparative to YOU. Resting
//      heart rate across the current cycle, drawn from `day_result`, with no
//      claim about what it means.
//
// Tracking is off until the user turns it on, and the switch lives here rather
// than in a settings screen — the toggle and the thing it toggles are one tap
// apart.
//
//   4. NO ANOMALY SURFACE MAY BE RENDERED ON THIS SCREEN. not the health
//      exception, not the illness CUSUM, not a multivariate-anomaly card, not
//      an "elevated for N nights" row — however it is worded and whatever the
//      strings say. "your resting heart rate has been elevated for 10
//      consecutive nights" placed next to a late period IS a pregnancy
//      inference; the layout does the inferring and no copy edit undoes it.
//      the app must never infer, display, store or export a pregnancy
//      probability: a false positive is cruel, a false negative reaching
//      someone deciding about medication, alcohol or imaging is dangerous, and
//      an inferred-pregnancy field is a category of data with real legal
//      exposure in several jurisdictions even when it never leaves the phone.
//      keep the anomaly surfaces on their own screens. the only honest
//      pregnancy feature is a DECLARED state whose entire function is to make
//      the app say less, and a declared state stays out of exports and out of
//      any AI-briefing prompt — exports are allow-listed to views, so keeping
//      it out is one line, and it is worth a test.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' show mdc, robustBaseline;
import 'package:provider/provider.dart';

import '../../data/day_label.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import '../onboarding/profile_setup.dart' show formatDay;
import 'metric_detail.dart' show detailScaffold;

/// WH-08 — the published range for an adult menstrual cycle, in days.
///
/// It is drawn as two lines and NOTHING ELSE. There is no verdict text on that
/// chart, no label for being outside it, and no vocabulary anywhere in this
/// file — strings, identifiers or otherwise — for any life stage. The code is
/// named after the arithmetic it does, because a variable name leaks into
/// logs, exports and eventually into copy.
const kPublishedCycleDays = (low: 24.0, high: 38.0);

/// How many consecutive measured gaps WH-08 needs before it will draw. Roughly
/// a year of unbroken logging: the chart is a description of a long run, and a
/// short run of it says nothing that the next three months would not overturn.
const kCycleLengthReviewMinGaps = 12;

/// A gap longer than this is far more likely a start that was never logged than
/// a cycle that genuinely ran that long, and from here the two are
/// indistinguishable. REFUSING ON HOLES IS THE FEATURE: one missed tap
/// manufactures a 60-day "cycle", and a chart that draws it has invented the
/// most alarming bar on the screen.
const kCycleLengthUnloggableGapDays = 60;

/// What the user may attach to a day. A short, plain, non-diagnostic list —
/// these are observations, not symptoms of anything the app claims to know.
const kCycleSymptoms = <String>[
  'cramps',
  'headache',
  'bloating',
  'fatigue',
  'low mood',
  'acne',
  'tender breasts',
  'nausea',
];

/// WH-07 — what she may declare, and nothing beyond it. There is no "trying to
/// conceive" and no due date: this list exists to switch things OFF, and every
/// entry that would switch something on is a claim we cannot back.
const kReproStates = <(String, String, String)>[
  (
    'cycling',
    'I have natural cycles',
    'Counts a phase from your logged starts.',
  ),
  (
    'contraception',
    'Hormonal contraception',
    'No ovulation to count from, so no phase. Bleeds are still logged.',
  ),
  (
    'none',
    'Pregnant, postpartum, or not cycling',
    'No phase and no predicted next. Your biometrics still show.',
  ),
];

class CycleData {
  final bool enabled;
  final String phase;
  final int? cycleDay;
  final num? daysUntilNext, medianLength;
  final String? predictedNext;

  /// The band half her logged gaps fell inside — median gap ± MAD. Both null
  /// until two gaps exist, because one gap has no spread to state.
  final String? predictedFrom, predictedTo;

  /// Measured gaps behind the prediction. One fewer than logged starts.
  final int gapN;

  /// WH-07 — what she told the app, or null if she never did. Null is not
  /// "cycling": it is the conservative reading, and it keeps the phase off.
  final String? reproState;

  /// `{date, kind}`, oldest first.
  final List<Map<String, dynamic>> logs;

  /// `{date, cycle_day, resting_hr, hrv_rmssd, skin_temp_idx}` — 120 days of
  /// derived days, so most rows fall outside the current cycle.
  final List<Map<String, dynamic>> overlay;

  final Map<String, List<String>> symptoms;

  const CycleData({
    this.enabled = false,
    this.phase = 'unknown',
    this.cycleDay,
    this.daysUntilNext,
    this.medianLength,
    this.predictedNext,
    this.predictedFrom,
    this.predictedTo,
    this.gapN = 0,
    this.reproState,
    this.logs = const [],
    this.overlay = const [],
    this.symptoms = const {},
  });

  static Future<CycleData> load(AppState app) async {
    final repo = app.repo;
    if (repo == null) return const CycleData();
    final c = await repo.getCycle();
    if (c['enabled'] != true) return const CycleData();
    return CycleData(
      enabled: true,
      phase: (c['phase'] ?? 'unknown').toString(),
      cycleDay: (c['cycle_day'] as num?)?.round(),
      daysUntilNext: c['days_until_next'] as num?,
      medianLength: c['median_length'] as num?,
      predictedNext: c['predicted_next'] as String?,
      predictedFrom: c['predicted_from'] as String?,
      predictedTo: c['predicted_to'] as String?,
      gapN: (c['gap_n'] as num?)?.round() ?? 0,
      reproState: c['repro_state'] as String?,
      logs: [
        for (final l in (c['logs'] as List? ?? const []))
          if (l is Map) l.cast<String, dynamic>(),
      ],
      overlay: [
        for (final o in (c['overlay'] as List? ?? const []))
          if (o is Map) o.cast<String, dynamic>(),
      ],
      symptoms: await repo.getCycleSymptoms(),
    );
  }
}

/// The Wellness sub-tab. Renders a `Column`, so it drops straight into the
/// screen's own `ListView` the way the other four tabs do.
class CycleTab extends StatefulWidget {
  final CycleData? data;
  const CycleTab({super.key, this.data});

  @override
  State<CycleTab> createState() => _CycleTabState();
}

class _CycleTabState extends State<CycleTab> with RevisionReload {
  CycleData? _d;

  /// The symptom look-back is folded away by default — the chips above it are
  /// what she opened the tab to tap.
  bool _showShape = false;

  /// Read on every use. The tab lives in the shell's IndexedStack, so a field
  /// initialiser would still be yesterday after midnight and a period start
  /// would be logged against the wrong day.
  String get _date => todayLabel();

  @override
  void initState() {
    super.initState();
    if (widget.data != null) {
      _d = widget.data;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  bool get revisionReloads => widget.data == null;

  /// Cycle logs and symptoms arrive by import as well as by tap, and this tab
  /// lives inside Wellness — same IndexedStack, same never-disposed lifetime.
  @override
  void reload() => _load();

  Future<void> _load() async {
    final t = beginRead(#cycle);
    try {
      final d = await CycleData.load(context.read<AppState>());
      if (stillNewest(#cycle, t)) setState(() => _d = d);
    } catch (_) {
      if (stillNewest(#cycle, t)) setState(() => _d = const CycleData());
    }
  }

  Future<void> _setEnabled(bool on) async {
    await context.read<AppState>().updateProfile({'track_cycle': on});
    await _load();
  }

  Future<void> _logStart() async {
    final repo = context.read<AppState>().repo;
    if (repo == null) return;
    await repo.postCycleLog(_date);
    await _load();
  }

  /// Confirmed, because it cannot be undone OR redone: the only writer on this
  /// screen logs TODAY, so a start deleted off an older date has no way back.
  Future<void> _deleteLog(String date) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmRemove(
      context,
      title:
          l?.cycleRemoveLogTitle(_short(date, l)) ?? 'Remove ${_short(date, l)}?',
      body:
          l?.cycleRemoveLogBody ??
          'Cycle day, phase and the predicted next date are all counted from '
              'the days you log. Only today can be logged, so this one cannot be '
              'put back.',
    );
    if (!ok || !mounted) return;
    final repo = context.read<AppState>().repo;
    if (repo == null) return;
    await repo.deleteCycleLog(date);
    await _load();
  }

  /// Pick, or clear back to unset. Clearing is a real answer — it returns the
  /// screen to the conservative reading rather than trapping her in a state she
  /// tapped once.
  Future<void> _pickRepro() async {
    final p = P.of(context);
    final l = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      backgroundColor: p.card,
      shape: const RoundedRectangleBorder(borderRadius: R.rXl),
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(S.x4),
              child: Text(
                l?.cycleWhatAppliesToYou ?? 'What applies to you',
                style: F.head.copyWith(color: P.of(c).ink),
              ),
            ),
            for (final key in [...kReproStates.map((r) => r.$1), ''])
              Pressable(
                onTap: () => Navigator.pop(c, key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: S.x4,
                    vertical: S.x3,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _reproDisplayLabel(l, key),
                        style: F.body.copyWith(color: P.of(c).ink),
                      ),
                      Text(
                        _reproDisplayWhy(l, key),
                        style: F.over.copyWith(
                          color: P.of(c).ink3,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await context.read<AppState>().updateProfile({
      'repro_state': picked.isEmpty ? null : picked,
    });
    await _load();
  }

  Future<void> _toggleSymptom(String s) async {
    final repo = context.read<AppState>().repo;
    final d = _d;
    if (repo == null || d == null) return;
    final now = [...?d.symptoms[_date]];
    now.contains(s) ? now.remove(s) : now.add(s);
    await repo.postCycleSymptoms(_date, now);
    await _load();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final d = _d;
    if (d == null) return const Center(child: CircularProgressIndicator());

    if (!d.enabled) {
      return StatusCard(
        l?.cycleTrackingOffTitle ?? 'Cycle tracking is off',
        l?.cycleTrackingOffBody ?? 'It stays on this phone.',
        fix: l?.cycleTurnOnTracking ?? 'Turn on cycle tracking',
        icon: LucideIcons.circleDot,
        onFix: () => _setEnabled(true),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (d.cycleDay == null)
          StatusCard(
            l?.cycleNoPeriodTitle ?? 'No period logged yet',
            l?.cycleNoPeriodBody ?? 'Counted from the days you log.',
            fix: l?.cycleLogPeriodButton ?? 'Log a period start today',
            icon: LucideIcons.calendarPlus,
            onFix: _logStart,
          )
        else
          _today(c, p, d),

        if (d.predictedNext != null) ...[
          const SizedBox(height: S.x4),
          _prediction(c, p, d),
        ],

        // The current-cycle chart used to live here. It moved BEHIND this card
        // rather than sitting above three more of them: WH-02, WH-03 and WH-08
        // are all look-backs, and the tab itself is for logging today.
        const SizedBox(height: S.x5),
        DeepDiveCard(
          l?.cycleAcrossCyclesTitle ?? 'Across your cycles',
          '${_completedCycles(d)}',
          _completedCycles(d) == 1
              ? (l?.cycleUnitCompleteCycle ?? 'complete cycle')
              : (l?.cycleUnitCompleteCycles ?? 'complete cycles'),
          l?.cycleOpenAction ?? 'Open',
          C.pink,
          onTap: () => Navigator.of(
            c,
          ).push(MaterialPageRoute<void>(builder: (_) => _CycleHistory(d))),
        ),

        Section(
          l?.cycleWhatYouNoticedToday ?? 'What you noticed today',
          _symptoms(c, p, d),
        ),

        if (d.logs.isNotEmpty)
          Section(l?.cycleLoggedDays ?? 'Logged days', _logs(c, p, d)),

        // WH-07 — the one control that makes the screen say less. It sits in
        // this tab's settings gutter, next to the switch that turns the whole
        // thing off, because that is what it is: not a reading, a declaration.
        const SizedBox(height: S.x5),
        Surface(
          pad: const EdgeInsets.symmetric(horizontal: S.x4),
          child: MetricRow(
            LucideIcons.circleDot,
            C.pink,
            l?.cycleWhatAppliesToYou ?? 'What applies to you',
            _reproDisplayLabel(l, d.reproState),
            sub: d.reproState == null
                ? (l?.cycleReproOptionalHint ??
                      'Optional. Until you say, the app leaves the phase off.')
                : (l?.cycleReproPrivateHint ??
                      'Only you and this phone. Never exported.'),
            onTap: _pickRepro,
          ),
        ),
        const SizedBox(height: S.x5),
        BigButton(
          l?.cycleLogPeriodButton ?? 'Log a period start today',
          icon: LucideIcons.calendarPlus,
          color: C.pink,
          onTap: _logStart,
        ),
        const SizedBox(height: S.x3),
        Pressable(
          onTap: () => _setEnabled(false),
          child: Text(
            l?.cycleTurnOffTracking ?? 'Turn off cycle tracking',
            textAlign: TextAlign.center,
            style: F.cap.copyWith(color: p.ink3),
          ),
        ),
      ],
    );
  }

  // ── today ────────────────────────────────────────────────────────────────

  Widget _today(BuildContext c, P p, CycleData d) {
    final l = AppLocalizations.of(c);
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l?.cycleDayInThisCycle ?? 'DAY IN THIS CYCLE',
                style: F.over.copyWith(color: p.ink3),
              ),
              const Spacer(),
              if (d.phase != 'unknown') Pill(_phaseLabel(l, d.phase), C.pink),
            ],
          ),
          const SizedBox(height: S.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${d.cycleDay}', style: F.n34.copyWith(color: p.ink)),
              const SizedBox(width: S.x2),
              Text(
                d.medianLength == null
                    ? (l?.cycleCountedFromLastStart ??
                          'counted from your last logged start')
                    : (l?.cycleOfAboutDays(d.medianLength!.round()) ??
                          'of about ${d.medianLength!.round()}'),
                style: F.cap.copyWith(color: p.ink3),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── prediction ───────────────────────────────────────────────────────────

  /// A RANGE, not a date — median gap ± the MAD of her own gaps.
  ///
  /// It is wide, often very wide, and that is the finding rather than a defect
  /// to tune away: a cycle that varies by six days cannot be predicted to one.
  /// Below two measured gaps there is no spread to state, so it falls back to
  /// the point and says why it has no width.
  Widget _prediction(BuildContext c, P p, CycleData d) {
    final l = AppLocalizations.of(c);
    final from = d.predictedFrom, to = d.predictedTo;
    final ranged = from != null && to != null;
    final due = _parse(d.predictedNext!);
    final headline = ranged
        ? '${_short(from, l)} – ${_short(to, l)}'
        : due == null
        ? d.predictedNext!
        : formatDay(due, l);
    return Surface(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ranged
                      ? (l?.cycleNextPeriodBetween ??
                            'NEXT PERIOD, EXPECTED BETWEEN')
                      : (l?.cycleNextPeriodAround ??
                            'NEXT PERIOD, EXPECTED AROUND'),
                  style: F.over.copyWith(color: p.ink3),
                ),
                const SizedBox(height: S.x1),
                Text(
                  headline,
                  style: (ranged ? F.n17 : F.n24).copyWith(color: p.ink),
                ),
                const SizedBox(height: S.x1),
                Text(
                  _when(l, d),
                  style: F.over.copyWith(color: p.ink3, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// When, and what the number is made of. The evidence rides on the same row
  /// as the claim — never a date on its own.
  String _when(AppLocalizations? l, CycleData d) {
    final n = d.gapN;
    if (d.predictedFrom == null || d.predictedTo == null) {
      final days = d.daysUntilNext?.round();
      return '${_lead(l, days)}${l?.cycleFromOneMeasuredGap ?? 'from your one measured gap, which cannot show how '
          'much your own cycle varies'}';
    }
    // Offsets off the SAME `days_until_next` the point case uses, never a
    // second read of the clock: the repo already resolved "today" once, and a
    // screen that resolves it again can disagree with itself over midnight.
    final w = _spanDays(d.predictedNext!, d.predictedTo!);
    final centre = d.daysUntilNext?.round();
    final lo = (centre == null || w == null) ? null : centre - w;
    final hi = (centre == null || w == null) ? null : centre + w;
    final String when;
    if (lo == null || hi == null) {
      when = '';
    } else if (hi < 0) {
      when = l?.cyclePastEndOfIt(-hi) ?? '${-hi} days past the end of it · ';
    } else if (lo <= 0) {
      when = l?.cycleInsideItNow ?? 'you are inside it now · ';
    } else {
      when = l?.cycleInDaysRange(lo, hi) ?? 'in $lo–$hi days · ';
    }
    return '$when${l?.cycleHalfOfMeasuredGaps(n) ?? 'half of your $n measured gaps landed inside a range this '
        'wide'}';
  }

  String _lead(AppLocalizations? l, int? days) => days == null
      ? ''
      : days < 0
      ? (l?.cycleLeadDaysLate(-days) ?? '${-days} days late · ')
      : days == 0
      ? (l?.cycleLeadToday ?? 'today · ')
      : (l?.cycleLeadInDays(days) ?? 'in $days days · ');

  int? _spanDays(String from, String to) {
    final a = _parse(from), b = _parse(to);
    return (a == null || b == null) ? null : b.difference(a).inDays;
  }

  // ── symptoms ─────────────────────────────────────────────────────────────

  Widget _symptoms(BuildContext c, P p, CycleData d) {
    final l = AppLocalizations.of(c);
    final on = d.symptoms[_date] ?? const <String>[];
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: S.x2,
            runSpacing: S.x2,
            children: [
              for (final s in kCycleSymptoms)
                Pressable(
                  onTap: () => _toggleSymptom(s),
                  child: AnimatedContainer(
                    duration: motion(c, Motion.fast),
                    padding: const EdgeInsets.symmetric(
                      horizontal: S.x3,
                      vertical: S.x2,
                    ),
                    decoration: BoxDecoration(
                      color: on.contains(s) ? p.wash(C.pink) : p.card2,
                      borderRadius: R.rPill,
                    ),
                    child: Text(
                      _symptomLabel(l, s),
                      style: F.cap.copyWith(
                        color: on.contains(s) ? p.on(C.pink) : p.ink2,
                        fontWeight: on.contains(s)
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          _shape(c, p, d),
        ],
      ),
    );
  }

  /// WH-06 — the shape of what she has been ticking, under the chips that
  /// write it. COUNTING ONLY. It is behind a tap because it is a look back and
  /// the chips above are the thing she came here to do.
  ///
  /// THE DENOMINATOR IS DAYS SHE LOGGED, never days elapsed. Symptom logging is
  /// bursty and self-selecting — three tagged days in a fortnight she opened
  /// the app twice is not "21% of days", it is three of two. A rate over the
  /// calendar would be a fabrication wearing a frequency's clothes.
  ///
  /// Nothing here says a week of the cycle CAUSES anything, and nothing is
  /// ranked by significance — these tags never go near a correlation. ~20 tags
  /// against a handful of tagged days is a p-hacking machine at this n.
  Widget _shape(BuildContext c, P p, CycleData d) {
    final l = AppLocalizations.of(c);
    final s = _symptomShape(d);
    if (s == null) return const SizedBox.shrink();
    final usuallyNotice =
        l?.cycleWhatYouUsuallyNotice ?? 'What you usually notice';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: S.x3),
        Pressable(
          semanticLabel: usuallyNotice,
          onTap: () => setState(() => _showShape = !_showShape),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  usuallyNotice,
                  style: F.cap.copyWith(color: p.ink2),
                ),
              ),
              Icon(
                _showShape ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                size: 18,
                color: p.ink3,
              ),
            ],
          ),
        ),
        if (_showShape) ...[
          const SizedBox(height: S.x2),
          for (final e in s.counts)
            Padding(
              padding: const EdgeInsets.only(bottom: S.x2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(_symptomLabel(l, e.$1),
                        style: F.cap.copyWith(color: p.ink)),
                  ),
                  Text(e.$2.join(' · '), style: F.n17.copyWith(color: p.ink2)),
                ],
              ),
            ),
          Text(
            l?.cycleSymptomShapeSummary(
                  s.daysByWeek.join(', '),
                  s.cycles,
                ) ??
                'Four numbers, one per week of the cycle, counted back to your own '
                    'logged starts. You logged something on ${s.daysByWeek.join(', ')} '
                    'days of each week across ${s.cycles} cycles — those are the only '
                    'days in any of this.',
            style: F.over.copyWith(color: p.ink3, height: 1.5),
          ),
        ],
      ],
    );
  }

  /// `null` when there is not enough to count over: under three logged starts
  /// is under two complete cycles, and a shape drawn on one is a shape drawn on
  /// nothing.
  _Shape? _symptomShape(CycleData d) {
    final starts = <DateTime>[
      for (final l in d.logs)
        if (l['kind'] == 'start') ?_parse(l['date'] as String? ?? ''),
    ]..sort();
    if (starts.length < 3) return null;

    final daysByWeek = List<int>.filled(4, 0);
    final byTag = <String, List<int>>{};
    var daysLogged = 0;
    for (final e in d.symptoms.entries) {
      if (e.value.isEmpty) continue;
      final day = _parse(e.key);
      if (day == null || day.isBefore(starts.first)) continue;
      // Nearest PRECEDING start, not the last one — a day from March belongs to
      // March's cycle, and counting it from the newest start puts it in week 40.
      final from = starts.lastWhere((s) => !s.isAfter(day));
      final week = (day.difference(from).inDays ~/ 7).clamp(0, 3);
      daysLogged++;
      daysByWeek[week]++;
      for (final tag in e.value) {
        (byTag[tag] ??= List<int>.filled(4, 0))[week]++;
      }
    }
    if (daysLogged == 0) return null;
    // Ordered by how often she ticked it. Frequency, not "significance" — one
    // is a count she can check, the other is a test we are not running.
    final counts = byTag.entries.map((e) => (e.key, e.value)).toList()
      ..sort(
        (a, b) => b.$2
            .reduce((x, y) => x + y)
            .compareTo(a.$2.reduce((x, y) => x + y)),
      );
    return _Shape(counts, daysByWeek, starts.length - 1);
  }

  // ── logs ─────────────────────────────────────────────────────────────────

  Widget _logs(BuildContext c, P p, CycleData d) {
    final l = AppLocalizations.of(c);
    final recent = d.logs.reversed.take(6).toList();
    return Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4),
      child: Column(
        children: [
          for (var i = 0; i < recent.length; i++) ...[
            if (i > 0) Divider(color: p.line, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _parse(recent[i]['date'] as String? ?? '') == null
                          ? '${recent[i]['date']}'
                          : formatDay(_parse(recent[i]['date'] as String)!, l),
                      style: F.body.copyWith(color: p.ink),
                    ),
                  ),
                  Text(
                    recent[i]['kind'] == 'start'
                        ? (l?.cycleLogKindStart ?? 'START')
                        : (l?.cycleLogKindEnd ?? 'END'),
                    style: F.over.copyWith(color: p.ink3),
                  ),
                  const SizedBox(width: S.x3),
                  Pressable(
                    semanticLabel:
                        l?.cycleRemoveLoggedDay(
                          '${recent[i]['date']}',
                        ) ??
                        'Remove ${recent[i]['date']}',
                    onTap: () => _deleteLog(recent[i]['date'] as String),
                    child: Icon(LucideIcons.x, size: 18, color: p.ink3),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// WH-06 — per-tag counts by week of the cycle, and the denominators they sit
/// on. Counts, nothing else: no rate over the calendar, no test, no cause.
class _Shape {
  /// `(tag, [week1, week2, week3, week4])`, most-ticked first.
  final List<(String, List<int>)> counts;

  /// Days she logged ANYTHING, per week. The denominator — and the reason a
  /// zero in week 3 may mean "not that week" or "did not open the app".
  final List<int> daysByWeek;

  /// Measured cycles behind it (logged starts − 1).
  final int cycles;

  const _Shape(this.counts, this.daysByWeek, this.cycles);
}

DateTime? _parse(String ymd) => DateTime.tryParse(ymd);

String _short(String ymd, [AppLocalizations? l]) {
  final d = _parse(ymd);
  return d == null ? ymd : formatDay(d, l);
}

/// Localized display label for a `repro_state` key ('' = prefer not to say,
/// null/unrecognised = never set).
String _reproDisplayLabel(AppLocalizations? l, String? key) => switch (key) {
  'cycling' => l?.cycleReproCyclingLabel ?? 'I have natural cycles',
  'contraception' =>
    l?.cycleReproContraceptionLabel ?? 'Hormonal contraception',
  'none' =>
    l?.cycleReproNoneLabel ?? 'Pregnant, postpartum, or not cycling',
  '' => l?.cyclePreferNotToSay ?? 'Prefer not to say',
  _ => l?.cycleReproNotSet ?? 'Not set',
};

/// Localized "why" copy shown under a `repro_state` option in the picker.
String _reproDisplayWhy(AppLocalizations? l, String key) => switch (key) {
  'cycling' =>
    l?.cycleReproCyclingWhy ?? 'Counts a phase from your logged starts.',
  'contraception' =>
    l?.cycleReproContraceptionWhy ??
        'No ovulation to count from, so no phase. Bleeds are still logged.',
  'none' =>
    l?.cycleReproNoneWhy ??
        'No phase and no predicted next. Your biometrics still show.',
  _ => l?.cyclePreferNotToSayWhy ?? 'The app keeps the phase off.',
};

/// Localized display label for a `kCycleSymptoms` key. The key itself stays
/// English — it is the storage value posted to the repo — only the label
/// shown on the chip is localized.
String _symptomLabel(AppLocalizations? l, String key) => switch (key) {
  'cramps' => l?.cycleSymptomCramps ?? 'cramps',
  'headache' => l?.cycleSymptomHeadache ?? 'headache',
  'bloating' => l?.cycleSymptomBloating ?? 'bloating',
  'fatigue' => l?.cycleSymptomFatigue ?? 'fatigue',
  'low mood' => l?.cycleSymptomLowMood ?? 'low mood',
  'acne' => l?.cycleSymptomAcne ?? 'acne',
  'tender breasts' => l?.cycleSymptomTenderBreasts ?? 'tender breasts',
  'nausea' => l?.cycleSymptomNausea ?? 'nausea',
  _ => key,
};

String _phaseLabel(AppLocalizations? l, String p) => switch (p) {
  'menstrual' => l?.cyclePhaseMenstrual ?? 'Menstrual',
  'follicular' => l?.cyclePhaseFollicular ?? 'Follicular',
  'ovulation' => l?.cyclePhaseOvulation ?? 'Ovulation window',
  'luteal' => l?.cyclePhaseLuteal ?? 'Luteal',
  _ => p,
};

// ══════════════════════ ACROSS YOUR CYCLES ══════════════════════
//
// Density 3. Everything on this screen is a LOOK BACK over days she logged
// herself, and it is behind one tap because the tab in front of it is for
// logging today, not for reading history.
//
// WH-02 · the (cycle index, cycle day) fix. `getCycle` numbers every derived
//   day against the LAST logged start, so a night from March came back as
//   "cycle day 214" and only the newest cycle could ever be drawn. Here each
//   day is placed against the start that actually preceded it, which is the
//   whole feature — the medians and the day-against-itself comparison both
//   ride on it.
// WH-03 · a COMPARISON, never a correction. Nothing here rescales readiness.
// WH-08 · cycle lengths against a published range. Bars, two lines, no verdict.
//
// AND NOTHING ELSE GOES HERE. In particular no anomaly surface — an elevated
// resting-HR card rendered next to a late period IS a pregnancy inference no
// matter what its strings say.

/// Complete cycles behind everything on this screen: one fewer than her logged
/// starts, because the newest one has not finished.
int _completedCycles(CycleData d) {
  final n = startDates(d).length;
  return n <= 1 ? 0 : n - 1;
}

/// Every logged start, oldest first.
List<DateTime> startDates(CycleData d) => <DateTime>[
  for (final l in d.logs)
    if (l['kind'] == 'start') ?_parse(l['date'] as String? ?? ''),
]..sort();

/// Consecutive gaps between logged starts, in days, oldest first.
List<int> cycleGaps(List<DateTime> s) => [
  for (var i = 1; i < s.length; i++) calendarDaysBetween(s[i - 1], s[i]),
];

/// WH-02 — `cycleDay -> {cycleIndex: value}` for one overlay key.
///
/// The index is the start the day actually followed, found by walking every
/// logged start rather than assuming the last one. That is what stops an old
/// day from being numbered in the 200s, and it is what makes "the same day of
/// a different cycle" a thing this screen can talk about at all.
Map<int, Map<int, double>> byCycleDay(CycleData d, String key) {
  final starts = startDates(d);
  final out = <int, Map<int, double>>{};
  if (starts.isEmpty) return out;
  for (final o in d.overlay) {
    final v = o[key];
    if (v is! num || !v.toDouble().isFinite) continue;
    final day = _parse(o['date'] as String? ?? '');
    if (day == null) continue;
    final i = starts.lastIndexWhere((s) => !s.isAfter(day));
    if (i < 0) continue; // before she ever logged a start
    final cd = calendarDaysBetween(starts[i], day) + 1;
    if (cd < 1) continue;
    (out[cd] ??= {})[i] = v.toDouble();
  }
  return out;
}

/// WH-02 — her own night-to-night noise in this metric, as a minimal
/// detectable change, or null when there is nothing to estimate it from.
///
/// Taken over EVERY overlay value, not over the per-cycle-day medians: the
/// medians are the thing being tested, and testing a series against its own
/// spread passes anything. `mdc` is 1.96·√2·MAD, so this is deliberately the
/// conservative reading — it will call a real small shift undetectable long
/// before it will call noise a finding.
double? cycleDayNoise(CycleData d, String key) {
  final all = <double>[
    for (final o in d.overlay)
      if (o[key] is num && (o[key] as num).toDouble().isFinite)
        (o[key] as num).toDouble(),
  ];
  if (all.length < 3) return null;
  return mdc(robustBaseline(all));
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// Mean and SAMPLE standard deviation, or null when there is nothing to spread
/// — fewer than two values, or every value identical. A z against a zero
/// spread is an infinity dressed as a finding.
({double mean, double sd})? _spread(List<double> v) {
  if (v.length < 2) return null;
  final m = v.reduce((a, b) => a + b) / v.length;
  var ss = 0.0;
  for (final x in v) {
    ss += (x - m) * (x - m);
  }
  final sd = math.sqrt(ss / (v.length - 1));
  return sd < 1e-9 ? null : (mean: m, sd: sd);
}

class _CycleHistory extends StatefulWidget {
  const _CycleHistory(this.data);
  final CycleData data;

  @override
  State<_CycleHistory> createState() => _CycleHistoryState();
}

class _CycleHistoryState extends State<_CycleHistory> {
  CycleData get d => widget.data;

  /// The store, or null in a golden — the same defence `unitsOf` uses. A build
  /// that throws because a provider is missing is a screen nobody can add to
  /// the gallery.
  AppState? get _app {
    try {
      return context.watch<AppState>();
    } catch (_) {
      return null;
    }
  }

  /// WH-08 is OPT IN. It is never turned on by an age read off the profile —
  /// that would be the app deciding what stage of life she is in, which is the
  /// one thing this screen must never do.
  bool get _lengthReview => _app?.user?['cycle_length_review'] == true;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return detailScaffold(c, l?.cycleAcrossCyclesTitle ?? 'Across your cycles', [
      const SizedBox(height: S.x2),
      Section(l?.cycleThisCycle ?? 'This cycle', _currentCycleChart(c, d)),
      Section(l?.cycleByDayOfYourCycle ?? 'By day of your cycle', _byDay(c)),
      Section(
        l?.cycleHowLongCyclesBeen ?? 'How long your cycles have been',
        _lengths(c),
      ),
    ]);
  }

  // ── WH-02 ────────────────────────────────────────────────────────────────

  Widget _byDay(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final rhr = byCycleDay(d, 'resting_hr');
    final rmssd = byCycleDay(d, 'hrv_rmssd');
    // TWO SERIES, NOT THREE. The third would be `skin_temp_idx`, which is the
    // generic `skin_temp_z` under a name that implies a cycle temperature
    // index. It is not one, so it is not drawn.
    final charts = [
      _cycleDayChart(
        c,
        l?.cycleRestingHeartRate ?? 'Resting heart rate',
        l?.cycleUnitBpm ?? 'bpm',
        C.pink,
        rhr,
        cycleDayNoise(d, 'resting_hr'),
      ),
      _cycleDayChart(
        c,
        l?.cycleHrvRmssdTitle ?? 'HRV (RMSSD)',
        l?.cycleUnitMs ?? 'ms',
        C.purple,
        rmssd,
        cycleDayNoise(d, 'hrv_rmssd'),
      ),
    ];
    if (charts.every((w) => w == null)) {
      return StatusCard(
        l?.cycleNotEnoughDescribeDayTitle ??
            'Not enough cycles to describe a cycle day yet',
        l?.cycleNotEnoughDescribeDayBody ??
            'Every point here is the middle of the same day across two or more of '
                'your own cycles. Nothing has two behind it yet.',
        icon: LucideIcons.circleDot,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final w in charts)
          if (w != null) ...[w, const SizedBox(height: S.x3)],
        Text(
          l?.cycleOwnPastCyclesDescribed ??
              'Your own past cycles, described. Days that only one cycle reached '
                  'are left empty rather than drawn — one night is not a middle. It '
                  'describes what happened, not what will.',
          style: F.over.copyWith(color: p.ink3, height: 1.5),
        ),
        const SizedBox(height: S.x4),
        _dayAgainstItself(c),
      ],
    );
  }

  /// One chart, or null when fewer than three cycle days had two cycles behind
  /// them — which is not enough to plot and is the normal state for months.
  ///
  /// [noise] is her own minimal detectable change in this metric. THE WHOLE
  /// CHART IS A NON-FINDING while the biggest gap between two of its days is
  /// smaller than that, and the footnote says so in those words: a 1 bpm
  /// "shift" drawn from two cycles is a line the eye reads as a cycle and the
  /// sensor cannot resolve. Null noise (too few nights to estimate a spread)
  /// prints nothing rather than an unqualified claim.
  Widget? _cycleDayChart(
    BuildContext c,
    String title,
    String unit,
    Color color,
    Map<int, Map<int, double>> byDay,
    double? noise,
  ) {
    final med = <int, double>{
      for (final e in byDay.entries)
        if (e.value.length >= 2) e.key: _median(e.value.values.toList()),
    };
    if (med.length < 3) return null;
    final last = med.keys.reduce((a, b) => a > b ? a : b);
    // Indexed by cycle day, never compacted: a day with no median is a HOLE,
    // and a compacted series quietly joins day 4 to day 9 as if adjacent.
    final vals = <double?>[for (var i = 1; i <= last; i++) med[i]];
    final axis = AxisSpec.of(med.values);
    if (axis == null) return null;
    final ns = [for (final k in med.keys) byDay[k]!.length]..sort();
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Surface(
      child: ChartFrame(
        title: title,
        unit: unit,
        yAxis: axis,
        xLabels: [
          l?.cycleDayOneLabel ?? 'Day 1',
          l?.cycleDayNLabel(last) ?? 'Day $last',
        ],
        // n, on every point — as the range it actually spans, because thirty
        // little numbers along a line is not a readable chart and a single
        // headline n would be false for most of the points under it. Then the
        // MDC line, which is what stops the shape being read as a finding.
        footnote:
            '${ns.first == ns.last ? (l?.cycleMiddleOfNCycles(ns.first) ?? 'Middle of ${ns.first} cycles at each day.') : (l?.cycleMiddleOfRangeCycles(ns.first, ns.last) ?? 'Middle of between ${ns.first} and ${ns.last} cycles at each day.')}'
            '${_mdcNote(l, med.values, unit, noise)}',
        series: vals,
        child: CustomPaint(
          size: Size.infinite,
          painter: LineChart(
            vals,
            p.on(color),
            fill: false,
            t: animate(c, 1),
            axis: axis,
          ),
        ),
      ),
    );
  }

  // ── WH-03 ────────────────────────────────────────────────────────────────

  /// Two numbers with their baselines named, and NOTHING RESCALED.
  ///
  /// A readiness composite quietly re-based on a calendar count is a hidden
  /// model, and the glass box exists precisely so that no composite in this app
  /// gets to be one. So this is a sentence in a detail screen, never a second
  /// hero, and it never appears next to the readiness number itself.
  ///
  /// It needs three previous cycles that reached the same day, so the empty
  /// state is the common one for most of a year.
  Widget _dayAgainstItself(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final lines = [
      for (final (key, label, dp) in [
        ('hrv_rmssd', l?.cycleCompareHrvLabel ?? 'HRV', 1),
        ('resting_hr', l?.cycleRestingHeartRate ?? 'Resting heart rate', 1),
      ])
        ?_compareLine(l, key, label, dp),
    ];
    if (lines.isEmpty) {
      final cd = d.cycleDay;
      return StatusCard(
        l?.cycleNotEnoughCompareTitle ??
            'Not enough cycles to compare a day against itself',
        cd == null
            ? (l?.cycleCompareBodyGeneric ??
                  'This puts today next to the same day of your own previous '
                      'cycles. It needs three of them that got that far.')
            : (l?.cycleCompareBodyWithDay(cd) ??
                  'This puts today next to the same day of your own previous '
                      'cycles. It needs three of them that reached day $cd.'),
        icon: LucideIcons.circleDot,
      );
    }
    // Which night these two numbers are about. The newest DERIVED night, which
    // is often not today — a line that silently means "three days ago" is the
    // same fabrication as a fabricated number.
    final night = [
      for (final o in d.overlay)
        if (o['resting_hr'] is num || o['hrv_rmssd'] is num)
          ?(o['date'] as String?),
    ];
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (night.isNotEmpty) ...[
            Text(
              l?.cycleNightOfLabel(_short(night.last, l).toUpperCase()) ??
                  'NIGHT OF ${_short(night.last, l).toUpperCase()}',
              style: F.over.copyWith(color: p.ink3),
            ),
            const SizedBox(height: S.x2),
          ],
          for (final line in lines) ...[
            Text(line, style: F.body.copyWith(color: p.ink, height: 1.4)),
            const SizedBox(height: S.x2),
          ],
          Text(
            l?.cycleComparisonNotCorrection ??
                'A comparison, not a correction. Nothing on your readiness has '
                    'been rescaled by this, and nothing here is a training '
                    'instruction.',
            style: F.over.copyWith(color: p.ink3, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// "HRV −1.2 vs your last 3 weeks, −0.3 vs your last three day-22s."
  String? _compareLine(AppLocalizations? l, String key, String label, int dp) {
    final starts = startDates(d);
    if (starts.isEmpty) return null;
    // Newest row that carries this key. `overlay` is oldest first.
    final dated = <(DateTime, int, double)>[];
    for (final o in d.overlay) {
      final v = o[key];
      final day = _parse(o['date'] as String? ?? '');
      if (v is! num || !v.toDouble().isFinite || day == null) continue;
      final i = starts.lastIndexWhere((s) => !s.isAfter(day));
      if (i < 0) continue;
      dated.add((day, i, v.toDouble()));
    }
    if (dated.isEmpty) return null;
    dated.sort((a, b) => a.$1.compareTo(b.$1));
    final (latest, cycleIndex, value) = dated.last;
    final cycleDay = calendarDaysBetween(starts[cycleIndex], latest) + 1;

    // Baseline one: her trailing three weeks, ending the day before this one.
    // Straddles the follicular/luteal boundary by construction, which is the
    // whole reason the second baseline exists.
    final trailing = [
      for (final (day, _, v) in dated)
        if (day.isBefore(latest) && calendarDaysBetween(day, latest) <= 21) v,
    ];
    // Baseline two: the SAME cycle day, in her own earlier cycles.
    final sameDay = [
      for (final (day, i, v) in dated)
        if (i != cycleIndex &&
            calendarDaysBetween(starts[i], day) + 1 == cycleDay)
          v,
    ];
    if (sameDay.length < 3) return null;
    final a = _spread(trailing), b = _spread(sameDay);
    if (a == null || b == null) return null;
    final z1 = (value - a.mean) / a.sd, z2 = (value - b.mean) / b.sd;
    return l?.cycleCompareLine(
          label,
          _signed(z1, dp),
          _signed(z2, dp),
          sameDay.length,
          cycleDay,
        ) ??
        '$label ${_signed(z1, dp)} vs your last 3 weeks, '
            '${_signed(z2, dp)} vs your last ${sameDay.length} day-${cycleDay}s.';
  }

  // ── WH-08 ────────────────────────────────────────────────────────────────

  /// Days between consecutive logged starts, drawn as bars against the two
  /// published lines. There is no sentence under it that says whether they meet
  /// the criterion, because the chart already shows that and a sentence would
  /// be a verdict.
  Widget _lengths(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final starts = startDates(d);
    final gaps = cycleGaps(starts);

    if (!_lengthReview) {
      return StatusCard(
        l?.cycleLengthsTitle ?? 'Your cycle lengths against a published range',
        l?.cycleLengthsBody ??
            'Off unless you ask for it. It draws the days between your own logged '
                'starts next to the range published for an adult cycle, and says '
                'nothing else about them.',
        fix: l?.cycleShowIt ?? 'Show it',
        icon: LucideIcons.ruler,
        onFix: _app == null
            ? null
            : () => _app!.updateProfile({'cycle_length_review': true}),
      );
    }
    if (gaps.length < kCycleLengthReviewMinGaps) {
      return StatusCard(
        l?.cycleNotEnoughLoggedTitle ?? 'Not enough logged cycles yet',
        l?.cycleNotEnoughLoggedBody(
              gaps.length,
              kCycleLengthReviewMinGaps,
            ) ??
            'This needs a long run: ${gaps.length} of '
                '$kCycleLengthReviewMinGaps gaps so far, which is about a year of '
                'logging every start.',
        icon: LucideIcons.ruler,
      );
    }
    // REFUSING ON HOLES IS THE FEATURE.
    if (gaps.any((g) => g > kCycleLengthUnloggableGapDays)) {
      return StatusCard(
        l?.cycleGapTitle ?? 'There is a gap in your logged starts',
        l?.cycleGapBody(kCycleLengthUnloggableGapDays) ??
            'One of them is more than $kCycleLengthUnloggableGapDays days after '
                'the one before it. A start you never logged and a cycle that '
                'genuinely ran that long look the same from here, so nothing is '
                'drawn.',
        icon: LucideIcons.ruler,
      );
    }

    final vals = [for (final g in gaps) g.toDouble()];
    // FROM ZERO. A bar is drawn from the canvas floor, so an axis that starts
    // at 20 makes a 26-day cycle look a third the length of a 38-day one —
    // the truncated-bar form, and on this chart the exaggeration lands on the
    // most frightening reading. `ceil` only EXTENDS, so a cycle longer than
    // the published range still sets the top of the scale.
    final axis = AxisSpec.of(
      vals,
      floor: 0,
      ceil: kPublishedCycleDays.high + 4,
    );
    if (axis == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Surface(
          child: ChartFrame(
            title: l?.cycleDaysBetweenStarts ?? 'Days between your logged starts',
            unit: l?.cycleUnitDays ?? 'days',
            yAxis: axis,
            xLabels: [
              _short(_ymdOf(starts[1]), l),
              _short(_ymdOf(starts.last), l),
            ],
            legend: [
              (l?.cycleLegendYourCycles ?? 'Your cycles', p.on(C.pink)),
              (l?.cycleLegendPublishedRange ?? 'Published range', p.ink3),
            ],
            footnote:
                l?.cycleTwoLinesFootnote(
                  kPublishedCycleDays.low.round(),
                  kPublishedCycleDays.high.round(),
                ) ??
                'The two lines are ${kPublishedCycleDays.low.round()} and '
                    '${kPublishedCycleDays.high.round()} days.',
            series: vals,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: Bars(
                    vals,
                    p.on(C.pink),
                    t: animate(c, 1),
                    axis: axis,
                  ),
                ),
                for (final v in [
                  kPublishedCycleDays.low,
                  kPublishedCycleDays.high,
                ])
                  Align(
                    alignment: Alignment(0, 1 - 2 * axis.t(v)),
                    child: Container(height: 1, color: p.ink3),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: S.x3),
        // Non-dismissible, and deliberately not a card that can be closed.
        Text(
          l?.cycleLengthChangesReasons ??
              'Cycle length changes for many reasons — thyroid, stress, weight '
                  'change, contraception, PCOS and others. This is your own logged '
                  'data next to a published range. It is a reason to ask a clinician, '
                  'not an answer from one.',
          style: F.over.copyWith(color: p.ink3, height: 1.5),
        ),
        const SizedBox(height: S.x3),
        Pressable(
          onTap: _app == null
              ? null
              : () => _app!.updateProfile({'cycle_length_review': false}),
          child: Text(
            l?.cycleHideLengths ?? 'Hide cycle lengths',
            textAlign: TextAlign.center,
            style: F.cap.copyWith(color: p.ink3),
          ),
        ),
      ],
    );
  }
}

/// Resting HR against cycle day, for the CURRENT cycle only.
///
/// WH-02 changed what `cycle_day` means: it is now counted off the start that
/// actually preceded the row, and the row carries the `cycle_index` of that
/// start. So an old cycle's day 4 is now a real day 4 and no longer excludes
/// itself by being out of range — the current cycle is the LAST index, and
/// that is what this filters on. `cycle_index` absent (older repo, fixtures)
/// falls back to the range check, which is what the numbering used to mean.
Widget _currentCycleChart(BuildContext c, CycleData d) {
  final today = d.cycleDay;
  final current = startDates(d).length - 1;
  final byDay = <int, double>{};
  for (final o in d.overlay) {
    final cd = o['cycle_day'], v = o['resting_hr'], ci = o['cycle_index'];
    if (cd is! num || v is! num) continue;
    if (ci is num && ci.round() != current) continue;
    if (cd < 1 || (today != null && cd > today)) continue;
    byDay[cd.round()] = v.toDouble();
  }
  // Indexed by cycle day, not compacted: a night the band was off is a HOLE in
  // the line, and a compacted series would quietly join Day 4 to Day 9 as if
  // they were adjacent.
  final last = byDay.isEmpty
      ? 0
      : today ?? byDay.keys.reduce((a, b) => a > b ? a : b);
  final vals = <double?>[for (var i = 1; i <= last; i++) byDay[i]];
  final present = byDay.values.toList();
  final axis = present.length < 3 ? null : AxisSpec.of(present);
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  return Surface(
    child: ChartFrame(
      title: l?.cycleRestingHeartRate ?? 'Resting heart rate',
      unit: l?.cycleUnitBpm ?? 'bpm',
      height: 120,
      yAxis: axis,
      xLabels: axis == null
          ? const []
          : [
              l?.cycleDayOneLabel ?? 'Day 1',
              l?.cycleDayNLabel(last) ?? 'Day $last',
            ],
      footnote: l?.cycleDescriptiveOnly ?? 'Descriptive only.',
      empty: axis == null
          ? NoData(
              message:
                  l?.cycleNotEnoughDerivedNights ??
                  'Not enough derived nights this cycle yet',
            )
          : null,
      series: vals,
      child: axis == null
          ? const SizedBox.shrink()
          // No fill: a filled area under a heart-rate axis that starts at 52 is
          // the truncated-axis form with the truncation hidden.
          : CustomPaint(
              size: Size.infinite,
              painter: LineChart(
                vals,
                p.on(C.pink),
                fill: false,
                t: animate(c, 1),
                axis: axis,
              ),
            ),
    ),
  );
}

/// WH-02 — what the drawn cycle-day medians are worth against her own noise.
///
/// The chart's whole visual claim is "this day differs from that one", and the
/// only number that can back it is the minimal detectable change. So the swing
/// across the drawn days is stated next to the MDC, in the metric's own units,
/// and when the swing is the smaller of the two the sentence says the shape is
/// not a shift. Returns '' when there is no MDC to state — an unqualified
/// claim is worse than a quiet one, but so is a fabricated threshold.
String _mdcNote(
  AppLocalizations? l,
  Iterable<double> medians,
  String unit,
  double? noise,
) {
  if (noise == null || noise <= 0 || medians.isEmpty) return '';
  final swing = medians.reduce(math.max) - medians.reduce(math.min);
  final s = '${swing.toStringAsFixed(1)} $unit';
  final n = '${noise.toStringAsFixed(1)} $unit';
  return swing < noise
      ? (l?.cycleMdcNoteInsideSpread(s, n) ??
            ' Every day drawn here is inside your own night-to-night spread: the '
                'biggest gap between two of them is $s, and $n is the smallest '
                'change this can tell from noise. A shape, not a shift.')
      : (l?.cycleMdcNoteVaries(n, s) ??
            ' Your nights vary by $n on their own, so days closer together than '
                'that are not separated. The biggest gap here is $s.');
}

/// A z with its sign always printed — "0.3" and "−0.3" are different findings
/// and a bare number reads as the first one.
String _signed(double z, int dp) =>
    '${z < 0 ? '−' : '+'}${z.abs().toStringAsFixed(dp)}';

String _ymdOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
