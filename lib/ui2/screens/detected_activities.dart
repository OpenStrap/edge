import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../compute/nap_edits.dart';
import '../../models/activity_suggestion.dart';
import '../../theme/theme_switcher.dart' show themedRoute;
import '../activity/catalogue.dart';
import '../ui2.dart';
import 'home_screen.dart';
import 'log_workout.dart';

class DetectedActivitiesScreen extends StatefulWidget {
  const DetectedActivitiesScreen({super.key, this.focusId, this.preloaded});
  final String? focusId;
  final List<ActivitySuggestion>? preloaded;
  @override
  State<DetectedActivitiesScreen> createState() =>
      _DetectedActivitiesScreenState();
}

class _DetectedActivitiesScreenState extends State<DetectedActivitiesScreen>
    with RevisionReload {
  List<ActivitySuggestion>? _items;
  String? _error;
  bool _busy = false;
  final _focusKey = GlobalKey();
  bool _focused = false;
  int _loadRevision = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void reload() {
    if (!_busy) _load();
  }

  Future<void> _load() async {
    final revision = ++_loadRevision;
    try {
      final items =
          widget.preloaded ?? await repoOf(context)!.pendingActivities();
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _items = items;
        _error = null;
      });
      if (!_focused && items.any((s) => s.id == widget.focusId)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = _focusKey.currentContext;
          if (target != null) {
            _focused = true;
            Scrollable.ensureVisible(target);
          }
        });
      }
    } catch (_) {
      if (mounted && revision == _loadRevision) {
        setState(
          () => _error =
              AppLocalizations.of(context)?.activityLoadFailed ??
              'Could not load activities. Try again.',
        );
      }
    }
  }

  Future<void> _act(
    ActivitySuggestion s, {
    bool discard = false,
    int? start,
    int? end,
  }) async {
    if (_busy) return;
    final repo = repoOf(context);
    if (repo == null) return;
    setState(() => _busy = true);
    String? error;
    try {
      if (discard) {
        await repo.discardActivity(s);
      } else {
        await repo.confirmActivity(
          s,
          startTs: start,
          endTs: end,
          workoutType: activityByName(s.sport)?.typeKey ?? 'other',
        );
      }
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    bumpInsights(context);
    await _load();
    if (mounted && error != null) setState(() => _error = error);
  }

  Future<void> _edit(ActivitySuggestion s) async {
    final l = AppLocalizations.of(context);
    if (s.kind == ActivityKind.workout) {
      await Navigator.of(context).push<bool>(
        themedActivityRoute(
          LogWorkout(
            suggestion: s,
            start: DateTime.fromMillisecondsSinceEpoch(s.startTs * 1000),
            end: DateTime.fromMillisecondsSinceEpoch(s.endTs * 1000),
            activity: activityByName(s.sport),
            title: l?.activityEditWorkout ?? 'Edit workout',
          ),
        ),
      );
      if (mounted) await _load();
    } else {
      final result = await Navigator.of(
        context,
      ).push<(int, int)>(themedActivityRoute(NapProposalEditor(suggestion: s)));
      if (result != null && mounted) {
        await _act(s, start: result.$1, end: result.$2);
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final items = _items;
    return Scaffold(
      backgroundColor: P.of(c).bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(l?.activityReviewTitle ?? 'Detected activities'),
            ),
            Expanded(
              child: ListView(
                padding: pad,
                children: [
                  if (_error != null)
                    StatusCard(
                      l?.activityReviewProblem ?? 'Could not finish',
                      _error!,
                      fix: l?.homeTryAgain ?? 'Try again',
                      onFix: _load,
                    ),
                  if (items == null && _error == null)
                    const Center(child: CircularProgressIndicator()),
                  if (_error == null && items != null && items.isEmpty)
                    StatusCard(
                      l?.activityNothing ?? 'Nothing to review',
                      l?.activityEmptyBody ??
                          'Possible naps and workouts will appear here.',
                    ),
                  if (items != null)
                    for (final s in items)
                      Padding(
                        key: widget.focusId == s.id
                            ? _focusKey
                            : ValueKey(s.id),
                        padding: const EdgeInsets.only(bottom: S.x3),
                        child: ActivityProposalCard(
                          suggestion: s,
                          highlighted: widget.focusId == s.id,
                          onConfirm: _busy ? null : () => _act(s),
                          onEdit: _busy ? null : () => _edit(s),
                          onDiscard: _busy
                              ? null
                              : () => _act(s, discard: true),
                        ),
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

/// Routes inherit the app's theme and reduced-motion policy.
Route<T> themedActivityRoute<T>(Widget child) =>
    themedRoute<T>((_) => child, name: child.runtimeType.toString());

class ActivityProposalCard extends StatelessWidget {
  const ActivityProposalCard({
    super.key,
    required this.suggestion,
    this.highlighted = false,
    this.onConfirm,
    this.onEdit,
    this.onDiscard,
  });
  final ActivitySuggestion suggestion;
  final bool highlighted;
  final VoidCallback? onConfirm, onEdit, onDiscard;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final nap = suggestion.kind == ActivityKind.nap;
    final accent = nap ? C.domHealth : C.domMove;
    final start = DateTime.fromMillisecondsSinceEpoch(
      suggestion.startTs * 1000,
    );
    final end = DateTime.fromMillisecondsSinceEpoch(suggestion.endTs * 1000);
    final material = MaterialLocalizations.of(c);
    String when(DateTime value) =>
        '${material.formatMediumDate(value)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(value), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(c))}';
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                nap ? LucideIcons.moon : LucideIcons.activity,
                color: p.on(accent),
                size: 20,
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(
                  nap
                      ? (l?.activityPossibleNap ?? 'Possible nap')
                      : (l?.activityPossibleWorkout ?? 'Possible workout'),
                  style: F.head.copyWith(color: p.ink),
                ),
              ),
              if (highlighted)
                Icon(LucideIcons.bell, color: p.on(accent), size: 20),
            ],
          ),
          const SizedBox(height: S.x2),
          Text(
            '${when(start)} – ${when(end)}',
            style: F.body.copyWith(color: p.ink2),
          ),
          Text(
            l?.activityLengthMinutes(suggestion.durationMin) ??
                '${suggestion.durationMin} min',
            style: F.cap.copyWith(color: p.ink3),
          ),
          const SizedBox(height: S.x3),
          Wrap(
            spacing: S.x4,
            runSpacing: S.x2,
            children: [
              _action(c, l?.activityConfirm ?? 'Confirm', onConfirm, accent),
              // The workout editor is where the sport is picked, so it says
              // that; a nap only has times to edit.
              _action(
                c,
                nap
                    ? (l?.activityEdit ?? 'Edit')
                    : (l?.activityChangeSport ?? 'Change sport'),
                onEdit,
                accent,
              ),
              // Same words as the correction on a logged nap and a night, so
              // "this was wrong" reads the same wherever the detection shows.
              // A discard is kept by window and wins over every re-detection.
              _action(
                c,
                nap
                    ? (l?.napsNotANapLabel ?? 'Not a nap')
                    : (l?.activityNotAWorkout ?? 'Not a workout'),
                onDiscard,
                C.red,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _action(
    BuildContext c,
    String label,
    VoidCallback? tap,
    Color accent,
  ) => Pressable(
    onTap: tap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: S.x2),
      child: Text(
        label,
        style: F.body.copyWith(
          color: P.of(c).on(accent),
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class DetectedActivitiesCard extends StatefulWidget {
  const DetectedActivitiesCard({super.key, this.pendingCount});
  final int? pendingCount;
  @override
  State<DetectedActivitiesCard> createState() => _DetectedActivitiesCardState();
}

class _DetectedActivitiesCardState extends State<DetectedActivitiesCard>
    with RevisionReload {
  int? _count;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _count = widget.pendingCount;
    reload();
  }

  @override
  void reload() {
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.pendingCount != null) return;
      final repo = repoOf(context);
      if (repo == null) return;
      final count = await repo.pendingActivityCount();
      if (mounted) {
        setState(() {
          _count = count;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext c) {
    // nothing pending (or not loaded yet) = no card on home. a failed load
    // isn't "nothing", so that still shows with the retry text.
    final n = _count;
    if (!_failed && (n == null || n <= 0)) return const SizedBox.shrink();
    final l = AppLocalizations.of(c);
    return Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: ActionCard(
        l?.activityReviewTitle ?? 'Detected activities',
        _failed
            ? (l?.activityLoadFailed ?? 'Could not load activities. Try again.')
            : (l?.activityPending(n!) ?? '$n to review'),
        l?.activityReview ?? 'Review',
        LucideIcons.radar,
        C.domHome,
        onTap: () => go(c, const DetectedActivitiesScreen()),
      ),
    );
  }
}

class NapProposalEditor extends StatefulWidget {
  const NapProposalEditor({super.key, required this.suggestion});
  final ActivitySuggestion suggestion;
  @override
  State<NapProposalEditor> createState() => _NapProposalEditorState();
}

class _NapProposalEditorState extends State<NapProposalEditor> {
  late DateTime _start, _end;
  @override
  void initState() {
    super.initState();
    _start = DateTime.fromMillisecondsSinceEpoch(
      widget.suggestion.startTs * 1000,
    );
    _end = DateTime.fromMillisecondsSinceEpoch(widget.suggestion.endTs * 1000);
  }

  Future<void> _pick(bool start) async {
    final value = start ? _start : _end;
    final day = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (time == null || !mounted) return;
    final picked = DateTime(
      day.year,
      day.month,
      day.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (start) {
        _start = picked;
      } else {
        _end = picked;
      }
    });
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final valid =
        manualNapWindowIsValid(
          _start.millisecondsSinceEpoch ~/ 1000,
          _end.millisecondsSinceEpoch ~/ 1000,
        ) &&
        !_end.isAfter(DateTime.now());
    final material = MaterialLocalizations.of(c);
    String label(DateTime d) =>
        '${material.formatMediumDate(d)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(c))}';
    return Scaffold(
      backgroundColor: P.of(c).bg,
      body: SafeArea(
        child: ListView(
          padding: pad,
          children: [
            NavBar(l?.activityEditNap ?? 'Edit nap'),
            ActionCard(
              l?.activityStart ?? 'Start',
              label(_start),
              l?.activityEdit ?? 'Edit',
              LucideIcons.clock,
              C.domHealth,
              onTap: () => _pick(true),
            ),
            const SizedBox(height: S.x3),
            ActionCard(
              l?.activityEnd ?? 'End',
              label(_end),
              l?.activityEdit ?? 'Edit',
              LucideIcons.clock,
              C.domHealth,
              onTap: () => _pick(false),
            ),
            const SizedBox(height: S.x4),
            if (!valid)
              StatusCard(
                l?.activityCheckTimes ?? 'Check the times',
                l?.activityNapWindow ??
                    'Choose a past window between 5 minutes and 6 hours.',
              ),
            BigButton(
              l?.activitySaveConfirm ?? 'Save and confirm',
              icon: LucideIcons.check,
              onTap: valid
                  ? () => Navigator.of(c).pop((
                      _start.millisecondsSinceEpoch ~/ 1000,
                      _end.millisecondsSinceEpoch ~/ 1000,
                    ))
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
