import 'dart:async';

import 'package:flutter/services.dart';

enum HealthSleepStage { awake, rem, light, deep }

class HealthSleepStageInterval {
  const HealthSleepStageInterval({
    required this.start,
    required this.end,
    required this.stage,
  });

  final DateTime start;
  final DateTime end;
  final HealthSleepStage stage;

  Duration get duration => end.difference(start);

  Map<String, Object> toMap() => {
    'startTime': start.millisecondsSinceEpoch,
    'endTime': end.millisecondsSinceEpoch,
    'stage': stage.name,
  };
}

class HealthSleepSession {
  const HealthSleepSession({
    required this.start,
    required this.end,
    required this.stages,
  });

  final DateTime start;
  final DateTime end;
  final List<HealthSleepStageInterval> stages;

  Map<String, Object> toMap() => {
    'startTime': start.millisecondsSinceEpoch,
    'endTime': end.millisecondsSinceEpoch,
    'stages': stages.map((stage) => stage.toMap()).toList(),
  };
}

HealthSleepSession? normalizeHealthSleepSession(Map<String, dynamic> bundle) {
  final sleep = bundle['sleep'];
  final window = sleep is Map ? sleep['window'] : null;
  final value = window is Map ? window['value'] : null;
  final onsetMs = value is Map ? (value['onset_ms'] as num?)?.toInt() : null;
  final offsetMs = value is Map ? (value['offset_ms'] as num?)?.toInt() : null;
  if (onsetMs == null || offsetMs == null || offsetMs <= onsetMs) return null;

  final start = DateTime.fromMillisecondsSinceEpoch(onsetMs);
  final end = DateTime.fromMillisecondsSinceEpoch(offsetMs);
  final series = bundle['series'];
  final rawStages = series is Map ? series['hypnogram'] : null;
  final candidates = <HealthSleepStageInterval>[];
  if (rawStages is List) {
    for (final interval in _hypnogramIntervals(rawStages)) {
      final stage = healthSleepStageOf(interval.stage);
      if (stage == null) continue;
      final clippedStart = interval.start.isBefore(start)
          ? start
          : interval.start;
      final clippedEnd = interval.end.isAfter(end) ? end : interval.end;
      if (!clippedStart.isBefore(clippedEnd)) continue;
      candidates.add(
        HealthSleepStageInterval(
          start: clippedStart,
          end: clippedEnd,
          stage: stage,
        ),
      );
    }
  }

  candidates.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.end.compareTo(b.end);
  });

  // Imported / unstaged nights have a window and no hypnogram. Do not invent
  // a full-night "awake" session — Android treats that as a no-op so a CSV
  // day cannot wipe Health Connect, and Apple writes only the in-bed bar.
  if (candidates.isEmpty) {
    return HealthSleepSession(start: start, end: end, stages: const []);
  }

  // Tile the detected stages across the in-bed envelope. Overlap trimming
  // stays (the native writers reject a stage starting before its predecessor
  // ends); GAPS are left unwritten on purpose: an unobserved second is not a
  // stage and not wake (onehz_pipeline.dart says it outright — "it belongs
  // to neither side"), and exporting it as measured wake fabricates a
  // reading other apps take as fact. Apple's Time Asleep is
  // asleepCore+Deep+REM, so a gap adds zero; the in-bed envelope carries the
  // span. Real 'wake' labels from the hypnogram still export as wake below —
  // those were measured.
  final normalized = <HealthSleepStageInterval>[];
  var cursor = start;
  void append(DateTime from, DateTime to, HealthSleepStage stage) {
    if (!from.isBefore(to)) return;
    if (normalized.isNotEmpty &&
        normalized.last.stage == stage &&
        !normalized.last.end.isBefore(from)) {
      normalized[normalized.length - 1] = HealthSleepStageInterval(
        start: normalized.last.start,
        end: to.isAfter(normalized.last.end) ? to : normalized.last.end,
        stage: stage,
      );
      return;
    }
    normalized.add(
      HealthSleepStageInterval(start: from, end: to, stage: stage),
    );
  }

  for (final candidate in candidates) {
    final normalizedStart = candidate.start.isBefore(cursor)
        ? cursor
        : candidate.start;
    if (!normalizedStart.isBefore(candidate.end)) continue;
    append(normalizedStart, candidate.end, candidate.stage);
    if (candidate.end.isAfter(cursor)) cursor = candidate.end;
  }

  return HealthSleepSession(start: start, end: end, stages: normalized);
}

