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
import 'dart:math' as math;

import 'package:clock/clock.dart';
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

  /// GPS noise floor (metres): a fix within this distance of the last
  /// ACCEPTED point is dropped — not added to distance or the route polyline.
  /// Consumer GPS commonly drifts a few metres between fixes from multipath
  /// alone, even while genuinely stationary (indoors, or before a workout's
  /// real movement starts) and even with a "good" reported accuracy well
  /// under [maxAccuracyM]. Without this floor, that drift silently
  /// accumulates into real-looking phantom distance, AND — separately —
  /// pollutes the route's bounding box with a tight jittery cluster, which
  /// made the map's fit-to-bounds zoom in to near-max trying to "fit" it.
  ///
  /// Deliberately does NOT advance the anchor when a fix is dropped: the next
  /// fix is compared against the SAME last-accepted point, so genuine slow
  /// movement still accumulates and gets captured (just in coarser steps)
  /// the moment its cumulative distance from the anchor clears the floor —
  /// only fixes that never net a real displacement (isolated back-and-forth
  /// jitter) are dropped for good. An engineering choice tuned to typical
  /// phone-GPS drift, not a cited scientific threshold — same convention as
  /// [maxJumpM]/[maxSpeedMps].
  final double minMovementM;

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

  /// No accepted fix for this long while running → [stalled] flips true. This
  /// is DISTINCT from [error] (an explicit stream error): geolocator can just
  /// stop delivering fixes silently (OS killed the location service, screen
  /// locked on iOS, permission revoked in Settings mid-run) without ever
  /// erroring the stream — the previous design only reacted to explicit
  /// errors, so that silent-stall case looked like "GPS works sometimes,
  /// mostly doesn't" with zero explanation to the user.
  final Duration stallAfter;

  RouteTracker({
    required this.sink,
    this.batchSize = 8,
    this.maxAccuracyM = 50,
    this.maxJumpM = 200,
    this.minMovementM = 4,
    this.maxSpeedMps = rmath.kMaxPlausibleSpeedMps,
    this.rejectStreakLimit = 3,
    this.zoneNow,
    this.stallAfter = const Duration(seconds: 15),
    this.pathEmitEvery = const Duration(seconds: 1),
  });

  /// Minimum spacing between [path] emissions (the ~1/s throttle — see the fix
  /// handler). Injectable so tests that feed many fixes inside one wall-clock
  /// second can pass [Duration.zero] and assert per-fix vertices.
  final Duration pathEmitEvery;

  /// The full path so far, coloured by live zone — drives the live map.
  final ValueNotifier<List<RouteVertex>> path =
      ValueNotifier<List<RouteVertex>>(const []);

  /// The most recent fix — drives the pulsing current-position marker.
  final ValueNotifier<LatLng?> current = ValueNotifier<LatLng?>(null);

  /// Cumulative distance in metres.
  final ValueNotifier<double> distanceMeters = ValueNotifier<double>(0);

  /// Smoothed instantaneous speed (m/s) — see [rmath.emaSpeed]. Null until the
  /// first usable fix (platform speed or a fallback derived from two fixes).
  final ValueNotifier<double?> currentSpeedMps = ValueNotifier<double?>(null);

  /// True when no fix has been ACCEPTED for [stallAfter] while running — see
  /// [stallAfter]'s doc. Distinct from [error]: a stall has no exception to
  /// report, just silence.
  final ValueNotifier<bool> stalled = ValueNotifier<bool>(false);

  /// Non-null after the GPS stream errored (location service died mid-run).
  /// The live map surfaces this instead of showing "Waiting for GPS…" forever.
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  StreamSubscription<GpsSample>? _sub;
  Timer? _watchdog;
  final List<RoutePoint> _buffer = [];
  final List<RouteVertex> _vertices = [];
  int _seq = 0;
  RoutePoint? _last;
  int _rejectStreak = 0;
  int _movingMs = 0;
  bool _stopped = false;
  DateTime _lastFixAt = clock.now();
  // Serializes every _flush() call (auto-triggered from _onSample AND the
  // ones stop() runs itself) through one chain, instead of firing auto
  // flushes unawaited. Two things this buys for free: stop() can `await` it
  // to know an in-flight auto-flush (and its requeue-on-failure) has fully
  // settled before stop() does its own tail flush and disposes — otherwise a
  // batch re-queued by a flush that resolves AFTER stop()'s own flushes ran
  // sits in `_buffer` forever (the tracker is terminal, nothing ever flushes
  // it again); and overlapping flushes can no longer race each other's
  // independent snapshot/clear/await of `_buffer`.
  Future<void> _flushChain = Future<void>.value();
  // Wall-ms of the last `path` emission (see the ~1/s throttle in the fix
  // handler). 0 ⇒ the first accepted fix always emits.
  int _lastPathEmitMs = 0;

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
    _lastFixAt = clock.now();
    _sub = source.listen(
      _onSample,
      onError: (Object e) {
        // Surface — a dead location service otherwise looks like eternal
        // "Waiting for GPS…". The subscription stays up (cancelOnError: false)
        // so fixes resume seamlessly if the service comes back.
        // `_stopped` guard: an event already in flight when stop()/dispose()
        // cancelled the subscription must not write to a disposed notifier.
        if (_stopped) return;
        error.value = e.toString();
      },
      cancelOnError: false,
    );
    // Proactive watchdog — a stalled (not errored) stream never fires onError,
    // so this is the only way to detect "fixes just stopped arriving" instead
    // of waiting forever with a stale last-known position.
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_stopped) return;
      final quiet = clock.now().difference(_lastFixAt) >= stallAfter;
      if (quiet != stalled.value) stalled.value = quiet;
    });
  }

  void _onSample(GpsSample s) {
    if (_stopped) return;
    if (s.accuracy != null && s.accuracy! > maxAccuracyM) return;
    if (s.lat.isNaN || s.lng.isNaN) return;
    if (error.value != null) error.value = null; // fixes flowing again
    _lastFixAt = clock.now();
    if (stalled.value) stalled.value = false;

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
      } else if (jump < minMovementM) {
        // Below the GPS noise floor — not implausible, just too small to be
        // real movement (multipath drift while stationary). Drop it WITHOUT
        // advancing `_last`: the next fix still compares against this SAME
        // anchor, so genuine slow movement accumulates across drops and gets
        // captured, coarsely, once it clears the floor — see [minMovementM].
        return;
      } else {
        _rejectStreak = 0;
        distanceMeters.value = distanceMeters.value + jump;
        if (dtMs > 0 && dtMs <= 60 * 1000) _movingMs += dtMs;
      }
    }

    // Prefer the platform's own (Doppler-derived) speed; fall back to a
    // fix-to-fix derivation only when the platform doesn't report one. A
    // fresh segment anchor (gapBefore) has no meaningful "speed since last
    // point" — don't let a big time/distance gap produce a bogus spike.
    final rawSpeed = s.speed ?? (gapBefore ? null : rmath.fallbackSpeedMps(prev, RoutePoint(
      seq: _seq, tsMs: s.tsMs, lat: s.lat, lng: s.lng,
    )));
    if (rawSpeed != null && rawSpeed.isFinite && rawSpeed >= 0) {
      // Clamp before smoothing, not just after: a single wild Doppler/
      // multipath spike (or a fallback speed inflated by two fixes arriving
      // unusually close together) shouldn't get to pull the EMA toward it
      // AT ALL beyond this ceiling, even damped — a real user report of a
      // transient implausible live pace (e.g. "1:45/km" mid-jog) showed a
      // single such reading still visibly swayed the displayed number.
      final clamped = math.min(rawSpeed, rmath.kMaxPlausibleSpeedMps);
      currentSpeedMps.value = rmath.emaSpeed(currentSpeedMps.value, clamped);
    }

    final p = RoutePoint(
      seq: _seq++,
      tsMs: s.tsMs,
      lat: s.lat,
      lng: s.lng,
      alt: s.alt,
      accuracy: s.accuracy,
      speed: currentSpeedMps.value,
    );
    _last = p;
    _buffer.add(p);

    _vertices.add(RouteVertex(p.latLng, zoneNow?.call(), gapBefore: gapBefore));
    // Emit a fresh list so ValueNotifier listeners rebuild — throttled to ~1/s.
    // Per-fix emission was an O(n) unmodifiable copy + full polyline rebuild on
    // EVERY accepted fix (O(n²) over a long ride: ~10k points at a 5 m filter),
    // and the map cannot visually resolve per-5-m updates anyway. `current`/
    // speed stay per-fix, so the position dot and pace never lag.
    final nowMs = clock.now().millisecondsSinceEpoch;
    if (nowMs - _lastPathEmitMs >= pathEmitEvery.inMilliseconds) {
      _lastPathEmitMs = nowMs;
      path.value = List<RouteVertex>.unmodifiable(_vertices);
    }
    current.value = p.latLng;

    if (_buffer.length >= batchSize) {
      _flushChain = _flushChain.then((_) => _flush());
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

  /// Stop tracking and flush any buffered tail, then release the tracker.
  /// Idempotent. Retries the final flush once — after stop() no later flush
  /// ever runs, so a single transient sink failure here used to silently drop
  /// the route's tail.
  ///
  /// TERMINAL: a tracker is single-use (`start` is a no-op after the first
  /// call), and both owners in AppState drop their reference the moment they
  /// call this, so stop() also runs [dispose]. Previously nothing ever called
  /// dispose(), which leaked the six ValueNotifiers (and their listeners) once
  /// per route workout. Read the notifiers BEFORE awaiting stop().
  /// Stop tracking and flush the throttle's held-back tail vertices.
  ///
  /// A GPS fix still IN FLIGHT (added to the source stream but not yet handed
  /// to us) is dropped: the subscription is cancelled before the final emit.
  /// Callers read the notifiers right after this returns.
  Future<void> stop() async {
    if (_stopped) {
      dispose();
      return;
    }
    _stopped = true;
    _watchdog?.cancel();
    _watchdog = null;
    await _sub?.cancel();
    _sub = null;
    // Wait for any auto-triggered flush from _onSample to fully settle
    // (including its requeue-on-failure) BEFORE our own flush below — see
    // _flushChain's doc. Without this, a batch that flush re-queues after our
    // own flushes and dispose() have already run is orphaned forever.
    await _flushChain;
    // Final emit: the ~1/s throttle can be holding up to a second of tail
    // vertices — the caller reads the notifiers right after stop().
    path.value = List<RouteVertex>.unmodifiable(_vertices);
    await _flush();
    if (_buffer.isNotEmpty) await _flush(); // one retry for the tail
    dispose();
  }

  bool _disposed = false;

  /// Release every resource the tracker holds. Idempotent, and safe to call
  /// WITHOUT stop() — it cancels the GPS subscription too, which the previous
  /// implementation did not: it only cancelled the watchdog, so a dispose()
  /// without a stop() left the location stream (and the platform's GPS
  /// hardware session behind it) running for the life of the process.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopped = true;
    _watchdog?.cancel();
    _watchdog = null;
    unawaited(_sub?.cancel());
    _sub = null;
    path.dispose();
    current.dispose();
    distanceMeters.dispose();
    currentSpeedMps.dispose();
    stalled.dispose();
    error.dispose();
  }
}
