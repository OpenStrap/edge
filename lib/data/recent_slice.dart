// The "last 2 weeks" database for an issue report: a new SQLite file with the
// SAME schema as the live database (tables, indexes, views, triggers,
// user_version), so every tool that opens a full export opens this too. The
// bulky time series keep only their last [kSliceDays] days (the second-by-
// second ones possibly fewer, to fit the upload cap); the small, diagnostic
// tables come whole. The live database is only ever READ.
//
// Built entirely inside SQLite by [attachCopy], so no row passes through Dart.

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../sync/file_log.dart';
import 'attach_copy.dart';
import 'day_label.dart';
import 'db.dart';

const int kSliceDays = 14;

enum SliceKeep {
  /// Every row.
  all,

  /// Rows whose time column (unix seconds OR milliseconds, told apart by
  /// size) falls in the last [kSliceDays] days.
  recent,

  /// Rows whose YYYY-MM-DD day-label column falls in the last [kSliceDays] days.
  recentDay,

  /// Like [recent], but over the last `rawDays` days only: the second-by-
  /// second series, the part that shrinks when a ticket is too big to upload.
  highRate,

  /// No rows (the table itself is still created).
  none,
}

/// Every table in the live schema: what the slice keeps, by which column, and
/// why. A table missing here falls back to [_fallback]; the test
/// test/issue_report_test.dart fails when one is missing, so add it here.
const Map<String, (SliceKeep, String?, String)> kSliceTables = {
  // Raw and per-second series: the size of the file.
  'decoded_onehz': (SliceKeep.highRate, 'rec_ts', '1 Hz samples, the bulk of the database'),
  'decoded_rr': (SliceKeep.highRate, 'rec_ts', 'beat-to-beat intervals'),
  'samples': (SliceKeep.highRate, 'ts', 'per-second heart rate'),
  'raw_archive': (SliceKeep.highRate, 'captured_at', 'records the app could not decode, by when they arrived'),
  'raw_archive_frames': (SliceKeep.highRate, 'captured_at', 'records the app could not decode, by when they arrived'),
  'raw_archive_legacy': (SliceKeep.highRate, 'captured_at', 'the same records in the older layout, until they are moved'),
  'events': (SliceKeep.recent, 'ts', 'strap event stream'),
  'band_events': (SliceKeep.recent, 'ts', 'decoded strap events'),
  'band_battery': (SliceKeep.recent, 'ts', 'battery readings every few minutes'),
  'band_backlog': (SliceKeep.recent, 'ts', 'strap storage readings per sync'),
  'sync_ledger': (SliceKeep.recent, 'created_at', 'one row per synced chunk'),
  'sync_quarantine': (SliceKeep.recent, 'created_at', 'rejected chunks with their payloads'),
  'external_hr': (SliceKeep.highRate, 'ts', 'per-second heart rate from chest straps'),
  'imported_measurement': (SliceKeep.recent, 'ts', 'Health app samples, can be per-minute'),
  'observation': (SliceKeep.recent, 'ts_ms', 'per-reading values from other wearables'),
  'vendor_sleep_epoch': (SliceKeep.recent, 'start_ts', 'per-epoch sleep stages from other wearables'),
  'live_coverage': (SliceKeep.recent, 'end_ts', 'live-stream coverage intervals'),
  'device_coverage': (SliceKeep.recent, 'end_ts', 'per-device coverage intervals'),
  'workout_route': (SliceKeep.recent, 'ts_ms', 'GPS points'),
  'live_workout_tally': (SliceKeep.recent, 'updated_ts', 'per-workout live heart-rate curves'),
  'compute_jobs': (SliceKeep.recent, 'updated_at', 'compute queue history'),
  'ecg_reading': (SliceKeep.recent, 'start_ts', 'ECG readings'),
  'ecg_reading_packet': (SliceKeep.highRate,
      '(SELECT r.start_ts FROM src.ecg_reading r WHERE r.id = reading_id)',
      'ECG samples, kept for the readings kept'),
  'ecg_raw_packet': (SliceKeep.highRate, 'captured_at', 'raw ECG packets'),
  // Per-night working data: up to ~200 KB a night.
  'sleep_session_candidates': (SliceKeep.recentDay, 'day_id', 'per-night sleep candidates (large)'),
  'wake_day_features': (SliceKeep.recentDay, 'day_id', 'per-day intermediate features'),
  // Long-term archive: already compressed and grows for ever.
  'substrate_archive': (SliceKeep.none, null, 'compressed long-term archive of old raw data'),
  // Daily scores and everything they are built from: every day.
  'day_result': (SliceKeep.all, null, 'daily scores, every day'),
  'derived_day': (SliceKeep.all, null, 'older daily scores'),
  'metric_series': (SliceKeep.all, null, 'one value per metric per day'),
  'metric_series_version': (SliceKeep.all, null, 'which algorithm made each day'),
  'metric_method': (SliceKeep.all, null, 'how each daily metric was measured'),
  'baselines': (SliceKeep.all, null, 'personal baselines'),
  'compute_freshness': (SliceKeep.all, null, 'compute bookkeeping'),
  'derive_fingerprint': (SliceKeep.all, null, 'which days changed since they were last scored'),
  'sleep_nap': (SliceKeep.all, null, 'naps'),
  'sleep_override': (SliceKeep.all, null, 'sleep times the user edited'),
  // Workouts and activity: one row each.
  'sessions': (SliceKeep.all, null, 'workouts'),
  'session_sensor': (SliceKeep.all, null, 'which sensor fed each workout'),
  'session_score_mask': (SliceKeep.all, null, 'workouts left out of scores'),
  'workout_split': (SliceKeep.all, null, 'per-km workout splits'),
  'strength_set': (SliceKeep.all, null, 'strength sets'),
  'workout_suggestions': (SliceKeep.all, null, 'detected workouts'),
  'imported_workout': (SliceKeep.all, null, 'workouts from the Health app'),
  'activity_suggestions': (SliceKeep.all, null, 'activity review items'),
  'activity_review_days': (SliceKeep.all, null, 'activity review state'),
  'activity_review_meta': (SliceKeep.all, null, 'activity review state'),
  'breathing_session': (SliceKeep.all, null, 'breathing sessions'),
  'triathlon_session': (SliceKeep.all, null, 'triathlon sessions'),
  'triathlon_segment': (SliceKeep.all, null, 'triathlon segments'),
  'exercise_def': (SliceKeep.all, null, 'exercise list'),
  // What the user logs: small.
  'journal': (SliceKeep.all, null, 'journal'),
  'journal_metric': (SliceKeep.all, null, 'journal values'),
  'journal_field_def': (SliceKeep.all, null, 'journal fields'),
  'cycle_log': (SliceKeep.all, null, 'cycle log'),
  'cycle_symptom': (SliceKeep.all, null, 'cycle symptoms'),
  'lab_result': (SliceKeep.all, null, 'lab results'),
  'lab_marker_def': (SliceKeep.all, null, 'lab markers'),
  'med_def': (SliceKeep.all, null, 'medications'),
  'med_dose': (SliceKeep.all, null, 'medication doses'),
  'food_def': (SliceKeep.all, null, 'foods'),
  'food_entry': (SliceKeep.all, null, 'food log'),
  // Devices, settings and app state.
  'device': (SliceKeep.all, null, 'paired devices'),
  'signal_priority': (SliceKeep.all, null, 'which device feeds which signal'),
  'step_calibration': (SliceKeep.all, null, 'step calibration'),
  'step_calibration_day': (SliceKeep.all, null, 'step calibration days'),
  'live_step_calibration': (SliceKeep.all, null, 'live step calibration'),
  'live_step_calibration_run':
      (SliceKeep.all, null, 'live step calibration runs'),
  'sync_cursor': (SliceKeep.all, null, 'sync position'),
  'alarm_schedule': (SliceKeep.all, null, 'alarm settings'),
  'notifications': (SliceKeep.all, null, 'in-app notifications'),
  'notif_fired': (SliceKeep.all, null, 'notification history'),
  'notif_slots': (SliceKeep.all, null, 'notification slots'),
};

