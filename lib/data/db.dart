// Local raw-first storage (SQLite via sqflite).
//
// Two tables:
//   raw_records  — the band's bytes verbatim, keyed by counter. Source of truth.
//   samples      — decoded telemetry, keyed by counter. Idempotent on counter.
//
// `counter` (u32 @[3:7]) is the band's per-record id and our natural idempotency
// key — re-draining the same flash region inserts nothing new (INSERT OR IGNORE).

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

  static Future<Database> get instance async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'openstrap.db');
    return openDatabase(
      path,
      onCreate: (db, version) async {
        await _createRaw(db);
        await _createSamples(db);
        await db.execute('CREATE INDEX idx_samples_ts ON samples(ts)');
        await _createEvents(db);
        await _createDerived(db);
        await _createDayResult(db);
        await _createUserTables(db);
        await _createSyncCursor(db);
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
          await db.execute('CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts)');
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
              'CREATE INDEX IF NOT EXISTS idx_raw_rects ON raw_records(rec_ts)');
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
          } catch (_) {/* derived_day may be absent — fine, raw rebuilds it */}
        }
        if (oldV < 10) {
          // RESUMABLE SYNC. Durable key→value cursor store so the historical
          // offload survives app restarts / disconnects: we persist the strap's
          // continuation token + counter/rec_ts high-water BEFORE ACKing a
          // HISTORY_END (the safe-trim invariant), and reconnect detectors read
          // it to tell a stalled cursor from a healthy one. Additive.
          await _createSyncCursor(db);
        }
        if (oldV < 11) {
          // Live workout steps (Tier-A pedometer over the session's 100 Hz
          // R10 accel). Additive nullable column — old rows read null.
          await db.execute('ALTER TABLE sessions ADD COLUMN steps INTEGER');
        }
      },
      version: 11,
    );
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

  /// Read a sync-cursor value (null if unset).
  static Future<String?> getCursor(String name) async {
    final db = await instance;
    final rows = await db.query('sync_cursor',
        columns: ['value'], where: 'name = ?', whereArgs: [name], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  static Future<int?> getCursorInt(String name) async {
    final v = await getCursor(name);
    return v == null ? null : int.tryParse(v);
  }

  /// Read a cursor int through a specific executor (used inside a transaction so
  /// the read shares the open txn instead of contending on the global handle).
  static Future<int?> _cursorIntVia(DatabaseExecutor ex, String name) async {
    final rows = await ex.query('sync_cursor',
        columns: ['value'], where: 'name = ?', whereArgs: [name], limit: 1);
    if (rows.isEmpty) return null;
    return int.tryParse(rows.first['value'] as String? ?? '');
  }

  /// Upsert a sync-cursor value. Caller may pass a [txn] so the cursor write
  /// shares the SAME transaction as the raw batch — keeping "persist raw then
  /// persist cursor" atomic before the band is ACKed.
  static Future<void> setCursor(String name, String value,
      {DatabaseExecutor? txn}) async {
    final ex = txn ?? await instance;
    await ex.insert(
      'sync_cursor',
      {
        'name': name,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
        batch.insert(
          'raw_records',
          {
            'hex': raw.hex,
            'packet_type': raw.packetType,
            'counter': raw.counter,
            'captured_at': raw.capturedAt,
            'rec_ts': recTs,
            'uploaded': raw.uploaded ? 1 : 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final sample = samples[i];
        if (sample != null) {
          batch.insert(
            'samples',
            {'counter': raw.counter, ...sample.toDbMap()},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
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
        'CREATE INDEX IF NOT EXISTS idx_metric_series_key ON metric_series(key, date)');
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
        'CREATE INDEX IF NOT EXISTS idx_day_result_day ON day_result(day_id, algo_version)');
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
        source TEXT NOT NULL DEFAULT 'manual',
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

  // samples — header-only record index (counter, ts, hr). The band is a raw pipe;
  // sensors are decoded in the cloud from the uploaded raw hex, never on-device.
  static Future<void> _createSamples(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS samples (
        counter INTEGER PRIMARY KEY,
        ts INTEGER NOT NULL,
        hr INTEGER
      )
    ''');
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
        'CREATE INDEX IF NOT EXISTS idx_raw_unuploaded ON raw_records(uploaded, captured_at) WHERE uploaded = 0');
    // rec_ts is the bucketing/window key for the DerivationEngine.
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_raw_rects ON raw_records(rec_ts)');
  }

  /// Add the additive `rec_ts` column to an EXISTING raw_records table (upgrade
  /// path only). NOT NULL with a DEFAULT 0 so legacy rows are well-formed until
  /// the backfill rewrites them.
  static Future<void> _addRecTsColumn(Database db) async {
    await db.execute(
        'ALTER TABLE raw_records ADD COLUMN rec_ts INTEGER NOT NULL DEFAULT 0');
  }

  /// Backfill `rec_ts` for every existing raw row by decoding its hex once. Runs
  /// inside the migration on a populated DB. Falls back to captured_at/1000 when a
  /// frame is undecodable or yields a non-positive ts — rec_ts is never left at 0.
  static Future<void> _backfillRecTs(Database db) async {
    final rows = await db.query('raw_records',
        columns: ['hex', 'captured_at'], where: 'rec_ts = 0 OR rec_ts IS NULL');
    if (rows.isEmpty) return;
    final batch = db.batch();
    for (final r in rows) {
      final hex = r['hex'] as String;
      final capturedSec = ((r['captured_at'] as int?) ?? 0) ~/ 1000;
      final ts = decodeRecTs(hex, fallbackSec: capturedSec);
      batch.update('raw_records', {'rec_ts': ts},
          where: 'hex = ?', whereArgs: [hex]);
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
    } catch (_) {/* fall through */}
    // RR-bearing live frames (0x28) as a secondary path.
    try {
      final rr = proto.realtimeRr(hex);
      if (rr != null && rr.ts > 0) return rr.ts;
    } catch (_) {/* fall through */}
    return fallbackSec;
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

  static Future<void> insertEvent(int eventId, int ts, String hex) async {
    final db = await instance;
    await db.insert(
      'events',
      {
        'hex': hex,
        'event_id': eventId,
        'ts': ts,
        'captured_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<List<Map<String, dynamic>>> unuploadedEvents({int limit = 500}) async {
    final db = await instance;
    return db.query('events', orderBy: 'ts ASC', limit: limit);
  }

  static Future<void> deleteEvents(List<String> hexes) async {
    if (hexes.isEmpty) return;
    final db = await instance;
    final placeholders = List.filled(hexes.length, '?').join(',');
    await db.rawDelete('DELETE FROM events WHERE hex IN ($placeholders)', hexes);
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
      rawRows = await txn.insert(
        'raw_records',
        {
          'hex': raw.hex,
          'packet_type': raw.packetType,
          'counter': raw.counter,
          'captured_at': raw.capturedAt,
          'rec_ts': _recTsFor(raw),
          'uploaded': raw.uploaded ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (sample != null) {
        await txn.insert(
          'samples',
          {'counter': raw.counter, ...sample.toDbMap()},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
    return rawRows != 0;
  }

  /// Insert many records in ONE transaction. During a historical drain this is far
  /// faster than a transaction-per-record (one fsync instead of thousands). `raws`
  /// and `samples` are parallel lists; a null sample means raw-only (live/no decode).
  /// Raw-first is preserved — callers flush this before ACKing a sync batch.
  static Future<void> insertRecordsBatch(
      List<RawRecord> raws, List<Sample?> samples) async {
    if (raws.isEmpty) return;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < raws.length; i++) {
        final raw = raws[i];
        batch.insert(
          'raw_records',
          {
            'hex': raw.hex,
            'packet_type': raw.packetType,
            'counter': raw.counter,
            'captured_at': raw.capturedAt,
            'rec_ts': _recTsFor(raw),
            'uploaded': raw.uploaded ? 1 : 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final sample = samples[i];
        if (sample != null) {
          batch.insert(
            'samples',
            {'counter': raw.counter, ...sample.toDbMap()},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<List<RawRecord>> unuploadedRaw({int limit = 500}) async {
    final db = await instance;
    final rows = await db.query('raw_records',
        where: 'uploaded = 0', orderBy: 'captured_at ASC', limit: limit);
    return rows
        .map((m) => RawRecord(
              counter: (m['counter'] as int?) ?? 0,
              packetType: (m['packet_type'] as int?) ?? 0,
              hex: m['hex'] as String,
              capturedAt: m['captured_at'] as int,
              recTs: (m['rec_ts'] as int?),
              uploaded: false,
            ))
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
        'DELETE FROM raw_records WHERE hex IN ($placeholders)', hexes);
  }

  static Future<List<Sample>> samplesInRange(int fromTs, int toTs) async {
    final db = await instance;
    final rows = await db.query('samples',
        where: 'ts >= ? AND ts <= ?', whereArgs: [fromTs, toTs], orderBy: 'ts ASC');
    return rows.map(Sample.fromDbMap).toList();
  }

  static Future<Sample?> latestSample() async {
    final db = await instance;
    final rows = await db.query('samples', orderBy: 'ts DESC', limit: 1);
    return rows.isEmpty ? null : Sample.fromDbMap(rows.first);
  }

  static Future<Map<String, int>> counts() async {
    final db = await instance;
    final raw = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM raw_records')) ??
        0;
    final pending = Sqflite.firstIntValue(await db
            .rawQuery('SELECT COUNT(*) FROM raw_records WHERE uploaded = 0')) ??
        0;
    return {'raw': raw, 'pending': pending};
  }

  // ── raw read (for the DerivationEngine — main isolate only) ─────────────────

  /// All raw record hexes captured in [fromMs, toMs] (epoch ms = captured_at),
  /// oldest first. The engine decodes these via openstrap_protocol off-isolate.
  static Future<List<String>> rawHexInCaptureRange(int fromMs, int toMs) async {
    final db = await instance;
    final rows = await db.query('raw_records',
        columns: ['hex'],
        where: 'captured_at >= ? AND captured_at <= ?',
        whereArgs: [fromMs, toMs],
        orderBy: 'captured_at ASC');
    return rows.map((m) => m['hex'] as String).toList();
  }

  /// All raw record hexes whose REAL record time (`rec_ts`, epoch SECONDS) is in
  /// [fromSec, toSec], oldest first. This is the day-window read the engine uses so
  /// a backfill is split by real day, not by when it was received (captured_at).
  static Future<List<String>> rawHexInRecTsRange(int fromSec, int toSec) async {
    final db = await instance;
    final rows = await db.query('raw_records',
        columns: ['hex'],
        where: 'rec_ts >= ? AND rec_ts <= ?',
        whereArgs: [fromSec, toSec],
        orderBy: 'rec_ts ASC');
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
        await db.rawQuery('SELECT MAX(captured_at) FROM raw_records'));
  }

  /// The oldest `captured_at` (epoch ms) across all raw. Null if empty.
  static Future<int?> earliestRawCapturedAt() async {
    final db = await instance;
    return Sqflite.firstIntValue(
        await db.rawQuery('SELECT MIN(captured_at) FROM raw_records'));
  }

  /// ALL retained raw record hexes, ordered by REAL record time (rec_ts). The
  /// engine decodes these ONCE into a single continuous Substrate (substrate.dart).
  static Future<List<String>> allRawHexByRecTs() async {
    final db = await instance;
    final rows = await db.query('raw_records',
        columns: ['hex'], orderBy: 'rec_ts ASC');
    return rows.map((m) => m['hex'] as String).toList();
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
      await txn.insert(
        'day_result',
        {
          'day_id': dayId,
          'algo_version': algoVersion,
          'payload_json': payloadJson,
          'window_json': windowJson,
          'computed_at': now,
          'finalized': finalized ? 1 : 0,
          'rhr': rhr,
          'rmssd': rmssd,
          'readiness': readiness,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final e in series.entries) {
        await txn.insert(
          'metric_series',
          {'date': dayId, 'key': e.key, 'value': e.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// The latest-version result row for one day_id (highest algo_version), with a
  /// normalized `date` alias for callers. Null if absent.
  static Future<Map<String, dynamic>?> dayResult(String dayId) async {
    final db = await instance;
    final rows = await db.query('day_result',
        where: 'day_id = ?',
        whereArgs: [dayId],
        orderBy: 'algo_version DESC',
        limit: 1);
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
    final rows = await db.query('day_result',
        columns: ['day_id'], where: 'algo_version = ?', whereArgs: [algoVersion]);
    return {for (final r in rows) r['day_id'] as String};
  }

  /// The set of day_id labels that are FINALIZED at [algoVersion] (locked). A
  /// finalized day is never recomputed even on a version bump.
  static Future<Set<String>> finalizedDayIds(int algoVersion) async {
    final db = await instance;
    final rows = await db.query('day_result',
        columns: ['day_id'],
        where: 'algo_version = ? AND finalized = 1',
        whereArgs: [algoVersion]);
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
                if (cols.contains(e.key)) e.key: e.value
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
    final count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM raw_records')) ??
        0;
    final tsRow = (await db.rawQuery(
            'SELECT MIN(rec_ts) AS lo, MAX(rec_ts) AS hi FROM raw_records WHERE rec_ts > 0'))
        .first;
    final capRow = (await db.rawQuery(
            'SELECT MIN(captured_at) AS lo, MAX(captured_at) AS hi FROM raw_records'))
        .first;
    final typeRows = await db.rawQuery(
        'SELECT packet_type AS t, COUNT(*) AS n FROM raw_records GROUP BY packet_type');
    final byType = <String, int>{};
    for (final r in typeRows) {
      byType['${(r['t'] as int?) ?? -1}'] = (r['n'] as int?) ?? 0;
    }
    return {
      'count': count,
      'min_rec_ts': (tsRow['lo'] as num?)?.toInt(),
      'max_rec_ts': (tsRow['hi'] as num?)?.toInt(),
      'by_type': byType,
      'min_captured_ms': (capRow['lo'] as num?)?.toInt(),
      'max_captured_ms': (capRow['hi'] as num?)?.toInt(),
    };
  }

  /// Derived store summary: distinct days, how many are skipped markers (latest
  /// version), the latest day label, and the most recent (up to 14) day labels.
  static Future<Map<String, dynamic>> derivedStats() async {
    final db = await instance;
    final count = Sqflite.firstIntValue(await db
            .rawQuery('SELECT COUNT(DISTINCT day_id) FROM day_result')) ??
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

  /// A long-format metric series (oldest first) for trends/sparklines.
  static Future<List<Map<String, dynamic>>> metricSeries(String key,
      {int? limit}) async {
    final db = await instance;
    return db.query('metric_series',
        where: 'key = ? AND value IS NOT NULL',
        whereArgs: [key],
        orderBy: 'date ASC',
        limit: limit);
  }

  static Future<Map<String, dynamic>?> baseline(String key) async {
    final db = await instance;
    final rows =
        await db.query('baselines', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> putBaseline(String key, String payloadJson) async {
    final db = await instance;
    await db.insert(
      'baselines',
      {
        'key': key,
        'payload_json': payloadJson,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── step-cadence calibration (baselines key `step_cadence`) ─────────────────
  // The personal cadence model the live 100 Hz pedometer learns and the 1 Hz
  // daily step ESTIMATE consumes (see analytics steps.dart). Stored as the
  // StepCalibration JSON so live walking steadily tunes the 24/7 estimate.

  /// The persisted personal cadence model, or null if never calibrated.
  static Future<ana.StepCalibration?> getStepCalibration() async {
    final row = await baseline('step_cadence');
    final json = row?['payload_json'];
    if (json is! String) return null;
    try {
      final m = jsonDecode(json);
      return m is Map
          ? ana.StepCalibration.fromJson(m.cast<String, dynamic>())
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Persist the personal cadence model (overwrites — it's a running estimate).
  static Future<void> putStepCalibration(ana.StepCalibration c) =>
      putBaseline('step_cadence', jsonEncode(c.toJson()));

  // ── journal I/O ─────────────────────────────────────────────────────────────

  /// Upsert one day's journal (tags JSON + note). Idempotent on date.
  static Future<void> putJournal(String date, String tagsJson, String note) async {
    final db = await instance;
    await db.insert(
      'journal',
      {
        'date': date,
        'tags_json': tagsJson,
        'note': note,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Recent journal rows, newest first. [sinceDaysEpoch] (a YYYY-MM-DD label) is
  /// an optional inclusive lower bound on `date`.
  static Future<List<Map<String, dynamic>>> journalRows({String? sinceDaysEpoch}) async {
    final db = await instance;
    if (sinceDaysEpoch != null) {
      return db.query('journal',
          where: 'date >= ?', whereArgs: [sinceDaysEpoch], orderBy: 'date DESC');
    }
    return db.query('journal', orderBy: 'date DESC');
  }

  // ── cycle log I/O ─────────────────────────────────────────────────────────────

  static Future<void> putCycleLog(String date, String kind, {String? note}) async {
    final db = await instance;
    await db.insert(
      'cycle_log',
      {'date': date, 'kind': kind, 'note': note},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    await db.insert('sessions', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, dynamic>?> session(String id) async {
    final db = await instance;
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Sessions whose `start_ts` (epoch SECONDS) is in [fromTs, toTs], newest first.
  static Future<List<Map<String, dynamic>>> sessionsInRange(int fromTs, int toTs) async {
    final db = await instance;
    return db.query('sessions',
        where: 'start_ts >= ? AND start_ts <= ?',
        whereArgs: [fromTs, toTs],
        orderBy: 'start_ts DESC');
  }

  static Future<void> deleteSession(String id) async {
    final db = await instance;
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> setSessionType(String id, String type) async {
    final db = await instance;
    await db.update('sessions', {'type': type}, where: 'id = ?', whereArgs: [id]);
  }

  // ── notifications I/O ─────────────────────────────────────────────────────────

  /// Insert a notification (INSERT OR IGNORE — idempotent by id, so the
  /// generator can re-run every derivation pass without duplicating).
  static Future<void> putNotification(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert('notifications', row, conflictAlgorithm: ConflictAlgorithm.ignore);
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
        'UPDATE notifications SET read = 1 WHERE id IN ($placeholders)', ids);
  }

  static Future<int> unreadCount() async {
    final db = await instance;
    return Sqflite.firstIntValue(await db
            .rawQuery('SELECT COUNT(*) FROM notifications WHERE read = 0')) ??
        0;
  }

  // ── raw pruning (raw-first invariant) ───────────────────────────────────────

  /// Delete raw_records / samples / events whose RECORD TIME (epoch seconds) is
  /// strictly before [cutoffSec]. Keyed on record time (`rec_ts`/`ts`), NOT
  /// receive time (`captured_at`): retention tracks the DATA, so a multi-day
  /// flash backfill drained in a single sync is never pruned merely for having
  /// just landed. The caller only prunes windows that are FULLY DERIVED — never
  /// prune raw for a day that hasn't been derived yet. Returns rows deleted.
  static Future<int> pruneRawBeforeRecTs(int cutoffSec) async {
    final db = await instance;
    int deleted = 0;
    await db.transaction((txn) async {
      deleted = await txn
          .delete('raw_records', where: 'rec_ts < ?', whereArgs: [cutoffSec]);
      await txn.delete('samples', where: 'ts < ?', whereArgs: [cutoffSec]);
      await txn.delete('events', where: 'ts < ?', whereArgs: [cutoffSec]);
    });
    return deleted;
  }

  /// The DATA EDGE — the timestamp (epoch seconds) of the last record we've
  /// actually drained. This, not the wall clock, is "the latest data we have":
  /// the band buffers in flash and drains on sync, so this can lag wall-clock
  /// time by hours/days. Null when there's no raw yet.
  static Future<int?> lastRawRecTs() async {
    final db = await instance;
    return Sqflite.firstIntValue(await db.rawQuery(
        'SELECT MAX(rec_ts) FROM raw_records WHERE rec_ts > 0'));
  }
}
