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

/// Arms [engine] with the next scheduled occurrence, if one exists and it
/// differs from [currentArmedEpoch] (unix seconds) — the "don't hammer the
/// strap on every sync" rule. Returns the newly-armed epoch on a confirmed
/// write, or null when nothing needed arming (no enabled day, or the target
/// is already what's armed) or the write itself was refused/failed.
///
/// Pure I/O orchestration only: the occurrence math is [nextAlarmOccurrence],
/// tested independently with no engine, and the wire form is whatever
/// `engine.setAlarm` already sends (rev1 gen4 / gen5 rich — unchanged here).
Future<int?> armNextScheduledOccurrence({
  required BleEngine engine,
  required List<AlarmScheduleEntry> schedule,
  required int? currentArmedEpoch,
  DateTime? now,
}) async {
  final next = nextAlarmOccurrence(schedule, now ?? DateTime.now());
  if (next == null) return null;
  final epoch = next.millisecondsSinceEpoch ~/ 1000;
  if (epoch == currentArmedEpoch) return null;
  final armed = await engine.setAlarm(next);
  if (armed == null) return null;
  return armed.millisecondsSinceEpoch ~/ 1000;
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

/// Whether the latch-failure safety notification should fire for [epoch]: the
/// toggle is on, [epoch] is STILL the confirmation machine's current target (a
/// newer arm, or a cancel, superseded it), and the strap never confirmed it.
/// Pure — no notification plumbing, no clock reads — so the decision itself is
/// unit-testable without a fake OS notification sink.
bool alarmLatchFailed(AlarmConfirmation a, int epoch, {required bool enabled}) =>
    enabled && a.targetEpoch == epoch && !a.confirmed;
