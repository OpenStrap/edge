// Local raw-first storage (SQLite via sqflite).
//
// Durable storage layers:
//   decoded_onehz — canonical per-second decoded substrate, deduped by rec_ts.
//   decoded_rr    — sparse RR beats for that substrate, deduped by (rr_ts_ms, beat_index).
//   samples       — legacy header cache kept only for backward-compat fallback.
//
// `counter` (u32 @[3:7]) is still kept as the strap's record id, but analytics
// read from canonical decoded tables keyed by physiological time so replayed or
// duplicated historical seconds cannot bloat compute.

import 'dart:convert';
import 'dart:io';

import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'day_label.dart';
import 'journal_fields.dart';
import 'live_coverage_policy.dart';
import 'models.dart';

class LocalDb {
  static Database? _db;
  static String dbName = 'openstrap.db';

  static Future<Database> get instance async {
    final db = _db;
    // `_db != null` is NOT enough: Android can close the underlying
    // SQLiteDatabase on background teardown without our close() ever nulling
    // `_db`. A plain `_db ??=` then keeps handing back that dead handle, and
    // every write throws `DatabaseException(attempt to re-open an already-closed
    // object)` — a sustained crash burst (seen in the wild on background event
    // ingest). Reopen whenever the cached handle isn't actually open.
    if (db != null && db.isOpen) return db;
    return _db = await _open();
  }

  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  /// Runs a write against a guaranteed-open handle, reopening ONCE if the
  /// cached handle was closed under us mid-write.
  ///
  /// `instance` validates `isOpen` at acquisition, but Android can tear the
  /// SQLiteDatabase down in the window between acquiring the handle and the
  /// write actually executing (a TOCTOU race — worst on background ingest that
  /// awaits non-DB work, e.g. event parsing, between acquiring `db` and using
  /// it). That surfaced as a sustained `DatabaseException(attempt to re-open an
  /// already-closed object)` burst on the `events` insert (Crashlytics 0.9.13,
  /// processState=BACKGROUND). On that exception we drop the dead handle so the
  /// retry reopens. For best-effort ingest ([bestEffort]) a still-closed DB
  /// after the retry is swallowed — the band re-sends these rows and crashing
  /// the app over a non-durable event write is never the right trade. The
  /// durable sync-commit path leaves it false so a genuine failure still throws
  /// and the HISTORY_END ACK is withheld (safe-trim invariant).
  static Future<T?> _guardedWrite<T>(
    Future<T> Function(Database db) op, {
    bool bestEffort = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      Database? handle;
      try {
        handle = await instance;
        return await op(handle);
      } on DatabaseException catch (e) {
        final closed =
            e.toString().contains('closed') || !(handle?.isOpen ?? false);
        if (closed && attempt == 0) {
          // Drop only the dead handle we actually used. A concurrent caller may
          // have already reopened `_db` to a fresh handle between our failure
          // and here — keep that one so `instance` reuses it on the retry
          // instead of forcing a redundant reopen.
          if (identical(_db, handle)) _db = null;
          continue;
        }
        if (bestEffort && closed) return null;
        rethrow;
      }
    }
    return null;
  }

  /// The live schema version — the ONE place it is declared. Every
  /// `openDatabase` this class performs (the app DB and the day-export DB) must
  /// pass it: sqflite throws `ArgumentError('onCreate must be null if no
  /// version is specified')` BEFORE opening anything when `onCreate` is given
  /// without `version` (sqflite_common database_mixin.dart).
  static const int schemaVersion = 28;

  /// SQLite caps host parameters per statement (`SQLITE_MAX_VARIABLE_NUMBER` —
  /// only 999 on the builds shipped with older Android/iOS). Any `IN (?, ?, …)`
  /// built from row data MUST be chunked below this; a single day of
  /// `decoded_onehz` is 86 400 counters. Same reason `commitSyncBatch` chunks.
  static const int _maxSqlVars = 500;

