// hyrox_reconciler.dart — rebuilds a race from the band's own record.
//
// The band IS the source of truth for the taps. When the phone was away from
// the athlete (charging at the venue, out of radio range in the arena), a
// tap still reached the strap and sits in `band_events` with the strap's own
// timestamp. This class turns those stored taps into round boundaries
// afterwards.
//
// WHAT IT WILL AND WILL NOT DO:
//
//  * Only EVENTS ARE READ, never `events`/`raw_*`. `band_events` is the
//    decoded, deduplicated history (PK on the frame hex), retained for the
//    band's own retention window.
//  * Only LIVE-provided timestamps count. The strap's RTC is the clock; a row
//    whose `ts` is zero (an unset RTC) is skipped rather than placed at 1970.
//  * A tap becomes a round boundary only when it CLEARS THE GATE: at least
//    [kMinTaps] double-taps within [kTapWindowSec], anchored on the FIRST tap
//    of the burst, and at least the segment's minimum duration after that
//    round started. Anything less is treated as an accidental touch. The live
//    gate (later PR) is specified to apply the same rule; this file is the
//    offline implementation, not a claim that the live path already exists.
//  * The whole chain is applied in ONE transaction through
//    [HyroxDb.applyOfflineBoundariesInTx]. A failure halfway through leaves the
//    race exactly as it was, not half-segmented.
//  * It NEVER overwrites a live-recorded boundary and never touches a
//    finalized session. Re-running is therefore safe and idempotent: the taps
//    at or before the last recorded boundary are ignored.
//
// What it does not decide: whether a race happened at all. The caller passes
// the session id of an armed/active session; an absent session is a no-op.

import 'package:sqflite/sqflite.dart';

import '../data/hyrox_plan.dart';
import '../data/hyrox_store.dart';

/// Double-tap event id, the only gesture the firmware emits today.
const int kHyroxDoubleTapEventId = 14;

/// How many double-taps make one accepted boundary. Matches the "keep
/// tapping until it answers" rule: an accidental blocked tap cannot reach it.
const int kMinTaps = 3;

/// The window those taps must fall inside, in seconds. The burst is anchored
/// on its FIRST tap: a chained 0 s / 6 s / 12 s sequence does NOT count,
/// because the third tap is outside the window of the first.
const int kTapWindowSec = 6;

/// Widening applied to the event window on both sides, because the strap's RTC
/// and the phone's clock are different clocks and can drift. The boundary
/// floor still rejects anything at or before the last recorded boundary, so a
/// wider read can only ADD taps the strap really recorded, never rewind.
const int kClockDriftToleranceSec = 120;

/// Minimum time a round must have been running before a boundary is
/// believable, per STATION. These are deliberately conservative floors on the
/// whole round (1 km run + station), not expected durations: they exist to
/// stop a tap during a sled struggle from ending the round, while still
/// allowing a fast round.
const Map<HyroxStation, int> kMinSegmentSec = {
  HyroxStation.skierg: 300,
  HyroxStation.sledPush: 240,
  HyroxStation.sledPull: 240,
  HyroxStation.burpeeBroadJump: 300,
  HyroxStation.rowing: 300,
  HyroxStation.farmersCarry: 240,
  HyroxStation.sandbagLunges: 300,
  HyroxStation.wallBalls: 240,
};

/// Floor for free-form training/custom plans: the race floors above assume a
/// full round (1 km run + station); a drill may be much shorter. 30 s still
/// rejects an accidental tap.
const int kTrainingFloorSec = 30;

class HyroxReconciler {
  const HyroxReconciler(this.db);

  final Database db;

  /// Rebuild boundaries for [sessionId] from the strap's stored taps.
  ///
  /// Returns the boundaries it actually applied, oldest first; an empty list
  /// means every accepted tap was already accounted for (or there were none).
  /// Throws [HyroxWriteError] on a finalized session, so a caller can
  /// report it instead of silently doing nothing.
  Future<List<ReconcileBoundary>> reconcile(
    String sessionId, {
    required String deviceId,
  }) async {
    // Read the session, the taps and apply the boundaries in ONE transaction,
    // so the decision is made against the same snapshot it is applied to.
    late final List<ReconcileBoundary> applied;
    await db.transaction((txn) async {
      final session = await HyroxDb.byId(txn, sessionId);
      if (session == null) {
        applied = const [];
        return;
      }
      if (session.isFinalized) {
        throw HyroxWriteError('session $sessionId is finalized');
      }
      final plan = session.plan;
      if (plan == null) {
        applied = const [];
        return;
      }
      // Only a race that is still going may be rebuilt. 'discarded' must stay
      // discarded (a sync must not resurrect it), and 'finished'/'finalized'
      // already carry their own boundaries.
      if (session.status != 'armed' && session.status != 'active') {
        applied = const [];
        return;
      }

      // The taps to consider: from the first thing this race recorded (a live
      // boundary, or the armed stamp when nothing has started) to now.
      final alreadyStarted =
          session.segments.where((s) => s.startTs != null).toList();
      final since = alreadyStarted.isEmpty
          ? session.createdAt ~/ 1000
          : alreadyStarted.map((s) => s.startTs!).reduce((a, b) => a > b ? a : b);
      final until = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final rows = await txn.query(
        'band_events',
        columns: ['ts'],
        where: 'event_id = ? AND device_id = ? AND ts >= ? AND ts <= ?',
        whereArgs: [
          kHyroxDoubleTapEventId,
          deviceId,
          since - kClockDriftToleranceSec,
          until + kClockDriftToleranceSec,
        ],
        orderBy: 'ts ASC',
      );
      final excluded = (await HyroxDb.excludedTaps(txn, sessionId)).toSet();
      final taps = [
        for (final r in rows)
          if (((r['ts'] as num?) ?? 0).toInt() > 0) (r['ts'] as num).toInt(),
      ].where((t) => !excluded.contains(t)).toList();
      if (taps.isEmpty) {
        applied = const [];
        return;
      }

      final boundaries = deriveBoundaries(
        taps: taps,
        segments: session.segments,
        plan: plan,
        sessionCreatedAtSec: session.createdAt ~/ 1000,
      );
      if (boundaries.isEmpty) {
        applied = const [];
        return;
      }

      await HyroxDb.applyOfflineBoundariesInTx(
        txn,
        sessionId: sessionId,
        boundaries: boundaries,
      );
      applied = boundaries;
    });
    return applied;
  }
}

