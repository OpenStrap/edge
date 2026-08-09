// The numeric half of the journal editor — one row per field.
//
// The contract that shapes every control here: ABSENT AND ZERO ARE DIFFERENT.
// "No caffeine today" is a measurement; "I didn't fill this in" is not, and a
// correlation that reads the second as the first invents a point at the bottom
// of the dose range. So every field starts unset, a value can always be
// cleared back to unset, and a real 0 is reachable and looks different from
// nothing.

import 'package:flutter/material.dart';

import '../../data/journal_fields.dart';
import '../design/design.dart';

class JournalMetricEditor extends StatelessWidget {
  const JournalMetricEditor({
    super.key,
    required this.specs,
    required this.values,
    required this.onChanged,
    this.onAddField,
    this.onRemoveField,
  });

  /// Built-ins followed by the user's own.
  final List<JournalFieldSpec> specs;

  /// Current day's values. A key absent here means the field is unset.
  final Map<String, JournalMetricValue> values;

  /// Called with the complete next map — the caller holds the state.
  final ValueChanged<Map<String, JournalMetricValue>> onChanged;

  /// Null hides the "add your own" affordance.
  final VoidCallback? onAddField;

  /// Called to forget a custom field's definition.
  final ValueChanged<JournalFieldSpec>? onRemoveField;

  void _set(String key, JournalMetricValue? v) {
    final next = Map<String, JournalMetricValue>.from(values);
    if (v == null) {
      next.remove(key);
    } else {
      next[key] = v;
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final spec in specs)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x3),
            child: _FieldRow(
              spec: spec,
              value: values[spec.key],
              onChanged: (v) => _set(spec.key, v),
              onRemove: spec.custom && onRemoveField != null
                  ? () => onRemoveField!(spec)
                  : null,
            ),
          ),
        if (onAddField != null)
          Pressable(
            pressedScale: 0.96,
            onTap: onAddField,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 18, color: AppColors.accent),
                const SizedBox(width: Sp.x1),
                Text(
                  'Track something else',
                  style: AppText.label.copyWith(color: AppColors.accent),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.spec,
    required this.value,
    required this.onChanged,
    this.onRemove,
  });

  final JournalFieldSpec spec;
  final JournalMetricValue? value;
  final ValueChanged<JournalMetricValue?> onChanged;
  final VoidCallback? onRemove;

  Future<void> _pickTime(BuildContext context) async {
    final current = value;
    if (current == null) return;
    final initial = current.atMinuteOfDay ?? 20 * 60;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
    );
    if (picked == null) return;
    onChanged(
      JournalMetricValue(
        current.value,
        atMinuteOfDay: picked.hour * 60 + picked.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                spec.label,
                style: AppText.label.copyWith(color: AppColors.inkSoft),
              ),
            ),
            if (v != null)
              Semantics(
                button: true,
                label: 'Clear ${spec.label}',
                child: Pressable(
                  pressedScale: 0.9,
                  onTap: () => onChanged(null),
                  child: Padding(
                    padding: const EdgeInsets.all(Sp.x1),
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: AppColors.inkMuted,
                    ),
                  ),
                ),
              ),
            if (onRemove != null)
              Semantics(
                button: true,
                label: 'Stop tracking ${spec.label}',
                child: Pressable(
                  pressedScale: 0.9,
                  onTap: onRemove,
                  child: Padding(
                    padding: const EdgeInsets.all(Sp.x1),
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 15,
                      color: AppColors.inkMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        if (spec.isRating)
          _RatingDots(
            spec: spec,
            value: v?.value,
            onChanged: (r) =>
                onChanged(r == null ? null : JournalMetricValue(r)),
          )
        else
          _Stepper(
            spec: spec,
            value: v,
            onChanged: onChanged,
            onPickTime: spec.hasTime && v != null
                ? () => _pickTime(context)
                : null,
          ),
      ],
    );
  }
}

