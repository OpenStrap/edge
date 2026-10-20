// "Track something else" — define a user-invented numeric journal field.
//
// Ported from the pre-ui2 journal (lib/ui/journal/custom_journal_field_sheet.dart,
// lost in the UI rebuild — issue #273). A custom field has to declare what its
// number MEANS: without a unit its values render as bare numbers, and without
// a ceiling a mis-tap can enter a value that dominates every correlation it
// appears in.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/journal_fields.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'journal_compose.dart' show OsTextField;

/// Opens the sheet. Returns the new field, or null if dismissed.
///
/// [existingKeys] are rejected on save so a second field cannot quietly
/// overwrite the first one's history by colliding on the generated key.
Future<JournalFieldSpec?> showCustomJournalFieldSheet(
  BuildContext context, {
  required Set<String> existingKeys,
}) {
  return AppSheet.open<JournalFieldSpec>(context,
    builder: (ctx) => Padding(
      // The sheet holds a text field; without this it sits under the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _CustomFieldSheet(existingKeys: existingKeys),
    ),
    scroll: true,
    bare: true,
  );
}

class _CustomFieldSheet extends StatefulWidget {
  const _CustomFieldSheet({required this.existingKeys});
  final Set<String> existingKeys;

  @override
  State<_CustomFieldSheet> createState() => _CustomFieldSheetState();
}

