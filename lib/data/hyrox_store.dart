// HYROX storage — schema, row models and the CRUD seam.
//
// Parent/child on purpose. `hyrox_session` owns the frozen plan and the
// lifecycle; `hyrox_segment` owns the timed boundaries. One segment per
// ROUND (1 km run + station, see hyrox_plan.dart), so a race is exactly eight
// segments with `round_index` 1..8; round 8 runs to the finish line and
// includes the final 1 km run. A round segment MAY also get a real `sessions`
// row (workout_id) from the live wiring, so routes, zones, splits and Health
// export keep their single existing code path.
//
// THE TWO INVARIANTS THIS FILE ENFORCES, INDEPENDENT OF THE STATE MACHINE:
//
//  1. FINALIZED MEANS IMMUTABLE. `finalize()` stamps `finalized_at`; every
//     later write to that session or its segments throws (including its note).
//     A race that has been saved is a record, and a screen must not be able to
//     quietly rewrite it. Boundary corrections belong to the not-yet-finalized
//     session, and a future "re-derive" flow gets a NEW row, exactly like
//     `day_result`'s immutable-per-version rule.
//
//  2. SEGMENTS CANNOT OVERLAP OR RUN BACKWARDS. A segment's end is at or after
//     its start, and neighbours meet at one instant or leave a gap: segment
//     i's end is at or before segment i+1's start. That is what a single
//     "next" tap on the band means. A gap is a PAUSE (station setup, a breather
//     between rounds), reported separately from moving time — never billed as
//     workout time.
//
// Units follow the `sessions` table: segment boundaries are epoch SECONDS,
// bookkeeping stamps (created_at / updated_at / finalized_at) are epoch
// MILLISECONDS. Mixing them is the classic silent bug, so the row models name
// the unit in every field.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'hyrox_plan.dart';

/// schemaVersion 61. Parent before child on every create. (Rung 60 belongs to
/// the triathlon storage PR; this feature takes the next free rung.)
Future<void> createHyroxTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS hyrox_session (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      preset TEXT NOT NULL,
      status TEXT NOT NULL,
      plan_json TEXT NOT NULL,
      start_ts INTEGER,
      end_ts INTEGER,
      note TEXT NOT NULL DEFAULT '',
      finalized_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_hyrox_session_status '
    'ON hyrox_session(status)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_hyrox_session_start '
    'ON hyrox_session(start_ts)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS hyrox_segment (
      session_id TEXT NOT NULL,
      idx INTEGER NOT NULL,
      kind TEXT NOT NULL,
      station TEXT NOT NULL,
      round_index INTEGER,
      planned_distance_m REAL,
      planned_reps INTEGER,
      planned_cal INTEGER,
      goal_sec INTEGER,
      start_ts INTEGER,
      end_ts INTEGER,
      boundary_source TEXT NOT NULL DEFAULT 'unknown',
      workout_id TEXT,
      distance_m REAL,
      distance_source TEXT,
      hr_source TEXT,
      PRIMARY KEY (session_id, idx)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_hyrox_segment_workout '
    'ON hyrox_segment(workout_id)',
  );
}

/// How a segment boundary was established. `gesture` is a live band tap,
/// `phone` an on-screen button, `manual` a boundary the user moved afterwards,
/// `posthoc` a boundary reconstructed from band history or suggested by the
/// timeline — i.e. NOT a measurement of when the athlete actually changed
/// station, and therefore never to be presented as one. `unknown` is the
/// honest default for a row this build did not write.
const List<String> kHyroxBoundarySources = [
  'gesture',
  'phone',
  'manual',
  'posthoc',
  'unknown',
];

class HyroxSegment {
  const HyroxSegment({
    required this.sessionId,
    required this.idx,
    required this.kind,
    required this.station,
    this.roundIndex,
    this.plannedDistanceM,
    this.plannedReps,
    this.plannedCal,
    this.goalSec,
    this.startTs,
    this.endTs,
    this.boundarySource = 'unknown',
    this.workoutId,
    this.distanceM,
    this.distanceSource,
    this.hrSource,
  });

  final String sessionId;
  final int idx;
  final HyroxSegmentKind kind;

  /// The station this round ends with.
  final HyroxStation station;

  /// 1..8 in a fixed race; null in a free-form plan.
  final int? roundIndex;

  /// Planned targets frozen from the plan. A PLAN, never a measurement.
  final double? plannedDistanceM;
  final int? plannedReps;
  final int? plannedCal;
  final int? goalSec;

  /// Epoch SECONDS. Null until the segment is entered / left.
  final int? startTs;
  final int? endTs;

  final String boundarySource;

  /// The linked `sessions.id` for a round segment, null when not banked yet.
  final String? workoutId;

  /// MEASURED or explicitly user-entered distance in metres. Null means "we do
  /// not know" and the UI shows "—". It is NEVER copied from
  /// [plannedDistanceM]: a plan is not a measurement.
  final double? distanceM;

  /// 'gps' | 'user' | null. Null whenever [distanceM] is null — a distance
  /// without a source is exactly the number this repo refuses to show.
  final String? distanceSource;

  /// 'band' | 'strap' | null: which heart-rate source the segment used.
  final String? hrSource;

  bool get isOpen => startTs != null && endTs == null;

  /// Seconds in the segment, or null while it is still open. Zero-length
  /// segments are legal (an instant tap-through), negative ones are not.
  int? get durationSec =>
      startTs == null || endTs == null ? null : endTs! - startTs!;