/// Time columns an unlisted table is sliced on, first match wins.
const _timeColumns = [
  'rec_ts', 'ts', 'ts_ms', 'start_ts', 'captured_at', 'created_at', 'updated_at'
];

/// An unlisted table with no time column comes whole only up to this many rows.
const int _smallTable = 5000;

/// Build the slice from the live database into a new temp file and return its
/// path. The caller deletes it. [rawDays] (1..[kSliceDays]) narrows only the
/// [SliceKeep.highRate] tables.
Future<String> exportRecentSlice({DateTime? now, int rawDays = kSliceDays}) async {
  assert(rawDays >= 1 && rawDays <= kSliceDays);
  final live = await LocalDb.instance;
  final t = now ?? DateTime.now();
  final nowSec = t.millisecondsSinceEpoch ~/ 1000;
  final cutoff = nowSec - kSliceDays * 86400;
  final rawCutoff = nowSec - rawDays * 86400;
  final cutoffDay =
      dayLabelOf(DateTime(t.year, t.month, t.day - kSliceDays));
  final dest = p.join((await getTemporaryDirectory()).path,
      'openstrap_slice_${DateTime.now().microsecondsSinceEpoch}.db');
  await attachCopy(live.path, dest,
      (db, name) => _where(db, name, cutoff, rawCutoff, cutoffDay));
  return dest;
}

/// The WHERE clause that keeps [table]'s rows ('' = all), or null for none.
Future<String?> _where(DatabaseExecutor db, String table, int cutoff,
    int rawCutoff, String cutoffDay) async {
  var rule = kSliceTables[table];
  if (rule == null) {
    rule = await _fallback(db, table);
    await FileLog.write('[report] slice: unlisted table $table -> '
        '${rule.$1.name}${rule.$2 == null ? '' : ' on ${rule.$2}'}');
  }
  final col = rule.$2;
  return switch (rule.$1) {
    SliceKeep.all => '',
    SliceKeep.none => null,
    // ponytail: the seconds/ms switch skips the time index (a full scan);
    // per-column units would let SQLite seek if a slice ever gets slow.
    SliceKeep.recent || SliceKeep.highRate =>
      ' WHERE (CASE WHEN $col > 100000000000 THEN $col / 1000 ELSE $col END)'
          ' >= ${rule.$1 == SliceKeep.highRate ? rawCutoff : cutoff}',
    SliceKeep.recentDay => " WHERE $col >= '$cutoffDay'",
  };
}

Future<(SliceKeep, String?, String)> _fallback(
    DatabaseExecutor db, String table) async {
  final cols = {
    for (final c in await db.rawQuery('PRAGMA src.table_info("$table")'))
      c['name'] as String
  };
  for (final c in _timeColumns) {
    if (cols.contains(c)) return (SliceKeep.recent, c, 'unlisted');
  }
  final n = (await db.rawQuery('SELECT COUNT(*) AS n FROM src."$table"'))
      .first['n'] as int;
  return n <= _smallTable
      ? (SliceKeep.all, null, 'unlisted, small')
      : (SliceKeep.none, null, 'unlisted, large, no time column');
}