class _CustomFieldSheetState extends State<_CustomFieldSheet> {
  final _nameCtrl = TextEditingController();
  final _unitCtrl = TextEditingController();
  JournalFieldKind _kind = JournalFieldKind.rating;
  double _max = 5;
  double _step = 1;
  bool _hasTime = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _unitCtrl.dispose();
    super.dispose();
  }

  void _selectKind(JournalFieldKind k) {
    setState(() {
      _kind = k;
      // Sensible shapes per kind, so the common case needs no further tapping.
      // Every branch sets BOTH unit and time — otherwise a unit typed under
      // one kind silently rides along when the kind changes.
      const durStep = 15.0;
      switch (k) {
        case JournalFieldKind.rating:
          _max = 5;
          _step = 1;
          _unitCtrl.text = '';
          _hasTime = false;
        case JournalFieldKind.dose:
          _max = 100;
          _step = 1;
          _unitCtrl.text = '';
          _hasTime = false;
        case JournalFieldKind.duration:
          // A value the ceiling chips can actually produce (step x 20).
          _step = durStep;
          _max = durStep * 20;
          _unitCtrl.text = 'min';
          _hasTime = false;
      }
    });
  }

  void _save() {
    final l = AppLocalizations.of(context);
    final label = _nameCtrl.text.trim();
    if (label.isEmpty) {
      setState(() => _error = l?.journalFieldErrorNoName ?? 'Give it a name');
      return;
    }
    final key = customJournalFieldKey(label);
    // A name that slugs to nothing ("???") would produce a bare `custom_`
    // key that every other such name also produces.
    if (key == customJournalFieldKey('')) {
      setState(() => _error =
          l?.journalFieldErrorInvalidName ?? 'Use at least one letter or number');
      return;
    }
    // An amount with no unit renders as a bare number everywhere after —
    // correlations, findings, CSV. Demand it up front.
    if (_kind == JournalFieldKind.dose && _unitCtrl.text.trim().isEmpty) {
      setState(() => _error =
          l?.journalFieldErrorNoUnit ?? 'Say what it is counted in (mg, ml, cups…)');
      return;
    }
    if (widget.existingKeys.contains(key)) {
      setState(() => _error =
          l?.journalFieldErrorDuplicate ?? 'You already track something by that name');
      return;
    }
    Navigator.pop(
      context,
      JournalFieldSpec(
        key: key,
        label: label,
        kind: _kind,
        unit: _kind == JournalFieldKind.rating ? '' : _unitCtrl.text.trim(),
        max: _max,
        step: _step,
        hasTime: _hasTime,
        custom: true,
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(c).height * 0.85,
        ),
        child: Surface(
          pad: const EdgeInsets.all(S.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l?.journalFieldTitle ?? 'Track something else',
                style: F.head.copyWith(color: p.ink),
              ),
              const SizedBox(height: S.x4),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OsTextField(
                        controller: _nameCtrl,
                        label: l?.journalFieldNameLabel ??
                            'What do you want to track?',
                        hint: l?.journalFieldNameHint ??
                            'Magnesium, screen time, headache…',
                      ),
                      const SizedBox(height: S.x4),
                      Text(l?.journalFieldKindQuestion ?? 'What kind of number is it?',
                          style: F.cap.copyWith(color: p.ink3)),
                      const SizedBox(height: S.x2),
                      Wrap(
                        spacing: S.x2,
                        runSpacing: S.x2,
                        children: [
                          for (final (kind, chipLabel) in [
                            (JournalFieldKind.rating,
                                l?.journalFieldKindRating ?? 'A 1–5 rating'),
                            (JournalFieldKind.dose,
                                l?.journalFieldKindAmount ?? 'An amount'),
                            (JournalFieldKind.duration,
                                l?.journalFieldKindMinutes ?? 'Minutes'),
                          ])
                            Pressable(
                              onTap: () => _selectKind(kind),
                              child: Pill(
                                chipLabel,
                                _kind == kind ? C.domMind : C.n400,
                                icon: _kind == kind ? LucideIcons.check : null,
                              ),
                            ),
                        ],
                      ),
                      if (_kind != JournalFieldKind.rating) ...[
                        const SizedBox(height: S.x4),
                        OsTextField(
                          controller: _unitCtrl,
                          label: l?.journalFieldUnitLabel ?? 'Unit',
                          hint: l?.journalFieldUnitHint ?? 'mg, ml, cups…',
                        ),
                        const SizedBox(height: S.x4),
                        Text(l?.journalFieldStepSize ?? 'Step size',
                            style: F.cap.copyWith(color: p.ink3)),
                        const SizedBox(height: S.x2),
                        Wrap(
                          spacing: S.x2,
                          runSpacing: S.x2,
                          children: [
                            for (final st in const [1.0, 5.0, 15.0, 50.0, 100.0])
                              Pressable(
                                onTap: () => setState(() {
                                  _step = st;
                                  // The ceiling must stay above the step or
                                  // the field can only ever hold 0 — and it
                                  // must be one of the chips below, or the
                                  // selected state lies. Anything not an exact
                                  // multiple of the new step snaps back to the
                                  // step-derived default.
                                  if (_max < st || _max % st != 0) {
                                    _max = st * 20;
                                  }
                                }),
                                child: Pill(
                                  st.round().toString(),
                                  _step == st ? C.domMind : C.n400,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: S.x4),
                        Text(l?.journalFieldMaxPerDay ?? 'Most you would log in a day',
                            style: F.cap.copyWith(color: p.ink3)),
                        const SizedBox(height: S.x2),
                        Wrap(
                          spacing: S.x2,
                          runSpacing: S.x2,
                          children: [
                            for (final m in [
                              _step * 10,
                              _step * 20,
                              _step * 50,
                              _step * 100,
                            ])
                              Pressable(
                                onTap: () => setState(() => _max = m),
                                child: Pill(
                                  m.round().toString(),
                                  _max == m ? C.domMind : C.n400,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: S.x4),
                        Pressable(
                          onTap: () =>
                              setState(() => _hasTime = !_hasTime),
                          child: Pill(
                            l?.journalFieldAskLastTime ?? 'Ask when the last one was',
                            _hasTime ? C.domMind : C.n400,
                            icon: _hasTime ? LucideIcons.check : null,
                          ),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: S.x3),
                        Text(_error!, style: F.cap.copyWith(color: C.red)),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: S.x4),
              BigButton(
                l?.journalFieldStartTracking ?? 'Start tracking it',
                icon: LucideIcons.check,
                color: C.domMind,
                onTap: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