/// Epoch seconds or milliseconds → a wall instant. Older/imported hypnograms
/// have mixed units; treating ms as seconds writes samples in the year 56000
/// (or, after a failed write, leaves last night's fragments behind).
DateTime healthInstantFromEpoch(num raw) {
  final n = raw.toInt();
  final ms = n.abs() >= 100000000000 ? n : n * 1000;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

class _RawHypnoInterval {
  const _RawHypnoInterval({
    required this.start,
    required this.end,
    required this.stage,
  });
  final DateTime start;
  final DateTime end;
  final String stage;
}

/// Stored hypnograms are `{start,end,stage}` segments. The sleep screen also
/// materializes `{t,stage}` points. Accept both so Health is not empty when
/// a reader round-trips the UI shape into `series.hypnogram`.
List<_RawHypnoInterval> _hypnogramIntervals(List<dynamic> rawStages) {
  final segmented = <_RawHypnoInterval>[];
  for (final raw in rawStages) {
    if (raw is! Map) continue;
    final stage = raw['stage']?.toString();
    if (stage == null) continue;
    // Runtime `is num` checks, not casts: a malformed row (a string epoch, a
    // nested map) must SKIP the record, not throw through the whole export.
    // (`as num?` throws TypeError on a non-num value rather than yielding
    // null — an imported hypnogram with one bad row killed every write.)
    final startRaw = raw['start'];
    final endRaw = raw['end'];
    if (startRaw is num && endRaw is num) {
      final start = healthInstantFromEpoch(startRaw);
      final end = healthInstantFromEpoch(endRaw);
      if (start.isBefore(end)) {
        segmented.add(_RawHypnoInterval(start: start, end: end, stage: stage));
      }
    }
  }
  if (segmented.isNotEmpty) return segmented;

  final points = <({DateTime t, String stage})>[];
  for (final raw in rawStages) {
    if (raw is! Map) continue;
    final tRaw = raw['t'];
    final stage = raw['stage']?.toString();
    if (tRaw is! num || stage == null) continue;
    points.add((t: healthInstantFromEpoch(tRaw), stage: stage));
  }
  points.sort((a, b) => a.t.compareTo(b.t));
  final out = <_RawHypnoInterval>[];
  for (var i = 0; i + 1 < points.length; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (!a.t.isBefore(b.t)) continue;
    out.add(_RawHypnoInterval(start: a.t, end: b.t, stage: a.stage));
  }
  return out;
}

HealthSleepStage? healthSleepStageOf(String? stage) {
  switch (stage) {
    case 'wake':
    case 'awake':
      return HealthSleepStage.awake;
    // 'unobserved' deliberately does NOT map to wake: it is the band's
    // off-skin / unwatched time, and exporting it as measured wake
    // fabricates a reading (see the gap-fill note in
    // normalizeHealthSleepSession). Returning null drops it.
    case 'unobserved':
      return null;
    case 'rem':
      return HealthSleepStage.rem;
    case 'light':
    case 'nrem':
    case 'core':
      return HealthSleepStage.light;
    case 'deep':
      return HealthSleepStage.deep;
    default:
      return null;
  }
}

/// Noon-to-noon around the night's wake, matching Android
/// `HealthConnectSleepWriter.sleepCleanupRange`.
///
/// A later derive that moves onset (23:00 → 01:06) leaves the previous
/// HealthKit samples *outside* `[night.start, night.end)`. Deleting only the
/// detected window is #225: Health keeps 11pm REM/Awake and a ~2 h remainder.
({DateTime start, DateTime end}) sleepSessionCleanupRange(
  HealthSleepSession night,
) {
  final localEnd = night.end;
  final wakeMidnight = DateTime(localEnd.year, localEnd.month, localEnd.day);
  // Calendar-field arithmetic, never `add(Duration(days: 1))`: a 25-hour
  // fall-back day would not advance the date and the window would widen into
  // the PREVIOUS night (which the delete then wipes irrecoverably — see
  // health_export.dart's note on this exact trap; the Kotlin this was ported
  // from uses plusDays(1)).
  final endDate = localEnd.hour < 12
      ? wakeMidnight
      : DateTime(wakeMidnight.year, wakeMidnight.month, wakeMidnight.day + 1);
  final cleanupEnd = DateTime(endDate.year, endDate.month, endDate.day, 12);
  final prevDate = DateTime(endDate.year, endDate.month, endDate.day - 1);
  final calculatedStart = DateTime(
    prevDate.year,
    prevDate.month,
    prevDate.day,
    12,
  );
  return (
    start: night.start.isBefore(calculatedStart)
        ? night.start
        : calculatedStart,
    end: cleanupEnd,
  );
}

/// The span a day's SLEEP-type delete has to cover.
///
/// Just [sleepSessionCleanupRange] — the noon-to-noon window around the
/// night's wake, same as Android. This used to UNION that with the whole
/// calendar day, and for a night waking after local noon the two windows
/// concatenated into one contiguous span reaching back into the PREVIOUS
/// night; the native predicate matches on overlap, so it deleted the whole
/// previous envelope sample — which is behind `health_export_through` and
/// never gets rewritten. Irrecoverable deletion is not a cleanup.
({DateTime start, DateTime end}) sleepCleanupWindow({
  required DateTime dayStart,
  required DateTime dayEnd,
  HealthSleepSession? night,
}) {
  if (night == null) return (start: dayStart, end: dayEnd);
  return sleepSessionCleanupRange(night);
}

abstract interface class HealthConnectSleepSessionWriter {
  Future<bool> replace(HealthSleepSession session);

  /// Delete our own SleepSessionRecords overlapping [start, end).
  Future<bool> clear(DateTime start, DateTime end);
}

class MethodChannelHealthConnectSleepSessionWriter
    implements HealthConnectSleepSessionWriter {
  MethodChannelHealthConnectSleepSessionWriter({
    this.channel = const MethodChannel('openstrap/health_connect_sleep'),
  });

  final MethodChannel channel;
  Future<void> _pending = Future<void>.value();

  @override
  Future<bool> replace(HealthSleepSession session) =>
      _invoke('replaceSleepSession', session.toMap());

  @override
  Future<bool> clear(DateTime start, DateTime end) =>
      _invoke('clearSleepSessions', {
        'startTime': start.millisecondsSinceEpoch,
        'endTime': end.millisecondsSinceEpoch,
      });

  Future<bool> _invoke(String method, Map<String, Object?> args) {
    final result = Completer<bool>();
    _pending = _pending.then((_) async {
      try {
        result.complete(await channel.invokeMethod<bool>(method, args) == true);
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}

class HealthConnectSleepSessionExporter {
  const HealthConnectSleepSessionExporter({required this.writer});

  final HealthConnectSleepSessionWriter writer;

  Future<bool> replace(Map<String, dynamic> bundle, {DateTime? dayStart}) async {
    final session = normalizeHealthSleepSession(bundle);
    // No sleep window at all — nothing to write, and that is not a failure.
    // But a night exported earlier (since rejected, or gone on re-derive) is
    // still in the store, and nothing else deletes Health Connect sleep. A
    // range delete matches records by START time and most nights start the
    // evening before, so clear the same noon-to-noon window a replace does.
    if (session == null) {
      if (dayStart == null) return true;
      return writer.clear(
        DateTime(dayStart.year, dayStart.month, dayStart.day - 1, 12),
        DateTime(dayStart.year, dayStart.month, dayStart.day, 12),
      );
    }
    // A window WITH NO STAGES is the same kind of "nothing to write", and has
    // to report the same way. It used to return false, and the caller treats
    // false as a hard failure of the ENTIRE day: `success = false` in
    // health_export.dart stops the cursor advancing, so steps, calories, heart
    // rate — every unrelated metric for that day — is withheld and retried on
    // backoff because one hypnogram was missing.
    //
    // Not a corner case either. Days without staging are ordinary: an IMPORTED
    // day (NOOP / WHOOP CSV) carries a sleep window but no per-second substrate
    // to stage from, and a night where staging failed keeps its window too.
    // Under the old behaviour those days could never complete an export at all.
    //
    // Deliberately conservative: this does NOT invent a stage-less
    // SleepSessionRecord, it only stops a missing hypnogram from failing
    // everything else. Writing the bare session span — so imported days still
    // contribute sleep DURATION — is a real improvement, but it depends on how
    // Health Connect handles a stage-less record and belongs in its own change,
    // verified on a device.
    if (session.stages.isEmpty) return true;
    return writer.replace(session);
  }
}

abstract interface class HealthKitSleepSessionWriter {
  Future<bool> replace({
    required DateTime cleanupStart,
    required DateTime cleanupEnd,
    HealthSleepSession? session,
  });
}

class MethodChannelHealthKitSleepSessionWriter
    implements HealthKitSleepSessionWriter {
  MethodChannelHealthKitSleepSessionWriter({
    this.channel = const MethodChannel('openstrap/healthkit_sleep'),
  });

  final MethodChannel channel;
  Future<void> _pending = Future<void>.value();

  @override
  Future<bool> replace({
    required DateTime cleanupStart,
    required DateTime cleanupEnd,
    HealthSleepSession? session,
  }) {
    final result = Completer<bool>();
    _pending = _pending.then((_) async {
      try {
        final args = <String, Object>{
          'cleanupStartTime': cleanupStart.millisecondsSinceEpoch,
          'cleanupEndTime': cleanupEnd.millisecondsSinceEpoch,
          if (session != null) ...session.toMap(),
        };
        // FINITE timeout. A native handler that never calls completion (a
        // killed extension, a missed callback) would otherwise leave this
        // future pending FOREVER — and since every replace serialises behind
        // `_pending`, one nonresponsive call stalls all later days and the
        // whole exportAll behind it. TimeoutException flows through the same
        // completeError path as any other failure.
        result.complete(
          await channel
              .invokeMethod<bool>('replaceSleepSession', args)
              .timeout(const Duration(seconds: 30)) ==
              true,
        );
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}

/// HealthKit has no SleepSessionRecord. One native replace writes `inBed` plus
/// stages (`asleepCore` for light) and deletes *our* overlapping samples in the
/// noon-to-noon window Dart already computed.
///
/// The Flutter `health` plugin is not used on this path: unknown keys (notably
/// SLEEP_SESSION) map to bodyMass and hang `delete()`, and SLEEP_LIGHT / inBed
/// writes have been failing on recent iOS as Core-less ~2 h nights (#239/#225).
class HealthKitSleepSessionExporter {
  const HealthKitSleepSessionExporter({required this.writer});

  final HealthKitSleepSessionWriter writer;

  Future<bool> replace({
    required Map<String, dynamic> bundle,
    required DateTime dayStart,
    required DateTime dayEnd,
  }) {
    final session = normalizeHealthSleepSession(bundle);
    final window = sleepCleanupWindow(
      dayStart: dayStart,
      dayEnd: dayEnd,
      night: session,
    );
    return writer.replace(
      cleanupStart: window.start,
      cleanupEnd: window.end,
      session: session,
    );
  }
}
