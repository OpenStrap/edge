// SQLite's JSON1, answered in Dart.
//
// sqflite on Android runs on the phone's OWN SQLite, and some builds ship
// without JSON1 (seen on Android 11, 12 and 13): every `json_valid`,
// `json_type`, `json_extract` or `json_each` in a query then throws `no such
// function` / `no such table`. A derive pass that hit one of those queries
// skipped the day with reason "error", on every day, for good (#912).
//
// `LocalDb.hasJson1` says whether the phone has it. Where it does not, each
// reader below answers the same question from the stored payload. They mirror
// the SQL they stand in for, including its NULLs, and a test holds the two to
// the same answers.

import 'dart:convert';

/// (isValidJson, value). `json_valid()` false for anything that is not JSON.
(bool, Object?) _parse(Object? payload) {
  if (payload is! String || payload.isEmpty) return (false, null);
  try {
    return (true, jsonDecode(payload));
  } catch (_) {
    return (false, null);
  }
}

/// Walks object keys. (present, value): present is false when any step is
/// missing, the way `json_type()` is NULL for an absent path.
(bool, Object?) _lookup(Object? node, List<String> path) {
  for (final k in path) {
    if (node is! Map || !node.containsKey(k)) return (false, null);
    node = node[k];
  }
  return (true, node);
}

num? _num(Object? v) => v is num ? v : null;

/// `LocalDb.storedNightClock`: the onset instant and the clock it froze, or
/// null for a malformed bundle, a skip marker, or a skipped row.
({num? onsetMs, num? onsetClockSec})? storedNightClockOf(
  Object? payload, {
  required bool skippedColumn,
}) {
  final (ok, doc) = _parse(payload);
  if (!ok || skippedColumn || _lookup(doc, ['skipped']).$2 == true) return null;
  return (
    onsetMs: _num(_lookup(doc, ['sleep', 'window', 'value', 'onset_ms']).$2),
    onsetClockSec: _num(_lookup(doc, ['scalars', 'sleep_onset_sec']).$2),
  );
}

/// `LocalDb.recentDayScalars`: each key's `scalars.<key>` when it is a number,
/// else null (a malformed bundle nulls every key).
Map<String, num?> dayScalarsOf(Object? payload, List<String> keys) {
  final (ok, doc) = _parse(payload);
  return {
    for (final k in keys) k: ok ? _num(_lookup(doc, ['scalars', k]).$2) : null,
  };
}

/// `LocalDb.daysWithSleepTst`: a real `sleep.accounting.value.tst_sec`.
bool hasSleepTst(Object? payload) {
  final (ok, doc) = _parse(payload);
  return ok &&
      _lookup(doc, ['sleep', 'accounting', 'value', 'tst_sec']).$2 != null;
}

/// `LocalDb._pastDayFreshnessFacts`: `skipped`, `has_sleep`, `no_sleep` and
/// `readiness` as 1/0/null. Empty for a malformed bundle.
Map<String, Object?> freshnessFactsOf(Object? payload) {
  final (ok, doc) = _parse(payload);
  if (!ok) return const {};
  final skipped = _lookup(doc, ['skipped']);
  final tst = _lookup(doc, ['sleep', 'accounting', 'value', 'tst_sec']);
  final flags = _lookup(doc, ['flags']).$2;
  final readiness = _lookup(doc, ['scalars', 'readiness']);
  return {
    'skipped': skipped.$1 ? (skipped.$2 == true ? 1 : 0) : null,
    'has_sleep': tst.$1 && tst.$2 != null ? 1 : 0,
    'no_sleep': flags is List
        ? (flags.any((f) => f == 'NO_SLEEP_DETECTED' || f == 'SLEEP_REJECTED')
            ? 1
            : 0)
        : null,
    'readiness': readiness.$1 ? (readiness.$2 is num ? 1 : 0) : null,
  };
}

/// The oldest day label in a stored `crossday_input` document: `days[0].date`.
String? crossdayInputFirstDateOf(Object? payload) {
  final (ok, doc) = _parse(payload);
  if (!ok) return null;
  final days = _lookup(doc, ['days']).$2;
  if (days is! List || days.isEmpty) return null;
  final first = days.first;
  final date = first is Map ? first['date'] : null;
  return date is String ? date : null;
}
