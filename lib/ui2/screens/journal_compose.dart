// Journal — the one place a day's self-report is written.
//
// Mood, water, caffeine and alcohol are NOT new concepts here: they are
// existing `journal_metric` fields (`lib/data/journal_fields.dart`), and this
// screen is their editor. A parallel "wellness log" model would have split the
// correlation engine's inputs in half for no gain.
//
// Ratings are 1–5 and doses are stepped, both straight off the field spec —
// the ceiling exists so one mis-tap cannot enter forty coffees and dominate
// every correlation that field appears in for months.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ai/journal_ai.dart';
import '../../coach/coach_config.dart';
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/journal_fields.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/units_controller.dart';
import '../ui2.dart';
import 'coach.dart' show coachReady;
import 'home_screen.dart' show unitsOf;
import 'custom_journal_field_sheet.dart';
import 'metric_detail.dart' show detailScaffold;

class JournalCompose extends StatefulWidget {
  const JournalCompose({super.key, this.date});

  /// The day being written. Defaults to today's LOCAL label — never a UTC one.
  final String? date;

  @override
  State<JournalCompose> createState() => _JournalComposeState();
}

class _JournalComposeState extends State<JournalCompose> {
  late final String _date = widget.date ?? todayLabel();
  final _note = TextEditingController();