  HyroxSegment copyWith({
    int? roundIndex,
    double? plannedDistanceM,
    int? plannedReps,
    int? plannedCal,
    int? goalSec,
    int? startTs,
    int? endTs,
    String? boundarySource,
    String? workoutId,
    double? distanceM,
    String? distanceSource,
    String? hrSource,
    bool clearEnd = false,
    bool clearStart = false,
  }) {
    return HyroxSegment(
      sessionId: sessionId,
      idx: idx,
      kind: kind,
      station: station,
      roundIndex: roundIndex ?? this.roundIndex,
      plannedDistanceM: plannedDistanceM ?? this.plannedDistanceM,
      plannedReps: plannedReps ?? this.plannedReps,
      plannedCal: plannedCal ?? this.plannedCal,
      goalSec: goalSec ?? this.goalSec,
      startTs: clearStart ? null : (startTs ?? this.startTs),
      endTs: clearEnd ? null : (endTs ?? this.endTs),
      boundarySource: boundarySource ?? this.boundarySource,
      workoutId: workoutId ?? this.workoutId,
      distanceM: distanceM ?? this.distanceM,
      distanceSource: distanceSource ?? this.distanceSource,
      hrSource: hrSource ?? this.hrSource,
    );
  }

  Map<String, Object?> toRow() => {
        'session_id': sessionId,
        'idx': idx,
        'kind': kind.key,
        'station': station.key,
        'round_index': roundIndex,
        'planned_distance_m': plannedDistanceM,
        'planned_reps': plannedReps,
        'planned_cal': plannedCal,
        'goal_sec': goalSec,
        'start_ts': startTs,
        'end_ts': endTs,
        'boundary_source': boundarySource,
        'workout_id': workoutId,
        'distance_m': distanceM,
        'distance_source': distanceSource,
        'hr_source': hrSource,
      };

  static HyroxSegment? fromRow(Map<String, Object?> r) {
    final kind = HyroxSegmentKindX.fromKey(r['kind'] as String?);
    final station = HyroxStationX.fromKey(r['station'] as String?);
    if (kind == null || station == null) return null;
    return HyroxSegment(
      sessionId: r['session_id'] as String,
      idx: (r['idx'] as num).toInt(),
      kind: kind,
      station: station,
      roundIndex: (r['round_index'] as num?)?.toInt(),
      plannedDistanceM: (r['planned_distance_m'] as num?)?.toDouble(),
      plannedReps: (r['planned_reps'] as num?)?.toInt(),
      plannedCal: (r['planned_cal'] as num?)?.toInt(),
      goalSec: (r['goal_sec'] as num?)?.toInt(),
      startTs: (r['start_ts'] as num?)?.toInt(),
      endTs: (r['end_ts'] as num?)?.toInt(),
      boundarySource: r['boundary_source'] as String? ?? 'unknown',
      workoutId: r['workout_id'] as String?,
      distanceM: (r['distance_m'] as num?)?.toDouble(),
      distanceSource: r['distance_source'] as String?,
      hrSource: r['hr_source'] as String?,
    );
  }
}

class HyroxSession {
  const HyroxSession({
    required this.id,
    required this.kind,
    required this.preset,
    required this.status,
    required this.plan,
    this.startTs,
    this.endTs,
    this.note = '',
    this.finalizedAt,
    required this.createdAt,
    required this.updatedAt,
    this.segments = const [],
  });

  final String id;

  /// 'race' | 'training'.
  final String kind;
  final String preset;

  /// 'armed' | 'active' | 'finished' | 'finalized' | 'discarded'. The state
  /// machine owns transitions; storage only refuses to write a finalized row.
  final String status;

  /// The frozen plan. Null only when a row was written by a build whose plan
  /// format this one cannot read — callers show "unknown plan", not a guess.
  final HyroxPlan? plan;

  /// Epoch SECONDS, mirroring the first/last segment boundary.
  final int? startTs;
  final int? endTs;

  final String note;

  /// Epoch MILLISECONDS. Non-null makes the session and its segments read-only.
  final int? finalizedAt;

  /// Epoch MILLISECONDS.
  final int createdAt;
  final int updatedAt;

  final List<HyroxSegment> segments;

  bool get isFinalized => finalizedAt != null;

  /// 'armed' | 'active' | 'finished' | 'abandoned' | 'discarded' | 'finalized'.
  static const statuses = {
    'armed',
    'active',
    'finished',
    'abandoned',
    'discarded',
    'finalized',
  };

  /// Sum of closed segment durations = time actually in a round.
  /// Null when no segment is closed yet — a pause or an open tail is never
  /// billed as workout time.
  int? get movingSec {
    final closed = [
      for (final s in segments)
        if (s.startTs != null && s.endTs != null) s.endTs! - s.startTs!,
    ];
    return closed.isEmpty ? null : closed.reduce((a, b) => a + b);
  }

  /// Total wall-clock time of the session (start to last end). INCLUDES any
  /// pauses between segments — that is the difference from [movingSec].
  int? get totalSec {
    if (startTs == null || endTs == null) return null;
    return endTs! - startTs!;
  }

