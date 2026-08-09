// "Track something else" — define a user-invented numeric journal field.
//
// A custom field has to declare what its number MEANS, because nothing else
// can: without a unit its values render as bare numbers, and without a ceiling
// a mis-tap can enter a value that dominates every correlation it appears in.

import 'package:flutter/material.dart';

import '../../data/journal_fields.dart';
import '../design/design.dart';

/// Opens the sheet. Returns the new field, or null if dismissed.
///
/// [existingKeys] are rejected on save so a second field cannot quietly
/// overwrite the first one's history by colliding on the generated key.
Future<JournalFieldSpec?> showCustomJournalFieldSheet(
  BuildContext context, {
  required Set<String> existingKeys,
}) {
  return showModalBottomSheet<JournalFieldSpec>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      // The sheet holds a text field; without this it sits under the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _CustomFieldSheet(existingKeys: existingKeys),
    ),
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
      switch (k) {
        case JournalFieldKind.rating:
          _max = 5;
          _step = 1;
          _unitCtrl.text = '';
          _hasTime = false;
        case JournalFieldKind.dose:
          _max = 100;
          _step = 1;
        case JournalFieldKind.duration:
          _max = 480;
          _step = 15;
          _unitCtrl.text = 'min';
      }
    });
  }

  void _save() {
    final label = _nameCtrl.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Give it a name');
      return;
    }
    final key = customJournalFieldKey(label);
    // A name that slugs to nothing ("???") would produce a bare `custom_`
    // key that every other such name also produces.
    if (key == 'custom_') {
      setState(() => _error = 'Use at least one letter or number');
      return;
    }
    if (widget.existingKeys.contains(key)) {
      setState(() => _error = 'You already track something by that name');
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
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.all(Sp.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Track something else', style: AppText.h2),
              const SizedBox(height: Sp.x4),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _field(
                        controller: _nameCtrl,
                        hint: 'Magnesium, screen time, headache…',
                      ),
                      const SizedBox(height: Sp.x4),
                      _label('What kind of number is it?'),
                      Wrap(
                        spacing: Sp.x2,
                        runSpacing: Sp.x2,
                        children: [
                          ToggleChip(
                            'A 1–5 rating',
                            selected: _kind == JournalFieldKind.rating,
                            onTap: () => _selectKind(JournalFieldKind.rating),
                          ),
                          ToggleChip(
                            'An amount',
                            selected: _kind == JournalFieldKind.dose,
                            onTap: () => _selectKind(JournalFieldKind.dose),
                          ),
                          ToggleChip(
                            'Minutes',
                            selected: _kind == JournalFieldKind.duration,
                            onTap: () =>
                                _selectKind(JournalFieldKind.duration),
                          ),
                        ],
                      ),
                      if (_kind != JournalFieldKind.rating) ...[
                        const SizedBox(height: Sp.x4),
                        _label('Unit'),
                        _field(controller: _unitCtrl, hint: 'mg, ml, cups…'),
                        const SizedBox(height: Sp.x4),
                        _label('Step size'),
                        Wrap(
                          spacing: Sp.x2,
                          runSpacing: Sp.x2,
                          children: [
                            for (final s in const [1.0, 5.0, 15.0, 50.0, 100.0])
                              ToggleChip(
                                s.round().toString(),
                                selected: _step == s,
                                onTap: () => setState(() {
                                  _step = s;
                                  // The ceiling must stay above the step or
                                  // the field can only ever hold 0.
                                  if (_max < s) _max = s * 20;
                                }),
                              ),
                          ],
                        ),
                        const SizedBox(height: Sp.x4),
                        _label('Most you would log in a day'),
                        Wrap(
                          spacing: Sp.x2,
                          runSpacing: Sp.x2,
                          children: [
                            for (final m in [
                              _step * 10,
                              _step * 20,
                              _step * 50,
                              _step * 100,
                            ])
                              ToggleChip(
                                m.round().toString(),
                                selected: _max == m,
                                onTap: () => setState(() => _max = m),
                              ),
                          ],
                        ),
                        const SizedBox(height: Sp.x4),
                        ToggleChip(
                          'Ask when the last one was',
                          selected: _hasTime,
                          onTap: () => setState(() => _hasTime = !_hasTime),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: Sp.x3),
                        Text(
                          _error!,
                          style: AppText.label.copyWith(color: AppColors.bad),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Sp.x4),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Start tracking it'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: Sp.x2),
    child: Text(text, style: AppText.label.copyWith(color: AppColors.inkSoft)),
  );

  Widget _field({
    required TextEditingController controller,
    required String hint,
  }) => TextField(
    controller: controller,
    style: AppText.body,
    textCapitalization: TextCapitalization.sentences,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: AppText.bodySoft.copyWith(color: AppColors.inkMuted),
      filled: true,
      fillColor: AppColors.surfaceAlt,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
