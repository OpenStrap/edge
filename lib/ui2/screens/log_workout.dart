// LOG A WORKOUT — the two places the athlete owns the times, and the review
// screen the auto-detector has been writing to for months with nobody reading.
//
// WHY THIS FILE EXISTS AT ALL. `LocalRepository.logManualWorkout` and
// `setWorkoutWindow` have been implemented, tested and reachable from the
// coach's tool layer since the manual-session work landed, and reachable from
// the app from nowhere: the UI rebuild deleted `lib/ui/workouts/` and lib/ui2
// never replaced this part of it. Back-logging a session, or widening one the
// detector clipped, meant asking a BYOK language model to do it for you.
//
// The same deletion orphaned `workout_suggestions`. The detector still fills
// that table on every derive; `activeWorkoutSuggestions()` had exactly one
// reader and it only ever DISMISSED. `kRouteWorkoutSuggestion` survived, the
// tab mapping survived, and the destination did not — so the deep link fell
// through `screenForRoute`'s `_ => null` and landed on the plain Workouts tab.
//
// ONE WRITE SEAM. Confirming a detected bout is not a special kind of write:
// it is a manual session over the window the detector proposed, so it goes
// through `logManualWorkout` like every other. That is what gets it a strain
// and a calorie figure scored from the 1 Hz substrate — the old confirm path
// hand-built a row with neither and every confirmed suggestion landed in the
// log showing blanks. It also retires the suggestion on its own, inside the
// repo, via `supersededSuggestionIds`.
//
// WHAT THE DETECTOR REPORTS. The hard-effort CORE, not wall clock — see the
// header of `compute/manual_session.dart`. An hour of mixed training routinely
// detects as ~25 minutes, which is correct for a prompt and wrong for a log
// entry, and is exactly why "Adjust the times" sits beside "Log it" rather
// than three screens away.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../compute/manual_session.dart';
import '../../data/day_label.dart' show calendarDaysBetween;
import '../../models/activity_suggestion.dart';
import 'detected_activities.dart';
import '../../data/db.dart';
import '../../data/journal_fields.dart' show formatMinuteOfDay;
import '../../data/local_repository.dart';
import '../../health/health_export.dart';
import '../../health/health_workout_import.dart' show rememberDeletedUuid;
import '../../l10n/app_localizations.dart';
import '../../l10n/date_text.dart';
import '../../state/app_state.dart';
import '../activity/catalogue.dart';
import '../profile/profile.dart' show SetRow, settingsGroup;
import '../ui2.dart';
import 'home_screen.dart' show monthShortName, repoOf, weekdayShortName;

/// One detected bout, as this screen needs it. Built straight off a
/// `workout_suggestions` row.
class Suggestion {
  const Suggestion({
    required this.id,
    required this.startTs,
    required this.endTs,
    this.sport,
    this.peakBpm,
    this.avgBpm,
  });

  final String id;
  final int startTs, endTs;
  final String? sport;
  final int? peakBpm, avgBpm;

  int get durationMin => ((endTs - startTs) / 60).round();

  /// The catalogue entry behind `sport`, when this build knows it. Null is
  /// carried rather than defaulted so the row can say what it was told.
  Activity? get activity => activityByName(sport);

  /// Null when the row is malformed — a suggestion with no window is not a
  /// suggestion, and it must not reach a screen that offers to log it.
  static Suggestion? from(Map<String, dynamic> r) {
    final id = r['id'];
    final s = (r['start_ts'] as num?)?.toInt();
    final e = (r['end_ts'] as num?)?.toInt();
    if (id is! String || s == null || e == null || e <= s) return null;
    return Suggestion(
      id: id,
      startTs: s,
      endTs: e,
      sport: r['sport'] as String?,
      peakBpm: (r['peak_bpm'] as num?)?.toInt(),
      avgBpm: (r['avg_bpm'] as num?)?.toInt(),
    );
  }
}

// ══════════════════ THE REVIEW SCREEN ══════════════════

