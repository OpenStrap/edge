// Local raw-first storage (SQLite via sqflite).
//
// Two tables:
//   raw_records  — the band's bytes verbatim, keyed by counter. Source of truth.
//   samples      — decoded telemetry, keyed by counter. Idempotent on counter.
//
// `counter` (u32 @[3:7]) is the band's per-record id and our natural idempotency
// key — re-draining the same flash region inserts nothing new (INSERT OR IGNORE).

import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:path/path.dart' as p;
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
        await _createUserTables(db);
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
      },
      version: 7,
    );
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

  // raw_records — keyed by the full frame hex (unique; dedupes identical
  // historical re-drains AND coexists with counter-less live packets).
  static Future<void> _createRaw(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raw_records (
        hex TEXT PRIMARY KEY,
        packet_type INTEGER,
        counter INTEGER,
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

  // ── derived store I/O (main isolate only — sqflite isn't isolate-safe) ──────

  /// Upsert a derived-day bundle + its indexed scalars in one transaction.
  static Future<void> putDerivedDay({
    required String date,
    required String payloadJson,
    required int version,
    required int lastRawTs,
    double? rhr,
    double? rmssd,
    double? readiness,
    Map<String, double?> series = const {},
  }) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.insert(
        'derived_day',
        {
          'date': date,
          'payload_json': payloadJson,
          'version': version,
          'last_raw_ts': lastRawTs,
          'computed_at': now,
          'rhr': rhr,
          'rmssd': rmssd,
          'readiness': readiness,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final e in series.entries) {
        await txn.insert(
          'metric_series',
          {'date': date, 'key': e.key, 'value': e.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// The full derived row for one day (or null). Columns + decoded payload_json.
  static Future<Map<String, dynamic>?> derivedDay(String date) async {
    final db = await instance;
    final rows =
        await db.query('derived_day', where: 'date = ?', whereArgs: [date], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// The most recent derived row (highest date label), or null.
  static Future<Map<String, dynamic>?> latestDerivedDay() async {
    final db = await instance;
    final rows = await db.query('derived_day', orderBy: 'date DESC', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Derived rows whose `date` is in [from, to] (inclusive string labels),
  /// newest first.
  static Future<List<Map<String, dynamic>>> derivedDaysBetween(
      String from, String to) async {
    final db = await instance;
    return db.query('derived_day',
        where: 'date >= ? AND date <= ?', whereArgs: [from, to], orderBy: 'date DESC');
  }

  /// The N most recent derived rows, newest first.
  static Future<List<Map<String, dynamic>>> recentDerivedDays(int limit) async {
    final db = await instance;
    return db.query('derived_day', orderBy: 'date DESC', limit: limit);
  }

  /// `{date -> last_raw_ts}` for every derived day — the engine compares these
  /// against the raw it has to decide which days need (re)derivation.
  static Future<Map<String, int>> derivedLastRawTs() async {
    final db = await instance;
    final rows = await db.query('derived_day', columns: ['date', 'last_raw_ts']);
    return {for (final r in rows) r['date'] as String: r['last_raw_ts'] as int};
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

  /// Delete raw_records / samples / events captured strictly before [cutoffMs].
  /// The caller is responsible for only pruning windows that are FULLY DERIVED —
  /// never prune raw for a day that hasn't been derived yet. Returns rows deleted.
  static Future<int> pruneRawBefore(int cutoffMs) async {
    final db = await instance;
    int deleted = 0;
    await db.transaction((txn) async {
      deleted = await txn
          .delete('raw_records', where: 'captured_at < ?', whereArgs: [cutoffMs]);
      // samples is keyed by counter with its own ts (epoch seconds); prune in
      // step using the same cutoff converted to seconds.
      await txn.delete('samples', where: 'ts < ?', whereArgs: [cutoffMs ~/ 1000]);
      await txn.delete('events', where: 'captured_at < ?', whereArgs: [cutoffMs]);
    });
    return deleted;
  }
}