/// 1..max as tappable dots. Tapping the current value clears it, which is the
/// only way to un-answer a rating — there is no "0 out of 5" mood.
class _RatingDots extends StatelessWidget {
  const _RatingDots({
    required this.spec,
    required this.value,
    required this.onChanged,
  });

  final JournalFieldSpec spec;
  final double? value;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final max = spec.max.round();
    return Row(
      children: [
        for (var i = 1; i <= max; i++)
          Padding(
            padding: const EdgeInsets.only(right: Sp.x2),
            child: Semantics(
              button: true,
              selected: value != null && value!.round() == i,
              label: '${spec.label} $i of $max',
              child: Pressable(
                pressedScale: 0.9,
                onTap: () => onChanged(value?.round() == i ? null : i * 1.0),
                child: AnimatedContainer(
                  duration: Motion.fast,
                  curve: Motion.curve,
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value != null && value!.round() >= i
                        ? AppColors.tonalFill(AppColors.accent)
                        : Elevation.surfaceAt(1),
                    border: Border.all(
                      color: value != null && value!.round() == i
                          ? AppColors.accent.withValues(alpha: 0.6)
                          : AppColors.divider,
                    ),
                  ),
                  child: Text(
                    '$i',
                    style: AppText.label.copyWith(
                      color: value != null && value!.round() >= i
                          ? AppColors.accent
                          : AppColors.inkMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.spec,
    required this.value,
    required this.onChanged,
    this.onPickTime,
  });

  final JournalFieldSpec spec;
  final JournalMetricValue? value;
  final ValueChanged<JournalMetricValue?> onChanged;
  final VoidCallback? onPickTime;

  void _bump(double delta) {
    final current = value;
    // The first tap on + lands on one step; the first tap on − lands on a real
    // zero, because "none today" is an answer worth being able to give in one
    // tap rather than something you have to step down to.
    if (current == null) {
      onChanged(JournalMetricValue(delta > 0 ? spec.step : 0));
      return;
    }
    final next = (current.value + delta).clamp(0.0, spec.max).toDouble();
    onChanged(
      JournalMetricValue(next, atMinuteOfDay: current.atMinuteOfDay),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = value;
    return Row(
      children: [
        _StepButton(
          icon: Icons.remove_rounded,
          semanticLabel: 'Less ${spec.label}',
          onTap: v != null && v.value <= 0 ? null : () => _bump(-spec.step),
        ),
        SizedBox(
          width: 96,
          child: Text(
            v == null ? '—' : spec.formatWithUnit(v.value),
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(
              color: v == null ? AppColors.inkMuted : AppColors.ink,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        _StepButton(
          icon: Icons.add_rounded,
          semanticLabel: 'More ${spec.label}',
          onTap: v != null && v.value >= spec.max
              ? null
              : () => _bump(spec.step),
        ),
        if (onPickTime != null) ...[
          const SizedBox(width: Sp.x3),
          Pressable(
            pressedScale: 0.94,
            onTap: onPickTime,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x3,
                vertical: Sp.x2,
              ),
              decoration: BoxDecoration(
                color: Elevation.surfaceAt(1),
                borderRadius: BorderRadius.circular(R.pill),
                border: Border.all(color: AppColors.divider),
              ),
              child: Text(
                v?.atMinuteOfDay == null
                    // Prompting for the LAST one is the point: a 200 mg
                    // morning coffee and a 200 mg evening one are the same
                    // dose and a completely different night.
                    ? 'Last at…'
                    : formatMinuteOfDay(v!.atMinuteOfDay!),
                style: AppText.label.copyWith(
                  color: v?.atMinuteOfDay == null
                      ? AppColors.inkMuted
                      : AppColors.accent,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: Pressable(
        pressedScale: enabled ? 0.9 : 1.0,
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Elevation.surfaceAt(1),
            border: Border.all(color: AppColors.divider),
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled ? AppColors.ink : AppColors.inkMuted,
          ),
        ),
      ),
    );
  }
}
