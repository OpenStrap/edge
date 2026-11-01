// Triathlon / multisport storage — schema, row models and the CRUD seam.
//
// Parent/child on purpose. `triathlon_session` owns the frozen plan and the
// lifecycle; `triathlon_segment` owns the timed boundaries. A discipline
// segment ALSO gets a real `sessions` row (workout_id) from the live wiring,
// so routes, zones, splits and Health export keep their single existing code
// path; a transition (T1/T2) has no `sessions` row because it is not a sport.
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
//     its start, and neighbours meet at one instant: segment i's end IS segment
//     i+1's start. That is what a single "next" tap on the band means, and it
//     keeps total time equal to the sum of the splits by construction.
//
// Units follow the `sessions` table: segment boundaries are epoch SECONDS,
// bookkeeping stamps (created_at / updated_at / finalized_at) are epoch
// MILLISECONDS. Mixing them is the classic silent bug, so the row models name
// the unit in every field.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'triathlon_plan.dart';

/// schemaVersion 60. Parent before child on every create.
Future<void> createTriathlonTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS triathlon_session (
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
    'CREATE INDEX IF NOT EXISTS idx_triathlon_session_status '
    'ON triathlon_session(status)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_triathlon_session_start '
    'ON triathlon_session(start_ts)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS triathlon_segment (
      session_id TEXT NOT NULL,
      idx INTEGER NOT NULL,
      kind TEXT NOT NULL,
      environment TEXT,
      planned_distance_m REAL,
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
    'CREATE INDEX IF NOT EXISTS idx_triathlon_segment_workout '
    'ON triathlon_segment(workout_id)',
  );
}

/// How a segment boundary was established. `gesture` is a live band tap,
/// `phone` an on-screen button, `manual` a boundary the user moved afterwards,
/// `posthoc` a boundary reconstructed from band history or suggested by the
/// timeline — i.e. NOT a measurement of when the athlete actually changed
/// discipline, and therefore never to be presented as one. `unknown` is the
/// honest default for a row this build did not write.
const List<String> kTriBoundarySources = [
  'gesture',
  'phone',
  'manual',
  'posthoc',
  'unknown',
];