/// Where "Did you work out?" lands. Every active bout, each with the two
/// answers that are honest — it happened, or it didn't — and the third that
/// matters more than either: the window is wrong.
class WorkoutSuggestionScreen extends DetectedActivitiesScreen {
  WorkoutSuggestionScreen({super.key, List<Suggestion>? preloaded, super.focusId})
      : super(preloaded: preloaded?.map((s) => ActivitySuggestion(
          id: s.id, kind: ActivityKind.workout, startTs: s.startTs, endTs: s.endTs,
          revision: 0, details: {'sport': s.sport, 'peak_bpm': s.peakBpm, 'avg_bpm': s.avgBpm},
        )).toList());
}

/// Today / Yesterday / "Mon 11 Aug", against the real calendar day rather than
/// a 24-hour subtraction — the day after a spring-forward is 23 hours long.
String dayLabel(DateTime at, {DateTime? now, AppLocalizations? l}) {
  final n = now ?? DateTime.now();
  final d = DateTime(at.year, at.month, at.day);
  final diff = calendarDaysBetween(d, n);
  if (diff == 0) return l?.logWorkoutToday ?? 'Today';
  if (diff == 1) return l?.logWorkoutYesterday ?? 'Yesterday';
  return l?.localeName.startsWith('ru') == true
      ? localizedDate(d, l!.localeName, pattern: 'EEE d MMM')
      : '${weekdayShortName(d.weekday, l)} ${d.day} ${monthShortName(d.month, l)}';
}


class LogWorkout extends StatefulWidget {
  const LogWorkout({
    super.key,
    this.sessionId,
    this.suggestion,
    this.start,
    this.end,
    this.activity,
    this.title,
    this.spans,
    this.now,
    this.importedUuid,
  });

  final String? sessionId;
  final ActivitySuggestion? suggestion;
  final DateTime? start, end;
  final Activity? activity;

  /// Null means "use the default heading" — kept null rather than defaulted
  /// in the constructor so the default can be localized with a BuildContext,
  /// which a `const` field initializer does not have.
  final String? title;

  /// The windows already in the log, for the live overlap check. Injected in
  /// tests; null means read them from the repo.
  final List<SessionSpan>? spans;

  /// Injected in tests so "that hasn't happened yet" is deterministic.
  final DateTime? now;

  /// Set when this scores an imported workout (#325): the saved session
  /// replaces that import, so the workout is not listed and counted twice.
  final String? importedUuid;

  @override
  State<LogWorkout> createState() => _LogWorkoutState();
}

class _LogWorkoutState extends State<LogWorkout> {
  late DateTime _start;
  late DateTime _end;
  late Activity _activity;
  List<SessionSpan> _spans = const [];
  bool _saving = false;
  String? _wrote;
  ActivitySuggestion? _suggestion;

  @override
  void initState() {
    super.initState();
    _suggestion = widget.suggestion;
    final now = widget.now ?? DateTime.now();
    // An hour, ending on the last whole hour. A form that opens on "now to
    // now" is a form whose first state is invalid.
    final defaultEnd = DateTime(now.year, now.month, now.day, now.hour);
    _end = widget.end ?? defaultEnd;
    _start = widget.start ?? _end.subtract(Motion.tick * 3600);
    _activity = widget.activity ?? (widget.suggestion != null ? const Activity('Other', LucideIcons.activity, C.domMove, Track.duration, null) : quickStart.first);
    if (widget.spans != null) {
      _spans = widget.spans!;
    } else {
      _loadSpans();
    }
  }

  Future<void> _loadSpans() async {
    final repo = repoOf(context);
    if (repo == null) return;
    try {
      final s = await repo.savedSessionSpans();
      if (mounted) setState(() => _spans = s);
    } catch (_) {/* the write seam re-checks anyway */}
  }

  int get _startSec => _start.millisecondsSinceEpoch ~/ 1000;
  int get _endSec => _end.millisecondsSinceEpoch ~/ 1000;

