// The filter/sort bottom sheet for the workout list. Edits a [WorkoutFilter]
// locally and returns it on apply — the screen owns persistence, this owns
// nothing but the draft.

import 'package:flutter/material.dart';

import '../design/design.dart';
import 'workout_filter.dart';
import 'workout_types.dart';

/// Minimum-duration steps, in minutes. 0 = no floor.
const _durationSteps = <int>[0, 15, 30, 45, 60, 90];

/// Minimum-strain steps on the 0–21 scale. 0 = no floor.
const _strainSteps = <double>[0, 5, 10, 14, 17];

/// Opens the filter sheet. Returns the edited filter, or null if dismissed.
///
/// [workouts] is the unfiltered list for the current range, used only to show
/// a live match count on the apply button — nothing is mutated.
Future<WorkoutFilter?> showWorkoutFilterSheet(
  BuildContext context, {
  required WorkoutFilter current,
  required List<Map<String, dynamic>> workouts,
}) {
  return showModalBottomSheet<WorkoutFilter>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _FilterSheet(current: current, workouts: workouts),
  );
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.current, required this.workouts});
  final WorkoutFilter current;
  final List<Map<String, dynamic>> workouts;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late WorkoutFilter _draft = widget.current;

  void _toggleType(String key) {
    final next = Set<String>.from(_draft.types);
    next.contains(key) ? next.remove(key) : next.add(key);
    setState(() => _draft = _draft.copyWith(types: next));
  }

  @override
  Widget build(BuildContext context) {
    final matches = _draft.apply(widget.workouts).length;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.all(Sp.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Filter workouts', style: AppText.h2)),
                  if (!_draft.isDefault)
                    TextButton(
                      onPressed: () =>
                          setState(() => _draft = const WorkoutFilter()),
                      child: const Text('Clear'),
                    ),
                ],
              ),
              const SizedBox(height: Sp.x3),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('Type'),
                      Wrap(
                        spacing: Sp.x2,
                        runSpacing: Sp.x2,
                        children: [
                          for (final e in kWorkoutTypes)
                            ToggleChip(
                              e.$2,
                              selected: _draft.types.contains(e.$1),
                              onTap: () => _toggleType(e.$1),
                            ),
                        ],
                      ),
                      const SizedBox(height: Sp.x4),
                      _label('Minimum duration'),
                      Wrap(
                        spacing: Sp.x2,
                        runSpacing: Sp.x2,
                        children: [
                          for (final m in _durationSteps)
                            ToggleChip(
                              m == 0 ? 'Any' : '${m}m',
                              selected: _draft.minMinutes == m,
                              onTap: () => setState(
                                () => _draft = _draft.copyWith(minMinutes: m),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: Sp.x4),
                      _label('Minimum strain'),
                      Wrap(
                        spacing: Sp.x2,
                        runSpacing: Sp.x2,
                        children: [
                          for (final s in _strainSteps)
                            ToggleChip(
                              s == 0 ? 'Any' : s.toStringAsFixed(0),
                              selected: _draft.minStrain == s,
                              onTap: () => setState(
                                () => _draft = _draft.copyWith(minStrain: s),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: Sp.x4),
                      _label('Sort'),
                      Wrap(
                        spacing: Sp.x2,
                        runSpacing: Sp.x2,
                        children: [
                          for (final s in WorkoutSort.values)
                            ToggleChip(
                              s.label,
                              selected: _draft.sort == s,
                              onTap: () => setState(
                                () => _draft = _draft.copyWith(sort: s),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Sp.x4),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _draft),
                  child: Text(
                    matches == 1 ? 'Show 1 workout' : 'Show $matches workouts',
                  ),
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
}
