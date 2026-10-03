import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../compute/manual_session.dart';
import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../compute/nap_edits.dart';
import '../models/activity_suggestion.dart';
import 'day_label.dart';

/// The single persistence seam for proposals and review decisions. Computing a
/// proposal never writes a session or credits sleep. All actions are atomic.
class ActivityStore {
  ActivityStore(this.db);
  final Database db;

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS activity_suggestions (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, day_id TEXT NOT NULL,
      start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL,
      detection_start INTEGER NOT NULL, detection_end INTEGER NOT NULL,
      details_json TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
      revision INTEGER NOT NULL DEFAULT 0, linked_id TEXT,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS activity_pending '
      'ON activity_suggestions(status, start_ts)',
    );
    await db.execute('''CREATE TABLE IF NOT EXISTS activity_review_meta (
      id INTEGER PRIMARY KEY CHECK(id = 1), activated_at INTEGER NOT NULL,
      revision INTEGER NOT NULL DEFAULT 0, legacy_migrated INTEGER NOT NULL DEFAULT 0,
      alert_after_ts INTEGER NOT NULL DEFAULT 0
    )''');
    final metaCols = await db.rawQuery(
      'PRAGMA table_info(activity_review_meta)',
    );
    if (!metaCols.any((r) => r['name'] == 'alert_after_ts')) {
      await db.execute(
        'ALTER TABLE activity_review_meta ADD COLUMN alert_after_ts INTEGER NOT NULL DEFAULT 0',
      );
    }
    await _ensureMeta(db);
    await db.execute('''CREATE TABLE IF NOT EXISTS activity_review_days (
      day_id TEXT PRIMARY KEY, revision INTEGER NOT NULL
    )''');
    final cols = await db.rawQuery('PRAGMA table_info(sleep_nap)');
    if (cols.isNotEmpty && !cols.any((r) => r['name'] == 'payload_json')) {
      await db.execute('ALTER TABLE sleep_nap ADD COLUMN payload_json TEXT');
    }
  }

  static Future<void> _ensureMeta(DatabaseExecutor tx) async {
    await tx.insert('activity_review_meta', {
      'id': 1,
      'activated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Small, resumable legacy transfer outside the schema upgrade transaction.
  Future<void> migrateLegacy() async {
    await _ensureMeta(db);
    while (true) {
      final finished = await db.transaction((tx) async {
        final meta = (await tx.query('activity_review_meta')).single;
        if (meta['legacy_migrated'] == 1) return true;
        final rows = await tx.rawQuery('''SELECT w.* FROM workout_suggestions w
          WHERE NOT EXISTS (SELECT 1 FROM activity_suggestions a WHERE a.id=w.id)
          ORDER BY w.created_at, w.id LIMIT 100''');
        for (final row in rows) {
          final s = row['start_ts'] as int, e = row['end_ts'] as int;
          final saved = await _overlappingSessions(tx, s, e);
          await tx.insert('activity_suggestions', {
            'id': row['id'],
            'kind': 'workout',
            'day_id': row['date'],
            'start_ts': s,
            'end_ts': e,
            'detection_start': s,
            'detection_end': e,
            'details_json': jsonEncode(row),
            'status': e <= s || saved.isNotEmpty
                ? 'superseded'
                : row['dismissed'] == 1
                ? 'discarded'
                : 'pending',
            'created_at': row['created_at'],
            'updated_at': row['created_at'],
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        if (rows.length < 100) {
          await tx.update('activity_review_meta', {'legacy_migrated': 1});
          return true;
        }
        return false;
      });
      if (finished) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<List<ActivitySuggestion>> pending() async {
    await migrateLegacy();
    return [
      for (final r in await db.query(
        'activity_suggestions',
        where: "status = 'pending'",
        orderBy: 'start_ts DESC, id ASC',
      ))
        ActivitySuggestion.fromRow(r),
    ];
  }

  Future<int> pendingCount() async {
    await migrateLegacy();
    return Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM activity_suggestions WHERE status = 'pending'",
          ),
        ) ??
        0;
  }

  Future<ActivitySuggestion?> get(String id) async {
    final rows = await db.query(
      'activity_suggestions',
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : ActivitySuggestion.fromRow(rows.single);
  }

  /// A later normal derive can encounter rows restored by an import. Those
  /// detections still belong in the list, but must not alert about the import.
  static Future<void> suppressImportedAlerts(DatabaseExecutor tx) async {
    await _ensureMeta(tx);
    await tx.update('activity_review_meta', {
      'alert_after_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  Future<bool> mayNotifyNew(ActivitySuggestion suggestion, {int? nowTs}) async {
    final age =
        (nowTs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000) -
        suggestion.endTs;
    if (age < 0 || age >= 2 * 3600) return false;
    final meta = (await db.query('activity_review_meta')).single;
    if (suggestion.endTs <= (meta['alert_after_ts'] as int)) return false;
    return (await get(suggestion.id))?.status == ActivityReviewStatus.pending;
  }

  /// Returns only genuinely NEW pending proposals, for one-time notification.
  Future<List<ActivitySuggestion>> reconcile(
    ActivityKind kind,
    List<Map<String, dynamic>> candidates,
  ) async {
    await migrateLegacy();
    return db.transaction((tx) async {
      final cutoff =
          (await tx.query('activity_review_meta')).single['activated_at']
              as int;
      final created = <ActivitySuggestion>[];
      for (final c in candidates) {
        final start = ((c['start_ts'] ?? c['start']) as num).toInt();
        final end = ((c['end_ts'] ?? c['end']) as num).toInt();
        if (end <= start) continue;
        final matches = await tx.query(
          'activity_suggestions',
          where:
              "kind = ? AND detection_start < ? AND detection_end > ? "
              "AND NOT (status = 'superseded' AND linked_id IS NOT NULL)",
          whereArgs: [kind.name, end, start],
          orderBy: 'created_at ASC, id ASC',
        );
        // A decided interval wins over every re-detection, including a merger
        // that now covers both a decided and a still-pending fragment.
        final decided = matches.where((m) => m['status'] != 'pending').toList();
        final saved = await _overlapsSleep(tx, start, end);
        if (decided.isNotEmpty || saved) {
          for (final m in matches) {
            await tx.update(
              'activity_suggestions',
              {
                'detection_start': math.min(m['detection_start'] as int, start),
                'detection_end': math.max(m['detection_end'] as int, end),
                if (m['status'] == 'pending') 'status': 'superseded',
              },
              where: 'id = ?',
              whereArgs: [m['id']],
            );
          }
          continue;
        }
        if (matches.isEmpty && start < cutoff) continue;
        final now = DateTime.now().millisecondsSinceEpoch;
        final id = matches.isEmpty
            ? (c['id'] as String? ?? '${kind.name}:$start')
            : matches.first['id'] as String;
        final details = jsonEncode(c);
        if (matches.isEmpty) {
          final row = <String, dynamic>{
            'id': id,
            'kind': kind.name,
            'day_id': dayLabelOf(
              DateTime.fromMillisecondsSinceEpoch(start * 1000),
            ),
            'start_ts': start,
            'end_ts': end,
            'detection_start': start,
            'detection_end': end,
            'details_json': details,
            'status': 'pending',
            'revision': 0,
            'created_at': now,
            'updated_at': now,
          };
          await tx.insert('activity_suggestions', row);
          created.add(ActivitySuggestion.fromRow(row));
        } else {
          final first = matches.first;
          final changed =
              first['start_ts'] != start ||
              first['end_ts'] != end ||
              first['details_json'] != details;
          await tx.update(
            'activity_suggestions',
            {
              'start_ts': start,
              'end_ts': end,
              'day_id': dayLabelOf(
                DateTime.fromMillisecondsSinceEpoch(start * 1000),
              ),
              'details_json': details,
              'detection_start': matches.fold<int>(
                start,
                (int a, m) => math.min(a, m['detection_start'] as int),
              ),
              'detection_end': matches.fold<int>(
                end,
                (int a, m) => math.max(a, m['detection_end'] as int),
              ),
              'revision': (first['revision'] as int) + (changed ? 1 : 0),
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          for (final duplicate in matches.skip(1)) {
            await tx.update(
              'activity_suggestions',
              {'status': 'superseded', 'linked_id': id},
              where: 'id = ?',
              whereArgs: [duplicate['id']],
            );
          }
        }
      }
      return created;
    });
  }

  static Future<List<Map<String, dynamic>>> _overlappingSessions(
    DatabaseExecutor tx,
    int s,
    int e,
  ) => tx.query(
    'sessions',
    where: 'start_ts < ? AND COALESCE(end_ts, ?) > ?',
    whereArgs: [e, DateTime.now().millisecondsSinceEpoch ~/ 1000, s],
  );

  static Future<bool> _overlapsSleep(DatabaseExecutor tx, int s, int e) async {
    final naps = await tx.query(
      'sleep_nap',
      where: "source != 'rejected' AND start_ts < ? AND end_ts > ?",
      whereArgs: [e, s],
    );
    if (naps.isNotEmpty) return true;
    final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(s * 1000));
    final end = DateTime.fromMillisecondsSinceEpoch(e * 1000);
    // An evening interval can overlap the main sleep owned by tomorrow's
    // wake date. Walk calendar dates rather than adding a fixed 24 hours.
    final next = dayLabelOf(DateTime(end.year, end.month, end.day + 1));
    final nights = await tx.rawQuery(
      '''SELECT d.* FROM day_result d
      WHERE d.day_id BETWEEN ? AND ? AND d.algo_version =
        (SELECT MAX(r.algo_version) FROM day_result r WHERE r.day_id = d.day_id AND r.algo_version <= ?)''',
      [day, next, kAlgoVersion],
    );
    for (final r in nights) {
      final b = jsonDecode(r['payload_json'] as String) as Map;
      // Before its first recompute, a pre-upgrade nap still lives only in the
      // day bundle. It is already logged and takes precedence just as a nap
      // that has been copied into the accepted-record table does.
      final legacy = (b['naps'] as Map?)?['value'];
      if (legacy is List) {
        for (final nap in legacy.whereType<Map>()) {
          final ns = nap['start'] as num?, ne = nap['end'] as num?;
          if (ns != null && ne != null && s < ne && e > ns) return true;
        }
      }
      final value = ((b['sleep'] as Map?)?['window'] as Map?)?['value'];
      // Absent metric envelopes store '—', not a window object.
      final w = value is Map ? value : null;
      final ns = w?['onset_ms'] as num?, ne = w?['offset_ms'] as num?;
      if (ns != null && ne != null && s * 1000 < ne && e * 1000 > ns) {
        return true;
      }
    }
    return (await _overlappingSessions(tx, s, e)).isNotEmpty;
  }

  static Future<void> supersedeWorkouts(
    DatabaseExecutor tx,
    int s,
    int e,
  ) async {
    await tx.rawUpdate(
      "UPDATE activity_suggestions SET status = 'superseded' "
      "WHERE kind = 'workout' AND status = 'pending' AND start_ts < ? AND end_ts > ?",
      [e, s],
    );
  }

  Future<void> discard(ActivitySuggestion expected) =>
      db.transaction((tx) async {
        final row = await _check(tx, expected);
        if (row == null) return;
        await tx.update(
          'activity_suggestions',
          {
            'status': 'discarded',
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [expected.id],
        );
        await _changed(tx, row['day_id'] as String);
      });

  static Future<Map<String, dynamic>?> _check(
    DatabaseExecutor tx,
    ActivitySuggestion expected,
  ) async {
    final rows = await tx.query(
      'activity_suggestions',
      where: 'id = ?',
      whereArgs: [expected.id],
    );
    if (rows.isEmpty) {
      throw const ActivityReviewException(
        'This suggestion is no longer available.',
      );
    }
    final row = rows.single;
    if (row['status'] != 'pending') return null;
    if (row['revision'] != expected.revision) {
      throw const ActivityReviewException(
        'This suggestion changed as more data arrived. Review its updated times and try again.',
      );
    }
    return row;
  }

  Future<void> confirm(
    ActivitySuggestion expected, {
    required int startTs,
    required int endTs,
    Map<String, dynamic>? session,
    bool edited = false,
  }) => db.transaction((tx) async {
    final row = await _check(tx, expected);
    if (row == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (endTs > now ~/ 1000) {
      throw const ActivityReviewException('The end time is in the future.');
    }
    final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(startTs * 1000));
    String linked;
    if (expected.kind == ActivityKind.workout) {
      final overlap = await _overlappingSessions(tx, startTs, endTs);
      final invalid = validateManualWindow(
        startSec: startTs,
        endSec: endTs,
        nowSec: now ~/ 1000,
        existing: [
          for (final r in overlap)
            SessionSpan(
              r['id'] as String,
              r['start_ts'] as int,
              (r['end_ts'] as int?) ?? now ~/ 1000,
            ),
        ],
      );
      if (invalid != null) throw ManualWindowException(invalid);
      if (await _overlapsSleep(tx, startTs, endTs)) {
        throw const ActivityReviewException(
          'That overlaps sleep already in your history.',
        );
      }
      if (session == null) {
        throw StateError('Workout must be scored before commit');
      }
      linked = session['id'] as String;
      await tx.insert('sessions', session);
      await supersedeWorkouts(tx, startTs, endTs);
    } else {
      if (!manualNapWindowIsValid(startTs, endTs)) {
        throw const ActivityReviewException(
          'A nap must last between 5 minutes and 6 hours.',
        );
      }
      if (await _overlapsSleep(tx, startTs, endTs)) {
        throw const ActivityReviewException(
          'That overlaps sleep or a workout already in your history.',
        );
      }
      linked = '$day:$startTs';
      await tx.insert('sleep_nap', {
        'day_id': day,
        'start_ts': startTs,
        'end_ts': endTs,
        'source': edited ? 'manual' : 'confirmed',
        'created_at': now ~/ 1000,
        'payload_json': edited
            ? null
            : jsonEncode({
                ...expected.details,
                'start': startTs,
                'end': endTs,
                'source': 'confirmed',
              }),
      });
      await _changed(tx, day);
    }
    await tx.update(
      'activity_suggestions',
      {'status': 'confirmed', 'linked_id': linked, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [expected.id],
    );
    await _changed(tx, row['day_id'] as String);
  });

  static Future<void> _changed(DatabaseExecutor tx, String day) async {
    await _ensureMeta(tx);
    await tx.rawUpdate(
      'UPDATE activity_review_meta SET revision = revision + 1',
    );
    final rev = (await tx.query('activity_review_meta')).single['revision'];
    await tx.insert('activity_review_days', {
      'day_id': day,
      'revision': rev,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> markDayChanged(DatabaseExecutor tx, String day) =>
      _changed(tx, day);

  /// Capture only previously LOGGED pre-upgrade naps, never newly detected old
  /// history. Called before replacing a day's result, outside the migration.
  static Future<void> preserveLegacyNaps(
    DatabaseExecutor tx,
    String day,
    Map<String, dynamic> bundle,
  ) async {
    await _ensureMeta(tx);
    final cutoff =
        (await tx.query('activity_review_meta')).single['activated_at'] as int;
    final naps = (bundle['naps'] as Map?)?['value'];
    if (naps is! List) return;
    for (final n in naps.whereType<Map>()) {
      final s = (n['start'] as num?)?.toInt(), e = (n['end'] as num?)?.toInt();
      if (s == null ||
          e == null ||
          s >= cutoff ||
          e <= s ||
          n['source'] == 'manual' ||
          n['source'] == 'confirmed') {
        continue;
      }
      if ((await tx.query(
        'sleep_nap',
        where: 'start_ts < ? AND end_ts > ?',
        whereArgs: [e, s],
      )).isNotEmpty) {
        continue;
      }
      await tx.insert('sleep_nap', {
        'day_id': day,
        'start_ts': s,
        'end_ts': e,
        'source': 'legacy',
        'created_at': cutoff,
        'payload_json': jsonEncode({...n, 'source': 'legacy'}),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<List<NapEdit>> napEdits(
    DatabaseExecutor tx,
    String day,
  ) async => [
    for (final row in await tx.query(
      'sleep_nap',
      where: 'day_id = ?',
      whereArgs: [day],
    ))
      NapEdit(
        kind: row['source'] == 'rejected'
            ? NapEditKind.rejected
            : NapEditKind.added,
        startSec: row['start_ts'] as int,
        endSec: row['end_ts'] as int,
        snapshot: row['payload_json'] is String
            ? Map<String, dynamic>.from(
                jsonDecode(row['payload_json'] as String) as Map,
              )
            : null,
      ),
  ];
}