class TriSegment {
  const TriSegment({
    required this.sessionId,
    required this.idx,
    required this.kind,
    this.environment,
    this.plannedDistanceM,
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
  final TriSegmentKind kind;
  final TriEnvironment? environment;
  final double? plannedDistanceM;
  final int? goalSec;

  /// Epoch SECONDS. Null until the segment is entered / left.
  final int? startTs;
  final int? endTs;

  final String boundarySource;

  /// The linked `sessions.id` for a discipline segment, null for transitions
  /// and for a segment that has not been banked yet.
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

  bool get isTransition => kind.isTransition;
  bool get isOpen => startTs != null && endTs == null;

  /// Seconds in the segment, or null while it is still open. Zero-length
  /// segments are legal (an instant tap-through), negative ones are not.
  int? get durationSec =>
      startTs == null || endTs == null ? null : endTs! - startTs!;

  TriSegment copyWith({
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
    return TriSegment(
      sessionId: sessionId,
      idx: idx,
      kind: kind,
      environment: environment,
      plannedDistanceM: plannedDistanceM,
      goalSec: goalSec,
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
        'environment': environment?.key,
        'planned_distance_m': plannedDistanceM,
        'goal_sec': goalSec,
        'start_ts': startTs,
        'end_ts': endTs,
        'boundary_source': boundarySource,
        'workout_id': workoutId,
        'distance_m': distanceM,
        'distance_source': distanceSource,
        'hr_source': hrSource,
      };

  static TriSegment? fromRow(Map<String, Object?> r) {
    final kind = TriSegmentKindX.fromKey(r['kind'] as String?);
    if (kind == null) return null;
    return TriSegment(
      sessionId: r['session_id'] as String,
      idx: (r['idx'] as num).toInt(),
      kind: kind,
      environment: TriEnvironmentX.fromKey(r['environment'] as String?),
      plannedDistanceM: (r['planned_distance_m'] as num?)?.toDouble(),
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

class TriSession {
  const TriSession({
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
  final TriathlonPlan? plan;

  /// Epoch SECONDS, mirroring the first/last segment boundary.
  final int? startTs;
  final int? endTs;

  final String note;

  /// Epoch MILLISECONDS. Non-null makes the session and its segments read-only.
  final int? finalizedAt;

  /// Epoch MILLISECONDS.
  final int createdAt;
  final int updatedAt;

  final List<TriSegment> segments;

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

  /// Sum of closed segment durations = time actually in a discipline.
  /// Null when no segment is closed yet — a pause or an open tail is never
  /// billed as training.
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

  static TriSession fromRow(Map<String, Object?> r) {
    TriathlonPlan? plan;
    try {
      final decoded = jsonDecode(r['plan_json'] as String? ?? '{}');
      if (decoded is Map) {
        plan = TriathlonPlan.fromJson(decoded.cast<String, Object?>());
      }
    } on FormatException {
      plan = null;
    }
    return TriSession(
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

/// Thrown when a write targets a finalized session, or would make segments
/// overlap. Deliberately loud: a silent no-op here reads as "the race saved".
/// One boundary derived from the strap's stored taps (see the reconciler).
///
/// Lives in the data layer so storage never has to import a state-layer file:
/// the dependency runs one way, reconciler -> store.
class ReconcileBoundary {
  const ReconcileBoundary(this.atSec, this.taps, this.kind);

  /// Strap time of the FIRST tap of the accepted cluster.
  final int atSec;
  final int taps;

  /// The segment the cluster closes; its successor starts at [atSec].
  final TriSegmentKind kind;

  @override
  String toString() => 'ReconcileBoundary($kind @$atSec, $taps taps)';
}

class TriathlonWriteError implements Exception {
  TriathlonWriteError(this.message);
  final String message;
  @override
  String toString() => 'TriathlonWriteError: $message';
}

class TriathlonDb {
  TriathlonDb._();

  /// Persist a new ARMED session with its planned segments in one transaction.
  /// Nothing here starts a clock: arming is a choice, not a measurement.
  static Future<void> create(Database db, TriSession session) async {
    final plan0 = session.plan;
    if (plan0 == null) throw TriathlonWriteError('a session needs a readable plan');
    final problem = plan0.validate();
    if (problem != null) throw TriathlonWriteError(problem);
    if (session.status != 'armed') {
      throw TriathlonWriteError('a new session is created armed, not ${session.status}');
    }
    if (session.isFinalized || session.startTs != null || session.endTs != null) {
      throw TriathlonWriteError('create cannot pre-fill session bounds');
    }
    if (session.segments.isNotEmpty &&
        session.segments.length != session.plan!.segments.length) {
      throw TriathlonWriteError('segment rows do not match the plan');
    }
    await db.transaction((txn) async {
      final clash = await txn.query(
        'triathlon_session',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [session.id],
        limit: 1,
      );
      if (clash.isNotEmpty) {
        throw TriathlonWriteError('session ${session.id} already exists');
      }
      await txn.insert('triathlon_session', session.toRow());
      final plan = session.plan!;
      for (var i = 0; i < plan.segments.length; i++) {
        final p = plan.segments[i];
        final supplied = i < session.segments.length ? session.segments[i] : null;
        final seg = supplied ??
            TriSegment(
              sessionId: session.id,
              idx: i,
              kind: p.kind,
              environment: p.environment,
              plannedDistanceM: p.plannedDistanceM,
              goalSec: p.goalSec,
            );
        if (seg.sessionId != session.id || seg.idx != i || seg.kind != p.kind ||
            seg.environment != p.environment ||
            seg.plannedDistanceM != p.plannedDistanceM || seg.goalSec != p.goalSec) {
          throw TriathlonWriteError('segment $i does not match the plan');
        }
        if (seg.startTs != null ||
            seg.endTs != null ||
            seg.workoutId != null ||
            seg.distanceM != null ||
            seg.distanceSource != null) {
          throw TriathlonWriteError(
            'create stores a plan; segment $i already carries history',
          );
        }
        _checkSegmentShape(seg);
        if (i > 0 && session.segments.isNotEmpty) {
          _checkNeighbour(seg, session.segments[i - 1]);
        }
        await txn.insert('triathlon_segment', seg.toRow());
      }
    });
  }

  static Future<TriSession?> byId(Database db, String id) async {
    final rows = await db.query(
      'triathlon_session',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _withSegments(db, TriSession.fromRow(rows.first));
  }

  static Future<List<TriSegment>> segments(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'triathlon_segment',
      where: 'session_id = ?',
      whereArgs: [id],
      orderBy: 'idx ASC',
    );
    return [for (final r in rows) TriSegment.fromRow(r)].whereType<TriSegment>().toList();
  }

  static Future<TriSession> _withSegments(Database db, TriSession s) async {
    final segs = await segments(db, s.id);
    return TriSession(
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
  static Future<TriSession?> activeSession(Database db) async {
    final rows = await db.query(
      'triathlon_session',
      where: "finalized_at IS NULL AND status != 'discarded'",
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _withSegments(db, TriSession.fromRow(rows.first));
  }

  /// Finalized sessions at [preset], newest first — the comparison set for
  /// "total time vs your previous races at this distance".
  static Future<List<TriSession>> finalized(
    Database db, {
    String? preset,
    int limit = 50,
  }) async {
    final rows = await db.query(
      'triathlon_session',
      where: preset == null ? 'finalized_at IS NOT NULL' : 'finalized_at IS NOT NULL AND preset = ?',
      whereArgs: preset == null ? null : [preset],
      orderBy: 'start_ts DESC',
      limit: limit,
    );
    final out = <TriSession>[];
    for (final r in rows) {
      out.add(await _withSegments(db, TriSession.fromRow(r)));
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
  static Future<void> saveSegment(Database db, TriSegment segment) async {
    _checkSegmentShape(segment);
    await db.transaction((txn) async {
      await _requireWritable(txn, segment.sessionId);
      final existing = await segments(txn, segment.sessionId);
      final matching = existing.where((s) => s.idx == segment.idx).toList();
      if (matching.isEmpty) {
        throw TriathlonWriteError('segment ${segment.idx} is not in the plan');
      }
      final original = matching.single;
      if (segment.kind != original.kind ||
          segment.environment != original.environment ||
          segment.plannedDistanceM != original.plannedDistanceM ||
          segment.goalSec != original.goalSec) {
        throw TriathlonWriteError('the planned segment is immutable');
      }
      for (final other in existing) {
        if (other.idx != segment.idx) _checkNeighbour(segment, other);
      }
      await txn.update(
        'triathlon_segment',
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
    if (ts <= 0) throw TriathlonWriteError('a start needs a real timestamp');
    _checkBoundarySource(boundarySource);
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      final segs = await segments(txn, sessionId);
      if (segs.isEmpty) throw TriathlonWriteError('the plan has no segments');
      if (segs.any((s) => s.startTs != null || s.endTs != null)) {
        throw TriathlonWriteError('the session has already started');
      }
      await txn.update(
        'triathlon_segment',
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
  /// A DNF needs an explicit model (skipped markers), not a silent half-race.
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
        throw TriathlonWriteError('exactly one segment must be open to finish');
      }
      final last = open.single;
      if (last.startTs == null || ts < last.startTs!) {
        throw TriathlonWriteError('a segment cannot end before it starts');
      }
      if (last.idx != segs.length - 1) {
        throw TriathlonWriteError(
          'finish closes the final segment; close segment ${last.idx} with a '
          'transition instead',
        );
      }
      await txn.update(
        'triathlon_segment',
        last.copyWith(endTs: ts, boundarySource: boundarySource).toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, last.idx],
      );
      _validateTimeline(await segments(txn, sessionId));
      await _recomputeSessionBounds(txn, sessionId, status: 'finished');
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
        throw TriathlonWriteError('there is no boundary after segment $idx');
      }
      final left = segs.firstWhere((s) => s.idx == idx);
      final right = segs.firstWhere((s) => s.idx == idx + 1);
      final wasStart = right.startTs;
      final wasEnd = left.endTs;
      if (wasStart == null || wasEnd == null || wasStart != wasEnd) {
        throw TriathlonWriteError('segments $idx and ${idx + 1} do not meet');
      }
      if (left.startTs != null && newTs < left.startTs!) {
        throw TriathlonWriteError('the boundary would precede segment $idx');
      }
      if (right.endTs != null && newTs > right.endTs!) {
        throw TriathlonWriteError('the boundary would follow segment ${idx + 1}');
      }
      // Provenance follows the actor: a boundary moved by hand is 'manual' on
      // both rows. Keeping 'gesture' here would claim the band recorded a time
      // the athlete actually corrected.
      await txn.update(
        'triathlon_segment',
        left.copyWith(endTs: newTs, boundarySource: 'manual').toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx],
      );
      await txn.update(
        'triathlon_segment',
        right.copyWith(startTs: newTs, boundarySource: 'manual').toRow(),
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
    if (segs.isEmpty) throw TriathlonWriteError('the plan has no segments');
    for (var i = 0; i < boundaries.length; i++) {
      final b = boundaries[i];
      _checkBoundarySource('posthoc');
      segs = await segments(txn, sessionId);
      final open = segs.where((s) => s.isOpen).toList();
      if (open.isEmpty) {
        // Nothing running: this boundary STARTS the race, and only as the
        // first one. Anything later is a log we cannot place.
        if (i != 0 ||
            segs.any((s) => s.startTs != null) ||
            b.kind != segs.first.kind) {
          throw TriathlonWriteError('no open segment to close at ${b.atSec}');
        }
        await txn.update(
          'triathlon_segment',
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
        throw TriathlonWriteError('more than one open segment');
      }
      final current = open.single;
      if (b.kind != current.kind) {
        throw TriathlonWriteError('boundary does not close the open segment');
      }
      final hasNext = current.idx + 1 < segs.length;
      if (!hasNext) {
        // Closing the final segment ends the race, so nothing may follow it.
        if (i != boundaries.length - 1) {
          throw TriathlonWriteError('boundaries follow the final segment');
        }
        if (current.startTs == null || b.atSec < current.startTs!) {
          throw TriathlonWriteError(
            'the final segment would end before it started',
          );
        }
        await txn.update(
          'triathlon_segment',
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

  /// Link a discipline segment to the `sessions` row the live workout banked.
  static Future<void> linkWorkout(
    Database db,
    String sessionId,
    int idx,
    String workoutId,
  ) async {
    if (workoutId.trim().isEmpty) {
      throw TriathlonWriteError('a workout link needs a workout id');
    }
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      final rows = await txn.query(
        'triathlon_segment',
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw TriathlonWriteError('segment $idx is not in session $sessionId');
      }
      final seg = TriSegment.fromRow(rows.first);
      if (seg.isTransition) {
        throw TriathlonWriteError(
          'a transition has no workout row to link',
        );
      }
      final existing = await txn.query(
        'triathlon_segment',
        columns: ['session_id', 'idx'],
        where: 'workout_id = ? AND NOT (session_id = ? AND idx = ?)',
        whereArgs: [workoutId, sessionId, idx],
      );
      if (existing.isNotEmpty) {
        throw TriathlonWriteError('workout $workoutId is already linked');
      }
      final updated = await txn.update(
        'triathlon_segment',
        {'workout_id': workoutId},
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx],
      );
      if (updated != 1) {
        throw TriathlonWriteError('workout link matched no segment row');
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
  static Future<void> updateSession(Database db, TriSession session) async {
    await db.transaction((txn) async {
      await _requireWritable(txn, session.id);
      if (session.isFinalized || session.status == 'finalized') {
        throw TriathlonWriteError('use finalize to finalize a session');
      }
      const writable = {'armed', 'active', 'discarded', 'abandoned'};
      if (!writable.contains(session.status)) {
        throw TriathlonWriteError(
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
        'triathlon_session',
        row,
        where: 'id = ?',
        whereArgs: [session.id],
      );
    });
  }

  /// Stamp finalization. Every segment must be CLOSED, otherwise the saved
  /// record would contain a split with no end — an open segment is a live
  /// session, and finalizing it would freeze a lie.
  static Future<void> finalize(Database db, String id) async {
    await db.transaction((txn) async {
      await _requireWritable(txn, id);
      final rows = await txn.query(
        'triathlon_session',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw TriathlonWriteError('no such session: $id');
      final status = rows.first['status'] as String;
      if (status != 'finished' && status != 'abandoned') {
        throw TriathlonWriteError(
          'only a finished or abandoned session can be finalized',
        );
      }
      final segs = await segments(txn, id);
      if (segs.isEmpty) throw TriathlonWriteError('nothing to finalize');
      if (status == 'finished') {
        for (final s in segs) {
          if (s.startTs == null || s.endTs == null) {
            throw TriathlonWriteError('segment ${s.idx} is still open');
          }
        }
      } else {
        // ABANDONED (DNF): exactly one segment may be open — the discipline
        // the athlete stopped in. Its duration stays null; nothing is
        // invented. Every segment before it must be closed, every segment
        // after it must be untouched, and at least one segment must have
        // started (otherwise this is a discard, not a race).
        final open = segs.where((s) => s.isOpen).toList();
        final started = segs.where((s) => s.startTs != null).length;
        if (started == 0) {
          throw TriathlonWriteError(
            'nothing started — discard the session instead of finalizing',
          );
        }
        if (open.length > 1) {
          throw TriathlonWriteError('more than one open segment');
        }
        if (open.isNotEmpty) {
          final cut = open.single;
          if (segs.where((s) => s.idx < cut.idx && s.endTs == null).isNotEmpty) {
            throw TriathlonWriteError('an earlier segment is still open');
          }
          if (segs.where((s) => s.idx > cut.idx && s.startTs != null).isNotEmpty) {
            throw TriathlonWriteError('a later segment already started');
          }
        }
      }
      _validateTimeline(segs);
      await txn.update(
        'triathlon_session',
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
        'triathlon_segment',
        columns: ['workout_id'],
        where: 'session_id = ?',
        whereArgs: [id],
      );
      final workoutIds = [
        for (final r in segs)
          if (r['workout_id'] is String) r['workout_id'] as String,
      ];
      await txn.delete(
        'triathlon_segment',
        where: 'session_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'triathlon_session',
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
  /// PAUSE, not a gap in the data: a workout can be interrupted for hours
  /// between disciplines, and a missed transition tap looks exactly like
  /// that. The session then reports total and moving time separately, so a
  /// pause is never silently billed as training time.
  static void _validateTimeline(List<TriSegment> segs) {
    var seenUnstarted = false;
    var open = 0;
    int? prevEnd;
    for (final s in segs) {
      final started = s.startTs != null;
      final ended = s.endTs != null;
      if (!started) {
        seenUnstarted = true;
        if (ended) {
          throw TriathlonWriteError('segment ${s.idx} ends before it starts');
        }
        continue;
      }
      if (seenUnstarted) {
        throw TriathlonWriteError(
          'segment ${s.idx} starts while an earlier segment never did',
        );
      }
      if (ended && s.endTs! < s.startTs!) {
        throw TriathlonWriteError('segment ${s.idx} ends before it starts');
      }
      if (prevEnd != null) {
        if (s.startTs! < prevEnd) {
          throw TriathlonWriteError(
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
          throw TriathlonWriteError('more than one segment is open');
        }
        for (final later in segs) {
          if (later.idx > s.idx && later.startTs != null) {
            throw TriathlonWriteError(
              'segment ${later.idx} starts while ${s.idx} is open',
            );
          }
        }
        prevEnd = null;
      }
    }
  }

  static void _checkBoundarySource(String source) {
    if (!kTriBoundarySources.contains(source)) {
      throw TriathlonWriteError('unknown boundary source $source');
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
      throw TriathlonWriteError('segment $currentIdx has no successor');
    }
    final a = current.single;
    final b = next.single;
    if (!a.isOpen) {
      throw TriathlonWriteError('segment $currentIdx is not open');
    }
    if (b.startTs != null) {
      throw TriathlonWriteError('segment ${currentIdx + 1} has already started');
    }
    if (a.startTs != null && transitionTs < a.startTs!) {
      throw TriathlonWriteError('a transition cannot precede its segment');
    }
    await txn.update(
      'triathlon_segment',
      a.copyWith(endTs: transitionTs, boundarySource: boundarySource).toRow(),
      where: 'session_id = ? AND idx = ?',
      whereArgs: [sessionId, currentIdx],
    );
    await txn.update(
      'triathlon_segment',
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
      if (status != null) 'status': status,
    };
    await db.update(
      'triathlon_session',
      row,
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  static Future<void> _requireWritable(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'triathlon_session',
      columns: ['finalized_at'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw TriathlonWriteError('no such session: $id');
    if (rows.first['finalized_at'] != null) {
      throw TriathlonWriteError('session $id is finalized and immutable');
    }
  }

  static Future<void> _touch(DatabaseExecutor db, String id) async {
    await db.update(
      'triathlon_session',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Fields that must hold for ANY segment row, planned or timed.
  static void _checkSegmentShape(TriSegment s) {
    if (s.isTransition &&
        (s.environment != null || s.plannedDistanceM != null)) {
      throw TriathlonWriteError('a transition has no environment or distance');
    }
    if (s.distanceM == null && s.distanceSource != null) {
      throw TriathlonWriteError('a distance source without a distance');
    }
    if (s.distanceM != null && (!s.distanceM!.isFinite || s.distanceM! < 0)) {
      throw TriathlonWriteError('a measured distance is finite and not negative');
    }
    if (s.distanceM != null && s.distanceSource == null) {
      throw TriathlonWriteError('a distance without a source');
    }
    if (s.startTs != null && s.endTs != null && s.endTs! < s.startTs!) {
      throw TriathlonWriteError('segment ends before it starts');
    }
    if (!kTriBoundarySources.contains(s.boundarySource)) {
      throw TriathlonWriteError('unknown boundary source ${s.boundarySource}');
    }
  }

  /// Neighbours share one instant: the earlier segment's end is the later
  /// segment's start. Anything else is either a gap or an overlap, and both
  /// would make the splits stop adding up to the total.
  /// Neighbour rule for a single edit: the previous segment's end must not
  /// lie AFTER this segment's start (overlap), and this segment's end must
  /// not precede the next segment's start. Equal means a direct transition;
  /// a gap means a pause. Both are legal now.
  static void _checkNeighbour(TriSegment changed, TriSegment other) {
    if (other.idx == changed.idx - 1) {
      if (other.endTs != null &&
          changed.startTs != null &&
          other.endTs! > changed.startTs!) {
        throw TriathlonWriteError(
          'segment ${changed.idx} starts before ${other.idx} ended',
        );
      }
    } else if (other.idx == changed.idx + 1) {
      if (changed.endTs != null &&
          other.startTs != null &&
          changed.endTs! > other.startTs!) {
        throw TriathlonWriteError(
          'segment ${other.idx} starts before ${changed.idx} ended',
        );
      }
    }
  }
}
