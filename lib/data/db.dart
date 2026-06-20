// Local raw-first storage (SQLite via sqflite).
//
// Two tables:
//   raw_records  — the band's bytes verbatim, keyed by counter. Source of truth.
//   samples      — decoded telemetry, keyed by counter. Idempotent on counter.
//
// `counter` (u32 @[3:7]) is the band's per-record id and our natural idempotency
// key — re-draining the same flash region inserts nothing new (INSERT OR IGNORE).

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
      },
      version: 4,
    );
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
        uploaded INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_raw_unuploaded ON raw_records(uploaded, captured_at) WHERE uploaded = 0');
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
}
