// The one exercise picker used for a first choice, adding another lift and
// changing the current one. It reads a generated on-device catalogue; opening
// it never performs a network request.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart';
import '../theme.dart';
import 'catalogue.dart';

enum ExercisePickMode { choose, add, change }

Future<String?> showExercisePicker(
  BuildContext context, {
  required ExercisePickMode mode,
  Set<String> selectedKeys = const {},
  List<String> recentKeys = const [],
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  sheetAnimationStyle: sheetMotion(context),
  backgroundColor: P.of(context).card,
  shape: const RoundedRectangleBorder(borderRadius: R.rXl),
  builder: (_) => FractionallySizedBox(
    heightFactor: .92,
    child: _ExercisePicker(
      mode: mode,
      selectedKeys: selectedKeys,
      recentKeys: recentKeys,
    ),
  ),
);

class _ExercisePicker extends StatefulWidget {
  const _ExercisePicker({
    required this.mode,
    required this.selectedKeys,
    required this.recentKeys,
  });

  final ExercisePickMode mode;
  final Set<String> selectedKeys;
  final List<String> recentKeys;

  @override
  State<_ExercisePicker> createState() => _ExercisePickerState();
}

class _ExercisePickerState extends State<_ExercisePicker> {
  static const _common = '__common__';
  static const _all = '__all__';

  String query = '';
  String filter = _common;
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<String> get categories {
    final out = {
      for (final exercise in exerciseLibrary)
        if (exercise.category.isNotEmpty) exercise.category,
    }.toList()..sort();
    return out;
  }

  List<ExerciseDef> _visible(String languageCode) {
    final needle = query.trim();
    if (needle.isNotEmpty) {
      return [
        for (final exercise in exerciseLibrary)
          if (exercise.matches(needle, languageCode)) exercise,
      ];
    }
    if (filter == _all) return exerciseLibrary;
    if (filter != _common) {
      return [
        for (final exercise in exerciseLibrary)
          if (exercise.category == filter) exercise,
      ];
    }

    // The familiar short list remains useful even after the full catalogue
    // arrives. A user's own recent lifts lead it; then the original eighteen
    // fill the rest, with keys de-duplicated in insertion order.
    final out = <ExerciseDef>[];
    final seen = <String>{};
    for (final key in widget.recentKeys) {
      final exercise = exerciseByKey(key);
      if (exercise != null && seen.add(key)) out.add(exercise);
    }
    for (final exercise in exerciseLibrary.take(coreExerciseCount)) {
      if (seen.add(exercise.key)) out.add(exercise);
    }
    return out;
  }

  String _title(AppLocalizations? l) => switch (widget.mode) {
    ExercisePickMode.choose =>
      l?.activityExercisePickerChooseTitle ?? 'Choose exercise',
    ExercisePickMode.add => l?.activityLiveAddExerciseTitle ?? 'Add exercise',
    ExercisePickMode.change =>
      l?.activityExercisePickerChangeTitle ?? 'Change exercise',
  };

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final l = AppLocalizations.of(context);
    final languageCode = Localizations.localeOf(context).languageCode;
    final visible = _visible(languageCode);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: S.x4,
          right: S.x4,
          top: S.x4,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_title(l), style: F.t2.copyWith(color: p.ink)),
                ),
                Pressable(
                  semanticLabel: l?.actionCancel ?? 'Cancel',
                  onTap: () => Navigator.pop(context),
                  child: Icon(LucideIcons.x, size: 20, color: p.ink3),
                ),
              ],
            ),
            const SizedBox(height: S.x3),
            Container(
              constraints: const BoxConstraints(minHeight: S.tap),
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
              child: Row(
                children: [
                  Icon(LucideIcons.search, size: 17, color: p.ink3),
                  const SizedBox(width: S.x2),
                  Expanded(
                    child: Semantics(
                      label:
                          l?.activityExercisePickerSearchLabel ??
                          'Search exercises',
                      textField: true,
                      child: TextField(
                        controller: search,
                        autofocus: false,
                        onChanged: (value) => setState(() => query = value),
                        style: F.body.copyWith(color: p.ink),
                        cursorColor: p.on(C.purple),
                        decoration: InputDecoration.collapsed(
                          hintText:
                              l?.activityExercisePickerSearchHint(
                                exerciseLibrary.length,
                              ) ??
                              'Search ${exerciseLibrary.length} exercises',
                          hintStyle: F.body.copyWith(color: p.ink3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: S.x3),
            SizedBox(
              height: S.tap,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _filter(
                    p,
                    _common,
                    l?.activityExercisePickerCommonFilter ?? 'Common',
                  ),
                  _filter(p, _all, l?.activityExercisePickerAllFilter ?? 'All'),
                  for (final category in categories)
                    _filter(p, category, category),
                ],
              ),
            ),
            const SizedBox(height: S.x2),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.searchX, size: 28, color: p.ink3),
                          const SizedBox(height: S.x3),
                          Text(
                            l?.activityExercisePickerNoMatch ??
                                'No exercises match that',
                            style: F.body.copyWith(color: p.ink3),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: visible.length,
                      separatorBuilder: (_, _) =>
                          Divider(color: p.line, height: 1),
                      itemBuilder: (_, index) =>
                          _row(p, visible[index], languageCode),
                    ),
            ),
            Divider(color: p.line, height: 1),
            Pressable(
              onTap: () => launchUrl(
                Uri.parse(
                  'https://openstrap.github.io/edge/notice.html'
                  '#wger-exercise-data',
                ),
                mode: LaunchMode.externalApplication,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x2),
                child: Text(
                  l?.activityExercisePickerWgerCredit ??
                      'Exercise catalogue from wger · available offline',
                  textAlign: TextAlign.center,
                  style: F.over.copyWith(color: p.ink3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filter(P p, String value, String label) {
    final selected = filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: S.x2),
      child: Pressable(
        onTap: () => setState(() {
          filter = value;
          query = '';
          search.clear();
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x2),
          decoration: BoxDecoration(
            color: selected ? p.fill(C.purple) : p.card2,
            borderRadius: R.rPill,
          ),
          child: Text(
            label,
            style: F.cap.copyWith(
              color: selected ? p.inkOnFill : p.ink2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(P p, ExerciseDef exercise, String languageCode) {
    final l = AppLocalizations.of(context);
    final label = exercise.labelFor(languageCode);
    final selected = widget.selectedKeys.contains(exercise.key);
    final sourceUrl = exercise.sourceUrl;
    final details = <String>[
      if (exercise.category.isNotEmpty) exercise.category,
      if (exercise.equipment.isNotEmpty) exercise.equipment.take(2).join(', '),
    ].join(' · ');
    final sourceLabel =
        l?.activityExercisePickerSourceLabel(label) ??
        'View source and credits for $label';
    return Row(
      children: [
        Expanded(
          child: Pressable(
            onTap: () => Navigator.pop(context, exercise.key),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: F.body.copyWith(color: p.ink)),
                        if (details.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            details,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: F.over.copyWith(color: p.ink3),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(
                      LucideIcons.circleCheck,
                      size: 18,
                      color: p.on(C.purple),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (sourceUrl != null)
          Tooltip(
            message: sourceLabel,
            child: Pressable(
              semanticLabel: sourceLabel,
              onTap: () => launchUrl(
                Uri.parse(sourceUrl),
                mode: LaunchMode.externalApplication,
              ),
              child: SizedBox(
                width: S.tap,
                height: S.tap,
                child: Icon(LucideIcons.info, size: 17, color: p.ink3),
              ),
            ),
          ),
      ],
    );
  }
}
