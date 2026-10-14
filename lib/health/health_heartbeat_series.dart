import 'dart:async';

import 'package:flutter/services.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../compute/substrate.dart' show monotonizeBeatAxis, plausibleRrOrNull;

// Apple Health beat-to-beat export (HKHeartbeatSeriesSample) for the night.
//
// WHY THIS EXISTS. HealthKit's only HRV quantity is SDNN, so the nightly HRV
// sample this app writes is SDNN (`healthHrvExportValue`). Apps that read
// Health and want RMSSD (Bevel's default HRV method, Athlytic, ...) compute it
// themselves from heartbeat series, which today only the Apple Watch writes.
// Without these samples an OpenStrap night has no RMSSD anywhere in HealthKit
// (see #315 for what users see instead).
//
// WHAT IS WRITTEN. Beat INSTANTS, nothing else: HealthKit stores a series as
// offsets from its start plus a per-beat `precededByGap` flag, and a reader
// derives every interval from successive instants. So the instants are the
// clock the nightly RMSSD itself runs on, `correctRr(...).nnTimesMs`, which
// cumsums the measured R-R *inside* a contiguous run and re-anchors to the
// beat's timestamp at a dropout. A spline-corrected beat keeps its REAL time
// there (rr_correction.dart says so outright), so no interpolated value
// reaches the store; it only changes which pairs count as contiguous.
//
// A beat is preceded by a gap unless the elapsed time from the previous
// exported beat IS its cleaned interval (the contiguity test `hrvTime` applies,
// tightened to both directions): after a dropped artifact run, a sensor
// dropout, or a corrected beat whose real interval differs from its cleaned
// one. A reader that honours the flag pairs the intervals OpenStrap's own RMSSD
// pairs, less the few around a spline-corrected beat: `hrvTime` differences
// the corrected value, and a corrected value is exactly what may not leave
// this app.
//
// Absent input => no series. No beats in the window is "nothing to write",
// never a substituted value.

/// One HKHeartbeatSeriesSample. [offsetsMs] are from [start]; the first is 0.
class HealthHeartbeatSeries {
  const HealthHeartbeatSeries({
    required this.start,
    required this.offsetsMs,
    required this.precededByGap,
  });

  final DateTime start;
  final List<int> offsetsMs;
  final List<bool> precededByGap;

  int get beats => offsetsMs.length;

  Map<String, Object> toMap() => {
    'startTime': start.millisecondsSinceEpoch,
    'offsetsMs': offsetsMs,
    'precededByGap': precededByGap,
  };
}

/// Upper bound on one series' span. Apple Watch writes ~1 min series; 5 min is
/// the standard short-term HRV window and the one the nightly `sdnn_window`
/// already averages over. Splitting costs one pair per window, against an
/// unbounded native-call payload per night.
const Duration kHeartbeatSeriesMaxSpan = Duration(minutes: 5);

/// A series needs at least one successive pair to say anything.
const int kHeartbeatSeriesMinBeats = 2;