/// Pure: turns raw strap-tap times into the boundaries this race can accept.
///
/// Kept Flutter- and database-free so the whole decision is unit-testable
/// without a band, a clock or a file. [segments] is the stored plan state;
/// only segments that have not started yet are advanced into.
List<ReconcileBoundary> deriveBoundaries({
  required List<int> taps,
  required List<HyroxSegment> segments,
  required HyroxPlan plan,
  required int sessionCreatedAtSec,
}) {
  if (taps.isEmpty || segments.isEmpty) return const [];
  if (plan.segments.length != segments.length) return const [];
  final sorted = [...taps]..sort();

  // Where the race stands right now. `started` counts the segments that have
  // a start, and a started segment is the one still running unless it already
  // has an end.
  var started = 0;
  var openIdx = -1;
  final localStarts = <int, int>{};
  for (final s in segments) {
    if (s.startTs != null) {
      started = s.idx + 1;
      localStarts[s.idx] = s.startTs!;
    }
    if (s.isOpen) openIdx = s.idx;
  }
  // A tap at or before the last recorded boundary is already accounted for.
  // Before anything is recorded the floor is the arming time, which is the
  // PHONE's clock, while the taps are the STRAP's. The query widens its window
  // by [kClockDriftToleranceSec] to catch a strap running behind, so the floor
  // has to give the same allowance, or the very start tap it just fetched is
  // thrown away here.
  int floor = sessionCreatedAtSec - kClockDriftToleranceSec;
  for (final s in segments) {
    final t = s.startTs;
    if (t != null && t > floor) floor = t;
  }

  // One intent = taps that BOTH start within [kTapWindowSec] of the first tap
  // AND follow the previous tap without a longer pause. The first condition
  // alone stops a chain (0 s, 6 s, 12 s) from counting as a single burst.
  final clusters = <List<int>>[];
  for (final t in sorted) {
    final current = clusters.isEmpty ? null : clusters.last;
    if (current != null &&
        t <= current.first + kTapWindowSec &&
        t - current.last <= kTapWindowSec) {
      current.add(t);
    } else {
      clusters.add([t]);
    }
  }

  final out = <ReconcileBoundary>[];
  for (final cluster in clusters) {
    final at = cluster.first;
    if (at <= floor) continue;
    // Every member is inside the window by construction.
    final supporting = cluster.length;
    if (supporting < kMinTaps) continue;

    if (started == 0) {
      // Nothing running: this cluster STARTS the race. There is no round to
      // close, so no minimum duration applies here — waiting at the start
      // line is not a round.
      out.add(ReconcileBoundary(at, supporting, plan.segments[0].kind,
          plan.segments[0].station));
      started = 1;
      openIdx = 0;
      localStarts[0] = at;
      floor = at;
      continue;
    }
    if (openIdx < 0) break; // the race is already fully marked
    final current = plan.segments[openIdx];
    // Full-round floors only apply to the fixed race presets. A free-form
    // training drill (single station, short piece) may legitimately end before
    // the race floor — use a small training floor so an accidental touch still
    // cannot close a drill.
    final minSec = plan.isTraining
        ? (kMinSegmentSec[current.station] != null
            ? (kMinSegmentSec[current.station]! < kTrainingFloorSec
                ? kMinSegmentSec[current.station]!
                : kTrainingFloorSec)
            : kTrainingFloorSec)
        : (kMinSegmentSec[current.station] ?? 0);
    final currentStart = localStarts[openIdx];
    if (currentStart != null && at - currentStart < minSec) continue;

    out.add(ReconcileBoundary(at, supporting, current.kind, current.station));
    localStarts[openIdx + 1] = at;
    openIdx = openIdx + 1 < plan.segments.length ? openIdx + 1 : -1;
    floor = at;
  }
  return out;
}
