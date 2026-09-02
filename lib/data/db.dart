// Local raw-first storage (SQLite via sqflite).
//
// Durable storage layers:
//   decoded_onehz — canonical per-second decoded substrate, keyed by rec_ts.
//   decoded_rr    — sparse RR beats for that substrate, keyed by (rec_ts, beat_index).
//   samples       — legacy header cache kept only for backward-compat fallback.
//
// `counter` (u32 @[3:7]) is still kept as the strap's record id, but analytics
// read from canonical decoded tables keyed by physiological time so replayed or
// duplicated historical seconds cannot bloat compute.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../compute/substrate.dart' show beatTimesMs;
// The ONE thing this layer takes from compute/: the running build's algo
// version, which every day_result read applies as a CEILING (see [dayResult]).
// `show` keeps the rest of the engine out of this namespace.
import '../coach/coach_db.dart' show CoachDb;
import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../import/import_container.dart';
import 'day_label.dart';
import 'journal_fields.dart';
import 'live_coverage_policy.dart';
import 'med_store.dart';
import 'models.dart';
import 'nutrition_store.dart';
import 'observation.dart';
import 'series_codec.dart';

/// The outcome of a database rebuild: why the old file would not open, where it
/// was parked, and how many rows came back per table.
typedef DbRebuild = ({
  String cause,
  String quarantinePath,
  Map<String, int> salvaged,
});

// ── SUBSTRATE ADMISSION — the one predicate that decides what may become a
//    number ───────────────────────────────────────────────────────────────────
//
// THE THREE PROVENANCE COLUMNS ON `decoded_onehz` / `decoded_rr`, AND THE RULE
// THAT THEY DO NOT OVERLAP:
//
//   device_id      WHICH UNIT.       '' is the primary band, permanently
//                                    (see [_createDecodedStore]); a real id
//                                    belongs to a secondary.
//   device_family  THE CALIBRATION KEY. Which sensor's constants a metric must
//                                    look itself up under. NULL = unknown, and
//                                    unknown is its own case, never gen4.
//   source         THE ADMISSION FLAG. NULL = the primary band. Non-NULL names
//                                    the adapter that wrote the row.
//
// None of the three is a stand-in for another. `source` in particular is NOT a
// provenance id you may read to find out what a row came from — `device_id` and
// `device_family` are — it exists so this file can answer ONE question in SQL:
// may this row become a number?
//
// Why an adapter's rows are stored but not derived by default: correctness of a
// community decoder cannot be enforced by review, and a decoder with a 2x scale
// error reads a resting 50 bpm as 100 and passes every generic physiological
// bound. So an unverified adapter's seconds bank, sync, back up and show up in
// diagnostics — and produce no metric at all until the owner has held that
// hardware in his own hands (ASSUMPTIONS R6/E5/E6). Silent, on purpose: the
// alternative is a plausible wrong number, which is the one failure this
// project treats as worse than an absent one.
//
// NOTE THE DIFFERENCE FROM MULTIBAND_PLAN §3.3, which said a verified adapter
// would write `source IS NULL` and so need no read-side change. It is written
// the other way round here — every non-band writer stamps its id, always, and
// ADMISSION IS A READ-SIDE DECISION — for two reasons that only show up later:
// verification is then REVOCABLE (a decoder bug found in v3 of an adapter is
// one edit to [kDerivableSources], not a data migration over rows that can no
// longer be told apart), and `source` keeps meaning something after a strap is
// verified, which is what lets [kPrimaryBandSourceSql] below still exist.

/// Non-NULL `source` values admitted to derivation: adapters the OWNER has
/// personally held and cross-confirmed (ASSUMPTIONS R6).
///
/// EMPTY TODAY, AND CORRECTLY SO. The only owner-confirmed band is the WHOOP 4,
/// which is the primary band and therefore writes `source IS NULL` — so the set
/// of *non-NULL* sources that may be derived from is genuinely empty, and
/// [derivableSourceSql] renders byte-identical SQL to the bare predicate it
/// replaced. It becomes non-empty the first time a strap earns it.
///
/// NOT the same set as `kOwnerConfirmedBandIds` in `ui2/profile/devices.dart`,
/// and deliberately not shared with it: that one holds BAND FAMILY ids
/// (`device_family`) and decides whether a badge says EXPERIMENTAL; this one
/// holds SOURCE values and decides whether a row may become a number. They
/// answer different questions off different columns and will diverge the moment
/// a family is decoded but its adapter is not yet trusted. Both are `ponytail:`
/// placeholders for the CODEOWNERS-gated `_verified.dart` (ASSUMPTIONS E5) —
/// when that lands it owns the owner-confirmation fact and BOTH of these read
/// from it. It must never become a CI rule, which hands the key to the PR
/// author.
const Set<String> kDerivableSources = <String>{};

/// SQL fragment for every read whose rows may become a NUMBER — a metric, a
/// baseline, a session aggregate, a day that gets derived.
///
/// [col] is the column expression, so a joined query passes `'d.source'`.
///
/// Interpolates [kDerivableSources] directly rather than binding parameters:
/// these are compile-time `const` identifiers from this repo's own source, and
/// the callers are `rawQuery` strings assembled at every call site. The
/// admission test pins the ids to `[a-z0-9_]` so this cannot become an
/// injection seam by accident.
String derivableSourceSql([String col = 'source']) => kDerivableSources.isEmpty
    ? '$col IS NULL'
    : '($col IS NULL OR $col IN '
          "(${kDerivableSources.map((s) => "'$s'").join(', ')}))";