  /// Split [items] into `_maxSqlVars`-sized chunks for `IN (…)` binding.
  static Iterable<List<T>> _sqlVarChunks<T>(List<T> items) sync* {
    for (var i = 0; i < items.length; i += _maxSqlVars) {
      yield items.sublist(
        i,
        i + _maxSqlVars > items.length ? items.length : i + _maxSqlVars,
      );
    }
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, dbName);
    return openDatabase(
      path,
      onConfigure: (db) async {
        // WRITE PERFORMANCE. The default rollback journal (journal_mode=delete)
        // with synchronous=FULL fsyncs the whole DB on every commit — brutal for
        // the high-volume sync-ingest and the raw re-decode migration on a large
        // ledger. WAL + synchronous=NORMAL is the standard mobile config: writers
        // append to a -wal file and don't block readers, with one fsync per
        // checkpoint instead of per commit. journal_mode is persistent per-file;
        // synchronous/cache_size are per-connection so we set them every open.
        // Durability trade-off under NORMAL: a crash/power-loss can lose only the
        // last uncheckpointed transactions, never corrupt the DB — fine here since
        // raw is re-syncable from the band and derived is recomputable.
        //
        // CRITICAL: a perf PRAGMA must NEVER prevent the DB from opening (a throw
        // here fails openDatabase → the app is stuck on the loading screen). And
        // `PRAGMA journal_mode=WAL` RETURNS A ROW ("wal"), so on the iOS sqflite
        // Darwin backend it MUST be issued via rawQuery — `execute()` on a
        // value-returning pragma throws DatabaseException("not an error") and
        // bricks the open (confirmed on device). So: rawQuery + try/catch.
        try {
          await db.rawQuery('PRAGMA journal_mode=WAL');
        } catch (_) {
          /* keep the default journal — this is a perf tweak, not a requirement */
        }
        try {
          await db.execute('PRAGMA synchronous=NORMAL');
          // ~40 MB page cache (negative = KiB) so hot b-tree pages stay resident
          // on a 150 MB+ DB instead of being re-read from disk each query.
          await db.execute('PRAGMA cache_size=-40000');
        } catch (_) {
          /* non-fatal */
        }
      },
      onCreate: (db, version) async {
        await _createSamples(db);
        await _createDecodedStore(db);
        await db.execute('CREATE INDEX idx_samples_ts ON samples(ts)');
        await _createEvents(db);
        await _createBandSignals(db);
        await _createRawArchive(db);
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
        await _createWorkoutRoute(db);
        await _createNotifFired(db);
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
          // GUARDED add: an oldV <= 2 DB already had raw_records DROPped and
          // re-created by the step-3 block above using the CURRENT `_createRaw`
          // DDL — which already carries rec_ts. A bare ALTER … ADD COLUMN then
          // threw "duplicate column name: rec_ts", and because onUpgrade runs
          // inside ONE exclusive transaction the whole ladder rolled back and
          // openDatabase rethrew → app stuck on the loading screen, forever.
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
          //
          // GUARDED add: an oldV <= 6 DB gets `sessions` from the step-7
          // `_createUserTables` block above, which uses the CURRENT DDL — and
          // that already declares `steps`. A bare ALTER … ADD COLUMN then threw
          // "duplicate column name: steps", rolling back the whole (single,
          // exclusive) onUpgrade transaction so openDatabase rethrew → app
          // permanently stuck on the loading screen.
          await _addColumnIfMissing(db, 'sessions', 'steps', 'INTEGER');
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
          await db.execute(
            "DELETE FROM metric_series WHERE key = 'active_min'",
          );
          await db.execute("DELETE FROM metric_series WHERE key = 'steps'");
        }
        if (oldV < 14) {
          await _createComputeState(db);
        }
        if (oldV < 16) {
          // Historically both the v15 and v16 steps called this (idempotent
          // CREATE IF NOT EXISTS); collapsed into one call — any pre-v16 DB
          // gets the primitive_artifacts table exactly once here.
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
          await _createDecodedStore(db);
          await _backfillDecodedStore(db);
          await _dropRawStore(db);
          await _ensureSessionSchema(db); // adds hrr_bpm
          await _createWorkoutSuggestions(db);
        }
        if (oldV < 20) {
          await _createSleepOverride(db);
        }
        if (oldV < 21) {
          // FIRMWARE RESILIENCE: durable archive of historical records we could
          // NOT decode (unknown/unsupported version). They used to be dropped
          // unseen — lost forever. Now they land in raw_archive (never pruned)
          // so a future firmware's records can be re-decoded. Also add
          // `millivolts` to band_battery for the battery-health series. Both
          // additive.
          await _createRawArchive(db);
          await _ensureBandBatteryMillivolts(db);
        }
        if (oldV < 22) {
          // GPS workout routes (run/ride/walk). Additive, on-device only —
          // never uploaded, never touches derivation output (no kAlgoVersion
          // bump). Pruned with its session.
          await _createWorkoutRoute(db);
        }
        if (oldV < 23) {
          // Additive: per-point smoothed instantaneous speed (m/s), captured
          // for the live speed/pace readout and kept with the point for a
          // future finished-route speed graph. Existing rows get null (no
          // speed was ever recorded for them) — never backfilled/guessed.
          await _ensureWorkoutRouteSpeed(db);
        }
        if (oldV < 24) {
          // day_result rows written by _markDaySkipped (a day whose
          // derivation threw) look identical to a real derived day to
          // anything just checking "is there a row at this algo_version" -
          // which is exactly what the raw-pruning guard does. that let a day
          // that failed to derive get treated as safe-to-prune, deleting its
          // raw substrate for good. this column lets the guard tell the two
          // apart. existing rows default to 0 (not skipped) - can't know in
          // hindsight which old rows were skip markers, but going forward
          // this is right.
          await _ensureDayResultSkippedColumn(db);
        }
        if (oldV < 25) {
          // Same class of bug as `skipped` above, different failure mode: the
          // offloaded second-half day-blocks compute (naps/workouts/HRR/wear/
          // curves/wake-features) can throw or time out AFTER the first-half
          // headline scalars (readiness/RHR/RMSSD) already succeeded. That
          // path is non-fatal by design (the day still gets a real,
          // non-skipped day_result row so headline scalars display), but the
          // raw-pruning guard only excluded `skipped` rows - a headline-only
          // partial row still counted as "derived" and let the raw substrate
          // it would need to fill in those missing blocks get pruned for
          // good. This column lets the guard exclude partial rows too.
          // Existing rows default to 0 (not partial) - can't know in
          // hindsight which old rows were partial, but going forward this is
          // right.
          await _ensureDayResultPartialColumn(db);
        }
        if (oldV < 26) {
          // Cross-isolate fire-once for notifications. The dedupe guard used to
          // live entirely in SharedPreferences, where a check and a record are
          // two separate operations — so the foreground and WorkManager derive
          // isolates could both read "not fired" and both alert (issue #136's
          // tail). This table makes the claim a single atomic INSERT OR IGNORE.
          // Purely additive; the legacy prefs keys are migrated lazily on first
          // use by FiredKeyStore, so nothing is lost on upgrade.
          await _createNotifFired(db);
        }
        if (oldV < 27) {
          // `live_coverage` gains a `source` column so a phone-pedometer count
          // can be told apart from the band's 100 Hz wrist count. Existing rows
          // default to 'band', which is what they are.
          //
          // This matters because the two sources must NEVER be summed: they
          // both count the same walk from different places on the body. The
          // reader prefers phone rows for a day when any exist (a
          // pocket-carried pedometer sees gait; a wrist one confuses arm work
          // for steps), and falls back to band rows otherwise.
          await _ensureLiveCoverageSource(db);
        }
        if (oldV < 28) {
          // The numeric half of a journal entry, plus definitions for
          // user-invented fields. Purely new tables — the existing `journal`
          // row for a day is untouched, so an upgrade loses no tags and no
          // notes, and a day with only tags simply has no metric rows.
          await _createJournalMetric(db);
          await _createJournalFieldDef(db);
        }
      },
      onOpen: (db) async {
        await _repairOpenSchema(db);
      },
      version: schemaVersion,
    );
  }

  static Future<void> _repairOpenSchema(Database db) async {
    // Same-version merged builds can still need additive schema repair on an
    // existing install. Keep this idempotent and cheap: create missing tables,
    // indexes, and additive columns the current code assumes are present.
    await _createSamples(db);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts)',
    );
    await _createEvents(db);
    await _createBandSignals(db);
    await _ensureBandBatteryMillivolts(db);
    await _createRawArchive(db);
    await _createDerived(db);
    await _createDayResult(db);
    await _createUserTables(db);
    await _createSyncState(db);
    await _createSyncCursor(db);
    await _createComputeState(db);
    await _createPrimitiveArtifacts(db);
    await _createDecodedStore(db);
    // Drop leftover DUPLICATE indexes from an old canonical-store rebuild. When
    // `_rebuildCanonicalDecodedStore` renamed `_decoded_*_new` → `decoded_*`, the
    // temp `_new`-named indexes rode along and now shadow the canonical ones on
    // the SAME columns — so every decoded insert (the hottest write path) updated
    // twice as many b-trees as needed. The canonical indexes are (re)created by
    // _createDecodedStore just above; these `_new` duplicates are pure write tax.
    for (final ix in const [
      'idx_decoded_onehz_new_rects',
      'idx_decoded_onehz_new_rec_ts_unique',
      'idx_decoded_rr_new_counter',
      'idx_decoded_rr_new_ts',
      'idx_decoded_rr_new_ts_beat_unique',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $ix');
    }
    await _createLiveCoverage(db);
    await _ensureLiveCoverageSource(db);
    await _createCycleSymptom(db);
    await _ensureSessionSchema(db);
    await _ensureSyncStateSchema(db);
    await _createWorkoutSuggestions(db);
    await _createSleepOverride(db);
    await _createWorkoutRoute(db);
    await _ensureWorkoutRouteSpeed(db);
    await _ensureDayResultSkippedColumn(db);
    await _ensureDayResultPartialColumn(db);
    await _createNotifFired(db);
    // Views LAST — they depend on metric_series / day_result / baselines / sessions
    // / notifications all existing. DROP+CREATE so a shape change takes effect.
    await _ensureCoachViews(db);
    await _dropRawStore(db);
  }

  /// The column names [table] currently has (empty if the table is absent).
  static Future<Set<String>> _columnsOf(Database db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return {
      for (final c in info)
        if (c['name'] is String) c['name'] as String,
    };
  }

  /// THE ONLY sanctioned way to add a column in a migration step.
  ///
  /// A bare `ALTER TABLE … ADD COLUMN` in the ladder is a latent brick: the
  /// `_create*` helpers are MODERNIZED IN PLACE (they always emit the current
  /// DDL), so any DB old enough to have a table created by a LATER-numbered
  /// step already has the column an EARLIER-numbered ALTER tries to add. That
  /// throws "duplicate column name", and since `onUpgrade` runs inside ONE
  /// exclusive transaction the entire ladder rolls back and `openDatabase`
  /// rethrows — the app is stuck on the loading screen on EVERY launch, with no
  /// way out. Check first; swallow a lost race (SQLite does statement-level
  /// rollback, so a caught failure never poisons the surrounding transaction).
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String ddlType,
  ) async {
    if ((await _columnsOf(db, table)).contains(column)) return;
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $ddlType');
    } catch (_) {
      /* another opener won the race — the column exists now */
    }
  }

  static Future<void> _ensureDayResultSkippedColumn(Database db) =>
      _addColumnIfMissing(
        db,
        'day_result',
        'skipped',
        'INTEGER NOT NULL DEFAULT 0',
      );

  static Future<void> _ensureDayResultPartialColumn(Database db) =>
      _addColumnIfMissing(
        db,
        'day_result',
        'partial',
        'INTEGER NOT NULL DEFAULT 0',
      );

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
    String date,
    List<String> symptoms, {
    String? note,
  }) async {
    final db = await instance;
    if (symptoms.isEmpty && (note == null || note.isEmpty)) {
      await db.delete('cycle_symptom', where: 'date = ?', whereArgs: [date]);
      return;
    }
    await db.insert('cycle_symptom', {
      'date': date,
      'symptoms_json': jsonEncode(symptoms),
      'note': note,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
  static Future<void> _createSyncCursor(DatabaseExecutor db) async {
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
  /// The cross-isolate fire-once claim ledger for notification dedupeKeys.
  ///
  /// SharedPreferences CANNOT enforce fire-once across isolates, however fresh
  /// its reads: a check and a record are two independent operations, so the
  /// foreground derive isolate and the WorkManager background derive isolate
  /// can both read "not fired" before either writes, and both alert. SQLite
  /// can: `INSERT OR IGNORE` against a PRIMARY KEY is ONE atomic statement, and
  /// writers are serialised (a single native handle per process, and SQLite's
  /// own write lock across handles), so for a given key exactly one caller ever
  /// observes `changes() == 1`. That caller owns the fire; everyone else backs
  /// off. See [claimNotifFired] and lib/notify/fired_keys.dart.
  static Future<void> _createNotifFired(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notif_fired (
        key TEXT PRIMARY KEY,
        fired_at INTEGER NOT NULL
      )
    ''');
  }

  /// Atomically claim [key] for a one-time OS notification fire.
  ///
  /// Returns true iff THIS caller won the claim (the row did not exist and we
  /// inserted it). A concurrent claimant — in this isolate or the other
  /// derivation isolate — gets false and MUST NOT present.
  ///
  /// Throws if the claim can't be decided, deliberately: the caller falls back
  /// to the best-effort store rather than treating an unusable DB as "already
  /// fired", which would silently swallow every notification on the device.
  static Future<bool> claimNotifFired(String key, {int? firedAtMs}) async {
    final now = firedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    final won = await _guardedWrite<bool>((db) async {
      return db.transaction<bool>((txn) async {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO notif_fired(key, fired_at) VALUES(?, ?)',
          [key, now],
        );
        // changes() reports rows touched by the statement just executed on this
        // connection; inside the transaction that is unambiguously our INSERT.
        final n = Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()'));
        return n == 1;
      });
    });
    if (won == null) throw StateError('notif_fired: claim undecided');
    return won;
  }

  /// Give back a claim taken by [claimNotifFired] — used when the present did
  /// NOT actually happen (permission denied, OS error), so a later attempt can
  /// still fire. Best-effort: never throws into the notification path.
  static Future<void> releaseNotifFired(String key) async {
    await _guardedWrite<int>(
      (db) => db.delete('notif_fired', where: 'key = ?', whereArgs: [key]),
      bestEffort: true,
    );
  }

  /// Whether [key] has already been claimed (read-only; does not claim).
  static Future<bool> notifFiredExists(String key) async {
    final db = await instance;
    final rows = await db.query(
      'notif_fired',
      columns: ['key'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Seed claims for [keys] without taking ownership — used once to carry the
  /// legacy SharedPreferences fired-key list over, so keys that already fired
  /// under the old store don't re-fire on the upgrade.
  static Future<void> seedNotifFired(
    Iterable<String> keys, {
    int? firedAtMs,
  }) async {
    if (keys.isEmpty) return;
    final now = firedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    await _guardedWrite<void>((db) async {
      final batch = db.batch();
      for (final k in keys) {
        batch.rawInsert(
          'INSERT OR IGNORE INTO notif_fired(key, fired_at) VALUES(?, ?)',
          [k, now],
        );
      }
      await batch.commit(noResult: true);
    }, bestEffort: true);
  }

  /// Drop dated claims whose leading "YYYY-MM-DD" is before [cutoffDate].
  ///
  /// Undated keys (e.g. `alarm_fired:<epoch>`) are left alone: they have no day
  /// to expire against, and they're rare enough to be self-limiting. Matches
  /// the retention semantics of the SharedPreferences fallback exactly.
  static Future<void> pruneNotifFired(String cutoffDate) async {
    await _guardedWrite<int>(
      (db) => db.rawDelete(
        "DELETE FROM notif_fired "
        "WHERE substr(key, 1, 10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "
        "AND substr(key, 1, 10) < ?",
        [cutoffDate],
      ),
      bestEffort: true,
    );
  }

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
    await db.insert('sleep_override', {
      'day_id': dayId,
      'onset_ts': onsetTs,
      'offset_ts': offsetTs,
      'source': source,
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The user's sleep window for [dayId], or null if none.
  static Future<Map<String, dynamic>?> getSleepOverride(String dayId) async {
    final db = await instance;
    final rows = await db.query(
      'sleep_override',
      where: 'day_id = ?',
      whereArgs: [dayId],
      limit: 1,
    );
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
  //
  // HISTORICAL ROWS. Databases written before the window derivation was fixed
  // contain ZERO-WIDTH rows (`end_ts == start_ts`) — the old writer took both
  // ends from a band record timestamp that does not advance during a live
  // session. They are left as they are: their real durations were never
  // recorded, and widening them after the fact would replace one wrong extent
  // with another while silently changing already-derived days. Readers must
  // tolerate them — `coverageWindowsOverlapping` matches them (`end_ts >= lo`)
  // and the derivation's minute test (`s + 60 > start && s < end`) still
  // excludes the minute containing the row, so such a row under-excludes but
  // never crashes or double-adds its steps.
  static Future<void> _createLiveCoverage(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS live_coverage (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        steps INTEGER NOT NULL,
        day TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT '$kStepSourceBand'
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_live_coverage_day ON live_coverage(day)',
    );
  }

  /// Ensure `live_coverage.source` exists (v27).
  ///
  /// Uses the shared guarded helper — an unguarded ALTER TABLE on an
  /// already-migrated db bricks the upgrade (that has bitten this file twice).
  static Future<void> _ensureLiveCoverageSource(Database db) async {
    await _addColumnIfMissing(
      db,
      'live_coverage',
      'source',
      "TEXT NOT NULL DEFAULT '$kStepSourceBand'",
    );
  }

  /// Step-count provenance for a `live_coverage` row.
  ///
  /// These are never summed together — see [liveStepsForDay].
  static const String kStepSourceBand = 'band'; // band 100 Hz AN-2554 (wrist)
  static const String kStepSourcePhone = 'phone'; // phone pedometer (pocket)

  /// Record a real 100 Hz step window (device-time seconds) + its step count.
  ///
  /// The window is normalised by [sanitizeCoverageWindow] first: a zero-width
  /// window that claims steps is REPAIRED (widened to the duration those steps
  /// physically imply) rather than dropped, because dropping it would lose a
  /// real 100 Hz count; an inverted window is rejected. See that function for
  /// the reasoning. This is a guard, not the derivation — the caller is
  /// expected to have measured a real window (see
  /// `deriveLiveCoverageWindow`); it exists so an upstream regression cannot
  /// silently reintroduce degenerate rows.
  static Future<void> addLiveCoverage(
    int startTs,
    int endTs,
    int steps,
    String day, {
    String source = kStepSourceBand,
  }) async {
    final w = sanitizeCoverageWindow(startTs, endTs, steps);
    if (w == null) return;
    final db = await instance;
    await db.insert('live_coverage', {
      'start_ts': w.startTs,
      'end_ts': w.endTs,
      'steps': steps,
      'day': day,
      'source': source,
    });
  }

  /// Replace ALL phone-pedometer rows for [day] with [windows], atomically.
  ///
  /// Phone step data is a re-readable snapshot, not an append-only stream: the
  /// same day can be synced repeatedly as it fills in. So the phone sync is
  /// delete-then-insert scoped to `source = 'phone'`, which is idempotent by
  /// construction and needs no window-clipping. Band rows are untouched.
  static Future<void> replacePhoneCoverageForDay(
    String day,
    List<({int startTs, int endTs, int steps})> windows,
  ) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete(
        'live_coverage',
        where: 'day = ? AND source = ?',
        whereArgs: [day, kStepSourcePhone],
      );
      for (final w in windows) {
        if (w.steps <= 0 || w.endTs <= w.startTs) continue;
        await txn.insert('live_coverage', {
          'start_ts': w.startTs,
          'end_ts': w.endTs,
          'steps': w.steps,
          'day': day,
          'source': kStepSourcePhone,
        });
      }
    });
  }

  /// True when a coverage row for exactly this window already exists.
  ///
  /// `live_coverage` is an append-only SUM (no uniqueness on the window), so a
  /// replayed write double-counts the day's real steps. The orphaned-session
  /// recovery uses this to stay idempotent: a process killed AFTER
  /// `_finalizeLivePedometer` wrote coverage but BEFORE it cleared the
  /// checkpoint would otherwise re-add the same bout on the next launch.
  static Future<bool> hasLiveCoverageWindow(int startTs, int endTs) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT 1 FROM live_coverage WHERE start_ts = ? AND end_ts = ? LIMIT 1',
      [startTs, endTs],
    );
    return r.isNotEmpty;
  }

  /// Phone-sourced steps already banked for [day].
  ///
  /// Used by the pedometer sync to tell "this day really had no steps" from
  /// "this read came back empty" before it replaces a day wholesale — see
  /// [replacePhoneCoverageForDay], which is delete-then-insert.
  ///
  /// Also the UI's source discriminator: it is the same quantity
  /// [liveStepsForDay] tests to decide which source owns the day, so a screen
  /// can ask "did the phone actually cover today?" instead of approximating it
  /// with "is the toggle on". Those differ exactly when the toggle is on and
  /// the phone has no data, where the band still owns the day.
  static Future<int> phoneStepsForDay(String day) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(steps),0) s FROM live_coverage '
      'WHERE day = ? AND source = ?',
      [day, kStepSourcePhone],
    );
    return (r.first['s'] as num?)?.toInt() ?? 0;
  }

  /// Drop every phone-sourced coverage row (the user turned phone steps off).
  /// Band rows are untouched, so days fall back to the band count.
  static Future<int> clearPhoneCoverage() async {
    final db = await instance;
    return db.delete(
      'live_coverage',
      where: 'source = ?',
      whereArgs: [kStepSourcePhone],
    );
  }

  /// Real pedometer steps attributed to [day], from ONE source.
  ///
  /// Phone and band counts are never added together: both count the same walk,
  /// one from the pocket and one from the wrist, so summing them roughly
  /// doubles a day. When the phone has any data for the day it wins outright —
  /// a pocket/waist pedometer observes trunk motion (real gait), whereas a
  /// wrist one is documented emitting 22-27 false steps/min during dishes,
  /// reaching and driving while missing slow walking (O'Connell 2017,
  /// doi:10.1371/journal.pone.0169616). Band rows are the fallback.
  static Future<int> liveStepsForDay(String day) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT source, COALESCE(SUM(steps),0) s FROM live_coverage '
      'WHERE day = ? GROUP BY source',
      [day],
    );
    var band = 0;
    var phone = 0;
    for (final row in r) {
      final n = (row['s'] as num?)?.toInt() ?? 0;
      if (row['source'] == kStepSourcePhone) {
        phone += n;
      } else {
        band += n;
      }
    }
    return phone > 0 ? phone : band;
  }

  /// Coverage windows ([startSec, endSec]) overlapping [loSec, hiSec), for ONE
  /// [source] (band by default).
  ///
  /// The 1 Hz-estimate exclusion this originally served is gone along with the
  /// estimator. Its only remaining caller is the NOOP importer, which reads back
  /// the spans it has already banked so `stepRuns` can clip them out and a
  /// re-import over an overlapping span cannot double-count.
  ///
  /// THE SOURCE FILTER IS LOAD-BEARING for that caller. Phone-pedometer rows now
  /// share this table and cover the same wall-clock hours, so an unfiltered read
  /// let a user with phone steps enabled import a NOOP backup whose BAND step
  /// runs were clipped against the PHONE's windows and silently dropped — the
  /// import reporting success while banking nothing for those days. Band clips
  /// against band. Phone coverage needs no clipping at all: it is replaced
  /// wholesale per day (see [replacePhoneCoverageForDay]).
  static Future<List<List<int>>> coverageWindowsOverlapping(
    int loSec,
    int hiSec, {
    String source = kStepSourceBand,
  }) async {
    final db = await instance;
    final rows = await db.query(
      'live_coverage',
      where: 'end_ts >= ? AND start_ts < ? AND source = ?',
      whereArgs: [loSec, hiSec, source],
    );
    return [
      for (final r in rows)
        [(r['start_ts'] as num).toInt(), (r['end_ts'] as num).toInt()],
    ];
  }

  /// Spans ([startSec, endSec]) in [loSec, hiSec) during which the band was NOT
  /// on the wrist, from the strap's own WRIST_OFF/WRIST_ON events.
  ///
  /// A band sitting on a table is PERFECTLY still and reads as deep rest to any
  /// motion-based detector — it is the dominant nap false positive. The strap
  /// already tells us; these events have been decoded and persisted all along,
  /// and `AdvancedSleepStager.detectSleep` has always accepted a `wristOff`
  /// argument, but nothing ever supplied one.
  ///
  /// State is carried in from BEFORE [loSec] so a window that opens mid-removal
  /// is still covered, and an unterminated removal extends to [hiSec] rather
  /// than being dropped (absent evidence of return is not evidence of return).
  static Future<List<List<int>>> wristOffSpans(int loSec, int hiSec) =>
      _toggleSpans(
        loSec,
        hiSec,
        onId: proto.EventId.wristOn,
        offId: proto.EventId.wristOff,
      );

  /// Spans ([startSec, endSec]) in [loSec, hiSec) during which the band was on
  /// the charger — off-wrist by definition, and motionless.
  static Future<List<List<int>>> chargingSpans(int loSec, int hiSec) =>
      _toggleSpans(
        loSec,
        hiSec,
        onId: proto.EventId.chargingOff,
        offId: proto.EventId.chargingOn,
      );

  /// Build "state active" spans from a pair of toggle events, clipped to
  /// [loSec, hiSec). [offId] opens a span; [onId] closes it.
  static Future<List<List<int>>> _toggleSpans(
    int loSec,
    int hiSec, {
    required int onId,
    required int offId,
  }) async {
    if (hiSec <= loSec) return const [];
    final db = await instance;
    // One row before the window establishes the state we open in.
    final prior = await db.query(
      'band_events',
      columns: ['ts', 'event_id'],
      where: 'ts < ? AND event_id IN (?, ?)',
      whereArgs: [loSec, onId, offId],
      orderBy: 'ts DESC',
      limit: 1,
    );
    final rows = await db.query(
      'band_events',
      columns: ['ts', 'event_id'],
      where: 'ts >= ? AND ts < ? AND event_id IN (?, ?)',
      whereArgs: [loSec, hiSec, onId, offId],
      orderBy: 'ts ASC',
    );

    final spans = <List<int>>[];
    int? openAt =
        (prior.isNotEmpty && (prior.first['event_id'] as num).toInt() == offId)
            ? loSec
            : null;
    for (final r in rows) {
      final ts = (r['ts'] as num).toInt();
      final id = (r['event_id'] as num).toInt();
      if (id == offId) {
        openAt ??= ts;
      } else if (openAt != null) {
        if (ts > openAt) spans.add([openAt, ts]);
        openAt = null;
      }
    }
    if (openAt != null && hiSec > openAt) spans.add([openAt, hiSec]);
    return spans;
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

  /// Cursor holding the FROZEN morning readiness headline (see #128): the
  /// day-tagged value pinned once today's overnight first settles on a genuinely
  /// complete night, so the Today hero + recovery story stop drifting through
  /// the day. Day-tagged so it survives restarts and is ignored on a new day.
  static const String kFrozenHeadlineCursor = 'frozen_headline';

  /// The pinned morning readiness headline (day + value), or null if unset /
  /// unparseable. The `day` must be compared to today's label by the caller — a
  /// pin left over from a previous day must NOT be surfaced.
  static Future<({String day, int value})?> frozenHeadline() async {
    final raw = await getCursor(kFrozenHeadlineCursor);
    if (raw == null || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is Map && d['day'] is String && d['value'] is num) {
        return (day: d['day'] as String, value: (d['value'] as num).round());
      }
    } catch (_) {/* malformed → treat as unset */}
    return null;
  }

  /// Pin [value] as the frozen readiness headline for [day] (overwrites any
  /// prior pin — first-complete-settle-per-day is enforced by the caller).
  static Future<void> setFrozenHeadline(String day, int value) =>
      setCursor(kFrozenHeadlineCursor, jsonEncode({'day': day, 'value': value}));

  /// Persist a sync batch atomically: the raw records, their samples, AND the
  /// continuation cursor in ONE transaction. This is the durable half of the
  /// safe-trim invariant — it MUST return before the engine writes the ACK frame.
  /// Advances counter_hw / rec_ts_hw to the batch max so a restart resumes cleanly.
  ///
  /// [onCheckpoint], if given, is called synchronously at each of the three
  /// phases (decoded+archive queued, decoded+archive committed, cursor
  /// advanced) — field diagnosability without giving up the single-txn
  /// atomicity: the checkpoint calls are pure logging, wrapped so a
  /// misbehaving callback can never abort a real commit. db.dart itself stays
  /// logging-framework-free (no Flutter dependency); callers pass their own
  /// logger (e.g. ble_engine.dart's `_log`, background_sync.dart's `debugPrint`).
  static Future<void> commitSyncBatch(
    List<RawRecord> raws,
    List<Sample?> samples, {
    String? trimToken,
    Map<String, String>? extraCursors,
    List<ArchiveRecord>? archives,
    void Function(String)? onCheckpoint,
  }) async {
    void checkpoint(String msg) {
      try {
        onCheckpoint?.call(msg);
      } catch (_) {
        /* a logging callback must never affect the commit */
      }
    }

    final db = await instance;
    await db.transaction((txn) async {
      // Read the existing high-water THROUGH the txn — never via the global db
      // handle, which would deadlock against this same open transaction.
      var maxCounter = await _cursorIntVia(txn, 'counter_hw') ?? 0;
      var maxRecTs = await _cursorIntVia(txn, 'rec_ts_hw') ?? 0;
      // CHUNKED BATCH: sqflite serialises an ENTIRE batch's operations+args into
      // ONE platform-channel message, and the native side builds a single
      // ArrayList of every argument. A large backlog offload (raws in the
      // hundreds-of-thousands) blew the native heap in SqlCommand.getSqlArguments
      // → OutOfMemoryError (Crashlytics 0.9.13). Committing in bounded chunks
      // flushes and frees each message's args. These commits all happen INSIDE
      // the single `db.transaction` below, so the safe-trim invariant holds: the
      // whole offload (raw_archive + samples + decoded_onehz + decoded_rr +
      // cursor) is still one atomic transaction — every row is durable before the
      // caller echoes the HISTORY_END trim token, or none is.
      const chunkOps = 4000;
      var batch = txn.batch();
      var ops = 0;
      Future<void> flushChunk() async {
        if (ops == 0) return;
        await batch.commit(noResult: true);
        batch = txn.batch();
        ops = 0;
      }

      // SAFE-TRIM INVARIANT: archive the undecodable records in the SAME
      // transaction as the raw records + trim cursor, so they are durably set
      // aside BEFORE the caller writes the batch-ACK that lets the band trim.
      if (archives != null) {
        for (final a in archives) {
          batch.insert('raw_archive', {
            'counter': a.counter,
            'hex': a.hex,
            'packet_type': a.packetType,
            'rec_ts': a.recTs,
            'captured_at': a.capturedAt,
            'reason': a.reason,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          if (++ops >= chunkOps) await flushChunk();
        }
      }
      for (var i = 0; i < raws.length; i++) {
        final raw = raws[i];
        final recTs = _recTsFor(raw);
        final sample = samples[i];
        if (sample != null) {
          batch.insert('samples', {
            'counter': raw.counter,
            ...sample.toDbMap(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          ops++;
        }
        ops += _queueDecodedOneHz(batch, raw, sample);
        if (raw.counter > maxCounter) maxCounter = raw.counter;
        if (recTs > maxRecTs) maxRecTs = recTs;
        if (ops >= chunkOps) await flushChunk();
      }
      checkpoint(
        'decoded_archive_queued raws=${raws.length} '
        'archives=${archives?.length ?? 0}',
      );
      await flushChunk();
      checkpoint('decoded_archive_committed');
      await setCursor('counter_hw', '$maxCounter', txn: txn);
      await setCursor('rec_ts_hw', '$maxRecTs', txn: txn);
      if (trimToken != null) await setCursor('strap_trim', trimToken, txn: txn);
      if (extraCursors != null) {
        for (final e in extraCursors.entries) {
          await setCursor(e.key, e.value, txn: txn);
        }
      }
      checkpoint(
        'cursor_advanced counter_hw=$maxCounter rec_ts_hw=$maxRecTs '
        'trim=${trimToken != null}',
      );
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
        skipped INTEGER NOT NULL DEFAULT 0,
        partial INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day_id, algo_version)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_day_result_day ON day_result(day_id, algo_version)',
    );
  }

  /// journal_metric — the numeric half of a journal entry.
  ///
  /// The `journal` table holds a tag set and a note, which can only ever
  /// answer "did this happen today". A field that carries a NUMBER — three
  /// coffees, 700 ml of water, mood 4 out of 5 — carries a dose, and that is
  /// usually the actual question. Kept in its own table rather than as columns
  /// on `journal` so a user-defined field costs a row, not a migration.
  ///
  /// One row per (day, field): the value is the day's TOTAL for a dose-like
  /// field and the day's single reading for a rating.
  ///
  /// `at_min` is local minutes past midnight for the LATEST occurrence, and is
  /// null for anything without a meaningful time. It exists because when a
  /// dose landed can matter more than its size — the sleep-relevant fact about
  /// caffeine is the last cup, not the total.
  static Future<void> _createJournalMetric(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_metric (
        date TEXT NOT NULL,
        field TEXT NOT NULL,
        value REAL NOT NULL,
        at_min INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (date, field)
      )
    ''');
    // Correlations read one field across every day, so the index is on the
    // field first — the primary key already covers day-scoped reads.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_journal_metric_field '
      'ON journal_metric(field, date)',
    );
  }

  /// journal_field_def — definitions for USER-INVENTED numeric fields only.
  ///
  /// Built-in fields live in `lib/data/journal_fields.dart` as code, because a
  /// definition that ships with the app should not be editable data. A custom
  /// field has nowhere else to record what its number means, and without a
  /// unit and a ceiling its values render as bare numbers and its entry has no
  /// bounds — so it gets a row.
  ///
  /// Deleting a definition deliberately does NOT delete its history: those
  /// readings were still real. They render unlabelled until the field is
  /// defined again.
  static Future<void> _createJournalFieldDef(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_field_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        kind TEXT NOT NULL,
        unit TEXT NOT NULL DEFAULT '',
        max_value REAL NOT NULL,
        step REAL NOT NULL,
        has_time INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
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
    await _createJournalMetric(db);
    await _createJournalFieldDef(db);
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

  static Future<void> _createSyncState(DatabaseExecutor db) async {
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

  static Future<void> _dropRawStore(Database db) async {
    await db.execute('DROP TABLE IF EXISTS raw_records');
  }

  static Future<void> _ensureSessionSchema(Database db) async {
    await _addColumnIfMissing(db, 'sessions', 'steps', 'INTEGER');
    await _addColumnIfMissing(db, 'sessions', 'hrr_bpm', 'REAL');
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
    await db.insert(
      'workout_suggestions',
      row,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Active (not-yet-dismissed, not-yet-confirmed) suggestions, newest first.
  static Future<List<Map<String, dynamic>>> activeWorkoutSuggestions() async {
    final db = await instance;
    return db.query(
      'workout_suggestions',
      where: 'dismissed = 0',
      orderBy: 'start_ts DESC',
    );
  }

  static Future<void> dismissWorkoutSuggestion(String id) async {
    final db = await instance;
    await db.update(
      'workout_suggestions',
      {'dismissed': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
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
    // Workouts (incl. HRR + steps). `date` is the session's LOCAL calendar day
    // (device-local, same 'localtime' pattern as dataHistoryDays()) — added so
    // "today's workout" can be resolved with `WHERE date = 'YYYY-MM-DD'`
    // instead of the coach having to convert a local day back into a raw
    // start_ts/end_ts epoch range itself, which silently drifted to UTC
    // (issue #129: coach mis-dated workouts near local-midnight boundaries).
    await db.execute('''
      CREATE VIEW v_sessions AS
      SELECT id, start_ts, end_ts,
             strftime('%Y-%m-%d', start_ts, 'unixepoch', 'localtime') AS date,
             type, status, calories, strain, max_hr,
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

  /// Run a rename → recreate → copy legacy-shape migration ATOMICALLY and
  /// IDEMPOTENTLY.
  ///
  /// The three callers below used to do `ALTER … RENAME`, then `CREATE`, then a
  /// row-by-row copy, then `DROP` — all OUTSIDE any transaction. That is fine
  /// under `onUpgrade` (sqflite wraps the whole ladder in one exclusive txn) but
  /// these also run from `_repairOpenSchema` in `onOpen`, which is NOT wrapped.
  /// A crash / OS kill between the rename and the end of the copy left
  /// `<table>` present AND correctly shaped, so the next open hit the
  /// "already current" early-return and `<table>_legacy` sat there orphaned with
  /// its rows never migrated — losing `strap_trim` / `counter_hw` / `rec_ts_hw`,
  /// i.e. the whole resumable-sync cursor and the safe-trim high-water.
  ///
  /// Now: one transaction — which sqflite JOINS to the already-open `onUpgrade`
  /// transaction when called from the ladder, and opens for real from `onOpen`
  /// — plus an explicit RESUME of an orphan left behind by any older build.
  ///
  /// [isCurrent] decides whether an existing `<table>` is already the new shape.
  /// [copy] must be idempotent (INSERT OR REPLACE on a natural key); set
  /// [copyOnlyIntoEmpty] for a destination with no natural key (autoincrement
  /// id), where re-running a resume would otherwise duplicate rows.
  static Future<void> _migrateLegacyTable(
    Database db, {
    required String table,
    required bool Function(Set<String> columns) isCurrent,
    required Future<void> Function(DatabaseExecutor ex) create,
    required Future<void> Function(
      DatabaseExecutor ex,
      List<Map<String, Object?>> legacyRows,
      int nowMs,
    )
    copy,
    bool copyOnlyIntoEmpty = false,
  }) async {
    final legacy = '${table}_legacy';
    await db.transaction((txn) async {
      Future<bool> exists(String t) async =>
          (await txn.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [t],
          )).isNotEmpty;
      Future<Set<String>> columnsOf(String t) async {
        final info = await txn.rawQuery('PRAGMA table_info($t)');
        return {
          for (final c in info)
            if (c['name'] is String) c['name'] as String,
        };
      }

      if (!await exists(legacy)) {
        // Normal path.
        if (!await exists(table)) {
          await create(txn);
          return;
        }
        if (isCurrent(await columnsOf(table))) return;
        await txn.execute('ALTER TABLE $table RENAME TO $legacy');
      }
      // From here on `<table>_legacy` holds the rows of record. `<table>` is
      // either absent (crash between RENAME and CREATE) or the new shape
      // (possibly half-copied, or fully copied by an older build that then
      // died before the DROP) — create it if needed and re-copy; the copy is
      // idempotent, so a repeat is a no-op rather than a duplication.
      if (!await exists(table)) await create(txn);
      final skipCopy =
          copyOnlyIntoEmpty &&
          (Sqflite.firstIntValue(
                await txn.rawQuery('SELECT COUNT(*) FROM $table'),
              ) ??
              0) >
              0;
      if (!skipCopy) {
        await copy(
          txn,
          await txn.query(legacy),
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      await txn.execute('DROP TABLE $legacy');
    });
  }

  static Future<void> _ensureSyncCursorSchema(Database db) =>
      _migrateLegacyTable(
        db,
        table: 'sync_cursor',
        isCurrent: (c) =>
            c.contains('name') &&
            c.contains('value') &&
            c.contains('updated_at'),
        create: _createSyncCursor,
        copy: (ex, legacyRows, now) async {
          for (final row in legacyRows) {
            final name = row['name'] as String?;
            if (name == null || name.isEmpty) continue;
            await ex.insert('sync_cursor', {
              'name': name,
              'value': row['value']?.toString(),
              'updated_at': (row['updated_at'] as num?)?.toInt() ?? now,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        },
      );

  static Future<void> _ensureSyncLedgerSchema(Database db) => _migrateLegacyTable(
    db,
    table: 'sync_ledger',
    isCurrent: (c) => c.contains('chunk_id'),
    create: _createSyncState,
    copy: (ex, legacyRows, now) async {
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
        await ex.insert('sync_ledger', {
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
    },
  );

  static Future<void> _ensureSyncQuarantineSchema(Database db) =>
      _migrateLegacyTable(
        db,
        table: 'sync_quarantine',
        isCurrent: (c) => c.contains('payload_json'),
        create: _createSyncState,
        // `id INTEGER PRIMARY KEY AUTOINCREMENT` — no natural key to REPLACE
        // on, so a resume must not re-copy into a destination that already has
        // rows or the quarantine log would double on every retry.
        copyOnlyIntoEmpty: true,
        copy: (ex, legacyRows, now) async {
          for (final row in legacyRows) {
            await ex.insert('sync_quarantine', {
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
        },
      );

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
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_decoded_rr_ts_beat_unique '
      'ON decoded_rr(rr_ts_ms, beat_index)',
    );
    // idx_decoded_rr_ts(rr_ts_ms) was a strict prefix of the unique index
    // above, so SQLite could already serve every rr_ts_ms lookup and ordering
    // from it. The narrower index only added a second b-tree to maintain on
    // the hottest write path in the app.
    await db.execute('DROP INDEX IF EXISTS idx_decoded_rr_ts');
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
  /// GUARDED (see [_addColumnIfMissing]): the step-3 rebuild already creates
  /// raw_records from the CURRENT `_createRaw` DDL, which carries rec_ts — so on
  /// an oldV <= 2 upgrade this column is already there.
  static Future<void> _addRecTsColumn(Database db) => _addColumnIfMissing(
    db,
    'raw_records',
    'rec_ts',
    'INTEGER NOT NULL DEFAULT 0',
  );

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

  // Canonical LOCAL day label — shared with the UI/coach via day_label.dart so
  // every layer computes "today" identically (never in UTC).
  static String _localDayLabel(DateTime dt) => dayLabelOf(dt);

  static String _localDayLabelFromEpoch(int epochSec) =>
      _localDayLabel(DateTime.fromMillisecondsSinceEpoch(epochSec * 1000));

  static Sample? _decodeOneHzSample(RawRecord raw, {Sample? preferred}) {
    if (preferred != null && preferred.hasDecodedOneHz) return preferred;
    try {
      // Legacy decoder first, firmware-fallback chain second — see
      // FirmwareAwareR24Decoder. This path only runs when no pre-decoded
      // `preferred` sample was supplied (e.g. a raw-hex import/merge), so a
      // fresh per-call instance is fine — no session state to preserve.
      final r = proto.FirmwareAwareR24Decoder().decode(
        proto.hexToBytes(raw.hex),
      );
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

  /// THE orphan guard for an INSERT-OR-REPLACE into `decoded_onehz`.
  ///
  /// Queue this onto [batch] IMMEDIATELY BEFORE writing the row for [counter] @
  /// [recTs] — every write path into `decoded_onehz` must go through it, or it
  /// strands `decoded_rr` beats (see [_queueDecodedOneHz] for the full
  /// derivation of both eviction cases). Returns the number of ops queued.
  static int _queueOrphanGuard(
    Batch batch, {
    required int counter,
    required int recTs,
  }) {
    batch.rawDelete(
      'DELETE FROM decoded_rr WHERE '
      // (a) UNIQUE(rec_ts) eviction — the LOSER counter's beats.
      'counter IN '
      '(SELECT counter FROM decoded_onehz WHERE rec_ts = ? AND counter != ?) '
      // (b) counter-PK eviction — stale-timestamped beats under OUR counter.
      'OR (counter = ? AND rr_ts_ms != ?)',
      [recTs, counter, counter, recTs * 1000],
    );
    return 1;
  }

  /// Queues the decoded_onehz + decoded_rr (+ orphan-guard delete) writes for
  /// one raw onto [batch]. Returns the number of batch operations added, so a
  /// caller committing a large offload can chunk the batch to bound the native
  /// argument-list size (see [commitSyncBatch]).
  static int _queueDecodedOneHz(Batch batch, RawRecord raw, Sample? sample) {
    final decoded = _decodeOneHzSample(raw, preferred: sample);
    if (decoded == null) return 0;
    final recTs = raw.recTs ?? decoded.tsEpoch;
    // TIME-KEYED, NEWEST-WINS (noop/WHOOP-4 model: dedupe records by their
    // embedded timestamp, not by a counter). decoded_onehz has a UNIQUE(rec_ts)
    // index and decoded_rr a UNIQUE(rr_ts_ms, beat_index). We use REPLACE, not
    // IGNORE: the strap's record `counter` RESETS to ~0 on every reboot, so a
    // post-reboot record whose second already had a row would be SILENTLY DROPPED
    // under IGNORE — quarantining everything after a reboot (observed: whole days
    // present in raw_records but absent from the decoded substrate the engine
    // reads → "not worn / metrics still computing / strain –"). REPLACE lets the
    // freshly-offloaded record for a given second win, which is what we want.
    //
    // ORPHAN GUARD: decoded_rr rows are keyed by their record's own counter. When
    // the REPLACE below evicts a DIFFERENT counter's row for this second, that
    // loser's RR beats would stay behind under a counter with no decoded_onehz
    // row — invisible to the counter-joined prune (permanent leak). The winner's
    // REPLACE on UNIQUE(rr_ts_ms, beat_index) only overwrites overlapping beat
    // indexes, so delete the evicted counter's beats explicitly, in the same
    // batch/transaction (mirrors the v17 rebuild's decoded_onehz join).
    //
    // …AND the COUNTER-PK eviction, which the guard used to miss entirely.
    // `decoded_onehz` is `counter INTEGER PRIMARY KEY` as well as
    // UNIQUE(rec_ts), and (per the comment above) the strap's counter RESETS to
    // ~0 on every reboot — so this same REPLACE also silently DELETES the row
    // of an OLDER SECOND that happened to reuse this counter. That older
    // second's beats live under OUR counter carrying ITS rr_ts_ms, and only the
    // overlapping beat_indexes get overwritten below: any beat at an index past
    // the new record's beat count SURVIVES, still stamped days earlier. Neither
    // prune path can ever see it (the counter-join finds a fresh rec_ts; the
    // orphan sweep finds the counter present), so a later page's RR series was
    // polluted with beats from another day — silently wrecking RMSSD/HRV.
    // Drop every beat under this counter that is not stamped with THIS second.
    var ops = _queueOrphanGuard(batch, counter: raw.counter, recTs: recTs);
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
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    ops++; // the decoded_onehz insert
    for (var i = 0; i < decoded.rrIntervalsMs.length; i++) {
      final rr = decoded.rrIntervalsMs[i];
      if (rr <= 0) continue;
      batch.insert('decoded_rr', {
        'counter': raw.counter,
        'beat_index': i,
        'rr_ts_ms': recTs * 1000,
        'rr_ms': rr,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      ops++;
    }
    return ops;
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
    // The PK is the frame hex, so a `ts` window (the timeline's day query, and
    // the retention prune) was a full table scan. Cheap to build — `events` is
    // pruned to the retention window.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)',
    );
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
        millivolts INTEGER,
        source TEXT NOT NULL,
        PRIMARY KEY (ts, source)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_band_battery_ts ON band_battery(ts DESC)',
    );
  }

  /// Additive: add the `millivolts` column to an existing band_battery table.
  /// Guarded — the column already exists on fresh installs (see _createBandSignals)
  /// and ALTER … ADD COLUMN throws if it's already there.
  static Future<void> _ensureBandBatteryMillivolts(Database db) =>
      _addColumnIfMissing(db, 'band_battery', 'millivolts', 'INTEGER');

  /// Durable archive for historical records we received but could not decode
  /// (unknown/unsupported version). NEVER pruned — the whole point is that a
  /// future firmware's records survive until we understand the format. Keyed by
  /// counter so a re-flood after a missed ACK dedups (IGNORE on conflict).
  static Future<void> _createRawArchive(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raw_archive (
        counter INTEGER PRIMARY KEY,
        hex TEXT NOT NULL,
        packet_type INTEGER NOT NULL,
        rec_ts INTEGER,
        captured_at INTEGER NOT NULL,
        reason TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_archive_captured '
      'ON raw_archive(captured_at DESC)',
    );
  }

  static Future<void> insertEvent(int eventId, int ts, String hex) async {
    final capturedAt = DateTime.now().millisecondsSinceEpoch;
    // Parse BEFORE acquiring the handle so both inserts run back-to-back on one
    // validated `db` with no intervening await — minimizing the closed-DB race
    // window. Best-effort: a background teardown that closes the DB mid-write
    // must not crash the app (the band re-sends events).
    final parsed = () {
      try {
        return proto.parseEvent(proto.hexToBytes(hex));
      } catch (_) {
        return null;
      }
    }();
    await _guardedWrite((db) async {
      await db.insert('events', {
        'hex': hex,
        'event_id': eventId,
        'ts': ts,
        'captured_at': capturedAt,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await db.insert('band_events', {
        'hex': hex,
        'event_id': eventId,
        'name': parsed?.name ?? proto.EventId.name(eventId),
        'ts': parsed?.tsEpoch ?? ts,
        'payload_json':
            jsonEncode(parsed?.decoded ?? const <String, dynamic>{}),
        'captured_at': capturedAt,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }, bestEffort: true);
  }

  static Future<void> insertBandBatterySample({
    required int ts,
    double? batteryPct,
    bool? charging,
    bool? wristOn,
    int? millivolts,
    required String source,
  }) async {
    // Best-effort background ingest — same closed-DB teardown race as
    // insertEvent; never crash over a battery row (it re-arrives on the poll).
    await _guardedWrite((db) async {
      await db.insert('band_battery', {
        'ts': ts,
        'battery_pct': batteryPct,
        'charging': charging == null ? null : (charging ? 1 : 0),
        'wrist_on': wristOn == null ? null : (wristOn ? 1 : 0),
        'millivolts': millivolts,
        'source': source,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }, bestEffort: true);
  }

  /// Recent battery samples (newest first), for the battery-health series.
  static Future<List<Map<String, dynamic>>> recentBandBatterySamples({
    int limit = 500,
  }) async {
    final db = await instance;
    return db.query('band_battery', orderBy: 'ts DESC', limit: limit);
  }

  /// A simple, honest battery-health readout derived from the recent series.
  ///   - `full_charge_mv`: the rolling max millivolts seen while charging (a
  ///     freshly-aged pack's full-charge voltage sags over its life);
  ///   - `charge_cycles`: count of rising 0→1 charging-edge transitions (a
  ///     coarse proxy — one "plugged in" event per cycle);
  ///   - `latest_pct` / `latest_mv`: the most recent sample.
  /// All fields are nullable (absent input → null, never fabricated).
  static Future<Map<String, dynamic>> batteryHealth({int lookback = 2000}) async {
    final rows = await recentBandBatterySamples(limit: lookback);
    if (rows.isEmpty) {
      return const {
        'samples': 0,
        'full_charge_mv': null,
        'charge_cycles': 0,
        'latest_pct': null,
        'latest_mv': null,
      };
    }
    int? fullChargeMv;
    int cycles = 0;
    int? prevCharging;
    // rows are newest-first; walk oldest-first for edge counting.
    for (final r in rows.reversed) {
      final mv = (r['millivolts'] as num?)?.toInt();
      final ch = (r['charging'] as num?)?.toInt();
      if (ch == 1 && mv != null && (fullChargeMv == null || mv > fullChargeMv)) {
        fullChargeMv = mv;
      }
      if (ch != null) {
        if (prevCharging == 0 && ch == 1) cycles++;
        prevCharging = ch;
      }
    }
    final latest = rows.first;
    return {
      'samples': rows.length,
      'full_charge_mv': fullChargeMv,
      'charge_cycles': cycles,
      'latest_pct': (latest['battery_pct'] as num?)?.toDouble(),
      'latest_mv': (latest['millivolts'] as num?)?.toInt(),
    };
  }

  /// Persist an undecodable historical record to the durable archive (never
  /// pruned). Used by the immediate fallback path; the drain path archives inside
  /// the same commit transaction as the batch (see [commitSyncBatch]).
  static Future<void> archiveRawRecord(ArchiveRecord a) async {
    final db = await instance;
    await db.insert('raw_archive', {
      'counter': a.counter,
      'hex': a.hex,
      'packet_type': a.packetType,
      'rec_ts': a.recTs,
      'captured_at': a.capturedAt,
      'reason': a.reason,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// How many undecodable records we've archived, and by reason — for the sync
  /// diagnostics ("clean sync" honesty: N records set aside, not lost).
  static Future<Map<String, dynamic>> rawArchiveStats() async {
    final db = await instance;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM raw_archive'),
        ) ??
        0;
    final byReason = await db.rawQuery(
      'SELECT reason, COUNT(*) AS n FROM raw_archive '
      'GROUP BY reason ORDER BY n DESC, reason ASC',
    );
    return {
      'count': count,
      'by_reason': {
        for (final row in byReason)
          (row['reason']?.toString() ?? 'unknown'):
              (row['n'] as num?)?.toInt() ?? 0,
      },
    };
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

  /// The OLDEST [limit] queued events — an upload-queue drain head, and ONLY
  /// that. Never use it to answer "what happened on day X": once `events` holds
  /// more than [limit] rows the page can't reach recent days at all (the same
  /// oldest-N-vs-trailing-N shape as the `metricSeries(limit:)` outage). Use
  /// [eventsInRange] for a day/window query.
  static Future<List<Map<String, dynamic>>> unuploadedEvents({
    int limit = 500,
  }) async {
    final db = await instance;
    return db.query('events', orderBy: 'ts ASC', limit: limit);
  }

  /// Events whose `ts` (epoch SECONDS) is in the half-open window
  /// `[fromTs, toTs)`, oldest first. Bounded BY THE WINDOW, not by an unrelated
  /// global page, so a day's markers can never be crowded out by older rows.
  /// [limit] is a defensive cap on a pathological window only.
  static Future<List<Map<String, dynamic>>> eventsInRange(
    int fromTs,
    int toTs, {
    int limit = 5000,
  }) async {
    final db = await instance;
    return db.query(
      'events',
      where: 'ts >= ? AND ts < ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'ts ASC',
      limit: limit,
    );
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
    var inserted = false;
    await db.transaction((txn) async {
      final batch = txn.batch();
      _queueDecodedOneHz(batch, raw, sample);
      await batch.commit(noResult: true);
      inserted = true;
    });
    return inserted;
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

  /// Previously write-only: `quarantineSyncChunk` had no reader anywhere,
  /// so a persistently-stuck batch was recorded but never actually
  /// retrievable for diagnosis. Append-only audit trail (like `raw_archive`)
  /// — never pruned here, resolution is implicit once the same token finally
  /// ACKs (see the `batch:$tokenHex` sync_ledger row transitioning to
  /// `acked`), not a deletion of the quarantine record.
  static Future<List<Map<String, dynamic>>> quarantinedSyncChunks() async {
    final db = await instance;
    return db.query('sync_quarantine', orderBy: 'created_at DESC');
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
    final oneHz =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_onehz'),
        ) ??
        0;
    final rr =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_rr'),
        ) ??
        0;
    return {
      'raw': oneHz,
      'pending': 0,
      'decoded_onehz': oneHz,
      'decoded_rr': rr,
    };
  }

  /// `(firstRecTs, lastRecTs)` in unix seconds over canonical decoded 1 Hz rows,
  /// or `(null, null)` when nothing has been decoded yet. Used by the onboarding
  /// "collecting your data" state to show a real progress bar (last record ts
  /// vs. now, against a first-record anchor) instead of a bare raw-record count.
  static Future<(int?, int?)> firstAndLastRecordTs() async {
    final db = await instance;
    final rows = await db.rawQuery(
      // rec_ts > 0, matching rawStats()/lastDecodedRecTs() — a stray rec_ts=0
      // row (e.g. via _queueDecodedOneHz's `raw.recTs ?? decoded.tsEpoch`,
      // which only substitutes on null, not on an explicit 0) would otherwise
      // make MIN(rec_ts) return 0 and render "Data from Jan 1" (1970 epoch).
      'SELECT MIN(rec_ts) AS lo, MAX(rec_ts) AS hi FROM decoded_onehz WHERE rec_ts > 0',
    );
    if (rows.isEmpty) return (null, null);
    final lo = (rows.first['lo'] as num?)?.toInt();
    final hi = (rows.first['hi'] as num?)?.toInt();
    return (lo, hi);
  }

  /// `{localDayLabel -> MAX(rec_ts)}` over canonical decoded 1 Hz rows, grouped
  /// by the LOCAL calendar day of the record's real time.
  static Future<Map<String, int>> decodedRecTsMaxByDay() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT strftime('%Y-%m-%d', rec_ts, 'unixepoch', 'localtime') AS d, "
      'MAX(rec_ts) AS mx FROM decoded_onehz GROUP BY d',
    );
    final out = <String, int>{};
    for (final r in rows) {
      final d = r['d'] as String?;
      final mx = (r['mx'] as num?)?.toInt();
      if (d != null && mx != null) out[d] = mx;
    }
    return out;
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

  /// How many times [decodedRrByCounterRange]'s degraded counter-span fallback
  /// hit its row cap and therefore returned an INCOMPLETE set of beats. Any
  /// value above zero means some window's HRV was computed from truncated
  /// input; it should stay at zero in normal operation.
  static int decodedRrFallbackTruncations = 0;

  /// Sparse RR beats for one contiguous decoded 1 Hz page.
  ///
  /// [fromCounter] / [toCounter] are the page's FIRST and LAST row counters, as
  /// returned by [decodedOneHzBatchByRecTsRange] (which orders `rec_ts ASC,
  /// counter ASC`). They are page ENDPOINTS, **not** a monotonic counter span:
  /// the strap's counter resets to ~0 on every reboot, so a page straddling a
  /// reboot has first = a pre-reboot high and last = a post-reboot low. The old
  /// `WHERE counter >= ? AND counter <= ?` then read `>= 1200000 AND <= 5` and
  /// returned ZERO rows — the entire page's RR beats vanished with no error, so
  /// that window silently produced no RMSSD/HRV at all.
  ///
  /// Selection is therefore by the page's real TIME window, resolved from those
  /// two endpoint counters. `decoded_onehz` is UNIQUE(rec_ts), so
  /// `[first.rec_ts, last.rec_ts]` contains exactly the page's rows — no
  /// over-fetch — and the join to `decoded_onehz` additionally keeps orphaned
  /// beats (whose owning row was evicted) out of the read path.
  ///
  /// When the endpoints are NOT real rows the caller is asking for a plain
  /// counter span (e.g. `0 .. 1<<30` = "everything"); that falls back to a
  /// NORMALIZED counter range so an inverted pair still can't return nothing.
  static Future<List<Map<String, dynamic>>> decodedRrByCounterRange({
    required int fromCounter,
    required int toCounter,
  }) async {
    final db = await instance;
    final bounds = (await db.rawQuery(
      'SELECT COUNT(*) AS n, MIN(rec_ts) AS lo, MAX(rec_ts) AS hi '
      'FROM decoded_onehz WHERE counter IN (?, ?)',
      [fromCounter, toCounter],
    )).first;
    final n = (bounds['n'] as num?)?.toInt() ?? 0;
    final want = fromCounter == toCounter ? 1 : 2;
    if (n == want) {
      return db.rawQuery(
        'SELECT rr.counter AS counter, rr.beat_index AS beat_index, '
        '       rr.rr_ts_ms AS rr_ts_ms, rr.rr_ms AS rr_ms '
        'FROM decoded_rr rr '
        'JOIN decoded_onehz d ON d.counter = rr.counter '
        'WHERE d.rec_ts >= ? AND d.rec_ts <= ? '
        'ORDER BY d.rec_ts ASC, rr.beat_index ASC',
        [bounds['lo'], bounds['hi']],
      );
    }
    final lo = fromCounter <= toCounter ? fromCounter : toCounter;
    final hi = fromCounter <= toCounter ? toCounter : fromCounter;
    // BOUNDED. This branch is reached when an endpoint row is not in
    // `decoded_onehz` — a prune, or an import's REPLACE + orphan-guard DELETE
    // landing between the frame-page read and this call. The caller's counters
    // are then just a span, and because the strap's counter resets on reboot a
    // reboot-straddling page degenerates to `0 .. ~1200000`, i.e. effectively
    // the whole table. Unbounded, that is a hundreds-of-MB platform-heap read
    // on the same Java heap that OOMed the import path. A page is 2000 frames
    // and a second rarely carries more than a handful of beats, so this cap is
    // orders of magnitude above any legitimate page — reaching it means the
    // degraded path is being used for a range it was never meant to serve.
    const fallbackBeatCap = 200000;
    final rows = await db.query(
      'decoded_rr',
      columns: ['counter', 'beat_index', 'rr_ts_ms', 'rr_ms'],
      where: 'counter >= ? AND counter <= ?',
      whereArgs: [lo, hi],
      orderBy: 'counter ASC, beat_index ASC',
      limit: fallbackBeatCap,
    );
    // Never truncate silently — a short read here means missing beats, which
    // shows up downstream as understated HRV rather than as an error. db.dart
    // deliberately takes no telemetry dependency, so the fact is recorded as a
    // plain counter the Diagnostics screen can surface.
    //
    // A static field is sound HERE specifically: every sqflite call needs the
    // root isolate's platform channel, and this method's only caller
    // (`DerivationEngine._prepare`) reads on the main isolate and ships each
    // page to the compute worker with `worker.send`. Increments therefore land
    // in the same isolate that reads them. Move this read into an isolate and
    // the counter silently stops working — pass the count back over the port
    // instead of reaching for a static.
    if (rows.length >= fallbackBeatCap) {
      decodedRrFallbackTruncations++;
    }
    return rows;
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
    bool skipped = false,
    // A day whose offloaded second-half compute (naps/workouts/HRR/wear/
    // curves/wake-features) failed or timed out AFTER the headline scalars
    // already succeeded — the row is real (not a skip marker) so headline
    // scalars still display, but it must never count as "derived" for the
    // raw-pruning guard (see dayResultIds). Callers should also avoid passing
    // `finalized: true` alongside `partial: true` unless there genuinely is
    // no raw substrate to ever retry from (e.g. the force-finalized import
    // path), since a finalized row is never revisited on a version bump.
    bool partial = false,
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
        'skipped': skipped ? 1 : 0,
        'partial': partial ? 1 : 0,
        'rhr': rhr,
        'rmssd': rmssd,
        'readiness': readiness,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // A `partial` row already doesn't count as "derived" for the raw-pruning
      // guard (see above) — extend the same caution to the rolling baselines:
      // don't let a day whose second-half compute failed/timed out overwrite
      // (or seed, for a brand-new day) the value tomorrow's readiness/illness
      // baseline reads via metric_series. The next successful (non-partial)
      // pass writes the real value once it lands.
      if (!partial) {
        for (final e in series.entries) {
          await txn.insert('metric_series', {
            'date': dayId,
            'key': e.key,
            'value': e.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
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

  /// Every day_id that has a `day_result` row at its LATEST algo_version, newest
  /// first — WITHOUT touching `payload_json`.
  ///
  /// `recentDayResults()` does `SELECT r.*`, which drags the whole bundle
  /// (hr_curve / hypnogram / HRV series, tens of KB a day) across the isolate
  /// boundary. Screens that only need "which days exist" must use this instead:
  /// over a multi-year history the payload variant is hundreds of MB.
  static Future<List<String>> dayResultDayIdsDesc() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT day_id FROM day_result GROUP BY day_id ORDER BY day_id DESC',
    );
    return [
      for (final r in rows)
        if (r['day_id'] is String) r['day_id'] as String,
    ];
  }

  /// Day labels whose LATEST-version bundle records a real sleep total
  /// (`sleep.accounting.value.tst_sec` present). Extracted IN SQLite via
  /// json_extract, so only the scalar crosses the boundary — never the payload.
  static Future<Set<String>> daysWithSleepTst() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT r.day_id FROM day_result r '
      'JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result GROUP BY day_id) m '
      '  ON r.day_id = m.day_id AND r.algo_version = m.v '
      // json_valid() first: json_extract() ERRORS on a malformed payload, and a
      // corrupt bundle must degrade to "no sleep that day", never take out the
      // whole Records screen.
      'WHERE json_valid(r.payload_json) '
      "AND json_extract(r.payload_json, '\$.sleep.accounting.value.tst_sec') "
      'IS NOT NULL',
    );
    return {
      for (final r in rows)
        if (r['day_id'] is String) r['day_id'] as String,
    };
  }

  /// Every day label ('YYYY-MM-DD') the lookback screen can actually RENDER —
  /// exactly the days [dayResult]/`_bundleForDate` would return a real bundle
  /// for, newest first. That is: the LATEST-`algo_version` `day_result` row per
  /// day that is NOT a derivation skip-marker. A day whose minute-detail was
  /// pruned still qualifies (its curves live in the persisted bundle payload,
  /// so it renders a summary); but a raw-only day (`decoded_onehz` with no
  /// derived row) and a skip-marker day both render EMPTY, so neither must
  /// bound navigation. Skips are excluded via the `skipped` column, which
  /// `_markDaySkipped` sets alongside the `{skipped:true}` payload.
  static Future<List<String>> availableDayIds() async {
    final db = await instance;
    // Latest version per day (matches [dayResult]), then drop skip-markers.
    final rows = await db.rawQuery(
      'SELECT r.day_id FROM day_result r '
      'JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result GROUP BY day_id) m '
      '  ON r.day_id = m.day_id AND r.algo_version = m.v '
      'WHERE r.skipped = 0 '
      'ORDER BY r.day_id DESC',
    );
    return [
      for (final r in rows)
        if (r['day_id'] is String && (r['day_id'] as String).isNotEmpty)
          r['day_id'] as String,
    ];
  }

  /// The set of day_id labels that already have a REAL, COMPLETE result at
  /// [algoVersion]. Used by the raw-pruning guard to decide what's safe to
  /// prune - a day that only ever got a skip-marker (its derivation threw)
  /// or a partial row (headline scalars only; the offloaded second-half
  /// blocks failed/timed out) must NOT count as "derived" here, or its raw
  /// substrate gets pruned with no way left to ever fill in the missing
  /// data correctly.
  static Future<Set<String>> dayResultIds(int algoVersion) async {
    final db = await instance;
    final rows = await db.query(
      'day_result',
      columns: ['day_id'],
      where: 'algo_version = ? AND skipped = 0 AND partial = 0',
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

  static Future<int> databaseFileBytes() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, dbName);
    final f = File(path);
    if (!await f.exists()) return 0;
    return await f.length();
  }

  static Future<List<Map<String, dynamic>>> dataHistoryDays() async {
    final db = await instance;
    final rawRows = await db.rawQuery(
      "SELECT strftime('%Y-%m-%d', rec_ts, 'unixepoch', 'localtime') AS day_id, "
      'COUNT(*) AS raw_count, '
      'MIN(rec_ts) AS min_rec_ts, '
      'MAX(rec_ts) AS max_rec_ts '
      'FROM decoded_onehz WHERE rec_ts > 0 GROUP BY day_id ORDER BY day_id DESC',
    );
    final derivedRows = await db.rawQuery(
      'SELECT r.day_id, r.algo_version, r.computed_at, r.finalized '
      'FROM day_result r '
      'JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result GROUP BY day_id) m '
      '  ON r.day_id = m.day_id AND r.algo_version = m.v '
      'ORDER BY r.day_id DESC',
    );
    final metricRows = await db.rawQuery(
      'SELECT date AS day_id, COUNT(*) AS metric_count '
      'FROM metric_series GROUP BY date',
    );
    final sessionRows = await db.rawQuery(
      "SELECT strftime('%Y-%m-%d', start_ts, 'unixepoch', 'localtime') AS day_id, "
      'COUNT(*) AS session_count '
      'FROM sessions GROUP BY day_id',
    );
    final byDay = <String, Map<String, dynamic>>{};
    Map<String, dynamic> ensure(String dayId) => byDay.putIfAbsent(
      dayId,
      () => {
        'day_id': dayId,
        'raw_count': 0,
        'min_rec_ts': null,
        'max_rec_ts': null,
        'has_derived': false,
        'algo_version': null,
        'computed_at': null,
        'finalized': 0,
        'metric_count': 0,
        'session_count': 0,
      },
    );
    for (final row in rawRows) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      final m = ensure(dayId);
      m['raw_count'] = (row['raw_count'] as num?)?.toInt() ?? 0;
      m['min_rec_ts'] = (row['min_rec_ts'] as num?)?.toInt();
      m['max_rec_ts'] = (row['max_rec_ts'] as num?)?.toInt();
    }
    for (final row in derivedRows) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      final m = ensure(dayId);
      m['has_derived'] = true;
      m['algo_version'] = (row['algo_version'] as num?)?.toInt();
      m['computed_at'] = (row['computed_at'] as num?)?.toInt();
      m['finalized'] = (row['finalized'] as num?)?.toInt() ?? 0;
    }
    for (final row in metricRows) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      ensure(dayId)['metric_count'] =
          (row['metric_count'] as num?)?.toInt() ?? 0;
    }
    for (final row in sessionRows) {
      final dayId = row['day_id']?.toString();
      if (dayId == null || dayId.isEmpty) continue;
      ensure(dayId)['session_count'] =
          (row['session_count'] as num?)?.toInt() ?? 0;
    }
    final out = byDay.values.toList()
      ..sort(
        (a, b) => (b['day_id'] as String).compareTo(a['day_id'] as String),
      );
    return out;
  }

  /// The half-open LOCAL window `[startSec, endSec)` covering day [dayId].
  ///
  /// `endSec` is the NEXT local midnight, NOT `startSec + 86400`: a local
  /// calendar day is 23 h on spring-forward and 25 h on fall-back. With the
  /// flat +86400 this returned a window that overran into the next day's first
  /// hour (deleteDays silently deleted the following day's first hour of
  /// decoded_onehz / sessions / band_* / events) or fell an hour short
  /// (fall-back left the last hour behind, and the export dropped it). Shared
  /// with the UI/coach via day_label.dart so every layer agrees.
  static (int, int) _localDayWindow(String dayId) {
    final lo = localDayStartSec(dayId);
    final hi = localDayEndSec(dayId);
    if (lo == null || hi == null) {
      throw ArgumentError.value(dayId, 'dayId', 'not a YYYY-MM-DD day label');
    }
    return (lo, hi);
  }

  static Future<String> exportDaysDb(Set<String> dayIds) async {
    final sorted = dayIds.toList()..sort();
    if (sorted.isEmpty) {
      throw ArgumentError('No days selected');
    }
    final src = await instance;
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = p.join(tmp.path, 'openstrap_days_$stamp.db');
    await deleteDatabase(dest);
    final out = await openDatabase(
      dest,
      // `version:` is MANDATORY here. Without it sqflite throws
      // ArgumentError('onCreate must be null if no version is specified')
      // before opening anything — so this whole export path (Profile → Data
      // history → Export) had never once produced a file.
      version: schemaVersion,
      onCreate: (db, _) async {
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
      },
    );

    // Every source read on the export path is PAGED on rowid. A day-ranged
    // `SELECT *` over `decoded_onehz` is 86,400 rows, and sqflite materialises
    // a whole result set as Java objects before any of it reaches Dart — the
    // same platform-heap exhaustion that OOMed the import path. Keyset, not
    // OFFSET, so paging stays linear.
    const exportPageSize = 2000;
    const rowidKey = '_rowid';

    /// Streams `table` (optionally filtered) into [out] one page at a time,
    /// calling [onPage] with each page after it has been written.
    ///
    /// [onPage] receives rows with the `$rowidKey` cursor column ALREADY
    /// stripped, so a callback can insert what it is handed without tripping
    /// over a column no destination table has. The cursor is read off the raw
    /// page here and never leaves this function.
    ///
    /// PAGING COLUMN: rowid, not the filtered column, so one helper serves
    /// every table regardless of what it is filtered on. That means a filtered
    /// page walks the rowid chain and tests the predicate per row rather than
    /// driving off the `rec_ts`/`ts` index. It stays cheap because both factors
    /// are small: `decoded_onehz` is bounded by `rawRetentionDays` (days, not
    /// years — it is pruned behind the data edge), and the never-pruned tables
    /// paged per day here are hundreds to thousands of rows. Measured on a real
    /// 435k-row ledger the worst case — the exhaustion page that scans to the
    /// end of the table — is ~10 ms. Revisit only if retention grows a lot;
    /// per-table cursors would need a composite `(ts, rowid)` key for the
    /// non-unique columns, which is not worth the complexity today.
    Future<void> copyPaged(
      String table, {
      String? where,
      List<Object?> whereArgs = const [],
      Future<void> Function(List<Map<String, Object?>> page)? onPage,
    }) async {
      var lastRowid = 0;
      while (true) {
        final clause = where == null ? '' : 'AND ($where) ';
        final page = await src.rawQuery(
          'SELECT rowid AS $rowidKey, * FROM $table '
          'WHERE rowid > ? $clause'
          'ORDER BY rowid ASC LIMIT ?',
          [lastRowid, ...whereArgs, exportPageSize],
        );
        if (page.isEmpty) return;
        final clean = [
          for (final row in page)
            <String, Object?>{
              for (final e in row.entries)
                if (e.key != rowidKey) e.key: e.value,
            },
        ];
        await out.transaction((txn) async {
          final batch = txn.batch();
          for (final row in clean) {
            batch.insert(
              table,
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await batch.commit(noResult: true);
        });
        if (onPage != null) await onPage(clean);
        lastRowid = (page.last[rowidKey] as num).toInt();
        if (page.length < exportPageSize) return;
      }
    }

    Future<void> copyRows(
      String table, {
      String? where,
      List<Object?> whereArgs = const [],
    }) =>
        copyPaged(table, where: where, whereArgs: whereArgs);

    Future<void> copyRawRange(int startSec, int endSec) async {
      // The day's 1 Hz rows stream page by page, and each page's RR beats are
      // pulled and written before the next page is read — so peak residency is
      // one page of `decoded_onehz` plus its beats, not a whole day of both.
      await copyPaged(
        'decoded_onehz',
        where: 'rec_ts >= ? AND rec_ts < ?',
        whereArgs: [startSec, endSec],
        onPage: (page) async {
          final counters = <Object?>[
            for (final row in page)
              if (row['counter'] != null) row['counter'],
          ];
          if (counters.isEmpty) return;
          // CHUNKED `IN (…)`: even one page's counters can approach
          // SQLITE_MAX_VARIABLE_NUMBER, and a full day is 86,400 — two orders
          // of magnitude past it, so one giant statement could never bind.
          // (This never surfaced only because the missing `version:` above
          // aborted the export earlier.)
          for (final chunk in _sqlVarChunks(counters)) {
            final placeholders = List.filled(chunk.length, '?').join(',');
            final rr = await src.rawQuery(
              'SELECT * FROM decoded_rr WHERE counter IN ($placeholders)',
              chunk,
            );
            if (rr.isEmpty) continue;
            await out.transaction((txn) async {
              final batch = txn.batch();
              for (final row in rr) {
                batch.insert(
                  'decoded_rr',
                  Map<String, Object?>.from(row),
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              }
              await batch.commit(noResult: true);
            });
          }
        },
      );
      await copyRows(
        'samples',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'events',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'band_events',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'band_battery',
        where: 'ts >= ? AND ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'sessions',
        where: 'start_ts >= ? AND start_ts < ?',
        whereArgs: [startSec, endSec],
      );
      await copyRows(
        'live_coverage',
        where: 'end_ts > ? AND start_ts < ?',
        whereArgs: [startSec, endSec],
      );
    }

    for (final dayId in sorted) {
      final (startSec, endSec) = _localDayWindow(dayId);
      await copyRawRange(startSec, endSec);
      await copyRows('day_result', where: 'day_id = ?', whereArgs: [dayId]);
      await copyRows('metric_series', where: 'date = ?', whereArgs: [dayId]);
      await copyRows('journal', where: 'date = ?', whereArgs: [dayId]);
      await copyRows(
        'journal_metric',
        where: 'date = ?',
        whereArgs: [dayId],
      );
      await copyRows('cycle_log', where: 'date = ?', whereArgs: [dayId]);
      await copyRows('notifications', where: 'date = ?', whereArgs: [dayId]);
      await copyRows(
        'sleep_session_candidates',
        where: 'day_id = ?',
        whereArgs: [dayId],
      );
      await copyRows(
        'wake_day_features',
        where: 'day_id = ?',
        whereArgs: [dayId],
      );
    }
    // Custom journal field definitions are not day-scoped, so they ride along
    // whole. Without them an exported day carries numbers under keys like
    // `custom_magnesium` with no label, no unit and no idea what scale they
    // are on — the values survive the export and their meaning does not.
    await copyRows('journal_field_def');
    await out.close();
    return dest;
  }

  static Future<int> deleteDays(Set<String> dayIds) async {
    final sorted = dayIds.toList()..sort();
    if (sorted.isEmpty) return 0;
    final db = await instance;
    int deleted = 0;
    Future<void> deleteByIn(
      Transaction txn,
      String table,
      String column,
      List<String> values,
    ) async {
      // Chunked: "select all" on a multi-year history binds one day label per
      // parameter, which would blow SQLITE_MAX_VARIABLE_NUMBER.
      for (final chunk in _sqlVarChunks(values)) {
        final placeholders = List.filled(chunk.length, '?').join(',');
        deleted += await txn.rawDelete(
          'DELETE FROM $table WHERE $column IN ($placeholders)',
          chunk,
        );
      }
    }

    await db.transaction((txn) async {
      for (final dayId in sorted) {
        final (startSec, endSec) = _localDayWindow(dayId);
        deleted += await txn.delete(
          'decoded_rr',
          where:
              'counter IN (SELECT counter FROM decoded_onehz WHERE rec_ts >= ? AND rec_ts < ?)',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'decoded_onehz',
          where: 'rec_ts >= ? AND rec_ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'samples',
          where: 'ts >= ? AND ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'events',
          where: 'ts >= ? AND ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'band_events',
          where: 'ts >= ? AND ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'band_battery',
          where: 'ts >= ? AND ts < ?',
          whereArgs: [startSec, endSec],
        );
        // CASCADE the GPS route BEFORE its session row disappears — otherwise
        // the join key is gone and every lat/lng point of a deleted run stays
        // on disk forever (deleteSession cascades explicitly; this path did
        // not). Must run first: once `sessions` is deleted the subquery is
        // empty and the route is unreachable.
        deleted += await txn.rawDelete(
          'DELETE FROM workout_route WHERE session_id IN '
          '(SELECT id FROM sessions WHERE start_ts >= ? AND start_ts < ?)',
          [startSec, endSec],
        );
        deleted += await txn.delete(
          'sessions',
          where: 'start_ts >= ? AND start_ts < ?',
          whereArgs: [startSec, endSec],
        );
        deleted += await txn.delete(
          'live_coverage',
          where: 'end_ts > ? AND start_ts < ?',
          whereArgs: [startSec, endSec],
        );
      }
      await deleteByIn(txn, 'day_result', 'day_id', sorted);
      await deleteByIn(txn, 'metric_series', 'date', sorted);
      await deleteByIn(txn, 'journal', 'date', sorted);
      await deleteByIn(txn, 'journal_metric', 'date', sorted);
      await deleteByIn(txn, 'cycle_log', 'date', sorted);
      await deleteByIn(txn, 'notifications', 'date', sorted);
      await deleteByIn(txn, 'sleep_session_candidates', 'day_id', sorted);
      await deleteByIn(txn, 'wake_day_features', 'day_id', sorted);
      // Day-keyed USER rows. Same class of leak as workout_route: "delete this
      // day" must not leave the user's own logged health data behind.
      await deleteByIn(txn, 'cycle_symptom', 'date', sorted);
      await deleteByIn(txn, 'workout_suggestions', 'date', sorted);
      await deleteByIn(txn, 'sleep_override', 'day_id', sorted);
    });
    return deleted;
  }

  /// Import another device's exported OpenStrap DB ([path], from [exportCopy] +
  /// share) by MERGING its rows into this one (INSERT-OR-REPLACE). Covers derived
  /// results, the metric series, user data, and the raw ledger so the receiving
  /// device has the full history (and can re-derive). Same app ⇒ same schema; a
  /// table missing in the source is skipped. Locally FINALIZED day_result rows
  /// are protected — an import never overwrites them. Returns per-table counts
  /// of rows actually copied.
  static Future<Map<String, int>> importFromDbFile(String path) async {
    if (!await File(path).exists()) {
      throw const FileSystemException('Backup file not found');
    }
    final src = await openDatabase(path, readOnly: true);
    final db = await instance;
    // Order: independent tables; all use INSERT OR REPLACE so re-import is safe.
    const tables = [
      'samples',
      'events',
      'decoded_onehz',
      'decoded_rr',
      'band_events',
      'band_battery',
      'day_result',
      'metric_series',
      'sessions',
      'journal',
      'journal_metric',
      'journal_field_def',
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
        // PAGED SOURCE READ — never `SELECT *` a whole table.
        //
        // This used to be a single `src.query(t)`. sqflite serialises an entire
        // result set into Java objects on the platform side BEFORE any of it
        // crosses the channel, so importing another device's `decoded_onehz`
        // (86,400 rows per day of history) materialised the whole table on the
        // 256 MB Dalvik heap at once — and then held it live for the duration
        // of the insert loop below. That is the production
        // `java.lang.OutOfMemoryError` seen on 0.9.19 from ImportScreen
        // ("target footprint 268435456, growth limit 268435456"); the OOM
        // surfaced on whichever thread happened to allocate next, which is why
        // it was blamed on a BLE binder callback.
        //
        // Keyset pagination on `rowid` (none of these tables is WITHOUT ROWID),
        // NOT LIMIT/OFFSET — OFFSET re-scans the skipped prefix on every page,
        // which is quadratic over a full history.
        // `_rowid` is aliased into the projection so the cursor can advance;
        // it is filtered straight back out when the row is rebuilt below,
        // because the `cols.contains(e.key)` guard only admits real
        // destination columns and no table has a column by that name.
        const pageSize = 2000;
        const rowidKey = '_rowid';
        var lastRowid = 0;
        Future<List<Map<String, Object?>>> nextPage() => src.rawQuery(
              'SELECT rowid AS $rowidKey, * FROM $t '
              'WHERE rowid > ? ORDER BY rowid ASC LIMIT ?',
              [lastRowid, pageSize],
            );

        List<Map<String, Object?>> firstPage;
        try {
          firstPage = await nextPage();
        } on DatabaseException catch (e) {
          // ONLY "this export doesn't carry that table" is skippable. A blanket
          // catch here made every read failure — corruption, a truncated or
          // malformed source file, an I/O error — look identical to an absent
          // table: the table was skipped, `counts[t]` was never set, and the
          // summed total then reported a PARTIAL import as a success. Silent
          // partial success on someone's health history is the worst available
          // outcome, so anything that is not a missing table now propagates.
          if (e.isNoSuchTableError()) continue;
          rethrow;
        }
        if (firstPage.isEmpty) {
          counts[t] = 0;
          continue;
        }
        final cols = await destCols(t);
        if (cols.isEmpty) continue; // table absent in THIS build
        // FINALIZED-DAY PROTECTION: a local day_result row with finalized=1 is
        // LOCKED (this device's own fully-derived history — the long-term
        // system of record). A foreign export merged with REPLACE must never
        // clobber it on a (day_id, algo_version) collision; non-finalized rows
        // keep the plain REPLACE behavior (the import may well be fresher).
        var protectedKeys = const <String>{};
        if (t == 'day_result') {
          final fin = await db.query(
            'day_result',
            columns: ['day_id', 'algo_version'],
            where: 'finalized = 1',
          );
          protectedKeys = {
            for (final r in fin) '${r['day_id']}|${r['algo_version']}',
          };
        }
        var copied = 0;
        var page = firstPage;
        // ONE TRANSACTION PER PAGE, not per table. The whole-table transaction
        // this replaces could only ever commit if the entire table fit in
        // memory first, which is the bug. Per-page commits keep peak residency
        // at one page, and the import stays safe to interrupt or repeat: every
        // write is INSERT OR REPLACE keyed on the row's own identity, so a
        // re-run converges to the same state, and each decoded_onehz row's
        // orphan guard is still queued in the SAME transaction as the row it
        // guards — the invariant that matters is per-row, not per-table.
        while (page.isNotEmpty) {
          await db.transaction((txn) async {
            // CHUNKED, for the same reason commitSyncBatch chunks: sqflite
            // serialises a whole batch's args into ONE platform message, and
            // the orphan guard below adds an op per decoded_onehz row on top.
            const chunkOps = 4000;
            var batch = txn.batch();
            var ops = 0;
            Future<void> flush() async {
              if (ops == 0) return;
              await batch.commit(noResult: true);
              batch = txn.batch();
              ops = 0;
            }

            for (final r in page) {
              final row = <String, Object?>{
                for (final e in r.entries)
                  if (cols.contains(e.key)) e.key: e.value,
              };
              if (row.isEmpty) continue;
              if (t == 'day_result' &&
                  protectedKeys.contains(
                    '${row['day_id']}|${row['algo_version']}',
                  )) {
                continue; // locally finalized — never overwritten by an import
              }
              // ORPHAN GUARD ON THE IMPORT PATH. A plain replace-insert into
              // decoded_onehz bypasses _queueDecodedOneHz entirely, so a
              // foreign row colliding on UNIQUE(rec_ts) (different counter) or
              // on the `counter` PRIMARY KEY (different second) evicted a local
              // row and stranded its decoded_rr beats — the exact leak the
              // ingest path is guarded against, wide open here. Queue the SAME
              // guard, in the same batch/transaction, right before the row.
              if (t == 'decoded_onehz') {
                final counter = (row['counter'] as num?)?.toInt();
                final recTs = (row['rec_ts'] as num?)?.toInt();
                if (counter == null || recTs == null) continue;
                ops += _queueOrphanGuard(batch, counter: counter, recTs: recTs);
              }
              batch.insert(t, row, conflictAlgorithm: ConflictAlgorithm.replace);
              copied++;
              if (++ops >= chunkOps) await flush();
            }
            await flush();
          });
          // Advance past the last row this page actually delivered. Read the
          // cursor BEFORE dropping the page, and stop on a short page rather
          // than issuing one more query to discover the end.
          lastRowid = (page.last[rowidKey] as num).toInt();
          if (page.length < pageSize) break;
          page = await nextPage();
        }
        counts[t] = copied;
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
          await db.rawQuery('SELECT COUNT(*) FROM decoded_onehz'),
        ) ??
        0;
    final tsRow = (await db.rawQuery(
      'SELECT MIN(rec_ts) AS lo, MAX(rec_ts) AS hi FROM decoded_onehz WHERE rec_ts > 0',
    )).first;
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
      'by_type': const <String, int>{},
      'min_captured_ms': null,
      'max_captured_ms': null,
      'decoded_onehz': decodedOneHz,
      'decoded_rr': decodedRr,
      'legacy_samples': legacySamples,
    };
  }

  static Future<List<Map<String, dynamic>>> tableStorageStats() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' "
      "AND name != 'android_metadata' "
      "ORDER BY name ASC",
    );
    final out = <Map<String, dynamic>>[];
    final dbstatAvailable = await _dbstatAvailable(db);
    for (final row in rows) {
      final name = row['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final tableRows =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $name'),
          ) ??
          0;
      final bytes = dbstatAvailable
          ? await _tableBytesViaDbstat(db, name)
          : await _tableBytesApprox(db, name);
      out.add({
        'table': name,
        'rows': tableRows,
        'bytes': bytes,
        'mb': bytes == null ? null : bytes / (1024 * 1024),
        'approximate': !dbstatAvailable,
      });
    }
    out.sort((a, b) {
      final aa = (a['bytes'] as num?)?.toInt() ?? -1;
      final bb = (b['bytes'] as num?)?.toInt() ?? -1;
      return bb.compareTo(aa);
    });
    return out;
  }

  static Future<bool> _dbstatAvailable(Database db) async {
    try {
      await db.rawQuery(
        "SELECT SUM(pgsize) AS bytes FROM dbstat WHERE name = 'decoded_onehz'",
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<int?> _tableBytesViaDbstat(Database db, String table) async {
    try {
      final row = (await db.rawQuery(
        'SELECT SUM(pgsize) AS bytes FROM dbstat WHERE name = ?',
        [table],
      )).first;
      return (row['bytes'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> _tableBytesApprox(Database db, String table) async {
    try {
      final cols = await db.rawQuery('PRAGMA table_info($table)');
      if (cols.isEmpty) return 0;
      final expr = cols
          .map((c) {
            final name = c['name']?.toString() ?? '';
            return 'IFNULL(LENGTH($name), 0)';
          })
          .join(' + ');
      final row = (await db.rawQuery(
        'SELECT SUM($expr) AS bytes FROM $table',
      )).first;
      return (row['bytes'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return null;
    }
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
      'journal_metric',
      'journal_field_def',
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
      'workout_route',
      'notif_fired',
    ];

    final missingTables = <String>[];
    for (final table in requiredTables) {
      if (!await hasTable(table)) missingTables.add(table);
    }

    final sessionCols = await hasTable('sessions')
        ? await cols('sessions')
        : <String>{};
    final syncLedgerCols = await hasTable('sync_ledger')
        ? await cols('sync_ledger')
        : <String>{};

    final missingColumns = <String, List<String>>{};
    void expect(String table, Set<String> present, List<String> required) {
      final miss = [
        for (final c in required)
          if (!present.contains(c)) c,
      ];
      if (miss.isNotEmpty) missingColumns[table] = miss;
    }

    expect('sessions', sessionCols, ['id', 'start_ts', 'status', 'steps']);
    expect('sync_ledger', syncLedgerCols, [
      'chunk_id',
      'kind',
      'status',
      'updated_at',
      'meta_json',
    ]);

    final integrity = await db.rawQuery('PRAGMA integrity_check');
    final integrityOk =
        integrity.isNotEmpty && integrity.first.values.first == 'ok';

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
    final rawByDay = await decodedRecTsMaxByDay();
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
    final rows = await db.query(
      'metric_series',
      where: 'date = ? AND key = ?',
      whereArgs: [date, key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['value'] as num?)?.toDouble();
  }

  /// The FROZEN personal movement floor (g, dynAmp units) + when it was frozen.
  ///
  /// Persisted rather than recomputed because a floor that keeps tracking the
  /// user cancels the trend it exists to report — see the derivation-engine
  /// comment for the measured before/after. Returns null until enrollment
  /// completes, which is the estimator's signal to abstain.
  static Future<({double floorG, String frozenOn, int days})?>
      getMovementFloor() async {
    final row = await baseline('movement_floor');
    final raw = row?['payload_json'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return null;
      final f = (d['floor_g'] as num?)?.toDouble();
      final on = d['frozen_on'] as String?;
      if (f == null || !f.isFinite || f <= 0 || on == null) return null;
      return (floorG: f, frozenOn: on, days: (d['days'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }

  static Future<void> putMovementFloor({
    required double floorG,
    required String frozenOn,
    required int days,
  }) =>
      putBaseline(
        'movement_floor',
        jsonEncode({'floor_g': floorG, 'frozen_on': frozenOn, 'days': days}),
      );


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

  /// The TRAILING [n] non-null values for [key] — the newest n days, returned
  /// oldest→newest. Unlike [metricSeries] (which is `date ASC LIMIT n`, i.e. the
  /// OLDEST n days), this is the right window for a rolling baseline. Because
  /// metric_series is keyed `(date, key)` with REPLACE, there is exactly one row
  /// per day, so the result is inherently de-duplicated.
  static Future<List<double>> trailingSeriesValues(String key, int n) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT value FROM metric_series '
      'WHERE key = ? AND value IS NOT NULL '
      'ORDER BY date DESC LIMIT ?',
      [key, n],
    );
    return [for (final r in rows.reversed) (r['value'] as num).toDouble()];
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

  /// Atomically read-modify-write one `baselines` row.
  ///
  /// [transform] receives the current `payload_json` (null when the row does
  /// not exist) and returns the replacement, or null to leave the row alone.
  ///
  /// Needed because a Dart-level lock CANNOT serialize this. Derivation runs in
  /// more than one isolate — `derivationDispatcher` is a `vm:entry-point`
  /// WorkManager entry that constructs its own `DerivationEngine` in a separate
  /// background isolate — and a `static` mutex has one copy per isolate. Two
  /// isolates would each read the same payload, merge into it, and write back,
  /// dropping the other's changes. That matters most for accumulator payloads
  /// like `sleep_user_profile`, where a lost write also loses the record of
  /// which days were already folded.
  ///
  /// `exclusive: true` issues BEGIN IMMEDIATE, taking SQLite's write lock up
  /// front rather than on first write. Without it a deferred transaction that
  /// reads and then writes can fail to upgrade under WAL when another
  /// connection holds the write lock. The lock is cross-connection and
  /// therefore cross-isolate, which is exactly the guarantee a Dart static
  /// cannot give.
  static Future<void> updateBaseline(
    String key,
    String? Function(String? current) transform,
  ) async {
    final db = await instance;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'baselines',
        columns: ['payload_json'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      final current =
          rows.isEmpty ? null : rows.first['payload_json'] as String?;
      final next = transform(current);
      if (next == null) return;
      await txn.insert('baselines', {
        'key': key,
        'payload_json': next,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }, exclusive: true);
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

  static Future<void> putComputeFreshness(
    String key,
    String payloadJson,
  ) async {
    final db = await instance;
    await db.insert('compute_freshness', {
      'key': key,
      'payload_json': payloadJson,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String localDayLabelNow() => todayLabel();

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
        final sleep =
            ((decoded['sleep'] as Map?)?['accounting'] as Map?)?['value'];
        final flags = decoded['flags'];
        final hasSleep = sleep is Map && sleep['tst_sec'] != null;
        final noSleep = flags is List && flags.contains('NO_SLEEP_DETECTED');
        if (hasSleep || noSleep) {
          latestOvernightDay = dayId;
          latestOvernightComputedAt = (row['computed_at'] as num?)?.toInt();
        }
      }
      if (latestRecoveryDay == null &&
          ((row['readiness'] as num?) != null || scalars['readiness'] is num)) {
        latestRecoveryDay = dayId;
        latestRecoveryComputedAt = (row['computed_at'] as num?)?.toInt();
      }
      if (latestOvernightDay != null &&
          latestRecoveryDay != null &&
          todayRow != null) {
        break;
      }
    }
    final todayComputedAt = (todayRow?['computed_at'] as num?)?.toInt();
    final wakeComputedAt = (todayWake?['computed_at'] as num?)?.toInt();
    final activityReady = todayRow != null || todayWake != null;
    final overnightReady = latestOvernightDay == today;
    final rawReachedToday =
        latestRawTs != null && _localDayLabelFromEpoch(latestRawTs) == today;
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
        'latest_raw_day': latestRawTs == null
            ? null
            : _localDayLabelFromEpoch(latestRawTs),
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
      {'state': 'queued', 'updated_at': now},
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

  /// Put a claimed job back on the queue without counting it as an attempt.
  ///
  /// Used when a gate closes DURING acquisition: `_drain()` clears the gate,
  /// awaits [takeNextComputeJob], and by the time that returns a workout may
  /// have started. The job is already marked `running`, so it has to be handed
  /// back explicitly or it sits claimed until the next [recoverComputeJobs].
  /// The attempt increment is undone too — being deferred is not a failure.
  static Future<void> requeueComputeJob(String id) async {
    final db = await instance;
    await db.rawUpdate(
      'UPDATE compute_jobs SET state = ?, '
      'attempts = MAX(attempts - 1, 0), updated_at = ? WHERE id = ?',
      ['queued', DateTime.now().millisecondsSinceEpoch, id],
    );
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

  /// Replace one day's numeric journal fields.
  ///
  /// The map IS the day: a field that is absent from [fields] is DELETED for
  /// that date, not left behind. Clearing a value the user cleared matters
  /// more than it sounds — a stale "3 coffees" that survives an edit becomes a
  /// data point the user never entered, and correlations are exactly where
  /// that does damage.
  ///
  /// Written in one transaction so a day is never half-updated.
  static Future<void> putJournalMetrics(
    String date,
    Map<String, JournalMetricValue> fields,
  ) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.delete('journal_metric', where: 'date = ?', whereArgs: [date]);
      for (final e in fields.entries) {
        await txn.insert('journal_metric', {
          'date': date,
          'field': e.key,
          'value': e.value.value,
          'at_min': e.value.atMinuteOfDay,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// One day's numeric fields, or an empty map when nothing was recorded.
  static Future<Map<String, JournalMetricValue>> journalMetricsForDay(
    String date,
  ) async {
    final db = await instance;
    final rows = await db.query(
      'journal_metric',
      where: 'date = ?',
      whereArgs: [date],
    );
    return {
      for (final r in rows)
        r['field'] as String: JournalMetricValue(
          (r['value'] as num).toDouble(),
          atMinuteOfDay: (r['at_min'] as num?)?.toInt(),
        ),
    };
  }

  /// Numeric journal fields per day, oldest first, for the correlation pass.
  /// [sinceDaysEpoch] is an optional inclusive lower bound on `date`.
  static Future<Map<String, Map<String, JournalMetricValue>>>
  journalMetricsByDay({String? sinceDaysEpoch}) async {
    final db = await instance;
    final rows = sinceDaysEpoch == null
        ? await db.query('journal_metric', orderBy: 'date ASC')
        : await db.query(
            'journal_metric',
            where: 'date >= ?',
            whereArgs: [sinceDaysEpoch],
            orderBy: 'date ASC',
          );
    final out = <String, Map<String, JournalMetricValue>>{};
    for (final r in rows) {
      (out[r['date'] as String] ??= {})[r['field'] as String] =
          JournalMetricValue(
            (r['value'] as num).toDouble(),
            atMinuteOfDay: (r['at_min'] as num?)?.toInt(),
          );
    }
    return out;
  }

  /// Every field name that has ever been recorded, so a user-defined field
  /// keeps appearing in the editor after the day it was invented on.
  static Future<List<String>> journalMetricFields() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT DISTINCT field FROM journal_metric ORDER BY field ASC',
    );
    return [for (final r in rows) r['field'] as String];
  }

  /// Custom field definitions, ordered by label.
  static Future<List<JournalFieldSpec>> journalFieldDefs() async {
    final db = await instance;
    final rows = await db.query('journal_field_def', orderBy: 'label ASC');
    return [
      for (final r in rows)
        JournalFieldSpec(
          key: r['key'] as String,
          label: r['label'] as String,
          kind: JournalFieldKind.values.firstWhere(
            (k) => k.name == r['kind'],
            // A row written by a newer build with a kind this one has never
            // heard of still renders as a dose rather than crashing the whole
            // journal screen.
            orElse: () => JournalFieldKind.dose,
          ),
          unit: r['unit'] as String,
          max: (r['max_value'] as num).toDouble(),
          step: (r['step'] as num).toDouble(),
          hasTime: ((r['has_time'] as num?)?.toInt() ?? 0) == 1,
          custom: true,
        ),
    ];
  }

  static Future<void> putJournalFieldDef(JournalFieldSpec spec) async {
    final db = await instance;
    await db.insert('journal_field_def', {
      'key': spec.key,
      'label': spec.label,
      'kind': spec.kind.name,
      'unit': spec.unit,
      'max_value': spec.max,
      'step': spec.step,
      'has_time': spec.hasTime ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Forget a custom field's DEFINITION. Its recorded values are deliberately
  /// left alone — they were real readings, and deleting a label should not
  /// delete history.
  static Future<void> deleteJournalFieldDef(String key) async {
    final db = await instance;
    await db.delete('journal_field_def', where: 'key = ?', whereArgs: [key]);
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

  /// Update ONLY a session's derived score columns.
  ///
  /// Deliberately not `putSession`: that is INSERT-OR-REPLACE over the whole
  /// row, so a re-score computed from a snapshot would also rewrite columns it
  /// never read — `hrr_bpm` (backfilled by the derivation engine) and `type`
  /// (the athlete correcting a mislabelled workout) are both written by their
  /// own narrow UPDATEs and would be reverted. Returns the number of rows
  /// changed (0 when the session has since been deleted).
  static Future<int> setSessionScores(
    String id, {
    required double? strain,
    required double? calories,
    required int? maxHr,
    required String zoneMinJson,
  }) async {
    final db = await instance;
    return db.update(
      'sessions',
      {
        'strain': strain,
        'calories': calories,
        'max_hr': maxHr,
        'zone_min_json': zoneMinJson,
      },
      where: 'id = ?',
      whereArgs: [id],
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

  /// The one session row (if any) still `status='live'` — i.e. its
  /// `stopWorkout`/finalize write never happened, most likely because the app
  /// was killed mid-workout. On a healthy run there is at most one (a second
  /// `startWorkout` can't begin while `activeWorkout` is already set), but a
  /// crash could in principle strand more than one across restarts, so this
  /// returns every match, newest first, rather than assuming exactly one.
  /// Used at startup to reconcile the orphaned-live-workout bug (issue: "can't
  /// stop workout, only delete" — activeWorkout was never rehydrated from this
  /// row, so the in-app stop control was unreachable after a restart).
  static Future<List<Map<String, dynamic>>> liveSessions() async {
    final db = await instance;
    return db.query(
      'sessions',
      where: "status = 'live'",
      orderBy: 'start_ts DESC',
    );
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
    // Cascade: a route belongs to its session (on-device only, no FK enforced).
    await db.delete('workout_route', where: 'session_id = ?', whereArgs: [id]);
  }

  // ── workout GPS routes (run/ride/walk) I/O ─────────────────────────────────
  // Recorded on-device only; never uploaded. Ordered by seq within a session.

  static Future<void> _createWorkoutRoute(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_route (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        ts_ms INTEGER NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        alt REAL,
        accuracy REAL,
        PRIMARY KEY (session_id, seq)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_workout_route_session '
      'ON workout_route(session_id, seq)',
    );
  }

  /// Additive: add the `speed` column (smoothed instantaneous m/s) to an
  /// existing workout_route table. Guarded — fresh installs get it from
  /// _createWorkoutRoute directly once that's updated; ALTER … ADD COLUMN
  /// throws if it's already there.
  static Future<void> _ensureWorkoutRouteSpeed(Database db) =>
      _addColumnIfMissing(db, 'workout_route', 'speed', 'REAL');

  /// Append a batch of route rows (INSERT OR REPLACE — idempotent on
  /// (session_id, seq)). Each row is a [RoutePoint.toRow] map.
  static Future<void> appendRoutePoints(
    String sessionId,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return;
    final db = await instance;
    final batch = db.batch();
    for (final r in rows) {
      batch.insert('workout_route', r,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// All route rows for a session, ordered by seq.
  static Future<List<Map<String, dynamic>>> routePoints(
      String sessionId) async {
    final db = await instance;
    return db.query(
      'workout_route',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq ASC',
    );
  }

  /// True when a session has any recorded route points (cheap existence check).
  static Future<bool> sessionHasRoute(String sessionId) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT 1 FROM workout_route WHERE session_id = ? LIMIT 1',
      [sessionId],
    );
    return rows.isNotEmpty;
  }

  /// 1 Hz heart-rate samples in [fromTs, toTs] (epoch SECONDS), ascending, used
  /// to colour a route and average HR per split. Only worn seconds (hr > 0).
  static Future<List<Map<String, dynamic>>> hrSamplesInRange(
    int fromTs,
    int toTs,
  ) async {
    final db = await instance;
    return db.query(
      'decoded_onehz',
      columns: ['rec_ts', 'hr'],
      where: 'rec_ts >= ? AND rec_ts <= ? AND hr > 0',
      whereArgs: [fromTs, toTs],
      orderBy: 'rec_ts ASC',
    );
  }

  /// Per-session HR aggregates over the 1 Hz substrate for every session in
  /// [fromTs, toTs] (epoch SECONDS): {session_id: {n, avg_hr, min_hr, max_hr}}.
  /// One indexed range join — powers the workout list's avg-bpm / no-data
  /// heuristic without a query per row. Sessions whose window has been pruned
  /// (14-day raw retention) simply don't appear.
  /// [maxHrCeiling] / [minHrFloor] physiologically bound the SQL MAX/MIN(d.hr):
  /// a coarse guard so a gross artefact can't define a session that has no
  /// on-read smoothed extreme (imported/legacy rows). Spike-suppressed
  /// max/min come from [sessionHrSamplesBySession] + the shared smoother; these
  /// aggregates are a last fallback only. 0/unset disables each bound.
  static Future<Map<String, Map<String, num>>> sessionHrStats(
    int fromTs,
    int toTs, {
    int maxHrCeiling = 0,
    int minHrFloor = 0,
  }) async {
    final db = await instance;
    final ceilClause = maxHrCeiling > 0 ? 'AND d.hr <= $maxHrCeiling ' : '';
    final floorClause = minHrFloor > 0 ? 'AND d.hr >= $minHrFloor ' : '';
    final rows = await db.rawQuery(
      'SELECT s.id AS id, COUNT(d.rec_ts) AS n, AVG(d.hr) AS avg_hr, '
      '       MIN(CASE WHEN 1=1 $floorClause THEN d.hr END) AS min_hr, '
      '       MAX(CASE WHEN 1=1 $ceilClause THEN d.hr END) AS max_hr '
      'FROM sessions s '
      'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
      '  AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) AND d.hr > 0 '
      'WHERE s.start_ts >= ? AND s.start_ts <= ? '
      'GROUP BY s.id',
      [fromTs, toTs],
    );
    return {
      for (final r in rows)
        if (r['id'] != null)
          r['id'] as String: {
            'n': (r['n'] as num?) ?? 0,
            'avg_hr': (r['avg_hr'] as num?) ?? 0,
            'min_hr': (r['min_hr'] as num?) ?? 0,
            'max_hr': (r['max_hr'] as num?) ?? 0,
          },
    };
  }

  /// Worn 1 Hz HR samples for every session in [fromTs, toTs] (epoch SECONDS),
  /// grouped {session_id: [hr, …]} in ascending time — one indexed range join.
  /// Feeds the workout list's spike-suppressed max (the shared smoother runs in
  /// the repo, not here). Sessions whose window has been pruned (14-day raw
  /// retention) simply don't appear, and the caller falls back to the stored
  /// column.
  static Future<Map<String, List<int>>> sessionHrSamplesBySession(
    int fromTs,
    int toTs,
  ) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT s.id AS id, d.hr AS hr '
      'FROM sessions s '
      'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
      '  AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) AND d.hr > 0 '
      'WHERE s.start_ts >= ? AND s.start_ts <= ? '
      'ORDER BY s.id, d.rec_ts ASC',
      [fromTs, toTs],
    );
    final out = <String, List<int>>{};
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null) continue;
      (out[id] ??= <int>[]).add((r['hr'] as num).toInt());
    }
    return out;
  }

  /// Backfill a session's heart-rate-recovery (bpm), computed retrospectively
  /// from the 1 Hz substrate around the session's end during derivation.
  static Future<void> setSessionHrr(String id, double hrrBpm) async {
    final db = await instance;
    await db.update(
      'sessions',
      {'hrr_bpm': hrrBpm},
      where: 'id = ?',
      whereArgs: [id],
    );
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

  // NOTE: the in-app notifications feed (putNotification/notifications/
  // markNotificationsRead/unreadCount, + the `notifications` table) was
  // removed — OS-level notifications (NotificationCenter.emit's
  // NotificationService.presentEvent path) are the only surface now. The
  // `notifications` table itself is left in the schema (unused, harmless)
  // rather than risk a DROP TABLE migration for no real benefit.

  // ── decoded retention ───────────────────────────────────────────────────────

  /// Delete decoded substrate / structured band signals / events whose RECORD
  /// TIME (epoch seconds) is strictly before [cutoffSec].
  static Future<int> pruneDecodedBeforeRecTs(int cutoffSec) async {
    final db = await instance;
    // `deleted` used to just stay 0 forever - none of the txn.delete() calls'
    // return values (rows actually deleted) were ever added to it, so the
    // caller's `if (deleted > 0) log(...)` never fired even on a real prune.
    int deleted = 0;
    await db.transaction((txn) async {
      deleted += await txn.delete(
        'decoded_rr',
        where:
            'counter IN (SELECT counter FROM decoded_onehz WHERE rec_ts < ?)',
        whereArgs: [cutoffSec],
      );
      deleted += await txn.delete(
        'decoded_onehz',
        where: 'rec_ts < ?',
        whereArgs: [cutoffSec],
      );
      // ORPHAN SWEEP: pre-guard builds could leave decoded_rr beats whose
      // owning counter lost a rec_ts collision (REPLACE evicted its
      // decoded_onehz row) — the counter-joined delete above never selects
      // those. Their rr_ts_ms is the colliding second, so once the window is
      // pruned they're strictly before the cutoff; delete any beat in the
      // pruned window whose counter no longer exists in decoded_onehz.
      deleted += await txn.delete(
        'decoded_rr',
        where:
            'rr_ts_ms < ? AND counter NOT IN (SELECT counter FROM decoded_onehz)',
        whereArgs: [cutoffSec * 1000],
      );
      deleted +=
          await txn.delete('samples', where: 'ts < ?', whereArgs: [cutoffSec]);
      deleted +=
          await txn.delete('events', where: 'ts < ?', whereArgs: [cutoffSec]);
      deleted += await txn.delete('band_events',
          where: 'ts < ?', whereArgs: [cutoffSec]);
      deleted += await txn.delete('band_battery',
          where: 'ts < ?', whereArgs: [cutoffSec]);
    });
    return deleted;
  }

  /// Drop recomputable per-day intermediates left behind by superseded
  /// algorithm versions.
  ///
  /// `sleep_session_candidates` and `wake_day_features` are keyed
  /// (day_id, algo_version), so every kAlgoVersion bump writes a whole new
  /// generation beside the old one and nothing ever removed the old one — the
  /// tables grow without bound across releases. Neither is durable ledger:
  /// both are derived from `decoded_*` and rewritten whenever a day is
  /// re-derived.
  ///
  /// [keepVersions] generations are retained per day_id, newest first.
  /// Keeping more than one matters: a user on a GitHub release can roll back
  /// to the previous build, and pruning down to only the current version
  /// would leave that build with nothing to read for a day it never
  /// re-derives (raw retention is 3 days; a day older than that only gets a
  /// fresh-version row if something forces a re-derive).
  ///
  /// Scoped PER day_id, not table-wide. A table-wide "keep the 2 highest
  /// versions present ANYWHERE" cutoff deletes a day's only cached
  /// generation the moment any two OTHER days reach newer versions — not
  /// when this day does — because a day whose raw substrate has already
  /// aged out never re-enters the derive pipeline to write a newer row of
  /// its own. That silently orphaned still-needed rows for days that can
  /// never be re-derived.
  static Future<int> pruneSupersededIntermediates({int keepVersions = 2}) async {
    if (keepVersions < 1) return 0;
    final db = await instance;
    var deleted = 0;
    for (final table in const [
      'sleep_session_candidates',
      'wake_day_features',
    ]) {
      final rows = await db.rawQuery(
        'SELECT DISTINCT day_id, algo_version FROM $table',
      );
      final versionsByDay = <String, List<int>>{};
      for (final r in rows) {
        final day = r['day_id'] as String;
        final v = r['algo_version'] as int;
        (versionsByDay[day] ??= <int>[]).add(v);
      }
      // One transaction per table instead of one round-trip per day_id —
      // right after a kAlgoVersion bump forces a bulk re-derive (or a user
      // runs "Re-analyze data"), many days can cross the keepVersions
      // threshold in the same pass, and un-batched deletes on iOS run under
      // the same CPU-watchdog constraint the rest of derivation is careful
      // about.
      await db.transaction((txn) async {
        for (final entry in versionsByDay.entries) {
          final versions = entry.value..sort((a, b) => b.compareTo(a));
          if (versions.length <= keepVersions) continue;
          final cutoff = versions[keepVersions - 1];
          deleted += await txn.delete(
            table,
            where: 'day_id = ? AND algo_version < ?',
            whereArgs: [entry.key, cutoff],
          );
        }
      });
    }
    return deleted;
  }

  /// The DATA EDGE — the timestamp (epoch seconds) of the last canonical 1 Hz
  /// record we've durably stored.
  static Future<int?> lastDecodedRecTs() async {
    final db = await instance;
    return Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT MAX(rec_ts) FROM decoded_onehz WHERE rec_ts > 0',
      ),
    );
  }
}
