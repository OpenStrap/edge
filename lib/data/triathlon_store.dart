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
//     later write to that session or its segments throws. A race that has been
//     saved is a record, and a screen must not be able to quietly rewrite it.
//     Boundary corrections belong to the not-yet-finalized session, and a
//     future "re-derive" flow gets a NEW row, exactly like `day_result`'s
//     immutable-per-version rule.
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
  }) {
    return TriSegment(
      sessionId: sessionId,
      idx: idx,
      kind: kind,
      environment: environment,
      plannedDistanceM: plannedDistanceM,
      goalSec: goalSec,
      startTs: startTs ?? this.startTs,
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

  static TriSession? fromRow(Map<String, Object?> r) {
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
    if (session.isFinalized) {
      throw TriathlonWriteError('cannot create an already-finalized session');
    }
    if (session.segments.isNotEmpty &&
        session.segments.length != session.plan!.segments.length) {
      throw TriathlonWriteError('segment rows do not match the plan');
    }
    await db.transaction((txn) async {
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
        if (seg.idx != i || seg.kind != p.kind) {
          throw TriathlonWriteError('segment $i does not match the plan');
        }
        _checkSegmentShape(seg);
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
    final session = TriSession.fromRow(rows.first);
    if (session == null) return null;
    return _withSegments(db, session);
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
    final session = TriSession.fromRow(rows.first);
    if (session == null) return null;
    return _withSegments(db, session);
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
      final s = TriSession.fromRow(r);
      if (s != null) out.add(await _withSegments(db, s));
    }
    return out;
  }

  /// Write one segment's boundaries. The whole point of doing this here rather
  /// than in the UI: the neighbour rows are read INSIDE the same transaction,
  /// so the no-overlap rule cannot be checked against a stale in-memory copy.
  static Future<void> saveSegment(Database db, TriSegment segment) async {
    _checkSegmentShape(segment);
    await db.transaction((txn) async {
      await _requireWritable(txn, segment.sessionId);
      final rows = await txn.query(
        'triathlon_segment',
        where: 'session_id = ?',
        whereArgs: [segment.sessionId],
        orderBy: 'idx ASC',
      );
      final existing = [
        for (final r in rows) TriSegment.fromRow(r)
      ].whereType<TriSegment>().toList();
      if (existing.every((s) => s.idx != segment.idx)) {
        throw TriathlonWriteError('segment ${segment.idx} is not in the plan');
      }
      for (final other in existing) {
        if (other.idx == segment.idx) continue;
        _checkNeighbour(segment, other);
      }
      await txn.update(
        'triathlon_segment',
        segment.toRow(),
        where: 'session_id = ? AND idx = ?',
        whereArgs: [segment.sessionId, segment.idx],
      );
      await _touch(txn, segment.sessionId);
    });
  }

  /// Link a discipline segment to the `sessions` row the live workout banked.
  static Future<void> linkWorkout(
    Database db,
    String sessionId,
    int idx,
    String workoutId,
  ) async {
    await db.transaction((txn) async {
      await _requireWritable(txn, sessionId);
      await txn.update(
        'triathlon_segment',
        {'workout_id': workoutId},
        where: 'session_id = ? AND idx = ?',
        whereArgs: [sessionId, idx],
      );
      await _touch(txn, sessionId);
    });
  }

  /// Status / session-level bounds / notes. Refuses a finalized row, and never
  /// clears `finalized_at` — finalization is one-way by design.
  static Future<void> updateSession(Database db, TriSession session) async {
    await db.transaction((txn) async {
      await _requireWritable(txn, session.id);
      final row = session.toRow();
      row['updated_at'] = DateTime.now().millisecondsSinceEpoch;
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
      final segs = await segments(db, id);
      if (segs.isEmpty) throw TriathlonWriteError('nothing to finalize');
      for (final s in segs) {
        if (s.startTs == null || s.endTs == null) {
          throw TriathlonWriteError('segment ${s.idx} is still open');
        }
      }
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
  static void _checkNeighbour(TriSegment changed, TriSegment other) {
    if (other.idx == changed.idx - 1) {
      // [other] is the previous segment.
      if (other.endTs != null &&
          changed.startTs != null &&
          other.endTs != changed.startTs) {
        throw TriathlonWriteError(
          'segment ${changed.idx} does not start where ${other.idx} ended',
        );
      }
    } else if (other.idx == changed.idx + 1) {
      if (changed.endTs != null &&
          other.startTs != null &&
          changed.endTs != other.startTs) {
        throw TriathlonWriteError(
          'segment ${other.idx} does not start where ${changed.idx} ended',
        );
      }
    }
  }
}
