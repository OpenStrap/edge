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
