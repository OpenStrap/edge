import 'dart:convert';

import '../ble/adapters/signals.dart';
import '../data/coverage_resolver.dart';
import 'sleep_profile_policy.dart';
import 'substrate.dart';
import 'vendor_sleep.dart';

class StagedSleepEntry {
  StagedSleepEntry({
    required this.algoVersion,
    required this.key,
    required this.mayFold,
    required this.candidateJson,
    required this.observationJson,
  });

  int algoVersion;
  final String key;
  final bool mayFold;
  final String candidateJson;
  final String? observationJson;
}

/// Per-engine RAM only. One worker result per day, least recently used first.
class StagedSleepCache {
  final _byDay = <String, StagedSleepEntry>{};
  int _maxDays = 14;

  int get size => _byDay.length;
  int get maxDays => _maxDays;
  set maxDays(int value) {
    _maxDays = value < 0 ? 0 : value;
    while (_byDay.length > _maxDays) {
      _byDay.remove(_byDay.keys.first);
    }
  }

  StagedSleepEntry? lookup(String day, int algoVersion, String key,
      {required bool mayFold}) {
    final entry = _byDay[day];
    if (entry == null || entry.algoVersion != algoVersion || entry.key != key ||
        (mayFold && !entry.mayFold)) {
      return null;
    }
    _byDay.remove(day);
    _byDay[day] = entry;
    return entry;
  }

  void store(String day, StagedSleepEntry entry) {
    _byDay.remove(day);
    if (_maxDays == 0) return;
    _byDay[day] = entry;
    maxDays = _maxDays;
  }

  void rekey(int version) {
    for (final entry in _byDay.values) {
      entry.algoVersion = version;
    }
  }
}

/// Revisions are captured before loading rows. A concurrent write then makes
/// the next request miss. No sample columns are walked on the UI isolate.
String stagingInputKey({
  required int fromSec,
  required int toSec,
  required List<List<Object>> revisions,
  required Substrate sub,
  required Map<InputSignal, List<OwnedSpan>> ownership,
  required Map<InputSignal, List<String>> priority,
  required SleepWindowOverride? override,
  required String? profileJson,
  required List<({int startSec, int endSec, String dayKey})> priorSleep,
  required List<VendorNight> vendorNights,
  required (String, String)? activeWearable,
  bool prefixContext = false,
}) {
  // Count local midnights, including DST days, rather than dividing by 86400.
  var walked = 0;
  if (sub.tsSec.isNotEmpty) {
    final first = DateTime.fromMillisecondsSinceEpoch(sub.tsSec.first * 1000);
    for (var d = DateTime(first.year, first.month, first.day);
        d.millisecondsSinceEpoch ~/ 1000 <= sub.tsSec.last;
        d = DateTime(d.year, d.month, d.day + 1)) {
      walked++;
    }
  }
  final effectiveHistory =
      {for (final h in priorSleep) h.dayKey}.length + walked < 14
          ? const <({int startSec, int endSec, String dayKey})>[]
          : priorSleep;

  // Fold bookkeeping is re-read by the caller. Only a warmed-up profile can
  // reach staging, but all of its fields (including updated_at_ms) are keyed.
  Map<String, dynamic>? blendedProfile;
  if (profileJson != null) {
    final p = (jsonDecode(profileJson) as Map).cast<String, dynamic>();
    if (SleepProfilePolicy.shouldBlend((p['nights'] as num?)?.toInt())) {
      blendedProfile = {...p}..remove(SleepProfilePolicy.foldedDaysKey);
    }
  }

  // Local day boundaries and historical midsleeps read offsets at their own
  // instants. Key those too: equal current zone names/offsets are insufficient.
  final zoneOffsets = <List<int>>[];
  for (var t = fromSec - 86400; t <= toSec + 86400; t += 900) {
    zoneOffsets.add([t, tzOffsetSecondsAt(t)]);
  }
  for (final h in effectiveHistory) {
    final mid = (h.startSec + h.endSec) ~/ 2;
    zoneOffsets.add([mid, tzOffsetSecondsAt(mid)]);
  }
  final now = DateTime.now();
  return jsonEncode([
    fromSec, toSec, prefixContext ? const [] : revisions,
    [for (final sig in InputSignal.values) [sig.name,
      [for (final o in ownership[sig] ?? const <OwnedSpan>[])
        [o.start, o.end, o.deviceId]], priority[sig]]],
    sub.deviceFamily, (sub.deviceIds.toList()..sort()),
    if (prefixContext) ...[null, null, null, null]
    else ...[sub.length, sub.firstTs, sub.lastTs, sub.rrMs.length],
    now.timeZoneName, now.timeZoneOffset.inSeconds, zoneOffsets,
    override == null ? null :
        [override.dayId, override.onsetSec, override.offsetSec, override.source],
    blendedProfile,
    [for (final h in effectiveHistory) [h.startSec, h.endSec, h.dayKey]],
    activeWearable == null ? null : [activeWearable.$1, activeWearable.$2],
    [for (final n in vendorNights) [n.deviceId, n.source, n.decodedAtSec,
      [for (final e in n.epochs) [e.startSec, e.endSec, e.stage]]]],
  ]);
}
