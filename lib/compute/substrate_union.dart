import 'dart:typed_data';

import '../ble/adapters/signals.dart';
import '../data/coverage_resolver.dart';
import 'substrate.dart';
import 'substrate_retention.dart';

typedef SubstrateUnionWindow = ({int from, int to,
    Map<InputSignal, List<OwnedSpan>> ownership});

/// Compare the loader's decisions, including null-owner (unfiltered) spans.
/// Wider resolver windows can seed hysteresis differently.
bool sameSubstrateOwnership(Map<InputSignal, List<OwnedSpan>> a,
    Map<InputSignal, List<OwnedSpan>> b, int from, int to) {
  List<OwnedSpan> clip(List<OwnedSpan> spans) {
    final out = <OwnedSpan>[];
    for (final s in spans) {
      if (s.deviceId == null || s.end <= from || s.start > to) continue;
      final lo = s.start < from ? from : s.start;
      final hi = s.end > to + 1 ? to + 1 : s.end;
      if (out.isNotEmpty && out.last.end == lo &&
          out.last.deviceId == s.deviceId) {
        out[out.length - 1] =
            (start: out.last.start, end: hi, deviceId: s.deviceId);
      } else {
        out.add((start: lo, end: hi, deviceId: s.deviceId));
      }
    }
    return out;
  }
  for (final signal in InputSignal.values) {
    final x = clip(a[signal] ?? const []), y = clip(b[signal] ?? const []);
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
  }
  return true;
}

int _lowerBound(List<int> ts, int value) {
  var lo = 0, hi = ts.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (ts[mid] < value) { lo = mid + 1; } else { hi = mid; }
  }
  return lo;
}

List<List<Object?>> _runs(RetainedSubstrate load) =>
    (load.extras['provenance'] as List).cast<List<Object?>>();
String? _unit(List<List<Object?>> runs) {
  for (final r in runs) {
    if (r[3] != null) return r[3] as String;
  }
  return null;
}
(Set<String>, Set<String>) _sources(List<List<Object?>> runs) {
  final families = <String>{}, ids = <String>{};
  for (final r in runs) {
    if (r[1] != null) families.add(r[1] as String);
    if (r[2] != null) ids.add(r[2] as String);
  }
  return (families, ids);
}

/// Worker-only: reproduce a decoded load by record second, restarting the
/// beat running maximum from the original placements. Substrate.slice instead
/// selects beats by their repaired time and keeps the parent's provenance.
RetainedSubstrate? cutSubstrateUnion(RetainedSubstrate load, int from, int to,
    Map<InputSignal, List<OwnedSpan>> ownership, {bool retainMetadata = true}) {
  if (load.from == null || from < load.from! || to > load.to! || to < from ||
      load.extras['provenance'] == null ||
      !sameSubstrateOwnership(load.ownership, ownership, from, to)) {
    return null;
  }
  final s = load.sub, n = s.length;
  final starts = load.extras['rr_start'] as List<int>;
  final raw = load.extras['rr_ts_raw'] as List<double>;
  if (starts.length != n || raw.length != s.rrMs.length) return null;
  final lo = _lowerBound(s.tsSec, from), hi = _lowerBound(s.tsSec, to + 1);
  final r0 = lo < n ? starts[lo] : s.rrMs.length;
  final r1 = hi < n ? starts[hi] : s.rrMs.length;
  final runs = _runs(load), selected = <List<Object?>>[];
  for (var i = 0; i < runs.length; i++) {
    final start = runs[i][0] as int;
    final end = i + 1 < runs.length ? runs[i + 1][0] as int : n;
    if (end <= lo || start >= hi) continue;
    selected.add([start < lo ? 0 : start - lo, ...runs[i].skip(1)]);
  }
  // The union has already suppressed other temperature units. A later
  // window that would choose another unit must take the ordinary loader.
  final unit = _unit(selected);
  if (unit != null && unit != _unit(runs)) return null;
  final (families, ids) = _sources(selected);
  final axis = Float64List(r1 - r0)..setRange(0, r1 - r0, raw, r0);
  monotonizeBeatAxis(axis);
  final columns = s.toJson();
  final out = <String, dynamic>{
    for (final key in _intColumns)
      key: (columns[key] as List<int>).sublist(lo, hi),
    for (final key in _motionColumns)
      key: (columns[key] as List<double>).sublist(lo, hi),
    'rr_ts_ms': axis, 'rr_ms': s.rrMs.sublist(r0, r1),
    'device_family': families.length == 1 ? families.first : null,
    'device_ids': ids.toList(),
  };
  return RetainedSubstrate(version: load.version, context: load.context,
    revisions: load.revisions, from: from, to: to,
    generation: load.generation, ownership: ownership,
    sub: Substrate.fromTransfer(out), cut: from,
    extras: !retainMetadata ? const {} : {
      'rr_start': Int32List.fromList([
        for (var i = lo; i < hi; i++) starts[i] - r0]),
      'rr_ts_raw': Float64List(r1 - r0)..setRange(0, r1 - r0, raw, r0),
      'provenance': selected,
      'meta': [for (final m in load.extras['meta'] as List)
        if ((m as List)[0] as int >= from ~/ 900 &&
            m[0] as int <= to ~/ 900) m],
      'raw_rows_by_bucket': <int, int>{
        for (final e in ((load.extras['raw_rows_by_bucket'] as Map<int, int>?) ??
            const <int, int>{}).entries)
          if (e.key >= from ~/ 900 && e.key <= to ~/ 900) e.key: e.value},
    });
}