/// Build the night's heartbeat series from the band's raw beats.
///
/// [rrMs] / [rrTsMs] are parallel: each beat's R-R interval (ms) and the
/// instant it ended (epoch ms, `beat_ts_ms` coalesced to `rr_ts_ms`), in
/// ascending time. Implausible intervals are dropped first, exactly as the
/// derive path does, so both see the same beat train.
///
/// Pure and synchronous. Run it on a background isolate: `correctRr` over a
/// full night (~25k beats) is not UI-isolate work.
List<HealthHeartbeatSeries> buildSleepHeartbeatSeries({
  required List<num> rrMs,
  required List<num> rrTsMs,
  required DateTime sleepStart,
  required DateTime sleepEnd,
  Duration maxSpan = kHeartbeatSeriesMaxSpan,
}) {
  if (rrMs.length != rrTsMs.length || !sleepStart.isBefore(sleepEnd)) {
    return const [];
  }
  final from = sleepStart.millisecondsSinceEpoch;
  final to = sleepEnd.millisecondsSinceEpoch;

  final rr = <double>[];
  final ts = <double>[];
  for (var i = 0; i < rrMs.length; i++) {
    final v = plausibleRrOrNull(rrMs[i]);
    if (v == null) continue;
    final t = rrTsMs[i].toDouble();
    if (t < from || t > to) continue;
    rr.add(v);
    ts.add(t);
  }
  if (rr.length < kHeartbeatSeriesMinBeats) return const [];
  monotonizeBeatAxis(ts);

  final cleaned = ana.correctRr(rr, rrTsMs: ts);
  final nn = cleaned.nn;
  final times = cleaned.nnTimesMs;
  if (nn.isEmpty || nn.length != times.length) return const [];
  // nnTimesMs is relative to the START of the first input beat.
  final epochZero = ts.first - rr.first;

  final out = <HealthHeartbeatSeries>[];
  var seriesStartMs = 0;
  var offsets = <int>[];
  var gaps = <bool>[];
  void flush() {
    if (offsets.length >= kHeartbeatSeriesMinBeats) {
      out.add(
        HealthHeartbeatSeries(
          start: DateTime.fromMillisecondsSinceEpoch(seriesStartMs),
          offsetsMs: offsets,
          precededByGap: gaps,
        ),
      );
    }
    offsets = <int>[];
    gaps = <bool>[];
  }

  final spanMs = maxSpan.inMilliseconds;
  double? prevTime; // clock of the last EXPORTED beat
  for (var k = 0; k < nn.length; k++) {
    final beatMs = (epochZero + times[k]).round();
    if (offsets.isEmpty || beatMs - seriesStartMs > spanMs) {
      flush();
      seriesStartMs = beatMs;
    }
    final offset = beatMs - seriesStartMs;
    // HealthKit needs strictly increasing instants. Two cleaned beats on one
    // millisecond cannot both be heartbeats; keep the first.
    if (offsets.isNotEmpty && offset <= offsets.last) continue;
    final contiguous =
        prevTime != null && ((times[k] - prevTime) - nn[k]).abs() <= 0.5;
    prevTime = times[k];
    offsets.add(offset);
    // The first beat of a series has no predecessor inside it.
    gaps.add(offsets.length > 1 && !contiguous);
  }
  flush();
  return out;
}

abstract interface class HealthKitHeartbeatWriter {
  /// Delete OUR heartbeat series in [cleanupStart, cleanupEnd), then write
  /// [series]. An empty [series] is a clear.
  Future<bool> replace({
    required DateTime cleanupStart,
    required DateTime cleanupEnd,
    required List<HealthHeartbeatSeries> series,
  });

  /// Ask for share access to HKSeriesType.heartbeat(). The `health` plugin has
  /// no heartbeat-series type, so its grant sheet never lists it. Call from a
  /// user gesture.
  Future<void> requestAuthorization();
}

class MethodChannelHealthKitHeartbeatWriter
    implements HealthKitHeartbeatWriter {
  MethodChannelHealthKitHeartbeatWriter({
    this.channel = const MethodChannel('openstrap/healthkit_heartbeat'),
  });

  final MethodChannel channel;
  Future<void> _pending = Future<void>.value();

  @override
  Future<bool> replace({
    required DateTime cleanupStart,
    required DateTime cleanupEnd,
    required List<HealthHeartbeatSeries> series,
  }) {
    final result = Completer<bool>();
    _pending = _pending.then((_) async {
      try {
        final args = <String, Object>{
          'cleanupStartTime': cleanupStart.millisecondsSinceEpoch,
          'cleanupEndTime': cleanupEnd.millisecondsSinceEpoch,
          'series': [for (final s in series) s.toMap()],
        };
        // Finite, for the same reason as the sleep writer: a native handler
        // that never calls back would otherwise stall every later day. A night
        // is ~100 series, each its own builder save, so this gets longer than
        // the sleep replace's 30 s.
        result.complete(
          await channel
                  .invokeMethod<bool>('replaceHeartbeatSeries', args)
                  .timeout(const Duration(seconds: 90)) ==
              true,
        );
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  @override
  Future<void> requestAuthorization() async {
    try {
      await channel
          .invokeMethod<bool>('requestAuthorization')
          .timeout(const Duration(minutes: 5));
    } catch (_) {
      // Best-effort, like the plugin grant: writes are attempted regardless
      // and an ungranted one no-ops.
    }
  }
}
