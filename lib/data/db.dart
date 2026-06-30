// Local raw-first storage (SQLite via sqflite).
//
// Durable storage layers:
//   raw_records   — the band's bytes verbatim, keyed by counter. Replay/debug ledger.
//   decoded_onehz — canonical per-second decoded substrate, deduped by rec_ts.
//   decoded_rr    — sparse RR beats for that substrate, deduped by (rr_ts_ms, beat_index).
//   samples       — legacy header cache kept only for backward-compat fallback.
//
// `counter` (u32 @[3:7]) is still kept as the strap's record id, but analytics
// read from canonical decoded tables keyed by physiological time so replayed or
// duplicated historical seconds cannot bloat compute.

import 'dart:convert';
import 'dart:io';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'models.dart';

class LocalDb {
  static Database? _db;
  static String dbName = 'openstrap.db';

  static Future<Database> get instance async {
    _db ??= await _open();
    return _db!;
  }

  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, dbName);
    return openDatabase(
      path,
      onCreate: (db, version) async {
        await _createRaw(db);
        await _createSamples(db);
        await _createDecodedStore(db);
        await db.execute('CREATE INDEX idx_samples_ts ON samples(ts)');
        await _createEvents(db);
        await _createBandSignals(db);
        await _createDerived(db);
        await _createDayResult(db);
        await _createUserTables(db);
        await _createSyncState(db);
        await _createSyncCursor(db);
        await _createComputeState(db);
        await _createPrimitiveArtifacts(db);
        await _createLiveCoverage(db);
        await _createWorkoutSuggestions(db);
        await _createSleepOverride(db);
        await _ensureCoachViews(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) await _createEvents(db);
        if (oldV < 3) {
          // Re-key raw_records by frame hex so LIVE packets (0x28/0x33) — which
          // have no per-record counter — can be queued without PK collisions.
          // Pending unuploaded raw is re-syncable from the band, so a clean
          // rebuild is acceptable.
          await db.execute('DROP TABLE IF EXISTS raw_records');
          await _createRaw(db);
        }
        if (oldV < 4) {
          // The old samples table cached decoded sensor fields (spo2/skin_temp) that
          // (a) were read from MISIDENTIFIED offsets and (b) nothing ever read. The
          // edge no longer decodes sensors — drop + recreate as a header-only index.
          await db.execute('DROP TABLE IF EXISTS samples');
          await _createSamples(db);
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts)',
          );
        }
        if (oldV < 5) {
          // LOCAL-FIRST re-layer: the on-device DerivationEngine now computes the
          // full 1 Hz analytics family from raw and stores PERMANENT derived rows.
          // Purely additive — raw tables are untouched.
          await _createDerived(db);
        }
        if (oldV < 6) {
          // BUCKET-BY-REAL-TIME fix. Add `rec_ts` (epoch SECONDS, the decoded
          // record time) to raw_records and backfill it for every existing row by
          // decoding the stored hex once. The DerivationEngine now buckets days by
          // rec_ts (not captured_at), so a multi-day flash backfill received in one
          // sync no longer collapses into a single "today" bucket. Additive + safe
          // on a populated DB.
          await _addRecTsColumn(db);
          await _backfillRecTs(db);
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_raw_rects ON raw_records(rec_ts)',
          );
        }
        if (oldV < 7) {
          // LOCAL-FIRST user-data layer: journal, menstrual cycle log, workout
          // sessions, and the notifications feed — all on-device, additive.
          await _createUserTables(db);
        }
        if (oldV < 8) {
          // RE-KEY raw_records by `counter` (drop the hex PRIMARY KEY, which
          // roughly DOUBLED on-disk size) and PURGE the live high-rate bloat
          // (0x28/0x2B/0x33). CRITICAL: we must NOT drop the 1 Hz historical
          // substrate (0x2F / R24) — the band will not re-send records its read
          // cursor has already passed, and they may not be derived yet, so a
          // blind rebuild would lose real data. Instead: rename aside, create the
          // new counter-keyed table, migrate the historical rows across (their
          // counters are unique), and discard only the live frames + the old
          // hex-PK overhead.
          await db.execute('ALTER TABLE raw_records RENAME TO _raw_old');
          await _createRaw(db);
          await db.execute(
            'INSERT OR IGNORE INTO raw_records '
            '(counter, hex, packet_type, captured_at, rec_ts, uploaded) '
            'SELECT counter, hex, packet_type, captured_at, rec_ts, uploaded '
            'FROM _raw_old WHERE packet_type = 47 AND counter IS NOT NULL',
          );
          await db.execute('DROP TABLE _raw_old');
        }
        if (oldV < 9) {
          // VERSIONED IMMUTABLE DERIVED STORE (ARCHITECTURE_V2 invariant 6).
          // Replace the single-row `derived_day` (PK date) with
          // `day_result(day_id, algo_version)` so an algo bump writes a NEW
          // version instead of mutating, and the serve seam reads the latest
          // version per day. Additive: create the new table and best-effort
          // migrate any existing derived_day rows across at the prior version, so
          // history survives the upgrade (raw is the source of truth regardless).
          await _createDayResult(db);
          try {
            await db.execute(
              'INSERT OR IGNORE INTO day_result '
              '(day_id, algo_version, payload_json, window_json, computed_at, '
              ' finalized, rhr, rmssd, readiness) '
              "SELECT date, 1, payload_json, '{}', computed_at, 0, rhr, rmssd, readiness "
              'FROM derived_day',
            );
          } catch (_) {
            /* derived_day may be absent — fine, raw rebuilds it */
          }
        }
        if (oldV < 10) {
          await _createSyncState(db);
          // RESUMABLE SYNC. Durable key→value cursor store so the historical
          // offload survives app restarts / disconnects: we persist the strap's
          // continuation token + counter/rec_ts high-water BEFORE ACKing a
          // HISTORY_END (the safe-trim invariant), and reconnect detectors read
          // it to tell a stalled cursor from a healthy one. Additive.
          await _createSyncCursor(db);
        }
        if (oldV < 11) {
          await _createDecodedStore(db);
          await _backfillDecodedStore(db);
          // Live workout steps (Tier-A pedometer over the session's 100 Hz
          // R10 accel). Additive nullable column — old rows read null.
          await db.execute('ALTER TABLE sessions ADD COLUMN steps INTEGER');
        }
        if (oldV < 12) {
          // PURGE the old 1 Hz step ESTIMATE. 1 Hz can't count steps (Nyquist),
          // and the prior ambulatory-minutes×cadence estimate inflated badly
          // (resting noise cleared the floor → ~100k/day). `steps` is recomputed
          // by the new hybrid (live 100 Hz real count + bounded 1 Hz estimate);
          // wipe the bogus history so trends don't carry it.
          await db.execute("DELETE FROM metric_series WHERE key = 'steps'");
        }
        if (oldV < 13) {
          // 100 Hz step coverage: the device-time windows the live pedometer
          // actually counted, so the 1 Hz estimate can EXCLUDE them (prefer the
          // real count, never double-count). Also drop the stale 'active_min'
          // trend — active-minutes was replaced by the steps hybrid.
          await _createBandSignals(db);
          await _ensureSyncStateSchema(db);
          await _createLiveCoverage(db);
          await db.execute("DELETE FROM metric_series WHERE key = 'active_min'");
          await db.execute("DELETE FROM metric_series WHERE key = 'steps'");
        }
        if (oldV < 14) {
          await _createComputeState(db);
        }
        if (oldV < 15) {
          await _createPrimitiveArtifacts(db);
        }
        if (oldV < 16) {
          await _createPrimitiveArtifacts(db);
        }
        if (oldV < 17) {
          await _rebuildCanonicalDecodedStore(db);
        }
        if (oldV < 18) {
          // Menstrual symptom log (full cycle screen) — one row per date, a JSON
          // list of symptom tags + optional note. Separate from cycle_log (whose
          // `date` PK is a period-start marker) so a date can carry both.
          await _createCycleSymptom(db);
        }
        if (oldV < 19) {
          // v25 features: HRR per session, opt-in auto-workout suggestions, and
          // the coach's read-only SQL views over derived data. `hrr_bpm` column +
          // suggestions table are additive; views are (re)built in _repairOpenSchema.
          await _ensureSessionSchema(db); // adds hrr_bpm
          await _createWorkoutSuggestions(db);
        }
        if (oldV < 20) {
          // Manual / confirmed sleep windows (Approach 1 + the fallback's
          // "is this right?" confirm). Additive table; survives algo bumps.
          await _createSleepOverride(db);
        }
      },
      onOpen: (db) async {
        await _repairOpenSchema(db);
      },
      version: 20,
    );
  }

  static Future<void> _repairOpenSchema(Database db) async {
    // Same-version merged builds can still need additive schema repair on an
    // existing install. Keep this idempotent and cheap: create missing tables,
    // indexes, and additive columns the current code assumes are present.
    await _createSamples(db);
    await db.execute('CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts)');
    await _createEvents(db);
    await _createBandSignals(db);
    await _createDerived(db);
    await _createDayResult(db);
    await _createUserTables(db);
    await _createSyncState(db);
    await _createSyncCursor(db);
    await _createComputeState(db);
    await _createPrimitiveArtifacts(db);
    await _createDecodedStore(db);
    await _createLiveCoverage(db);
    await _createCycleSymptom(db);
    await _ensureRawRecordSchema(db);
    await _ensureSessionSchema(db);
    await _ensureSyncStateSchema(db);
    await _createWorkoutSuggestions(db);
    await _createSleepOverride(db);
    // Views LAST — they depend on metric_series / day_result / baselines / sessions
    // / notifications all existing. DROP+CREATE so a shape change takes effect.
    await _ensureCoachViews(db);
  }

  // ── MENSTRUAL SYMPTOM LOG ──────────────────────────────────────────────────
  static Future<void> _createCycleSymptom(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cycle_symptom (
        date TEXT PRIMARY KEY,
        symptoms_json TEXT NOT NULL,
        note TEXT,
        updated_at INTEGER
      )
    ''');
  }

  /// Upsert the symptom set for [date] (empty list clears the row).
  static Future<void> putCycleSymptoms(
      String date, List<String> symptoms, {String? note}) async {
    final db = await instance;
    if (symptoms.isEmpty && (note == null || note.isEmpty)) {
      await db.delete('cycle_symptom', where: 'date = ?', whereArgs: [date]);
      return;
    }
    await db.insert(
      'cycle_symptom',
      {
        'date': date,
        'symptoms_json': jsonEncode(symptoms),
        'note': note,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// All symptom rows (newest first): {date, symptoms_json, note}.
  static Future<List<Map<String, dynamic>>> cycleSymptoms() async {
    final db = await instance;
    return db.query('cycle_symptom', orderBy: 'date DESC');
  }

  // ── RESUMABLE-SYNC CURSOR (durable KV) ──────────────────────────────────────
  // A tiny key→value store for sync bookkeeping that must survive process death.
  // Keys we use (durable resumable-sync cursor semantics):
  //   strap_trim       — hex of the last ACKed HISTORY_END 8-byte token
  //   counter_hw       — highest record `counter` we have durably persisted
  //   rec_ts_hw        — highest record `rec_ts` (epoch sec) durably persisted
  //   data_range_lo/hi — strap's own oldest/newest banked record unix (GET_DATA_RANGE)
  // The "safe-trim invariant" is: persist decoded+raw → persist this cursor →
  // ACK with-response. The band only trims its flash once the ACK is link-layer
  // confirmed, so a crash anywhere before the ACK re-delivers the batch.
  static Future<void> _createSyncCursor(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_cursor (
        name TEXT PRIMARY KEY,
        value TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  // ── SLEEP OVERRIDE (manual / confirmed sleep windows) ───────────────────────
  // The user's word on when they slept — either typed in manually (Approach 1)
  // or a confirmation of the HR-led fallback's proposal (Approach 2). Stored
  // SEPARATELY from the derived day_result so it survives finalization AND any
  // kAlgoVersion bump: the engine re-applies it on every derive of that day.
  //   source: 'manual'    — user typed the times
  //           'confirmed' — user accepted the fallback's proposed window
  // Times are epoch SECONDS (phone clock; raw rec_ts is SET_CLOCK'd to match).
  static Future<void> _createSleepOverride(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_override (
        day_id TEXT PRIMARY KEY,
        onset_ts INTEGER NOT NULL,
        offset_ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Upsert the user's sleep window for [dayId] (local date label). [source] is
  /// 'manual' or 'confirmed'. Replaces any prior override for that day.
  static Future<void> putSleepOverride({
    required String dayId,
    required int onsetTs,
    required int offsetTs,
    required String source,
  }) async {
    final db = await instance;
    await db.insert(
      'sleep_override',
      {
        'day_id': dayId,
        'onset_ts': onsetTs,
        'offset_ts': offsetTs,
        'source': source,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The user's sleep window for [dayId], or null if none.
  static Future<Map<String, dynamic>?> getSleepOverride(String dayId) async {
    final db = await instance;
    final rows = await db.query('sleep_override',
        where: 'day_id = ?', whereArgs: [dayId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Remove the override for [dayId] (revert to auto detection).
  static Future<void> deleteSleepOverride(String dayId) async {
    final db = await instance;
    await db.delete('sleep_override', where: 'day_id = ?', whereArgs: [dayId]);
  }

  /// Every day that currently has a user override — these must be force-derived
  /// even when finalized, so an edit to a locked day actually takes effect.
  static Future<Set<String>> sleepOverrideDays() async {
    final db = await instance;
    final rows = await db.query('sleep_override', columns: ['day_id']);
    return {for (final r in rows) r['day_id'] as String};
  }

  // ── 100 Hz STEP COVERAGE ────────────────────────────────────────────────────
  // Device-time windows the live AN-2554 pedometer actually counted (real steps).
  // The 1 Hz estimate excludes any minute that falls inside one of these windows
  // — 100 Hz is the real count and always wins; we never count a minute twice.
  // Times are device epoch SECONDS (same clock as raw_records.rec_ts, since the
  // band's RTC is SET_CLOCK'd to phone time on connect). `day` = local date label
  // of the window start (for per-day step attribution).
  static Future<void> _createLiveCoverage(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS live_coverage (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        steps INTEGER NOT NULL,
        day TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_live_coverage_day ON live_coverage(day)');
  }

  /// Record a real 100 Hz step window (device-time seconds) + its step count.
  static Future<void> addLiveCoverage(
      int startTs, int endTs, int steps, String day) async {
    if (steps <= 0 || endTs < startTs) return;
    final db = await instance;
    await db.insert('live_coverage',
        {'start_ts': startTs, 'end_ts': endTs, 'steps': steps, 'day': day});
  }

  /// Real (100 Hz) steps attributed to [day].
  static Future<int> liveStepsForDay(String day) async {
    final db = await instance;
    final r = await db.rawQuery(
        'SELECT COALESCE(SUM(steps),0) s FROM live_coverage WHERE day = ?', [day]);
    return (r.first['s'] as num?)?.toInt() ?? 0;
  }

  /// Coverage windows ([startSec, endSec]) overlapping [loSec, hiSec) — used to
  /// exclude already-counted minutes from the 1 Hz estimate.
  static Future<List<List<int>>> coverageWindowsOverlapping(
      int loSec, int hiSec) async {
    final db = await instance;
    final rows = await db.query('live_coverage',
        where: 'end_ts >= ? AND start_ts < ?', whereArgs: [loSec, hiSec]);
    return [
      for (final r in rows)
        [(r['start_ts'] as num).toInt(), (r['end_ts'] as num).toInt()]
    ];
  }

  /// Read a sync-cursor value (null if unset).
  static Future<String?> getCursor(String name) async {
    final db = await instance;
    final rows = await db.query(
      'sync_cursor',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  static Future<int?> getCursorInt(String name) async {
    final v = await getCursor(name);
    return v == null ? null : int.tryParse(v);
  }

  /// Read a cursor int through a specific executor (used inside a transaction so
  /// the read shares the open txn instead of contending on the global handle).
  static Future<int?> _cursorIntVia(DatabaseExecutor ex, String name) async {
    final rows = await ex.query(
      'sync_cursor',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return int.tryParse(rows.first['value'] as String? ?? '');
  }

  /// Upsert a sync-cursor value. Caller may pass a [txn] so the cursor write
  /// shares the SAME transaction as the raw batch — keeping "persist raw then
  /// persist cursor" atomic before the band is ACKed.
  static Future<void> setCursor(
    String name,
    String value, {
    DatabaseExecutor? txn,
  }) async {
    final ex = txn ?? await instance;
    await ex.insert('sync_cursor', {
      'name': name,
      'value': value,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Persist a sync batch atomically: the raw records, their samples, AND the
  /// continuation cursor in ONE transaction. This is the durable half of the
  /// safe-trim invariant — it MUST return before the engine writes the ACK frame.
  /// Advances counter_hw / rec_ts_hw to the batch max so a restart resumes cleanly.
  static Future<void> commitSyncBatch(
    List<RawRecord> raws,
    List<Sample?> samples, {
    String? trimToken,
    Map<String, String>? extraCursors,
  }) async {
    final db = await instance;
    await db.transaction((txn) async {
      // Read the existing high-water THROUGH the txn — never via the global db
      // handle, which would deadlock against this same open transaction.
      var maxCounter = await _cursorIntVia(txn, 'counter_hw') ?? 0;
      var maxRecTs = await _cursorIntVia(txn, 'rec_ts_hw') ?? 0;
      final batch = txn.batch();
      for (var i = 0; i < raws.length; i++) {
        final raw = raws[i];
        final recTs = _recTsFor(raw);
        batch.insert('raw_records', {
          'hex': raw.hex,
          'packet_type': raw.packetType,
          'counter': raw.counter,
          'captured_at': raw.capturedAt,
          'rec_ts': recTs,
          'uploaded': raw.uploaded ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        final sample = samples[i];
        if (sample != null) {
          batch.insert('samples', {
            'counter': raw.counter,
            ...sample.toDbMap(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        _queueDecodedOneHz(batch, raw, sample);
        if (raw.counter > maxCounter) maxCounter = raw.counter;
        if (recTs > maxRecTs) maxRecTs = recTs;
      }
      await batch.commit(noResult: true);
      await setCursor('counter_hw', '$maxCounter', txn: txn);
      await setCursor('rec_ts_hw', '$maxRecTs', txn: txn);
      if (trimToken != null) await setCursor('strap_trim', trimToken, txn: txn);
      if (extraCursors != null) {
        for (final e in extraCursors.entries) {
          await setCursor(e.key, e.value, txn: txn);
        }
      }
    });
    await _writeCaptureFreshness(raws);
  }

  // ── DERIVED STORE (permanent, rich) ────────────────────────────────────────
  // The on-device analytics output, keyed by physiological day (wake-to-wake;
  // the `date` label is edge-supplied, display-only). These rows are PERMANENT —
  // raw is pruned after derivation (rawRetentionDays) but the derived bundle is
  // the long-term system of record the UI reads from. See lib/compute/.
  static Future<void> _createDerived(Database db) async {
    // derived_day — one row per physiological day. `payload_json` is the full
    // result bundle (all clinical/sleep/respiration/motion/wellness/human metrics,
    // each keeping its tier/confidence/inputs_used) PLUS the per-minute/curve
    // series the UI needs (HR curve, HRV timeline, hypnogram). Frequently queried
    // scalars are indexed into columns for cheap trends.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS derived_day (
        date TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        version INTEGER NOT NULL,
        last_raw_ts INTEGER NOT NULL,
        computed_at INTEGER NOT NULL,
        rhr REAL,
        rmssd REAL,
        readiness REAL
      )
    ''');
    // baselines — rolling personal baselines, so a derivation pass reuses stored
    // state instead of refolding full history each time.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS baselines (
        key TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    // metric_series — long-format scalars for trends / sparklines.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS metric_series (
        date TEXT NOT NULL,
        key TEXT NOT NULL,
        value REAL,
        PRIMARY KEY (date, key)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_metric_series_key ON metric_series(key, date)',
    );
  }

  // ── VERSIONED IMMUTABLE DERIVED STORE (ARCHITECTURE_V2 invariant 6) ─────────
  // day_result — one row per (physiological day, algo_version). Derived rows are
  // IMMUTABLE per version: an algo_version bump writes a NEW row (never mutates).
  // The serve seam reads the LATEST algo_version per day_id. A day stays
  // recomputable for ~48 h after its wake (finalized=0); then it LOCKS
  // (finalized=1) and is no longer recomputed even on a version bump.
  static Future<void> _createDayResult(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS day_result (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        window_json TEXT NOT NULL DEFAULT '{}',
        computed_at INTEGER NOT NULL,
        finalized INTEGER NOT NULL DEFAULT 0,
        rhr REAL,
        rmssd REAL,
        readiness REAL,
        PRIMARY KEY (day_id, algo_version)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_day_result_day ON day_result(day_id, algo_version)',
    );
  }

  // ── USER-DATA STORE (journal / cycle / workouts / notifications) ────────────
  // On-device user-entered + locally-generated data. All keyed for idempotent
  // upserts; none of it round-trips to a server (cloud excised).
  static Future<void> _createUserTables(Database db) async {
    // journal — one row per day; tags is a JSON string list, note free text.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal (
        date TEXT PRIMARY KEY,
        tags_json TEXT NOT NULL DEFAULT '[]',
        note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL
      )
    ''');
    // cycle_log — menstrual cycle markers; `kind` is 'start' (cycle start) etc.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cycle_log (
        date TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        note TEXT
      )
    ''');
    // sessions — manual/live/auto workouts; status 'live'|'done', zone tallies JSON.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        calories REAL,
        strain REAL,
        max_hr INTEGER,
        duration_min INTEGER,
        zone_min_json TEXT,
        steps INTEGER,
        hrr_bpm REAL,
        source TEXT NOT NULL DEFAULT 'manual',
        created_at INTEGER NOT NULL
      )
    ''');
    // workout_suggestions — opt-in "did you work out?" auto-detections. Never a
    // real session until the user confirms; `dismissed` hides a rejected one.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_suggestions (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        avg_bpm INTEGER,
        peak_bpm INTEGER,
        duration_min INTEGER,
        sport TEXT,
        dismissed INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    // notifications — locally-generated insight feed (illness/anomaly/temp/readiness).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notifications (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        date TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        read INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  static Future<void> _createSyncState(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_ledger (
        chunk_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        acked_at INTEGER,
        last_error TEXT,
        meta_json TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_quarantine (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        reason TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_quarantine_created ON sync_quarantine(created_at)',
    );
  }

  static Future<void> _createComputeState(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS compute_freshness (
        key TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS compute_jobs (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        scope TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        state TEXT NOT NULL,
        reason TEXT,
        depends_on TEXT,
        input_from_ts INTEGER,
        input_to_ts INTEGER,
        algo_version INTEGER,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_run_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_compute_jobs_state_pri ON compute_jobs(state, priority DESC, updated_at ASC)',
    );
  }

  static Future<void> _createPrimitiveArtifacts(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_session_candidates (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        computed_at INTEGER NOT NULL,
        PRIMARY KEY(day_id, algo_version)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wake_day_features (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        computed_at INTEGER NOT NULL,
        PRIMARY KEY(day_id, algo_version)
      )
    ''');
  }

  static Future<void> _ensureSyncStateSchema(Database db) async {
    await _ensureSyncCursorSchema(db);
    await _ensureSyncLedgerSchema(db);
    await _ensureSyncQuarantineSchema(db);
  }

  static Future<void> _ensureRawRecordSchema(Database db) async {
    final cols = await db.rawQuery("PRAGMA table_info(raw_records)");
    final names = {
      for (final c in cols)
        if (c['name'] is String) c['name'] as String,
    };
    if (!names.contains('rec_ts')) {
      await _addRecTsColumn(db);
      await _backfillRecTs(db);
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_raw_rects ON raw_records(rec_ts)',
      );
    }
  }

  static Future<void> _ensureSessionSchema(Database db) async {
    final cols = await db.rawQuery("PRAGMA table_info(sessions)");
    final names = {
      for (final c in cols)
        if (c['name'] is String) c['name'] as String,
    };
    if (!names.contains('steps')) {
      await db.execute('ALTER TABLE sessions ADD COLUMN steps INTEGER');
    }
    if (!names.contains('hrr_bpm')) {
      await db.execute('ALTER TABLE sessions ADD COLUMN hrr_bpm REAL');
    }
  }

  // ── WORKOUT SUGGESTIONS (opt-in auto-detect) ───────────────────────────────
  static Future<void> _createWorkoutSuggestions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_suggestions (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        avg_bpm INTEGER,
        peak_bpm INTEGER,
        duration_min INTEGER,
        sport TEXT,
        dismissed INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Upsert an auto-detected workout suggestion (id = "$date:$startSec").
  static Future<void> putWorkoutSuggestion(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert('workout_suggestions', row,
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Active (not-yet-dismissed, not-yet-confirmed) suggestions, newest first.
  static Future<List<Map<String, dynamic>>> activeWorkoutSuggestions() async {
    final db = await instance;
    return db.query('workout_suggestions',
        where: 'dismissed = 0', orderBy: 'start_ts DESC');
  }

  static Future<void> dismissWorkoutSuggestion(String id) async {
    final db = await instance;
    await db.update('workout_suggestions', {'dismissed': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  // ── COACH READ-ONLY SQL VIEWS (derived-only) ───────────────────────────────
  // Re-created on every open (DROP+CREATE) so a view-shape change takes effect on
  // upgrade. These flatten DERIVED data only; the coach's read-only SQL layer is
  // allow-listed to these views and can never reach raw_records / decoded_*.
  // Every view over day_result selects the LATEST algo_version per day_id.
  static Future<void> _ensureCoachViews(Database db) async {
    const views = [
      'v_metric',
      'v_daily',
      'v_series',
      'v_hypnogram',
      'v_sessions',
      'v_baselines',
      'v_insights',
    ];
    for (final v in views) {
      await db.execute('DROP VIEW IF EXISTS $v');
    }
    // Long-form scalar trends — the natural per-metric time series.
    await db.execute('''
      CREATE VIEW v_metric AS
      SELECT date, key, value FROM metric_series
    ''');
    // One row per day, common scalars pivoted from metric_series (no JSON path
    // drift; metric_series is the canonical scalar store).
    await db.execute('''
      CREATE VIEW v_daily AS
      SELECT date,
        MAX(CASE WHEN key='rhr' THEN value END)            AS resting_hr,
        MAX(CASE WHEN key='rmssd' THEN value END)          AS hrv,
        MAX(CASE WHEN key='sdnn' THEN value END)           AS sdnn,
        MAX(CASE WHEN key='readiness' THEN value END)      AS readiness,
        MAX(CASE WHEN key='strain' THEN value END)         AS strain,
        MAX(CASE WHEN key='resp_rate' THEN value END)      AS resp_rate,
        MAX(CASE WHEN key='stress' THEN value END)         AS stress,
        MAX(CASE WHEN key='efficiency' THEN value END)     AS sleep_efficiency,
        MAX(CASE WHEN key='tst_min' THEN value END)        AS sleep_min,
        MAX(CASE WHEN key='deep_min' THEN value END)       AS deep_min,
        MAX(CASE WHEN key='rem_min' THEN value END)        AS rem_min,
        MAX(CASE WHEN key='light_min' THEN value END)      AS light_min,
        MAX(CASE WHEN key='nap_min' THEN value END)        AS nap_min,
        MAX(CASE WHEN key='steps' THEN value END)          AS steps,
        MAX(CASE WHEN key='calories' THEN value END)       AS active_calories,
        MAX(CASE WHEN key='calories_total' THEN value END) AS total_calories,
        MAX(CASE WHEN key='skin_temp_z' THEN value END)    AS skin_temp_z,
        MAX(CASE WHEN key='lf_hf' THEN value END)          AS lf_hf,
        MAX(CASE WHEN key='hrv_cv' THEN value END)         AS hrv_cv,
        MAX(CASE WHEN key='dip_pct' THEN value END)        AS dip_pct,
        MAX(CASE WHEN key='odi_per_hour' THEN value END)   AS odi_per_hour,
        MAX(CASE WHEN key='worn_min' THEN value END)       AS worn_min,
        MAX(CASE WHEN key='hrr_bpm' THEN value END)        AS hrr_bpm,
        MAX(CASE WHEN key='brv_cv' THEN value END)         AS brv_cv,
        MAX(CASE WHEN key='irregular_rhythm_flag' THEN value END) AS irregular_flag
      FROM metric_series GROUP BY date
    ''');
    // Intra-day curves UNNESTED from the latest day_result bundle. HEAVY — always
    // filter by date AND series. zone_timeline uses 'z'; activity_curve is root.
    await db.execute('''
      CREATE VIEW v_series AS
      WITH latest AS (
        SELECT r.day_id, r.payload_json FROM day_result r
        JOIN (SELECT day_id, MAX(algo_version) v FROM day_result GROUP BY day_id) m
          ON r.day_id = m.day_id AND r.algo_version = m.v
      )
      SELECT l.day_id AS date, s.sk AS series,
             json_extract(e.value,'\$.t') AS t,
             json_extract(e.value,'\$.v') AS v
      FROM latest l
      JOIN (SELECT 'hr_curve' sk UNION ALL SELECT 'strain_curve'
            UNION ALL SELECT 'hrv_timeline' UNION ALL SELECT 'hrv_day'
            UNION ALL SELECT 'resp_day' UNION ALL SELECT 'skin_temp_day') s
      JOIN json_each(json_extract(l.payload_json,'\$.series.'||s.sk)) e
      UNION ALL
      SELECT l.day_id, 'zone_timeline',
             json_extract(e.value,'\$.t'), json_extract(e.value,'\$.z')
      FROM latest l, json_each(json_extract(l.payload_json,'\$.series.zone_timeline')) e
      UNION ALL
      SELECT l.day_id, 'activity_curve',
             json_extract(e.value,'\$.t'), json_extract(e.value,'\$.v')
      FROM latest l, json_each(json_extract(l.payload_json,'\$.activity_curve')) e
    ''');
    // Sleep stage segments (different element shape from the {t,v} curves).
    await db.execute('''
      CREATE VIEW v_hypnogram AS
      WITH latest AS (
        SELECT r.day_id, r.payload_json FROM day_result r
        JOIN (SELECT day_id, MAX(algo_version) v FROM day_result GROUP BY day_id) m
          ON r.day_id = m.day_id AND r.algo_version = m.v
      )
      SELECT l.day_id AS date,
             json_extract(e.value,'\$.start') AS start_ts,
             json_extract(e.value,'\$.end')   AS end_ts,
             json_extract(e.value,'\$.stage') AS stage
      FROM latest l, json_each(json_extract(l.payload_json,'\$.series.hypnogram')) e
    ''');
    // Workouts (incl. HRR + steps). Passthrough.
    await db.execute('''
      CREATE VIEW v_sessions AS
      SELECT id, start_ts, end_ts, type, status, calories, strain, max_hr,
             duration_min, steps, hrr_bpm, source, zone_min_json
      FROM sessions
    ''');
    // Rolling personal baselines (json_extract; missing paths return NULL safely).
    await db.execute('''
      CREATE VIEW v_baselines AS
      SELECT key,
             json_extract(payload_json,'\$.value')           AS value,
             json_extract(payload_json,'\$.mean')            AS mean,
             json_extract(payload_json,'\$.z')               AS z,
             json_extract(payload_json,'\$.delta')           AS delta,
             json_extract(payload_json,'\$.ratio')           AS ratio,
             json_extract(payload_json,'\$.n')               AS n,
             updated_at
      FROM baselines
    ''');
    // Locally-generated insight / notification feed.
    await db.execute('''
      CREATE VIEW v_insights AS
      SELECT id, kind, title, body, date, created_at, read FROM notifications
    ''');
  }

  static Future<void> _ensureSyncCursorSchema(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_cursor'",
    );
    if (tables.isEmpty) {
      await _createSyncCursor(db);
      return;
    }
    final cols = await db.rawQuery("PRAGMA table_info(sync_cursor)");
    final names = {
      for (final c in cols)
        if (c['name'] is String) c['name'] as String,
    };
    if (names.contains('name') &&
        names.contains('value') &&
        names.contains('updated_at')) {
      return;
    }

    await db.execute('ALTER TABLE sync_cursor RENAME TO sync_cursor_legacy');
    await _createSyncCursor(db);
    final legacyRows = await db.query('sync_cursor_legacy');
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in legacyRows) {
      final name = row['name'] as String?;
      if (name == null || name.isEmpty) continue;
      await db.insert('sync_cursor', {
        'name': name,
        'value': row['value']?.toString(),
        'updated_at': (row['updated_at'] as num?)?.toInt() ?? now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await db.execute('DROP TABLE sync_cursor_legacy');
  }

  static Future<void> _ensureSyncLedgerSchema(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_ledger'",
    );
    if (tables.isEmpty) {
      await _createSyncState(db);
      return;
    }
    final cols = await db.rawQuery("PRAGMA table_info(sync_ledger)");
    final names = {
      for (final c in cols)
        if (c['name'] is String) c['name'] as String,
    };
    if (names.contains('chunk_id')) return;

    await db.execute('ALTER TABLE sync_ledger RENAME TO sync_ledger_legacy');
    await _createSyncState(db);
    final legacyRows = await db.query('sync_ledger_legacy');
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in legacyRows) {
      final meta = <String, dynamic>{
        'last_batch_token': row['last_batch_token'],
        'last_batch_id': row['last_batch_id'],
        'last_batch_records': row['last_batch_records'],
        'last_history_complete_at': row['last_history_complete_at'],
        'last_trim_cutoff_ms': row['last_trim_cutoff_ms'],
        'last_trimmed_at': row['last_trimmed_at'],
        if (row['note'] != null) 'legacy_note': row['note'],
      };
      await db.insert('sync_ledger', {
        'chunk_id': (row['id'] as String?) ?? 'capture',
        'kind': 'historical',
        'status': row['last_history_complete_at'] != null
            ? 'complete'
            : row['last_batch_acked_at'] != null
            ? 'acknowledged'
            : 'legacy',
        'created_at': (row['updated_at'] as num?)?.toInt() ?? now,
        'updated_at': (row['updated_at'] as num?)?.toInt() ?? now,
        'acked_at': (row['last_batch_acked_at'] as num?)?.toInt(),
        'last_error': null,
        'meta_json': jsonEncode(meta),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await db.execute('DROP TABLE sync_ledger_legacy');
  }

  static Future<void> _ensureSyncQuarantineSchema(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_quarantine'",
    );
    if (tables.isEmpty) {
      await _createSyncState(db);
      return;
    }
    final cols = await db.rawQuery("PRAGMA table_info(sync_quarantine)");
    final names = {
      for (final c in cols)
        if (c['name'] is String) c['name'] as String,
    };
    if (names.contains('payload_json')) return;

    await db.execute(
      'ALTER TABLE sync_quarantine RENAME TO sync_quarantine_legacy',
    );
    await _createSyncState(db);
    final legacyRows = await db.query('sync_quarantine_legacy');
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in legacyRows) {
      await db.insert('sync_quarantine', {
        'kind': (row['source_role'] as String?) ?? 'legacy',
        'payload_json': jsonEncode({
          'fingerprint': row['fingerprint'],
          'packet_type': row['packet_type'],
          'hex': row['hex'],
          'counter': row['counter'],
          'captured_at': row['captured_at'],
        }),
        'reason': (row['reason'] as String?) ?? 'legacy_migrated',
        'created_at': (row['created_at'] as num?)?.toInt() ?? now,
      });
    }
    await db.execute('DROP TABLE sync_quarantine_legacy');
  }

  // samples — LEGACY header-only record index (counter, ts, hr). Retained only
  // so pre-v11 databases stay readable if decoded_onehz backfill was partial.
  // New writes should go to decoded_onehz instead.
  static Future<void> _createSamples(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS samples (
        counter INTEGER PRIMARY KEY,
        ts INTEGER NOT NULL,
        hr INTEGER
      )
    ''');
  }

  // decoded_onehz / decoded_rr — durable canonical decoded substrate, additive
  // beside raw_records. This is the canonical query surface for on-device
  // analytics: one row per real second (`rec_ts`) plus sparse RR beats for that
  // second. raw_records stays as the replay/debug ledger and upgrade fallback.
  static Future<void> _createDecodedStore(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_onehz (
        counter INTEGER PRIMARY KEY,
        rec_ts INTEGER NOT NULL,
        hr INTEGER NOT NULL,
        ax REAL NOT NULL,
        ay REAL NOT NULL,
        az REAL NOT NULL,
        spo2_red_raw INTEGER NOT NULL,
        spo2_ir_raw INTEGER NOT NULL,
        skin_temp_raw INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_decoded_onehz_rects ON decoded_onehz(rec_ts, counter)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_decoded_onehz_rec_ts_unique '
      'ON decoded_onehz(rec_ts)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_rr (
        counter INTEGER NOT NULL,
        beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        PRIMARY KEY (counter, beat_index)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_decoded_rr_counter ON decoded_rr(counter, beat_index)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_decoded_rr_ts ON decoded_rr(rr_ts_ms)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_decoded_rr_ts_beat_unique '
      'ON decoded_rr(rr_ts_ms, beat_index)',
    );
  }

  /// Rebuild the decoded substrate into noop-style canonical time-keyed rows:
  /// keep exactly one decoded row per record second and one RR beat per
  /// (second, beat_index). Older duplicate counters remain in raw_records for
  /// forensics, but analytics no longer sees them.
  static Future<void> _rebuildCanonicalDecodedStore(Database db) async {
    // Guarantee the source tables exist before we SELECT from them. On upgrade
    // paths from before the decoded store landed, decoded_onehz/decoded_rr were
    // never created in the migration chain, so this rebuild threw "no such table:
    // decoded_onehz" — failing openDatabase on every launch (stuck at loading).
    // Creating them (empty) here makes the dedup/rebuild a safe no-op in that case.
    await _createDecodedStore(db);
    await db.execute('DROP TABLE IF EXISTS _decoded_onehz_new');
    await db.execute('DROP TABLE IF EXISTS _decoded_rr_new');
    // Drop any leftover temp-named indexes BEFORE recreating them. SQLite index
    // names are database-GLOBAL, and a prior rebuild's `ALTER TABLE _decoded_*_new
    // RENAME TO decoded_*` leaks these `_new` index names onto the FINAL tables
    // (a renamed table keeps its indexes, names and all). On a re-run the plain
    // `CREATE INDEX idx_decoded_onehz_new_rects ...` then throws "index already
    // exists", which fails openDatabase → the upgrade never commits → the rebuild
    // re-runs every launch → app stuck on the loading screen. Dropping the names
    // first makes this rebuild fully idempotent and breaks that loop.
    for (final ix in const [
      'idx_decoded_onehz_new_rects',
      'idx_decoded_onehz_new_rec_ts_unique',
      'idx_decoded_rr_new_counter',
      'idx_decoded_rr_new_ts',
      'idx_decoded_rr_new_ts_beat_unique',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $ix');
    }
    await db.execute('''
      CREATE TABLE _decoded_onehz_new (
        counter INTEGER PRIMARY KEY,
        rec_ts INTEGER NOT NULL,
        hr INTEGER NOT NULL,
        ax REAL NOT NULL,
        ay REAL NOT NULL,
        az REAL NOT NULL,
        spo2_red_raw INTEGER NOT NULL,
        spo2_ir_raw INTEGER NOT NULL,
        skin_temp_raw INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_decoded_onehz_new_rects ON _decoded_onehz_new(rec_ts, counter)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_decoded_onehz_new_rec_ts_unique '
      'ON _decoded_onehz_new(rec_ts)',
    );
    await db.execute('''
      CREATE TABLE _decoded_rr_new (
        counter INTEGER NOT NULL,
        beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        PRIMARY KEY (counter, beat_index)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_decoded_rr_new_counter ON _decoded_rr_new(counter, beat_index)',
    );
    await db.execute(
      'CREATE INDEX idx_decoded_rr_new_ts ON _decoded_rr_new(rr_ts_ms)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_decoded_rr_new_ts_beat_unique '
      'ON _decoded_rr_new(rr_ts_ms, beat_index)',
    );
    await db.execute(
      'INSERT OR IGNORE INTO _decoded_onehz_new '
      '(counter, rec_ts, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, skin_temp_raw) '
      'SELECT d.counter, d.rec_ts, d.hr, d.ax, d.ay, d.az, '
      'd.spo2_red_raw, d.spo2_ir_raw, d.skin_temp_raw '
      'FROM decoded_onehz d '
      'JOIN ('
      '  SELECT rec_ts, MIN(counter) AS keep_counter '
      '  FROM decoded_onehz GROUP BY rec_ts'
      ') k '
      'ON k.rec_ts = d.rec_ts AND k.keep_counter = d.counter '
      'ORDER BY d.rec_ts ASC, d.counter ASC',
    );
    await db.execute(
      'INSERT OR IGNORE INTO _decoded_rr_new(counter, beat_index, rr_ts_ms, rr_ms) '
      'SELECT rr.counter, rr.beat_index, rr.rr_ts_ms, rr.rr_ms '
      'FROM decoded_rr rr '
      'JOIN _decoded_onehz_new onehz ON onehz.counter = rr.counter '
      'ORDER BY rr.rr_ts_ms ASC, rr.beat_index ASC, rr.counter ASC',
    );
    await db.execute('DROP TABLE IF EXISTS decoded_rr');
    await db.execute('DROP TABLE IF EXISTS decoded_onehz');
    await db.execute('ALTER TABLE _decoded_onehz_new RENAME TO decoded_onehz');
    await db.execute('ALTER TABLE _decoded_rr_new RENAME TO decoded_rr');
  }

  // raw_records — keyed by the band's per-record u32 `counter` (the natural
  // idempotency key; re-draining the same flash region inserts nothing new). Only
  // the 1 Hz historical substrate (0x2F / R24) is persisted here — LIVE high-rate
  // frames are ephemeral (routed to an in-memory sink, never stored). Keying by
  // counter instead of the full hex string roughly HALVES on-disk size.
  static Future<void> _createRaw(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raw_records (
        counter INTEGER PRIMARY KEY,
        hex TEXT NOT NULL,
        packet_type INTEGER,
        captured_at INTEGER NOT NULL,
        rec_ts INTEGER NOT NULL DEFAULT 0,
        uploaded INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_unuploaded ON raw_records(uploaded, captured_at) WHERE uploaded = 0',
    );
    // rec_ts is the bucketing/window key for the DerivationEngine.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_rects ON raw_records(rec_ts)',
    );
  }

  /// Add the additive `rec_ts` column to an EXISTING raw_records table (upgrade
  /// path only). NOT NULL with a DEFAULT 0 so legacy rows are well-formed until
  /// the backfill rewrites them.
  static Future<void> _addRecTsColumn(Database db) async {
    await db.execute(
      'ALTER TABLE raw_records ADD COLUMN rec_ts INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// Backfill `rec_ts` for every existing raw row by decoding its hex once. Runs
  /// inside the migration on a populated DB. Falls back to captured_at/1000 when a
  /// frame is undecodable or yields a non-positive ts — rec_ts is never left at 0.
  static Future<void> _backfillRecTs(Database db) async {
    final rows = await db.query(
      'raw_records',
      columns: ['hex', 'captured_at'],
      where: 'rec_ts = 0 OR rec_ts IS NULL',
    );
    if (rows.isEmpty) return;
    final batch = db.batch();
    for (final r in rows) {
      final hex = r['hex'] as String;
      final capturedSec = ((r['captured_at'] as int?) ?? 0) ~/ 1000;
      final ts = decodeRecTs(hex, fallbackSec: capturedSec);
      batch.update(
        'raw_records',
        {'rec_ts': ts},
        where: 'hex = ?',
        whereArgs: [hex],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Decode a frame's REAL record timestamp (epoch seconds) from its inner hex.
  /// Cheap (reads the ts field only via the protocol decoders). Returns
  /// [fallbackSec] when undecodable or the decoded ts is non-positive — so callers
  /// never store a 0/negative rec_ts. Used at insert and during the v6 backfill.
  static int decodeRecTs(String hex, {required int fallbackSec}) {
    // Historical type-24 carries the canonical ts; decodeRecord covers 0x28/R10/R24.
    try {
      final s = proto.decodeRecord(hex);
      if (s != null && s.ts > 0) return s.ts;
    } catch (_) {
      /* fall through */
    }
    // RR-bearing live frames (0x28) as a secondary path.
    try {
      final rr = proto.realtimeRr(hex);
      if (rr != null && rr.ts > 0) return rr.ts;
    } catch (_) {
      /* fall through */
    }
    return fallbackSec;
  }

  static Future<void> _writeCaptureFreshness(List<RawRecord> raws) async {
    if (raws.isEmpty) return;
    var latest = 0;
    for (final raw in raws) {
      final recTs = _recTsFor(raw);
      if (recTs > latest) latest = recTs;
    }
    if (latest <= 0) return;
    final prev = await computeFreshness('capture');
    Map<String, dynamic> payload = const {};
    final rawJson = prev?['payload_json'];
    if (rawJson is String && rawJson.isNotEmpty) {
      try {
        final d = jsonDecode(rawJson);
        if (d is Map) payload = d.cast<String, dynamic>();
      } catch (_) {
        payload = const {};
      }
    }
    payload = {
      ...payload,
      'latest_raw_rec_ts': latest,
      'latest_raw_day': _localDayLabelFromEpoch(latest),
    };
    await putComputeFreshness('capture', jsonEncode(payload));
  }

  static String _localDayLabel(DateTime dt) {
    String two(int x) => x.toString().padLeft(2, '0');
    return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)}';
  }

  static String _localDayLabelFromEpoch(int epochSec) =>
      _localDayLabel(DateTime.fromMillisecondsSinceEpoch(epochSec * 1000));

  static Sample? _decodeOneHzSample(RawRecord raw, {Sample? preferred}) {
    if (preferred != null && preferred.hasDecodedOneHz) return preferred;
    try {
      final r = proto.parseR24(proto.hexToBytes(raw.hex));
      if (r == null || r.tsEpoch <= 0) return null;
      return Sample(
        tsEpoch: r.tsEpoch,
        counter: r.counter,
        hr: r.hr,
        rrIntervalsMs: List<int>.from(r.rrIntervalsMs),
        ax: r.accelG.isNotEmpty ? r.accelG[0] : 0,
        ay: r.accelG.length > 1 ? r.accelG[1] : 0,
        az: r.accelG.length > 2 ? r.accelG[2] : 0,
        spo2RedRaw: r.spo2RedRaw,
        spo2IrRaw: r.spo2IrRaw,
        skinTempRaw: r.skinTempRaw,
      );
    } catch (_) {
      return null;
    }
  }

  static void _queueDecodedOneHz(Batch batch, RawRecord raw, Sample? sample) {
    final decoded = _decodeOneHzSample(raw, preferred: sample);
    if (decoded == null) return;
    final recTs = raw.recTs ?? decoded.tsEpoch;
    batch.insert('decoded_onehz', {
      'counter': raw.counter,
      'rec_ts': recTs,
      'hr': decoded.hr,
      'ax': decoded.ax ?? 0,
      'ay': decoded.ay ?? 0,
      'az': decoded.az ?? 0,
      'spo2_red_raw': decoded.spo2RedRaw ?? 0,
      'spo2_ir_raw': decoded.spo2IrRaw ?? 0,
      'skin_temp_raw': decoded.skinTempRaw ?? 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    for (var i = 0; i < decoded.rrIntervalsMs.length; i++) {
      final rr = decoded.rrIntervalsMs[i];
      if (rr <= 0) continue;
      batch.insert('decoded_rr', {
        'counter': raw.counter,
        'beat_index': i,
        'rr_ts_ms': recTs * 1000,
        'rr_ms': rr,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> _backfillDecodedStore(Database db) async {
    const pageSize = 1000;
    int afterCounter = -1;
    while (true) {
      final rows = await db.query(
        'raw_records',
        columns: ['counter', 'hex', 'packet_type', 'captured_at', 'rec_ts'],
        where: 'counter > ? AND packet_type = ?',
        whereArgs: [afterCounter, 47],
        orderBy: 'counter ASC',
        limit: pageSize,
      );
      if (rows.isEmpty) return;
      final batch = db.batch();
      for (final row in rows) {
        final raw = RawRecord(
          counter: (row['counter'] as num?)?.toInt() ?? 0,
          packetType: (row['packet_type'] as num?)?.toInt() ?? 0,
          hex: row['hex'] as String,
          capturedAt: (row['captured_at'] as num?)?.toInt() ?? 0,
          recTs: (row['rec_ts'] as num?)?.toInt(),
        );
        _queueDecodedOneHz(batch, raw, null);
      }
      await batch.commit(noResult: true);
      afterCounter = (rows.last['counter'] as num?)?.toInt() ?? afterCounter;
      if (rows.length < pageSize) return;
    }
  }

  // Events (wrist on/off, charging, battery, double-tap, …) — live OR from sync.
  // Keyed by the full frame hex so re-delivered identical events dedupe. Retained
  // until uploaded, then deleted (same guarantee as raw_records).
  static Future<void> _createEvents(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        hex TEXT PRIMARY KEY,
        event_id INTEGER,
        ts INTEGER,
        captured_at INTEGER NOT NULL
      )
    ''');
  }

  // band_events / band_battery — structured local history for device-state
  // signals that were previously only ephemeral or raw-only. Additive beside
  // the upload-queue `events` table.
  static Future<void> _createBandSignals(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS band_events (
        hex TEXT PRIMARY KEY,
        event_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        ts INTEGER NOT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        captured_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_band_events_ts ON band_events(ts, event_id)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS band_battery (
        ts INTEGER NOT NULL,
        battery_pct REAL,
        charging INTEGER,
        wrist_on INTEGER,
        source TEXT NOT NULL,
        PRIMARY KEY (ts, source)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_band_battery_ts ON band_battery(ts DESC)',
    );
  }

  static Future<void> insertEvent(int eventId, int ts, String hex) async {
    final db = await instance;
    final capturedAt = DateTime.now().millisecondsSinceEpoch;
    await db.insert('events', {
      'hex': hex,
      'event_id': eventId,
      'ts': ts,
      'captured_at': capturedAt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final parsed = () {
      try {
        return proto.parseEvent(proto.hexToBytes(hex));
      } catch (_) {
        return null;
      }
    }();
    await db.insert('band_events', {
      'hex': hex,
      'event_id': eventId,
      'name': parsed?.name ?? proto.EventId.name(eventId),
      'ts': parsed?.tsEpoch ?? ts,
      'payload_json': jsonEncode(parsed?.decoded ?? const <String, dynamic>{}),
      'captured_at': capturedAt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> insertBandBatterySample({
    required int ts,
    double? batteryPct,
    bool? charging,
    bool? wristOn,
    required String source,
  }) async {
    final db = await instance;
    await db.insert('band_battery', {
      'ts': ts,
      'battery_pct': batteryPct,
      'charging': charging == null ? null : (charging ? 1 : 0),
      'wrist_on': wristOn == null ? null : (wristOn ? 1 : 0),
      'source': source,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<Map<String, dynamic>?> latestBandBatterySample() async {
    final db = await instance;
    final rows = await db.query('band_battery', orderBy: 'ts DESC', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<Map<String, dynamic>> bandSignalsStats() async {
    final db = await instance;
    final eventCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM band_events'),
        ) ??
        0;
    final batteryCount =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM band_battery'),
        ) ??
        0;
    final eventSpan = (await db.rawQuery(
      'SELECT MIN(ts) AS lo, MAX(ts) AS hi FROM band_events',
    )).first;
    final batterySpan = (await db.rawQuery(
      'SELECT MIN(ts) AS lo, MAX(ts) AS hi FROM band_battery',
    )).first;
    final eventKinds = await db.rawQuery(
      'SELECT name, COUNT(*) AS n FROM band_events GROUP BY name ORDER BY n DESC, name ASC',
    );
    return {
      'event_count': eventCount,
      'battery_count': batteryCount,
      'event_min_ts': (eventSpan['lo'] as num?)?.toInt(),
      'event_max_ts': (eventSpan['hi'] as num?)?.toInt(),
      'battery_min_ts': (batterySpan['lo'] as num?)?.toInt(),
      'battery_max_ts': (batterySpan['hi'] as num?)?.toInt(),
      'event_kinds': {
        for (final row in eventKinds)
          (row['name']?.toString() ?? 'unknown'):
              (row['n'] as num?)?.toInt() ?? 0,
      },
    };
  }

  static Future<List<Map<String, dynamic>>> unuploadedEvents({
    int limit = 500,
  }) async {
    final db = await instance;
    return db.query('events', orderBy: 'ts ASC', limit: limit);
  }

  static Future<void> deleteEvents(List<String> hexes) async {
    if (hexes.isEmpty) return;
    final db = await instance;
    final placeholders = List.filled(hexes.length, '?').join(',');
    await db.rawDelete(
      'DELETE FROM events WHERE hex IN ($placeholders)',
      hexes,
    );
  }

  /// Store a raw record (+ optional decoded sample). Idempotent on frame hex.
  /// Raw is written FIRST (raw-first invariant). Returns true if newly inserted.
  /// LIVE packets pass sample=null — the backend field-decodes them from raw.
  /// Resolve the rec_ts (epoch sec) to store: reuse the already-decoded value from
  /// [raw] (ble_engine sets it from the record it parsed) to avoid a double-decode,
  /// else decode the hex here, else fall back to captured_at/1000.
  static int _recTsFor(RawRecord raw) {
    if (raw.recTs != null && raw.recTs! > 0) return raw.recTs!;
    return decodeRecTs(raw.hex, fallbackSec: raw.capturedAt ~/ 1000);
  }

  static Future<bool> insertRecord(RawRecord raw, Sample? sample) async {
    final db = await instance;
    int rawRows = 0;
    await db.transaction((txn) async {
      final batch = txn.batch();
      rawRows = await txn.insert('raw_records', {
        'hex': raw.hex,
        'packet_type': raw.packetType,
        'counter': raw.counter,
        'captured_at': raw.capturedAt,
        'rec_ts': _recTsFor(raw),
        'uploaded': raw.uploaded ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      _queueDecodedOneHz(batch, raw, sample);
      await batch.commit(noResult: true);
    });
    return rawRows != 0;
  }

  /// Insert many records in ONE transaction. During a historical drain this is
  /// far faster than a transaction-per-record (one fsync instead of thousands).
  /// `samples` is now purely an ingest carrier for decoded fields; rows are
  /// persisted into decoded_onehz/decoded_rr, not into the legacy `samples`
  /// table. Raw-first is preserved — callers flush this before ACKing a sync batch.
  static Future<void> insertRecordsBatch(
    List<RawRecord> raws,
    List<Sample?> samples,
  ) async {
    if (raws.isEmpty) return;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < raws.length; i++) {
        final raw = raws[i];
        batch.insert('raw_records', {
          'hex': raw.hex,
          'packet_type': raw.packetType,
          'counter': raw.counter,
          'captured_at': raw.capturedAt,
          'rec_ts': _recTsFor(raw),
          'uploaded': raw.uploaded ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        final sample = samples[i];
        _queueDecodedOneHz(batch, raw, sample);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> putSyncLedger(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert(
      'sync_ledger',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> syncLedgerEntry([
    String chunkId = 'capture',
  ]) async {
    final db = await instance;
    final rows = await db.query(
      'sync_ledger',
      where: 'chunk_id = ?',
      whereArgs: [chunkId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Merge a diagnostic/sync snapshot into the durable capture ledger row.
  /// `meta_json` is treated as a shallow object and patched, not replaced.
  static Future<void> upsertSyncLedgerEntry({
    String chunkId = 'capture',
    String kind = 'historical',
    required String status,
    int? ackedAt,
    String? lastError,
    Map<String, dynamic>? metaPatch,
  }) async {
    final db = await instance;
    final existing = await syncLedgerEntry(chunkId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final meta = <String, dynamic>{};
    if (existing != null) {
      final rawMeta = existing['meta_json'];
      if (rawMeta is String && rawMeta.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawMeta);
          if (decoded is Map) {
            meta.addAll(decoded.cast<String, dynamic>());
          }
        } catch (_) {
          /* keep empty */
        }
      }
    }
    if (metaPatch != null) meta.addAll(metaPatch);
    await db.insert('sync_ledger', {
      'chunk_id': chunkId,
      'kind': kind,
      'status': status,
      'created_at': (existing?['created_at'] as num?)?.toInt() ?? now,
      'updated_at': now,
      'acked_at': ackedAt ?? (existing?['acked_at'] as num?)?.toInt(),
      'last_error': lastError,
      'meta_json': jsonEncode(meta),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> syncLedger() async {
    final db = await instance;
    return db.query('sync_ledger', orderBy: 'created_at ASC');
  }

  static Future<void> quarantineSyncChunk({
    required String kind,
    required String payloadJson,
    required String reason,
  }) async {
    final db = await instance;
    await db.insert('sync_quarantine', {
      'kind': kind,
      'payload_json': payloadJson,
      'reason': reason,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<List<RawRecord>> unuploadedRaw({int limit = 500}) async {
    final db = await instance;
    final rows = await db.query(
      'raw_records',
      where: 'uploaded = 0',
      orderBy: 'captured_at ASC',
      limit: limit,
    );
    return rows
        .map(
          (m) => RawRecord(
            counter: (m['counter'] as int?) ?? 0,
            packetType: (m['packet_type'] as int?) ?? 0,
            hex: m['hex'] as String,
            capturedAt: m['captured_at'] as int,
            recTs: (m['rec_ts'] as int?),
            uploaded: false,
          ),
        )
        .toList();
  }

  /// Once a batch is safely on the server, DELETE the raw blobs locally — we
  /// don't need on-device history (the cloud is the system of record). Keeps the
  /// device storage tiny: raw_records only ever holds the not-yet-uploaded queue.
  static Future<void> markUploaded(List<String> hexes) async {
    if (hexes.isEmpty) return;
    final db = await instance;
    final placeholders = List.filled(hexes.length, '?').join(',');
    await db.rawDelete(
      'DELETE FROM raw_records WHERE hex IN ($placeholders)',
      hexes,
    );
  }

  static Future<List<Sample>> samplesInRange(int fromTs, int toTs) async {
    final db = await instance;
    final decodedRows = await db.query(
      'decoded_onehz',
      columns: ['counter', 'rec_ts', 'hr'],
      where: 'rec_ts >= ? AND rec_ts <= ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'rec_ts ASC, counter ASC',
    );
    if (decodedRows.isNotEmpty) {
      return decodedRows
          .map(
            (m) => Sample(
              tsEpoch: (m['rec_ts'] as num).toInt(),
              counter: (m['counter'] as num).toInt(),
              hr: (m['hr'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList();
    }
    final rows = await db.query(
      'samples',
      where: 'ts >= ? AND ts <= ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'ts ASC',
    );
    return rows.map(Sample.fromDbMap).toList();
  }

  static Future<Sample?> latestSample() async {
    final db = await instance;
    final decodedRows = await db.query(
      'decoded_onehz',
      columns: ['counter', 'rec_ts', 'hr'],
      orderBy: 'rec_ts DESC, counter DESC',
      limit: 1,
    );
    if (decodedRows.isNotEmpty) {
      final row = decodedRows.first;
      return Sample(
        tsEpoch: (row['rec_ts'] as num).toInt(),
        counter: (row['counter'] as num).toInt(),
        hr: (row['hr'] as num?)?.toInt() ?? 0,
      );
    }
    final rows = await db.query('samples', orderBy: 'ts DESC', limit: 1);
    return rows.isEmpty ? null : Sample.fromDbMap(rows.first);
  }

  static Future<Map<String, int>> counts() async {
    final db = await instance;
    final raw =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM raw_records'),
        ) ??
        0;
    final pending =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM raw_records WHERE uploaded = 0',
          ),
        ) ??
        0;
    return {'raw': raw, 'pending': pending};
  }

  // ── raw read (for the DerivationEngine — main isolate only) ─────────────────

  /// All raw record hexes captured in [fromMs, toMs] (epoch ms = captured_at),
  /// oldest first. The engine decodes these via openstrap_protocol off-isolate.
  static Future<List<String>> rawHexInCaptureRange(int fromMs, int toMs) async {
    final db = await instance;
    final rows = await db.query(
      'raw_records',
      columns: ['hex'],
      where: 'captured_at >= ? AND captured_at <= ?',
      whereArgs: [fromMs, toMs],
      orderBy: 'captured_at ASC',
    );
    return rows.map((m) => m['hex'] as String).toList();
  }

  /// All raw record hexes whose REAL record time (`rec_ts`, epoch SECONDS) is in
  /// [fromSec, toSec], oldest first. This is the day-window read the engine uses so
  /// a backfill is split by real day, not by when it was received (captured_at).
  static Future<List<String>> rawHexInRecTsRange(int fromSec, int toSec) async {
    final db = await instance;
    final rows = await db.query(
      'raw_records',
      columns: ['hex'],
      where: 'rec_ts >= ? AND rec_ts <= ?',
      whereArgs: [fromSec, toSec],
      orderBy: 'rec_ts ASC',
    );
    return rows.map((m) => m['hex'] as String).toList();
  }

  /// `{localDayLabel -> MAX(rec_ts)}` over all raw, grouped by the LOCAL calendar
  /// day of the record's real time. The engine compares each day's max rec_ts
  /// against its derived cursor to decide what needs (re)derivation.
  static Future<Map<String, int>> rawRecTsMaxByDay() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT strftime('%Y-%m-%d', rec_ts, 'unixepoch', 'localtime') AS d, "
      'MAX(rec_ts) AS mx FROM raw_records GROUP BY d',
    );
    final out = <String, int>{};
    for (final r in rows) {
      final d = r['d'] as String?;
      final mx = (r['mx'] as num?)?.toInt();
      if (d != null && mx != null) out[d] = mx;
    }
    return out;
  }

  /// The newest `captured_at` (epoch ms) across all raw — used to find days with
  /// new raw to (re)derive. Null if the store is empty.
  static Future<int?> latestRawCapturedAt() async {
    final db = await instance;
    return Sqflite.firstIntValue(
      await db.rawQuery('SELECT MAX(captured_at) FROM raw_records'),
    );
  }

  /// The oldest `captured_at` (epoch ms) across all raw. Null if empty.
  static Future<int?> earliestRawCapturedAt() async {
    final db = await instance;
    return Sqflite.firstIntValue(
      await db.rawQuery('SELECT MIN(captured_at) FROM raw_records'),
    );
  }

  /// ALL retained raw record hexes, ordered by REAL record time (rec_ts). The
  /// engine decodes these ONCE into a single continuous Substrate (substrate.dart).
  static Future<List<String>> allRawHexByRecTs() async {
    final db = await instance;
    final rows = await db.query(
      'raw_records',
      columns: ['hex'],
      orderBy: 'rec_ts ASC',
    );
    return rows.map((m) => m['hex'] as String).toList();
  }

  /// Cursor for batched decode. Used by the derivation coordinator so the raw
  /// ledger never has to cross sqflite as one huge result set.
  static Future<List<Map<String, dynamic>>> rawHexBatchByRecTs({
    required int limit,
    int? afterRecTs,
    int? afterRowId,
  }) async {
    final db = await instance;
    if (afterRecTs == null || afterRowId == null) {
      return db.rawQuery(
        'SELECT rowid, hex, rec_ts FROM raw_records '
        'ORDER BY rec_ts ASC, rowid ASC LIMIT ?',
        [limit],
      );
    }
    return db.rawQuery(
      'SELECT rowid, hex, rec_ts FROM raw_records '
      'WHERE rec_ts > ? OR (rec_ts = ? AND rowid > ?) '
      'ORDER BY rec_ts ASC, rowid ASC LIMIT ?',
      [afterRecTs, afterRecTs, afterRowId, limit],
    );
  }

  /// Cursor for batched decode scoped to a REAL record-time window. Used by the
  /// derive coordinator so a light/heavy pass can rebuild only the affected raw
  /// horizon rather than the full retained ledger.
  static Future<List<Map<String, dynamic>>> rawHexBatchByRecTsRange({
    required int limit,
    required int fromRecTs,
    required int toRecTs,
    int? afterRecTs,
    int? afterRowId,
  }) async {
    final db = await instance;
    if (afterRecTs == null || afterRowId == null) {
      return db.rawQuery(
        'SELECT rowid, hex, rec_ts FROM raw_records '
        'WHERE rec_ts >= ? AND rec_ts <= ? '
        'ORDER BY rec_ts ASC, rowid ASC LIMIT ?',
        [fromRecTs, toRecTs, limit],
      );
    }
    return db.rawQuery(
      'SELECT rowid, hex, rec_ts FROM raw_records '
      'WHERE rec_ts >= ? AND rec_ts <= ? '
      'AND (rec_ts > ? OR (rec_ts = ? AND rowid > ?)) '
      'ORDER BY rec_ts ASC, rowid ASC LIMIT ?',
      [fromRecTs, toRecTs, afterRecTs, afterRecTs, afterRowId, limit],
    );
  }

  /// Decoded 1 Hz frames in record-time order. This is the preferred derive
  /// read path: smaller than raw hex, directly queryable, and already split into
  /// canonical columns.
  static Future<List<Map<String, dynamic>>> decodedOneHzBatchByRecTsRange({
    required int limit,
    required int fromRecTs,
    required int toRecTs,
    int? afterRecTs,
    int? afterCounter,
  }) async {
    final db = await instance;
    if (afterRecTs == null || afterCounter == null) {
      return db.rawQuery(
        'SELECT counter, rec_ts, hr, ax, ay, az, '
        'spo2_red_raw, spo2_ir_raw, skin_temp_raw '
        'FROM decoded_onehz '
        'WHERE rec_ts >= ? AND rec_ts <= ? '
        'ORDER BY rec_ts ASC, counter ASC LIMIT ?',
        [fromRecTs, toRecTs, limit],
      );
    }
    return db.rawQuery(
      'SELECT counter, rec_ts, hr, ax, ay, az, '
      'spo2_red_raw, spo2_ir_raw, skin_temp_raw '
      'FROM decoded_onehz '
      'WHERE rec_ts >= ? AND rec_ts <= ? '
      'AND (rec_ts > ? OR (rec_ts = ? AND counter > ?)) '
      'ORDER BY rec_ts ASC, counter ASC LIMIT ?',
      [fromRecTs, toRecTs, afterRecTs, afterRecTs, afterCounter, limit],
    );
  }

  /// Sparse RR beats for a contiguous decoded 1 Hz page, keyed by the owning
  /// frame counter and ordered by that frame.
  static Future<List<Map<String, dynamic>>> decodedRrByCounterRange({
    required int fromCounter,
    required int toCounter,
  }) async {
    final db = await instance;
    return db.query(
      'decoded_rr',
      columns: ['counter', 'beat_index', 'rr_ts_ms', 'rr_ms'],
      where: 'counter >= ? AND counter <= ?',
      whereArgs: [fromCounter, toCounter],
      orderBy: 'counter ASC, beat_index ASC',
    );
  }

  // ── VERSIONED DERIVED STORE I/O (day_result; main isolate only) ─────────────

  /// Upsert one (day_id, algo_version) result + its indexed scalars in one
  /// transaction. Immutable PER VERSION: a version bump writes a new row. The
  /// `finalized` flag locks a day from further recompute (~48 h after wake).
  static Future<void> putDayResult({
    required String dayId,
    required int algoVersion,
    required String payloadJson,
    required String windowJson,
    bool finalized = false,
    double? rhr,
    double? rmssd,
    double? readiness,
    Map<String, double?> series = const {},
  }) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.insert('day_result', {
        'day_id': dayId,
        'algo_version': algoVersion,
        'payload_json': payloadJson,
        'window_json': windowJson,
        'computed_at': now,
        'finalized': finalized ? 1 : 0,
        'rhr': rhr,
        'rmssd': rmssd,
        'readiness': readiness,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final e in series.entries) {
        await txn.insert('metric_series', {
          'date': dayId,
          'key': e.key,
          'value': e.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// The latest-version result row for one day_id (highest algo_version), with a
  /// normalized `date` alias for callers. Null if absent.
  static Future<Map<String, dynamic>?> dayResult(String dayId) async {
    final db = await instance;
    final rows = await db.query(
      'day_result',
      where: 'day_id = ?',
      whereArgs: [dayId],
      orderBy: 'algo_version DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _withDate(rows.first);
  }

  /// The most recent day (highest day_id label), latest version, or null.
  static Future<Map<String, dynamic>?> latestDayResult() async {
    final rows = await recentDayResults(1);
    return rows.isEmpty ? null : rows.first;
  }

  /// The N most recent days (newest day_id first), each at its LATEST version.
  static Future<List<Map<String, dynamic>>> recentDayResults(int limit) async {
    final db = await instance;
    // For each day_id pick MAX(algo_version), then join back for the full row.
    final rows = await db.rawQuery(
      'SELECT r.* FROM day_result r '
      'JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result GROUP BY day_id) m '
      '  ON r.day_id = m.day_id AND r.algo_version = m.v '
      'ORDER BY r.day_id DESC LIMIT ?',
      [limit],
    );
    return [for (final r in rows) _withDate(r)];
  }

  /// The set of day_id labels that already have a result at [algoVersion].
  static Future<Set<String>> dayResultIds(int algoVersion) async {
    final db = await instance;
    final rows = await db.query(
      'day_result',
      columns: ['day_id'],
      where: 'algo_version = ?',
      whereArgs: [algoVersion],
    );
    return {for (final r in rows) r['day_id'] as String};
  }

  /// The set of day_id labels that are FINALIZED at [algoVersion] (locked). A
  /// finalized day is never recomputed even on a version bump.
  static Future<Set<String>> finalizedDayIds(int algoVersion) async {
    final db = await instance;
    final rows = await db.query(
      'day_result',
      columns: ['day_id'],
      where: 'algo_version = ? AND finalized = 1',
      whereArgs: [algoVersion],
    );
    return {for (final r in rows) r['day_id'] as String};
  }

  /// Normalize a day_result row to also carry a `date` key (== day_id) so legacy
  /// readers that keyed on `date` keep working.
  static Map<String, dynamic> _withDate(Map<String, dynamic> row) {
    final m = Map<String, dynamic>.from(row);
    m['date'] = m['day_id'];
    return m;
  }

  /// Write a consistent, compacted snapshot of the DB to a temp file for export.
  /// Uses `VACUUM INTO` (NOT a raw file copy) so the snapshot is transactionally
  /// consistent — a plain copy of a live SQLite file can produce torn pages
  /// (a corrupt export). VACUUM INTO also defragments, so the file is small.
  static Future<String> exportCopy() async {
    final db = await instance;
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = p.join(tmp.path, 'openstrap_export_$stamp.db');
    final f = File(dest);
    if (await f.exists()) await f.delete(); // VACUUM INTO requires a fresh path
    await db.execute('VACUUM INTO ?', [dest]);
    return dest;
  }

  /// Import another device's exported OpenStrap DB ([path], from [exportCopy] +
  /// share) by MERGING its rows into this one (INSERT-OR-REPLACE). Covers derived
  /// results, the metric series, user data, and the raw ledger so the receiving
  /// device has the full history (and can re-derive). Same app ⇒ same schema; a
  /// table missing in the source is skipped. Returns per-table copied counts.
  static Future<Map<String, int>> importFromDbFile(String path) async {
    if (!await File(path).exists()) {
      throw const FileSystemException('Backup file not found');
    }
    final src = await openDatabase(path, readOnly: true);
    final db = await instance;
    // Order: independent tables; all use INSERT OR REPLACE so re-import is safe.
    const tables = [
      'raw_records',
      'samples',
      'events',
      'day_result',
      'metric_series',
      'sessions',
      'journal',
      'cycle_log',
      'notifications',
      'baselines',
      'sync_cursor',
    ];
    // Columns this app's schema actually has, per table — so a row from a NEWER
    // export carrying extra columns this build doesn't know about is filtered
    // down (dropped) instead of throwing "no such column". A column the source
    // LACKS simply isn't in the map → the dest default applies. Forward- and
    // backward-compatible across schema versions.
    Future<Set<String>> destCols(String t) async {
      final info = await db.rawQuery('PRAGMA table_info($t)');
      return {for (final c in info) (c['name'] as String)};
    }

    final counts = <String, int>{};
    try {
      for (final t in tables) {
        List<Map<String, Object?>> rows;
        try {
          rows = await src.query(t);
        } catch (_) {
          continue; // table absent in the source export
        }
        if (rows.isEmpty) {
          counts[t] = 0;
          continue;
        }
        final cols = await destCols(t);
        if (cols.isEmpty) continue; // table absent in THIS build
        await db.transaction((txn) async {
          final batch = txn.batch();
          for (final r in rows) {
            final row = <String, Object?>{
              for (final e in r.entries)
                if (cols.contains(e.key)) e.key: e.value,
            };
            if (row.isEmpty) continue;
            batch.insert(t, row, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          await batch.commit(noResult: true);
        });
        counts[t] = rows.length;
      }
    } finally {
      await src.close();
    }
    return counts;
  }

  // ── diagnostics (read-only summaries for the Diagnostics screen) ────────────

  /// Raw store summary: total rows, rec_ts span (real record time, sec, >0 only),
  /// per-packet_type counts, and the captured_at span (ms) for comparison.
  static Future<Map<String, dynamic>> rawStats() async {
    final db = await instance;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM raw_records'),
        ) ??
        0;
    final tsRow = (await db.rawQuery(
      'SELECT MIN(rec_ts) AS lo, MAX(rec_ts) AS hi FROM raw_records WHERE rec_ts > 0',
    )).first;
    final capRow = (await db.rawQuery(
      'SELECT MIN(captured_at) AS lo, MAX(captured_at) AS hi FROM raw_records',
    )).first;
    final typeRows = await db.rawQuery(
      'SELECT packet_type AS t, COUNT(*) AS n FROM raw_records GROUP BY packet_type',
    );
    final byType = <String, int>{};
    for (final r in typeRows) {
      byType['${(r['t'] as int?) ?? -1}'] = (r['n'] as int?) ?? 0;
    }
    final decodedOneHz =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_onehz'),
        ) ??
        0;
    final decodedRr =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_rr'),
        ) ??
        0;
    final legacySamples =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM samples'),
        ) ??
        0;
    return {
      'count': count,
      'min_rec_ts': (tsRow['lo'] as num?)?.toInt(),
      'max_rec_ts': (tsRow['hi'] as num?)?.toInt(),
      'by_type': byType,
      'min_captured_ms': (capRow['lo'] as num?)?.toInt(),
      'max_captured_ms': (capRow['hi'] as num?)?.toInt(),
      'decoded_onehz': decodedOneHz,
      'decoded_rr': decodedRr,
      'legacy_samples': legacySamples,
    };
  }

  static Future<Map<String, dynamic>> schemaHealth() async {
    final db = await instance;
    Future<bool> hasTable(String name) async {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [name],
      );
      return rows.isNotEmpty;
    }

    Future<Set<String>> cols(String table) async {
      final info = await db.rawQuery('PRAGMA table_info($table)');
      return {
        for (final c in info)
          if (c['name'] is String) c['name'] as String,
      };
    }

    final requiredTables = <String>[
      'raw_records',
      'samples',
      'decoded_onehz',
      'decoded_rr',
      'events',
      'band_events',
      'band_battery',
      'day_result',
      'metric_series',
      'baselines',
      'sessions',
      'journal',
      'cycle_log',
      'notifications',
      'sync_cursor',
      'sync_ledger',
      'sync_quarantine',
      'compute_freshness',
      'compute_jobs',
      'sleep_session_candidates',
      'wake_day_features',
      'live_coverage',
    ];

    final missingTables = <String>[];
    for (final table in requiredTables) {
      if (!await hasTable(table)) missingTables.add(table);
    }

    final rawCols =
        await hasTable('raw_records') ? await cols('raw_records') : <String>{};
    final sessionCols =
        await hasTable('sessions') ? await cols('sessions') : <String>{};
    final syncLedgerCols =
        await hasTable('sync_ledger') ? await cols('sync_ledger') : <String>{};

    final missingColumns = <String, List<String>>{};
    void expect(String table, Set<String> present, List<String> required) {
      final miss = [for (final c in required) if (!present.contains(c)) c];
      if (miss.isNotEmpty) missingColumns[table] = miss;
    }

    expect('raw_records', rawCols, ['counter', 'hex', 'captured_at', 'rec_ts']);
    expect('sessions', sessionCols, ['id', 'start_ts', 'status', 'steps']);
    expect('sync_ledger', syncLedgerCols,
        ['chunk_id', 'kind', 'status', 'updated_at', 'meta_json']);

    final integrity = await db.rawQuery('PRAGMA integrity_check');
    final integrityOk = integrity.isNotEmpty && integrity.first.values.first == 'ok';

    return {
      'ok': missingTables.isEmpty && missingColumns.isEmpty && integrityOk,
      'missing_tables': missingTables,
      'missing_columns': missingColumns,
      'integrity_ok': integrityOk,
    };
  }

  static Future<Map<String, dynamic>?> syncLedgerSummary([
    String chunkId = 'capture',
  ]) async {
    final row = await syncLedgerEntry(chunkId);
    if (row == null) return null;
    final meta = <String, dynamic>{};
    final rawMeta = row['meta_json'];
    if (rawMeta is String && rawMeta.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMeta);
        if (decoded is Map) meta.addAll(decoded.cast<String, dynamic>());
      } catch (_) {
        /* ignore */
      }
    }
    return {
      'chunk_id': row['chunk_id'],
      'kind': row['kind'],
      'status': row['status'],
      'created_at': row['created_at'],
      'updated_at': row['updated_at'],
      'acked_at': row['acked_at'],
      'last_error': row['last_error'],
      ...meta,
    };
  }

  /// Derived store summary: distinct days, how many are skipped markers (latest
  /// version), the latest day label, and the most recent (up to 14) day labels.
  static Future<Map<String, dynamic>> derivedStats() async {
    final db = await instance;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(DISTINCT day_id) FROM day_result'),
        ) ??
        0;
    final recent = await recentDayResults(14);
    var skipped = 0;
    for (final r in recent) {
      final pj = r['payload_json'];
      if (pj is String && pj.contains('"skipped":true')) skipped++;
    }
    final dates = [for (final r in recent) r['day_id'] as String];
    return {
      'count': count,
      'skipped': skipped,
      'latest_date': dates.isEmpty ? null : dates.first,
      'dates': dates,
    };
  }

  /// Recent latest-version day rows with lightweight status fields used by the
  /// metrics diagnostics view.
  static Future<List<Map<String, dynamic>>> recentDayDiagnostics(
    int limit,
  ) async {
    final rows = await recentDayResults(limit);
    final rawByDay = await rawRecTsMaxByDay();
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      final payload = row['payload_json'] as String?;
      Map<String, dynamic> decoded = const {};
      if (payload != null && payload.isNotEmpty) {
        try {
          final d = jsonDecode(payload);
          if (d is Map) decoded = d.cast<String, dynamic>();
        } catch (_) {
          /* ignore */
        }
      }
      final scalars = ((decoded['scalars'] as Map?) ?? const {})
          .cast<String, dynamic>();
      final dayId = row['day_id'] as String? ?? '';
      out.add({
        'day_id': dayId,
        'computed_at': row['computed_at'],
        'algo_version': row['algo_version'],
        'finalized': row['finalized'],
        'raw_max_rec_ts': rawByDay[dayId],
        'skipped': decoded['skipped'] == true,
        'skip_reason': decoded['reason'],
        'rhr': row['rhr'] ?? scalars['rhr'],
        'rmssd': row['rmssd'] ?? scalars['rmssd'],
        'readiness': row['readiness'] ?? scalars['readiness'],
        'strain': scalars['strain'],
        'tst_min': scalars['tst_min'],
        'resp_rate': scalars['resp_rate'],
      });
    }
    return out;
  }

  /// Count non-null series points for each requested metric key.
  static Future<Map<String, int>> metricSeriesCounts(List<String> keys) async {
    if (keys.isEmpty) return const {};
    final db = await instance;
    final out = <String, int>{};
    for (final key in keys) {
      out[key] =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM metric_series WHERE key = ? AND value IS NOT NULL',
              [key],
            ),
          ) ??
          0;
    }
    return out;
  }

  /// Cross-day rollup presence + day count, read from the `crossday` baseline.
  static Future<Map<String, dynamic>?> crossDayStats() async {
    final r = await baseline('crossday');
    final json = r?['payload_json'];
    if (json is! String) return {'present': false};
    try {
      final p = jsonDecode(json);
      final nDays = p is Map ? p['n_days'] : null;
      return {'present': true, 'n_days': nDays};
    } catch (_) {
      return {'present': false};
    }
  }

  /// Single metric_series value for one (date, key), or null.
  static Future<double?> metricValueOn(String date, String key) async {
    final db = await instance;
    final rows = await db.query('metric_series',
        where: 'date = ? AND key = ?', whereArgs: [date, key], limit: 1);
    if (rows.isEmpty) return null;
    return (rows.first['value'] as num?)?.toDouble();
  }

  static Future<ana.StepCalibration?> getStepCalibration() async {
    final row = await baseline('step_calibration');
    final raw = row?['payload_json'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? ana.StepCalibration.fromJson(decoded.cast<String, dynamic>())
          : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> putStepCalibration(ana.StepCalibration calibration) =>
      putBaseline('step_calibration', jsonEncode(calibration.toJson()));

  /// A long-format metric series (oldest first) for trends/sparklines.
  static Future<List<Map<String, dynamic>>> metricSeries(
    String key, {
    int? limit,
  }) async {
    final db = await instance;
    return db.query(
      'metric_series',
      where: 'key = ? AND value IS NOT NULL',
      whereArgs: [key],
      orderBy: 'date ASC',
      limit: limit,
    );
  }

  static Future<Map<String, dynamic>?> baseline(String key) async {
    final db = await instance;
    final rows = await db.query(
      'baselines',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> putBaseline(String key, String payloadJson) async {
    final db = await instance;
    await db.insert('baselines', {
      'key': key,
      'payload_json': payloadJson,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, dynamic>?> computeFreshness(String key) async {
    final db = await instance;
    final rows = await db.query(
      'compute_freshness',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> putComputeFreshness(String key, String payloadJson) async {
    final db = await instance;
    await db.insert('compute_freshness', {
      'key': key,
      'payload_json': payloadJson,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String localDayLabelNow() {
    final now = DateTime.now();
    return _localDayLabel(now);
  }

  static Future<void> refreshComputeFreshness() async {
    final raw = await rawStats();
    final recent = await recentDayResults(30);
    final rolling = await baseline('rolling');
    final cross = await baseline('crossday');
    final today = localDayLabelNow();
    final latestRawTs = (raw['max_rec_ts'] as num?)?.toInt();
    final todayWake = await wakeDayFeatures(today);
    String? latestOvernightDay;
    int? latestOvernightComputedAt;
    String? latestRecoveryDay;
    int? latestRecoveryComputedAt;
    Map<String, dynamic>? todayRow;
    for (final row in recent) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      if (dayId == today && todayRow == null) todayRow = row;
      final payload = row['payload_json'] as String?;
      Map<String, dynamic> decoded = const {};
      if (payload != null && payload.isNotEmpty) {
        try {
          final d = jsonDecode(payload);
          if (d is Map) decoded = d.cast<String, dynamic>();
        } catch (_) {
          decoded = const {};
        }
      }
      if (decoded['skipped'] == true) continue;
      final scalars = ((decoded['scalars'] as Map?) ?? const {})
          .cast<String, dynamic>();
      if (latestOvernightDay == null) {
        final sleep = ((decoded['sleep'] as Map?)?['accounting'] as Map?)?['value'];
        if (sleep is Map && sleep['tst_sec'] != null) {
          latestOvernightDay = dayId;
          latestOvernightComputedAt = (row['computed_at'] as num?)?.toInt();
        }
      }
      if (latestRecoveryDay == null &&
          ((row['readiness'] as num?) != null || scalars['readiness'] is num)) {
        latestRecoveryDay = dayId;
        latestRecoveryComputedAt = (row['computed_at'] as num?)?.toInt();
      }
      if (latestOvernightDay != null && latestRecoveryDay != null && todayRow != null) {
        break;
      }
    }
    final todayComputedAt = (todayRow?['computed_at'] as num?)?.toInt();
    final wakeComputedAt = (todayWake?['computed_at'] as num?)?.toInt();
    final activityReady = todayRow != null || todayWake != null;
    final overnightReady = latestOvernightDay == today;
    final rawReachedToday = latestRawTs != null && _localDayLabelFromEpoch(latestRawTs) == today;
    final activityState = activityReady
        ? 'ready'
        : (rawReachedToday ? 'building' : 'missing');
    final overnightState = overnightReady
        ? 'ready'
        : (rawReachedToday ? 'building' : 'missing');
    await putComputeFreshness(
      'capture',
      jsonEncode({
        'latest_raw_rec_ts': latestRawTs,
        'latest_raw_day': latestRawTs == null ? null : _localDayLabelFromEpoch(latestRawTs),
        'decoded_onehz': raw['decoded_onehz'],
        'decoded_rr': raw['decoded_rr'],
      }),
    );
    await putComputeFreshness(
      'today',
      jsonEncode({
        'today_day': today,
        'activity_day': activityReady ? today : null,
        'activity_state': activityState,
        'activity_computed_at': todayComputedAt ?? wakeComputedAt,
        'overnight_day': latestOvernightDay,
        'overnight_state': overnightState,
        'overnight_computed_at': latestOvernightComputedAt,
        'recovery_day': latestRecoveryDay,
        'recovery_computed_at': latestRecoveryComputedAt,
        'showing_prior_overnight':
            latestOvernightDay != null && latestOvernightDay != today,
      }),
    );
    await putComputeFreshness(
      'crossday',
      jsonEncode({
        'present': cross != null,
        'updated_at': rolling?['updated_at'],
      }),
    );
  }

  static Future<List<Map<String, dynamic>>> computeJobs({
    String? state,
    int limit = 50,
  }) async {
    final db = await instance;
    return db.query(
      'compute_jobs',
      where: state == null ? null : 'state = ?',
      whereArgs: state == null ? null : [state],
      orderBy: 'priority DESC, updated_at ASC',
      limit: limit,
    );
  }

  static Future<void> recoverComputeJobs() async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'compute_jobs',
      {
        'state': 'queued',
        'updated_at': now,
      },
      where: 'state = ?',
      whereArgs: ['running'],
    );
  }

  static Future<void> enqueueDeriveJob({
    required String type,
    required String reason,
  }) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final active = await txn.query(
        'compute_jobs',
        columns: ['id', 'type', 'state'],
        where: 'scope = ? AND state IN (?, ?)',
        whereArgs: ['derive', 'queued', 'running'],
      );
      bool hasType(String t) =>
          active.any((row) => row['type']?.toString() == t);
      if (type == 'derive_light') {
        if (hasType('derive_light') || hasType('derive_heavy')) return;
      } else if (type == 'derive_heavy') {
        if (hasType('derive_heavy')) return;
        await txn.delete(
          'compute_jobs',
          where: 'scope = ? AND state = ? AND type = ?',
          whereArgs: ['derive', 'queued', 'derive_light'],
        );
      }
      await txn.insert('compute_jobs', {
        'id': 'derive_${type}_$now',
        'type': type,
        'scope': 'derive',
        'priority': type == 'derive_heavy' ? 200 : 100,
        'state': 'queued',
        'reason': reason,
        'depends_on': null,
        'input_from_ts': null,
        'input_to_ts': null,
        'algo_version': null,
        'attempts': 0,
        'next_run_at': null,
        'created_at': now,
        'updated_at': now,
      });
    });
  }

  static Future<Map<String, dynamic>?> takeNextComputeJob() async {
    final db = await instance;
    return db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await txn.rawQuery(
        'SELECT * FROM compute_jobs '
        'WHERE state = ? AND (next_run_at IS NULL OR next_run_at <= ?) '
        'ORDER BY priority DESC, updated_at ASC, created_at ASC '
        'LIMIT 1',
        ['queued', now],
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      await txn.update(
        'compute_jobs',
        {
          'state': 'running',
          'attempts': ((row['attempts'] as num?)?.toInt() ?? 0) + 1,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      return {...row, 'state': 'running', 'updated_at': now};
    });
  }

  static Future<void> completeComputeJob(String id) async {
    final db = await instance;
    await db.delete('compute_jobs', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> failComputeJob(String id, String error) async {
    final db = await instance;
    await db.update(
      'compute_jobs',
      {
        'state': 'failed',
        'reason': error,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<Map<String, dynamic>?> sleepSessionCandidate(
    String dayId,
    int algoVersion,
  ) async {
    final db = await instance;
    final rows = await db.query(
      'sleep_session_candidates',
      where: 'day_id = ? AND algo_version = ?',
      whereArgs: [dayId, algoVersion],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> putSleepSessionCandidate({
    required String dayId,
    required int algoVersion,
    required String payloadJson,
  }) async {
    final db = await instance;
    await db.insert('sleep_session_candidates', {
      'day_id': dayId,
      'algo_version': algoVersion,
      'payload_json': payloadJson,
      'computed_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, dynamic>?> wakeDayFeatures(
    String dayId, [
    int? algoVersion,
  ]) async {
    final db = await instance;
    final rows = await db.query(
      'wake_day_features',
      where: algoVersion == null
          ? 'day_id = ?'
          : 'day_id = ? AND algo_version = ?',
      whereArgs: algoVersion == null ? [dayId] : [dayId, algoVersion],
      orderBy: algoVersion == null ? 'algo_version DESC' : null,
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> putWakeDayFeatures({
    required String dayId,
    required int algoVersion,
    required String payloadJson,
  }) async {
    final db = await instance;
    await db.insert('wake_day_features', {
      'day_id': dayId,
      'algo_version': algoVersion,
      'payload_json': payloadJson,
      'computed_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── journal I/O ─────────────────────────────────────────────────────────────

  /// Upsert one day's journal (tags JSON + note). Idempotent on date.
  static Future<void> putJournal(
    String date,
    String tagsJson,
    String note,
  ) async {
    final db = await instance;
    await db.insert('journal', {
      'date': date,
      'tags_json': tagsJson,
      'note': note,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Recent journal rows, newest first. [sinceDaysEpoch] (a YYYY-MM-DD label) is
  /// an optional inclusive lower bound on `date`.
  static Future<List<Map<String, dynamic>>> journalRows({
    String? sinceDaysEpoch,
  }) async {
    final db = await instance;
    if (sinceDaysEpoch != null) {
      return db.query(
        'journal',
        where: 'date >= ?',
        whereArgs: [sinceDaysEpoch],
        orderBy: 'date DESC',
      );
    }
    return db.query('journal', orderBy: 'date DESC');
  }

  // ── cycle log I/O ─────────────────────────────────────────────────────────────

  static Future<void> putCycleLog(
    String date,
    String kind, {
    String? note,
  }) async {
    final db = await instance;
    await db.insert('cycle_log', {
      'date': date,
      'kind': kind,
      'note': note,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteCycleLog(String date) async {
    final db = await instance;
    await db.delete('cycle_log', where: 'date = ?', whereArgs: [date]);
  }

  /// All cycle markers, oldest first.
  static Future<List<Map<String, dynamic>>> cycleLogs() async {
    final db = await instance;
    return db.query('cycle_log', orderBy: 'date ASC');
  }

  // ── sessions (workouts) I/O ────────────────────────────────────────────────

  /// Upsert a workout session row (INSERT OR REPLACE — idempotent on id).
  static Future<void> putSession(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert(
      'sessions',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> session(String id) async {
    final db = await instance;
    final rows = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Sessions whose `start_ts` (epoch SECONDS) is in [fromTs, toTs], newest first.
  static Future<List<Map<String, dynamic>>> sessionsInRange(
    int fromTs,
    int toTs,
  ) async {
    final db = await instance;
    return db.query(
      'sessions',
      where: 'start_ts >= ? AND start_ts <= ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'start_ts DESC',
    );
  }

  static Future<void> deleteSession(String id) async {
    final db = await instance;
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  /// Backfill a session's heart-rate-recovery (bpm), computed retrospectively
  /// from the 1 Hz substrate around the session's end during derivation.
  static Future<void> setSessionHrr(String id, double hrrBpm) async {
    final db = await instance;
    await db.update('sessions', {'hrr_bpm': hrrBpm},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> setSessionType(String id, String type) async {
    final db = await instance;
    await db.update(
      'sessions',
      {'type': type},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── notifications I/O ─────────────────────────────────────────────────────────

  /// Insert a notification (INSERT OR IGNORE — idempotent by id, so the
  /// generator can re-run every derivation pass without duplicating).
  static Future<void> putNotification(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert(
      'notifications',
      row,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// All notifications, newest first.
  static Future<List<Map<String, dynamic>>> notifications() async {
    final db = await instance;
    return db.query('notifications', orderBy: 'created_at DESC');
  }

  /// Mark notifications read (all, or the given [ids]).
  static Future<void> markNotificationsRead({List<String>? ids}) async {
    final db = await instance;
    if (ids == null || ids.isEmpty) {
      await db.update('notifications', {'read': 1});
      return;
    }
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE notifications SET read = 1 WHERE id IN ($placeholders)',
      ids,
    );
  }

  static Future<int> unreadCount() async {
    final db = await instance;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM notifications WHERE read = 0',
          ),
        ) ??
        0;
  }

  // ── raw pruning (raw-first invariant) ───────────────────────────────────────

  /// Delete raw_records / decoded substrate / structured band signals / events whose RECORD TIME (epoch
  /// seconds) is
  /// strictly before [cutoffSec]. Keyed on record time (`rec_ts`/`ts`), NOT
  /// receive time (`captured_at`): retention tracks the DATA, so a multi-day
  /// flash backfill drained in a single sync is never pruned merely for having
  /// just landed. The caller only prunes windows that are FULLY DERIVED — never
  /// prune raw for a day that hasn't been derived yet. Returns rows deleted.
  static Future<int> pruneRawBeforeRecTs(int cutoffSec) async {
    final db = await instance;
    int deleted = 0;
    await db.transaction((txn) async {
      deleted = await txn.delete(
        'raw_records',
        where: 'rec_ts < ?',
        whereArgs: [cutoffSec],
      );
      await txn.delete(
        'decoded_rr',
        where:
            'counter IN (SELECT counter FROM decoded_onehz WHERE rec_ts < ?)',
        whereArgs: [cutoffSec],
      );
      await txn.delete(
        'decoded_onehz',
        where: 'rec_ts < ?',
        whereArgs: [cutoffSec],
      );
      await txn.delete('samples', where: 'ts < ?', whereArgs: [cutoffSec]);
      await txn.delete('events', where: 'ts < ?', whereArgs: [cutoffSec]);
      await txn.delete('band_events', where: 'ts < ?', whereArgs: [cutoffSec]);
      await txn.delete('band_battery', where: 'ts < ?', whereArgs: [cutoffSec]);
    });
    return deleted;
  }

  /// The DATA EDGE — the timestamp (epoch seconds) of the last record we've
  /// actually drained. This, not the wall clock, is "the latest data we have":
  /// the band buffers in flash and drains on sync, so this can lag wall-clock
  /// time by hours/days. Null when there's no raw yet.
  static Future<int?> lastRawRecTs() async {
    final db = await instance;
    return Sqflite.firstIntValue(
      await db.rawQuery('SELECT MAX(rec_ts) FROM raw_records WHERE rec_ts > 0'),
    );
  }
}
