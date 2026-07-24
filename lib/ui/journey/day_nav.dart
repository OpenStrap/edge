// Pure day-navigation maths for the lookback ("Your day") screen — no Flutter,
// no DateTime, no intl. Days are 'YYYY-MM-DD' labels and, because they are
// always zero-padded ISO, lexicographic string order IS chronological order —
// so we compare and sort them as plain strings.
//
// Kept separate from [JourneyScreen] so the stepping/bounds rules (never past
// today, stop at the earliest recorded day, skip empty gaps) are unit-testable
// without a widget, a repo, or a database.

class DayNav {
  DayNav._();

  /// The days the user may land on: every day that has data ([available]),
  /// plus [today] and (when given) [current] — both always reachable. [today]
  /// is the entry point even before it has filled, and [current] must never be
  /// stranded outside its own bounds. Anything AFTER [today] is dropped so
  /// navigation can never step into the future. Returned sorted ASCending
  /// (oldest → newest) and de-duplicated.
  static List<String> navigableDays(
    Iterable<String> available,
    String today, {
    String? current,
  }) {
    final set = <String>{today};
    if (current != null && current.isNotEmpty && current.compareTo(today) <= 0) {
      set.add(current);
    }
    for (final d in available) {
      if (d.isNotEmpty && d.compareTo(today) <= 0) set.add(d);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// The next day AFTER [current] the user may view — the SMALLEST navigable
  /// day strictly later than [current] (so empty gaps between recorded days
  /// are skipped). Null when [current] is already at/after the latest
  /// navigable day (→ the "next" control is disabled, never entering the
  /// future). Order-independent in [navigable].
  static String? next(String current, Iterable<String> navigable) {
    String? best;
    for (final d in navigable) {
      if (d.compareTo(current) <= 0) continue;
      if (best == null || d.compareTo(best) < 0) best = d;
    }
    return best;
  }

  /// The previous day BEFORE [current] — the LARGEST navigable day strictly
  /// earlier than [current] (gaps skipped). Null when [current] is already the
  /// earliest navigable day (→ the "prev" control is disabled).
  /// Order-independent in [navigable].
  static String? prev(String current, Iterable<String> navigable) {
    String? best;
    for (final d in navigable) {
      if (d.compareTo(current) >= 0) continue;
      if (best == null || d.compareTo(best) > 0) best = d;
    }
    return best;
  }

  /// Whether the date picker may select [ymd] — true only for a day in
  /// [navigable] (a recorded/renderable day, or today). Backs the picker's
  /// `selectableDayPredicate` so an empty gap between recorded days can't be
  /// chosen, only stepped over. [navigable] is the set from [navigableDays].
  static bool isSelectable(String ymd, Iterable<String> navigable) {
    for (final d in navigable) {
      if (d == ymd) return true;
    }
    return false;
  }

  /// The earliest navigable day — the date picker's `firstDate` bound. Null
  /// when [navigable] is empty. Order-independent.
  static String? earliest(Iterable<String> navigable) {
    String? best;
    for (final d in navigable) {
      if (best == null || d.compareTo(best) < 0) best = d;
    }
    return best;
  }
}
