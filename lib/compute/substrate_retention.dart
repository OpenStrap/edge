import 'dart:convert';

import '../ble/adapters/signals.dart';
import '../data/coverage_resolver.dart';
import 'substrate.dart';

/// One exact load, plus the worker metadata needed to rebuild its open bucket.
class RetainedSubstrate {
  RetainedSubstrate({required this.version, required this.context,
    required this.revisions, required this.sub, required this.extras,
    required this.cut, this.from, this.to, this.generation,
    this.ownership = const {}});

  int version;
  final String context;
  final Map<int, int> revisions;
  final Substrate sub;
  final Map<String, Object?> extras;
  final int cut;
  final int? from, to, generation;
  final Map<InputSignal, List<OwnedSpan>> ownership;

  /// A changed closed bucket requires a cold load. Otherwise rebuild the tail
  /// from [cut], or return the whole load when every bucket is unchanged.
  int? readFrom(int version, String context, Map<int, int> revisions, int to) {
    if (version != this.version || context != this.context) return null;
    var changed = false;
    for (final b in {...this.revisions.keys, ...revisions.keys}) {
      if ((revisions[b] ?? 0) == (this.revisions[b] ?? 0)) continue;
      if (b < cut ~/ 900) return null;
      changed = true;
    }
    return changed ? cut : to + 1;
  }

  Map<String, Object?> seed(int cut) => {
    ...sub.toJson(), ...extras, 'type': 'seed', 'cut': cut,
  };
}

/// At most three loads per day: separate windows, or their shared union.
/// Both days and loads are ordered least recently used first.
class SubstrateRetention {
  final _days = <String, Map<String, RetainedSubstrate>>{};
  int _maxDays = 2;

  int get maxDays => _maxDays;
  set maxDays(int value) {
    _maxDays = value < 0 ? 0 : value;
    while (_days.length > _maxDays) {
      _days.remove(_days.keys.first);
    }
  }
  Set<String> get days => _days.keys.toSet();
  Iterable<RetainedSubstrate> get unions sync* {
    for (final loads in _days.values) {
      final union = loads['union'];
      if (union != null) yield union;
    }
  }

  RetainedSubstrate? lookup(String day, String load) {
    final loads = _days.remove(day);
    if (loads == null) return null;
    _days[day] = loads;
    final entry = loads.remove(load);
    if (entry != null) loads[load] = entry;
    return entry;
  }

  void store(String day, String load, RetainedSubstrate entry) {
    if (_maxDays == 0) return;
    final loads = _days.remove(day) ?? {};
    loads.remove(load);
    loads[load] = entry;
    while (loads.length > 3) {
      loads.remove(loads.keys.first);
    }
    _days[day] = loads;
    maxDays = _maxDays;
  }

  Map<String, Object?> extras(String day) =>
      _days[day]?.values.last.extras ?? const {};
  void remove(String day) => _days.remove(day);
  void clear() => _days.clear();
  void retainDays(Set<String> days) =>
      _days.removeWhere((day, _) => !days.contains(day));
  void rekey(int version) {
    for (final loads in _days.values) {
      for (final entry in loads.values) {
        entry.version = version;
      }
    }
  }
}

/// Only inputs consumed by the decoded loader belong here. Resolved spans
/// already carry priority, coverage and device eligibility decisions.
String substrateLoadContext(int from, int to, int generation,
    Map<InputSignal, List<OwnedSpan>> ownership) {
  final now = DateTime.now();
  return jsonEncode([
    from, to, generation, now.timeZoneName, now.timeZoneOffset.inSeconds,
    [for (var t = from - 86400; t <= to + 86400; t += 900)
      [t, tzOffsetSecondsAt(t)]],
    [for (final sig in InputSignal.values) [sig.name,
      [for (final s in ownership[sig] ?? const <OwnedSpan>[])
        [s.start, s.end, s.deviceId]]]],
  ]);
}