const _intColumns = ['ts_sec', 'hr', 'spo2_red', 'spo2_ir', 'skin_temp',
    'skin_contact', 'step_count', 'hr_valid', 'band_sleep_state'];
const _motionColumns = ['ax', 'ay', 'az'];

/// Worker-only: join disjoint loads and repair their raw beat axis once across
/// the seams. Refuse independently selected temperature units that cannot be
/// reconstructed from already suppressed columns.
RetainedSubstrate? joinSubstrateUnions(List<RetainedSubstrate> parts,
    String context, Map<int, int> revisions,
    Map<InputSignal, List<OwnedSpan>> ownership) {
  if (parts.isEmpty) return null;
  final units = {for (final p in parts) _unit(_runs(p))}..remove(null);
  if (units.length > 1) return null;
  var n = 0, beats = 0;
  for (var i = 0; i < parts.length; i++) {
    if (i > 0 && parts[i].from != parts[i - 1].to! + 1) return null;
    n += parts[i].sub.length;
    beats += parts[i].sub.rrMs.length;
  }
  final columns = <String, dynamic>{
    for (final key in _intColumns) key: Int64List(n),
    for (final key in _motionColumns) key: Float64List(n),
    'rr_ms': Float64List(beats),
  };
  final raw = Float64List(beats), starts = Int32List(n);
  final runs = <List<Object?>>[], meta = <int, List<Object?>>{};
  final rawRows = <int, int>{};
  var at = 0, rat = 0;
  for (final p in parts) {
    final source = p.sub.toJson(), pn = p.sub.length, rn = p.sub.rrMs.length;
    for (final key in [..._intColumns, ..._motionColumns]) {
      (columns[key] as List).setRange(at, at + pn, source[key] as List);
    }
    (columns['rr_ms'] as List<double>).setRange(rat, rat + rn, p.sub.rrMs);
    raw.setRange(rat, rat + rn, p.extras['rr_ts_raw'] as List<double>);
    final rs = p.extras['rr_start'] as List<int>;
    for (var i = 0; i < pn; i++) { starts[at + i] = rs[i] + rat; }
    for (final r in _runs(p)) {
      final last = runs.isEmpty ? null : runs.last;
      if (last == null || last[1] != r[1] || last[2] != r[2] || last[3] != r[3]) {
        runs.add([(r[0] as int) + at, ...r.skip(1)]);
      }
    }
    for (final m in p.extras['meta'] as List) {
      final wire = m as List;
      final target = meta.putIfAbsent(wire[0] as int,
          () => [wire[0], <String>{}, <String>{}, null]);
      (target[1] as Set<String>).addAll((wire[1] as List).cast<String>());
      (target[2] as Set<String>).addAll((wire[2] as List).cast<String>());
      target[3] ??= wire[3];
    }
    for (final e in (p.extras['raw_rows_by_bucket'] as Map<int, int>).entries) {
      rawRows[e.key] = (rawRows[e.key] ?? 0) + e.value;
    }
    at += pn; rat += rn;
  }
  final axis = Float64List.fromList(raw);
  monotonizeBeatAxis(axis);
  final (families, ids) = _sources(runs);
  columns.addAll({'rr_ts_ms': axis,
    'device_family': families.length == 1 ? families.first : null,
    'device_ids': ids.toList()});
  return RetainedSubstrate(version: parts.first.version, context: context,
    revisions: revisions, from: parts.first.from, to: parts.last.to,
    generation: parts.first.generation, ownership: ownership,
    sub: Substrate.fromTransfer(columns), cut: parts.first.from!,
    extras: {'rr_start': starts, 'rr_ts_raw': raw, 'provenance': runs,
      'raw_rows_by_bucket': rawRows,
      'meta': [for (final m in meta.values)
        [m[0], (m[1] as Set).toList(), (m[2] as Set).toList(), m[3]]],
    });
}

