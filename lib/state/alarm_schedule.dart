// The weekly alarm schedule — pure occurrence math plus the thin engine
// orchestration that arms it, shared between AppState (foreground connect/
// sync) and background_sync.dart's headless drain, which has no AppState.
//
// [AlarmScheduleEntry.weekday] is 0=Mon..6=Sun — the same 0-indexed convention
// `workout_screen.dart` already uses for weekday array positions. This is a
// storage/UI indexing choice, not a replacement for `DateTime.weekday`
// (1=Mon..7=Sun), which every conversion below still goes through explicitly.

import '../ble/ble_engine.dart';
import '../ble/ble_state.dart' show AlarmConfirmation;

/// One weekday's slot in the schedule. Immutable — callers build a new one to
/// change a field.
class AlarmScheduleEntry {
  final int weekday; // 0=Mon..6=Sun
  final int hour;
  final int minute;
  final bool enabled;

  const AlarmScheduleEntry({
    required this.weekday,
    required this.hour,
    required this.minute,
    this.enabled = true,
  });

  AlarmScheduleEntry copyWith({int? hour, int? minute, bool? enabled}) =>
      AlarmScheduleEntry(
        weekday: weekday,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        enabled: enabled ?? this.enabled,
      );

  factory AlarmScheduleEntry.fromRow(Map<String, Object?> row) =>
      AlarmScheduleEntry(
        weekday: row['weekday'] as int,
        hour: row['hour'] as int,
        minute: row['minute'] as int,
        enabled: (row['enabled'] as int) != 0,
      );

  @override
  bool operator ==(Object other) =>
      other is AlarmScheduleEntry &&
      other.weekday == weekday &&
      other.hour == hour &&
      other.minute == minute &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(weekday, hour, minute, enabled);

  @override
  String toString() =>
      'AlarmScheduleEntry(weekday: $weekday, hour: $hour, minute: $minute, '
      'enabled: $enabled)';
}

/// The default slot for a weekday nobody has configured yet: 07:00, off. A
/// made-up ON default would arm a wake alarm nobody asked for; the honest
/// default is silence with a sensible time already dialled in.
const int defaultAlarmHour = 7;
const int defaultAlarmMinute = 0;

/// Exactly 7 entries, one per weekday, in weekday order (index == weekday). A
/// weekday absent from [stored] gets [defaultAlarmHour]:[defaultAlarmMinute],
/// disabled. This is the ONE place "unconfigured" and "configured but off"
/// are made to look the same to every caller (the UI always renders 7 rows;
/// [nextAlarmOccurrence] only ever sees a fully-populated list).
List<AlarmScheduleEntry> fillDefaultAlarmSchedule(
  List<AlarmScheduleEntry> stored,
) {
  final byWeekday = {for (final e in stored) e.weekday: e};
  return [
    for (var w = 0; w < 7; w++)
      byWeekday[w] ??
          AlarmScheduleEntry(
            weekday: w,
            hour: defaultAlarmHour,
            minute: defaultAlarmMinute,
            enabled: false,
          ),
  ];
}

/// The next enabled occurrence strictly after [now], or null when every
/// weekday is disabled (or [schedule] is empty). Wraps to next week when this
/// week's occurrence for a weekday has already passed.
///
/// CALENDAR arithmetic throughout (`DateTime(y, m, d + n, h, min)`), not
/// `Duration` multiples of a day — the same reasoning as
/// `AlarmScreenView.nextAt`: a `Duration(days: 7)` add is 168 ELAPSED hours,
/// which is a different wall-clock time across a DST change.
DateTime? nextAlarmOccurrence(List<AlarmScheduleEntry> schedule, DateTime now) {
  DateTime? best;
  for (final e in schedule) {
    if (!e.enabled) continue;
    final entryDow = e.weekday + 1; // DateTime.monday(1)..sunday(7)
    var daysAhead = (entryDow - now.weekday) % 7;
    if (daysAhead < 0) daysAhead += 7; // Dart's % can return negative
    var candidate =
        DateTime(now.year, now.month, now.day + daysAhead, e.hour, e.minute);
    // Strictly after `now` — the same instant is treated as past, so an
    // alarm never arms for "right now" (mirrors AlarmScreenView.nextAt).
    if (!candidate.isAfter(now)) {
      candidate =
          DateTime(now.year, now.month, now.day + daysAhead + 7, e.hour, e.minute);
    }
    if (best == null || candidate.isBefore(best)) best = candidate;
  }
  return best;
}