  /// The live verdict, from the SAME pure function the repo refuses on. Null
  /// means the window is acceptable.
  ManualWindowError? get _invalid => validateManualWindow(
        startSec: _startSec,
        endSec: _endSec,
        nowSec:
            (widget.now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
        existing: _spans,
        // A retime must not collide with itself; a new entry's id is derived
        // from its start second, so re-logging the same window updates that
        // row rather than colliding with it.
        editingId: widget.sessionId ?? manualSessionId(_startSec),
      );

  Future<void> _pickDate() async {
    final now = widget.now ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    final span = _end.difference(_start);
    setState(() {
      _start = DateTime(
          picked.year, picked.month, picked.day, _start.hour, _start.minute);
      _end = _start.add(span);
    });
  }

  Future<void> _pickTime({required bool isStart}) async {
    final at = isStart ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: at.hour, minute: at.minute),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        final span = _end.difference(_start);
        _start = DateTime(_start.year, _start.month, _start.day, picked.hour,
            picked.minute);
        _end = _start.add(span);
      } else {
        var e = DateTime(
            _start.year, _start.month, _start.day, picked.hour, picked.minute);
        // Past midnight. A late run that finishes at 00:20 is an ordinary
        // session, not an invalid window — the alternative is asking the user
        // for a second date to express it.
        //
        // The NEXT CALENDAR DAY at the picked wall time, built from date
        // fields — not +24h of absolute Duration, which lands at 23:20 or
        // 01:20 on the two transition nights a year and saves a window an
        // hour off the one the user picked. Same trap as `_exportDay`'s
        // `dayEnd` in health_export.dart.
        if (!e.isAfter(_start)) {
          e = DateTime(_start.year, _start.month, _start.day + 1, picked.hour,
              picked.minute);
        }
        _end = e;
      }
    });
  }

  Future<void> _pickActivity() async {
    final picked = await showModalBottomSheet<Activity>(
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: sheetMotion(context),
      backgroundColor: P.of(context).card,
      shape: const RoundedRectangleBorder(borderRadius: R.rXl),
      builder: (_) => const _TypeSheet(),
    );
    if (picked != null) setState(() => _activity = picked);
  }

  Future<void> _save() async {
    final repo = repoOf(context);
    if (repo == null || _saving || _invalid != null) return;
    final nav = Navigator.of(context);
    final app = appOf(context);
    final l = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _wrote = null;
    });
    try {
      if (_suggestion case final suggestion?) {
        await repo.confirmActivity(suggestion, startTs: _startSec, endTs: _endSec, workoutType: _activity.typeKey);
        app?.insightsRevision.value++;
        if (mounted) nav.pop(true);
        return;
      }
      final r = widget.sessionId == null
          ? await repo.logManualWorkout(
              startTs: _startSec, endTs: _endSec, type: _activity.typeKey)
          : await repo.setWorkoutWindow(widget.sessionId!,
              startTs: _startSec, endTs: _endSec);
      if (widget.importedUuid case final uuid?) {
        if (!await replaceImportWithScored(repo, uuid, r)) {
          if (!mounted) return;
          setState(() {
            _saving = false;
            _wrote = l?.logWorkoutImportedHrGone ??
                'Heart rate for this workout is no longer stored, so the band '
                    'cannot score it.';
          });
          return;
        }
      } else {
        // Both branches: a new session and a RETIMED one both change what the
        // health store should hold for that window (#130).
        await HealthExporter.exportWorkoutId(
            (r['workout_id'] ?? widget.sessionId) as String?);
      }
      // Say what was actually banked. A window with no 1 Hz substrate left
      // behind it — anything past the `rawRetentionDays` retention, or a
      // stretch the band was off — is saved UNSCORED, and a screen that pops
      // silently would let the athlete believe a strain was computed for it.
      app?.insightsRevision.value++;
      if (r['unscored'] == true) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _wrote = l?.logWorkoutUnscoredSaved ??
              'Saved. No heart rate was recorded over that window, so it '
                  'has no strain and no calorie figure — the times are all this '
                  'one carries.';
        });
        return;
      }
      nav.pop(true);
    } on ActivityReviewException catch (e) {
      try {
        final pending = await repo.pendingActivities();
        if (!mounted) return;
        for (final latest in pending) {
          if (latest.id != _suggestion?.id || latest.revision == _suggestion?.revision) {
            continue;
          }
          _suggestion = latest;
          _start = DateTime.fromMillisecondsSinceEpoch(latest.startTs * 1000);
          _end = DateTime.fromMillisecondsSinceEpoch(latest.endTs * 1000);
        }
      } catch (_) {
        // Keep the old revision: another save must still recheck it. A failed
        // reload must not leave the save button permanently busy.
      } finally {
        if (mounted) {
          setState(() { _saving = false; _wrote = e.message; });
        }
      }
    } on ManualWindowException catch (e) {
      if (mounted) {
        setState(() { _saving = false; _wrote = e.error.message; });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _wrote = l?.logWorkoutCouldNotSave ?? 'Could not save that — try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final bad = _invalid;
    final mins = _end.difference(_start).inMinutes;
    final retime = widget.sessionId != null;
    final title = widget.title ?? (l?.logWorkoutDefaultTitle ?? 'Log a past workout');
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(title,
                sub: retime
                    ? (l?.logWorkoutWindowRescoredSub ?? 'THE WINDOW, RE-SCORED')
                    : (l?.logWorkoutYourOwnTimesSub ?? 'YOUR OWN TIMES')),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                settingsGroup(c, l?.logWorkoutWhenGroup ?? 'When', [
                  if (!retime)
                    SetRow(_activity.icon, _activity.color,
                        l?.logWorkoutActivityLabel ?? 'Activity',
                        value: _activity.displayName(c),
                        onTap: _pickActivity,
                      ),
                  SetRow(LucideIcons.calendar, C.blue,
                      l?.logWorkoutDateLabel ?? 'Date',
                      value: dayLabel(_start, now: widget.now, l: l),
                      onTap: _pickDate),
                  SetRow(LucideIcons.play, C.green,
                      l?.logWorkoutStartedLabel ?? 'Started',
                      value:
                          formatMinuteOfDay(_start.hour * 60 + _start.minute),
                      onTap: () => _pickTime(isStart: true)),
                  SetRow(LucideIcons.square, C.orange,
                      l?.logWorkoutEndedLabel ?? 'Ended',
                      value: formatMinuteOfDay(_end.hour * 60 + _end.minute),
                      sub: _end.day != _start.day
                          ? (l?.logWorkoutNextMorningSub ?? 'the next morning')
                          : '',
                      onTap: () => _pickTime(isStart: false)),
                  SetRow(LucideIcons.timer, C.purple,
                      l?.logWorkoutLengthLabel ?? 'Length',
                      value: mins > 0 ? '$mins min' : '—',
                      chevron: false),
                ]),
                const SizedBox(height: S.x4),
                if (bad != null)
                  StatusCard(
                      l?.logWorkoutWindowInvalidTitle ?? 'That window will not save',
                      bad.message,
                      icon: LucideIcons.triangleAlert)
                else if (_wrote != null)
                  StatusCard(
                      retime
                          ? (l?.logWorkoutTimesUpdatedTitle ?? 'Times updated')
                          : (l?.logWorkoutLoggedTitle ?? 'Workout logged'),
                      _wrote!, icon: LucideIcons.circleCheck)
                else
                  StatusCard(
                    l?.logWorkoutScoredTitle ?? 'Scored from what the band recorded',
                    l?.logWorkoutScoredBody ??
                        'Strain and calories come from the 1-second heart rate '
                            'inside these times, through the same method the day '
                            'uses. Nothing is estimated from the duration.',
                    icon: LucideIcons.heartPulse,
                  ),
                const SizedBox(height: S.x4),
                BigButton(
                  _saving
                      ? (l?.logWorkoutSaving ?? 'Saving…')
                      : widget.suggestion != null
                          ? (l?.activitySaveConfirm ?? 'Save and confirm')
                          : retime
                          ? (l?.logWorkoutSaveNewTimes ?? 'Save the new times')
                          : (l?.logWorkoutLogIt ?? 'Log it'),
                  icon: LucideIcons.check,
                  onTap: bad == null && !_saving ? _save : null,
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

/// The activity list, searchable. The picker proper (`ActivityPicker`) starts a
/// LIVE session; this one only names a window that has already happened.
class _TypeSheet extends StatefulWidget {
  const _TypeSheet();
  @override
  State<_TypeSheet> createState() => _TypeSheetState();
}

class _TypeSheetState extends State<_TypeSheet> {
  String _q = '';

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final q = _q.trim().toLowerCase();
    final items = q.isEmpty
        ? allActivities
        : [
            for (final a in allActivities)
              if (a.displayName(c).toLowerCase().contains(q) ||
                  a.name.toLowerCase().contains(q))
                a,
          ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x2),
            child: TextField(
              autofocus: false,
              style: F.body.copyWith(color: p.ink),
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: l?.logWorkoutSearchActivities ?? 'Search activities',
                hintStyle: F.body.copyWith(color: p.ink3),
                filled: true,
                fillColor: p.card2,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: S.x4, vertical: S.x3),
                border: const OutlineInputBorder(
                    borderRadius: R.rPill, borderSide: BorderSide.none),
              ),
            ),
          ),
          Flexible(
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(S.x6),
                    child: NoData(
                        message: l?.logWorkoutNoActivityByName ??
                            'No activity by that name'),
                  )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x6),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final a = items[i];
                        return SetRow(
                          a.icon,
                          a.color,
                          a.displayName(c),
                          chevron: false,
                          onTap: () => Navigator.of(c).pop(a));
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════ THE WORKOUTS-TAB ENTRY ══════════════════