/// Revision/ownership proofs are small; column cuts and joins run in workers.
List<(int, int, RetainedSubstrate)> reusableUnionStretches(
    Iterable<RetainedSubstrate> bases, int from, int to,
    Map<int, int> revisions, Map<InputSignal, List<OwnedSpan>> ownership) {
  final candidates = <(int, int, RetainedSubstrate)>[];
  for (final base in bases) {
    final lo = from > base.from! ? from : base.from!;
    final hi = to < base.to! ? to : base.to!;
    int? start;
    void close(int end) {
      if (start == null) return;
      final a = start! < lo ? lo : start!;
      final b = end > hi ? hi : end;
      start = null;
      if (b < a || (a != base.from && a % 900 != 0) ||
          (b != base.to && (b + 1) % 900 != 0)) { return; }
      if (sameSubstrateOwnership(base.ownership, ownership, a, b)) {
        candidates.add((a, b, base));
      }
    }
    for (var b = lo ~/ 900; b <= hi ~/ 900; b++) {
      if ((revisions[b] ?? 0) == (base.revisions[b] ?? 0)) {
        start ??= b * 900;
      } else { close(b * 900 - 1); }
    }
    close(hi);
  }
  final out = <(int, int, RetainedSubstrate)>[];
  var pos = from;
  while (pos <= to) {
    (int, int, RetainedSubstrate)? best;
    int? next;
    for (final c in candidates) {
      if (c.$1 <= pos && c.$2 >= pos &&
          (best == null || c.$2 > best.$2)) { best = c; }
      if (c.$1 > pos && (next == null || c.$1 < next)) next = c.$1;
    }
    if (best == null) {
      if (next == null) break;
      pos = next;
    } else {
      if (pos != best.$3.from && pos % 900 != 0) {
        pos = (pos ~/ 900 + 1) * 900;
        continue;
      }
      out.add((pos, best.$2, best.$3));
      pos = best.$2 + 1;
    }
  }
  return out;
}

// Factories keep dispatch closures in a scope containing only plain inputs.
List<RetainedSubstrate?> Function() borrowUnionJob(
    List<(int, int, RetainedSubstrate)> stretches,
    Map<InputSignal, List<OwnedSpan>> ownership) => () => [
  for (final s in stretches) cutSubstrateUnion(s.$3, s.$1, s.$2, ownership)];

RetainedSubstrate? Function() joinUnionJob(List<RetainedSubstrate> parts,
    String context, Map<int, int> revisions,
    Map<InputSignal, List<OwnedSpan>> ownership) => () =>
    joinSubstrateUnions(parts, context, revisions, ownership);

(List<Substrate?>, Substrate?) Function() cutUnionJob(RetainedSubstrate load,
    List<(int, int)> ranges, Map<InputSignal, List<OwnedSpan>> ownership,
    int? dayStart, int? dayEnd) => () {
  final windows = [for (final r in ranges)
    cutSubstrateUnion(load, r.$1, r.$2, ownership, retainMetadata: false)?.sub];
  final day = dayStart == null || dayEnd == null ? null :
      windows.first?.slice(dayStart, dayEnd);
  return (windows, day);
};
