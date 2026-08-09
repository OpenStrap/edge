// Add or edit one lab result.
//
// The unit is NOT editable for a catalogue marker. Free-form units are how a
// series ends up with ferritin in ng/mL on one row and nmol/L on the next, and
// a chart drawn across both is worse than no chart. A marker your lab reports
// differently is a custom marker, with its own unit, kept as its own series.

import 'package:flutter/material.dart';

import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/lab_catalogue.dart';
import '../design/design.dart';

/// Returns true when something was saved or deleted.
Future<bool> showLabEntrySheet(
  BuildContext context, {
  required List<LabMarker> custom,
  Map<String, dynamic>? existing,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _LabEntrySheet(custom: custom, existing: existing),
    ),
  );
  return saved ?? false;
}

class _LabEntrySheet extends StatefulWidget {
  const _LabEntrySheet({required this.custom, this.existing});
  final List<LabMarker> custom;
  final Map<String, dynamic>? existing;

  @override
  State<_LabEntrySheet> createState() => _LabEntrySheetState();
}

class _LabEntrySheetState extends State<_LabEntrySheet> {
  final _valueCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _customNameCtrl = TextEditingController();
  final _customUnitCtrl = TextEditingController();

  String? _markerKey;
  bool _definingCustom = false;
  late DateTime _takenOn;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _markerKey = e['marker'] as String;
      _valueCtrl.text = (e['value'] as num).toString();
      _noteCtrl.text = (e['note'] as String?) ?? '';
      _takenOn = DateTime.parse(e['taken_on'] as String);
    } else {
      _takenOn = DateTime.now();
    }
  }

  @override
  void dispose() {
    _valueCtrl.dispose();
    _noteCtrl.dispose();
    _customNameCtrl.dispose();
    _customUnitCtrl.dispose();
    super.dispose();
  }

  // The one local-day-label formatter, shared with every other layer.
  String get _dateLabel => dayLabelOf(_takenOn);

  Future<void> _pickDate() async {
    final now = DateTime.now();
    // Blood cannot be drawn in the future, and a decade covers any history
    // worth typing in by hand.
    final first = DateTime(now.year - 10);
    // showDatePicker ASSERTS that initialDate sits inside the bounds, so a row
    // older than the window — or an imported one dated in the future — would
    // throw instead of opening the picker.
    final initial = _takenOn.isBefore(first)
        ? first
        : (_takenOn.isAfter(now) ? now : _takenOn);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: now,
    );
    if (picked != null && mounted) setState(() => _takenOn = picked);
  }

  Future<void> _save() async {
    final key = _markerKey;
    if (key == null) {
      setState(() => _error = 'Pick a marker');
      return;
    }
    final value = double.tryParse(_valueCtrl.text.trim().replaceAll(',', '.'));
    if (value == null) {
      setState(() => _error = 'Enter the number from your report');
      return;
    }
    final marker = labMarker(key, custom: widget.custom);
    await LocalDb.putLabResult(
      marker: key,
      takenOn: _dateLabel,
      value: value,
      // Stored per row so the reading keeps the unit it was entered under,
      // even if the catalogue's canonical unit changes later. Editing an
      // existing row therefore keeps ITS unit rather than adopting whatever
      // the definition says now — and a row whose definition has been deleted
      // keeps its unit instead of being blanked.
      unit: marker?.unit ?? (widget.existing?['unit'] as String?) ?? '',
      note: _noteCtrl.text.trim(),
    );
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final e = widget.existing;
    if (e == null) return;
    await LocalDb.deleteLabResult(e['marker'] as String, e['taken_on'] as String);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _saveCustomMarker() async {
    final label = _customNameCtrl.text.trim();
    final unit = _customUnitCtrl.text.trim();
    if (label.isEmpty || unit.isEmpty) {
      setState(() => _error = 'A name and a unit, both from your report');
      return;
    }
    final key = customLabMarkerKey(label);
    if (key == 'custom_') {
      setState(() => _error = 'Use at least one letter or number');
      return;
    }
    // "Lp(a)", "Lp a" and "LP-A" all slug to the same key, and the write
    // replaces on key — so without this the second one silently overwrites the
    // first's unit, and every reading already stored under it starts rendering
    // in a unit it was never measured in.
    final clash = widget.custom.where((m) => m.key == key).firstOrNull;
    if (clash != null && (clash.label != label || clash.unit != unit)) {
      setState(
        () => _error = 'You already track "${clash.label}" (${clash.unit})',
      );
      return;
    }
    await LocalDb.putLabMarkerDef({
      'key': key,
      'label': label,
      'unit': unit,
      'category': LabCategory.blood.name,
      'decimals': 2,
      // No reference range: inventing one for a marker the app knows nothing
      // about is exactly the kind of false verdict this feature must avoid.
      'ref_low': null,
      'ref_high': null,
    });
    if (!mounted) return;
    setState(() {
      _definingCustom = false;
      _markerKey = key;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final marker = _markerKey == null
        ? null
        : labMarker(_markerKey!, custom: widget.custom);
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _isEdit ? 'Edit result' : 'Add a result',
                      style: AppText.h2,
                    ),
                  ),
                  if (_isEdit)
                    Semantics(
                      button: true,
                      label: 'Delete this result',
                      child: Pressable(
                        pressedScale: 0.9,
                        onTap: _delete,
                        child: Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                          color: AppColors.inkSoft,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Sp.x4),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_definingCustom)
                        ..._customFields()
                      else ...[
                        if (!_isEdit) ..._markerPicker(),
                        if (marker != null)
                          ..._valueFields(marker)
                        // An edit whose definition has since been deleted must
                        // still be editable — its own row carries the unit.
                        else if (_isEdit)
                          ..._valueFieldsForDeletedMarker(),
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
                  onPressed: _definingCustom ? _saveCustomMarker : _save,
                  child: Text(_definingCustom ? 'Add marker' : 'Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _markerPicker() => [
    for (final entry in _groupedForPicker().entries) ...[
      Padding(
        padding: const EdgeInsets.only(bottom: Sp.x2, top: Sp.x2),
        child: Text(
          entry.key,
          style: AppText.label.copyWith(color: AppColors.inkSoft),
        ),
      ),
      Wrap(
        spacing: Sp.x2,
        runSpacing: Sp.x2,
        children: [
          for (final m in entry.value)
            ToggleChip(
              m.label,
              selected: _markerKey == m.key,
              onTap: () => setState(() {
                _markerKey = m.key;
                _error = null;
              }),
            ),
        ],
      ),
    ],
    const SizedBox(height: Sp.x3),
    Pressable(
      pressedScale: 0.96,
      onTap: () => setState(() {
        _definingCustom = true;
        _error = null;
      }),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: Sp.x1),
          Text(
            'Something else',
            style: AppText.label.copyWith(color: AppColors.accent),
          ),
        ],
      ),
    ),
  ];

  Map<String, List<LabMarker>> _groupedForPicker() {
    final out = <String, List<LabMarker>>{};
    for (final e in labMarkersByCategory().entries) {
      out[e.key.label] = e.value;
    }
    if (widget.custom.isNotEmpty) out['Yours'] = widget.custom;
    return out;
  }

  List<Widget> _valueFields(LabMarker marker) => [
    const SizedBox(height: Sp.x4),
    Text(
      marker.label,
      style: AppText.label.copyWith(color: AppColors.inkSoft),
    ),
    const SizedBox(height: Sp.x2),
    Row(
      children: [
        Expanded(
          child: TextField(
            controller: _valueCtrl,
            autofocus: !_isEdit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: AppText.body,
            decoration: _fieldDecoration('Value'),
          ),
        ),
        const SizedBox(width: Sp.x3),
        // Fixed, not editable: a series that mixes units is unchartable.
        Text(marker.unit, style: AppText.body.copyWith(
          color: AppColors.inkSoft,
        )),
      ],
    ),
    const SizedBox(height: Sp.x4),
    Text('Date drawn', style: AppText.label.copyWith(color: AppColors.inkSoft)),
    const SizedBox(height: Sp.x2),
    Pressable(
      pressedScale: 0.96,
      onTap: _pickDate,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x4,
          vertical: Sp.x3,
        ),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(R.cardSm),
        ),
        child: Text(_dateLabel, style: AppText.body),
      ),
    ),
    const SizedBox(height: Sp.x4),
    TextField(
      controller: _noteCtrl,
      style: AppText.body,
      decoration: _fieldDecoration('Note (optional)'),
    ),
  ];

  /// Edit fields for a row whose marker definition no longer exists. The row's
  /// own `unit` is the authority, so it stays fully editable rather than
  /// becoming a value nobody can correct.
  List<Widget> _valueFieldsForDeletedMarker() => _valueFields(
    LabMarker(
      key: _markerKey ?? '',
      label: _markerKey ?? 'Result',
      unit: (widget.existing?['unit'] as String?) ?? '',
      category: LabCategory.blood,
      decimals: 2,
      custom: true,
    ),
  );

  List<Widget> _customFields() => [
    Text(
      'Add a marker this app does not know about. It is stored with the unit '
      'you give it and shown without a reference range — the app will not '
      'invent one.',
      style: AppText.caption.copyWith(color: AppColors.inkMuted),
    ),
    const SizedBox(height: Sp.x4),
    TextField(
      controller: _customNameCtrl,
      autofocus: true,
      textCapitalization: TextCapitalization.sentences,
      style: AppText.body,
      decoration: _fieldDecoration('Name, e.g. Lp(a)'),
    ),
    const SizedBox(height: Sp.x3),
    TextField(
      controller: _customUnitCtrl,
      style: AppText.body,
      decoration: _fieldDecoration('Unit, e.g. nmol/L'),
    ),
  ];

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: AppText.bodySoft.copyWith(color: AppColors.inkMuted),
    filled: true,
    fillColor: AppColors.surfaceAlt,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(R.cardSm),
      borderSide: BorderSide.none,
    ),
  );
}