  List<JournalFieldSpec> _specs = const [];
  Map<String, JournalMetricValue> _values = {};
  Set<String> _tags = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = context.read<AppState>().repo;
    if (repo == null) {
      setState(() => _loading = false);
      return;
    }
    final specs = await repo.getJournalFields();
    final values = await repo.getJournalMetrics(_date);
    final entries = await repo.getJournal(range: '30d');
    Map<String, dynamic>? today;
    for (final e in entries) {
      if (e['date'] == _date) today = e;
    }
    if (!mounted) return;
    setState(() {
      _specs = specs;
      _values = {...values};
      _tags = {...?(today?['tags'] as List?)?.map((t) => t.toString())};
      _note.text = (today?['note'] as String?) ?? '';
      _loading = false;
    });
  }

  void _set(String key, double? v) {
    setState(() {
      if (v == null) {
        _values.remove(key);
      } else {
        _values[key] = JournalMetricValue(
          v,
          atMinuteOfDay: _values[key]?.atMinuteOfDay,
        );
      }
    });
  }

  bool _addingField = false;

  /// #273 — define + persist a user-invented field, then pick it up.
  Future<void> _addField() async {
    if (_addingField) return;
    final spec = await showCustomJournalFieldSheet(
      context,
      existingKeys: _specs.map((f) => f.key).toSet(),
    );
    if (spec == null || !mounted) return;
    final repo = context.read<AppState>().repo;
    // No repo means the sheet should never have been reachable; say so rather
    // than eating the tap.
    if (repo == null) {
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(l?.journalComposeNotReady ??
                'Not ready yet — open the app first.')),
      );
      return;
    }
    setState(() => _addingField = true);
    try {
      await repo.postCustomJournalField(spec);
    } catch (_) {
      if (!mounted) return;
      // A failed persist must not read as success — the field would vanish
      // from the list while the user believes it saved.
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(l?.journalComposeSaveFailed ??
                'Could not save it — check storage and retry.')),
      );
      return;
    }
    if (!mounted) return;
    await _load();
    if (mounted) setState(() => _addingField = false);
  }

  /// MT-06 — when the LAST one landed.
  ///
  /// `at_min` has been in the schema, the CSV and the round trip for ages with
  /// nothing anywhere in the UI that could set it, so it was null for every
  /// user and the analysis that wants it had nothing to read. The control only
  /// appears once a dose is logged: a time with no dose is not a fact about
  /// anything.
  Future<void> _setTime(String key) async {
    final cur = _values[key];
    if (cur == null) return;
    final l = AppLocalizations.of(context);
    final at = await showTimePicker(
      context: context,
      initialTime: cur.atMinuteOfDay == null
          ? TimeOfDay.now()
          : TimeOfDay(
              hour: cur.atMinuteOfDay! ~/ 60,
              minute: cur.atMinuteOfDay! % 60,
            ),
      helpText: l?.journalComposeWhenWasLastOne ?? 'When was the last one?',
    );
    if (at == null || !mounted) return;
    setState(() {
      _values[key] = JournalMetricValue(
        cur.value,
        atMinuteOfDay: at.hour * 60 + at.minute,
      );
    });
  }

  /// Opens the AI chat and, on accept, merges its proposal into whatever the
  /// day already holds — the merge is [mergeJournalEntry], never a plain
  /// overwrite of `_tags`/`_note`.
  Future<void> _openAiChat() async {
    final cfg = context.read<CoachConfig>();
    final result = await showModalBottomSheet<({List<String> tags, String note})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _JournalAiSheet(config: cfg),
    );
    if (result == null || !mounted) return;
    final merged = mergeJournalEntry(
      existingTags: _tags.toList(),
      existingNote: _note.text,
      newTags: result.tags,
      newNote: result.note,
    );
    setState(() {
      _tags = merged.tags.toSet();
      _note.text = merged.note;
    });
  }

  Future<void> _save() async {
    final repo = context.read<AppState>().repo;
    if (repo == null) return;
    setState(() => _saving = true);
    await repo.postJournalMetrics(_date, _values);
    await repo.postJournal(_date, _tags.toList(), _note.text.trim());
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            NavBar(l?.journalComposeTitle ?? 'Journal',
                sub: _date, onBack: () => Navigator.of(c).pop()),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x8),
                      children: [
                        MoodPicker(
                          value: _values['mood']?.value.round(),
                          onChanged: (v) => _set('mood', v?.toDouble()),
                        ),
                        Section(
                          l?.journalComposeTodaySection ?? 'Today',
                          Surface(
                            pad: const EdgeInsets.symmetric(horizontal: S.x4),
                            child: Column(
                              children: [
                                for (final s in _specs.where(
                                  (s) => s.key != 'mood',
                                ))
                                  // MT-03 — weight is TYPED, not stepped. On a
                                  // 0.1 kg step a stepper is 700 taps from
                                  // blank, and the field it writes is the one
                                  // surface in this app that must never nag: a
                                  // control nobody can reach is a field nobody
                                  // fills, which is its own kind of dishonest.
                                  if (s.key == 'weight_kg')
                                    _WeightRow(
                                      kg: _values[s.key]?.value,
                                      onChanged: (v) => _set(s.key, v),
                                    )
                                  else
                                    FieldStepper(
                                      spec: s,
                                      value: _values[s.key]?.value,
                                      atMin: _values[s.key]?.atMinuteOfDay,
                                      onChanged: (v) => _set(s.key, v),
                                      onTime: s.hasTime
                                          ? () => _setTime(s.key)
                                          : null,
                                    ),
                                  // #273 — custom fields come back. The old
                                  // UI's "Track something else": define a
                                  // personal numeric field and it behaves
                                  // like a built-in everywhere after.
                                  Pressable(
                                    // Disabled (null onTap) while a write is
                                    // in flight: two submits would race the
                                    // create-only insert below.
                                    onTap: _addingField
                                        ? null
                                        : () => unawaited(_addField()),
                                    child: Row(
                                      children: [
                                        Icon(LucideIcons.plusCircle,
                                            size: 18, color: p.ink3),
                                        const SizedBox(width: S.x2),
                                        Text(
                                            l?.journalComposeTrackSomethingElse ??
                                                'Track something else',
                                            style:
                                                F.body.copyWith(color: p.ink3)),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Section(
                          // Same English text as day_timeline's section — key
                          // shared across the two files, not duplicated.
                          l?.dayTimelineWhatHappenedSection ?? 'What happened',
                          Wrap(
                            spacing: S.x2,
                            runSpacing: S.x2,
                            children: [
                              for (final t in kJournalPresetTags)
                                Pressable(
                                  onTap: () => setState(
                                    () => _tags.contains(t)
                                        ? _tags.remove(t)
                                        : _tags.add(t),
                                  ),
                                  child: Pill(
                                    t,
                                    _tags.contains(t) ? C.domMind : C.n400,
                                    icon: _tags.contains(t)
                                        ? LucideIcons.check
                                        : null,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: S.x5),
                        if (coachReady(c))
                          Padding(
                            padding: const EdgeInsets.only(bottom: S.x2),
                            child: Pressable(
                              onTap: () => unawaited(_openAiChat()),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(LucideIcons.sparkles,
                                      size: 16, color: p.on(C.domMind)),
                                  const SizedBox(width: S.x1),
                                  Text(
                                    // Not localized yet — a new entry point,
                                    // not a copy pass over the whole screen.
                                    'Talk it through with AI',
                                    style: F.over
                                        .copyWith(color: p.on(C.domMind)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        OsTextField(
                          controller: _note,
                          label: l?.journalComposeAnythingElseLabel ?? 'Anything else',
                          hint: l?.journalComposeAnythingElseHint ??
                              'A line about the day.',
                          lines: 4,
                        ),
                        const SizedBox(height: S.x6),
                        BigButton(
                          _saving
                              ? (l?.journalComposeSavingLabel ?? 'Saving')
                              : (l?.actionSave ?? 'Save'),
                          icon: LucideIcons.check,
                          color: C.domMind,
                          onTap: _saving ? null : _save,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The 1–5 self-report. Five faces, not ten: a ten-point self-report is not
/// ten distinguishable states, and the extra resolution is noise a rank
/// correlation then has to see through.
class MoodPicker extends StatelessWidget {
  const MoodPicker({super.key, this.value, required this.onChanged});

  final int? value;

  /// Null means "clear it". A mis-tap used to be permanent: every face wrote a
  /// mood and none of them could write absence back, so the only way out of a
  /// mood you never meant to log was to pick a different wrong one. Tapping
  /// the selected face again takes it back to not-answered — the same rule the
  /// [FieldStepper] uses when it steps down off zero.
  final ValueChanged<int?> onChanged;

  static const _faces = [
    LucideIcons.frown,
    LucideIcons.annoyed,
    LucideIcons.meh,
    LucideIcons.smile,
    LucideIcons.laugh,
  ];
  static const _tints = [C.red, C.orange, C.yellow, C.green, C.green];

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l?.journalComposeHowAreYouFeeling ?? 'How are you feeling?',
            style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: S.x1),
          Text(
            value == null
                ? (l?.journalComposeNotAnsweredYet ?? 'Not answered yet')
                : (l?.journalComposeMoodOfFive(value!) ??
                    'Mood $value of 5 · tap it again to clear'),
            style: F.cap.copyWith(color: p.ink3),
          ),
          const SizedBox(height: S.x4),
          Row(
            children: [
              for (var i = 0; i < 5; i++) ...[
                Expanded(
                  child: Pressable(
                    semanticLabel: value == i + 1
                        ? (l?.journalComposeMoodOfFiveSelected(i + 1) ??
                            'Mood ${i + 1} of 5, selected. Activate to clear.')
                        : (l?.journalComposeMoodOfFiveLabel(i + 1) ??
                            'Mood ${i + 1} of 5'),
                    onTap: () => onChanged(value == i + 1 ? null : i + 1),
                    child: AnimatedContainer(
                      duration: motion(c, Motion.base),
                      height: S.tap,
                      // A Container with a child and no alignment sizes itself
                      // to that child, and the constraints coming down here are
                      // LOOSE — so these rendered as narrow pills with even
                      // gaps, the icon's width instead of the fifth of the row
                      // the Expanded above had already paid for. A non-null
                      // alignment makes a Container take the largest size its
                      // constraints allow, which is the fix and also what
                      // centres the face.
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: R.rMd,
                        color: value == i + 1
                            ? p.fill(_tints[i])
                            : p.wash(_tints[i]),
                      ),
                      child: Icon(
                        _faces[i],
                        size: 22,
                        color: value == i + 1 ? p.inkOnFill : p.on(_tints[i]),
                      ),
                    ),
                  ),
                ),
                if (i < 4) const SizedBox(width: S.x2),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// One journal field as a stepper. Handles ratings and doses from the same
/// spec — the difference is only the step size and the ceiling.
class FieldStepper extends StatelessWidget {
  const FieldStepper({
    super.key,
    required this.spec,
    required this.value,
    required this.onChanged,
    this.atMin,
    this.onTime,
  });

  final JournalFieldSpec spec;

  /// Null means the field was left blank, which is NOT zero: "no caffeine
  /// today" is a logged zero, "did not say" is an absence.
  final double? value;
  final ValueChanged<double?> onChanged;

  /// The LAST occurrence, in local minutes past midnight. Null = not said.
  final int? atMin;

  /// Non-null on a field whose spec says timing matters. The row only offers
  /// it once a dose exists — an hour on its own is not a measurement.
  final VoidCallback? onTime;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final v = value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(spec.label, style: F.body.copyWith(color: p.ink)),
                Text(
                  v == null
                      ? (l?.journalComposeNotLogged ?? 'Not logged')
                      : spec.formatWithUnit(v),
                  style: F.over.copyWith(color: p.ink3),
                ),
                if (v != null && v > 0 && onTime != null)
                  Pressable(
                    semanticLabel: l?.journalComposeWhenWasLastField(spec.label) ??
                        'When was the last ${spec.label}',
                    onTap: onTime,
                    child: Text(
                      atMin == null
                          ? (l?.journalComposeAddTimeOfLastOne ??
                              'Add the time of the last one')
                          : (l?.journalComposeLastAt(formatMinuteOfDay(atMin!)) ??
                              'Last at ${formatMinuteOfDay(atMin!)}'),
                      style: F.over.copyWith(color: p.on(C.blue)),
                    ),
                  ),
              ],
            ),
          ),
          _Step(
            icon: LucideIcons.minus,
            // Enabled AT zero on purpose: zero is a logged "none today" and
            // the step down from it is back to absence. Disabling it there
            // made that path unreachable and locked a zero the user never
            // asserted into the correlation inputs.
            enabled: v != null,
            onTap: () {
              final next = (v ?? 0) - spec.step;
              onChanged(next <= 0 ? (v == 0 ? null : 0) : next);
            },
          ),
          const SizedBox(width: S.x2),
          _Step(
            icon: LucideIcons.plus,
            enabled: v == null || v < spec.max,
            onTap: () =>
                onChanged(((v ?? 0) + spec.step).clamp(0, spec.max).toDouble()),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.enabled, required this.onTap});
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Pressable(
      semanticLabel: icon == LucideIcons.plus
          ? (l?.journalComposeIncrease ?? 'Increase')
          : (l?.journalComposeDecrease ?? 'Decrease'),
      onTap: enabled ? onTap : null,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: p.card2, borderRadius: R.rSm),
        child: Icon(icon, size: 16, color: enabled ? p.ink2 : p.ink3),
      ),
    );
  }
}

/// The app's one text input. Lives here rather than in `grammar.dart` because
/// exactly two screens type into anything — a journal note and a medication
/// name.
class OsTextField extends StatelessWidget {
  const OsTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint = '',
    this.lines = 1,
    this.keyboard,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final int lines;
  final TextInputType? keyboard;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x2),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: R.rMd,
            border: Border.all(color: p.line),
          ),
          // The label is drawn as a sibling `Text`, which a screen reader reads
          // on the way past and then forgets. Focused, the field itself
          // announced only its HINT — and the hint disappears the moment the
          // user types, leaving "text field" with no way to ask what it is for.
          child: Semantics(
            label: label,
            textField: true,
            child: TextField(
              controller: controller,
              maxLines: lines,
              minLines: 1,
              keyboardType: keyboard,
              style: F.body.copyWith(color: p.ink),
              cursorColor: p.on(C.domMind),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: F.body.copyWith(color: p.ink3),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════ MT-03 · WEIGHT ══════════════════════════
//
// The most eating-disorder-adjacent surface in the app, and it is built to
// EMIT NOTHING. Read the ceiling before adding anything here:
//
//   · ENTERED, never measured, and labelled that way everywhere it appears.
//   · The seven-day EWMA trend is what gets drawn — never the raw readings.
//     Day-to-day scale noise is water and glycogen at ±1-2 kg, and a raw line
//     makes that read as change that happened to a body.
//   · Gaps stay gaps. Nothing is interpolated across a fortnight nobody
//     weighed.
//   · NO goal weight. NO daily prompt. NO red/green. NO arrow, no delta, no
//     "you gained" anything, no notification, ever. No body fat, no lean mass,
//     no metabolic age.
//   · It lives here, where it is entered, and nowhere else. It is on no
//     dashboard and in no summary, because a number that greets you is a
//     number that asks you for something.
//
// BMR still reads the onboarding scalar. Changing the BMR input recomputes
// every historical calorie number in the app, so it lands on its own commit
// where a regression is attributable.

/// How much history the trend screen reads. Long enough for a real four-week
/// change to be visible with a season either side of it.
const int kWeightTrendDays = 180;

/// One journal row, typed rather than stepped, plus the way into the trend.
class _WeightRow extends StatelessWidget {
  const _WeightRow({required this.kg, required this.onChanged});

  /// Today's entry in kilograms, or null when nothing was entered. Null is not
  /// zero and it is not a missed target — it is a day she did not weigh.
  final double? kg;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final u = unitsOf(c);
    final v = kg;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l?.journalComposeWeightLabel ?? 'Weight',
                        style: F.body.copyWith(color: p.ink)),
                    Text(
                      v == null
                          ? (l?.journalComposeNotEntered ?? 'Not entered')
                          : (l?.journalComposeEnteredNotMeasured(
                                  u == null ? '${v.toStringAsFixed(1)} kg' : u.weight(v)) ??
                              '${u == null ? '${v.toStringAsFixed(1)} kg' : u.weight(v)} · entered, not measured'),
                      style: F.over.copyWith(color: p.ink3),
                    ),
                  ],
                ),
              ),
              Pressable(
                semanticLabel: l?.journalComposeEnterWeight ?? 'Enter weight',
                onTap: () async {
                  final next = await _askWeight(c, u, v);
                  if (next != null) onChanged(next.value);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: S.x3,
                    vertical: S.x2,
                  ),
                  decoration: BoxDecoration(color: p.card2, borderRadius: R.rSm),
                  child: Text(
                    v == null
                        ? (l?.journalComposeEnter ?? 'Enter')
                        : (l?.journalComposeChange ?? 'Change'),
                    style: F.cap.copyWith(color: p.ink2),
                  ),
                ),
              ),
            ],
          ),
          Pressable(
            semanticLabel: l?.journalComposeSeeWeightTrend ?? 'See the weight trend',
            onTap: () => Navigator.of(c).push(
              MaterialPageRoute<void>(builder: (_) => const _WeightTrend()),
            ),
            child: Text(
              l?.journalComposeSeeTheTrend ?? 'See the trend',
              style: F.over.copyWith(color: p.on(C.blue)),
            ),
          ),
        ],
      ),
    );
  }

  /// The typed entry. Returns a box holding the new value (null inside it means
  /// "clear today's entry"), or null when she backed out — the two are
  /// different answers and collapsing them would make clearing impossible.
  static Future<({double? value})?> _askWeight(
    BuildContext c,
    UnitsController? u,
    double? kg,
  ) {
    final imperial = u?.isImperial ?? false;
    final ctrl = TextEditingController(text: u?.weightField(kg) ?? '');
    final l = AppLocalizations.of(c);
    return showDialog<({double? value})>(
      context: c,
      builder: (dc) => AlertDialog(
        backgroundColor: P.of(dc).card,
        title: Text(
          l?.journalComposeWeightToday ?? 'Weight today',
          style: F.head.copyWith(color: P.of(dc).ink),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OsTextField(
              controller: ctrl,
              label: u?.weightLabel ?? (l?.journalComposeWeightKgLabel ?? 'Weight (kg)'),
              hint: imperial ? '154' : '70.0',
              keyboard: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: S.x3),
            Text(
              l?.journalComposeWeightScaleNote ??
                  'What you or your scale read. The band does not measure this.',
              style: F.over.copyWith(color: P.of(dc).ink3, height: 1.4),
            ),
          ],
        ),
        actions: [
          if (kg != null)
            TextButton(
              onPressed: () => Navigator.of(dc).pop((value: null)),
              child: Text(
                l?.journalComposeClear ?? 'Clear',
                style: F.body.copyWith(color: P.of(dc).ink2),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(dc).pop(),
            child: Text(
              l?.actionCancel ?? 'Cancel',
              style: F.body.copyWith(color: P.of(dc).ink2),
            ),
          ),
          TextButton(
            onPressed: () {
              // A typo is not a blank. Nothing is saved from an unreadable
              // field, and the form says which one rather than storing a hole.
              if (Typed.of(ctrl.text).bad) {
                sayUnreadable(
                    dc, [u?.weightLabel ?? (l?.journalComposeWeightLabel ?? 'Weight')]);
                return;
              }
              final kgIn = u == null
                  ? Typed.of(ctrl.text).value
                  : u.weightToKg(ctrl.text);
              Navigator.of(dc).pop((value: kgIn));
            },
            child: Text(
              l?.actionSave ?? 'Save',
              style: F.body.copyWith(color: P.of(dc).on(C.blue)),
            ),
          ),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }
}

/// The trend, and only the trend.
///
/// One line, no headline number, no delta, no arrow, no target and no colour
/// that means good or bad. If a future change wants to add any of those, the
/// answer is in the ceiling at the top of this section.
class _WeightTrend extends StatefulWidget {
  const _WeightTrend();

  @override
  State<_WeightTrend> createState() => _WeightTrendState();
}

class _WeightTrendState extends State<_WeightTrend> {
  Map<String, double> _byDay = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      // Day arithmetic, not a subtracted duration: a DST day is 23 or 25 hours
      // long and `now - 180 days` lands on the wrong calendar date across one.
      final now = DateTime.now();
      final since = dayLabelOf(
        DateTime(now.year, now.month, now.day - (kWeightTrendDays - 1)),
      );
      final rows = await LocalDb.journalMetricsByDay(sinceDaysEpoch: since);
      if (!mounted) return;
      setState(() {
        _byDay = {
          for (final e in rows.entries)
            // The `when` does real work — a non-finite or non-positive weight
            // is not a weight — and the null-aware element form has nowhere to
            // put a guard.
            // ignore: use_null_aware_elements
            if (e.value['weight_kg']?.value case final v?
                when v.isFinite && v > 0)
              e.key: v,
        };
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final title = l?.journalComposeWeightLabel ?? 'Weight';
    if (_loading) {
      return detailScaffold(c, title, const [
        SizedBox(height: S.x8),
        Center(child: CircularProgressIndicator()),
      ]);
    }
    final p = P.of(c);
    final u = unitsOf(c);
    final trend = weightTrendEwma(_byDay);
    if (trend.length < 2) {
      return detailScaffold(c, title, [
        const SizedBox(height: S.x2),
        StatusCard(
          l?.journalComposeNotEnoughEntriesTitle ?? 'Not enough entries for a trend',
          l?.journalComposeNotEnoughEntriesBody ??
              'The line is a seven-day average through what you entered, so it '
                  'needs at least two days. Nothing is filled in between them.',
          icon: LucideIcons.scale,
        ),
      ]);
    }

    // Indexed by CALENDAR DAY, never compacted: a fortnight nobody weighed is a
    // hole in the line, and compacting would draw a straight, confident segment
    // across it.
    final days = trend.keys.toList()..sort();
    final first = DateTime.parse(days.first);
    final span = DateTime.parse(days.last).difference(first).inDays;
    // The controller owns every conversion; this only asks it for the number
    // rather than the sentence, because an axis cannot print "72.4 kg".
    double show(double kg) =>
        u == null ? kg : (double.tryParse(u.weightField(kg)) ?? kg);
    // NOT null-aware: a null here is a day she did not weigh, and dropping it
    // would compact the series and draw a confident straight segment across
    // the gap. The holes are the point.
    final vals = <double?>[
      for (var i = 0; i <= span; i++) _at(trend, first, i, show),
    ];
    final present = <double>[for (final v in vals) ?v];
    final axis = AxisSpec.of(present, format: axisFixed);

    return detailScaffold(c, title, [
      const SizedBox(height: S.x2),
      Surface(
        child: ChartFrame(
          title: l?.journalComposeSevenDayTrend ?? 'Seven-day trend',
          unit: u?.isImperial == true ? 'lb' : 'kg',
          height: 140,
          yAxis: axis,
          xLabels: [days.first, days.last],
          footnote: l?.journalComposeTrendFootnote ??
              'Entered by you. Days with no entry are left empty.',
          series: vals,
          empty: axis == null ? const NoData() : null,
          child: axis == null
              ? const SizedBox.shrink()
              // No fill: a filled area under an axis that starts at 68 kg is a
              // truncated axis with the truncation hidden.
              : CustomPaint(
                  size: Size.infinite,
                  painter: LineChart(
                    vals,
                    p.on(C.blue),
                    fill: false,
                    t: animate(c, 1),
                    axis: axis,
                  ),
                ),
        ),
      ),
      const SizedBox(height: S.x4),
      Text(
        l?.journalComposeWeightTrendExplainer(trend.length) ??
            'Entered by you or your scale — the band does not measure weight. What '
            'is drawn is a seven-day average, because a scale moves one to two '
            'kilos on water and food alone and the raw readings would show that as '
            'something happening to your body. ${trend.length} '
            '${trend.length == 1 ? 'day' : 'days'} entered.',
        style: F.over.copyWith(color: p.ink3, height: 1.5),
      ),
    ]);
  }

  /// The trend value on one calendar day, or null. Nulls are what draw the gaps
  /// — there is no nearest-neighbour lookup here on purpose.
  double? _at(
    Map<String, double> trend,
    DateTime first,
    int offset,
    double Function(double) show,
  ) {
    // Calendar arithmetic, not a 24 h duration: a DST day is 23 or 25 hours
    // long and adding days as hours slides the whole series by one across one.
    final day = DateTime(first.year, first.month, first.day + offset);
    final v = trend[dayLabelOf(day)];
    return v == null ? null : show(v);
  }
}

// ══════════════════════════ AI JOURNAL CHAT ══════════════════════════
//
// The pre-sleep "tell me about your day" chat over [JournalAiEngine]. The
// model never writes anything: it proposes tags + a note, this sheet shows
// exactly that proposal, and only a tap on "Add to journal" hands it back to
// [_JournalComposeState._openAiChat], which merges it with whatever the day
// already holds via [mergeJournalEntry] — never a plain overwrite.
class _JournalAiSheet extends StatefulWidget {
  const _JournalAiSheet({required this.config});

  final CoachConfig config;

  @override
  State<_JournalAiSheet> createState() => _JournalAiSheetState();
}

class _JournalAiSheetState extends State<_JournalAiSheet> {
  late final JournalAiEngine _engine = JournalAiEngine(config: widget.config);
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <({bool fromUser, String text})>[];
  JournalAiTurn? _last;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _turns.add((fromUser: true, text: text));
      _input.clear();
      _busy = true;
      _error = null;
    });
    try {
      final turn = await _engine.send(text);
      if (!mounted) return;
      setState(() {
        _turns.add((fromUser: false, text: turn.reply));
        _last = turn;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Not fabricated: a failed turn shows the real error, not a canned
      // reply pretending the model answered.
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && mounted) {
        unawaited(_scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: motion(context, Motion.base),
          curve: Curves.easeOut,
        ));
      }
    });
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final last = _last;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Container(
          height: MediaQuery.of(c).size.height * 0.75,
          decoration: BoxDecoration(
            color: p.bg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(R.lg)),
          ),
          child: Column(
            children: [
              const SizedBox(height: S.x2),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: p.line, borderRadius: R.rSm),
              ),
              const SizedBox(height: S.x3),
              Text('Talk it through',
                  style: F.head.copyWith(color: p.ink)),
              const SizedBox(height: S.x2),
              Expanded(
                child: _turns.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(S.x4),
                          child: Text(
                            'Tell it about your day — it proposes tags and a '
                            'note, you decide what to keep.',
                            textAlign: TextAlign.center,
                            style: F.body.copyWith(color: p.ink3),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                            horizontal: S.x4, vertical: S.x2),
                        itemCount: _turns.length,
                        itemBuilder: (_, i) {
                          final t = _turns[i];
                          return Align(
                            alignment: t.fromUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: S.x1),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: S.x3, vertical: S.x2),
                              constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(c).size.width * 0.75),
                              decoration: BoxDecoration(
                                color: t.fromUser ? p.fill(C.domMind) : p.card2,
                                borderRadius: R.rMd,
                              ),
                              child: Text(
                                t.text,
                                style: F.body.copyWith(
                                  color: t.fromUser ? p.inkOnFill : p.ink,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (last != null && last.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x2),
                  child: Wrap(
                    spacing: S.x2,
                    runSpacing: S.x2,
                    children: [for (final t in last.tags) Pill(t, C.domMind)],
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x2),
                  child: Text(_error!, style: F.over.copyWith(color: C.red)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x2),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        enabled: !_busy,
                        onSubmitted: (_) => unawaited(_send()),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Tell it about your day…',
                          border: OutlineInputBorder(borderRadius: R.rMd),
                        ),
                      ),
                    ),
                    const SizedBox(width: S.x2),
                    Pressable(
                      onTap: _busy ? null : () => unawaited(_send()),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: p.fill(C.domMind),
                          borderRadius: R.rMd,
                        ),
                        child: _busy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: p.inkOnFill),
                              )
                            : Icon(LucideIcons.arrowUp, color: p.inkOnFill),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
                child: BigButton(
                  'Add to journal',
                  icon: LucideIcons.check,
                  color: C.domMind,
                  onTap: last == null
                      ? null
                      : () => Navigator.of(c)
                          .pop((tags: last.tags, note: last.note)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