  /// Pauses between segments, in seconds. Always >= 0.
  int? get pauseSec {
    final t = totalSec;
    final m = movingSec;
    if (t == null || m == null) return null;
    return t - m;
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'kind': kind,
        'preset': preset,
        'status': status,
        'plan_json': plan == null ? '{}' : jsonEncode(plan!.toJson()),
        'start_ts': startTs,
        'end_ts': endTs,
        'note': note,
        'finalized_at': finalizedAt,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  static HyroxSession fromRow(Map<String, Object?> r) {
    HyroxPlan? plan;
    try {
      final decoded = jsonDecode(r['plan_json'] as String? ?? '{}');
      if (decoded is Map) {
        plan = HyroxPlan.fromJson(decoded.cast<String, Object?>());
      }
    } on FormatException {
      plan = null;
    } catch (_) {
      // A persisted payload that is not even a JSON map (or contains
      // wrong-typed fields) is an unreadable plan, not a crash.
      plan = null;
    }
    return HyroxSession(
      id: r['id'] as String,
      kind: r['kind'] as String? ?? 'race',
      preset: r['preset'] as String? ?? 'custom',
      status: r['status'] as String? ?? 'armed',
      plan: plan,
      startTs: (r['start_ts'] as num?)?.toInt(),
      endTs: (r['end_ts'] as num?)?.toInt(),
      note: r['note'] as String? ?? '',
      finalizedAt: (r['finalized_at'] as num?)?.toInt(),
      createdAt: (r['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (r['updated_at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One boundary derived from the strap's stored taps (see the reconciler).
///
/// Lives in the data layer so storage never has to import a state-layer file:
/// the dependency runs one way, reconciler -> store.
class ReconcileBoundary {
  const ReconcileBoundary(this.atSec, this.taps, this.kind, this.station);

  /// Strap time of the FIRST tap of the accepted cluster.
  final int atSec;
  final int taps;

  /// The segment the cluster closes; its successor starts at [atSec].
  final HyroxSegmentKind kind;

  /// The station of the segment the cluster closes.
  final HyroxStation station;

  @override
  String toString() =>
      'ReconcileBoundary($kind/${station.key} @$atSec, $taps taps)';
}

/// Thrown when a write targets a finalized session, or would make segments
/// overlap. Deliberately loud: a silent no-op here reads as "the race saved".
class HyroxWriteError implements Exception {
  HyroxWriteError(this.message);
  final String message;
  @override
  String toString() => 'HyroxWriteError: $message';
}

class HyroxDb {
  HyroxDb._();

  /// Persist a new ARMED session with its planned segments in one transaction.
  /// Nothing here starts a clock: arming is a choice, not a measurement.
  static Future<void> create(Database db, HyroxSession session) async {
    final plan0 = session.plan;
    if (plan0 == null) throw HyroxWriteError('a session needs a readable plan');
    final problem = plan0.validate();
    if (problem != null) throw HyroxWriteError(problem);
    if (session.preset != plan0.preset) {
      throw HyroxWriteError(
        'session preset ${session.preset} does not match the plan preset '
        '${plan0.preset}',
      );
    }
    if (session.status != 'armed') {
      throw HyroxWriteError('a new session is created armed, not ${session.status}');
    }
    if (session.isFinalized || session.startTs != null || session.endTs != null) {
      throw HyroxWriteError('create cannot pre-fill session bounds');
    }
    if (session.segments.isNotEmpty &&
        session.segments.length != session.plan!.segments.length) {
      throw HyroxWriteError('segment rows do not match the plan');
    }
    await db.transaction((txn) async {
      final clash = await txn.query(
        'hyrox_session',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [session.id],
        limit: 1,
      );
      if (clash.isNotEmpty) {
        throw HyroxWriteError('session ${session.id} already exists');
      }
      await txn.insert('hyrox_session', session.toRow());
      final plan = session.plan!;
      for (var i = 0; i < plan.segments.length; i++) {
        final p = plan.segments[i];
        final supplied = i < session.segments.length ? session.segments[i] : null;
        final seg = supplied ??
            HyroxSegment(
              sessionId: session.id,
              idx: i,
              kind: p.kind,
              station: p.station,
              roundIndex: p.roundIndex,
              plannedDistanceM: p.plannedDistanceM,
              plannedReps: p.plannedReps,
              plannedCal: p.plannedCal,
              goalSec: p.goalSec,
            );
        if (seg.sessionId != session.id || seg.idx != i || seg.kind != p.kind ||
            seg.station != p.station || seg.roundIndex != p.roundIndex ||
            seg.plannedDistanceM != p.plannedDistanceM ||
            seg.plannedReps != p.plannedReps || seg.plannedCal != p.plannedCal ||
            seg.goalSec != p.goalSec) {
          throw HyroxWriteError('segment $i does not match the plan');
        }
        if (seg.startTs != null ||
            seg.endTs != null ||
            seg.workoutId != null ||
            seg.distanceM != null ||
            seg.distanceSource != null) {
          throw HyroxWriteError(
            'create stores a plan; segment $i already carries history',
          );
        }
        _checkSegmentShape(seg);
        if (i > 0 && session.segments.isNotEmpty) {
          _checkNeighbour(seg, session.segments[i - 1]);
        }
        await txn.insert('hyrox_segment', seg.toRow());
      }
    });
  }

  static Future<HyroxSession?> byId(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'hyrox_session',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _withSegments(db, HyroxSession.fromRow(rows.first));
  }

  static Future<List<HyroxSegment>> segments(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'hyrox_segment',
      where: 'session_id = ?',
      whereArgs: [id],
      orderBy: 'idx ASC',
    );
    return [for (final r in rows) HyroxSegment.fromRow(r)].whereType<HyroxSegment>().toList();
  }

  static Future<HyroxSession> _withSegments(DatabaseExecutor db, HyroxSession s) async {
    final segs = await segments(db, s.id);
    return HyroxSession(
      id: s.id,
      kind: s.kind,
      preset: s.preset,
      status: s.status,
      plan: s.plan,
      startTs: s.startTs,
      endTs: s.endTs,
      note: s.note,
      finalizedAt: s.finalizedAt,
      createdAt: s.createdAt,
      updatedAt: s.updatedAt,
      segments: segs,
    );
  }

  /// The ONE session a relaunch must resume: not finalized, not discarded,
  /// newest first. Returning more than the newest would let a stale armed row
  /// shadow the race actually in progress, so callers get a single answer.
  static Future<HyroxSession?> activeSession(Database db) async {
    final rows = await db.query(
      'hyrox_session',
      where: "finalized_at IS NULL AND status != 'discarded'",
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _withSegments(db, HyroxSession.fromRow(rows.first));
  }

  /// Finalized sessions at [preset], newest first — the comparison set for
  /// "total time vs your previous races".
  static Future<List<HyroxSession>> finalized(
    Database db, {
    String? preset,
    int limit = 50,
  }) async {
    final rows = await db.query(
      'hyrox_session',
      where: preset == null ? 'finalized_at IS NOT NULL' : 'finalized_at IS NOT NULL AND preset = ?',
      whereArgs: preset == null ? null : [preset],
      orderBy: 'start_ts DESC',
      limit: limit,
    );
    final out = <HyroxSession>[];
    for (final r in rows) {
      out.add(await _withSegments(db, HyroxSession.fromRow(r)));
    }
    return out;
  }

  /// Write one segment's boundaries.
  ///
  /// Reads the plan and the neighbours INSIDE the same transaction, so the
  /// checks cannot be made against a stale in-memory copy. A segment's INDEX
  /// never changes here: this method only moves/records the boundaries of a
  /// row the plan already created. Moving a boundary that neighbours share is
  /// [adjustBoundary]'s job, because both sides have to move together.
  static Future<void> saveSegment(Database db, HyroxSegment segment) async {
    _checkSegmentShape(segment);
    await db.transaction((txn) async {
      await _requireWritable(txn, segment.sessionId);
      final existing = await segments(txn, segment.sessionId);
      final matching = existing.where((s) => s.idx == segment.idx).toList();
      if (matching.isEmpty) {
        throw HyroxWriteError('segment ${segment.idx} is not in the plan');
      }
      final original = matching.single;
      if (segment.kind != original.kind ||
          segment.station != original.station ||
          segment.roundIndex != original.roundIndex ||
          segment.plannedDistanceM != original.plannedDistanceM ||
          segment.plannedReps != original.plannedReps ||
          segment.plannedCal != original.plannedCal ||
          segment.goalSec != original.goalSec) {
        throw HyroxWriteError('the planned segment is immutable');
      }
      for (final other in existing) {
        if (other.idx != segment.idx) _checkNeighbour(segment, other);
      }
      await txn.update(
        'hyrox_segment',
        segment.toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [segment.sessionId, segment.idx],
      );
      _validateTimeline(await segments(txn, segment.sessionId));
      await _recomputeSessionBounds(txn, segment.sessionId);
    });
  }

  /// Opens segment 0 at [ts] and marks the session active.
  ///
  /// Fails when the session already has a boundary: an armed session may start
  /// exactly once, and a second start is a bug in the caller, not a rewind.
  static Future<void> startSegment({
    required Database db,
    required String sessionId,
    required int ts,
    required String boundarySource,
  }) async {
    if (ts <= 0) throw HyroxWriteError('a start needs a real timestamp');
    _checkBoundarySource(boundarySource);
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      final segs = await segments(txn, sessionId);
      if (segs.isEmpty) throw HyroxWriteError('the plan has no segments');
      if (segs.any((s) => s.startTs != null || s.endTs != null)) {
        throw HyroxWriteError('the session has already started');
      }
      await txn.update(
        'hyrox_segment',
        segs.first
            .copyWith(startTs: ts, boundarySource: boundarySource)
            .toRow(),
        where: 'session_id = ? AND idx = 0',
        whereArgs: [sessionId],
      );
      _validateTimeline(await segments(txn, sessionId));
      await _recomputeSessionBounds(txn, sessionId, status: 'active');
    });
  }

  /// Atomically closes segment [currentIdx] and opens [currentIdx + 1] at [ts].
  ///
  /// Both sides move or neither does. Validation is deliberately strict: the
  /// current segment must be open, the next one must not have started, and
  /// [ts] must not run backwards past either neighbouring boundary.
  static Future<void> transitionSegment({
    required Database db,
    required String sessionId,
    required int currentIdx,
    required int transitionTs,
    required String boundarySource,
  }) async {
    _checkBoundarySource(boundarySource);
    await db.transaction((txn) async {
      await _transitionInTx(
        txn,
        sessionId: sessionId,
        currentIdx: currentIdx,
        transitionTs: transitionTs,
        boundarySource: boundarySource,
      );
    });
  }

  /// Closes the FINAL segment at [ts] and marks the session finished.
  ///
  /// Only the last segment may be finished: closing an earlier one would leave
  /// later segments unstarted while the session claims to be over, and
  /// [finalize] — which requires every segment closed — could never accept it.
  /// A DNF needs an explicit model (the open cut segment), not a silent
  /// half-race.
  static Future<void> finishSegment({
    required Database db,
    required String sessionId,
    required int ts,
    required String boundarySource,
  }) async {
    _checkBoundarySource(boundarySource);
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      final segs = await segments(txn, sessionId);
      final open = segs.where((s) => s.isOpen).toList();
      if (open.length != 1) {
        throw HyroxWriteError('exactly one segment must be open to finish');
      }
      final last = open.single;
      if (last.startTs == null || ts < last.startTs!) {
        throw HyroxWriteError('a segment cannot end before it starts');
      }
      if (last.idx != segs.length - 1) {
        throw HyroxWriteError(
          'finish closes the final segment; close segment ${last.idx} with a '
          'transition instead',
        );
      }
      await txn.update(
        'hyrox_segment',
        last.copyWith(endTs: ts, boundarySource: boundarySource).toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, last.idx],
      );
      _validateTimeline(await segments(txn, sessionId));
      await _recomputeSessionBounds(txn, sessionId, status: 'finished');
    });
  }

  /// Moves the race start: clears every boundary of the not-yet-finalized
  /// session and restarts segment 0 at [newTs].
  ///
  /// A false triple-tap at the start line starts the race wrongly, and because
  /// the session may only start once, no existing write can heal that. This
  /// is the explicit correction path: it is only legal while NO segment has
  /// ended yet (a race with closed splits keeps its history), and the new
  /// start is stamped 'manual'.
  static Future<void> adjustStart({
    required Database db,
    required String sessionId,
    required int newTs,
  }) async {
    if (newTs <= 0) {
      throw HyroxWriteError('a start needs a real timestamp');
    }
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      final segs = await segments(txn, sessionId);
      if (segs.isEmpty) throw HyroxWriteError('the plan has no segments');
      if (segs.any((s) => s.endTs != null)) {
        throw HyroxWriteError(
          'a segment already ended — the start can no longer be moved',
        );
      }
      if (segs.any((s) => s.workoutId != null)) {
        throw HyroxWriteError(
          'a segment is linked to a workout — unlink it before moving the start',
        );
      }
      for (var i = 0; i < segs.length; i++) {
        final cleared = segs[i].copyWith(
          clearStart: true,
          clearEnd: true,
          boundarySource: i == 0 ? 'manual' : segs[i].boundarySource,
        );
        await txn.update(
          'hyrox_segment',
          cleared.toRow(),
          where: 'session_id = ? AND idx = ?',
          whereArgs: [sessionId, i],
        );
      }
      final first = (await segments(txn, sessionId)).first;
      await txn.update(
        'hyrox_segment',
        first.copyWith(startTs: newTs, boundarySource: 'manual').toRow(),
        where: 'session_id = ? AND idx = 0',
        whereArgs: [sessionId],
      );
      _validateTimeline(await segments(txn, sessionId));
      await _recomputeSessionBounds(txn, sessionId, status: 'active');
    });
  }

  /// Atomically moves a boundary shared by segment [idx] and [idx + 1].
  ///
  /// Separate [saveSegment] calls cannot do this: as soon as both sides have
  /// timestamps, changing one alone breaks the contiguity rule and is refused.
  /// Both rows must already meet, and [newTs] must stay inside both segments.
  static Future<void> adjustBoundary({
    required Database db,
    required String sessionId,
    required int idx,
    required int newTs,
  }) async {
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      final segs = await segments(txn, sessionId);
      if (idx < 0 || idx + 1 >= segs.length) {
        throw HyroxWriteError('there is no boundary after segment $idx');
      }
      final left = segs.firstWhere((s) => s.idx == idx);
      final right = segs.firstWhere((s) => s.idx == idx + 1);
      final wasStart = right.startTs;
      final wasEnd = left.endTs;
      if (wasStart == null || wasEnd == null || wasStart != wasEnd) {
        throw HyroxWriteError('segments $idx and ${idx + 1} do not meet');
      }
      if (left.startTs != null && newTs < left.startTs!) {
        throw HyroxWriteError('the boundary would precede segment $idx');
      }
      if (right.endTs != null && newTs > right.endTs!) {
        throw HyroxWriteError('the boundary would follow segment ${idx + 1}');
      }
      // Provenance follows the actor: a boundary moved by hand is 'manual' on
      // both rows. Keeping 'gesture' here would claim the band recorded a time
      // the athlete actually corrected.
      await txn.update(
        'hyrox_segment',
        left.copyWith(endTs: newTs, boundarySource: 'manual').toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx],
      );
      await txn.update(
        'hyrox_segment',
        right.copyWith(startTs: newTs, boundarySource: 'manual').toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx + 1],
      );
      _validateTimeline(await segments(txn, sessionId));
      await _recomputeSessionBounds(txn, sessionId);
    });
  }

  /// Removes the boundary after segment [idx]: segments [idx] and [idx + 1]
  /// merge into one, the successor's boundaries are cleared, and the merged
  /// segment keeps the earlier start and the later end. Both rows must have
  /// started, and the boundary is stamped 'manual' on the survivor.
  ///
  /// This is the correction for a false triple-tap mid-race that split one
  /// round in two: [adjustBoundary] can only move a boundary, not delete
  /// one, and after [finalize] the record is immutable by design.
  static Future<void> removeBoundary({
    required Database db,
    required String sessionId,
    required int idx,
  }) async {
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      final segs = await segments(txn, sessionId);
      if (idx < 0 || idx + 1 >= segs.length) {
        throw HyroxWriteError('there is no boundary after segment $idx');
      }
      final left = segs.firstWhere((s) => s.idx == idx);
      final right = segs.firstWhere((s) => s.idx == idx + 1);
      if (left.startTs == null || right.startTs == null) {
        throw HyroxWriteError(
          'segments $idx and ${idx + 1} have not both started',
        );
      }
      if (left.endTs != null && left.endTs != right.startTs) {
        throw HyroxWriteError('segments $idx and ${idx + 1} do not meet');
      }
      // Merging is only meaningful while the successor is the newest started
      // segment: clearing its start would break the started-prefix rule the
      // moment any later segment has already begun.
      if (segs.any((s) => s.idx > idx + 1 && s.startTs != null)) {
        throw HyroxWriteError(
          'a later segment already started — the boundary cannot be removed',
        );
      }
      if (left.workoutId != null || right.workoutId != null) {
        throw HyroxWriteError(
          'a segment is linked to a workout — unlink it before removing the boundary',
        );
      }
      // Merging into the final segment when it is already CLOSED would leave
      // the session 'finished' with an unstarted last segment — no write could
      // ever progress or finalize it again. Move the boundary instead.
      if (right.idx == segs.length - 1 && right.endTs != null) {
        throw HyroxWriteError(
          'the final segment is closed — move the boundary instead of removing it',
        );
      }
      final merged = right.endTs == null
          ? left.copyWith(clearEnd: true, boundarySource: 'manual')
          : left.copyWith(endTs: right.endTs, boundarySource: 'manual');
      await txn.update(
        'hyrox_segment',
        merged.toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx],
      );
      await txn.update(
        'hyrox_segment',
        right.copyWith(clearStart: true, clearEnd: true).toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx + 1],
      );
      _validateTimeline(await segments(txn, sessionId));
      await _recomputeSessionBounds(txn, sessionId);
    });
  }

  /// Applies a whole offline-derived boundary chain in ONE transaction.
  ///
  /// Used by the reconciler. The FIRST boundary starts the race when nothing
  /// has started yet; every later one closes the current segment and opens the
  /// next; a boundary at the very end closes the last segment. A failure
  /// anywhere rolls the whole chain back, so a race is never left half-marked.
  ///
  /// Rejects a boundary that would not advance, so a stale or repeated event
  /// log cannot rewind a session.
  static Future<void> applyOfflineBoundariesInTx(
    DatabaseExecutor txn, {
    required String sessionId,
    required List<ReconcileBoundary> boundaries,
  }) async {
    if (boundaries.isEmpty) return;
    await _requireWritable(txn, sessionId);
    var segs = await segments(txn, sessionId);
    if (segs.isEmpty) throw HyroxWriteError('the plan has no segments');
    for (var i = 0; i < boundaries.length; i++) {
      final b = boundaries[i];
      segs = await segments(txn, sessionId);
      final open = segs.where((s) => s.isOpen).toList();
      if (open.isEmpty) {
        // Nothing running: this boundary STARTS the race, and only as the
        // first one. Anything later is a log we cannot place.
        if (i != 0 ||
            segs.any((s) => s.startTs != null) ||
            b.kind != segs.first.kind) {
          throw HyroxWriteError('no open segment to close at ${b.atSec}');
        }
        await txn.update(
          'hyrox_segment',
          segs.first
              .copyWith(startTs: b.atSec, boundarySource: 'posthoc')
              .toRow(),
          where: 'session_id = ? AND idx = 0',
          whereArgs: [sessionId],
        );
        _validateTimeline(segs = await segments(txn, sessionId));
        await _recomputeSessionBounds(txn, sessionId, status: 'active');
        continue;
      }
      if (open.length != 1) {
        throw HyroxWriteError('more than one open segment');
      }
      final current = open.single;
      if (b.kind != current.kind || b.station != current.station) {
        throw HyroxWriteError('boundary does not close the open segment');
      }
      final hasNext = current.idx + 1 < segs.length;
      if (!hasNext) {
        // Closing the final segment ends the race, so nothing may follow it.
        if (i != boundaries.length - 1) {
          throw HyroxWriteError('boundaries follow the final segment');
        }
        if (current.startTs == null || b.atSec < current.startTs!) {
          throw HyroxWriteError(
            'the final segment would end before it started',
          );
        }
        await txn.update(
          'hyrox_segment',
          current
              .copyWith(endTs: b.atSec, boundarySource: 'posthoc')
              .toRow(),
          where: 'session_id = ? AND idx = ?',
          whereArgs: [sessionId, current.idx],
        );
        _validateTimeline(await segments(txn, sessionId));
        await _recomputeSessionBounds(txn, sessionId, status: 'finished');
        return;
      }
      await _transitionInTx(
        txn,
        sessionId: sessionId,
        currentIdx: current.idx,
        transitionTs: b.atSec,
        boundarySource: 'posthoc',
      );
    }
    // A chain that never reached the last segment leaves it running; the
    // session bounds are still correct for what is known.
    _validateTimeline(await segments(txn, sessionId));
    await _recomputeSessionBounds(txn, sessionId);
  }

  /// Link a round segment to the `sessions` row the live workout banked.
  ///
  /// Every HYROX segment is a real round (there is no transition kind), so
  /// unlike the multisport store there is no transition refusal here — the
  /// null check on [HyroxSegment.fromRow] already refuses an unreadable row.
  static Future<void> linkWorkout(
    Database db,
    String sessionId,
    int idx,
    String workoutId,
  ) async {
    if (workoutId.trim().isEmpty) {
      throw HyroxWriteError('a workout link needs a workout id');
    }
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      final rows = await txn.query(
        'hyrox_segment',
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw HyroxWriteError('segment $idx is not in session $sessionId');
      }
      final seg = HyroxSegment.fromRow(rows.first);
      if (seg == null) {
        throw HyroxWriteError('segment $idx has an unknown kind or station');
      }
      final existing = await txn.query(
        'hyrox_segment',
        columns: ['session_id', 'idx'],
        where: 'workout_id = ? AND NOT (session_id = ? AND idx = ?)',
        whereArgs: [workoutId, sessionId, idx],
      );
      if (existing.isNotEmpty) {
        throw HyroxWriteError('workout $workoutId is already linked');
      }
      final updated = await txn.update(
        'hyrox_segment',
        {'workout_id': workoutId},
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx],
      );
      if (updated != 1) {
        throw HyroxWriteError('workout link matched no segment row');
      }
      await _touch(txn, sessionId);
    });
  }

  /// Note and lifecycle status. Refuses a finalized row, and never clears
  /// `finalized_at` — finalization is one-way by design.
  ///
  /// Session bounds are NOT writable here: they are derived from the segments
  /// by [_recomputeSessionBounds], and letting a screen set them would give the
  /// same fact two sources. `finished`/`finalized` are set by their own calls.
  static Future<void> updateSession(Database db, HyroxSession session) async {
    await db.transaction((txn) async {
      await _requireWritable(txn, session.id);
      if (session.isFinalized || session.status == 'finalized') {
        throw HyroxWriteError('use finalize to finalize a session');
      }
      const writable = {'armed', 'active', 'discarded', 'abandoned'};
      if (!writable.contains(session.status)) {
        throw HyroxWriteError(
          'status ${session.status} is set by start/finish/finalize, not here',
        );
      }
      // Bounds are derived from the segments (_recomputeSessionBounds) and
      // deliberately absent here: a screen must not be able to desync them.
      final row = <String, Object?>{
        'status': session.status,
        'note': session.note,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };
      await txn.update(
        'hyrox_session',
        row,
        where: 'id = ?',
        whereArgs: [session.id],
      );
    });
  }

  /// Stamp finalization. Every segment must be CLOSED for a finished race,
  /// otherwise the saved record would contain a split with no end — an open
  /// segment is a live session, and finalizing it would freeze a lie.
  static Future<void> finalize(Database db, String id) async {
    await db.transaction((txn) async {
      await _requireWritable(txn, id);
      final rows = await txn.query(
        'hyrox_session',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw HyroxWriteError('no such session: $id');
      final status = rows.first['status'] as String;
      if (status != 'finished' && status != 'abandoned') {
        throw HyroxWriteError(
          'only a finished or abandoned session can be finalized',
        );
      }
      final segs = await segments(txn, id);
      if (segs.isEmpty) throw HyroxWriteError('nothing to finalize');
      if (status == 'finished') {
        for (final s in segs) {
          if (s.startTs == null || s.endTs == null) {
            throw HyroxWriteError('segment ${s.idx} is still open');
          }
        }
      } else {
        // ABANDONED (DNF): exactly one segment may be open — the round the
        // athlete stopped in. Its duration stays null; nothing is invented.
        // Every segment before it must be closed, every segment after it
        // must be untouched, and at least one segment must have started
        // (otherwise this is a discard, not a race).
        final open = segs.where((s) => s.isOpen).toList();
        final started = segs.where((s) => s.startTs != null).length;
        if (started == 0) {
          throw HyroxWriteError(
            'nothing started — discard the session instead of finalizing',
          );
        }
        if (open.length > 1) {
          throw HyroxWriteError('more than one open segment');
        }
        if (open.isNotEmpty) {
          final cut = open.single;
          if (segs.where((s) => s.idx < cut.idx && s.endTs == null).isNotEmpty) {
            throw HyroxWriteError('an earlier segment is still open');
          }
          if (segs.where((s) => s.idx > cut.idx && s.startTs != null).isNotEmpty) {
            throw HyroxWriteError('a later segment already started');
          }
        }
      }
      _validateTimeline(segs);
      await txn.update(
        'hyrox_session',
        {
          'status': 'finalized',
          'finalized_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  /// Deleting a race removes its segment rows with it; the linked `sessions`
  /// rows are deleted by the caller, which owns that table's cascade (route,
  /// splits, sets). Returns the workout ids so the caller can do exactly that.
  static Future<List<String>> delete(Database db, String id) async {
    return db.transaction((txn) async {
      final segs = await txn.query(
        'hyrox_segment',
        columns: ['workout_id'],
        where: 'session_id = ?',
        whereArgs: [id],
      );
      final workoutIds = [
        for (final r in segs)
          if (r['workout_id'] is String) r['workout_id'] as String,
      ];
      await txn.delete(
        'hyrox_segment',
        where: 'session_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'hyrox_session',
        where: 'id = ?',
        whereArgs: [id],
      );
      return workoutIds;
    });
  }

  /// THE timeline rule, applied to the whole session and not just the row
  /// that changed.
  ///
  /// Started segments form a PREFIX (segment 3 cannot start while segment 0
  /// is still a plan row), boundaries are MONOTONIC, and no two segments
  /// OVERLAP. A gap between one segment's end and the next one's start is a
  /// PAUSE, not a gap in the data: a workout can be interrupted for minutes
  /// between stations, and a missed transition tap looks exactly like that.
  /// The session then reports total and moving time separately, so a pause is
  /// never silently billed as workout time.
  static void _validateTimeline(List<HyroxSegment> segs) {
    var seenUnstarted = false;
    var open = 0;
    int? prevEnd;
    for (final s in segs) {
      final started = s.startTs != null;
      final ended = s.endTs != null;
      if (!started) {
        seenUnstarted = true;
        if (ended) {
          throw HyroxWriteError('segment ${s.idx} ends before it starts');
        }
        continue;
      }
      if (seenUnstarted) {
        throw HyroxWriteError(
          'segment ${s.idx} starts while an earlier segment never did',
        );
      }
      if (ended && s.endTs! < s.startTs!) {
        throw HyroxWriteError('segment ${s.idx} ends before it starts');
      }
      if (prevEnd != null) {
        if (s.startTs! < prevEnd) {
          throw HyroxWriteError(
            'segment ${s.idx} overlaps its predecessor',
          );
        }
        // s.startTs == prevEnd is a direct transition; > is a pause. Both legal.
      }
      if (ended) {
        prevEnd = s.endTs;
      } else {
        open++;
        if (open > 1) {
          throw HyroxWriteError('more than one segment is open');
        }
        for (final later in segs) {
          if (later.idx > s.idx && later.startTs != null) {
            throw HyroxWriteError(
              'segment ${later.idx} starts while ${s.idx} is open',
            );
          }
        }
        prevEnd = null;
      }
    }
  }

  static void _checkBoundarySource(String source) {
    if (!kHyroxBoundarySources.contains(source)) {
      throw HyroxWriteError('unknown boundary source $source');
    }
  }

  /// The transition body, callable from inside an existing transaction.
  ///
  /// Public [transitionSegment] wraps it; the offline reconciler uses it to
  /// apply a whole chain of boundaries atomically instead of one commit each.
  static Future<void> _transitionInTx(
    DatabaseExecutor txn, {
    required String sessionId,
    required int currentIdx,
    required int transitionTs,
    required String boundarySource,
  }) async {
    await _requireWritable(txn, sessionId);
    final segs = await segments(txn, sessionId);
    final current = segs.where((s) => s.idx == currentIdx).toList();
    final next = segs.where((s) => s.idx == currentIdx + 1).toList();
    if (current.isEmpty || next.isEmpty) {
      throw HyroxWriteError('segment $currentIdx has no successor');
    }
    final a = current.single;
    final b = next.single;
    if (!a.isOpen) {
      throw HyroxWriteError('segment $currentIdx is not open');
    }
    if (b.startTs != null) {
      throw HyroxWriteError('segment ${currentIdx + 1} has already started');
    }
    if (a.startTs != null && transitionTs < a.startTs!) {
      throw HyroxWriteError('a transition cannot precede its segment');
    }
    await txn.update(
      'hyrox_segment',
      a.copyWith(endTs: transitionTs, boundarySource: boundarySource).toRow(),
      where: 'session_id = ? AND idx = ?',
      whereArgs: [sessionId, currentIdx],
    );
    await txn.update(
      'hyrox_segment',
      b.copyWith(startTs: transitionTs, boundarySource: boundarySource).toRow(),
      where: 'session_id = ? AND idx = ?',
      whereArgs: [sessionId, currentIdx + 1],
    );
    _validateTimeline(await segments(txn, sessionId));
    await _recomputeSessionBounds(txn, sessionId);
  }

  /// Derives the session bounds from its segments — one source of truth.
  ///
  /// With NO started segment both bounds are cleared, not kept at a stale
  /// value; a bound is written only when a segment actually supports it.
  /// [status] is left untouched unless the caller is changing the lifecycle.
  static Future<void> _recomputeSessionBounds(
    DatabaseExecutor db,
    String sessionId, {
    String? status,
  }) async {
    final segs = await segments(db, sessionId);
    int? start;
    int? end;
    for (final s in segs) {
      if (s.startTs != null && (start == null || s.startTs! < start)) {
        start = s.startTs;
      }
      if (s.endTs != null && (end == null || s.endTs! > end)) {
        end = s.endTs;
      }
    }
    final row = <String, Object?>{
      'start_ts': start,
      'end_ts': end,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (status != null) row['status'] = status;
    await db.update(
      'hyrox_session',
      row,
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  static Future<void> _requireWritable(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'hyrox_session',
      columns: ['finalized_at'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw HyroxWriteError('no such session: $id');
    if (rows.first['finalized_at'] != null) {
      throw HyroxWriteError('session $id is finalized and immutable');
    }
  }

  static Future<void> _touch(DatabaseExecutor db, String id) async {
    await db.update(
      'hyrox_session',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Fields that must hold for ANY segment row, planned or timed.
  static void _checkSegmentShape(HyroxSegment s) {
    if (s.distanceM == null && s.distanceSource != null) {
      throw HyroxWriteError('a distance source without a distance');
    }
    if (s.distanceM != null && (!s.distanceM!.isFinite || s.distanceM! < 0)) {
      throw HyroxWriteError('a measured distance is finite and not negative');
    }
    if (s.distanceM != null && s.distanceSource == null) {
      throw HyroxWriteError('a distance without a source');
    }
    if (s.startTs != null && s.endTs != null && s.endTs! < s.startTs!) {
      throw HyroxWriteError('segment ends before it starts');
    }
    if (!kHyroxBoundarySources.contains(s.boundarySource)) {
      throw HyroxWriteError('unknown boundary source ${s.boundarySource}');
    }
  }

  /// Neighbour rule for a single edit: the previous segment's end must not
  /// lie AFTER this segment's start (overlap), and this segment's end must
  /// not precede the next segment's start. Equal means a direct transition;
  /// a gap means a pause. Both are legal now.
  static void _checkNeighbour(HyroxSegment changed, HyroxSegment other) {
    if (other.idx == changed.idx - 1) {
      if (other.endTs != null &&
          changed.startTs != null &&
          other.endTs! > changed.startTs!) {
        throw HyroxWriteError(
          'segment ${changed.idx} starts before ${other.idx} ended',
        );
      }
    } else if (other.idx == changed.idx + 1) {
      if (changed.endTs != null &&
          other.startTs != null &&
          changed.endTs! > other.startTs!) {
        throw HyroxWriteError(
          'segment ${other.idx} starts before ${changed.idx} ended',
        );
      }
    }
  }
}
