// day_label.dart — THE one local-calendar day-label helper.
//
// The whole day model is keyed by LOCAL calendar dates: LocalDb labels days in
// the device's timezone, the DerivationEngine buckets raw by those labels, and
// getToday() serves the local label. A "today" computed in UTC diverges from
// that key whenever the local date != the UTC date (for a UTC+5:30 user, every
// day until ~05:30), making detail cards/trends/coach look up a day_id that
// doesn't exist (or worse, yesterday's). ALWAYS compute day labels through
// these helpers — never `DateTime.now().toUtc()...substring(0, 10)`.
//
// Epoch timestamps (session bounds, rec_ts, prune cutoffs) are absolute and are
// NOT day labels — leave those alone.

/// 'YYYY-MM-DD' of [dt]'s LOCAL calendar date. A UTC instant is converted to
/// local time first so the label always matches the device-local day model.
String dayLabelOf(DateTime dt) {
  final local = dt.isUtc ? dt.toLocal() : dt;
  String two(int x) => x.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}';
}

/// Today's LOCAL day label — the key `LocalDb`/the derivation engine file days
/// under. [now] is injectable for tests (defaults to the real clock).
String todayLabel([DateTime? now]) => dayLabelOf(now ?? DateTime.now());

/// Parse a 'YYYY-MM-DD' label into its (year, month, day) parts, or null if it
/// isn't one. Deliberately strict — a malformed label must not silently become
/// epoch 0 and delete/export the wrong window.
List<int>? _partsOf(String dayId) {
  final p = dayId.split('-');
  if (p.length != 3) return null;
  final y = int.tryParse(p[0]);
  final m = int.tryParse(p[1]);
  final d = int.tryParse(p[2]);
  if (y == null || m == null || d == null) return null;
  return [y, m, d];
}

/// Epoch SECONDS of the LOCAL midnight that STARTS day [dayId] ('YYYY-MM-DD').
/// Returns null for a malformed label.
int? localDayStartSec(String dayId) {
  final p = _partsOf(dayId);
  if (p == null) return null;
  return DateTime(p[0], p[1], p[2]).millisecondsSinceEpoch ~/ 1000;
}

/// Epoch SECONDS of the LOCAL midnight that ENDS day [dayId] — i.e. the start
/// of the NEXT local calendar day. Returns null for a malformed label.
///
/// This is deliberately NOT `localDayStartSec(dayId) + 86400`. A local calendar
/// day is only 86 400 s when there is no DST transition inside it: a
/// spring-forward day is 23 h and a fall-back day is 25 h. Using `+86400` made
/// day-window deletes/exports overrun into the NEXT day's first hour on
/// spring-forward, and leave the last hour behind on fall-back. `DateTime`'s
/// local constructor normalizes day/month/year rollover AND the wall-clock
/// offset, so "midnight of the next calendar date" is the only correct end.
int? localDayEndSec(String dayId) {
  final p = _partsOf(dayId);
  if (p == null) return null;
  return DateTime(p[0], p[1], p[2] + 1).millisecondsSinceEpoch ~/ 1000;
}

/// True local length of day [dayId] in seconds (86400 / 82800 / 90000 …), or
/// null for a malformed label.
int? localDayLengthSec(String dayId) {
  final lo = localDayStartSec(dayId);
  final hi = localDayEndSec(dayId);
  if (lo == null || hi == null) return null;
  return hi - lo;
}

/// Whole CALENDAR days from [a] to [b] (negative if [b] precedes [a]).
///
/// Anchors both dates at UTC midnight of their own year/month/day before
/// diffing, so a local-midnight `DateTime.difference(...).inDays` — which
/// floors real elapsed hours by 24 — can't undercount by 1 across a
/// spring-forward day (23h) or overcount across a fall-back day (25h). Works
/// for both local `DateTime`s and the naive local `DateTime`s produced by
/// `DateTime.tryParse('YYYY-MM-DD')`.
int calendarDaysBetween(DateTime a, DateTime b) {
  return DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}
