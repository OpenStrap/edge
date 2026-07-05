// RouteTracker — buffers GPS fixes during a live run/ride/walk and persists
// them in batches, tied to the active session id.
//
// It is deliberately decoupled from geolocator and the DB: it consumes a plain
// `Stream<GpsSample>` (see gps_source.dart for the platform boundary) and hands
// completed batches to an injected [RouteSink]. That makes the buffering /
// flushing / de-noising logic unit-testable with a fake stream and a fake sink.
//
// LOCAL-FIRST: the sink writes to the on-device `workout_route` table only.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'route_math.dart' as rmath;
import 'route_math.dart' show haversineMeters;
import 'route_models.dart';

/// Persists a completed batch of route points. Returns when durably stored.
typedef RouteSink = Future<void> Function(List<RoutePoint> batch);

class RouteTracker {
  final RouteSink sink;

  /// Flush to the sink once this many points have buffered.
  final int batchSize;

  /// Drop fixes whose horizontal accuracy is worse than this (metres). A null
  /// accuracy is kept (some platforms don't report it).
  final double maxAccuracyM;

  /// Floor (metres) for the per-fix jump allowance. The real allowance is
  /// speed-based: max(maxJumpM, seconds-since-last-accepted-fix ×
  /// [maxSpeedMps]) — so a fix arriving after a genuine gap is allowed the
  /// distance the athlete could plausibly have covered, while a 1 s teleport
  /// spike is still rejected.
  final double maxJumpM;

  /// Fastest plausible sustained speed (m/s) for the jump allowance.
  final double maxSpeedMps;

  /// After this many CONSECUTIVE rejections, the incoming fix is accepted as a
  /// fresh segment anchor (the old anchor is stale — e.g. a tunnel or a
  /// screen-off pause moved the athlete). Without this, one real >allowance
  /// displacement poisoned `_last` and every later fix was rejected forever —
  /// the "route stops recording after a gap" bug.
  final int rejectStreakLimit;

  /// Live zone provider (0..5) sampled at each fix, used to colour the live
  /// map. Optional; when null, vertices are drawn in the neutral colour.
  final int Function()? zoneNow;

  RouteTracker({
    required this.sink,
    this.batchSize = 8,
    this.maxAccuracyM = 50,
    this.maxJumpM = 200,
    this.maxSpeedMps = rmath.kMaxPlausibleSpeedMps,
    this.rejectStreakLimit = 3,
    this.zoneNow,
  });

  /// The full path so far, coloured by live zone — drives the live map.
  final ValueNotifier<List<RouteVertex>> path =
      ValueNotifier<List<RouteVertex>>(const []);

  /// The most recent fix — drives the pulsing current-position marker.
  final ValueNotifier<LatLng?> current = ValueNotifier<LatLng?>(null);

  /// Cumulative distance in metres.
  final ValueNotifier<double> distanceMeters = ValueNotifier<double>(0);

  /// Non-null after the GPS stream errored (location service died mid-run).
  /// The live map surfaces this instead of showing "Waiting for GPS…" forever.
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  StreamSubscription<GpsSample>? _sub;
  final List<RoutePoint> _buffer = [];
  final List<RouteVertex> _vertices = [];
  int _seq = 0;
  RoutePoint? _last;
  int _rejectStreak = 0;
  int _movingMs = 0;
  bool _stopped = false;

  bool get isRunning => _sub != null && !_stopped;
  int get pointCount => _seq;

  /// Moving time in seconds so far — the sum of inter-fix intervals, excluding
  /// gaps > 60 s (paused / no signal). Drives the LIVE pace so pre-first-fix
  /// waiting and pauses don't dilute it. Mirrors route_math.movingSeconds.
  int get movingSeconds => _movingMs ~/ 1000;

  /// Begin consuming [source]. Safe to call once per tracker instance.
  void start(Stream<GpsSample> source) {
    if (_sub != null) return;
    _stopped = false;
    _sub = source.listen(
      _onSample,
      onError: (Object e) {
        // Surface — a dead location service otherwise looks like eternal
        // "Waiting for GPS…". The subscription stays up (cancelOnError: false)
        // so fixes resume seamlessly if the service comes back.
        error.value = e.toString();
      },
      cancelOnError: false,
    );
  }

  void _onSample(GpsSample s) {
    if (_stopped) return;
    if (s.accuracy != null && s.accuracy! > maxAccuracyM) return;
    if (s.lat.isNaN || s.lng.isNaN) return;
    if (error.value != null) error.value = null; // fixes flowing again

    var gapBefore = false;
    final prev = _last;
    if (prev != null) {
      final jump = haversineMeters(prev.lat, prev.lng, s.lat, s.lng);
      final dtMs = s.tsMs - prev.tsMs;
      if (rmath.isImplausibleSegment(jump, dtMs,
          minJumpM: maxJumpM, maxSpeedMps: maxSpeedMps)) {
        _rejectStreak++;
        if (_rejectStreak < rejectStreakLimit) return; // reject a wild spike
        // N consecutive fixes disagree with the anchor → the ANCHOR is stale
        // (tunnel / screen-off pause), not the fixes. Accept this one as a
        // fresh segment anchor: no distance for the jump, polyline breaks here.
        _rejectStreak = 0;
        gapBefore = true;
      } else {
        _rejectStreak = 0;
        distanceMeters.value = distanceMeters.value + jump;
        if (dtMs > 0 && dtMs <= 60 * 1000) _movingMs += dtMs;
      }
    }

    final p = RoutePoint(
      seq: _seq++,
      tsMs: s.tsMs,
      lat: s.lat,
      lng: s.lng,
      alt: s.alt,
      accuracy: s.accuracy,
    );
    _last = p;
    _buffer.add(p);

    _vertices.add(RouteVertex(p.latLng, zoneNow?.call(), gapBefore: gapBefore));
    // Emit a fresh list so ValueNotifier listeners rebuild.
    path.value = List<RouteVertex>.unmodifiable(_vertices);
    current.value = p.latLng;

    if (_buffer.length >= batchSize) {
      unawaited(_flush());
    }
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    final batch = List<RoutePoint>.of(_buffer);
    _buffer.clear();
    try {
      await sink(batch);
    } catch (_) {
      // Persistence failed — re-queue so the next flush retries. The live map
      // is unaffected (it draws from _vertices, already updated).
      _buffer.insertAll(0, batch);
    }
  }

  /// Stop tracking and flush any buffered tail. Idempotent. Retries the final
  /// flush once — after stop() no later flush ever runs, so a single transient
  /// sink failure here used to silently drop the route's tail.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _sub?.cancel();
    _sub = null;
    await _flush();
    if (_buffer.isNotEmpty) await _flush(); // one retry for the tail
  }

  void dispose() {
    path.dispose();
    current.dispose();
    distanceMeters.dispose();
    error.dispose();
  }
}
