/// PURE policy for the frozen personal movement floor.
///
/// The floor is a SINGLE persisted personal scalar, not a per-day value: once
/// committed it is applied to every day, past and future. That is the whole
/// point of freezing it — a floor derived from the signal it thresholds cancels
/// the trend it exists to report if it keeps tracking the user (measured on real
/// substrate: 37 active minutes at 1x, 1.5x, 2x AND 3x activity when
/// recomputed, versus 23 -> 254 frozen).
///
/// Because it is one shared scalar, resolving it is a READ-MODIFY-WRITE against
/// state every day of a sweep touches. `DerivationEngine.run()` dispatches days
/// NEWEST-FIRST through a concurrent worker pool, so the decisions below have to
/// be order-independent or the frozen floor is decided by a race. These helpers
/// are pure so that property is unit-testable without a database.
library;

import '../data/day_label.dart';

/// The `YYYY-MM-DD` label [back] calendar days before [dayId].
///
/// CALENDAR arithmetic, never `Duration`. `DateTime.subtract(Duration(days: n))`
/// is ABSOLUTE: from local midnight on 2026-03-10 (US), subtracting 24 h lands
/// at 23:00 on 2026-03-07 because 2026-03-08 was only 23 h long — so the walk
/// SKIPS 2026-03-08 entirely and the caller mis-counts the gap. Feeding an
/// out-of-range day field to the `DateTime` constructor normalises correctly.
String? dayLabelBefore(String dayId, int back) {
  final d = DateTime.tryParse(dayId);
  if (d == null) return null;
  return dayLabelOf(DateTime(d.year, d.month, d.day - back));
}

/// Consecutive days immediately before [dayId] with no entry in [have].
///
/// A missing `dyn_p90` daily summary means the band produced no usable motion
/// that day, i.e. it was not worn. Used only as a re-freeze trigger: a long gap
/// suggests the body/device relationship may have changed enough that the frozen
/// floor should be re-estimated.
///
/// Returns 0 when [have] is empty — an empty history is "no information", not "a
/// 60-day gap", and must not be allowed to trigger a re-freeze.
int wearGapDays({
  required Set<String> have,
  required String dayId,
  int maxScan = 60,
}) {
  if (have.isEmpty) return 0;
  var gap = 0;
  for (var back = 1; back <= maxScan; back++) {
    final label = dayLabelBefore(dayId, back);
    if (label == null) return gap;
    if (have.contains(label)) break;
    gap++;
  }
  return gap;
}

/// Age of the frozen floor as seen from [dayId], NEVER negative.
///
/// A day BEFORE the freeze date is not a stale floor — it is a backfill. The
/// previous `.abs()` made every historical re-derive look maximally stale, which
/// matters because a `kAlgoVersion` bump re-derives days newest-first: walking
/// backwards past `maxAgeDays` tripped the staleness rule and re-froze the
/// shared floor onto an OLDER `frozenOn`, which could then trip again on the
/// next real derive. Clamping to 0 makes a backfill day simply consume the
/// stored floor, which is what "frozen" means.
int daysSinceFrozen({required String frozenOn, required String dayId}) {
  final from = DateTime.tryParse(frozenOn);
  final to = DateTime.tryParse(dayId);
  if (from == null || to == null) return 0;
  // UTC, not `.difference()` on the parsed (local) DateTimes directly: the
  // same spring-forward trap `dayLabelBefore` above is built to avoid. A span
  // crossing the one short day loses an hour of wall-clock duration, so
  // `.inDays` floors a real 10-day gap to 9.
  final fromUtc = DateTime.utc(from.year, from.month, from.day);
  final toUtc = DateTime.utc(to.year, to.month, to.day);
  final diff = toUtc.difference(fromUtc).inDays;
  return diff > 0 ? diff : 0;
}

/// May [dayId] commit (or re-commit) the shared floor?
///
/// A day may only move the floor FORWARD in time. Without this, a backfill day
/// in a newest-first sweep could overwrite a freeze that a newer day had just
/// established, making the persisted floor — and therefore every day's
/// `active_min` — depend on which worker in the pool finished last.
///
/// This is the same principle `_BaselineHistoryCache.valuesBefore` already
/// states for baselines: a sweep must not make the result depend on sweep order.
bool mayCommitFloorOn({required String? frozenOn, required String dayId}) {
  if (frozenOn == null) return true;
  return dayId.compareTo(frozenOn) >= 0;
}