/// SQL fragment for the reads that mean THE PRIMARY BAND SPECIFICALLY, not
/// "admitted to derive" — they look identical today and they are not the same
/// question, which is the whole reason both have names.
///
/// Three sites, one meaning each: where the band's own data starts and ends,
/// how far the band has synced, and what we are willing to write into the
/// operating system's health store under our name. A verified chest strap must
/// widen [derivableSourceSql] and must NOT widen this one.
const String kPrimaryBandSourceSql = 'source IS NULL';

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
    return _db = await _openOrRebuild();
  }

  /// Set when [_openOrRebuild] had to quarantine an unopenable database and
  /// rebuild. Null on every normal launch. AppState reads it so the user is
  /// TOLD what happened and what survived — a rebuild that happens silently is
  /// indistinguishable from data vanishing.
  static DbRebuild? lastRebuild;

  /// What a rebuild tries to save, in the order it tries — most irreplaceable
  /// first, so a salvage that gets cut short (a genuinely corrupt file gives up
  /// partway) has already banked the rows nothing can regenerate.
  ///
  /// Everything in the first block was typed by a human. Nothing re-measures
  /// it, nothing re-derives it, and it is not in the band's flash. The second
  /// block is measured-once data whose raw substrate is pruned at
  /// `rawRetentionDays`, so it is equally unrecoverable in practice. The third
  /// is the 3-day substrate: re-syncable in principle, but the band trims its
  /// flash as we ACK, so in practice this is the only copy of those days too.
  static const _salvageTables = [
    // Hand-entered. The only copy that exists anywhere.
    'journal',
    'journal_metric',
    'journal_field_def',
    'lab_result',
    'lab_marker_def',
    'strength_set',
    'exercise_def',
    'food_entry',
    'food_def',
    'med_def',
    'med_dose',
    'cycle_log',
    'cycle_symptom',
    'sleep_override',
    'sleep_nap',
    'breathing_session',
    'sessions',
    'workout_route',
    'workout_split',
    // Derived once, from raw that no longer exists.
    'day_result',
    'metric_series',
    'metric_series_version',
    'baselines',
    'raw_archive',
    'sync_cursor',
    // The retention window. Big, and last for that reason.
    'decoded_onehz',
    'decoded_rr',
    'samples',
    'events',
    'band_events',
    'band_battery',
  ];

  /// [_open], plus the one recovery that exists for a database that will not
  /// open at all.
  ///
  /// `onUpgrade` runs inside ONE exclusive transaction, so a step that throws
  /// rolls the whole ladder back, the on-disk `user_version` never advances,
  /// and the SAME step throws on the next launch, and the next. Every guard in
  /// the ladder above was added reactively, after a build shipped that bricked
  /// somebody — so the ladder will trip again. What was missing was what
  /// happens next: the app sat on the loading screen forever and reinstalling
  /// was the only way out, which takes the hand-typed entries with it.
  ///
  /// So: never delete, never wipe. Move the unopenable file aside, create a
  /// fresh one at the current schema, and merge back everything the old file
  /// will still hand over — [_salvageTables] order, each table guarded on its
  /// own, so one unreadable table costs that table and nothing else. The
  /// quarantined file STAYS on disk: if the salvage got less than everything,
  /// the rest is still in there and can be handed to a human.
  static Future<Database> _openOrRebuild() async {
    try {
      return await _open();
    } catch (e) {
      final dir = await getDatabasesPath();
      final path = p.join(dir, dbName);
      // A UNIQUE quarantine name every time. A fixed one would let a SECOND
      // rebuild overwrite the first rebuild's file — the one holding whatever
      // the tolerant salvage could not read — which is the one outcome this
      // whole path exists to prevent. Disk is the cheaper thing to spend here.
      final quarantine = p.join(
        dir,
        '$dbName.unopenable-${DateTime.now().millisecondsSinceEpoch}',
      );
      // The -wal/-shm siblings belong to the file being moved. Leaving them
      // beside a FRESH database of the same name hands that database someone
      // else's journal, which is how a recovery corrupts the thing it just
      // created. All three move together or none of them do — a rebuild that
      // cannot quarantine cleanly must fail loudly rather than half-destroy.
      final moved = <String>[];
      for (final suffix in const ['', '-wal', '-shm']) {
        final f = File('$path$suffix');
        if (!f.existsSync()) continue;
        await f.rename('$quarantine$suffix');
        moved.add(suffix);
      }
      final Database fresh;
      try {
        fresh = await _open();
      } catch (_) {
        // A FRESH database at the current schema will not open either, so this
        // is not something a rebuild fixes. Put the user's file back exactly
        // where it was — leaving them with the quarantine and no database is
        // strictly worse than leaving them where they started.
        for (final suffix in moved) {
          await File('$quarantine$suffix').rename('$path$suffix');
        }
        rethrow;
      }
      // Published BEFORE the salvage so `_mergeFromDbFile`'s own `instance`
      // resolves to the new file instead of re-entering this method.
      _db = fresh;
      var salvaged = const <String, int>{};
      try {
        // `_days` is the importer's bookkeeping key, not a table. The rebuild
        // card prints this map verbatim, so it read "Recovered: … _days 312 …"
        // as though a table by that name had survived — or "Empty: _days" as
        // though one had been lost. Drop it here; the card is the one surface
        // whose whole job is telling the truth about a data-loss event.
        salvaged = Map.of(
          await _mergeFromDbFile(
            quarantine,
            only: _salvageTables,
            tolerant: true,
          ),
        )..remove('_days');
      } catch (_) {
        // The quarantined file gave us nothing. The app still opens, and the
        // file is still there — that is the whole point of not deleting it.
      }
      lastRebuild = (
        cause: '$e',
        quarantinePath: quarantine,
        salvaged: salvaged,
      );
      return fresh;
    }
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
  static const int schemaVersion = 50;

  /// SQLite caps host parameters per statement (`SQLITE_MAX_VARIABLE_NUMBER` —
  /// only 999 on the builds shipped with older Android/iOS). Any `IN (?, ?, …)`
  /// built from row data MUST be chunked below this; a single day of
  /// `decoded_onehz` is 86 400 counters. Same reason `commitSyncBatch` chunks.
  static const int _maxSqlVars = 500;

  /// THE PRIMARY BAND'S `device_id`, and it is reserved permanently.
  ///
  /// Not a migration default — a standing rule, load-bearing twice over:
  ///  * The newest-wins dedupe on `decoded_onehz` only works while every row
  ///    from the one physical band shares one key value, so a post-reboot
  ///    counter reset and a re-drained record still collide.
  ///  * A BLE `remoteId` is NOT a stable identity (per-app CBPeripheral UUID
  ///    on iOS, a rotating RPA on Android). Letting one reach the key would
  ///    fragment one band into N identities across reinstalls.
  ///
  /// A SECONDARY device gets a real id, issued by its adapter from something
  /// the band emits across the handshake — never from the link.
  static const String kPrimaryDeviceId = '';

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
        await _createDevice(db);
        await _createWorkoutSuggestions(db);
        await _createSleepOverride(db);
        await _createSleepNap(db);
        await _createWorkoutRoute(db);
        await _createNotifFired(db);
        await _createAlarmSchedule(db);
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
          // The v17 step (or a v11-16 origin) may leave OLD counter-keyed decoded
          // tables here; the backfill below writes through the rec_ts-keyed
          // _queueDecodedOneHz, so convert to the current schema first (preserving
          // any existing rows), then reconstruct the rest from raw_records.
          await _rekeyDecodedStoreByRecTs(db);
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
        if (oldV < 29) {
          // Hand-entered blood work. Purely new tables; nothing existing is
          // read or rewritten.
          await _createLabTables(db);
        }
        if (oldV < 30) {
          // Paced-breathing history. New table only.
          await _createBreathingSessions(db);
        }
        if (oldV < 31) {
          // User edits to a day's naps. New table only — the detector's own
          // output is untouched and the edits replay over it.
          await _createSleepNap(db);
        }
        if (oldV < 32) {
          // Re-key raw_archive off the volatile `counter` onto frame `hex`.
          // `counter INTEGER PRIMARY KEY` + IGNORE silently DROPPED a distinct
          // undecodable frame whenever a post-reboot counter (reset to ~0)
          // collided with a still-present pre-reboot row — data loss in the
          // "never lose" table. Rebuild keyed by content. Existing rows have
          // unique counters, so the copy loses nothing; at most it collapses an
          // exact-duplicate hex, which is the dedup we want.
          //
          // raw_archive is normally created lazily in onOpen (_repairOpenSchema),
          // NOT in this ladder, so on an old DB it may not exist yet here — in
          // which case there is nothing to migrate and a fresh (hex-keyed) create
          // is all that's needed. DROP the old index name before the fresh CREATE
          // so it can't collide on the name the rename carried onto the aside
          // table (the leaked-`_new`-index footgun documented on the decoded
          // rebuild).
          final hasArchive = (await db.rawQuery(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='raw_archive'",
          )).isNotEmpty;
          if (hasArchive) {
            await db.execute(
              'ALTER TABLE raw_archive RENAME TO _raw_archive_old',
            );
            await db.execute('DROP INDEX IF EXISTS idx_raw_archive_captured');
            await _createRawArchive(db);
            await db.execute(
              'INSERT OR IGNORE INTO raw_archive '
              '(hex, counter, packet_type, rec_ts, captured_at, reason) '
              'SELECT hex, counter, packet_type, rec_ts, captured_at, reason '
              'FROM _raw_archive_old',
            );
            await db.execute('DROP TABLE _raw_archive_old');
          } else {
            await _createRawArchive(db);
          }
        }
        if (oldV < 33) {
          // RE-KEY the decoded ledger off the volatile record `counter` onto
          // rec_ts. The counter resets to ~0 on every reboot, so counter-as-PK
          // let a post-reboot second REPLACE-evict a pre-reboot one — silently,
          // unrecoverably deleting a 1 Hz row (raw_records is dropped).
          await _rekeyDecodedStoreByRecTs(db);
        }
        if (oldV < 34) {
          // Keep the per-second fields the band computes itself instead of
          // decoding and discarding them. Additive columns only — see
          // _ensureDecodedOneHzBandFields. MUST run after the v33 re-key, which
          // rebuilds decoded_onehz from an explicit column list.
          await _ensureDecodedOneHzBandFields(db);
        }
        if (oldV < 35) {
          // Nutrition. Purely new tables — nothing existing is read or
          // rewritten, and water stays in journal_metric.water_ml rather than
          // being duplicated here.
          await createNutritionTables(db);
        }
        if (oldV < 36) {
          // Medication and supplements. New tables only.
          await createMedTables(db);
        }
        if (oldV < 38) {
          // Strength sets. New tables only — `sessions` is untouched and the
          // sets hang off its id. (37 is reserved for symptoms, UI_WIRING §5.3;
          // skipping it costs nothing, and _repairOpenSchema creates these
          // idempotently anyway if the ladder lands out of order.)
          await _createStrengthTables(db);
        }
        if (oldV < 39) {
          // Make ABSENCE representable in the decoded ledger: the six sensor
          // columns lose their NOT NULL so a record that carried no accel /
          // no optical / no thermal reading stops being written as a real zero.
          await _relaxDecodedSensorNulls(db);
        }
        if (oldV < 40) {
          // `sessions.private` — the per-workout "keep this off the shared
          // surfaces" flag. Existing rows read 0, which is what they have
          // always meant. ADD COLUMN only, deliberately NOT the whole
          // `_ensureSessionSchema`: that also creates an index, which throws on
          // a DB whose `sessions` table this ladder has not created yet — and a
          // throw in here rolls the ENTIRE ladder back and quarantines the
          // user's database. `_addColumnIfMissing` is a no-op on a missing
          // table, and `_repairOpenSchema` does the rest at onOpen.
          await _addColumnIfMissing(
            db,
            'sessions',
            'private',
            'INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldV < 41) {
          // Which strap measured the row (see _ensureDeviceFamilyColumns).
          // ADD COLUMN only, idempotent, and a no-op on a table this ladder has
          // not created yet — a throw in here rolls the WHOLE ladder back.
          await _ensureDeviceFamilyColumns(db);
        }
        if (oldV < 42) {
          // ADDITIVE ONLY, and every step is a no-op on a table this ladder has
          // not created yet — a throw in here rolls the WHOLE ladder back.
          //
          //  * decoded_onehz.ambient_raw — the gen4 ambient-light channel,
          //    which until now was decoded and thrown away on every record.
          //  * sessions.trace_json / trace_samples — the frozen session trace.
          //  * metric_series_version — which build's maths wrote each day's
          //    scalars, backfilled from the version day_result already carries.
          //  * band_backlog — the strap's ring-buffer bookkeeping.
          //
          // No rewrite pass and no delete: `onUpgrade` runs inside openDatabase
          // under iOS's CPU watchdog (invariant 11). The raw_archive thinning
          // that lands with this version is deliberately NOT here — it runs on
          // the retention path, off the launch path, where a 500 MB back
          // catalogue can be cleared without a launch hang.
          await _ensureDecodedOneHzBandFields(db);
          await _ensureSessionTraceColumns(db);
          await _createMetricSeriesVersion(db);
          await _backfillMetricSeriesVersion(db);
          await _createBandBacklog(db);
        }
        if (oldV < 43) {
          // `decoded_onehz.source` / `decoded_rr.source` — which SENSOR produced
          // the row (see _ensureSourceColumns), plus the session-scoped landing
          // table for a standard Bluetooth heart-rate sensor. Both are ADD
          // COLUMN / CREATE TABLE only and no-ops on a table this ladder has not
          // created yet — a throw in here rolls the WHOLE ladder back.
          await _ensureSourceColumns(db);
          await _createExternalHr(db);
          await _createImportedMeasurement(db);
          // ADD COLUMN / CREATE TABLE only, each a no-op on a table this ladder
          // has not created yet:
          //  * decoded_onehz.temp_ch2_c / temp_ch3_c / signal_quality_logvar —
          //    the gen5 channels the mapper decoded and dropped (MT-12).
          //  * sessions.rpe — session-level self-reported exertion (TS-09).
          //  * metric_series_version.source — measured vs imported, in every
          //    export (export-provenance), on L13's existing side table.
          //  * workout_split — per-km splits frozen at finalize (CV-01/TS-07),
          //    because `decoded_onehz` is gone at 3 days and cannot be re-read.
          await _ensureDecodedOneHzBandFields(db);
          await _addColumnIfMissing(db, 'sessions', 'rpe', 'REAL');
          await _addColumnIfMissing(db, 'sessions', 'cadence_spm', 'INTEGER');
          await _addColumnIfMissing(
            db,
            'metric_series_version',
            'source',
            'TEXT',
          );
          await _createWorkoutSplit(db);
          // LAST, and the only rewrite in this rung: `decoded_onehz.hr` loses
          // its NOT NULL. Runs after every ADD COLUMN above so the rebuild
          // carries them across.
          await _relaxDecodedHrNull(db);
        }
        if (oldV < 44) {
          // GATES 4b — NO SCHEMA CHANGE. The one rung on this ladder that is a
          // data recovery rather than a DDL step: archived records that this
          // build's decoders can now read are replayed into `decoded_onehz`.
          //
          // Here and not on the retention path (where `thinRawArchiveBefore`
          // runs) for two reasons: the recovered seconds are OLDER than the
          // retention edge, so a prune-time replay would insert them and delete
          // them in the same pass; and derivation has to see them, which means
          // landing before the next derive, not after it.
          //
          // Bounded by `redrivableArchiveReasons` precisely so it is not the
          // heavy pass the v42 rung refuses to do here: it is 1,035 short
          // frames on the largest real export, not the 492 MB of v20 hex
          // sitting beside them.
          await redriveArchivedRecords(db);
        }
        if (oldV < 45) {
          // `band_battery.charge_units` — ADD COLUMN, idempotent, a no-op on a
          // table this ladder has not created yet — plus the one-time replay of
          // stored band events into the series that had a reader, a widget and
          // no writer. Both bounded; see _backfillBandBatteryFromEvents for why
          // the replay is safe to run on the launch path and the v42 rung's
          // rewrite was not.
          await _ensureBandBatteryChargeUnits(db);
          await _backfillBandBatteryFromEvents(db);
        }
        if (oldV < 46) {
          // Retire the disproven gen5 columns that v34-era dev builds banked
          // (`on_wrist` / `hr_valid`, plus the -50.00 °C skin-temp sentinel).
          // Data-only: the DDL is untouched, so this does NOT diverge an
          // upgraded install's schema from a fresh one. See
          // _retireDisprovenOneHzColumns for the evidence.
          await _retireDisprovenOneHzColumns(db);
        }
        if (oldV < 47) {
          // Put `device_id` in front of the key of the three stores whose
          // identity was a WHOOP-shaped quantity (a record second, the band's
          // flash counter). The one item on the band-agnostic list that cannot
          // be done after a second device has written — see
          // [_rekeyStoresByDeviceId]. Rewrites no value and moves no derived
          // number, so it ships without a kAlgoVersion bump.
          //
          // LAST on the ladder, after every ADD COLUMN above, because the
          // rebuild reconstructs its DDL from `PRAGMA table_info` and so
          // carries across exactly the columns that exist when it runs.
          await _rekeyStoresByDeviceId(db);
        }
        if (oldV < 48) {
          // The observation store — vendor-computed, typed-in and imported
          // scalars. CREATE TABLE IF NOT EXISTS + two indexes and NOTHING
          // else: no backfill, no rewrite, no ADD COLUMN, nothing read. It is
          // a new empty table, so the CHECK and the UNIQUE index have no
          // existing row to fail on — which matters, because a throw in here
          // rolls the WHOLE ladder back and quarantines the user's database
          // (invariant 11), and this rung runs after the v47 re-key that every
          // upgrading install is already paying for on the launch path.
          //
          // Ships without a kAlgoVersion bump, deliberately: nothing writes
          // this table, nothing reads it, and no derived number can move.
          await _createObservation(db);
        }
        if (oldV < 49) {
          // The device store, and the `live_coverage` column that lets the step
          // ladder tell two sensors apart. CREATE TABLE IF NOT EXISTS + ONE
          // guarded ADD COLUMN: no backfill, no rewrite, nothing read, and both
          // are no-ops on a table this ladder has not created yet — which is
          // what keeps it off the wrong side of invariant 11 (a throw in here
          // rolls the WHOLE ladder back and quarantines the user's database).
          //
          // ADD COLUMN with a constant DEFAULT does not rewrite the table, so
          // this rung is O(1) in `live_coverage` rows rather than O(n) — unlike
          // the v47 re-key every upgrading install is already paying for.
          //
          // Ships without a kAlgoVersion bump: every existing row takes
          // `device_id = ''`, one id is one sensor, and [resolveDaySteps]
          // returns exactly the totals it returned yesterday.
          await _createDevice(db);
          await _ensureLiveCoverageDeviceId(db);
        }
        if (oldV < 50) {
          // The weekly alarm schedule — one row per weekday (0=Mon..6=Sun,
          // matching the 0-indexed convention `workout_screen.dart` already
          // uses for weekday array positions; DateTime.weekday itself stays
          // 1=Mon..7=Sun everywhere else). CREATE TABLE IF NOT EXISTS and
          // NOTHING else: a new empty table has no existing row for the PK to
          // reject, so a throw here has nothing to roll back onto — which
          // matters, because a throw in here rolls the WHOLE ladder back and
          // quarantines the user's database (invariant 11). The legacy
          // single-alarm value (`alarm_epoch` in SharedPreferences) is seeded
          // into this table from AppState at startup, not here — this layer
          // never touches SharedPreferences (see the doc on _createDevice's
          // neighbours), and a plugin-channel read has no place inside a
          // migration ladder step running under iOS's CPU watchdog.
          //
          // Ships without a kAlgoVersion bump: the alarm is not a health
          // metric and nothing here changes a derived number.
          await _createAlarmSchedule(db);
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
    await _ensureBandBatteryChargeUnits(db);
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
    //
    // Plus `idx_decoded_onehz_counter`, which was never on a read path at all —
    // see _createDecodedStore for why it is gone rather than merely unused.
    for (final ix in const [
      'idx_decoded_onehz_new_rects',
      'idx_decoded_onehz_new_rec_ts_unique',
      'idx_decoded_rr_new_counter',
      'idx_decoded_rr_new_ts',
      'idx_decoded_rr_new_ts_beat_unique',
      'idx_decoded_onehz_counter',
    ]) {
      await db.execute('DROP INDEX IF EXISTS $ix');
    }
    await _createLiveCoverage(db);
    await _ensureLiveCoverageSource(db);
    await _ensureLiveCoverageDeviceId(db);
    await _createDevice(db);
    await _createExternalHr(db);
    await _createImportedMeasurement(db);
    // CREATE TABLE IF NOT EXISTS on the every-open repair path, and NO schema
    // version bump: this table is additive with no backfill, so the repair pass
    // creates it on a fresh install and on an existing one alike. Spending a
    // version number here would collide with the other branches reaching for
    // the next one, and buy nothing a no-op CREATE does not already do.
    await _createImportedWorkout(db);
    await _createObservation(db);
    await _createCycleSymptom(db);
    await _ensureSessionSchema(db);
    await _ensureSyncStateSchema(db);
    await _createWorkoutSuggestions(db);
    await _createSleepOverride(db);
    await _createSleepNap(db);
    await _createWorkoutRoute(db);
    await _ensureWorkoutRouteSpeed(db);
    await _createWorkoutSplit(db);
    await _ensureBreathingWindowColumns(db);
    // Self-skipping (one PRAGMA) unless the table really is still NOT NULL —
    // the same-version merged-build case this whole method exists for.
    await _relaxDecodedHrNull(db);
    await _ensureDayResultSkippedColumn(db);
    await _ensureDayResultPartialColumn(db);
    await _createNotifFired(db);
    await _createAlarmSchedule(db);
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

  /// v34: the per-second fields a gen5 band computes on its own and reports in
  /// every record — its pedometer's cumulative step count and cadence, its
  /// activity class, a calibrated skin temperature in °C, its on-wrist
  /// determination, and the HR-validity flag plus the second HR byte that
  /// corroborates the primary one. They used to be decoded and dropped.
  ///
  /// v42 adds `ambient_raw` here rather than in its own helper. It is the other
  /// direction (gen4-only — gen5 has no per-second equivalent), but it needs
  /// the exact same treatment for the exact same reason: the mid-ladder
  /// `_backfillDecodedStore` writes through `_queueDecodedOneHz`, which names
  /// the column, so every rebuild path has to hand it back before the backfill
  /// runs or the whole exclusive ladder rolls back. That is what this helper is
  /// for, and every rebuild already calls it.
  ///
  /// Additive and safe on a populated DB: eight nullable columns, no rewrite of
  /// the (million-row) table, no backfill. Existing rows read NULL — which is
  /// the truth for them, since the values were never stored. `skin_temp_raw`,
  /// `skin_contact` and the `spo2_*` columns are deliberately left alone; they
  /// hold real historical data regardless of what the names now suggest.
  static Future<void> _ensureDecodedOneHzBandFields(Database db) async {
    const cols = {
      'step_count': 'INTEGER',
      'step_cadence': 'INTEGER',
      'activity_class': 'INTEGER',
      'skin_temp_c': 'REAL',
      'on_wrist': 'INTEGER',
      'hr_valid': 'INTEGER',
      'hr_alt': 'INTEGER',
      // Ambient-light ADC, u16 @inner[70] on a gen4 R24 record. A RELATIVE
      // count on the user's own scale, never lux — and one-sided: bright means
      // bright, dark means nothing (a sleeve or a duvet reads dark in a lit
      // room). 0 is the absent sentinel, not a reading — see _queueDecodedOneHz.
      'ambient_raw': 'INTEGER',
      // v43 (MT-12): the gen5 record's SECOND and THIRD temperature channels
      // (i16 ÷10 °C), decoded by protocol and dropped by the mapper until now.
      //
      // DELIBERATELY NOT NAMED AFTER A BODY PART. protocol itself calls their
      // semantics loose, and naming one of them is exactly how gen4's
      // `skin_temp_raw` came to feed readiness as if it were a skin
      // temperature. `temp_ch2` / `temp_ch3` is the channel index and nothing
      // else. If they turn out to be die or battery temperature they are not
      // body signals and stay unread — persisting them claims NOTHING, which
      // is the entire point of the column. Assume dual-heat-flux core temp is
      // UNAVAILABLE: that method needs two characterised sensors and a known
      // thermal resistance, and we have neither.
      'temp_ch2_c': 'REAL',
      'temp_ch3_c': 'REAL',
      // The band's own per-second signal-quality figure (log-variance, f32).
      // Its scale is the band's, so it can only ever be a WITHIN-NIGHT rank or
      // a weight — never a percentage, never a bar, never "HRV confidence 82%".
      'signal_quality_logvar': 'REAL',
      // MT-12's last channel: the band's own gravity-removed motion magnitude
      // for this second (f32 g). Named for what protocol says it is and
      // nothing more. It is NOT our ENMO — we do not know the band's window,
      // filter or statistic — so it may not be substituted for one, and
      // nothing reads it. Same contract as the two temp channels: persisting
      // claims nothing, and that is what makes it possible to find out later
      // whether it agrees with the ENMO we compute over the same seconds.
      //
      // Not a ladder rung. `_ensureDecodedOneHzBandFields` runs from
      // `_createDecodedStore`, which `_repairOpenSchema` calls on EVERY open,
      // so an existing install gets the column for one PRAGMA without
      // spending a schema version other branches are also reaching for.
      'dyn_accel_g': 'REAL',
      // The record's own sub-second, u16 in units of 1/32768 s. BOTH
      // GENERATIONS SEND IT and both decoders have always read it; nothing
      // carried it past the decoder, so every record in this table was pinned
      // to a whole second. Stored as the strap's own ticks, NOT converted to
      // ms: the conversion is lossy and the raw count is what the strap said.
      // See Sample.tsSubsec and beatTimesMs.
      'ts_subsec': 'INTEGER',
      // The band's own coarse wake/sleep code (2 bits: 0 wake, 1 still,
      // 2 sleep, 3 up) — GEN5/MG ONLY, null on gen4.
      //
      // AN ENVELOPE, NOT A STAGE, and the column may only ever be read as one:
      // deep, light and REM all read `sleep`, and it lags true onset by ~10
      // minutes. It cannot improve a hypnogram and must never be written into
      // one. Its value is that it is an OUTSIDE OPINION on a staging pipeline
      // that is otherwise single-source — the disagreement between our sleep
      // window and the band's is a thing this app currently cannot even see.
      // Stored as the raw code rather than a name: a name freezes a meaning.
      // See Sample.bandSleepState for the evidence that it varies and means
      // what it says.
      'band_sleep_state': 'INTEGER',
    };
    final have = await _columnsOf(db, 'decoded_onehz');
    if (have.isEmpty) return; // table not created yet — the DDL carries them
    for (final e in cols.entries) {
      if (have.contains(e.key)) continue;
      await _addColumnIfMissing(db, 'decoded_onehz', e.key, e.value);
    }
  }

  /// v41: `device_family` — WHICH STRAP MEASURED THIS ROW.
  ///
  /// Stamped AT INGEST from the link that produced it (`ble_engine` pins the
  /// generation at service discovery), because that is the only moment anyone
  /// actually knows. It is never inferred from the data afterwards and never
  /// backfilled with a guess: a gen4 skin-temp ADC count and a gen5 centi-°C
  /// reading share `decoded_onehz`'s columns, so a wrong stamp is worse than no
  /// stamp. Existing rows — and anything imported, which came from no link at
  /// all — read NULL, meaning UNKNOWN PROVENANCE, which readers must treat as
  /// its own case (analytics: `calibrationFor` → null → refuse) rather than as
  /// gen4.
  ///
  /// Nullable TEXT, no DEFAULT, ever: a default would turn "we don't know" into
  /// a claim about the sensor.
  static Future<void> _ensureDeviceFamilyColumns(Database db) async {
    for (final t in const ['decoded_onehz', 'decoded_rr', 'sessions']) {
      await _addColumnIfMissing(db, t, 'device_family', 'TEXT');
    }
  }

  /// v43: `source` — WHICH SENSOR PRODUCED THIS ROW, as distinct from which
  /// strap generation ([_ensureDeviceFamilyColumns]).
  ///
  /// NULL means the band — every row ever written before this column existed,
  /// every import, every raw replay, and every byte the WHOOP link will ever
  /// deliver. A non-NULL value means a peripheral that is NOT the band (today:
  /// a standard Bluetooth heart-rate sensor, `0x180D`).
  ///
  /// This lands BEFORE the first 0x180D byte does, and it exists for exactly
  /// one reason: resting HR from a chest strap and resting HR from wrist PPG
  /// differ SYSTEMATICALLY. Quietly folding both into one baseline puts a step
  /// change into every long-horizon number the app keeps, which surfaces to the
  /// user as readiness reading wrong with no visible cause and no way to find
  /// it. So every read that feeds a baseline, a derive page or the data edge
  /// filters on provenance, and the filter is in place while the answer is
  /// still trivially "all of them".
  ///
  /// THE COLUMN IS AN ADMISSION FLAG, NOT A PROVENANCE ID — see the
  /// SUBSTRATE ADMISSION block at the top of this file, which states the
  /// non-overlap rule for all three provenance columns and owns the two SQL
  /// fragments ([derivableSourceSql], [kPrimaryBandSourceSql]) that every
  /// reader must use instead of writing the predicate by hand.
  ///
  /// Nullable TEXT, no DEFAULT: the same reason `device_family` has none.
  static Future<void> _ensureSourceColumns(Database db) async {
    for (final t in const ['decoded_onehz', 'decoded_rr']) {
      await _addColumnIfMissing(db, t, 'source', 'TEXT');
    }
  }

  /// `decoded_rr.beat_ts_ms` — where the beat actually was, beside the
  /// whole-second `rr_ts_ms` rather than instead of it. NULL on every row
  /// written before this column existed, and that NULL is the honest value: the
  /// sub-second it is built from was never stored and the frames it could be
  /// re-read from are pruned. See [beatTimesMs].
  ///
  /// Not a ladder rung, same as `dyn_accel_g`: `_ensureDecodedStore` runs from
  /// `_repairOpenSchema` on every open, so an existing install gets the column
  /// for one PRAGMA without spending a schema version.
  static Future<void> _ensureBeatTimeColumn(Database db) =>
      _addColumnIfMissing(db, 'decoded_rr', 'beat_ts_ms', 'INTEGER');


  /// v46: retire what v34 banked into `on_wrist` / `hr_valid`, and any
  /// `skin_temp_c` that is really the sensor's unavailable sentinel.
  ///
  /// v34 filled `on_wrist` from gen5 v18 body 60 bits 0-1 and `hr_valid` from
  /// body 15 bit7. Both readings are disproven: bits 0-1 are the primary-flags
  /// bit-8 snapshot (not wear), and bit7 toggles ~50/50 independently of HR
  /// presence across 1,587,671 retained records (not validity). `skin_temp_c`
  /// could likewise hold the AS6221 -50.00 °C unavailable/error code, which is
  /// not a temperature. The writer stopped emitting all three
  /// (`sampleFromGen5Historical`); this clears what it already stored, so no
  /// future reader can pick up a confident answer the data never supported.
  ///
  /// DDL-NEUTRAL on purpose: the columns stay, nullable, exactly as v34 created
  /// them, so a fresh install and an upgraded one still end at the same schema
  /// (the fields remain the right shape should an honest source ever appear).
  /// Idempotent — a second run matches no rows. Cheap enough for the iOS
  /// open-database watchdog: `decoded_onehz` is bounded by `rawRetentionDays`,
  /// this is one scan, and it writes only the rows that carry a value.
  static Future<void> _retireDisprovenOneHzColumns(Database db) async {
    final have = await _columnsOf(db, 'decoded_onehz');
    // Pre-v34 tables never had the columns; nothing to retire.
    if (!have.contains('on_wrist')) return;
    await db.execute(
      'UPDATE decoded_onehz SET '
      'on_wrist = NULL, '
      'hr_valid = NULL, '
      'skin_temp_c = CASE WHEN skin_temp_c <= -49.995 THEN NULL '
      'ELSE skin_temp_c END '
      'WHERE on_wrist IS NOT NULL OR hr_valid IS NOT NULL '
      'OR skin_temp_c <= -49.995',
    );
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

  // ── alarm_schedule — the weekly wake-alarm schedule ─────────────────────

  static Future<void> _createAlarmSchedule(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS alarm_schedule (
        weekday INTEGER NOT NULL,
        hour    INTEGER NOT NULL,
        minute  INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (weekday)
      )
    ''');
  }

  /// Every configured weekday row, in no particular order — callers that care
  /// about weekday order (the UI, [nextAlarmOccurrence]) sort/fill it
  /// themselves. A weekday absent from this list has never been configured;
  /// it is NOT the same as a row with `enabled = 0`, and callers must not
  /// collapse the two (see `AlarmScheduleEntry` / `fillDefaultAlarmSchedule`
  /// in state/alarm_schedule.dart, which is where that distinction is made).
  static Future<List<Map<String, Object?>>> alarmScheduleRows() async {
    final db = await instance;
    return db.query('alarm_schedule');
  }

  /// Upsert one weekday's slot. [weekday] is 0=Mon..6=Sun (see
  /// `_createAlarmSchedule`'s doc); out-of-range values are the caller's bug,
  /// not something this layer silently clamps.
  static Future<void> setAlarmScheduleDay({
    required int weekday,
    required int hour,
    required int minute,
    required bool enabled,
  }) async {
    final db = await instance;
    await db.insert(
      'alarm_schedule',
      {
        'weekday': weekday,
        'hour': hour,
        'minute': minute,
        'enabled': enabled ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Wipe the whole weekly schedule — the "Cancel-all" half of disabling the
  /// alarm (see AppState.disableAlarm), so a cancelled alarm cannot silently
  /// re-arm itself from a schedule the user thought they'd cleared.
  static Future<void> clearAlarmSchedule() async {
    final db = await instance;
    await db.delete('alarm_schedule');
  }

  /// sleep_nap — the user's edits to a day's naps.
  ///
  /// Separate from `sleep_override` on purpose: that table means "the main
  /// sleep window for this day", which is one thing, while naps are a list.
  /// Widening its primary key would have made "the main sleep" and "a nap"
  /// indistinguishable in storage.
  ///
  /// Edits are stored SEPARATELY from the detector's output and replayed over
  /// it on every derivation. The detector improves; a day re-derived under a
  /// better stager should still respect "there was no nap here", and baking
  /// the edit into the result would freeze the old detection alongside it.
  ///
  /// `source` is 'manual' (a nap the user logged) or 'rejected' (a detected
  /// one they removed — the window is stored so it keeps suppressing that nap
  /// even after the detector's bounds shift by a minute).
  static Future<void> _createSleepNap(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_nap (
        day_id TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (day_id, start_ts)
      )
    ''');
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

  // ── IMPORTED MEASUREMENTS FROM DEVICES WE ARE NOT ───────────────────────────
  /// Readings a CLEARED device took and wrote to the phone's health store: a
  /// blood-pressure cuff, a CGM, a thermometer.
  ///
  /// THE WHOLE VALUE IS THAT OPENSTRAP DID NOT MEASURE IT. The source name is
  /// mandatory and travels with every row, and these never blend into a
  /// composite of ours — there is no "combined" anything, and no derived number
  /// takes one of these as an input.
  ///
  /// ⚠️ READ-ONLY INPUTS TO DISPLAY. NEVER TRAINING TARGETS. ⚠️
  /// The moment a cuff series exists in the same database as a wrist PPG
  /// series, someone will want to fit a wrist→blood-pressure mapping on it.
  /// That is a cuffless-blood-pressure claim from a device cleared for nothing
  /// of the kind, and that path ends at a regulator's warning letter. These
  /// rows may be SHOWN next to ours and may never be REGRESSED against ours.
  /// This comment lives here, at the table, and not only in a document,
  /// because the document is not what the next person reads.
  ///
  /// Keyed by the store's own record uuid, so re-reading the same window is
  /// idempotent and an edit made in the source app lands as an update.
  /// Readings taken by a device that is CLEARED to take them — a BP cuff, a
  /// CGM, a thermometer. `source` is NOT NULL because the whole value of these
  /// rows is that OpenStrap did not measure them.
  ///
  /// READ-ONLY INPUTS TO DISPLAY. NEVER TRAINING TARGETS. the moment a cuff
  /// series and a wrist PPG series live in one database, the obvious next idea
  /// is to fit one to the other — and a wrist→BP mapping is a cuffless blood
  /// pressure claim from an uncleared device, which is the exact category that
  /// earned WHOOP an FDA Warning Letter in Jul 2025 (trend-only, no units, and
  /// the general-wellness defence was rejected anyway). so: this table may be
  /// JOINed for display. it may not be joined to `decoded_onehz`, `decoded_rr`
  /// or `metric_series` to fit, calibrate, validate or regress anything of
  /// ours, and no derived value may take one of these rows as an input.
  ///
  /// NEVER BLENDED either — no combined series, no averaging an imported
  /// reading with one of ours, no "your blood pressure" without the cuff's name
  /// attached. see health/health_measurement_import.dart, which states the same
  /// guard on the write side; it is in both places on purpose.
  static Future<void> _createImportedMeasurement(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS imported_measurement (
        uuid TEXT PRIMARY KEY,
        ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT NOT NULL,
        source TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imported_measurement_kind '
      'ON imported_measurement(kind, ts)',
    );
  }

  /// Upsert imported readings. Idempotent on the source store's uuid.
  static Future<int> putImportedMeasurements(
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return 0;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert(
          'imported_measurement',
          r,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    return rows.length;
  }

  /// Imported readings of one kind, newest first. The caller renders the
  /// `source` with the value; a row without its source is not renderable.
  static Future<List<Map<String, dynamic>>> importedMeasurements(
    String kind, {
    int limit = 200,
  }) async {
    final db = await instance;
    return db.query(
      'imported_measurement',
      where: 'kind = ?',
      whereArgs: [kind],
      orderBy: 'ts DESC',
      limit: limit,
    );
  }

  // ── DEVICES (the things that measure) ─────────────────────────────────────
  /// The devices this phone knows about, one row each.
  ///
  /// Until now a "device" was TWO SharedPreferences scalars (`paired_remote_id`
  /// / `paired_serial`), which can hold exactly one band, carries no state
  /// beside the id, and cannot be joined to anything. `decoded_onehz`,
  /// `decoded_rr` and `samples` have been keyed by `device_id` since v47 with
  /// nothing on the other end of that key — this is the other end.
  ///
  /// `id` IS the `device_id` those tables carry, so [kPrimaryDeviceId] (`''`)
  /// is this table's primary row, permanently (ASSUMPTIONS A1). That is what
  /// keeps an unstable BLE `remoteId` — a per-app CBPeripheral UUID on iOS, a
  /// rotating RPA on Android — out of the key: it lives in `remote_id`, a plain
  /// column that may change under the same row as often as the OS likes.
  ///
  ///  * `adapter_id` — the `BandEntry.id` from the registry (`gen4`/`gen5`), or
  ///    NULL when the link has not said yet. NULL is a refusal, not a default:
  ///    every metric that looks its constants up per family abstains on it
  ///    rather than borrowing gen4's numbers, and the device screen says so.
  ///  * `label` — the band's own advertising name / serial, already passed
  ///    through `cleanDeviceLabel`. Never junk, never a placeholder.
  ///  * `tier` — the `SourceTier` enum NAME (measurement quality, which is the
  ///    only thing that decides precedence between two sources).
  ///  * `first_seen` / `last_seen` — epoch seconds.
  ///
  /// ponytail: no `UPSERT`. `INSERT … ON CONFLICT DO UPDATE` needs SQLite 3.24
  /// and minSdk 26 ships 3.18 (the same floor the `observation` index reasons
  /// about), so [upsertDevice] is INSERT OR IGNORE + UPDATE.
  static Future<void> _createDevice(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS device (
        id          TEXT PRIMARY KEY,
        adapter_id  TEXT,
        remote_id   TEXT,
        label       TEXT,
        tier        TEXT,
        first_seen  INTEGER NOT NULL,
        last_seen   INTEGER NOT NULL
      )
    ''');
  }

  /// Record that [id] exists and was seen now. Every field except [id] is
  /// COALESCED, so a caller that only knows the remote id cannot blank out a
  /// label or an adapter another caller already established.
  ///
  /// [clearAdapterId] is the one deliberate exception, and it exists because
  /// COALESCE is wrong in exactly one case: this row is the PRIMARY band
  /// permanently (`id` is `''`), so pairing a DIFFERENT band reuses it, and a
  /// null [adapterId] would then leave the FORGOTTEN band's family on the new
  /// one. `PairedDevice.save` passes it when the remote id changed and the
  /// caller does not know the new band's family. It is ignored when
  /// [adapterId] is non-null — a caller that knows wins over one that clears.
  static Future<void> upsertDevice({
    String id = kPrimaryDeviceId,
    String? adapterId,
    String? remoteId,
    String? label,
    String? tier,
    bool clearAdapterId = false,
  }) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.insert('device', {
      'id': id,
      'adapter_id': adapterId,
      'remote_id': remoteId,
      'label': label,
      'tier': tier,
      'first_seen': now,
      'last_seen': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    // ONE flag decides both the placeholder and its argument. It is a local
    // and not the expression twice because the two must never disagree: a
    // statement whose `?` count differs from the argument list binds every
    // value one column to the left, which SQLite accepts silently.
    final blankAdapter = adapterId == null && clearAdapterId;
    await db.rawUpdate(
      'UPDATE device SET '
      '${blankAdapter ? 'adapter_id = NULL, ' : 'adapter_id = COALESCE(?, adapter_id), '}'
      'remote_id = COALESCE(?, remote_id), label = COALESCE(?, label), '
      'tier = COALESCE(?, tier), last_seen = ? WHERE id = ?',
      [
        if (!blankAdapter) adapterId,
        remoteId,
        label,
        tier,
        now,
        id,
      ],
    );
  }

  /// One device row, or null when this phone has never seen it.
  static Future<Map<String, Object?>?> deviceRow([
    String id = kPrimaryDeviceId,
  ]) async {
    final db = await instance;
    final r = await db.query('device', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  /// Every device this phone knows about, most recently seen first.
  static Future<List<Map<String, Object?>>> deviceRows() async {
    final db = await instance;
    return db.query('device', orderBy: 'last_seen DESC');
  }

  /// Forget one device. The MEASUREMENTS it wrote are untouched — "this
  /// removes the source, not the data", which is what the forget dialog
  /// promises and what `decoded_*` keeping its `device_id` makes possible.
  static Future<void> deleteDevice([String id = kPrimaryDeviceId]) async {
    final db = await instance;
    await db.delete('device', where: 'id = ?', whereArgs: [id]);
  }

  // ── OBSERVATIONS (vendor-computed / typed-in / imported scalars) ───────────
  /// Everything that is NOT a raw sensor sample and NOT computed by us:
  /// a `reports` band's own conclusions, the user's typed-in numbers, and
  /// another app's history. See docs/OBSERVATION_SPEC.md.
  ///
  /// THE SINGLE INVARIANT, and it is the whole safety story: **nothing reads
  /// this table into a baseline, into a trend that also carries derived
  /// values, or into any input to a derivation.** Held the same way
  /// `imported_measurement` holds its own version of the rule — a SEPARATE
  /// table, so the only way to violate it is to name it somewhere new, and
  /// `observation_isolation_test.dart` fails the moment anyone does. If it is
  /// ever violated the failure is SILENT: an unexplained step change in a
  /// long-horizon number, months later, with no way to tell which day broke it.
  ///
  /// IDENTITY IS AN EXPRESSION INDEX, NOT A PRIMARY KEY, and that is not a
  /// stylistic choice. The spec's key is
  /// `(device_id, ts_ms, source_kind, COALESCE(vendor_key, key))`, and SQLite
  /// takes no expression in a table-level PRIMARY KEY. The two obvious repairs
  /// both fail:
  ///
  ///  * A `GENERATED ALWAYS AS (COALESCE(...)) STORED` column is rejected
  ///    outright — "generated columns cannot be part of the PRIMARY KEY" — and
  ///    generated columns need SQLite 3.31 (2020) besides, which minSdk 26
  ///    (Android 8 ships 3.18) does not have.
  ///  * A plain composite `PRIMARY KEY (…, vendor_key, key)` COMPILES AND IS
  ///    WRONG. A PRIMARY KEY on a rowid table is a UNIQUE INDEX, and SQLite
  ///    treats NULLs in one as DISTINCT — so two rows with the same
  ///    `vendor_key` and a NULL `key` do not collide, `INSERT OR REPLACE` does
  ///    not replace, and a re-import silently doubles every composite it
  ///    carries. Proven, not assumed.
  ///
  /// A UNIQUE INDEX may hold an expression (SQLite 3.9, 2015 — safely below
  /// the Android 8 floor), `INSERT OR REPLACE` resolves against it exactly as
  /// it would against a PRIMARY KEY, and `COALESCE` is non-NULL whenever the
  /// CHECK holds, so the NULL-distinctness trap never arms. The CHECK is what
  /// makes that true, which is why it is a DB constraint and not a Dart assert.
  ///
  /// `device_id = ''` is the primary band, permanently — the standing rule
  /// established for `decoded_onehz` at v47, and for the same reason: a BLE
  /// remoteId is not a stable identity.
  ///
  /// ponytail: scalars only (`value REAL` + `unit TEXT`). A vendor hypnogram
  /// or a vendor GPS track is not a scalar and has no consumer — give it a
  /// table of its own when something is actually going to read it.
  static Future<void> _createObservation(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS observation (
        device_id    TEXT NOT NULL DEFAULT '',
        ts_ms        INTEGER NOT NULL,
        date         TEXT NOT NULL,
        source_kind  TEXT NOT NULL,
        vendor_key   TEXT,
        key          TEXT,
        value        REAL,
        unit         TEXT,
        attribution  TEXT NOT NULL,
        CHECK (vendor_key IS NOT NULL OR key IS NOT NULL)
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_observation_identity '
      'ON observation(device_id, ts_ms, source_kind, COALESCE(vendor_key, key))',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_observation_date '
      'ON observation(date, source_kind)',
    );
  }

  /// Upsert observations. Idempotent on `(device_id, ts_ms, source_kind, name)`
  /// so re-running an import re-states rather than duplicates.
  ///
  /// `date` comes from [dayLabelOf] and nowhere else — the day model is LOCAL
  /// calendar days, and a label computed any other way is wrong for 23 h/25 h
  /// DST days and for every user whose local date differs from UTC's.
  ///
  /// There is deliberately NO reader here yet. Nothing writes observations
  /// either: the adapter seam that will is phase 4, and wiring an existing
  /// importer into this table today would move numbers users already see.
  static Future<int> putObservations(
    List<Observation> rows, {
    String deviceId = kPrimaryDeviceId,
  }) async {
    if (rows.isEmpty) return 0;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final o in rows) {
        batch.insert('observation', {
          'device_id': deviceId,
          'ts_ms': o.at.millisecondsSinceEpoch,
          'date': o.date,
          'source_kind': o.sourceKind.name,
          'vendor_key': o.vendorKey,
          'key': o.key,
          'value': o.value.toDouble(),
          'unit': o.unit,
          'attribution': o.attribution,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    return rows.length;
  }

  /// One observation. [putObservations] is the batch this delegates to.
  static Future<int> putObservation(
    Observation o, {
    String deviceId = kPrimaryDeviceId,
  }) => putObservations([o], deviceId: deviceId);

  // ── IMPORTED WORKOUTS (Apple Health / Health Connect) ──────────────────────
  /// A workout some OTHER app recorded, held in its own table for the same
  /// reason `imported_measurement` is: so that it CANNOT become one of ours.
  ///
  /// It is deliberately NOT a row in `sessions`. Everything that reads
  /// `sessions` treats what it finds as measured — strain, the day rollup, the
  /// workout list, the personal records — and a table this app does not own is
  /// the wrong input to every one of them. A separate table makes that
  /// structural instead of a flag someone has to remember to check: there is no
  /// WHERE clause to forget, because the rows are not there.
  ///
  /// DISPLAY ONLY, and `source` is NOT NULL for it — a workout shown without
  /// the app that recorded it is a workout this app is implicitly claiming.
  ///
  /// `uuid` is the health store's own identifier, so a re-import updates in
  /// place rather than stacking duplicates of the same run.
  ///
  /// ROUTES REUSE `workout_route`, keyed by this uuid as its `session_id`. That
  /// table is an opaque-id → lat/lng store with no notion of who measured it,
  /// and a coordinate is not an input to any metric, so there is nothing to
  /// keep apart. What it buys is the existing map: no second route table, no
  /// second reader, no second renderer. [deleteImportedWorkout] cascades, since
  /// [deleteSession] never sees these ids.
  static Future<void> _createImportedWorkout(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS imported_workout (
        uuid TEXT PRIMARY KEY,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        energy_kcal REAL,
        distance_m REAL,
        steps INTEGER,
        source TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imported_workout_start '
      'ON imported_workout(start_ts)',
    );
  }

  /// Upsert imported workouts. Idempotent on the health store's uuid.
  static Future<int> putImportedWorkouts(
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return 0;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert(
          'imported_workout',
          r,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    return rows.length;
  }

  /// Imported workouts, newest first.
  static Future<List<Map<String, dynamic>>> importedWorkouts({
    int limit = 200,
  }) async {
    final db = await instance;
    return db.query(
      'imported_workout',
      orderBy: 'start_ts DESC',
      limit: limit,
    );
  }

  /// Drop one imported workout AND its route. `deleteSession` cannot do this —
  /// these ids are never in `sessions` — so without the cascade here every
  /// lat/lng point of a removed import would stay on disk unreachable.
  static Future<void> deleteImportedWorkout(String uuid) async {
    final db = await instance;
    await db.delete('imported_workout', where: 'uuid = ?', whereArgs: [uuid]);
    await db.delete(
      'workout_route',
      where: 'session_id = ?',
      whereArgs: [uuid],
    );
  }

  // ── EXTERNAL HEART-RATE SENSOR (0x180D) ─────────────────────────────────────
  /// What a standard Bluetooth heart-rate sensor delivered during ONE workout.
  ///
  /// A SCRATCH LEDGER, deliberately: this is not the substrate. Nothing derives
  /// from it, no baseline reads it, no daily number is computed from it. It
  /// exists so a session can show the sensor's HR and RR *durations* next to
  /// the band's, and so the first question — does a second GATT link fight the
  /// band's? — can be answered against real rows.
  ///
  /// `source` is NOT NULL and carries the peripheral's advertised name, because
  /// the whole point is that the reader always knows this did not come from the
  /// wrist. `rr_ms` is a JSON list of BEAT DURATIONS in milliseconds as the
  /// sensor reported them in one notification — durations, not beat times: a
  /// sub-second beat timeline is a change to `decoded_rr`'s key and to every
  /// consumer of beat times, and is out of scope here.
  ///
  /// One row per (second, sensor). A sensor notifies about once per second; two
  /// notifications inside the same second REPLACE, which loses a beat count but
  /// never invents one.
  static Future<void> _createExternalHr(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS external_hr (
        ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        hr INTEGER NOT NULL,
        rr_ms TEXT,
        session_id TEXT,
        PRIMARY KEY (ts, source)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_external_hr_session '
      'ON external_hr(session_id)',
    );
  }

  /// Append one notification's worth of external-sensor HR. Batched by the
  /// caller: a sensor notifies ~1 Hz and a one-insert-per-beat transaction on
  /// the UI isolate is the same mistake `commitSyncBatch` chunks around.
  static Future<void> appendExternalHr(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert(
          'external_hr',
          r,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Everything an external sensor logged for one session, in time order.
  static Future<List<Map<String, dynamic>>> externalHrForSession(
    String sessionId,
  ) async {
    final db = await instance;
    return db.query(
      'external_hr',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'ts ASC',
    );
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
        source TEXT NOT NULL DEFAULT '$kStepSourceBand',
        device_id TEXT NOT NULL DEFAULT '$kPrimaryDeviceId'
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

  /// Ensure `live_coverage.device_id` exists (v49).
  ///
  /// WHICH SENSOR counted, not which KIND of sensor — `source` already says
  /// band-or-phone. Without it two straps on the same 3,000-step walk both
  /// rank 2 in [resolveDaySteps], skip each other's overlap subtraction, and
  /// the day publishes 6,000: the resolver has handled that since the ladder
  /// gained `CoverageSpan.deviceId`, and could never fire because this column
  /// did not exist. Existing rows take the DEFAULT — the primary band — which
  /// is exactly what they have always meant, so no day's total moves.
  static Future<void> _ensureLiveCoverageDeviceId(Database db) async {
    await _addColumnIfMissing(
      db,
      'live_coverage',
      'device_id',
      "TEXT NOT NULL DEFAULT '$kPrimaryDeviceId'",
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
    // WHICH physical sensor counted (see [_ensureLiveCoverageDeviceId]). The
    // phone is the primary device's own pedometer, so it keeps `''` too —
    // `source` is what tells wrist from pocket.
    String deviceId = kPrimaryDeviceId,
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
      'device_id': deviceId,
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

  /// [day]'s real pedometer steps, resolved PER WINDOW and split by sensor.
  ///
  /// Phone and band counts are never blindly added: both count the same walk,
  /// one from the pocket and one from the wrist, so summing a day whole doubles
  /// it. But they are not alternatives either — the strap streams only while a
  /// session runs, so it can only ever cover workout minutes, and letting
  /// either source take a whole day it only partly covered is the bug this
  /// replaces (it reported 622 steps against the phone's 18,856 on a real
  /// export). Each SPAN goes to the best source that actually covered it, and
  /// the spans sum. [resolveDaySteps] owns that decision, including why a wide
  /// band span with no gait in it does NOT outrank the phone (a wrist counter
  /// is documented emitting 22-27 false steps/min during dishes, reaching and
  /// driving while missing slow walking — O'Connell 2017,
  /// doi:10.1371/journal.pone.0169616).
  static Future<ResolvedDaySteps> resolvedStepsForDay(String day) async {
    final db = await instance;
    final rows = await db.query(
      'live_coverage',
      columns: ['start_ts', 'end_ts', 'steps', 'source', 'device_id'],
      where: 'day = ?',
      whereArgs: [day],
    );
    return resolveDaySteps([
      for (final r in rows)
        CoverageSpan(
          startTs: (r['start_ts'] as num).toInt(),
          endTs: (r['end_ts'] as num).toInt(),
          steps: (r['steps'] as num).toInt(),
          // Anything not explicitly 'phone' is band — pre-v27 rows default to
          // it, and relabelling them would suppress a real band count.
          fromBand: r['source'] != kStepSourcePhone,
          // WHICH sensor, so two equal-ranked spans from two different straps
          // compete instead of both being credited in full (see
          // [_ensureLiveCoverageDeviceId]). Pre-v49 rows take the column
          // default — the primary band — so a single-device install resolves
          // exactly as it did before the column existed.
          deviceId: (r['device_id'] as String?) ?? kPrimaryDeviceId,
        ),
    ]);
  }

  /// [day]'s resolved step TOTAL. See [resolvedStepsForDay] for the split.
  static Future<int> liveStepsForDay(String day) async =>
      (await resolvedStepsForDay(day)).total;

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
    } catch (_) {
      /* malformed → treat as unset */
    }
    return null;
  }

  /// Pin [value] as the frozen readiness headline for [day] (overwrites any
  /// prior pin — first-complete-settle-per-day is enforced by the caller).
  static Future<void> setFrozenHeadline(String day, int value) => setCursor(
    kFrozenHeadlineCursor,
    jsonEncode({'day': day, 'value': value}),
  );

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
  /// Times the ACK-gating commit ran at a weaker durability level than
  /// intended, because `PRAGMA synchronous=FULL` was refused or did not stick.
  /// Not fatal (see the pragma block below) but never silent.
  static int _syncFullDowngrades = 0;

  /// Read-only view of [_syncFullDowngrades] for diagnostics/tests.
  static int get syncFullDowngrades => _syncFullDowngrades;

  static Future<void> commitSyncBatch(
    List<RawRecord> raws,
    List<Sample?> samples, {
    String? trimToken,
    Map<String, String>? extraCursors,
    List<ArchiveRecord>? archives,
    void Function(String)? onCheckpoint,
    // Which strap this batch came off, from the LIVE LINK (the engine pins it at
    // service discovery). Null = the caller could not name it, which lands as
    // NULL = unknown provenance. Never defaulted to gen4.
    String? deviceFamily,
    // WHICH PHYSICAL DEVICE these rows belong to (see [kPrimaryDeviceId]).
    String deviceId = kPrimaryDeviceId,
  }) async {
    // B4: `sync_cursor` is a SINGLE GLOBAL `name TEXT PRIMARY KEY` namespace
    // shared with everything else that keeps a scalar (`frozen_headline`, …),
    // and `band_backlog` carries `device_family` but no device id. So the trim
    // token, `counter_hw`, `rec_ts_hw` and the data range of a SECOND
    // offloading band would land on the first band's cursor and mis-trim its
    // flash. Namespacing that key space is a phase-4 job (it needs the device
    // table and a decision about which keys are per-device at all); refusing is
    // the honest thing until then, and it refuses in the SAFE direction —
    // nothing commits, so nothing is ACKed and the band keeps its data.
    //
    // ponytail: global cursor namespace, one offloading device. Per-device
    // namespacing when a second adapter can actually offload.
    if (deviceId != kPrimaryDeviceId) {
      throw StateError(
        'commitSyncBatch: sync_cursor is a single global namespace and cannot '
        'hold a second offloading device (deviceId="$deviceId"). Namespace it '
        'before enabling a non-primary offload path.',
      );
    }
    void checkpoint(String msg) {
      try {
        onCheckpoint?.call(msg);
      } catch (_) {
        /* a logging callback must never affect the commit */
      }
    }

    final db = await instance;
    // POWER-LOSS DURABILITY WINDOW. This is the ACK-gating commit: once it
    // returns, the caller writes the BLE batch-ACK and the band trims its flash.
    // Under WAL + synchronous=NORMAL (the default this connection opens with) a
    // commit is durable only at the next checkpoint — so a kernel panic /
    // battery-yank AFTER the ACK but BEFORE the -wal is checkpointed loses these
    // just-committed rows from the phone while they are already gone from the
    // band. Raise durability to FULL (fsync AT commit) for THIS commit only,
    // leaving every other path at NORMAL — they are all recomputable and FULL
    // everywhere is brutally slow. `synchronous` is per-connection and CANNOT be
    // changed mid-transaction, so it is set on the connection BEFORE
    // db.transaction opens and reset AFTER it commits. The reset lives in a
    // finally: a leaked FULL from a throwing commit would fsync every subsequent
    // write on this connection forever. `PRAGMA synchronous=FULL/NORMAL` returns
    // NO rows → execute() (not rawQuery), kept non-fatal like the open-time
    // PRAGMAs so a PRAGMA throw can never fail a durable commit. Every ACK-gating
    // commit — the foreground drain AND the headless iOS-restore recovery drain
    // (background_sync.dart) — funnels through here, so this one choke point
    // covers them all. `synchronous` is per-connection, so the bracket is only
    // safe because these drains never OVERLAP on a shared connection: the offload
    // processor is single-flight (ble_engine.dart) and BandOwnership makes the
    // headless drain yield when the foreground owns the band. Do not add a second
    // concurrent caller of commitSyncBatch on the main-isolate connection without
    // reinstating that serialization — a mid-window reset would silently
    // downgrade this commit back to NORMAL.
    // Best-effort, and deliberately NOT fatal. Failing the commit when the
    // upgrade is refused would mean never committing, therefore never ACKing,
    // therefore never trimming — the strap re-floods the same backlog forever
    // and sync is dead on any platform that rejects the pragma. NORMAL under
    // WAL still commits atomically; FULL narrows the power-loss window, it is
    // not itself the safe-trim invariant.
    //
    // What it must not do is fail SILENTLY, which is what "best-effort" meant
    // before: read it back, so a downgrade shows up in the log and the counter
    // instead of being invisible for the life of the install.
    try {
      await db.execute('PRAGMA synchronous=FULL');
      final got = await db.rawQuery('PRAGMA synchronous');
      final level = got.isEmpty ? null : got.first.values.firstOrNull;
      // 2 == FULL. sqflite reports the numeric level.
      if (level is num && level.toInt() != 2) {
        _syncFullDowngrades++;
        checkpoint(
          '[DB] synchronous=FULL did not take (reads back as '
          '$level) — the ACK-gating commit is running at a weaker '
          'durability level (downgrades_total=$_syncFullDowngrades).',
        );
      }
    } catch (e) {
      _syncFullDowngrades++;
      checkpoint(
        '[DB] PRAGMA synchronous=FULL was refused ($e) — the '
        'ACK-gating commit is running at NORMAL '
        '(downgrades_total=$_syncFullDowngrades).',
      );
    }
    try {
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
              'device_id': deviceId,
              // From `ts`, not `recTs`: `toDbMap` writes `ts: sample.tsEpoch`
              // and the migration derives `ts_ms` from `ts`, so the key and the
              // column it is built from must not be allowed to disagree.
              'ts_ms': sample.tsEpoch * 1000,
              'counter': raw.counter,
              ...sample.toDbMap(),
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
            ops++;
          }
          ops += _queueDecodedOneHz(
            batch,
            raw,
            sample,
            deviceFamily: deviceFamily,
            deviceId: deviceId,
          );
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
    } finally {
      // ALWAYS restore NORMAL — even if the commit threw — so a leaked FULL does
      // not fsync every subsequent write on this connection. Non-fatal.
      try {
        await db.execute('PRAGMA synchronous=NORMAL');
      } catch (_) {
        /* non-fatal — see open-time PRAGMA discipline */
      }
    }
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
    await _createMetricSeriesVersion(db);
  }

  /// metric_series_version — which build's maths produced a day's scalars.
  ///
  /// `day_result` is versioned (PK day_id, algo_version); `metric_series` is
  /// not, and cannot become so — `v_metric` and `v_daily` are pivots over it
  /// and `v_daily` is in the coach's allow-list, so widening the PK changes
  /// what the coach sees. So the stamp lives beside it, one row per day.
  ///
  /// WHAT IT IS FOR. Days lock at finalized ~48 h after wake and are never
  /// recomputed on a bump, and the 1 Hz substrate is gone at 3 days, so a March
  /// day physically cannot be re-derived in December. `kAlgoVersion` moved
  /// 65 → 66 → 68 inside two weeks. A 12-month chart therefore splices values
  /// from several different algorithms with nothing marking the seams. This
  /// does NOT make those values comparable — nothing can. It makes the
  /// incomparability VISIBLE, so a change-point search can refuse to run across
  /// a seam instead of reporting the day the maths changed as a finding about
  /// the user.
  static Future<void> _createMetricSeriesVersion(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS metric_series_version (
        date TEXT PRIMARY KEY,
        algo_version INTEGER NOT NULL,
        source TEXT
      )
    ''');
    // v43 (export-provenance): `source` — WHO produced this day's scalars.
    // ONE table with L13, not two: same day key, same write, same read.
    //
    // `v_daily` is a pure pivot over `metric_series` with no source and no
    // version, so an imported vendor snapshot day and a 1 Hz-derived day are
    // BYTE-IDENTICAL in an export. A file presenting another vendor's derived
    // score beside your band's measured one, unlabelled, is the export
    // surface's version of the fabricated-number law.
    //
    // 'band' means this app derived the day from 1 Hz records. NULL means
    // UNKNOWN and is NEVER retro-filled with a guess — every day written before
    // this column existed reads NULL, and `csvField` already renders that as an
    // empty cell rather than a claim.
    //
    // Hand it back on a table an older build created without it. This helper
    // takes a `DatabaseExecutor` (it is called from inside a transaction), so
    // it cannot use `_addColumnIfMissing`; the throw when the column is already
    // there is the check.
    try {
      await db.execute(
        'ALTER TABLE metric_series_version ADD COLUMN source TEXT',
      );
    } catch (_) {
      /* already present */
    }
    // WHICH BAND'S UNITS this day's scalars are in (B5). Same table, same
    // write, same read as `source` — and the same rules: nullable, no DEFAULT,
    // NEVER retro-filled, because a guessed provenance is worse than none.
    //
    // This is live TODAY on a gen4→gen5 swap, with no second device involved:
    // `skin_temp_adc` holds gen4 ADC COUNTS on one side of the swap and gen5
    // CENTI-DEGREES on the other, under one `metric_series` key, feeding one
    // 28-day baseline that every nightly z-score is taken against. The seam is
    // a step change in the units, not in the person.
    //
    // NOT the same as [_importedDatesSql]'s question. Imported days are ANOTHER
    // ALGORITHM'S OUTPUT and are masked out of every baseline. A foreign family
    // is this app's own maths over a different sensor, so it is masked
    // PER-METRIC — only where the seam makes the number WRONG (different
    // units), never merely noisier. See [foreignFamilyDates].
    try {
      await db.execute(
        'ALTER TABLE metric_series_version ADD COLUMN device_family TEXT',
      );
    } catch (_) {
      /* already present */
    }
  }

  /// Backfill the stamp from `day_result`, which has carried the version all
  /// along. `INSERT OR IGNORE`, so a stamp already written by [putDayResult]
  /// wins — that one is exact, this one infers.
  ///
  /// `skipped`/`partial` rows are excluded because those passes do not write
  /// `metric_series` at all (see [putDayResult]), so their version never
  /// produced the values being stamped. MAX per day is the same rule the serve
  /// seam uses; it is only wrong for a day last written by a ROLLED-BACK build,
  /// and going forward [putDayResult] records that case exactly.
  static Future<void> _backfillMetricSeriesVersion(Database db) async {
    // `day_result` may not exist yet on an upgrade path that has not reached
    // the rung which creates it (or on a DB that never had it). A SELECT from a
    // missing table throws, and a throw inside onUpgrade rolls the WHOLE ladder
    // back and quarantines the user's database — the standing trap this file is
    // full of guards against. Nothing to infer from, so infer nothing.
    if ((await _columnsOf(db, 'day_result')).isEmpty) return;
    await db.execute(
      'INSERT OR IGNORE INTO metric_series_version (date, algo_version) '
      'SELECT day_id, MAX(algo_version) FROM day_result '
      'WHERE skipped = 0 AND partial = 0 GROUP BY day_id',
    );
  }

  /// The algo version behind each day's `metric_series` scalars, oldest first.
  /// Days with no stamp are simply absent — never guessed at.
  static Future<List<Map<String, dynamic>>> metricSeriesVersions() async {
    final db = await instance;
    return db.query('metric_series_version', orderBy: 'date ASC');
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

  /// lab_result — hand-entered blood work, and definitions for user-defined
  /// markers.
  ///
  /// Keyed on (marker, taken_on) so re-entering the same draw corrects it
  /// rather than stacking duplicates; two genuinely different draws on one day
  /// are rare enough that correcting a typo is the case worth optimising for.
  ///
  /// `unit` is stored per row rather than looked up from the catalogue, so a
  /// value keeps the unit it was entered under even if a later release changes
  /// the marker's canonical unit. Silently reinterpreting 400 ng/mL as
  /// 400 nmol/L would be a fabrication of the worst kind.
  ///
  /// NOT day-scoped, NOT pruned, and deliberately NOT removed by `deleteDays`.
  /// A lab result belongs to the date the blood was drawn, not to a band-data
  /// day. "Delete this day" in the data manager is about reclaiming space from
  /// sensor data; a blood test is neither sensor data nor large, it was typed
  /// in by hand on a different screen, and it has its own delete there. Losing
  /// a year-old blood panel because the band data from that date was cleared
  /// would be a genuinely surprising deletion.
  ///
  /// Indexed by its PRIMARY KEY alone — `(marker, taken_on)` already gives
  /// SQLite an implicit index on exactly the columns every read here filters
  /// and orders by, so a second one would only be another b-tree to maintain.
  static Future<void> _createLabTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_result (
        marker TEXT NOT NULL,
        taken_on TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (marker, taken_on)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS lab_marker_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        unit TEXT NOT NULL,
        category TEXT NOT NULL,
        decimals INTEGER NOT NULL DEFAULT 1,
        ref_low REAL,
        ref_high REAL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// breathing_session — one row per completed paced-breathing session.
  ///
  /// The coherence score was computed live and then thrown away, so the
  /// feature could tell you how a session went and never whether it was going
  /// anywhere. A score is only meaningful for a pattern that is TRYING to
  /// drive heart-rate oscillation at the paced frequency, so `coherence` is
  /// null for the others rather than a number that grades box breathing on
  /// resonance breathing's exam.
  ///
  /// `pre_rmssd` / `post_rmssd` (MIND-06) are RMSSD over the two QUIET windows
  /// either side of the paced block — never during it. RMSSD rises during slow
  /// breathing as a mechanical consequence of respiratory sinus arrhythmia, so
  /// a during-session number measures the pacing, not any effect of it. Only
  /// the pre→post pair carries information, and only across many sessions.
  /// Both null on every session run without the windows, which is the default.
  static Future<void> _createBreathingSessions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS breathing_session (
        started_at INTEGER PRIMARY KEY,
        ended_at INTEGER NOT NULL,
        pattern TEXT NOT NULL,
        seconds INTEGER NOT NULL,
        coherence REAL,
        confidence REAL,
        pre_rmssd REAL,
        post_rmssd REAL
      )
    ''');
  }

  /// The MIND-06 window columns on an existing `breathing_session`.
  ///
  /// Additive only, and NOT a ladder rung: `_addColumnIfMissing` is a no-op on
  /// a table this build has not created yet and costs one PRAGMA at open, so
  /// the onOpen repair covers every existing install without spending a schema
  /// version that three other branches are also reaching for.
  static Future<void> _ensureBreathingWindowColumns(Database db) async {
    await _addColumnIfMissing(db, 'breathing_session', 'pre_rmssd', 'REAL');
    await _addColumnIfMissing(db, 'breathing_session', 'post_rmssd', 'REAL');
  }

  /// strength_set / exercise_def — the sets a lift is made of.
  ///
  /// Nothing measures a bench press, so this is the one part of a workout the
  /// user types, and until now there was nowhere to put it: `sessions` has no
  /// exercise, set, rep, load or RPE column, which made every number on the
  /// strength screens unbacked. Hangs off `sessions.id` so strain, calories,
  /// zones and heart rate keep coming from the existing pipeline rather than
  /// being duplicated here.
  ///
  /// `load_kg` is NULLABLE and that is the whole point: a bodyweight pull-up
  /// stored as 0 would make session volume (Σ load × reps) report zero for a
  /// real session. Volume is derived on read and excludes null-load sets,
  /// which the UI states in as many words.
  ///
  /// Derived on read, never stored: total volume, set/rep counts, 1RM
  /// estimates, per-muscle volume, "vs last session", PR detection.
  static Future<void> _createStrengthTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS strength_set (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        exercise_key TEXT NOT NULL,
        set_index INTEGER NOT NULL,
        reps INTEGER,
        load_kg REAL,
        rpe INTEGER,
        hold_sec INTEGER,
        rest_sec INTEGER,
        at_ts INTEGER,
        note TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (session_id, seq)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_strength_set_ex '
      'ON strength_set(exercise_key, at_ts)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS exercise_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        muscles_json TEXT NOT NULL DEFAULT '{}',
        equipment TEXT NOT NULL DEFAULT '',
        unilateral INTEGER NOT NULL DEFAULT 0,
        custom INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Append the sets of one strength session, in log order. Idempotent by
  /// (session_id, seq) so a re-save of the same session replaces rather than
  /// duplicates.
  static Future<void> saveStrengthSets(
    String sessionId,
    List<Map<String, Object?>> sets,
  ) async {
    if (sets.isEmpty) return;
    final db = await instance;
    await db.transaction((txn) async {
      for (var i = 0; i < sets.length; i++) {
        await txn.insert('strength_set', {
          ...sets[i],
          'session_id': sessionId,
          'seq': i,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static Future<List<Map<String, Object?>>> strengthSets(
    String sessionId,
  ) async {
    final db = await instance;
    return db.query(
      'strength_set',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq ASC',
    );
  }

  /// The most recent sets logged for one exercise, newest first — the
  /// substrate for "previous" and "best" on the live screen.
  static Future<List<Map<String, Object?>>> recentSetsFor(
    String exerciseKey, {
    int limit = 60,
  }) async {
    final db = await instance;
    return db.query(
      'strength_set',
      where: 'exercise_key = ?',
      whereArgs: [exerciseKey],
      orderBy: 'at_ts DESC',
      limit: limit,
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
    await _createJournalMetric(db);
    await _createJournalFieldDef(db);
    await _createLabTables(db);
    await _createBreathingSessions(db);
    await _createStrengthTables(db);
    // Nutrition (food_entry + food_def) and medication (med_def + med_dose).
    // Both live in their own files with their models and rollup logic — the
    // DDL belongs next to the code that reads it, not two thousand lines away.
    await createNutritionTables(db);
    await createMedTables(db);
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
        cadence_spm INTEGER,
        hrr_bpm REAL,
        source TEXT NOT NULL DEFAULT 'manual',
        private INTEGER NOT NULL DEFAULT 0,
        device_family TEXT,
        trace_json TEXT,
        trace_samples INTEGER,
        rpe REAL,
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

  /// v42 — THE FROZEN SESSION TRACE. Everything the detail screen draws that is
  /// rebuilt from the 1 Hz substrate on every open: the minute HR curve, the
  /// zone bands, drift, time-to-peak, the recovery curve. `decoded_onehz` is
  /// pruned at `rawRetentionDays`, so every one of those went permanently blank
  /// on a session's fourth day — the summary scalars survived in their own
  /// columns and the whole chart half of the screen did not.
  ///
  /// `trace_samples` is the 1 Hz sample COUNT the trace was built from, kept
  /// with it so a session the band only partly handed over reads as partial
  /// instead of drawing a confident thin line over a sync gap. NOT backfilled —
  /// those seconds are gone; a session that aged out before this shipped has no
  /// trace and never will.
  ///
  /// Its own helper, and NOT [_ensureSessionSchema], because the ladder rung
  /// must not run that one: it also creates an index, which throws on a DB
  /// whose `sessions` table this ladder has not created yet, and a throw inside
  /// onUpgrade quarantines the whole database. `_addColumnIfMissing` is a no-op
  /// on a missing table.
  static Future<void> _ensureSessionTraceColumns(Database db) async {
    await _addColumnIfMissing(db, 'sessions', 'trace_json', 'TEXT');
    await _addColumnIfMissing(db, 'sessions', 'trace_samples', 'INTEGER');
  }

  static Future<void> _ensureSessionSchema(Database db) async {
    await _addColumnIfMissing(db, 'sessions', 'steps', 'INTEGER');
    await _addColumnIfMissing(db, 'sessions', 'hrr_bpm', 'REAL');
    // Mean HR over the session window. Stored rather than recomputed because
    // the 1 Hz substrate it comes from is pruned after 3 days: without a column
    // every workout older than that permanently loses its average, while
    // `max_hr` (already a column) survives. Additive + nullable, so old rows
    // read NULL — the truth for them — and the read path still recomputes from
    // the substrate while it is there.
    await _addColumnIfMissing(db, 'sessions', 'avg_hr', 'INTEGER');
    // v43 (TS-09) — SESSION RPE. A SELF-REPORT, and labelled as one everywhere
    // it is ever shown. It exists to score the sessions heart rate cannot see
    // (lifting, climbing, anything intermittent) and its real value is the
    // DISAGREEMENT with TRIMP — a feeling compared against a measurement.
    //
    // NULLABLE WITH NO DEFAULT, and that is load-bearing: the set-level picker
    // already defaults to 7, which is a garbage-data mechanism already running.
    // A session nobody rated must read as UNRATED, not as a 7 somebody typed.
    // Skippable forever.
    await _addColumnIfMissing(db, 'sessions', 'rpe', 'REAL');
    // Private session (v40): the user's "don't surface this one" flag. NOT NULL
    // DEFAULT 0 because every session that already exists was not marked
    // private — absence here is a real answer, not a missing measurement.
    await _addColumnIfMissing(
      db,
      'sessions',
      'private',
      'INTEGER NOT NULL DEFAULT 0',
    );
    // Which strap measured this workout (v41) — see _ensureDeviceFamilyColumns.
    // NULL on every existing row, on a hand-entered session, and on an import:
    // no link produced them, so their provenance is genuinely unknown.
    await _addColumnIfMissing(db, 'sessions', 'device_family', 'TEXT');
    // Measured walking cadence for the session (v43, steps/min) — the median of
    // the gait-like minutes the live 100 Hz pedometer counted (see
    // `ble/live_cadence.dart`). NULL means the session had no walking to have a
    // cadence for, which is most of them: it is an absence, never a 0.
    await _addColumnIfMissing(db, 'sessions', 'cadence_spm', 'INTEGER');
    // Set only by `_reconcileOrphanedLiveWorkout` on a stale `status='live'`
    // row it finalizes without ever having seen the real finish: `end_ts` there
    // is reconcile-time, not a measurement. `_writeOneWorkout` skips any row
    // with this set so that fabricated duration never reaches Apple
    // Health/Health Connect on the next periodic export pass. NOT NULL DEFAULT
    // 0: every existing/normal row really did finish for real.
    await _addColumnIfMissing(
      db,
      'sessions',
      'end_ts_fabricated',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureSessionTraceColumns(db);
    // `sessions` is keyed by a TEXT id, so every read that matters — the
    // workouts list, the activity tab, both `decoded_onehz` HR joins,
    // [sessionsInRange], [liveSessions] — was a full table scan plus a full
    // sort on an unindexed column. Nothing prunes `sessions` either (only an
    // explicit day delete), so the scan grows for the life of the install.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sessions_start ON sessions(start_ts)',
    );
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
    //
    // THREE SHAPES, one row each. A curve is stored either legacy
    // (`[{t,v},…]`), grid (`{t0,dt,v[]}`) or offset (`{t0,to[],v[]}`) — see
    // data/series_codec.dart for why. Old rows keep their legacy shape forever,
    // so this view must read all three, and the branch guards are what keep a
    // row from being emitted twice: legacy requires an `array`, grid requires
    // `.dt`, offset requires `.to` AND no `.dt`. The codec never writes both,
    // but "never" is not enforced by the storage layer — a foreign or corrupted
    // curve carrying both fields matched the grid and offset branches at once
    // and silently doubled the curve. The `.dt` precedence also matches
    // SeriesCodec.decodeCurve, so SQL and Dart resolve an ambiguous curve the
    // same way rather than disagreeing.
    //
    // `latest` filters on json_valid first: json_extract raises on a malformed
    // document, and without the guard ONE corrupt payload fails the entire
    // v_series query instead of dropping that one day. Same guard, same reason,
    // as daysWithSleepTst.
    //
    // The grid branch needs no running sum because json_each exposes an array's
    // index as `key`, so t = t0 + key*dt. Verified row-for-row against the
    // pre-codec view on the three tracked bundle fixtures, including a database
    // holding both shapes at once (test/coach_views_series_shapes_test.dart).
    //
    // The offset branch walks `.v` ONCE and indexes into `.to` by that key. The
    // obvious form — json_each over `.to` joined to json_each over `.v` on
    // `key` — is quadratic: SQLite cannot index a table-valued function, so the
    // join degrades to a full cross product of the two and the cost grows with
    // the SQUARE of the curve length. hrv_day, hrv_timeline and resp_day are
    // all irregularly sampled and therefore all offset-encoded, so this is the
    // hot path, not a corner: on 365 real days a `SELECT AVG(v)` measured 877 ms
    // against 89 ms, and on 1440-point curves a 30-day slice took 2.1 s. The
    // `e.key < json_array_length(.to)` bound is what keeps the rewrite
    // row-for-row identical rather than merely equivalent on well-formed data —
    // the join emitted min(len(to), len(v)) rows, and without the bound a `to`
    // shorter than `v` would gain rows with a NULL `t`. Pinned by a query-plan
    // assertion in test/coach_views_series_shapes_test.dart: two nested virtual
    // table scans in this branch is the regression.
    await db.execute('''
      CREATE VIEW v_series AS
      WITH latest AS (
        SELECT r.day_id, r.payload_json FROM day_result r
        $_servedDayJoin
        WHERE json_valid(r.payload_json)
      ),
      curve(sk, pth, vk) AS (
        SELECT 'hr_curve','\$.series.hr_curve','\$.v'
        UNION ALL SELECT 'strain_curve','\$.series.strain_curve','\$.v'
        UNION ALL SELECT 'hrv_timeline','\$.series.hrv_timeline','\$.v'
        UNION ALL SELECT 'hrv_day','\$.series.hrv_day','\$.v'
        UNION ALL SELECT 'resp_day','\$.series.resp_day','\$.v'
        UNION ALL SELECT 'skin_temp_day','\$.series.skin_temp_day','\$.v'
        UNION ALL SELECT 'zone_timeline','\$.series.zone_timeline','\$.z'
        UNION ALL SELECT 'activity_curve','\$.activity_curve','\$.v'
      )
      SELECT l.day_id AS date, c.sk AS series,
             json_extract(e.value,'\$.t') AS t,
             json_extract(e.value, c.vk) AS v
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth)) e
      WHERE json_type(json_extract(l.payload_json, c.pth)) = 'array'
      UNION ALL
      SELECT l.day_id, c.sk,
             json_extract(l.payload_json, c.pth||'.t0')
               + e.key * json_extract(l.payload_json, c.pth||'.dt'),
             e.value
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth||'.v')) e
      WHERE json_extract(l.payload_json, c.pth||'.dt') IS NOT NULL
      UNION ALL
      SELECT l.day_id, c.sk,
             json_extract(l.payload_json, c.pth||'.t0')
               + json_extract(l.payload_json, c.pth||'.to['||e.key||']'),
             e.value
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth||'.v')) e
      WHERE json_extract(l.payload_json, c.pth||'.dt') IS NULL
        AND json_extract(l.payload_json, c.pth||'.to') IS NOT NULL
        AND e.key < json_array_length(json_extract(l.payload_json, c.pth||'.to'))
    ''');
    // Sleep stage segments (different element shape from the {t,v} curves).
    // Same json_valid guard as v_series and for the same reason: without it one
    // malformed payload_json anywhere in day_result makes this view THROW, so a
    // single corrupt row takes every day's sleep stages away from the coach
    // instead of just its own.
    await db.execute('''
      CREATE VIEW v_hypnogram AS
      WITH latest AS (
        SELECT r.day_id, r.payload_json FROM day_result r
        $_servedDayJoin
        WHERE json_valid(r.payload_json)
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
      Future<bool> exists(String t) async => (await txn.rawQuery(
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

  static Future<void> _ensureSyncLedgerSchema(Database db) =>
      _migrateLegacyTable(
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
  //
  // v47: re-keyed off `counter` for the same reason decoded_onehz was re-keyed
  // off it at v33 and off rec_ts now — `counter` is a WHOOP FLASH RECORD
  // COUNTER, so a second offloading band's counter 500 is a different reading
  // that collides with the first band's. The insert is IGNORE, so the collision
  // DROPPED the newer row rather than replacing the older one, and
  // [latestSample]'s fallback then served a stale second.
  static Future<void> _createSamples(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS samples (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        counter INTEGER,
        ts INTEGER NOT NULL,
        hr INTEGER,
        PRIMARY KEY (device_id, ts_ms)
      )
    ''');
  }

  // decoded_onehz / decoded_rr — durable canonical decoded substrate, additive
  // beside raw_records. This is the canonical query surface for on-device
  // analytics: one row per real second (`rec_ts`) plus sparse RR beats for that
  // second. raw_records stays as the replay/debug ledger and upgrade fallback.
  static Future<void> _createDecodedStore(Database db) async {
    // KEYED BY rec_ts, NOT the band's record `counter`. The strap resets its
    // per-record counter to ~0 on every reboot, so `counter INTEGER PRIMARY KEY`
    // let a post-reboot record (counter=c, rec_ts=T2) REPLACE-evict a still-present
    // pre-reboot row (counter=c, rec_ts=T1) — silently and UNRECOVERABLY deleting
    // T1's only decoded 1 Hz row (raw_records is DROPped, so this store is the sole
    // system of record). rec_ts is unique per real second, so newest-wins REPLACE
    // on rec_ts is safe. `counter` is demoted to a NOT NULL forensic column (also
    // the keyset-cursor tiebreak in decodedOneHzBatchByRecTsRange, which never
    // fires now that rec_ts is unique).
    //
    // v47: KEYED BY (device_id, ts_ms), NOT rec_ts alone. `rec_ts` stays as the
    // indexed READ key — every query in this file and in health_export ranges
    // over it — but it can no longer be the identity, because a second device
    // measuring the same second is a DIFFERENT reading, and REPLACE on a
    // shared rec_ts silently deletes the first one (raw prunes at 3 days, so
    // that loss is permanent). See [_rekeyTableByDevice].
    //
    // `device_id = ''` IS RESERVED PERMANENTLY FOR THE PRIMARY BAND. Not a
    // migration default — a standing rule, and it is load-bearing twice over:
    //  * The newest-wins dedupe above only works if every row from the one
    //    physical band shares one key value. A post-reboot counter reset and a
    //    re-drained record must still collide on (device_id, ts_ms).
    //  * A BLE `remoteId` is NOT STABLE (per-app CBPeripheral UUID on iOS, a
    //    rotating RPA on Android). Letting one reach this column would
    //    fragment one band into N identities across reinstalls, each with its
    //    own baseline. Only a SECONDARY device gets a real id, and only one an
    //    adapter issues from something the band emits across the handshake.
    //
    // `ts_ms` is `rec_ts * 1000` for every WHOOP row and for every row this
    // migration rewrites, so the key is EXACTLY as unique as it was — no
    // number moves. The millisecond resolution is there so a source faster
    // than 1 Hz has somewhere to land instead of REPLACE-ing itself down to
    // one row per second, which is the same defect in a different table.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_onehz (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        -- NOT re-asserted NOT NULL, deliberately: [_rekeyTableByDevice] copies
        -- this column verbatim out of a table where SQLite never enforced it
        -- (a declared PRIMARY KEY on a legacy rowid table does not imply NOT
        -- NULL), and a constraint failure inside onUpgrade's one exclusive
        -- transaction quarantines the whole database (invariant 11).
        rec_ts INTEGER,
        counter INTEGER NOT NULL,
        hr INTEGER,
        ax REAL,
        ay REAL,
        az REAL,
        spo2_red_raw INTEGER,
        spo2_ir_raw INTEGER,
        skin_temp_raw INTEGER,
        step_count INTEGER,
        step_cadence INTEGER,
        activity_class INTEGER,
        skin_temp_c REAL,
        on_wrist INTEGER,
        hr_valid INTEGER,
        hr_alt INTEGER,
        ambient_raw INTEGER,
        device_family TEXT,
        source TEXT,
        temp_ch2_c REAL,
        temp_ch3_c REAL,
        signal_quality_logvar REAL,
        dyn_accel_g REAL,
        PRIMARY KEY (device_id, ts_ms)
      )
    ''');
    // v43: `hr` IS NULLABLE TOO, and it is the last sensor column to get there.
    //
    // `hr == 0` is this app's OFF-SKIN SENTINEL, and the NOT NULL forced every
    // record carrying no heart-rate field at all to be written as one. That is
    // a different claim — "the band was off your wrist" instead of "this record
    // has no HR" — and it is the reason the gen4 v25 record is archived instead
    // of banked: a 24 Hz PPG burst with a decoder-validated gravity vector and
    // genuinely no beat anywhere in it (ble_engine's own note says so), ~50 000
    // seconds per real export. NULL says the honest thing, and the app already
    // agrees with it everywhere: every SQL read of this column is gated
    // `hr > 0` (which NULL fails) or is an aggregate (which skips NULL), and
    // every Dart read lands NULL on the same 0 the substrate has always used
    // for "no heart rate this second".
    //
    // What it does NOT buy: a NULL-hr second is observed for the REST window
    // and UNOBSERVED for staging. It carries no beat, so it can never
    // contribute to a stage, an RHR, an HRV or the cardiac-evidence test —
    // analytics' observed mask is `sampled[i] && hrNear[i]` and only `sampled`
    // flips. Expect a 1-5 pp lift in observed fraction plus denser gravity.
    //
    // Every band-computed column above is NULLABLE ON PURPOSE: only a gen5 band
    // sends them, and a gen4 row must read back as "not reported", not as zero
    // steps / 0 °C / "off wrist". No DEFAULT, ever.
    //
    // v39: the SENSOR columns (ax/ay/az, spo2_*, skin_temp_raw) are nullable for
    // the same reason. They were `NOT NULL`, so `commitSyncBatch` coerced an
    // absent reading to `?? 0` and the ledger stored a fabricated measurement —
    // a real 0 g gravity vector and a real ADC count of 0. A record can
    // legitimately carry HR without accel (gen5 v18, and the gen4 R10-historical
    // path decodes HR/counter only), and gen5 has no equivalent of the gen4
    // optical/thermal ADCs at all, so those three are ALWAYS absent there.
    // Absence now lands as NULL. `_relaxDecodedSensorNulls` (v39) rebuilds the
    // table on existing installs.
    // `on_wrist` and `hr_valid` currently have NO honest writer at all — the
    // gen5 v18 bits once mapped onto them are disproven (see
    // `sampleFromGen5Historical` and _retireDisprovenOneHzColumns), so every
    // row written since that mapping change stores NULL. The columns are kept, nullable and
    // correctly shaped, for a source that can actually supply them; they are
    // NOT a place to park a plausible-looking bit.
    await _ensureDecodedOneHzBandFields(db);
    // NO index on `counter`. There was one, described as a forensic-only
    // lookup — and nothing in the app ever filtered or ordered by `counter`
    // alone (every decoded read is `ORDER BY rec_ts, counter`, which a
    // single-column counter index cannot serve). It cost a b-tree insert per
    // 1 Hz record on the hottest write path in the app, ~1.7 MB/day of disk,
    // and the inserts were NON-SEQUENTIAL because `counter` resets to ~0 on a
    // band reboot — so it was paying page splits on the ingest path for a
    // query nobody makes. Dropped for existing installs in _repairOpenSchema.
    // decoded_rr shares its parent's key EXACTLY, one level deeper: PRIMARY KEY
    // (device_id, ts_ms, beat_index) against the parent's (device_id, ts_ms).
    // Parent and child still delete/replace by the SAME key, so no orphan guard
    // is needed — and that is the whole reason the two keys must move together.
    // Before v47 `_queueRrBeats` cleared the second with an unscoped
    // `DELETE ... WHERE rec_ts = ?`, which for a second device deleted the
    // FIRST band's beats for that second and could not be undone.
    // rr_ts_ms (= rec_ts*1000) stays as the per-beat timestamp the compute
    // worker reads; `rec_ts` stays as the indexed range key.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_rr (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        rec_ts INTEGER NOT NULL,
        beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        device_family TEXT,
        source TEXT,
        PRIMARY KEY (device_id, ts_ms, beat_index)
      )
    ''');
    // rec_ts USED TO BE THE KEY, and the key was the only index — every read in
    // this file and in health_export ranges over it. Without these the v47
    // re-key turns each of them into a full table scan.
    //
    // GUARDED ON THE COLUMN, not on IF NOT EXISTS. This helper runs MID-LADDER
    // too (`_rekeyDecodedStoreByRecTs`, oldV<33), where `decoded_rr` is still
    // the counter-keyed shape and has no `rec_ts` at all — and an index on a
    // missing column throws inside onUpgrade's one exclusive transaction and
    // quarantines the whole database (invariant 11).
    //
    // TWO COLUMNS EACH, matching each table's `ORDER BY` exactly — `rec_ts,
    // counter` on the parent and `rec_ts, beat_index` on the child — so the
    // ordering comes out of the index and the planner needs no temp b-tree.
    //
    // ponytail: rec_ts kept as a second, indexed time axis. `ts_ms` is
    // `rec_ts * 1000` for every row this app writes, so these reads COULD range
    // on ts_ms and ride the PK for free — measured ~4.5 MB per 3-day store per
    // index, on the hottest write path. Not done here because ~20 call sites in
    // this file plus health_export range on rec_ts, and phase 2 is meant to
    // change no read. Fold it in when a reader is being touched anyway.
    for (final t in const {
      'decoded_onehz': 'rec_ts, counter',
      'decoded_rr': 'rec_ts, beat_index',
    }.entries) {
      if ((await _columnsOf(db, t.key)).contains('rec_ts')) {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_${t.key}_rects ON ${t.key}(${t.value})',
        );
      }
    }
    // Existing installs get these here (ADD COLUMN, idempotent).
    await _ensureDeviceFamilyColumns(db);
    await _ensureSourceColumns(db);
    await _ensureBeatTimeColumn(db);
  }

  /// Rebuild the decoded substrate into noop-style canonical time-keyed rows:
  /// keep exactly one decoded row per record second and one RR beat per
  /// (second, beat_index). Older duplicate counters remain in raw_records for
  /// forensics, but analytics no longer sees them.
  static Future<void> _rebuildCanonicalDecodedStore(Database db) async {
    // FROZEN v17 step: it dedups the OLD counter-keyed decoded tables by rec_ts
    // via a `decoded_rr.counter` join. If the store is ALREADY rec_ts-keyed (the
    // ladder created it fresh at v11 with the current schema, so decoded_rr has
    // no `counter` column), it is already canonical — this rebuild is impossible
    // and unnecessary, so skip it. A genuinely old (counter-keyed) store still
    // gets the original rebuild here, and the v33 re-key converts it afterward.
    final rrCols = await db.rawQuery('PRAGMA table_info(decoded_rr)');
    if (rrCols.isNotEmpty && !rrCols.any((c) => c['name'] == 'counter')) return;
    // Guarantee the OLD-schema source tables exist before we SELECT from them.
    // On upgrade paths from before the decoded store landed they were never
    // created, so this rebuild threw "no such table" and bricked openDatabase.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_onehz (
        counter INTEGER PRIMARY KEY, rec_ts INTEGER NOT NULL,
        hr INTEGER NOT NULL, ax REAL NOT NULL, ay REAL NOT NULL, az REAL NOT NULL,
        spo2_red_raw INTEGER NOT NULL, spo2_ir_raw INTEGER NOT NULL,
        skin_temp_raw INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS decoded_rr (
        counter INTEGER NOT NULL, beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
        PRIMARY KEY (counter, beat_index)
      )
    ''');
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
        -- `hr` IS NULLABLE ON EVERY INTERMEDIATE TABLE OF THE LADDER, not just
        -- the final one. These rebuilds are copy TARGETS for rows an EARLIER
        -- rung already wrote, and since v43 `_queueDecodedOneHz` writes NULL
        -- for a record with no heart rate (`hr == 0` was the off-skin
        -- sentinel — ordinary, not rare). A NOT NULL here fails the copy,
        -- throws inside the one exclusive onUpgrade transaction, and
        -- quarantines the database. See _relaxDecodedHrNull.
        hr INTEGER,
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

  /// v33: re-key the decoded store off the volatile record `counter` onto rec_ts.
  ///
  /// Rebuilds BOTH decoded tables FROM THE EXISTING decoded tables ONLY. It must
  /// NOT backfill from raw_records (that table is DROPped — a raw-backfill would
  /// zero the store, total loss). Existing rows have a unique rec_ts, so the copy
  /// loses nothing; any pre-fix duplicate counters collapse to newest-wins per
  /// rec_ts. Idempotent: a crash mid-migration re-runs cleanly (the temp tables
  /// are dropped up front, and every write is INSERT OR REPLACE keyed on identity).
  ///
  /// All copies are INSERT ... SELECT (server-side, ZERO host-bound variables),
  /// so the iOS SQLITE_MAX_VARIABLE_NUMBER (999) never applies — no chunking is
  /// needed. Mirrors [_rebuildCanonicalDecodedStore]'s rename-aside shape.
  /// v39: drop `NOT NULL` from the six SENSOR columns of `decoded_onehz`.
  ///
  /// SQLite cannot relax a constraint in place, so this is the standard
  /// rebuild — same shape as [_rekeyDecodedStoreByRecTs], but `decoded_rr` is
  /// untouched and no row is rewritten: the copy is a straight column-for-column
  /// SELECT, so it is safe on a populated table and existing values (including
  /// the historical fabricated zeros, which readers already treat as absent)
  /// survive verbatim. A pre-v34 DB reaching this step has already had the band
  /// columns added by the v34 rung above, so the explicit column list is valid.
  static Future<void> _relaxDecodedSensorNulls(Database db) async {
    // No table yet (fresh-ish upgrade path) ⇒ the current DDL already carries
    // the nullable columns and there is nothing to rebuild.
    if ((await _columnsOf(db, 'decoded_onehz')).isEmpty) return;
    await _ensureDecodedOneHzBandFields(db);
    await db.execute('DROP TABLE IF EXISTS _decoded_onehz_v39');
    await db.execute('''
      CREATE TABLE _decoded_onehz_v39 (
        rec_ts INTEGER PRIMARY KEY,
        counter INTEGER NOT NULL,
        hr INTEGER, -- nullable on every intermediate: see _decoded_onehz_new
        ax REAL,
        ay REAL,
        az REAL,
        spo2_red_raw INTEGER,
        spo2_ir_raw INTEGER,
        skin_temp_raw INTEGER,
        step_count INTEGER,
        step_cadence INTEGER,
        activity_class INTEGER,
        skin_temp_c REAL,
        on_wrist INTEGER,
        hr_valid INTEGER,
        hr_alt INTEGER
      )
    ''');
    const cols =
        'rec_ts, counter, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, '
        'skin_temp_raw, step_count, step_cadence, activity_class, skin_temp_c, '
        'on_wrist, hr_valid, hr_alt';
    await db.execute(
      'INSERT OR REPLACE INTO _decoded_onehz_v39 ($cols) '
      'SELECT $cols FROM decoded_onehz ORDER BY rec_ts ASC',
    );
    await db.execute('DROP TABLE IF EXISTS decoded_onehz');
    await db.execute('ALTER TABLE _decoded_onehz_v39 RENAME TO decoded_onehz');
  }

  /// One `CREATE TABLE (…)` body reconstructed from a live `PRAGMA
  /// table_info`, for the rebuild-aside migrations in this file.
  ///
  /// DERIVED, NEVER HARDCODED. These tables' column sets are genuinely in flux
  /// (`ambient_raw` v42, `device_family` v41, `source` + the MT-12 channels
  /// v43, `ts_subsec` / `band_sleep_state` off-ladder), and a hardcoded list
  /// silently DROPS every column added after it was written — data loss, in a
  /// rung that runs once and cannot be re-run.
  ///
  /// THE PRIMARY KEY IS THE PART THAT NEEDS CARE. `PRAGMA table_info.pk` is a
  /// 1-based POSITION, not a flag, so a composite key reports several columns.
  /// A one-column key is emitted INLINE (`x INTEGER PRIMARY KEY`) because that
  /// is the only spelling that keeps SQLite's rowid-alias behaviour; anything
  /// wider must be a table-level `PRIMARY KEY (a, b)` clause, and emitting the
  /// inline form for each of them instead throws "table has more than one
  /// primary key".
  ///
  /// [prepend] columns are emitted first, verbatim, and are NOT in [info] — a
  /// re-key adds its new key columns that way. [primaryKey] replaces the old
  /// key entirely; omit it to carry the table's own key across.
  /// [dropNotNull] relaxes named columns. Nothing here ever ADDS a constraint:
  /// a constraint failure inside `onUpgrade`'s single exclusive transaction
  /// rolls the whole ladder back and quarantines the database (invariant 11),
  /// so a rebuild may only ever loosen.
  static String _rebuildDdlBody(
    List<Map<String, Object?>> info, {
    Set<String> dropNotNull = const {},
    List<String> prepend = const [],
    List<String>? primaryKey,
  }) {
    final own = [
      for (final c in info)
        if ((((c['pk'] as num?)?.toInt()) ?? 0) > 0) c,
    ]..sort(
        (a, b) => ((a['pk'] as num).toInt()).compareTo((b['pk'] as num).toInt()),
      );
    final key = primaryKey ?? [for (final c in own) c['name'] as String];
    final inline = key.length == 1 ? key.first : null;
    final defs = <String>[...prepend];
    for (final c in info) {
      final name = c['name'] as String;
      final dflt = c['dflt_value'];
      final notNull =
          (((c['notnull'] as num?)?.toInt()) ?? 0) == 1 &&
          !dropNotNull.contains(name);
      defs.add(
        '$name ${(c['type'] as String?) ?? ''}'
        '${name == inline ? ' PRIMARY KEY' : ''}'
        '${notNull ? ' NOT NULL' : ''}'
        '${dflt == null ? '' : ' DEFAULT $dflt'}',
      );
    }
    if (inline == null && key.isNotEmpty) {
      defs.add('PRIMARY KEY (${key.join(', ')})');
    }
    return defs.join(', ');
  }

  /// v47: put `device_id` in front of the key of every table whose identity was
  /// a WHOOP-shaped quantity — a record second, or the band's flash counter.
  ///
  /// WHY THIS ONE IS NOT DEFERRABLE. `decoded_onehz` was `rec_ts INTEGER
  /// PRIMARY KEY` written with REPLACE and `decoded_rr` was cleared by an
  /// unscoped `DELETE … WHERE rec_ts = ?`, so a second device measuring the
  /// same second did not merge with the first — it DELETED it, row and beats.
  /// `raw_archive` prunes at `rawRetentionDays = 3`, so within three days the
  /// bytes that could rebuild the evicted row are gone too. Every other item on
  /// the band-agnostic roadmap can be done after a second device has written;
  /// this one cannot.
  ///
  /// WHAT IT DOES NOT CHANGE. Every existing row is copied under
  /// `device_id = ''` with `ts_ms = rec_ts * 1000`, which is exactly as unique
  /// as `rec_ts` was — one row per second per device, same newest-wins REPLACE,
  /// same dedupe. No stored value is rewritten and no derived number moves, so
  /// there is no `kAlgoVersion` bump with it.
  ///
  /// Cheap enough for the launch-path CPU watchdog `onUpgrade` runs inside:
  /// the decoded store is retention-capped at `rawRetentionDays`, ~260 k rows,
  /// and every copy is a server-side `INSERT … SELECT` with zero host-bound
  /// variables (so the iOS `SQLITE_MAX_VARIABLE_NUMBER` never applies and no
  /// chunking is needed).
  static Future<void> _rekeyStoresByDeviceId(Database db) async {
    await _rekeyTableByDevice(db, 'decoded_onehz');
    await _rekeyTableByDevice(db, 'decoded_rr', keyTail: const ['beat_index']);
    await _rekeyTableByDevice(db, 'samples', timeCol: 'ts');
  }

  /// The rename-aside rebuild behind [_rekeyStoresByDeviceId], for one table.
  ///
  /// Self-skipping and idempotent: a table that already carries `device_id` is
  /// left alone (so a fresh install at v47+ does no work at all), the temp
  /// table is dropped up front so a crash mid-migration re-runs cleanly, and
  /// the copy is keyed on identity.
  static Future<void> _rekeyTableByDevice(
    Database db,
    String table, {
    String timeCol = 'rec_ts',
    List<String> keyTail = const [],
  }) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    // Table absent on this upgrade path ⇒ the current DDL already carries the
    // new key and there is nothing to rebuild.
    if (info.isEmpty) return;
    final names = [for (final c in info) c['name'] as String];
    if (names.contains('device_id')) return;
    final tmp = '_${table}_v47';
    await db.execute('DROP TABLE IF EXISTS $tmp');
    await db.execute(
      'CREATE TABLE $tmp (${_rebuildDdlBody(
        info,
        prepend: const [
          "device_id TEXT NOT NULL DEFAULT ''",
          'ts_ms INTEGER NOT NULL DEFAULT 0',
        ],
        primaryKey: ['device_id', 'ts_ms', ...keyTail],
      )})',
    );
    final cols = names.join(', ');
    // COALESCE because a declared PRIMARY KEY on a legacy rowid table does NOT
    // enforce NOT NULL — a NULL time column would put a NULL in the new key,
    // where it compares unequal to itself and escapes the retention prune
    // forever. 0 is behind every cutoff, so such a row is pruned on the next
    // pass instead of leaking.
    await db.execute(
      'INSERT OR REPLACE INTO $tmp (device_id, ts_ms, $cols) '
      "SELECT '', COALESCE($timeCol, 0) * 1000, $cols "
      'FROM $table ORDER BY $timeCol ASC',
    );
    // The COPIED column is normalised too, or the row escapes anyway:
    // `pruneDecodedBeforeRecTs` and `deleteDays` both filter the ORIGINAL
    // time column (`rec_ts < ?`), never the key, and `NULL < ?` is NULL.
    // Without this the row is immortal AND invisible — every read gates > 0.
    await db.execute('UPDATE $tmp SET $timeCol = 0 WHERE $timeCol IS NULL');
    await db.execute('DROP TABLE IF EXISTS $table');
    await db.execute('ALTER TABLE $tmp RENAME TO $table');
  }

  /// v43 (SLP-05): drop `NOT NULL` from `decoded_onehz.hr`.
  ///
  /// See [_createDecodedStore] for WHY. This is the same rebuild shape as
  /// [_relaxDecodedSensorNulls] with one difference: the new table's DDL is
  /// DERIVED from the old table's `PRAGMA table_info` rather than hardcoded.
  /// That column set is genuinely in flux (`ambient_raw` at v42, `device_family`
  /// at v41, `source` and the MT-12 channels at v43, and whatever lands next),
  /// and a hardcoded list here silently DROPS any column added after it was
  /// written — data loss, in a rung that runs once and cannot be re-run. The
  /// copy is column-for-column with no row rewritten, so it is safe on a
  /// populated table and existing values (including the historical `hr = 0`
  /// rows, which every reader already treats as absent) survive verbatim.
  ///
  /// Self-skipping: a database whose `hr` is already nullable — every fresh
  /// create at v43+ — does no work at all. That also keeps it cheap under the
  /// launch-path CPU watchdog `onUpgrade` runs inside (invariant 11); the table
  /// is retention-capped at ~3 days, so the one-time copy is bounded.
  static Future<void> _relaxDecodedHrNull(Database db) async {
    final info = await db.rawQuery('PRAGMA table_info(decoded_onehz)');
    // No table yet on this upgrade path ⇒ the current DDL already carries a
    // nullable `hr` and there is nothing to rebuild.
    if (info.isEmpty) return;
    final hr = info.where((c) => c['name'] == 'hr');
    if (hr.isEmpty || (hr.first['notnull'] as num?)?.toInt() != 1) return;

    final names = [for (final c in info) c['name'] as String];
    await db.execute('DROP TABLE IF EXISTS _decoded_onehz_v43');
    await db.execute(
      'CREATE TABLE _decoded_onehz_v43 '
      '(${_rebuildDdlBody(info, dropNotNull: const {'hr'})})',
    );
    final cols = names.join(', ');
    await db.execute(
      'INSERT OR REPLACE INTO _decoded_onehz_v43 ($cols) '
      'SELECT $cols FROM decoded_onehz ORDER BY rec_ts ASC',
    );
    await db.execute('DROP TABLE IF EXISTS decoded_onehz');
    await db.execute('ALTER TABLE _decoded_onehz_v43 RENAME TO decoded_onehz');
  }

  static Future<void> _rekeyDecodedStoreByRecTs(Database db) async {
    // The source tables may not exist on a pre-decoded-store upgrade path; a
    // create (new schema, IF NOT EXISTS) makes the copy a safe no-op there. On a
    // normal path the OLD-schema tables already exist and this is a no-op — the
    // columns we SELECT (rec_ts, counter, hr, …; beat_index, rr_ts_ms, rr_ms)
    // are present in both the old and new decoded schemas.
    await _createDecodedStore(db);
    await db.execute('DROP TABLE IF EXISTS _decoded_onehz_v33');
    await db.execute('DROP TABLE IF EXISTS _decoded_rr_v33');
    await db.execute('''
      CREATE TABLE _decoded_onehz_v33 (
        rec_ts INTEGER PRIMARY KEY,
        counter INTEGER NOT NULL,
        hr INTEGER, -- nullable on every intermediate: see _decoded_onehz_new
        ax REAL,
        ay REAL,
        az REAL,
        spo2_red_raw INTEGER,
        spo2_ir_raw INTEGER,
        skin_temp_raw INTEGER
      )
    ''');
    // Sensor columns nullable from the start (the v39 shape). They used to be
    // NOT NULL here, which bricked step 19: the rung backfills straight into
    // this rebuilt table via _queueDecodedOneHz, which writes a real NULL for
    // an absent reading. Same reason as _relaxDecodedSensorNulls — absence is
    // not a zero g vector and not an ADC count of 0.
    await db.execute('''
      CREATE TABLE _decoded_rr_v33 (
        rec_ts INTEGER NOT NULL,
        beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        PRIMARY KEY (rec_ts, beat_index)
      )
    ''');
    // Deterministic newest-wins: ORDER BY rec_ts, counter so INSERT OR REPLACE on
    // the rec_ts PK keeps the highest-counter (latest-offloaded) row per second.
    await db.execute(
      'INSERT OR REPLACE INTO _decoded_onehz_v33 '
      '(rec_ts, counter, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, skin_temp_raw) '
      'SELECT rec_ts, counter, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, skin_temp_raw '
      'FROM decoded_onehz ORDER BY rec_ts ASC, counter ASC',
    );
    // rec_ts derived from rr_ts_ms (= rec_ts*1000 by construction). Pre-fix orphan
    // beats (owning row evicted) re-home onto their real second here.
    await db.execute(
      'INSERT OR REPLACE INTO _decoded_rr_v33 (rec_ts, beat_index, rr_ts_ms, rr_ms) '
      'SELECT rr_ts_ms / 1000, beat_index, rr_ts_ms, rr_ms '
      'FROM decoded_rr ORDER BY rr_ts_ms ASC, beat_index ASC',
    );
    await db.execute('DROP TABLE IF EXISTS decoded_rr');
    await db.execute('DROP TABLE IF EXISTS decoded_onehz');
    await db.execute('ALTER TABLE _decoded_onehz_v33 RENAME TO decoded_onehz');
    await db.execute('ALTER TABLE _decoded_rr_v33 RENAME TO decoded_rr');
    // The rebuild drops the band-computed columns, so put them straight back.
    // Step 33 got away with it because step 34 re-adds them on the next rung;
    // step 19 does NOT — it backfills through _queueDecodedOneHz on the very
    // next line, which names step_count/…/hr_alt, so SQLite threw `no such
    // column: step_count`, the whole exclusive ladder rolled back, and every
    // upgrade from schema <= 18 went down the quarantine-and-rebuild path.
    // Idempotent (ADD COLUMN only when missing), so step 34 stays a no-op.
    await _ensureDecodedOneHzBandFields(db);
    // The rec_ts PK auto-indexes and nothing reads by `counter`, so the rebuilt
    // tables carry no secondary index at all.
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

  /// Gen4 historical R10-lite (hr-only, no accel/optical) must stay out of
  /// `decoded_onehz` — they belong in the legacy `samples` table only.
  ///
  /// Matched on the hex prefix rather than decoded bytes: this runs once per
  /// record inside the offload transaction, and parsing 240 hex chars to read
  /// two of them costs ~13 ms per 50k records plus a Uint8List of garbage each.
  static final _gen4R10LitePrefix =
      '${proto.PacketType.historicalData.toRadixString(16).padLeft(2, '0')}'
      '${proto.Record.r10.toRadixString(16).padLeft(2, '0')}';
  static bool _isGen4R10LiteHistorical(String hex) =>
      hex.length >= 4 &&
      hex.substring(0, 4).toLowerCase() == _gen4R10LitePrefix;

  static Sample? _decodeOneHzSample(RawRecord raw, {Sample? preferred}) {
    // Reject Gen4 R10-lite even when a complete preferred Sample is supplied.
    // Invalid/placeholder hex (test fixtures, corrupt imports) must NOT abort
    // before the preferred paths — commit 1f85b10 returned null on hexToBytes
    // failure and zeroed decoded_onehz for every insertRecord that used non-hex
    // placeholders. The bytes are now parsed lazily, below, for that reason too.
    if (_isGen4R10LiteHistorical(raw.hex)) return null;
    if (preferred != null && preferred.hasDecodedOneHz) return preferred;
    // The band's OWN decode outranks the other generation's decoder. A gen5 v18
    // has no gen4 optics so hasDecodedOneHz is false, and feeding it to the v24
    // map is not harmless: HR sits at byte 14 in both layouts and gravity is
    // exactly one byte off, so whenever an axis lands in |g| ∈ [0.746, 0.75)
    // the misread collapses into a believable vector instead of failing the
    // plausibility gate — about 0.6% of records, ~550 rows a day. Those rows
    // keep the right hr and ts (so they look fine) while carrying a fabricated
    // gravity vector, fabricated optics, and none of the gen5 RR beats.
    if (preferred != null && preferred.tsEpoch > 0) return preferred;
    Uint8List? bytes;
    try {
      bytes = proto.hexToBytes(raw.hex);
    } catch (_) {}
    if (bytes != null) {
      // GEN5 FIRST — and only on a full gen5 decode. This whole fallback used
      // to be gen4-only, so any gen5 frame arriving without a pre-decoded
      // sample (a raw replay, an archive re-drive, a raw-hex import) was fed
      // to the R24 map, which is precisely the misread the comment above
      // describes: same HR byte, gravity one byte off, a believable-looking
      // fabricated vector.
      //
      // Order is safe in this direction and not the other:
      // `parseGen5Historical` dispatches off the record version and returns
      // null for anything it does not recognise, so a gen4 R24/R12 frame
      // (version 24/12) falls straight through to the chain below.
      try {
        final g = proto.parseGen5Historical(bytes);
        // Only the per-second v18 record maps onto a 1 Hz Sample; the deep
        // buffers (v20/v21/v26) are correctly identified and deliberately not
        // storable here — same contract as the live drain's mapper in
        // ble_engine.dart, which this duplicates because lib/data must not
        // depend on lib/ble.
        if (g is proto.Gen5HistorySample && g.unix > 0) {
          return Sample(
            tsEpoch: g.unix,
            counter: g.recordIndex,
            hr: g.heartRate,
            rrIntervalsMs: List<int>.from(g.rrIntervalsMs),
            ax: g.gravityG.isNotEmpty ? g.gravityG[0] : null,
            ay: g.gravityG.length > 1 ? g.gravityG[1] : null,
            az: g.gravityG.length > 2 ? g.gravityG[2] : null,
            stepCount: g.stepMotionCounter,
            stepCadence: g.stepCadence,
            activityClass: g.activityClassKnown,
            // Same honesty contract as the live mapper: the -50.00 °C code is
            // the sensor's unavailable sentinel, and body-60 bits 0-1 / body-15
            // bit7 are disproven as wear / HR-validity (see
            // sampleFromGen5Historical) — a replay must not resurrect them.
            skinTempC: g.skinTempCOrNull,
            hrAlt: g.heartRateAlt,
            // MT-12's three columns exist (v43) and the write below names
            // them. Carried here because they are free and the point of
            // storing them is to make it possible to find out later whether
            // they mean anything — see Sample.tempCh2C for why they are not
            // named after a body part.
            tempCh2C: g.tempAux1C,
            tempCh3C: g.tempAux2C,
            signalQualityLogVar: g.signalQualityLogVariance,
            dynAccelG: g.dynamicAccelerationG,
            tsSubsec: g.tsSubsec,
            bandSleepState: g.sleepStateRawNibble,
          );
        }
      } catch (_) {}
      try {
        // Legacy decoder first, firmware-fallback chain second — see
        // FirmwareAwareR24Decoder. This path only runs when no pre-decoded
        // `preferred` sample was supplied (e.g. a raw-hex import/merge), so a
        // fresh per-call instance is fine — no session state to preserve.
        final r = proto.FirmwareAwareR24Decoder().decode(bytes);
        // v25 NEVER BECOMES A SECOND, on any path into this table.
        //
        // The live drain already excludes it (see `_ingestHistoricalFrame`),
        // but this seam is the one every OTHER path shares — the mid-ladder
        // `_backfillDecodedStore` replay of `raw_records`, `insertRecord` with
        // no pre-decoded sample, a raw-hex import, `redriveArchivedRecords` —
        // and `FirmwareAwareR24Decoder` routes v25 straight to `_parseV25`,
        // which returns a gravity vector that ISN'T ONE: measured across all
        // 28,395 v25 records in `whoop-4.db`, its "z" takes three distinct
        // values, its "y" seventeen, its "x" is the high half of an f32, and
        // the median angle to the real v24 gravity at the SAME second is 83°.
        // A near-constant vector reads downstream as a perfectly still wrist,
        // which is the one thing the nullable accel columns exist to prevent.
        //
        // Banking it would also REPLACE (rec_ts is the PK) the v24 row for
        // that second on 49% of records, deleting real HR and R-R. Refused at
        // the seam so no future caller can reintroduce it by accident. The
        // bytes stay in `raw_archive`, whole and unpruned.
        if (r != null && r.histVersion == 25) return null;
        if (r != null && r.tsEpoch > 0) {
          return Sample(
            tsEpoch: r.tsEpoch,
            counter: r.counter,
            hr: r.hr,
            rrIntervalsMs: List<int>.from(r.rrIntervalsMs),
            // ABSENT ACCEL STAYS ABSENT. These used to coalesce to 0, which is
            // a reading — a perfectly still wrist — and it is the same
            // fabricated stillness the nullable columns and the v25 refusal
            // above exist to prevent. protocol now returns an empty `accelG`
            // for a record whose accelerometer it will not vouch for, so the
            // fallback is null, exactly as the gen5 `gravityG` path above does.
            ax: r.accelG.isNotEmpty ? r.accelG[0] : null,
            ay: r.accelG.length > 1 ? r.accelG[1] : null,
            az: r.accelG.length > 2 ? r.accelG[2] : null,
            spo2RedRaw: r.spo2RedRaw,
            spo2IrRaw: r.spo2IrRaw,
            // raw column passthrough, same as the ble path. not read as a temp.
            // ignore: deprecated_member_use
            skinTempRaw: r.skinTempRaw,
            // gen4 ambient-light ADC. 0 (unconfirmed optical block) is turned
            // into NULL at the write, not here — see _queueDecodedOneHz.
            ambientRaw: r.ambientRaw,
            tsSubsec: r.tsSubsec,
          );
        }
      } catch (_) {}
    }
    return null;
  }

  /// Queues the decoded_onehz + decoded_rr writes for one raw onto [batch].
  /// Returns the number of batch operations added, so a caller committing a
  /// large offload can chunk the batch to bound the native argument-list size
  /// (see [commitSyncBatch]).
  static int _queueDecodedOneHz(
    Batch batch,
    RawRecord raw,
    Sample? sample, {
    String? deviceFamily,
    String deviceId = kPrimaryDeviceId,
    // TRUE ONLY FROM A MID-LADDER REPLAY, and it is not a style choice. This
    // map is also written by `_backfillDecodedStore` (rungs oldV<11 / oldV<20)
    // and `redriveArchivedRecords` (rung oldV<44), both of which run BEFORE the
    // v47 rung hands `device_id` / `ts_ms` back — and naming a column that does
    // not exist yet throws inside onUpgrade's one exclusive transaction and
    // quarantines the whole database. Their rows are re-keyed by
    // [_rekeyTableByDevice] a few rungs later, from `rec_ts`, which is the same
    // value this path would have written.
    //
    // The default is FALSE and the key columns are named, deliberately: the
    // opposite default would let a forgotten argument write every row at
    // ('', 0), where REPLACE collapses the entire store to ONE row.
    bool preDeviceKey = false,
  }) {
    final decoded = _decodeOneHzSample(raw, preferred: sample);
    if (decoded == null) {
      // Gen4 R10-lite has no accel/optical, so it stays out of decoded_onehz —
      // but it DOES carry an R-R block (protocol 539a97b), and dropping it here
      // is permanent, not degraded: the record commits as decoded, so it is
      // never archived, and the band is then acked to trim it. Persist the
      // beats on their own. `samples` cannot hold them — it is (counter, ts, hr).
      if (sample != null &&
          sample.rrIntervalsMs.isNotEmpty &&
          _isGen4R10LiteHistorical(raw.hex)) {
        return _queueRrBeats(
          batch,
          _recTsFrom(raw, sample),
          sample,
          deviceFamily: deviceFamily,
          deviceId: deviceId,
          preDeviceKey: preDeviceKey,
        );
      }
      return 0;
    }
    final recTs = _recTsFrom(raw, decoded);
    final ambient = decoded.ambientRaw == 0 ? null : decoded.ambientRaw;
    // TIME-KEYED, NEWEST-WINS (noop/WHOOP-4 model: dedupe records by their
    // embedded timestamp, not by the volatile counter). decoded_onehz is keyed
    // by rec_ts and decoded_rr by (rec_ts, beat_index). We use REPLACE, not
    // IGNORE: a freshly-offloaded record for a given second should win over a
    // stale one. Because rec_ts is the key, the strap's per-reboot counter reset
    // can no longer make one second's record evict another's (the pre-fix
    // counter-PK eviction that silently, unrecoverably deleted 1 Hz rows).
    batch.insert('decoded_onehz', {
      // v47: WHICH DEVICE, in front of the key. '' is the primary band and
      // nothing else may ever use it — see _createDecodedStore for why an
      // unstable BLE remoteId must never reach this column.
      'device_id': ?(preDeviceKey ? null : deviceId),
      // `rec_ts * 1000` EXACTLY, never `+ tsSubsec`. The key has to stay as
      // unique as `rec_ts` was or the newest-wins dedupe splits into one row
      // per sub-second and every count in the app changes. The millisecond
      // resolution is headroom for a faster-than-1-Hz source, not a place to
      // put this record's own sub-second (which already has `ts_subsec`).
      'ts_ms': ?(preDeviceKey ? null : recTs * 1000),
      'rec_ts': recTs,
      'counter': raw.counter,
      // v43: ABSENCE IS NULL HERE TOO. `hr == 0` is the off-skin sentinel, so
      // writing a 0 for a record that simply has no heart-rate field asserts
      // the band was off the wrist. Every reader gates `hr > 0` (SQL) or maps
      // NULL to the same 0 (Dart), so this changes no number — it stops the
      // ledger from claiming something the record never said, and it is what
      // lets an accel-only record (gen4 v25) be banked at all. See
      // _createDecodedStore.
      'hr': decoded.hr > 0 ? decoded.hr : null,
      // NO `?? 0` on ANY of these (schema v39 made the sensor columns
      // nullable): a null must land in the DB as NULL. Zeroing invented a real
      // 0 g gravity vector, a real ADC count of 0, a 0-step second and a 0 °C
      // skin temperature for every record that simply did not carry the field.
      'ax': decoded.ax,
      'ay': decoded.ay,
      'az': decoded.az,
      'spo2_red_raw': decoded.spo2RedRaw,
      'spo2_ir_raw': decoded.spo2IrRaw,
      'skin_temp_raw': decoded.skinTempRaw,
      'step_count': decoded.stepCount,
      'step_cadence': decoded.stepCadence,
      'activity_class': decoded.activityClass,
      'skin_temp_c': decoded.skinTempC,
      'on_wrist': decoded.onWrist,
      'hr_valid': decoded.hrValid == null ? null : (decoded.hrValid! ? 1 : 0),
      'hr_alt': decoded.hrAlt,
      // MT-12 — gen5's second/third temperature channels and its own
      // signal-quality figure. Stored, unnamed, unread. See Sample.tempCh2C.
      'temp_ch2_c': decoded.tempCh2C,
      'temp_ch3_c': decoded.tempCh3C,
      'signal_quality_logvar': decoded.signalQualityLogVar,
      // OMITTED when null, unlike the three above: this column is newer than
      // the mid-ladder `_backfillDecodedStore`, which writes through this map
      // on the oldV<11 / oldV<20 rungs — before any step has handed the column
      // back. Naming a column that does not exist yet throws inside
      // onUpgrade's single transaction and quarantines the database. Only a
      // gen5 record carries a value, and no gen5 record is in a pre-v11
      // `raw_records`, so omitting-when-null loses nothing.
      'dyn_accel_g': ?decoded.dynAccelG,
      // The record's own sub-second. Omitted-when-null for the same
      // mid-ladder-backfill reason as `dyn_accel_g` directly above.
      'ts_subsec': ?decoded.tsSubsec,
      // The band's own wake/sleep envelope. gen5/MG only, so it is null on
      // everything the mid-ladder backfill can replay — but omitted-when-null
      // regardless, for the same reason.
      'band_sleep_state': ?decoded.bandSleepState,
      // 0 IS THE ABSENT SENTINEL, NOT A READING. records.dart:501 emits
      // `ambientRaw: optical ? u16@70 : 0`, so every unconfirmed record version
      // reports 0 — writing that through would turn "we did not read the
      // channel" into a real measurement of total darkness on a one-sided
      // signal where dark already means nothing. Omitted-when-null (same form
      // as device_family) so the mid-ladder backfill can't name a column a
      // pre-v42 rebuild has not handed back yet.
      'ambient_raw': ?ambient,
      // Which strap measured this second. Stamped from the live link; unknown
      // provenance is NULL, never a guess. See _ensureDeviceFamilyColumns.
      //
      // OMITTED when null rather than written as null — same stored value (the
      // column has no DEFAULT), but this map is also used by the MID-LADDER
      // `_backfillDecodedStore`, which runs before the v41 rung adds the
      // column. Naming a column that does not exist yet throws inside
      // onUpgrade's single transaction and quarantines the whole database.
      'device_family': ?deviceFamily,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return 1 /* the decoded_onehz insert */ +
        _queueRrBeats(
          batch,
          recTs,
          decoded,
          deviceFamily: deviceFamily,
          deviceId: deviceId,
          preDeviceKey: preDeviceKey,
        );
  }

  /// `rec_ts` for one raw+decoded pair.
  ///
  /// `??` substitutes on NULL only, and `rec_ts` is the primary key now. The
  /// legacy `raw_records.rec_ts` column is `NOT NULL DEFAULT 0`, so every
  /// undated row [_backfillDecodedStore] replays arrives here as an explicit
  /// 0 — which under the old counter PK coexisted harmlessly and under this
  /// one REPLACE-evicts all the others down to a single row. Same `> 0`
  /// fallback [_recTsFor] uses (the decoded sample already carries the
  /// timestamp, so going through it would re-decode the hex for nothing).
  static int _recTsFrom(RawRecord raw, Sample decoded) {
    final rawRecTs = raw.recTs;
    return (rawRecTs != null && rawRecTs > 0) ? rawRecTs : decoded.tsEpoch;
  }


  /// Replaces this second's RR beats. Returns the ops queued.
  ///
  /// Clear the second before reinserting so a SHRINKING beat count can't strand
  /// stale high-index beats — parent and child share the rec_ts key, so this
  /// single DELETE replaces the old counter-based orphan guard.
  static int _queueRrBeats(
    Batch batch,
    int recTs,
    Sample decoded, {
    String? deviceFamily,
    String deviceId = kPrimaryDeviceId,
    bool preDeviceKey = false,
  }) {
    // SCOPED TO THE WRITING DEVICE (v47). Unscoped, this cleared every device's
    // beats for the second — so a second band writing one row deleted the
    // first band's R-R for that second, permanently (raw prunes at 3 days).
    // Same key prefix as the parent row, so the PK serves the delete.
    if (preDeviceKey) {
      batch.rawDelete('DELETE FROM decoded_rr WHERE rec_ts = ?', [recTs]);
    } else {
      batch.rawDelete(
        'DELETE FROM decoded_rr WHERE device_id = ? AND ts_ms = ?',
        [deviceId, recTs * 1000],
      );
    }
    final beatTs = beatTimesMs(recTs, decoded.tsSubsec, decoded.rrIntervalsMs);
    var ops = 1;
    for (var i = 0; i < decoded.rrIntervalsMs.length; i++) {
      final rr = decoded.rrIntervalsMs[i];
      if (rr <= 0) continue;
      batch.insert('decoded_rr', {
        // Same key prefix as the parent row — see _createDecodedStore. Omitted
        // on the mid-ladder replay for the reason _queueDecodedOneHz gives.
        'device_id': ?(preDeviceKey ? null : deviceId),
        'ts_ms': ?(preDeviceKey ? null : recTs * 1000),
        'rec_ts': recTs,
        'beat_index': i,
        // UNCHANGED, DELIBERATELY. `rr_ts_ms` stays `rec_ts * 1000` and
        // `beat_ts_ms` lands beside it instead of replacing it, for one
        // concrete reason: the sub-second is NOT RECOVERABLE for a row already
        // on disk. Nothing stores it, and the raw frames it could be re-read
        // from are pruned at the retention edge — so redefining this column
        // would leave two different quantities living in it with nothing able
        // to tell them apart. A nullable column beside it says the true thing:
        // NULL is "we did not keep the sub-second for this beat", which is
        // exactly the case for every row written before today.
        //
        // The compute layer (substrate.dart, derive_prepare.dart) now prefers
        // `beat_ts_ms` and falls back to this column, so `rr_ts_ms` stays the
        // honest answer for every row that has no sub-second — which is every
        // row written before the column existed.
        'rr_ts_ms': recTs * 1000,
        'rr_ms': rr,
        // Omitted when null — see _queueDecodedOneHz. Also newer than the
        // mid-ladder backfill, same trap.
        'beat_ts_ms': ?beatTs[i],
        'device_family': ?deviceFamily,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      ops++;
    }
    return ops;
  }

  static Future<void> _backfillDecodedStore(Database db) async {
    // MUST run before the first insert. This backfill writes through
    // `_queueDecodedOneHz`, which since v43 writes NULL for a record with no
    // heart rate — and it is called from the oldV<11 and oldV<20 rungs, where
    // `decoded_onehz.hr` is still `NOT NULL`. An off-skin record (hr = 0, which
    // is ordinary, not rare) would then fail the constraint, throw inside
    // `onUpgrade`, roll the WHOLE ladder back and quarantine the database — the
    // standing trap this file is full of guards against. Self-skipping (one
    // PRAGMA) once the column is already nullable.
    await _relaxDecodedHrNull(db);
    // SAME REASON, THE OTHER DIRECTION: these two columns are NEWER than this
    // backfill, and unlike `ambient_raw` / `dyn_accel_g` (which are null on
    // everything a pre-v11 `raw_records` can hold, so the omit-when-null form
    // never names them) the sub-second is present on every real gen4 record
    // being replayed here. Naming a column the ladder has not handed back yet
    // throws inside onUpgrade's single transaction and quarantines the whole
    // database. Both are ADD COLUMN, idempotent, and no-ops on a missing table.
    await _addColumnIfMissing(db, 'decoded_onehz', 'ts_subsec', 'INTEGER');
    await _ensureBeatTimeColumn(db);
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
        // MID-LADDER: `device_id` / `ts_ms` do not exist yet (v47 rung). See
        // _queueDecodedOneHz's `preDeviceKey`.
        _queueDecodedOneHz(batch, raw, null, preDeviceKey: true);
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
    await db.execute('CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)');
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
        charge_units INTEGER,
        source TEXT NOT NULL,
        PRIMARY KEY (ts, source)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_band_battery_ts ON band_battery(ts DESC)',
    );
    await _createBandBacklog(db);
  }

  /// band_backlog — the strap's own ring-buffer bookkeeping, one row per
  /// connect. `pages_behind` is fully parsed by the protocol
  /// (`control.dart:652`) and arrives on a response edge already reads; until
  /// now it had zero readers anywhere in the app and was decoded and dropped.
  ///
  /// DEVICE STATE, NOT PHYSIOLOGY. It can claim exactly what it says: how much
  /// the band is still holding, and whether its ring has wrapped. That is the
  /// one distinction the app currently cannot draw — a STALLED offload versus
  /// an idle one — and `wrap_count` moving between two connects is a hard fact
  /// that data was overwritten before we ever saw it.
  ///
  /// NOT PRUNED, for the band_battery reason: a 3-day cap on a series whose
  /// only use is comparing today's reading to the last one destroys it. Six
  /// narrow columns per connect is not a storage problem.
  ///
  /// `device_family` rides along because a page and a record mean different
  /// things on different straps — `free_records` on gen4 and on gen5 must never
  /// be put on the same axis or divided by the same records-per-day.
  ///
  /// `batchId` is deliberately NOT stored: it is a ring wrap count, not a
  /// unique batch id, so nothing here may be used to dedupe a batch.
  static Future<void> _createBandBacklog(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS band_backlog (
        ts INTEGER PRIMARY KEY,
        written INTEGER,
        used INTEGER,
        capacity INTEGER,
        trim_page INTEGER,
        wrap_count INTEGER,
        free_records INTEGER,
        device_family TEXT
      )
    ''');
  }

  /// Record one connect's `pages_behind` reading. [ts] is epoch SECONDS.
  ///
  /// LOGGING ONLY for now, by instruction: no copy, no notification, no
  /// headroom estimate. `free_records / records-per-day` is the headroom in
  /// days and `wrap_count` moving means a loss already happened, but the
  /// records-per-day divisor is per-device and has to be established from real
  /// logged data before any number goes in front of a user. This is what
  /// establishes it.
  static Future<void> putBandBacklog({
    required int ts,
    int? written,
    int? used,
    int? capacity,
    int? trimPage,
    int? wrapCount,
    int? freeRecords,
    String? deviceFamily,
  }) async {
    final db = await instance;
    await db.insert('band_backlog', {
      'ts': ts,
      'written': written,
      'used': used,
      'capacity': capacity,
      'trim_page': trimPage,
      'wrap_count': wrapCount,
      'free_records': freeRecords,
      // Unknown provenance stays NULL — never defaulted to gen4.
      'device_family': deviceFamily,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The most recent [limit] backlog readings, newest first.
  static Future<List<Map<String, dynamic>>> bandBacklog({
    int limit = 60,
  }) async {
    final db = await instance;
    return db.query('band_backlog', orderBy: 'ts DESC', limit: limit);
  }

  /// Additive: add the `millivolts` column to an existing band_battery table.
  /// Guarded — the column already exists on fresh installs (see _createBandSignals)
  /// and ALTER … ADD COLUMN throws if it's already there.
  static Future<void> _ensureBandBatteryMillivolts(Database db) =>
      _addColumnIfMissing(db, 'band_battery', 'millivolts', 'INTEGER');

  /// Additive: the strap's own charge counter. Same guard, same reason as
  /// [_ensureBandBatteryMillivolts]. See [extendedChargeUnits] for what it is
  /// and — more importantly — what it is not.
  static Future<void> _ensureBandBatteryChargeUnits(Database db) =>
      _addColumnIfMissing(db, 'band_battery', 'charge_units', 'INTEGER');

  /// Replay stored band events into `band_battery`.
  ///
  /// The point of running this at all: the writer added alongside it only fills
  /// the series from here forward, and `batteryHealth` reports a full-charge
  /// voltage and a charge count that only mean anything ACROSS the life of the
  /// pack. Everything needed to fill the past is already on disk — `band_events`
  /// keeps the whole frame — so an existing install gets its history rather than
  /// starting the series at this upgrade.
  ///
  /// BOUNDED, because this runs inside `openDatabase` under iOS's CPU watchdog
  /// (invariant 11): the two ids together are ~2,400 rows over 9 days on the
  /// largest real export, and non-charge/wear band events are pruned at the
  /// retention edge anyway, so the cap is a backstop and not the normal case.
  /// INSERT OR IGNORE, so it can never overwrite a row the live writer already
  /// wrote.
  static Future<void> _backfillBandBatteryFromEvents(DatabaseExecutor db) async {
    // A DB whose ladder has not created these yet (or is mid-ladder) must
    // NO-OP rather than throw. `redriveArchivedRecords` guards the same way and
    // for the same reason: a throw in here rolls the WHOLE upgrade back and
    // quarantines the database.
    for (final t in const ['band_events', 'band_battery']) {
      final present = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        [t],
      );
      if (present.isEmpty) return;
    }
    const cap = 20000;
    final rows = await db.query(
      'band_events',
      columns: ['hex'],
      where: 'event_id IN (?, ?)',
      whereArgs: [proto.EventId.batteryLevel, kExtendedBatteryInfoEventId],
      orderBy: 'ts DESC',
      limit: cap,
    );
    if (rows.isEmpty) return;
    final batch = db.batch();
    var queued = 0;
    for (final r in rows) {
      final hex = r['hex'] as String?;
      if (hex == null) continue;
      Map<String, Object?>? row;
      try {
        final e = proto.parseEvent(proto.hexToBytes(hex));
        row = e == null ? null : batteryRowFromEvent(e);
      } catch (_) {
        // A frame this build cannot parse is one battery row we do not get.
        // It must never take the upgrade down with it.
        continue;
      }
      if (row == null) continue;
      batch.insert(
        'band_battery',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      queued++;
    }
    if (queued > 0) await batch.commit(noResult: true);
  }

  /// Durable archive for historical records we received but could not decode
  /// (unknown/unsupported version). Thinned to a stated SAMPLE RATE behind the
  /// retention edge and otherwise kept forever — the point is that a future
  /// firmware's records survive until we understand the format, and a sample is
  /// what a decode needs. See [thinRawArchiveBefore] for the numbers. Keyed by
  /// frame `hex` (content identity), like `events`/`band_events` — NOT by
  /// `counter`. The strap resets its record counter to ~0 on every reboot, so
  /// two DISTINCT undecodable frames from different boots can collide on a
  /// reused counter; a `counter`-PK + IGNORE silently DROPPED the second, in
  /// the one table whose whole purpose is to never lose a frame. Hashing on the
  /// bytes means an identical re-flood (missed-ACK redelivery) still dedups,
  /// while genuinely distinct frames both survive a counter collision. `counter`
  /// is retained as a plain forensic column.
  static Future<void> _createRawArchive(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raw_archive (
        hex TEXT PRIMARY KEY,
        counter INTEGER,
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
    final battery = parsed == null ? null : batteryRowFromEvent(parsed);
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
        'payload_json': jsonEncode(
          parsed?.decoded ?? const <String, dynamic>{},
        ),
        'captured_at': capturedAt,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (battery != null) {
        await db.insert(
          'band_battery',
          battery,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }, bestEffort: true);
  }

  /// The `band_battery` row an incoming band event carries, or null when it
  /// carries none.
  ///
  /// WHY THIS EXISTS. `band_battery.millivolts` has had a column, a reader
  /// ([batteryHealth]) and a rendered widget since it was added, and NO WRITER:
  /// the only insert was AppState's `DeviceState` tick, which has no voltage.
  /// It was 0-filled on all four real exports (0 of 433 / 413 / 626 / 171 rows),
  /// so the device screen's charge-history line has been blank on every install
  /// there has ever been. The number was on the wire the whole time — the band
  /// sends BATTERY_LEVEL every few minutes and the protocol already decodes
  /// `battery_mv` out of it; nothing carried it the last four inches into the
  /// series table. This is that write, on the funnel every event already goes
  /// through (live AND headless — see AppState._onLiveEvent and
  /// background_sync).
  ///
  /// Two events land here, under two SOURCES rather than one merged row: they
  /// arrive 1:1 at the same strap second, and `band_battery` is keyed
  /// `(ts, source)`, so one source would make each overwrite the other's
  /// columns. Split, each row states only what its own event said.
  ///
  ///  * BATTERY_LEVEL — `battery_pct` / `millivolts` / `charging`, all three
  ///    already decoded by the protocol. Source `band_event`.
  ///  * EXTENDED_BATTERY_INFORMATION — [extendedChargeUnits]. Source
  ///    `band_event_ext`.
  ///
  /// ON THE `charging` FLAG. It rides on the BATTERY_LEVEL row (the event's own
  /// byte), NOT on a chargingOn/chargingOff transition, and the strap can
  /// replay these out of its flash backlog hours late — which is exactly why
  /// [batteryHealth] counts charge edges PER SOURCE and takes the max rather
  /// than walking one interleaved series.
  @visibleForTesting
  static Map<String, Object?>? batteryRowFromEvent(proto.EventInfo e) {
    if (e.tsEpoch <= 0) return null;
    if (e.eventId == proto.EventId.batteryLevel) {
      final pct = e.decoded['battery_pct'];
      final mv = e.decoded['battery_mv'];
      final charging = e.decoded['charging'];
      if (pct == null && mv == null) return null;
      return {
        'ts': e.tsEpoch,
        'battery_pct': pct is num ? pct.toDouble() : null,
        'charging': charging is bool ? (charging ? 1 : 0) : null,
        'wrist_on': null,
        'millivolts': mv is num ? mv.toInt() : null,
        'charge_units': null,
        'source': 'band_event',
      };
    }
    if (e.eventId == kExtendedBatteryInfoEventId) {
      final units = extendedChargeUnits(e.body);
      if (units == null) return null;
      return {
        'ts': e.tsEpoch,
        'battery_pct': null,
        'charging': null,
        'wrist_on': null,
        'millivolts': null,
        'charge_units': units,
        'source': 'band_event_ext',
      };
    }
    return null;
  }

  /// EXTENDED_BATTERY_INFORMATION. Named here rather than taken from
  /// `proto.EventId` because the sealed protocol has no constant for it.
  static const int kExtendedBatteryInfoEventId = 63;

  /// The strap's own charge counter out of an EXTENDED_BATTERY_INFORMATION
  /// body, or null when the body is not one this reads.
  ///
  /// WHAT THE EVIDENCE IS. The event arrives paired 1:1 with BATTERY_LEVEL and
  /// its body was dropped whole (`payload_json = '{}'` on 3,372 stored rows
  /// across the four real exports). Decoding the stored bodies and joining each
  /// to the BATTERY_LEVEL it arrived beside:
  ///
  ///   rev 3 (gen5/MG, 12-byte body), u16 LE @ [9]:
  ///     r = +1.0000 against `battery_pct` over 263 pairs (whoop-mg) and 85
  ///     (whoop-5); range 977-1915 against 50.9-99.7 %, i.e. 977/1915 = 0.5100
  ///     against 0.5106 — the same quantity at ~19x the resolution of the
  ///     deci-percent.
  ///   rev 1 (gen4, 28-byte body), u16 LE @ [11]:
  ///     r = +0.9992 against `battery_pct` over 273 pairs; range 790-1750.
  ///     (That body ALSO carries the millivolts at [5], r = +1.0000 against
  ///     BATTERY_LEVEL's own `battery_mv`. Not read here — it is the same
  ///     number from the same second, and one source for it is enough.)
  ///
  /// WHAT IS NOT CLAIMED. THE UNIT IS UNPINNED. It is linear in state of
  /// charge and that is the whole claim — it is not mAh, not coulombs, not a
  /// capacity, and it must never be rendered with a unit or compared against a
  /// cell spec. What a ratio of two of them supports (this reading over the
  /// full-charge reading) is a fraction, which needs no unit; anything else
  /// needs a unit nobody has established. The two signed words at [1] and [3]
  /// are negative while discharging and look like instantaneous and averaged
  /// current — deliberately NOT decoded, for the same reason: a current in
  /// unknown units is a number that invites "mA" and cannot support it.
  @visibleForTesting
  static int? extendedChargeUnits(Uint8List body) {
    if (body.isEmpty) return null;
    // Offset is per BODY REVISION, never per length: a future revision that
    // happens to be 12 or 28 bytes long would otherwise be read at an offset
    // that was only ever verified for this one.
    final at = switch (body[0]) {
      3 => 9, // gen5 / MG
      1 => 11, // gen4
      _ => null,
    };
    if (at == null || body.length < at + 2) return null;
    final units = body[at] | (body[at + 1] << 8);
    // 0 is the absent/uninitialised read, not a flat pack — a strap reporting a
    // real battery level in the same second has not measured zero charge.
    return units > 0 ? units : null;
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

  /// A simple, honest battery-health readout derived from the stored series.
  ///   - `full_charge_mv`: the highest millivolts ever seen while charging (a
  ///     pack's full-charge voltage sags over its life);
  ///   - `charge_cycles`: how many times the band has been put on the charger
  ///     (a coarse proxy — a top-up is not a cycle);
  ///   - `latest_pct` / `latest_mv`: the most recent sample.
  /// All fields are nullable (absent input → null, never fabricated).
  ///
  /// BOTH LIFETIME FACTS COME OUT OF SQL, NOT A ROW WINDOW. They only mean
  /// anything across the life of the pack, and the row window they used to be
  /// computed over was a `LIMIT` on a table that now takes a row every few
  /// minutes rather than every few state changes — the same window that used to
  /// span a month would span days, quietly shrinking "the highest ever seen"
  /// into "the highest this week".
  ///
  /// `charge_cycles` counts CHARGING_ON events rather than rising edges in this
  /// series, which is both cheaper and truer: the events are one of the four ids
  /// `band_events` keeps forever, so the count is lifetime; and an edge walk
  /// over a SAMPLED series misses any charge that began and ended between two
  /// samples, while double-counting one that two sources disagree about at the
  /// boundary — a real hazard now that the strap's own (replayable, possibly
  /// hours-late) battery events land in the same table as the live device tick.
  static Future<Map<String, dynamic>> batteryHealth({
    int lookback = 2000,
  }) async {
    final db = await instance;
    final rows = await recentBandBatterySamples(limit: lookback);
    final fullCharge = await db.rawQuery(
      'SELECT MAX(millivolts) AS mv FROM band_battery WHERE charging = 1',
    );
    final cycleRows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM band_events WHERE event_id = ?',
      [proto.EventId.chargingOn],
    );
    final fullChargeMv = (fullCharge.first['mv'] as num?)?.toInt();
    final cycles = (cycleRows.first['n'] as num?)?.toInt() ?? 0;
    // The most recent reading of each — NOT of the newest row. The sources
    // write different columns (the device tick has no voltage, the strap's
    // extended event has no percentage), so the newest row is routinely missing
    // one of the two and reading it alone reported "no voltage" on a series
    // that had one a few seconds earlier.
    T? newest<T>(String column, T? Function(Object?) read) {
      for (final r in rows) {
        final v = read(r[column]);
        if (v != null) return v;
      }
      return null;
    }

    return {
      'samples': rows.length,
      'full_charge_mv': fullChargeMv,
      'charge_cycles': cycles,
      'latest_pct': newest('battery_pct', (v) => (v as num?)?.toDouble()),
      'latest_mv': newest('millivolts', (v) => (v as num?)?.toInt()),
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

  /// The `raw_archive.reason` values [redriveArchivedRecords] will retry.
  ///
  /// A reason names the RECORD VERSION a build could not decode, and only the
  /// per-second records map onto 1 Hz rows at all: gen5's v20/v21/v26 and
  /// gen4's v25 are deep buffers this build IDENTIFIES correctly and
  /// deliberately does not store as seconds (see `_ingestHistoricalFrame`), so
  /// retrying them re-reads half a gigabyte of hex to re-learn the same answer.
  /// MEASURED on the real MG export: `undecodable_rec_v20` alone is 115,672
  /// rows and 492 MB. A future format that becomes re-drivable gets a line
  /// here, by name.
  static const List<String> redrivableArchiveReasons = [
    // gen5's per-second summary. 1,035 of these sit in the MG export, archived
    // before this month's decoder fixes under a gravity window that was gen4's
    // — 0.5-1.8 g on a NORMALISED vector, applied to gen5's raw per-axis means.
    // All 1,035 decode today, gravity included.
    'undecodable_rec_v18',
    // The same records under a reason string an older build wrote and nothing
    // writes any more. Both labels are stale, which is the whole point.
    'partial_decode_v18_no_gravity',
    // gen4's R24, for symmetry — a record the R24 chain rejected once may
    // decode under a later firmware fallback. Zero rows carry it on any of the
    // three real exports; it costs nothing to include and is the case this
    // would otherwise have to be rewritten for.
    'undecodable_rec_v24',
  ];

  /// GATES 4b — replay the archive through the CURRENT decoders, into
  /// `decoded_onehz` / `decoded_rr`. Returns the seconds recovered.
  ///
  /// `raw_archive` holds frames a BUILD could not turn into a [Sample]. That is
  /// a statement about the build, not about the bytes — and nothing ever went
  /// back to re-read them, so the archive silently became a graveyard rather
  /// than the recovery store it was created to be. On the real MG export that
  /// is 1,035 seconds of gen5 history the app already owns, carrying HR, R-R,
  /// steps, sleep state and a skin temperature populated on 1,035 of 1,035.
  ///
  /// Run ONCE, from the migration ladder: off the ACK-critical sync path, and
  /// never on the launch path of a DB that has already had it.
  ///
  /// THREE THINGS IT DOES NOT DO:
  ///
  ///  * It does not touch a second `decoded_onehz` already holds.
  ///    [_queueDecodedOneHz] writes REPLACE (newest-wins, for a re-offload of a
  ///    live second) and a replay is the opposite case: a frame that FAILED to
  ///    decode must never evict one that succeeded. Collisions are skipped.
  ///  * It does not stamp `device_family`. A replay has no live link to ask,
  ///    and the record version does not answer it either — v18 exists on BOTH
  ///    generations (gen4 lists v7/v9/v18 as unconfirmed field maps). NULL is
  ///    the documented value for exactly this case, and the metrics that need
  ///    the family will correctly refuse rather than assume gen4.
  ///  * It does not delete, thin or relabel the archived row. The bytes stay
  ///    exactly where they are, under the reason they were captured with.
  static Future<int> redriveArchivedRecords(Database db) async {
    // Both are cheap and both are required: a DB whose ladder has not created
    // the archive yet (or is mid-ladder) must no-op rather than throw — a throw
    // in here rolls the WHOLE upgrade back and quarantines the database.
    for (final t in const ['raw_archive', 'decoded_onehz']) {
      final present = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        [t],
      );
      if (present.isEmpty) return 0;
    }
    // SELF-DETECTING, because this runs from BOTH sides of the v47 rung: from
    // the oldV<44 ladder step, where `decoded_onehz` is still keyed by rec_ts
    // alone and naming `device_id` would throw inside onUpgrade (quarantining
    // the database), and from the app/tests on a re-keyed table. One PRAGMA.
    final preDeviceKey =
        !(await _columnsOf(db, 'decoded_onehz')).contains('device_id');

    final marks = List.filled(redrivableArchiveReasons.length, '?').join(',');
    // Paged on `hex`, which is the table's PRIMARY KEY — a stable, total order
    // that needs no extra index and no offset scan.
    var afterHex = '';
    var recovered = 0;
    while (true) {
      final rows = await db.rawQuery(
        'SELECT hex, counter, packet_type, rec_ts, captured_at '
        'FROM raw_archive WHERE reason IN ($marks) AND hex > ? '
        'ORDER BY hex ASC LIMIT 500',
        [...redrivableArchiveReasons, afterHex],
      );
      if (rows.isEmpty) return recovered;
      afterHex = rows.last['hex'] as String;

      // Decode first, keyed by the second each record claims. Two archived
      // frames for the same second collapse here rather than fighting over the
      // primary key inside the batch.
      final byRecTs = <int, (RawRecord, Sample)>{};
      for (final r in rows) {
        final raw = RawRecord(
          counter: (r['counter'] as num?)?.toInt() ?? 0,
          packetType: (r['packet_type'] as num?)?.toInt() ?? 0,
          hex: r['hex'] as String,
          capturedAt: (r['captured_at'] as num?)?.toInt() ?? 0,
          recTs: (r['rec_ts'] as num?)?.toInt(),
        );
        final s = _decodeOneHzSample(raw);
        // Still undecodable under today's decoders. Left in the archive,
        // untouched, for the build that can read it.
        if (s == null) continue;
        final recTs = _recTsFrom(raw, s);
        // `rec_ts` is NULL on every archived row on all three real exports (we
        // archive a frame precisely because we never learned its time), so this
        // is the decoded timestamp — and a record with no plausible time has
        // nowhere to land in a table keyed by one.
        if (recTs <= 0) continue;
        byRecTs[recTs] = (raw, s);
      }
      if (byRecTs.isEmpty) continue;

      final keys = byRecTs.keys.toList();
      final taken = <int>{};
      for (var i = 0; i < keys.length; i += 400) {
        final end = i + 400 < keys.length ? i + 400 : keys.length;
        final slice = keys.sublist(i, end);
        for (final e in await db.rawQuery(
          'SELECT rec_ts FROM decoded_onehz WHERE rec_ts IN '
          '(${List.filled(slice.length, '?').join(',')})',
          slice,
        )) {
          taken.add((e['rec_ts'] as num).toInt());
        }
      }

      final batch = db.batch();
      var queued = 0;
      for (final e in byRecTs.entries) {
        if (taken.contains(e.key)) continue;
        final (raw, sample) = e.value;
        // `sample` is handed back as `preferred` so the hex is decoded once,
        // not twice; `_queueDecodedOneHz` returns it straight back out.
        // `deviceFamily` is deliberately omitted — see the doc comment.
        if (_queueDecodedOneHz(
              batch,
              raw,
              sample,
              preDeviceKey: preDeviceKey,
            ) >
            0) {
          queued++;
          recovered++;
        }
      }
      if (queued > 0) await batch.commit(noResult: true);
    }
  }

  /// One in this many `undecodable_rec_v20` frames is kept behind the retention
  /// edge. A STATED RATE, not a byte budget, so what survives is auditable: a
  /// future decode gets 1 record a minute of whatever the band was banking,
  /// which is a sample, not a recording.
  ///
  /// Sampled on `counter`, which resets to ~0 on a band reboot — that makes the
  /// sample slightly uneven across reboots and does not matter at all; what it
  /// buys is a rule you can re-run and get the same rows back.
  static const int rawArchiveKeepEvery = 60;

  /// The one `reason` this thinning applies to, and the reason it exists.
  ///
  /// MEASURED on the real MG export: `undecodable_rec_v20` is 115,672 rows of
  /// 4,256-char hex = 492 MB of the 538 MB `raw_archive` holds, banked in 11
  /// days. That is ~45 MB/day, ~16 GB/year, and `auto_backup.dart` gzips the
  /// whole database on a schedule. Nothing else in the table is close: v26 is
  /// 25,804 rows for 3.9 MB and gen4's v25 is 28,395 rows for 4.3 MB — both
  /// 152-char frames, and v25 is a channel we have since identified, so
  /// thinning either would cost real evidence and save nothing. One `reason`,
  /// one WHERE clause. A future format that turns out to be this big gets its
  /// own line here, by name — the diagnostics already break the table down by
  /// reason, so it shows up before it hurts.
  static const String _thinnedArchiveReason = 'undecodable_rec_v20';

  /// Thin the undecodable archive: drop all but 1-in-[rawArchiveKeepEvery]
  /// `undecodable_rec_v20` frames captured before [beforeMs]. Returns the rows
  /// deleted.
  ///
  /// Gated on `captured_at` and NOT `rec_ts`: `rec_ts` is NULL for every row in
  /// this table on all three real exports (142,511 of 142,511), which is not an
  /// accident — we archive a frame precisely BECAUSE we could not decode it, so
  /// we never learned its record time. When we received it is the only time we
  /// have.
  ///
  /// Called only from [pruneDecodedBeforeRecTs], so full-rate frames live
  /// exactly as long as the 1 Hz substrate they arrived with, and the sample
  /// lives forever.
  static Future<int> thinRawArchiveBefore(int beforeMs) async {
    final db = await instance;
    return db.transaction((txn) => _thinRawArchiveVia(txn, beforeMs));
  }

  static Future<int> _thinRawArchiveVia(
    DatabaseExecutor txn,
    int beforeMs,
  ) async {
    return txn.delete(
      'raw_archive',
      // `counter` is NOT NULL in practice but the column is nullable, and
      // `NULL % 60` is NULL — so a counter-less row would never match and would
      // be kept. Keeping an unsampleable frame is the safe direction.
      where: 'reason = ? AND captured_at < ? AND counter % ? != 0',
      whereArgs: [_thinnedArchiveReason, beforeMs, rawArchiveKeepEvery],
    );
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

  /// Whether an ALARM_SET (event 56) row landed at or after [sinceMs]
  /// (`captured_at`, device receive time — the band's own `ts` can be
  /// RTC-skewed). The headless alarm-arm path (background_sync.dart) polls
  /// this for a short grace window to confirm a SET actually latched before
  /// the background connection closes, since there's no live AppState there
  /// to catch a late event 56 the way the foreground confirmation machine
  /// does.
  static Future<bool> alarmSetConfirmedSince(int sinceMs) async {
    final db = await instance;
    final rows = await db.query(
      'events',
      where: 'event_id = ? AND captured_at >= ?',
      whereArgs: [56, sinceMs],
      limit: 1,
    );
    return rows.isNotEmpty;
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

  /// Columns [Sample.fromDecodedRow] reads. Deliberately NOT `*`: the accel /
  /// spo2 / raw-skin-temp columns are bulk and nothing on these two paths uses
  /// them (the derive path has its own wider query).
  static const List<String> _decodedSampleColumns = [
    'counter',
    'rec_ts',
    'hr',
    'step_count',
    'step_cadence',
    'activity_class',
    'skin_temp_c',
    'on_wrist',
    'hr_valid',
    'hr_alt',
  ];

  /// [kPrimaryBandSourceSql], and the `samples` fallback below is why: that
  /// table has no `source` column at all, so it can only ever hold the band's
  /// rows. Returning gated decoded rows from one branch and ungated legacy rows
  /// from the other under one [Sample] type would make the provenance of the
  /// result depend on which branch fired. (No production caller today — only
  /// tests reach this; gated with its sibling rather than left as the one
  /// decoded read whose answer changes when a strap is paired.)
  static Future<List<Sample>> samplesInRange(int fromTs, int toTs) async {
    final db = await instance;
    final decodedRows = await db.query(
      'decoded_onehz',
      columns: _decodedSampleColumns,
      where: 'rec_ts >= ? AND rec_ts <= ? AND $kPrimaryBandSourceSql',
      whereArgs: [fromTs, toTs],
      orderBy: 'rec_ts ASC, counter ASC',
    );
    if (decodedRows.isNotEmpty) {
      return decodedRows.map(Sample.fromDecodedRow).toList();
    }
    final rows = await db.query(
      'samples',
      where: 'ts >= ? AND ts <= ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'ts ASC',
    );
    return rows.map(Sample.fromDbMap).toList();
  }

  /// [kPrimaryBandSourceSql], for the [samplesInRange] reason above AND for its
  /// own: its one caller keeps this as `lastSynced`, whose `tsEpoch` is the
  /// fallback frontier behind the `rec_ts_hw` cursor — i.e. "how fresh is the
  /// BAND". A peripheral sensor's second would make a band that has not synced
  /// in two days read as current.
  static Future<Sample?> latestSample() async {
    final db = await instance;
    final decodedRows = await db.query(
      'decoded_onehz',
      columns: _decodedSampleColumns,
      where: kPrimaryBandSourceSql,
      orderBy: 'rec_ts DESC, counter DESC',
      limit: 1,
    );
    if (decodedRows.isNotEmpty) {
      return Sample.fromDecodedRow(decodedRows.first);
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
  /// or `(null, null)` when nothing has been decoded yet.
  ///
  /// Its ONE production caller is [decodedRecTsMaxByDay], which uses it purely
  /// as the span to walk — so this is an ADMISSION read ([derivableSourceSql]),
  /// not a band-edge one. Band-only here would clip a verified second source's
  /// days out of derivation entirely, before any of them reached the day walk.
  /// (The old doc comment claimed the onboarding progress bar; that call site
  /// is gone.)
  static Future<(int?, int?)> firstAndLastRecordTs() async {
    final db = await instance;
    final rows = await db.rawQuery(
      // rec_ts > 0, matching rawStats()/lastDecodedRecTs() — a stray rec_ts=0
      // row (e.g. via _queueDecodedOneHz's `raw.recTs ?? decoded.tsEpoch`,
      // which only substitutes on null, not on an explicit 0) would otherwise
      // make MIN(rec_ts) return 0 and render "Data from Jan 1" (1970 epoch).
      'SELECT MIN(rec_ts) AS lo, MAX(rec_ts) AS hi FROM decoded_onehz '
      'WHERE rec_ts > 0 AND ${derivableSourceSql()}',
    );
    if (rows.isEmpty) return (null, null);
    final lo = (rows.first['lo'] as num?)?.toInt();
    final hi = (rows.first['hi'] as num?)?.toInt();
    return (lo, hi);
  }

  /// `{localDayLabel -> MAX(rec_ts)}` over canonical decoded 1 Hz rows, grouped
  /// by the LOCAL calendar day of the record's real time.
  ///
  /// One bounded `MAX(rec_ts)` per local day in the retained span, NOT one
  /// `GROUP BY strftime(…, 'localtime')` over the whole table. That grouping key
  /// is a function of the column, so SQLite could use no index for it: it was a
  /// full scan of every retained second plus a temp b-tree — 91 ms on a 3-day
  /// (259 k row) table on desktop, and the derive calls this up to three times
  /// a pass. `rec_ts` is the INTEGER PRIMARY KEY (the rowid), so a bounded
  /// `MAX(rec_ts) WHERE rec_ts >= a AND rec_ts < b` is a single index seek, and
  /// the span is bounded by `rawRetentionDays` in any healthy install.
  ///
  /// The day walk goes through [localDayEndSec] rather than `+ 86400` for the
  /// reason that helper documents: a local calendar day is 23 h on a
  /// spring-forward and 25 h on a fall-back, and the old `strftime('localtime')`
  /// grouping got that right, so the replacement has to as well.
  static Future<Map<String, int>> decodedRecTsMaxByDay() async {
    final (lo, hi) = await firstAndLastRecordTs();
    if (lo == null || hi == null) return {};
    final db = await instance;
    final out = <String, int>{};
    var day = dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch(lo * 1000, isUtc: true).toLocal(),
    );
    // Bounded by the number of days actually present. `localDayEndSec` returns
    // null only for a malformed label, which `dayLabelOf` cannot produce — the
    // guard is there so a future change can never spin here.
    for (var guard = 0; guard < 4000; guard++) {
      final end = localDayEndSec(day);
      if (end == null) break;
      final rows = await db.rawQuery(
        'SELECT MAX(rec_ts) AS mx FROM decoded_onehz '
        'WHERE rec_ts > 0 AND ${derivableSourceSql()} '
        'AND rec_ts >= ? AND rec_ts < ?',
        [localDayStartSec(day) ?? 0, end],
      );
      final mx = rows.isEmpty ? null : (rows.first['mx'] as num?)?.toInt();
      if (mx != null) out[day] = mx;
      if (end > hi) break;
      day = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch(end * 1000, isUtc: true).toLocal(),
      );
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
        'spo2_red_raw, spo2_ir_raw, skin_temp_raw, '
        'step_count, step_cadence, activity_class, skin_temp_c, '
        'on_wrist, hr_valid, hr_alt, device_family '
        'FROM decoded_onehz '
        'WHERE rec_ts >= ? AND rec_ts <= ? AND ${derivableSourceSql()} '
        'ORDER BY rec_ts ASC, counter ASC LIMIT ?',
        [fromRecTs, toRecTs, limit],
      );
    }
    return db.rawQuery(
      'SELECT counter, rec_ts, hr, ax, ay, az, '
      'spo2_red_raw, spo2_ir_raw, skin_temp_raw, '
      'step_count, step_cadence, activity_class, skin_temp_c, '
      'on_wrist, hr_valid, hr_alt, device_family '
      'FROM decoded_onehz '
      'WHERE rec_ts >= ? AND rec_ts <= ? AND ${derivableSourceSql()} '
      'AND (rec_ts > ? OR (rec_ts = ? AND counter > ?)) '
      'ORDER BY rec_ts ASC, counter ASC LIMIT ?',
      [fromRecTs, toRecTs, afterRecTs, afterRecTs, afterCounter, limit],
    );
  }

  /// Sparse RR beats for one contiguous decoded 1 Hz page, by its rec_ts window.
  ///
  /// [fromRecTs] / [toRecTs] are the page's first and last record seconds (the
  /// page is ordered `rec_ts ASC`, so first = min, last = max). decoded_rr shares
  /// the rec_ts key with decoded_onehz, so `[fromRecTs, toRecTs]` on the PK
  /// contains exactly the page's beats — bounded, indexed, and immune to the
  /// strap's reboot counter reset (the old counter-span read could degenerate to
  /// `counter >= high AND counter <= low` = zero rows, silently dropping a whole
  /// page's RR).
  static Future<List<Map<String, dynamic>>> decodedRrByRecTsRange({
    required int fromRecTs,
    required int toRecTs,
  }) async {
    final db = await instance;
    final lo = fromRecTs <= toRecTs ? fromRecTs : toRecTs;
    final hi = fromRecTs <= toRecTs ? toRecTs : fromRecTs;
    return db.rawQuery(
      // `beat_ts_ms` is the MEASURED beat instant (`beatTimesMs`); `rr_ts_ms` is
      // `rec_ts * 1000`, a whole-second staircase that says every beat inside
      // one record happened at the same millisecond. Both are returned because
      // `beat_ts_ms` is NULL on every row banked before the column existed and
      // on every source that carries no sub-second — the reader coalesces.
      'SELECT rec_ts, beat_index, rr_ts_ms, rr_ms, beat_ts_ms FROM decoded_rr '
      'WHERE rec_ts >= ? AND rec_ts <= ? AND ${derivableSourceSql()} '
      'ORDER BY rec_ts ASC, beat_index ASC',
      [lo, hi],
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
    // WHO produced these scalars — 'band' for a day this app derived from 1 Hz
    // records, a vendor tag for an importer. NULL is the default and means
    // UNKNOWN; it is never filled in with a guess, because the whole point of
    // the column is that a guessed provenance is worse than none. See
    // [_createMetricSeriesVersion].
    String? source,
    // WHICH BAND'S UNITS these scalars are in — the substrate's own
    // `device_family` stamp, which is already null when the window spans two
    // straps or carries no stamp at all. Same rule as [source]: never guessed.
    // See [_createMetricSeriesVersion] and [foreignFamilyDates].
    String? deviceFamily,
  }) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    // THE write seam for the compact curve format. All four callers
    // (DerivationEngine x2, cloud_import, whoop_import) funnel through here, so
    // no producer needs to know the wire format exists — upstream code keeps
    // merging and patching plain [{t,v}] lists in memory. Lossless or no-op:
    // SeriesCodec leaves anything it cannot encode exactly as it found it.
    final encodedPayload = SeriesCodec.encodePayloadJson(payloadJson);
    await db.transaction((txn) async {
      await txn.insert('day_result', {
        'day_id': dayId,
        'algo_version': algoVersion,
        'payload_json': encodedPayload,
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
        // Whose maths wrote those scalars (see _createMetricSeriesVersion).
        // REPLACE, not IGNORE: the last pass to write the series is the one
        // that owns the stamp, including a ROLLED-BACK build writing a lower
        // version over a higher one — that is the case a MAX() over day_result
        // gets wrong, and the reason this is a stamp and not a query.
        //
        // Inside the same transaction as the values, so the stamp and what it
        // describes can never disagree. Skipped when the series map is empty:
        // an empty map wrote nothing, so there is nothing to attribute.
        if (series.isNotEmpty) {
          await txn.insert('metric_series_version', {
            'date': dayId,
            'algo_version': algoVersion,
            // The last pass to write the series owns the stamp — provenance
            // included, so a caller that does not know its own writes NULL
            // here rather than inheriting the previous writer's claim.
            'source': source,
            'device_family': deviceFamily,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  /// The version a `day_result` read is allowed to serve at most: the algo
  /// version of the build doing the reading.
  ///
  /// `PRIMARY KEY (day_id, algo_version)` makes versions SIBLINGS, not
  /// replacements, so a day can hold several generations at once. Picking the
  /// highest one present is right on the way up and wrong on the way down: a
  /// user who rolls back a store build, or leaves TestFlight for release, has
  /// rows from a version this build no longer implements, and `MAX()` serves
  /// them forever. A re-derive does not repair it — it writes a row at the
  /// LOWER version that `MAX()` then ignores — so day-detail (reading the
  /// bundle) and trends (reading the unversioned, always-overwritten
  /// `metric_series`) disagree about the same day permanently. Worse, if the
  /// newer version reinterpreted a field under the same key, the older UI reads
  /// it as a real number.
  ///
  /// A ceiling, not an equality test: rows from OLDER versions are still
  /// served, which is the existing (correct) behaviour for a day whose raw has
  /// aged out and which therefore never gets a fresh-version row. The rows
  /// above the ceiling are not deleted either — re-upgrading brings them back.
  ///
  /// `local_repository_impl.crossDayStaleReason` applies the same discipline to
  /// the cross-day artifact, with a comment calling the ungated case "the bug".
  static const int _servedAlgoCeiling = kAlgoVersion;

  /// The served-version join, in SQL: bind a `day_result r` to its highest row
  /// at or below [_servedAlgoCeiling]. Every reader (and the coach views) uses
  /// THIS rather than writing its own `MAX(algo_version)` — the pattern had
  /// already reappeared at five readers and two views, and the ceiling has to
  /// be on all of them or it is on none of them.
  static const String _servedDayJoin =
      'JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result '
      'WHERE algo_version <= $_servedAlgoCeiling GROUP BY day_id) m '
      'ON r.day_id = m.day_id AND r.algo_version = m.v';

  /// The result row for one day_id at the highest version this build serves
  /// (see [_servedAlgoCeiling]), with a normalized `date` alias for callers.
  /// Null if absent.
  static Future<Map<String, dynamic>?> dayResult(String dayId) async {
    final db = await instance;
    final rows = await db.query(
      'day_result',
      where: 'day_id = ? AND algo_version <= ?',
      whereArgs: [dayId, _servedAlgoCeiling],
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
      '$_servedDayJoin '
      'ORDER BY r.day_id DESC LIMIT ?',
      [limit],
    );
    return [for (final r in rows) _withDate(r)];
  }

  /// The N most recent days at their served version — EVERY column except the
  /// two big JSON blobs. Newest day_id first.
  ///
  /// The payload-free half of [recentDayResults]. `SELECT r.*` drags
  /// `payload_json` (~88 KB a day) for every row, so a caller that only needs
  /// "which days, at what version, finalized or not" was moving tens of MB of
  /// Dart strings to read a few scalars — measured at ~35 MB for a 400-day
  /// health-export pass, before the caller then decoded and RETAINED a bundle
  /// per day (~298 MB RSS). Fetch the bundle for one day at a time with
  /// [dayResult] and let each one go.
  static Future<List<Map<String, dynamic>>> recentDayResultsMeta(
    int limit,
  ) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT r.day_id, r.algo_version, r.computed_at, r.finalized, '
      'r.skipped, r.partial, r.rhr, r.rmssd, r.readiness '
      'FROM day_result r '
      '$_servedDayJoin '
      'ORDER BY r.day_id DESC LIMIT ?',
      [limit],
    );
    return [for (final r in rows) _withDate(r)];
  }

  /// `{day_id -> served algo_version}` for every day, payload-free.
  ///
  /// One query instead of a `dayResult()` per day: a caller walking history to
  /// ask "what version is this day at" was doing an N+1 that pulled a full
  /// bundle each time to read one integer.
  static Future<Map<String, int>> dayResultVersions() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT day_id, MAX(algo_version) AS v FROM day_result '
      'WHERE algo_version <= ? GROUP BY day_id',
      [_servedAlgoCeiling],
    );
    return {
      for (final r in rows)
        if (r['day_id'] is String && r['v'] is num)
          r['day_id'] as String: (r['v'] as num).toInt(),
    };
  }

  /// The stored sleep WINDOW for each of the [limit] most recent days, newest
  /// first, WITHOUT touching `payload_json`.
  ///
  /// `day_result.window_json` already holds the sleep-window Metric envelope
  /// (`{value: {onset_ms, offset_ms, …}, confidence, tier, …}`) in its own
  /// column, so onset/offset are one small projected read — no bundle decode,
  /// no per-day round trip. Rows: `{day_id, window_json}`.
  static Future<List<Map<String, dynamic>>> sleepWindowRows(int limit) async {
    final db = await instance;
    return db.rawQuery(
      'SELECT r.day_id AS day_id, r.window_json AS window_json '
      'FROM day_result r '
      '$_servedDayJoin '
      'WHERE r.skipped = 0 '
      'ORDER BY r.day_id DESC LIMIT ?',
      [limit],
    );
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
      'SELECT day_id FROM day_result WHERE algo_version <= ? '
      'GROUP BY day_id ORDER BY day_id DESC',
      [_servedAlgoCeiling],
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
      '$_servedDayJoin '
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
      '$_servedDayJoin '
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
      'FROM decoded_onehz WHERE rec_ts > 0 AND ${derivableSourceSql()} '
      'GROUP BY day_id ORDER BY day_id DESC',
    );
    final derivedRows = await db.rawQuery(
      'SELECT r.day_id, r.algo_version, r.computed_at, r.finalized '
      'FROM day_result r '
      '$_servedDayJoin '
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
    }) => copyPaged(table, where: where, whereArgs: whereArgs);

    Future<void> copyRawRange(int startSec, int endSec) async {
      // The day's 1 Hz rows stream page by page, and each page's RR beats are
      // pulled and written before the next page is read — so peak residency is
      // one page of `decoded_onehz` plus its beats, not a whole day of both.
      await copyPaged(
        'decoded_onehz',
        where: 'rec_ts >= ? AND rec_ts < ?',
        whereArgs: [startSec, endSec],
        onPage: (page) async {
          final recTsList = <Object?>[
            for (final row in page)
              if (row['rec_ts'] != null) row['rec_ts'],
          ];
          if (recTsList.isEmpty) return;
          // CHUNKED `IN (…)`: even one page's seconds can approach
          // SQLITE_MAX_VARIABLE_NUMBER, and a full day is 86,400 — two orders
          // of magnitude past it, so one giant statement could never bind.
          // Keyed on rec_ts (decoded_rr's key), which pulls exactly this page's
          // beats — a counter `IN` could over-match a reboot-reused counter.
          for (final chunk in _sqlVarChunks(recTsList)) {
            final placeholders = List.filled(chunk.length, '?').join(',');
            final rr = await src.rawQuery(
              'SELECT * FROM decoded_rr WHERE rec_ts IN ($placeholders)',
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
      await copyRows(
        'metric_series_version',
        where: 'date = ?',
        whereArgs: [dayId],
      );
      await copyRows('journal', where: 'date = ?', whereArgs: [dayId]);
      await copyRows('journal_metric', where: 'date = ?', whereArgs: [dayId]);
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
          where: 'rec_ts >= ? AND rec_ts < ?',
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
        // CASCADE the GPS route and the typed sets BEFORE their session row
        // disappears — otherwise the join key is gone and every lat/lng point
        // of a deleted run (and every logged set) stays on disk forever. Must
        // run first: once `sessions` is deleted the subquery is empty and the
        // children are unreachable.
        for (final child in const [
          'workout_route',
          'workout_split',
          'strength_set',
        ]) {
          deleted += await txn.rawDelete(
            'DELETE FROM $child WHERE session_id IN '
            '(SELECT id FROM sessions WHERE start_ts >= ? AND start_ts < ?)',
            [startSec, endSec],
          );
        }
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
      await deleteByIn(txn, 'metric_series_version', 'date', sorted);
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
      await deleteByIn(txn, 'sleep_nap', 'day_id', sorted);
    });
    return deleted;
  }

  /// Empty EVERY table — the honest reading of "Delete everything".
  ///
  /// Enumerated from `sqlite_master`, never from a hand-written list. The
  /// hand-written list is exactly how the old reset missed about twenty tables
  /// (labs, nutrition, medication, breathing sessions, strength sets, the
  /// rolling baselines) while telling the user it had deleted them: a table
  /// added later has to be REMEMBERED here, and it never is. This way a new
  /// table cannot escape the wipe by being forgotten.
  ///
  /// `sync_cursor` IS cleared, deliberately. It is the band's "you already have
  /// everything up to here" mark, and the band trims its flash as we ACK — so
  /// the history is unrecoverable either way, cursor or no cursor. Keeping it
  /// would only leave a wiped phone silently draining nothing on the next sync,
  /// because every record the band still holds sits behind the frontier. A
  /// reset that leaves the cursor is not a reset.
  ///
  /// The SCHEMA is untouched: no DROP, no re-open, no re-migration (migrations
  /// run inside `openDatabase` on iOS's CPU watchdog — not somewhere to be on
  /// the tail of a destructive user action). Views are `type='view'` and are
  /// not matched; the sqlite/Android internal tables are skipped by name.
  static Future<int> wipeAll() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
    );
    var deleted = 0;
    await db.transaction((txn) async {
      for (final r in rows) {
        final t = r['name'];
        if (t is String) deleted += await txn.delete(t);
      }
    });
    return deleted;
  }

  /// Every table this database owns, for callers that need to reason about the
  /// whole store rather than one part of it (the reset test, [wipeAll]).
  static Future<List<String>> tableNames() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata' "
      'ORDER BY name',
    );
    return [for (final r in rows) r['name'] as String];
  }

  /// True when [dayId] holds a day this device DERIVED ITSELF from real 1 Hz —
  /// as opposed to absent, a skip marker, or an earlier import.
  ///
  /// THE guard every import must pass before writing a day. `putDayResult` is
  /// INSERT OR REPLACE and imports write `finalized: 1`, so overwriting a
  /// measured day both destroys it and locks the replacement in — the raw it
  /// came from is pruned within days, and `DerivationEngine` never revisits a
  /// finalized row. Irreversible, and there is no per-source undo.
  ///
  /// It lived as a private static inside `WhoopImporter`, which is why exactly
  /// one of the four import paths honoured it.
  static Future<bool> isMeasuredDay(String dayId) async =>
      isMeasuredDayRow(await dayResult(dayId));

  /// [isMeasuredDay] over an already-fetched row. Pure.
  static bool isMeasuredDayRow(Map<String, dynamic>? row) {
    if (row == null) return false;
    if (((row['skipped'] as num?) ?? 0).toInt() == 1) return false;
    try {
      final p = SeriesCodec.decodePayloadJson(
        (row['payload_json'] as String?) ?? '{}',
      );
      if (p != null) {
        if (p['skipped'] == true) return false;
        // A prior import (any importer) is replaceable — all of them are
        // snapshots, none of them is measured on-device data.
        if (p['imported'] == true) return false;
      }
    } catch (_) {
      // Present but unreadable — treat as real and refuse to clobber it.
      return true;
    }
    return true;
  }

  /// SQL selecting the `date` of every day whose scalars were IMPORTED.
  /// A fragment so the mask and the filters that apply it cannot drift apart.
  ///
  /// TWO SIGNALS, because the exact one is younger than the data:
  ///
  ///  * `metric_series_version.source` — precise, but the column only exists
  ///    from schema v43 and is deliberately NEVER retro-filled (a guessed
  ///    provenance is worse than none). Every day written before v43 reads
  ///    NULL, which is most of any real user's history.
  ///  * `day_result.payload_json`'s `"imported": true` — the marker BOTH
  ///    importers have written since they existed, and the same flag
  ///    [isMeasuredDayRow] tests on the write path.
  ///
  /// The second is what makes a NULL `source` DECIDABLE rather than ambiguous:
  /// NULL means "the column did not exist yet", not "unknown vendor", and the
  /// bundle behind that day still says who wrote it. So NULL is resolved
  /// against the payload rather than treated as suspect — dropping every
  /// NULL-source day would delete the user's genuine pre-v43 history from
  /// their own baselines, i.e. fabricate a baseline out of a short recent
  /// window, which is the worse fault of the two.
  ///
  /// A substring match, not `json_extract`: `jsonEncode` emits no spaces and
  /// this app is the only writer of the flag, so the literal is exact, and it
  /// does not assume a JSON1-enabled sqlite on every platform we ship to.
  ///
  /// The `IS NOT NULL` guards are not decoration. SQLite does not enforce NOT
  /// NULL on a declared PRIMARY KEY column of a legacy rowid table, and a
  /// single NULL inside a `NOT IN (…)` list makes the whole predicate NULL for
  /// EVERY row — one stray row would silently empty every baseline in the app
  /// rather than filter one day out of it.
  /// THE SERVED VERSION ONLY on the `day_result` half, for the same reason
  /// every other reader uses [_servedDayJoin]: `PRIMARY KEY (day_id,
  /// algo_version)` makes versions siblings, so an imported day that the band
  /// LATER re-derived keeps its old imported row sitting beside the new
  /// measured one. Testing every row made that day imported FOREVER — masked
  /// out of the baselines it is now entitled to be in, with no way back
  /// short of deleting the superseded row. `metric_series_version` needs no
  /// such guard: it is `PRIMARY KEY (date)` and the last writer replaces it,
  /// which is exactly why the stamp exists.
  static const String _importedDatesSql =
      'SELECT date FROM metric_series_version '
      "WHERE date IS NOT NULL AND source IS NOT NULL AND source <> 'band' "
      'UNION '
      'SELECT r.day_id FROM day_result r '
      '$_servedDayJoin '
      "WHERE r.day_id IS NOT NULL AND r.payload_json LIKE '%\"imported\":true%'";

  /// Day labels whose stored scalars are ANOTHER vendor's derived numbers.
  ///
  /// THE MASK for every baseline read, and the inverse of [isMeasuredDay]:
  /// that one guards the WRITE path (an import must not clobber a measured
  /// day), and nothing guarded the read path — so imported days were feeding
  /// the readiness and illness baselines the user's own scores are measured
  /// against. A window that mixes them is not a baseline of this person.
  ///
  /// Returned as a set rather than applied inside each query on purpose: the
  /// scan behind it is over `day_result.payload_json` (whole day bundles), so
  /// a caller reading several series takes it ONCE and filters in Dart.
  static Future<Set<String>> importedDates() async {
    final db = await instance;
    return {
      for (final r in await db.rawQuery(_importedDatesSql)) r['date'] as String,
    };
  }

  /// The `metric_series` keys whose stored VALUES ARE IN THE BAND'S OWN UNITS,
  /// so a day measured by a different band family is not on the same scale as
  /// today's and must not sit in the same baseline.
  ///
  /// DELIBERATELY SHORT, and it is a list of UNIT MISMATCHES, not of things
  /// that got noisier. `skin_temp_adc` is a gen4 thermistor ADC COUNT on one
  /// side of a strap swap and a gen5 CENTI-DEGREE reading on the other — the
  /// same key holding two different quantities, which is a wrong number, not a
  /// less precise one. `rhr` and `rmssd` off a different wrist sensor are the
  /// same quantity measured slightly differently: masking those would delete
  /// the user's history from their own baseline to fix a bias smaller than the
  /// window it is measured over. Nothing joins this set without a measured unit
  /// difference behind it.
  static const Set<String> familySeamKeys = {'skin_temp_adc'};

  /// Day labels whose scalars were measured by a DIFFERENT band family than the
  /// most recent stamped day — the mask for [familySeamKeys] baselines.
  ///
  /// Two properties that make this safe to apply unconditionally:
  ///  * A NULL stamp is never foreign. Unknown provenance is its own case (see
  ///    [_createMetricSeriesVersion]); every day written before the column
  ///    existed reads NULL, and dropping those would delete a real user's whole
  ///    history from their own baseline.
  ///  * A single-family user gets the EMPTY SET, because nothing differs from
  ///    the newest stamp. So this changes no number until a strap actually
  ///    changes generation.
  static Future<Set<String>> foreignFamilyDates() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT date FROM metric_series_version '
      'WHERE date IS NOT NULL AND device_family IS NOT NULL '
      'AND device_family <> ('
      '  SELECT device_family FROM metric_series_version '
      '  WHERE device_family IS NOT NULL ORDER BY date DESC LIMIT 1'
      ')',
    );
    return {for (final r in rows) r['date'] as String};
  }

  /// Import another device's exported OpenStrap DB ([path], from [exportCopy] +
  /// share) by MERGING its rows into this one (INSERT-OR-REPLACE). Covers derived
  /// results, the metric series, user data, and the raw ledger so the receiving
  /// device has the full history (and can re-derive). Same app ⇒ same schema; a
  /// table missing in the source is skipped. Locally FINALIZED day_result rows
  /// are protected — an import never overwrites them. Returns per-table counts
  /// of rows actually copied.
  ///
  /// The picked file may be COMPRESSED. Auto-backups are written gzipped, so
  /// the file a user reinstalling onto a new phone reaches for is a `.db.gz`,
  /// and handing that straight to `openDatabase` fails with "file is not a
  /// database" — the app could write backups it could not restore. Detected by
  /// MAGIC BYTES, not by extension: a file manager or a sync client that
  /// renames on the way through is exactly the situation a restore has to
  /// survive. Plain `.db` files (older backups, and `exportCopy` output) take
  /// the same path they always did.
  static Future<Map<String, int>> importFromDbFile(String path) async {
    if (!await File(path).exists()) {
      throw const FileSystemException('Backup file not found');
    }
    if (await sniffFile(path) != ImportContainer.gzip) {
      return _mergeFromDbFile(path);
    }
    final work = await Directory.systemTemp.createTemp('openstrap_restore_');
    try {
      final inflated = await inflateGzip(path, work);
      if (inflated == null ||
          await sniffFile(inflated) != ImportContainer.sqlite) {
        throw const ImportFormatException(
          'That file unpacked to something that is not an OpenStrap database.',
        );
      }
      return await _mergeFromDbFile(inflated);
    } finally {
      // The inflated copy is a full second copy of the database, so it goes
      // whether the import worked or not.
      try {
        if (work.existsSync()) await work.delete(recursive: true);
      } catch (_) {
        /* the OS reclaims the temp dir eventually */
      }
    }
  }

  /// Merge every table [tables] names from the database file at [path] into
  /// this one.
  ///
  /// [only] overrides the table list and its ORDER — used by [_openOrRebuild],
  /// which wants the irreplaceable tables first. [tolerant] isolates each table
  /// behind its own catch: a rebuild salvaging a genuinely damaged file must
  /// lose that table and keep going, where a user-initiated restore of a file
  /// they chose must still fail loudly rather than report a partial success.
  static Future<Map<String, int>> _mergeFromDbFile(
    String path, {
    List<String>? only,
    bool tolerant = false,
  }) async {
    final src = await openDatabase(path, readOnly: true);
    final db = await instance;
    // Order: independent tables; all use INSERT OR REPLACE so re-import is safe.
    const tables = [
      // Hand-entered rows first. Nothing regenerates these, so if a merge is
      // ever cut short (an OOM, a damaged source) they are the ones already
      // banked. They were also simply MISSING here until now — nutrition,
      // medication, strength sets, symptoms and routes did not survive a
      // backup/restore round trip at all, the same omission `wipeAll` documents.
      'journal',
      'journal_metric',
      'journal_field_def',
      'lab_result',
      'lab_marker_def',
      'strength_set',
      'exercise_def',
      'food_entry',
      'food_def',
      'med_def',
      'med_dose',
      'cycle_log',
      'cycle_symptom',
      'breathing_session',
      // Vendor-computed, typed-in and imported scalars. In the hand-entered
      // block because a third of it IS hand-entered and nothing regenerates
      // any of it — a `reports` band trims its own history, and the app whose
      // export the imported rows came from may be uninstalled by now.
      'observation',
      'workout_route',
      'workout_split',
      // The user's sleep corrections. These are the ONLY copy of them — the
      // detector's output is deliberately not baked in, so a restore that
      // skipped these would silently reinstate every nap the user had deleted
      // and lose every one they logged.
      'sleep_override',
      'sleep_nap',
      'samples',
      'events',
      'decoded_onehz',
      'decoded_rr',
      // The only copy of what a paired sensor measured during a session — the
      // band cannot re-deliver it, so a restore that skipped it loses it.
      'external_hr',
      // Re-readable from the health store, but only for as long as that app is
      // installed and that permission is granted — cheaper to carry.
      'imported_measurement',
      // Same reasoning, and more so: a route is thousands of points that the
      // source app may have deleted since. `workout_route` is already in this
      // list above and carries the imported routes too.
      'imported_workout',
      // The never-pruned archive of frames we could not decode. exportCopy()
      // is a whole-database VACUUM INTO, so these rows DO leave the device —
      // leaving the table out here meant a backup/restore round trip silently
      // dropped them, in the one table whose entire purpose is that a frame is
      // never lost. Keyed by `hex`, so two same-counter frames from different
      // boots both survive the merge.
      'raw_archive',
      'band_events',
      'band_battery',
      'day_result',
      'metric_series',
      'metric_series_version',
      'sessions',
      'notifications',
      'baselines',
      // The devices this phone knows about — so a SECONDARY device's identity
      // survives a backup/restore round trip rather than leaving its rows in
      // `decoded_onehz` pointing at a `device_id` nothing can name. The PRIMARY
      // row is deliberately skipped on the way in; see the guard below.
      'device',
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
    // DISTINCT DAYS ACTUALLY WRITTEN — the number the caller reports as
    // "N days imported".
    //
    // `day_result`'s primary key is (day_id, algo_version), so a row count is
    // not a day count: a history that has lived through two algo bumps has two
    // rows for the same day. This used to be a COUNT(DISTINCT day_id) asked of
    // the SOURCE before anything was copied, which over-reported the other way
    // — a re-import where every local row is finalized (all skipped by the
    // protectedKeys guard below) still claimed the full source day count. Stays
    // null when day_result could not be read at all, so the caller can tell
    // "nothing imported" from "we don't know".
    Set<String>? importedDays;
    try {
      for (final t in (only ?? tables)) {
        try {
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
          if (t == 'day_result') importedDays = <String>{};
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

              final rows = <Map<String, Object?>>[];
              for (final r in page) {
                final row = <String, Object?>{
                  for (final e in r.entries)
                    if (cols.contains(e.key)) e.key: e.value,
                };
                if (row.isEmpty) continue;
                if (t == 'decoded_onehz') {
                  // A pre-v46 export still carries the retired columns as
                  // VALUES (the disproven on_wrist/hr_valid reads and the
                  // -50.00 °C skin-temp error sentinel). Importing them
                  // verbatim would reinstate exactly the rows the v46
                  // data-retirement cleaned, so the same rule applies at this
                  // boundary — the migration only runs on version bumps and
                  // never sees imported rows.
                  if (cols.contains('on_wrist')) row['on_wrist'] = null;
                  if (cols.contains('hr_valid')) row['hr_valid'] = null;
                  final st = row['skin_temp_c'];
                  if (st is num && st <= -49.995) row['skin_temp_c'] = null;
                }
                // THE PRIMARY DEVICE IS NOT PORTABLE. Its `remote_id` is a
                // per-install handle — a CBPeripheral UUID that is unique to
                // the phone AND the app install on iOS, a rotating RPA on
                // Android — so a foreign export's copy names a peripheral this
                // phone cannot connect to. Importing it would REPLACE the local
                // pairing (id `''` is the primary, permanently) and leave the
                // app claiming a band that is not there. A restore onto the
                // same install needs nothing from here: the row is already
                // present, and the SharedPreferences mirror re-establishes it
                // if the database was rebuilt.
                if (t == 'device' && row['id'] == kPrimaryDeviceId) continue;
                if (t == 'day_result') {
                  if (protectedKeys.contains(
                    '${row['day_id']}|${row['algo_version']}',
                  )) {
                    continue; // locally finalized — never overwritten by import
                  }
                  importedDays?.add('${row['day_id']}');
                }
                // A LEGACY export's decoded_rr carries no rec_ts column; derive
                // it from rr_ts_ms (= rec_ts*1000) so the NOT NULL PK column is
                // always populated. SQLite storage classes are per VALUE, not per
                // column, so a foreign export can hand back a String where
                // INTEGER is declared — a bare `as num` there throws inside the
                // transaction and takes the whole restore down with it. Leave a
                // non-numeric value alone and let the row fail its own NOT NULL
                // check instead of aborting every other row's import.
                if (t == 'decoded_rr' && row['rec_ts'] == null) {
                  final rrTsMs = row['rr_ts_ms'];
                  if (rrTsMs is! num) {
                    // Nothing to key this beat by. Dropping the one row keeps the
                    // rest of the restore alive; letting it through would fail
                    // the NOT NULL check inside the transaction and take every
                    // other row on the page down with it.
                    continue;
                  }
                  row['rec_ts'] = rrTsMs.toInt() ~/ 1000;
                }
                // A PRE-v47 EXPORT CARRIES NO `device_id` / `ts_ms`. Left
                // alone they take the column DEFAULTS — ('', 0) — so every
                // imported row would collide on ONE primary key and REPLACE
                // the whole table down to a single row. Derive the key exactly
                // as [_rekeyTableByDevice] does: the primary band, and the
                // row's own time in ms. AFTER the rec_ts recovery above, which
                // is what decoded_rr's key is built from.
                // NAMED, not sniffed off `ts_ms`: `workout_route` declares that
                // column too and is in the merge list, but it was never re-keyed —
                // it has no `device_id` and no `rec_ts`, so a null `ts_ms` there
                // falls to the `t0 is! num` drop below and the route point vanishes
                // without a word. NOT NULL keeps that unreachable from a database
                // this app wrote; the table NAME is what keeps it unreachable after
                // the next schema change.
                const deviceKeyed = {'samples', 'decoded_onehz', 'decoded_rr'};
                if (deviceKeyed.contains(t) && row['ts_ms'] == null) {
                  row['device_id'] ??= kPrimaryDeviceId;
                  final t0 = row[t == 'samples' ? 'ts' : 'rec_ts'];
                  // Non-numeric (storage classes are per VALUE in a foreign
                  // export) ⇒ drop the one row rather than key it at 0, where
                  // it would REPLACE another row that genuinely belongs there.
                  if (t0 is! num) continue;
                  row['ts_ms'] = t0.toInt() * 1000;
                }
                rows.add(row);
              }
              // REPLACE the beat set for a colliding second, don't patch it.
              // decoded_rr is keyed by (rec_ts, beat_index), so a row-by-row
              // replace-insert only overwrites the indices the foreign export
              // actually reaches: importing [500] over a local [700, 710, 720]
              // leaves beats 1 and 2 behind and hands that second a spliced
              // foreign/local RR series — silently wrong RMSSD, out of a restore.
              // [_queueDecodedOneHz] guards the identical hazard on the write
              // path with a DELETE ahead of its inserts.
              //
              // Here the delete has to TRAIL the inserts and be bounded by the
              // highest index this page carried, because a second's beats can
              // straddle a page boundary: a leading `DELETE WHERE rec_ts = ?` on
              // page 2 would wipe the beats page 1 just imported. Trailing +
              // bounded is idempotent across the split — page 1 inserts 0,1 and
              // clears >1; page 2 inserts 2,3 and clears >3 — and beat_index is
              // dense by construction, so "everything past the last one" is
              // exactly the stale local tail.
              // v47: keyed on (device_id, ts_ms), the beat's real key — so the
              // tail sweep can only ever clear the WRITING device's stale
              // beats, never the other band's for the same second.
              final highestBeat = <(Object?, Object?), int>{};
              for (final row in rows) {
                batch.insert(
                  t,
                  row,
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
                copied++;
                if (t == 'decoded_rr') {
                  final idx = row['beat_index'];
                  final key = (row['device_id'], row['ts_ms']);
                  if (key.$2 != null && idx is num) {
                    final n = idx.toInt();
                    final prev = highestBeat[key];
                    if (prev == null || n > prev) highestBeat[key] = n;
                  }
                }
                if (++ops >= chunkOps) await flush();
              }
              for (final e in highestBeat.entries) {
                batch.delete(
                  'decoded_rr',
                  where: 'device_id = ? AND ts_ms = ? AND beat_index > ?',
                  whereArgs: [e.key.$1, e.key.$2, e.value],
                );
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
        } catch (_) {
          // One table's worth of loss, not the whole salvage. A user-initiated
          // restore still rethrows: reporting a partial import as a success is
          // the worst available outcome there, whereas a rebuild has no better
          // file to fall back to.
          if (!tolerant) rethrow;
          counts[t] = 0;
        }
      }
    } finally {
      await src.close();
    }
    // An import writes day_result rows with a raw batch.insert, deliberately
    // bypassing putDayResult (and therefore the curve-encode seam), so the rows
    // arrive in whatever shape the source device stored — legacy, if it was on
    // an older build. The re-encode walk is forward-only and latches `done`, so
    // once it has finished those rows would never be looked at again and the
    // growth this walk exists to remove would come straight back with the
    // import. Rewind it.
    if ((counts['day_result'] ?? 0) > 0) {
      await putComputeFreshness(kReencodeCursorKey, jsonEncode({}));
    }
    // Last, so it can never be mistaken for a table row count by anything that
    // walks this map in order.
    if (importedDays != null) counts['_days'] = importedDays.length;
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
      'lab_result',
      'lab_marker_def',
      'breathing_session',
      'food_entry',
      'food_def',
      'med_def',
      'med_dose',
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
      'workout_split',
      'notif_fired',
      'metric_series_version',
      'band_backlog',
      'external_hr',
      'imported_measurement',
      'imported_workout',
      'observation',
      'device',
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

    expect('sessions', sessionCols, [
      'id',
      'start_ts',
      'status',
      'steps',
      // The frozen trace: a build that lost these columns silently blanks the
      // chart half of every session older than the substrate window.
      'trace_json',
      'trace_samples',
    ]);
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
      final decoded =
          SeriesCodec.decodePayloadJson(row['payload_json']) ??
          const <String, dynamic>{};
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
  }) => putBaseline(
    'movement_floor',
    jsonEncode({'floor_g': floorG, 'frozen_on': frozenOn, 'days': days}),
  );

  /// Write ONE (date, key) scalar into the canonical series store.
  ///
  /// The bulk path is [putDayResult]'s `series` map, which writes a whole day's
  /// scalars alongside its bundle. This is for the case where a series row has
  /// to be corrected on its own — a day whose bundle is gone but whose trend
  /// point is still on screen (see `strain_backfill.dart`).
  static Future<void> putMetricSeriesValue(
    String date,
    String key,
    double? value,
  ) async {
    final db = await instance;
    await db.insert('metric_series', {
      'date': date,
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// A long-format metric series (oldest first) for trends/sparklines.
  ///
  /// [measuredOnly] drops days another vendor's export wrote (see
  /// [importedDates]). OFF by default: a trend line is a picture of the user's
  /// history and imported days belong in it. Turn it ON for anything that
  /// COMPUTES against the series — a baseline, a personal percentile, a
  /// seed-versus-band comparison — where a foreign algorithm's output is not
  /// the same measurement.
  static Future<List<Map<String, dynamic>>> metricSeries(
    String key, {
    int? limit,
    bool measuredOnly = false,
  }) async {
    final db = await instance;
    return db.query(
      'metric_series',
      where: 'key = ? AND value IS NOT NULL'
          '${measuredOnly ? ' AND date NOT IN ($_importedDatesSql)' : ''}',
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
  ///
  /// [measuredOnly] defaults ON here, unlike [metricSeries]: this helper exists
  /// to build a rolling baseline, and a baseline blended with another vendor's
  /// derived numbers is not a baseline of this person (see [importedDates]).
  static Future<List<double>> trailingSeriesValues(
    String key,
    int n, {
    bool measuredOnly = true,
  }) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT value FROM metric_series '
      'WHERE key = ? AND value IS NOT NULL '
      '${measuredOnly ? 'AND date NOT IN ($_importedDatesSql) ' : ''}'
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
  /// more than one isolate — Android headless sync wakes construct their own
  /// `DerivationEngine` in a separate background isolate — and a `static`
  /// mutex has one copy per isolate. Two isolates would each read the same
  /// payload, merge into it, and write back, dropping the other's changes.
  /// That matters most for accumulator payloads like `sleep_user_profile`,
  /// where a lost write also loses the record of
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
      final current = rows.isEmpty
          ? null
          : rows.first['payload_json'] as String?;
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

  /// Bookkeeping key for the one-time walk in [reencodeLegacyDayResults].
  static const String kReencodeCursorKey = 'series_reencode';

  /// Test seam: awaited inside [reencodeLegacyDayResults] between the batch
  /// prepare and the write transaction. Null in production, and the only cost
  /// there is one null check per batch.
  ///
  /// It exists because the race the compare-and-set guards is a placement
  /// problem, not a timing one: a competing derive has to land in that exact
  /// window. Pinning it with a sleep meant the test asserted a real property
  /// only as long as the runner stayed inside the delay, which is the shape of
  /// a test that passes on a laptop and goes red on a loaded CI box.
  @visibleForTesting
  static Future<void> Function()? debugAfterReencodePrepare;

  /// Re-encode a BOUNDED batch of pre-codec `day_result` rows into the compact
  /// curve format, newest first. Returns how many rows were rewritten.
  ///
  /// WHY A BACKFILL AT ALL. `SeriesCodec` reads the legacy shape forever, so
  /// nothing breaks without this — but a user's existing history would stay at
  /// ~88 KB/day while only new days shrank, and `day_result` is precisely the
  /// store that grows without bound. This converts the back catalogue once.
  ///
  /// WHERE IT RUNS. Called from the derivation engine's post-derive
  /// housekeeping, beside `pruneSupersededIntermediates` — off the path to a
  /// durable commit, and NEVER inside a migration: `onUpgrade` runs inside
  /// `openDatabase` under iOS's CPU watchdog, where rewriting a year of bundles
  /// would be a launch hang (invariant 11).
  ///
  /// A FORWARD-ONLY CURSOR, not a rescan. Progress is stored in
  /// `compute_freshness`, so each call walks strictly older days than the last
  /// and the whole history costs one pass. Re-scanning from the newest day
  /// every time would re-read (and re-parse) every already-converted bundle
  /// forever — tens of MB of I/O per derivation.
  ///
  /// IMMUTABILITY. `day_result` rows are immutable PER VERSION, meaning their
  /// derived VALUES never change without a `kAlgoVersion` bump. This rewrite
  /// changes only how those same values are spelled, and every row is gated on
  /// [SeriesCodec.verifyLossless] before it is touched — a bundle whose
  /// round-trip is not provably exact is skipped and left legacy. Nothing but
  /// `payload_json` is written: `computed_at`, `finalized`, `partial` and the
  /// indexed scalars are untouched, so no day is re-finalized or re-dated.
  static Future<int> reencodeLegacyDayResults({int limit = 40}) async {
    final db = await instance;

    String? cursorDay;
    int? cursorVersion;
    final prev = await computeFreshness(kReencodeCursorKey);
    final prevJson = prev?['payload_json'];
    if (prevJson is String && prevJson.isNotEmpty) {
      try {
        final d = jsonDecode(prevJson);
        if (d is Map) {
          if (d['done'] == true) return 0; // whole history already walked
          final c = d['cursor'];
          if (c is String && c.isNotEmpty) cursorDay = c;
          final v = d['cursor_version'];
          if (v is int) cursorVersion = v;
        }
      } catch (_) {
        /* unreadable bookkeeping ⇒ start over; the walk is idempotent */
      }
    }

    // The cursor is the COMPOSITE key, not just the day. `day_result` is keyed
    // (day_id, algo_version) and one day can hold several generations, so a
    // day-only cursor stepped straight past a day's older rows and left them
    // legacy forever.
    //
    // Spelled out rather than as the row-value form `(day_id, algo_version) <
    // (?, ?)`: row values need SQLite 3.15, and on Android sqflite uses the
    // OS's SQLite, which is older than that on the devices this app still
    // supports.
    final String? where;
    final List<Object?>? whereArgs;
    if (cursorDay == null) {
      where = null;
      whereArgs = null;
    } else if (cursorVersion == null) {
      where = 'day_id < ?';
      whereArgs = [cursorDay];
    } else {
      where = 'day_id < ? OR (day_id = ? AND algo_version < ?)';
      whereArgs = [cursorDay, cursorDay, cursorVersion];
    }

    final rows = await db.query(
      'day_result',
      columns: ['day_id', 'algo_version', 'payload_json'],
      where: where,
      whereArgs: whereArgs,
      orderBy: 'day_id DESC, algo_version DESC',
      limit: limit,
    );
    if (rows.isEmpty) {
      await putComputeFreshness(kReencodeCursorKey, jsonEncode({'done': true}));
      return 0;
    }

    // PREPARE ON A WORKER ISOLATE, outside the transaction.
    //
    // Outside the transaction because each eligible bundle costs several JSON
    // parse/serialize passes (needsReencode, then verifyLossless, which encodes
    // and decodes to prove the round trip, then the real encode), and doing
    // that inside db.transaction held the write lock open across ~40 x ~88 KB
    // of pure CPU while the rest of the app waited to write.
    //
    // Off THIS isolate because that CPU is otherwise synchronous on whichever
    // isolate called the derive, and the derive is called from the UI one:
    // measured at 0.1-0.4 s per batch on a desktop, which is several times that
    // on a mid-tier phone, with no await in the loop for the frame scheduler to
    // get a word in. This app has shipped a derive-correlated main-isolate
    // freeze before. `SeriesCodec` is pure — no I/O, no plugins, no Flutter —
    // so it is safe anywhere, and the batch is bounded by `limit`.
    final payloads = [
      for (final row in rows)
        (row['payload_json'] is String) ? row['payload_json'] as String : '',
    ];
    final prepared = await Isolate.run(() => _reencodeBatch(payloads));
    // The window the compare-and-set below exists to close: the rows were read,
    // the encode took real time, and nothing has been locked yet. A test drives
    // a competing write through here rather than racing a sleep against it —
    // the interleave is the whole property, so it has to be placed rather than
    // hoped for.
    final afterPrepare = debugAfterReencodePrepare;
    if (afterPrepare != null) await afterPrepare();

    final updates =
        <
          ({
            int rowIndex,
            String dayId,
            int algoVersion,
            String from,
            String to,
          })
        >[];
    for (var i = 0; i < rows.length; i++) {
      final encoded = prepared[i];
      if (encoded == null) continue;
      updates.add((
        rowIndex: i,
        dayId: rows[i]['day_id'] as String,
        algoVersion: (rows[i]['algo_version'] as num).toInt(),
        from: payloads[i],
        to: encoded,
      ));
    }

    var rewritten = 0;
    // Index of the OLDEST-ranked row (first in this newest-first batch) whose
    // compare-and-set found something other than what we read.
    int? missedIndex;
    if (updates.isNotEmpty) {
      await db.transaction((txn) async {
        for (final u in updates) {
          // COMPARE-AND-SET on the payload we actually read.
          //
          // The prepare above deliberately runs outside any transaction and
          // takes hundreds of milliseconds, and derivation runs in more than
          // one isolate (see updateBaseline's exclusive transaction for the
          // same hazard). A blind `WHERE day_id = ? AND algo_version = ?` will
          // happily write a stale bundle over a row that a concurrent derive
          // rewrote in the meantime — and because this walk starts at the
          // NEWEST day with kAlgoVersion unbumped, its first targets are
          // exactly the rows a light derive is rewriting. The row would end up
          // holding the new scalar columns beside the old payload.
          //
          // A row that has moved is left alone. It is not lost: the cursor is
          // held back below so a later pass looks at it again.
          final n = await txn.update(
            'day_result',
            {'payload_json': u.to},
            where: 'day_id = ? AND algo_version = ? AND payload_json = ?',
            whereArgs: [u.dayId, u.algoVersion, u.from],
          );
          if (n > 0) {
            rewritten++;
          } else {
            missedIndex ??= u.rowIndex;
          }
        }
      });
    }

    // The cursor advances past every row we LOOKED at, not just the ones we
    // rewrote — a row we skipped (already encoded, or not provably lossless)
    // would otherwise be re-examined on every future pass and the walk would
    // never terminate.
    //
    // A row that lost the compare-and-set is the one exception: it is parked
    // just BEHIND the cursor so the next pass reads it again, and `done` is
    // withheld so the walk cannot latch shut over it. A missed FIRST row leaves
    // the cursor exactly where it was, which costs one repeated batch and
    // converges — the second look either re-encodes the row or finds it already
    // encoded and steps past.
    final Map<String, Object?> mark;
    final missed = missedIndex;
    if (missed == null) {
      mark = {
        'cursor': rows.last['day_id'],
        'cursor_version': rows.last['algo_version'],
        'done': rows.length < limit,
      };
    } else if (missed > 0) {
      mark = {
        'cursor': rows[missed - 1]['day_id'],
        'cursor_version': rows[missed - 1]['algo_version'],
        'done': false,
      };
    } else if (cursorDay == null) {
      mark = const {};
    } else {
      mark = {
        'cursor': cursorDay,
        'cursor_version': cursorVersion,
        'done': false,
      };
    }
    await putComputeFreshness(
      kReencodeCursorKey,
      jsonEncode({...mark, 'rewritten_last': rewritten}),
    );
    return rewritten;
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
      final decoded =
          SeriesCodec.decodePayloadJson(row['payload_json']) ??
          const <String, dynamic>{};
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
      (out[r['date'] as String] ??= {})[r['field']
          as String] = JournalMetricValue(
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

  /// Create-only. A conflicting key THROWS instead of replacing: REPLACE
  /// would silently rewrite another definition's metadata (label, unit, kind)
  /// while its recorded history stayed — a field that means something else
  /// wearing the old rows. The UI rejects duplicates before it gets here; the
  /// throw is the race/programmatic-caller backstop.
  static Future<void> putJournalFieldDef(JournalFieldSpec spec) async {
    final db = await instance;
    final exists = await db.query(
      'journal_field_def',
      where: 'key = ?',
      whereArgs: [spec.key],
      limit: 1,
    );
    if (exists.isNotEmpty) {
      throw StateError('journal field already exists: ${spec.key}');
    }
    await db.insert('journal_field_def', {
      'key': spec.key,
      'label': spec.label,
      'kind': spec.kind.name,
      'unit': spec.unit,
      'max_value': spec.max,
      'step': spec.step,
      'has_time': spec.hasTime ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ── nap edits ─────────────────────────────────────────────────────────────

  /// Log a nap the detector missed, or suppress one it invented.
  static Future<void> putNapEdit({
    required String dayId,
    required int startTs,
    required int endTs,
    required String source,
  }) async {
    final db = await instance;
    await db.insert('sleep_nap', {
      'day_id': dayId,
      'start_ts': startTs,
      'end_ts': endTs,
      'source': source,
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteNapEdit(String dayId, int startTs) async {
    final db = await instance;
    await db.delete(
      'sleep_nap',
      where: 'day_id = ? AND start_ts = ?',
      whereArgs: [dayId, startTs],
    );
  }

  static Future<List<Map<String, dynamic>>> napEdits(String dayId) async {
    final db = await instance;
    return db.query(
      'sleep_nap',
      where: 'day_id = ?',
      whereArgs: [dayId],
      orderBy: 'start_ts ASC',
    );
  }

  /// Every day carrying a nap edit. Force-derived alongside the sleep-override
  /// days for the same reason: an edit to a finalized day has to take effect.
  static Future<Set<String>> napEditDays() async {
    final db = await instance;
    final rows = await db.query('sleep_nap', columns: ['day_id']);
    return {for (final r in rows) r['day_id'] as String};
  }

  // ── breathing sessions ────────────────────────────────────────────────────

  static Future<void> putBreathingSession({
    required int startedAt,
    required int endedAt,
    required String pattern,
    required int seconds,
    double? coherence,
    double? confidence,
  }) async {
    final db = await instance;
    await db.insert('breathing_session', {
      'started_at': startedAt,
      'ended_at': endedAt,
      'pattern': pattern,
      'seconds': seconds,
      'coherence': coherence,
      'confidence': confidence,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// MIND-06 — attach the quiet-window RMSSDs to an already-banked session.
  ///
  /// A separate write because the two windows outlive the paced block by two
  /// minutes: the row is banked when the pacing stops, and the post window is
  /// still running then. An UPDATE rather than a second insert, so a session
  /// that was too short to bank at all stays unbanked (`changes` is 0 and
  /// nothing is created behind it).
  ///
  /// A window that produced no usable estimate writes NULL rather than being
  /// skipped — "we measured and could not read it" and "we never measured" are
  /// the same row here, and both are absent, which is what the paired test
  /// drops.
  static Future<void> updateBreathingWindows({
    required int startedAt,
    double? preRmssd,
    double? postRmssd,
  }) async {
    final db = await instance;
    await db.update(
      'breathing_session',
      {'pre_rmssd': preRmssd, 'post_rmssd': postRmssd},
      where: 'started_at = ?',
      whereArgs: [startedAt],
    );
  }

  /// Recent sessions, newest first.
  static Future<List<Map<String, dynamic>>> breathingSessions({
    int limit = 30,
  }) async {
    final db = await instance;
    return db.query(
      'breathing_session',
      orderBy: 'started_at DESC',
      limit: limit,
    );
  }

  // ── lab results ───────────────────────────────────────────────────────────

  /// Upsert one result. Idempotent on (marker, date drawn), so re-entering a
  /// value corrects it instead of stacking a near-duplicate.
  static Future<void> putLabResult({
    required String marker,
    required String takenOn,
    required double value,
    required String unit,
    String note = '',
  }) async {
    final db = await instance;
    await db.insert('lab_result', {
      'marker': marker,
      'taken_on': takenOn,
      'value': value,
      'unit': unit,
      'note': note,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteLabResult(String marker, String takenOn) async {
    final db = await instance;
    await db.delete(
      'lab_result',
      where: 'marker = ? AND taken_on = ?',
      whereArgs: [marker, takenOn],
    );
  }

  /// Every result, newest draw first. [marker] narrows to one series.
  static Future<List<Map<String, dynamic>>> labResults({String? marker}) async {
    final db = await instance;
    return db.query(
      'lab_result',
      where: marker == null ? null : 'marker = ?',
      whereArgs: marker == null ? null : [marker],
      orderBy: 'taken_on DESC',
    );
  }

  /// Custom marker definitions, by label.
  static Future<List<Map<String, dynamic>>> labMarkerDefs() async {
    final db = await instance;
    return db.query('lab_marker_def', orderBy: 'label ASC');
  }

  static Future<void> putLabMarkerDef(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert('lab_marker_def', {
      ...row,
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

  /// Forget a custom marker's DEFINITION. Its results are left alone — those
  /// were real draws, and each row already carries its own unit, so they stay
  /// readable without it.
  static Future<void> deleteLabMarkerDef(String key) async {
    final db = await instance;
    await db.delete('lab_marker_def', where: 'key = ?', whereArgs: [key]);
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
    int? avgHr,
    String? traceJson,
    int? traceSamples,
  }) async {
    final db = await instance;
    return db.update(
      'sessions',
      {
        'strain': strain,
        'calories': calories,
        'max_hr': maxHr,
        'zone_min_json': zoneMinJson,
        // Only when the re-score actually measured one. Writing null over a
        // previously-banked average because THIS pass found no substrate would
        // delete a real measurement.
        'avg_hr': ?avgHr,
        // Same rule for the frozen trace: only ever written when this pass
        // actually read a window. A pass that found no substrate must not wipe
        // the trace banked by an earlier one — the substrate is gone for good.
        'trace_json': ?traceJson,
        'trace_samples': ?traceSamples,
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
  /// How many FINISHED sessions exist, ever. Counted in SQL: the Workouts tab
  /// awaits this while it opens, and it used to pull every session row an
  /// install had ever written (full payload, sorted) back across the platform
  /// channel to add up one integer.
  static Future<int> finishedSessionCount() async {
    final db = await instance;
    final r = await db.rawQuery(
      "SELECT COUNT(*) c FROM sessions WHERE status IS NOT 'live'",
    );
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  /// TS-03 — the highest heart rate the band has ever OBSERVED on this user,
  /// and the local day it was held on. Null when no day ever produced one.
  ///
  /// Every value in the `hr_ceiling_bpm` series already passed the hold +
  /// corroborating-motion guard in analytics' `observed_max_hr.dart`. THE MAX
  /// MUST ONLY EVER BE TAKEN OVER THAT SERIES: a max over `sessions.max_hr`
  /// would be one PPG artifact away from dragging every zone boundary in the
  /// app up forever, with nothing on screen to say why.
  ///
  /// All-time, not a trailing window. This is "highest we've seen"; a ceiling
  /// that silently aged out of a window would move every zone edge with no
  /// visible cause. The date rides along so an old one is attributable.
  static Future<({double bpm, String date})?> observedHrCeiling() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT date, value FROM metric_series "
      "WHERE key = 'hr_ceiling_bpm' AND value IS NOT NULL "
      'ORDER BY value DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    final d = rows.first['date'], v = rows.first['value'];
    if (d is! String || v is! num) return null;
    return (bpm: v.toDouble(), date: d);
  }

  /// The `device_family` of the most recent session that carries one, or null.
  ///
  /// The zone ceiling is a per-family constant, so a screen that prints zone
  /// EDGES has to say which strap they belong to — and it has to be able to say
  /// it for a user who has not synced in a week (`decoded_onehz` is pruned at
  /// ~3 days; `sessions` is not). NULL is unknown and stays unknown: a
  /// pre-schema-41 session, an import and a raw replay all carry none, and an
  /// uncalibrated strap is never gen4 with a different badge.
  static Future<String?> latestSessionDeviceFamily() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT device_family FROM sessions "
      "WHERE device_family IS NOT NULL AND device_family <> '' "
      'ORDER BY start_ts DESC LIMIT 1',
    );
    return rows.isEmpty ? null : rows.first['device_family'] as String?;
  }

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
    // …and its frozen per-km splits (CV-01), same reason.
    await db.delete('workout_split', where: 'session_id = ?', whereArgs: [id]);
    // …and so do its typed sets. These used to survive the delete, so a
    // mistyped 200 kg set on a deleted workout kept coming back as "previous"
    // and "best" on the strength screen (recentSetsFor reads strength_set with
    // no session-existence filter) and kept exporting under a dead session_id.
    await db.delete('strength_set', where: 'session_id = ?', whereArgs: [id]);
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

  /// workout_split — per-KILOMETRE splits, frozen at finalize (CV-01 / TS-07).
  ///
  /// WHY A TABLE AND NOT A QUERY. A split's `avg_hr` is computed on demand by
  /// joining the route against `decoded_onehz`, which is gone at ~3 days. So
  /// there is NO retroactive index here and never can be: this write is the
  /// whole gate, it is FORWARD-ONLY, and it produces its first honest chart
  /// 8-12 weeks after it ships. Nothing reads this table yet.
  ///
  /// `net_elev_m` is the elevation change over the WHOLE kilometre, not a
  /// per-point sum. GPS altitude error is tens of metres pointwise and there is
  /// no barometer in this stack, so a 1 m-deadband ascent total would be mostly
  /// noise; the net over a km is the only elevation figure the fix supports.
  /// NULL when any point in the split carried no altitude — never 0, which
  /// would read as "flat".
  ///
  /// Kilometres only. The UI also renders miles, but that is a display unit for
  /// the same route; a second stored copy of the same run in different bins is
  /// not a second measurement.
  static Future<void> _createWorkoutSplit(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_split (
        session_id TEXT NOT NULL,
        km INTEGER NOT NULL,
        meters REAL NOT NULL,
        duration_sec INTEGER NOT NULL,
        avg_hr REAL,
        net_elev_m REAL,
        PRIMARY KEY (session_id, km)
      )
    ''');
  }

  /// Replace the stored splits for one session (empty list clears them).
  /// INSERT OR REPLACE on (session_id, km), so a later pass over a fuller
  /// window overwrites rather than duplicating.
  static Future<void> putWorkoutSplits(
    String sessionId,
    List<Map<String, Object?>> rows,
  ) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete(
        'workout_split',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      for (final r in rows) {
        await txn.insert('workout_split', {
          'session_id': sessionId,
          ...r,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// The stored splits for one session, in order. Empty when the session
  /// predates this table or had no route — never inferred.
  static Future<List<Map<String, dynamic>>> workoutSplits(
    String sessionId,
  ) async {
    final db = await instance;
    return db.query(
      'workout_split',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'km ASC',
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
      batch.insert(
        'workout_route',
        r,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// All route rows for a session, ordered by seq.
  static Future<List<Map<String, dynamic>>> routePoints(
    String sessionId,
  ) async {
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
  ///
  /// Admitted rows only ([derivableSourceSql]), for the same reason
  /// [sessionHrStats] states below: an unverified adapter writes its own
  /// seconds into this table with `source` set, and averaging the two together
  /// reports a session HR that is neither sensor's. Today nothing writes a
  /// non-null source, so this filter is a no-op — it is here so the six call
  /// sites are already correct on the day one does.
  static Future<List<Map<String, dynamic>>> hrSamplesInRange(
    int fromTs,
    int toTs,
  ) async {
    final db = await instance;
    return db.query(
      'decoded_onehz',
      columns: ['rec_ts', 'hr'],
      where:
          'rec_ts >= ? AND rec_ts <= ? AND hr > 0 AND ${derivableSourceSql()}',
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
      // Admitted rows only. An unverified adapter writes its own seconds into
      // this table with `source` set; averaging the two together would report a
      // session HR that is neither sensor's.
      '  AND ${derivableSourceSql('d.source')} '
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
      // Admitted rows only. An unverified adapter writes its own seconds into
      // this table with `source` set; averaging the two together would report a
      // session HR that is neither sensor's.
      '  AND ${derivableSourceSql('d.source')} '
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

  /// Mark a session private (or not). Its own narrow UPDATE for the same reason
  /// [setSessionType] is one: `putSession` is INSERT-OR-REPLACE over the whole
  /// row, so a re-score would revert a flag it never read.
  static Future<void> setSessionPrivate(String id, bool private) async {
    final db = await instance;
    await db.update(
      'sessions',
      {'private': private ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Set (or clear, with null) a session's self-reported RPE. Its own narrow
  /// UPDATE for the same reason [setSessionType] is one, and because the user's
  /// own word must survive every re-score.
  ///
  /// The caller must pass what the user actually chose. There is no default and
  /// no pre-selection: an unrated session stays NULL forever, which is the
  /// honest reading of "they skipped it".
  static Future<void> setSessionRpe(String id, double? rpe) async {
    final db = await instance;
    await db.update('sessions', {'rpe': rpe}, where: 'id = ?', whereArgs: [id]);
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
      // decoded_rr shares the rec_ts key, so a plain rec_ts range delete covers
      // every beat in the window — no counter subquery, no orphan sweep (there
      // are no counter-orphans once parent and child are keyed the same way).
      deleted += await txn.delete(
        'decoded_rr',
        where: 'rec_ts < ?',
        whereArgs: [cutoffSec],
      );
      deleted += await txn.delete(
        'decoded_onehz',
        where: 'rec_ts < ?',
        whereArgs: [cutoffSec],
      );
      deleted += await txn.delete(
        'samples',
        where: 'ts < ?',
        whereArgs: [cutoffSec],
      );
      deleted += await txn.delete(
        'events',
        where: 'ts < ?',
        whereArgs: [cutoffSec],
      );
      // band_events keeps its WEAR AND CHARGE TRANSITIONS forever; everything
      // else in it goes at the cutoff. `detectNaps` rejects bouts that overlap
      // an off-wrist or on-charger span, and those spans are built by
      // `_toggleSpans` out of exactly these four ids — so with them pruned at
      // 3 days, any re-derive of an older day ran the nap detector with BOTH
      // rejection lists empty and a charging session on the desk could score as
      // a nap. Nap history rewrote itself, quietly, just for being looked at.
      //
      // Same shape as the band_battery exemption below (a 3-day cap
      // structurally destroys a lifetime series), and the same size argument:
      // on the three real exports these four ids are 87, 22 and 12 rows across
      // 8 to 11 days — a few thousand a year. Event 33 alone is ~1900 A DAY,
      // which is why the exemption is four ids and not the whole table.
      deleted += await txn.delete(
        'band_events',
        where: 'ts < ? AND event_id NOT IN (?, ?, ?, ?)',
        whereArgs: [
          cutoffSec,
          proto.EventId.chargingOn,
          proto.EventId.chargingOff,
          proto.EventId.wristOn,
          proto.EventId.wristOff,
        ],
      );
      // THE UNDECODABLE ARCHIVE IS THINNED, NOT KEPT WHOLE. See
      // [thinRawArchiveBefore] — this is the only caller, so the archive is
      // capped by the same retention pass that caps the substrate.
      deleted += await _thinRawArchiveVia(txn, cutoffSec * 1000);
      // band_battery is NOT pruned here. It was, at the 3-day substrate cutoff,
      // which structurally capped the battery-health series at 3 days — while
      // batteryHealth() reports `charge_cycles` (rising 0→1 charging edges) and
      // `full_charge_mv` (rolling max mV while charging), both of which only
      // mean anything across the life of the pack. A year-old band would have
      // reported 1 cycle. Six narrow columns a few minutes apart is not a
      // storage problem; the 1 Hz substrate is.
      // ponytail: unbounded, so give it its own multi-year cutoff if a real
      // install's table ever shows up big.
    });
    return deleted;
  }

  /// Bytes SQLite is holding in the free page list — deleted, reusable, and
  /// invisible to the user, who sees only the file size.
  static Future<int> freelistBytes() async {
    final db = await instance;
    final free =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA freelist_count')) ?? 0;
    final pageSize =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA page_size')) ?? 4096;
    return free * pageSize;
  }

  /// Return free pages to the FILESYSTEM when there are enough of them to be
  /// worth a full rewrite. Returns the bytes reclaimed, or 0 if it declined.
  ///
  /// A delete only moves pages to the freelist; the file never shrinks below
  /// its all-time high-water mark. That is normally fine — the freelist is
  /// reused by the next day's ingest, so steady state is bounded — but two
  /// things put a permanent step in the mark: an install that let the substrate
  /// backlog build before the retention prune ran on every derive, and the v39
  /// migrations, each of which builds a full shadow copy of `decoded_onehz`
  /// before dropping the original. A 170 MB file stays 170 MB forever.
  ///
  /// WHY A FULL `VACUUM` AND NOT `auto_vacuum`:
  ///   * `auto_vacuum` cannot be turned on for an existing database without a
  ///     full `VACUUM` anyway, so it does not avoid this cost — it adds to it.
  ///   * `auto_vacuum=FULL` moves pages on EVERY commit, on a store taking
  ///     ~86 400 inserts a day. `INCREMENTAL` is cheaper but still adds
  ///     pointer-map pages to every write.
  ///   * Both would tax the hottest write path in the app, forever, to fix
  ///     something that happens once.
  ///
  /// A full `VACUUM` rewrites the whole file under an exclusive lock and needs
  /// roughly twice the file size free on disk, so it must NEVER run on the
  /// sync/ACK path, during a live session, or in the background. That gating is
  /// the caller's job — see `AppState._maybeReclaimDiskSpace`, which runs it
  /// only on a foreground heavy derive with nothing else in flight.
  static Future<int> vacuumIfBloated({int minFreeBytes = 64 << 20}) async {
    final free = await freelistBytes();
    if (free < minFreeBytes) return 0;
    final db = await instance;
    await db.execute('VACUUM');
    // VACUUM rewrites the file and renumbers every btree root page. CoachDb
    // caches the root pages of its allow-listed views to decide what a coach
    // query is allowed to touch, and nothing else calls CoachDb.close() — so
    // after this ran, every valid coach query started failing its own guard
    // ("Query reaches storage outside the coach views") for the rest of the
    // process. The invariant belongs to whoever moves the pages.
    await CoachDb.close();
    return free;
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
  static Future<int> pruneSupersededIntermediates({
    int keepVersions = 2,
  }) async {
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
        // [kPrimaryBandSourceSql], NOT [derivableSourceSql]: the data edge is
        // the BAND's edge. A peripheral sensor's second is not evidence the
        // strap synced, and letting it move this would tell the sync engine it
        // made progress it did not make.
        //
        // ponytail: the derive engine reads this as "now, in data time" (its
        // finalization anchor, and `dataNowSec <= 0` short-circuits the whole
        // pass), which is a DIFFERENT question — an install with a verified
        // strap and no band would derive nothing. The upgrade is a sibling
        // `lastAdmittedRecTs()` on [derivableSourceSql] for the derive callers,
        // added when a second admitted source actually exists; splitting it now
        // would be two names for one query.
        'SELECT MAX(rec_ts) FROM decoded_onehz '
        'WHERE rec_ts > 0 AND $kPrimaryBandSourceSql',
      ),
    );
  }
}

/// One batch of curve re-encodes: for each input bundle, the compacted
/// replacement, or null when the row must be left exactly as it is.
///
/// TOP-LEVEL and pure so it can be handed to `Isolate.run` — it touches nothing
/// but `SeriesCodec`, which has no I/O, no plugins and no Flutter. The null
/// cases are all "leave it legacy": already encoded, not provably lossless
/// (see `verifyLossless` — this OVERWRITES durable user data, and a day past
/// `rawRetentionDays` has no substrate left to re-derive from), or an encode
/// that did not actually shrink the row.
List<String?> _reencodeBatch(List<String> payloads) {
  final out = <String?>[];
  for (final pj in payloads) {
    if (pj.isEmpty ||
        !SeriesCodec.needsReencode(pj) ||
        !SeriesCodec.verifyLossless(pj)) {
      out.add(null);
      continue;
    }
    final encoded = SeriesCodec.encodePayloadJson(pj);
    out.add(encoded.length < pj.length ? encoded : null);
  }
  return out;
}