/// Tell the app a session was written, so the Workouts tab re-reads. Null-safe
/// for a golden or a widget test, which have no AppState above them.
void bumpInsights(BuildContext c) => appOf(c)?.insightsRevision.value++;

/// The AppState, or null when there is none — same shape as [repoOf].
AppState? appOf(BuildContext c) {
  try {
    return c.read<AppState>();
  } catch (_) {
    return null;
  }
}

/// Settle a scoring save against the import it was opened from (#325).
///
/// Only a SCORED session supersedes the import. The heart-rate check runs
/// before the form opens, so a retimed window (or samples pruned meanwhile)
/// can still save unscored; that copy carries less than the import, so it is
/// removed and the import kept. False when that happened.
Future<bool> replaceImportWithScored(
    LocalRepository repo, String uuid, Map<String, dynamic> saved) async {
  final id = saved['workout_id'] as String;
  if (saved['unscored'] == true) {
    await repo.deleteWorkout(id);
    return false;
  }
  // The original already sits in the health store; exporting ours too would
  // put the same workout there twice.
  await rememberDeletedUuid(uuid);
  await LocalDb.supersedeImportedWorkout(uuid, id);
  return true;
}

/// Tapping an imported workout (#325): score its window from the band's own
/// 1 Hz heart rate through the ordinary manual-log form, or say plainly that
/// the heart rate behind it is gone. [hasHr] is injected in tests.
Future<void> scoreImportedWorkout(
  BuildContext c, {
  required String uuid,
  required DateTime start,
  required DateTime end,
  required Activity activity,
  Future<bool> Function(int startSec, int endSec)? hasHr,
}) async {
  final l = AppLocalizations.of(c);
  final s = start.millisecondsSinceEpoch ~/ 1000;
  final e = end.millisecondsSinceEpoch ~/ 1000;
  final stored = await (hasHr ??
      (s, e) async => (await LocalDb.hrSamplesInRange(s, e)).isNotEmpty)(s, e);
  if (!c.mounted) return;
  if (!stored) {
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(
      content: Text(l?.logWorkoutImportedHrGone ??
          'Heart rate for this workout is no longer stored, so the band '
              'cannot score it.'),
    ));
    return;
  }
  await Navigator.of(c).push(MaterialPageRoute<void>(
    builder: (_) => LogWorkout(
      start: start,
      end: end,
      activity: activity,
      importedUuid: uuid,
      title: l?.logWorkoutScoreWithBand ?? 'Score with band heart rate',
    ),
  ));
}

/// Pending workouts for the History tab, independent of push preferences.
Future<List<Suggestion>> activeSuggestions() async {
  try {
    return [
      for (final r in await LocalDb.activeWorkoutSuggestions())
        ?Suggestion.from(r),
    ];
  } catch (_) {
    return const [];
  }
}