/// Result of [armNextScheduledOccurrence]. [epoch] is the newly-armed unix
/// instant, or null when nothing changed on the strap (no enabled day and
/// already unarmed, the target already matches what's armed, or the write
/// was refused/failed). [disabled] is true only when this call actively sent
/// DISABLE_ALARM because the schedule now has nothing enabled but the strap
/// still held a live arm — the case a caller must clear its own
/// persisted/optimistic epoch for.
typedef AlarmArmResult = ({int? epoch, bool disabled});

/// Arms [engine] with the next scheduled occurrence, if one exists and it
/// differs from [currentArmedEpoch] (unix seconds) — the "don't hammer the
/// strap on every sync" rule. See [AlarmArmResult] for what's returned.
///
/// Pure I/O orchestration only: the occurrence math is [nextAlarmOccurrence],
/// tested independently with no engine, and the wire form is whatever
/// `engine.setAlarm` already sends (rev1 gen4 / gen5 rich — unchanged here).
Future<AlarmArmResult> armNextScheduledOccurrence({
  required BleEngine engine,
  required List<AlarmScheduleEntry> schedule,
  required int? currentArmedEpoch,
  DateTime? now,
}) async {
  final next = nextAlarmOccurrence(schedule, now ?? DateTime.now());
  if (next == null) {
    // Nothing enabled. Toggling every weekday off individually (rather than
    // an explicit cancel-all) must not leave the strap holding its last arm
    // forever — nothing else in this flow ever tells the band to give it up.
    if (currentArmedEpoch == null) return (epoch: null, disabled: false);
    await engine.disableAlarm();
    return (epoch: null, disabled: true);
  }
  final epoch = next.millisecondsSinceEpoch ~/ 1000;
  if (epoch == currentArmedEpoch) return (epoch: null, disabled: false);
  final armed = await engine.setAlarm(next);
  if (armed == null) return (epoch: null, disabled: false);
  return (epoch: armed.millisecondsSinceEpoch ~/ 1000, disabled: false);
}

/// The weekday/hour/minute a legacy single-alarm epoch maps onto, for the
/// one-time 49→50 seed (see AppState._seedAlarmScheduleFromLegacyEpoch).
/// [epoch] is unix seconds, LOCAL wall-clock time is what the user saw when
/// they set it, so this reads `DateTime.fromMillisecondsSinceEpoch` in local
/// time (not UTC) and maps `DateTime.weekday` (1=Mon..7=Sun) to the 0-indexed
/// column via `- 1`.
AlarmScheduleEntry seedEntryFromLegacyEpoch(int epoch) {
  final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  return AlarmScheduleEntry(
    weekday: at.weekday - 1,
    hour: at.hour,
    minute: at.minute,
    enabled: true,
  );
}

/// Whether the alarm armed for [armedEpochSec] fires during tonight's
/// upcoming overnight sleep, as measured from [now]. TRUE iff the epoch is
/// non-null, strictly after [now], AND strictly before noon of the day after
/// [now]'s calendar date — the window covering the whole overnight sleep
/// ahead, whether the arm lands later tonight or in the small hours of
/// tomorrow morning. An epoch already past, or one two-or-more nights out, is
/// not "tonight". Calendar-date comparison of the two DateTimes is
/// deliberately not used: a wake alarm armed for tomorrow morning is tonight's
/// alarm even though its date differs from today's.
///
/// Pure — no AppState/DB/engine deps — so the 7pm "no alarm tonight" check can
/// be unit-tested without a clock or a strap.
///
/// CALENDAR arithmetic for the window boundary (`DateTime(y, m, d + 1, 12, 0)`),
/// not a `Duration` of hours — the same DST reasoning as [nextAlarmOccurrence]
/// above: noon tomorrow is a wall-clock instant, not 36 elapsed hours.
bool alarmArmsTonight(int? armedEpochSec, DateTime now) {
  if (armedEpochSec == null) return false;
  final at = DateTime.fromMillisecondsSinceEpoch(armedEpochSec * 1000);
  if (!at.isAfter(now)) return false;
  final endOfTonight = DateTime(now.year, now.month, now.day + 1, 12, 0);
  return at.isBefore(endOfTonight);
}

/// Whether the latch-failure safety notification should fire for [epoch]: the
/// toggle is on, [epoch] is STILL the confirmation machine's current target (a
/// newer arm, or a cancel, superseded it), and the strap never confirmed it.
/// Pure — no notification plumbing, no clock reads — so the decision itself is
/// unit-testable without a fake OS notification sink.
bool alarmLatchFailed(AlarmConfirmation a, int epoch, {required bool enabled}) =>
    enabled && a.targetEpoch == epoch && !a.confirmed;
