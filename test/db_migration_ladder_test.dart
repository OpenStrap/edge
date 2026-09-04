// END-TO-END migration-ladder regressions, run against the REAL LocalDb over
// sqflite_ffi. Each test hand-builds a database at an OLD schema version, then
// opens it through LocalDb so sqflite runs the whole onUpgrade ladder.
//
// Why this file exists: `onUpgrade` runs inside ONE exclusive transaction, so a
// single throwing step rolls the whole ladder back and `openDatabase` rethrows.
// The app then has NO recoverable state — it is stuck on the loading screen on
// every launch, permanently. Two steps used a bare `ALTER TABLE … ADD COLUMN`
// against a table that a LATER-numbered `_create*` helper had already created
// with the CURRENT (column-bearing) DDL:
//
//   oldV <= 2 : step 3 re-creates raw_records WITH rec_ts, step 6 re-adds it.
//   oldV <= 6 : step 7 creates sessions WITH steps,        step 11 re-adds it.
//
// Plus the legacy-table migrations (sync_cursor / sync_ledger / sync_quarantine)
// which renamed → created → copied → dropped OUTSIDE any transaction, so a crash
// mid-copy orphaned `<table>_legacy` forever and silently lost the resumable-sync
// cursor (strap_trim / counter_hw / rec_ts_hw).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The pre-v3 raw_records shape: keyed by frame hex, NO rec_ts column.
const _legacyRawDdl = '''
  CREATE TABLE raw_records (
    hex TEXT PRIMARY KEY,
    counter INTEGER,
    packet_type INTEGER,
    captured_at INTEGER NOT NULL,
    uploaded INTEGER NOT NULL DEFAULT 0
  )
''';

/// The v6-era raw_records shape: hex PK, rec_ts already present.
const _v6RawDdl = '''
  CREATE TABLE raw_records (
    hex TEXT PRIMARY KEY,
    counter INTEGER,
    packet_type INTEGER,
    captured_at INTEGER NOT NULL,
    rec_ts INTEGER NOT NULL DEFAULT 0,
    uploaded INTEGER NOT NULL DEFAULT 0
  )
''';

/// The origin/main (pre-v33) COUNTER-keyed decoded store, exactly as a user who
/// installed at v19..31 has it — and by then raw_records is already DROPPED, so
/// the v33 rekey is the ONLY copy of their 1 Hz data (no raw-backfill safety
/// net). This is the highest-risk path the re-key touches.
const _counterKeyedDecodedDdl = [
  '''
  CREATE TABLE decoded_onehz (
    counter INTEGER PRIMARY KEY, rec_ts INTEGER NOT NULL,
    hr INTEGER NOT NULL, ax REAL NOT NULL, ay REAL NOT NULL, az REAL NOT NULL,
    spo2_red_raw INTEGER NOT NULL, spo2_ir_raw INTEGER NOT NULL,
    skin_temp_raw INTEGER NOT NULL)
''',
  'CREATE UNIQUE INDEX idx_decoded_onehz_rec_ts_unique ON decoded_onehz(rec_ts)',
  '''
  CREATE TABLE decoded_rr (
    counter INTEGER NOT NULL, beat_index INTEGER NOT NULL,
    rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
    PRIMARY KEY (counter, beat_index))
''',
  'CREATE UNIQUE INDEX idx_decoded_rr_ts_beat_unique '
      'ON decoded_rr(rr_ts_ms, beat_index)',
];

/// The PRE-v47 decoded store, exactly as a user on v43..46 has it: `rec_ts` is
/// the whole primary key of `decoded_onehz`, `decoded_rr` hangs off it by
/// `(rec_ts, beat_index)`, and `samples` is keyed by the band's flash counter.
/// This is the shape the device re-key rebuilds, and the one every 3-day
/// retention window of real 1 Hz data sits in.
const _preDeviceKeyDecodedDdl = [
  '''
  CREATE TABLE decoded_onehz (
    rec_ts INTEGER PRIMARY KEY,
    counter INTEGER NOT NULL,
    hr INTEGER, ax REAL, ay REAL, az REAL,
    spo2_red_raw INTEGER, spo2_ir_raw INTEGER, skin_temp_raw INTEGER,
    device_family TEXT, source TEXT, ts_subsec INTEGER)
''',
  '''
  CREATE TABLE decoded_rr (
    rec_ts INTEGER NOT NULL, beat_index INTEGER NOT NULL,
    rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
    device_family TEXT, source TEXT, beat_ts_ms INTEGER,
    PRIMARY KEY (rec_ts, beat_index))
''',
  '''
  CREATE TABLE samples (
    counter INTEGER PRIMARY KEY, ts INTEGER NOT NULL, hr INTEGER)
''',
];

/// The PRE-v49 `live_coverage`, exactly as a user on v27..48 has it: `source`
/// says band-or-phone and NOTHING says WHICH band, which is why two straps on
/// one walk could both be credited in full.
const _preDeviceLiveCoverageDdl = '''
  CREATE TABLE live_coverage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    start_ts INTEGER NOT NULL,
    end_ts INTEGER NOT NULL,
    steps INTEGER NOT NULL,
    day TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'band')
''';

/// The v5-era derived tables, so step 9's derived_day → day_result copy is real.
const _v5DerivedDdl = [
  '''
  CREATE TABLE derived_day (
    date TEXT PRIMARY KEY,
    payload_json TEXT NOT NULL,
    version INTEGER NOT NULL,
    last_raw_ts INTEGER NOT NULL,
    computed_at INTEGER NOT NULL,
    rhr REAL, rmssd REAL, readiness REAL
  )
''',
  '''
  CREATE TABLE baselines (
    key TEXT PRIMARY KEY,
    payload_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
  )
''',
  '''
  CREATE TABLE metric_series (
    date TEXT NOT NULL, key TEXT NOT NULL, value REAL,
    PRIMARY KEY (date, key)
  )
''',
];

/// One REAL 89-byte gen4 v24 historical record, hex-encoded — the shape
/// `_backfillDecodedStore` replays out of `raw_records` at ladder step 19.
///
/// The old seed here was `deadbeef`, which decodes to nothing, so the backfill
/// queued zero writes and the step-19 brick never fired in the test.
String _v24RecordHex({
  required int counter,
  required int tsEpoch,
  required int hr,
  int rrMs = 850,
}) {
  final b = Uint8List(89);
  final v = ByteData.view(b.buffer);
  b[0] = 0x2f; // historical data
  b[1] = 24; // v24 field map (trusted — no plausibility gate)
  v.setUint32(3, counter, Endian.little);
  v.setUint32(7, tsEpoch, Endian.little);
  b[17] = hr;
  b[18] = 1; // rr_count
  v.setInt16(19, rrMs, Endian.little);
  // accel float32s at 36/40/44 stay 0.0 — finite, which is all v24 requires.
  return [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
}

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// Build a database file at [version] with [ddl] applied, then close it.
Future<void> _seedOldDb(
  String name,
  int version,
  List<String> ddl, {
  Future<void> Function(Database db)? seedRows,
}) async {
  final path = await _dbPath(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        for (final s in ddl) {
          await db.execute(s);
        }
      },
    ),
  );
  if (seedRows != null) await seedRows(db);
  await db.close();
}

/// Open [name] through LocalDb (running the real ladder) and hand back the
/// resulting user_version.
Future<int> _openThroughLocalDb(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  final db = await LocalDb.instance;
  // THE LADDER, not the safety net. A step that throws rolls the whole
  // exclusive transaction back and `_openOrRebuild` quarantines the file and
  // starts a fresh one — which still ends up at the current schema version, so
  // every `expect(version, schemaVersion)` below passes either way. Without
  // this, a test in here can go green on the recovery path for a bricked rung.
  expect(LocalDb.lastRebuild, isNull,
      reason: 'the upgrade bricked and fell back to quarantine-and-rebuild: '
          '${LocalDb.lastRebuild?.cause}');
  final rows = await db.rawQuery('PRAGMA user_version');
  return (rows.first.values.first as num?)?.toInt() ?? -1;
}

void main() {
  // SharedPreferences' mock needs a binding, and the pairing migration below
  // reads it.
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
  });

  test(
    'upgrade from v2 completes — step 3 recreates raw_records WITH rec_ts, '
    'so step 6 must not re-add it (duplicate column bricked every launch)',
    () async {
      const name = 'migrate_from_v2_test.db';
      created.add(name);
      await _seedOldDb(name, 2, [
        _legacyRawDdl,
        'CREATE TABLE samples (counter INTEGER PRIMARY KEY, ts INTEGER NOT NULL, hr INTEGER)',
        '''CREATE TABLE events (
             hex TEXT PRIMARY KEY, event_id INTEGER, ts INTEGER,
             captured_at INTEGER NOT NULL)''',
      ]);

      // Before the guard this threw
      // DatabaseException(duplicate column name: rec_ts) out of openDatabase,
      // rolling the whole ladder back — forever, on every launch.
      final version = await _openThroughLocalDb(name);
      expect(version, LocalDb.schemaVersion);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'upgrade from v6 completes — step 7 creates sessions WITH steps, '
    'so step 11 must not re-add it',
    () async {
      const name = 'migrate_from_v6_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        6,
        [
          _v6RawDdl,
          'CREATE TABLE samples (counter INTEGER PRIMARY KEY, ts INTEGER NOT NULL, hr INTEGER)',
          '''CREATE TABLE events (
               hex TEXT PRIMARY KEY, event_id INTEGER, ts INTEGER,
               captured_at INTEGER NOT NULL)''',
          ..._v5DerivedDdl,
        ],
        seedRows: (db) async {
          await db.insert('raw_records', {
            'hex': 'deadbeef',
            'counter': 42,
            'packet_type': 47,
            'captured_at': 1780000000 * 1000,
            'rec_ts': 0,
          });
          // …and a record that ACTUALLY DECODES, so step 19's backfill really
          // writes through _queueDecodedOneHz. With only the undecodable row
          // above, the backfill queued nothing and the step-19 brick (the
          // re-key dropping step_count/… out from under the insert that names
          // them) never fired.
          for (var i = 0; i < 2; i++) {
            await db.insert('raw_records', {
              'hex': _v24RecordHex(
                counter: 4200 + i,
                tsEpoch: 1785000000 + i,
                hr: 61 + i,
              ),
              'counter': 4200 + i,
              'packet_type': 47,
              'captured_at': (1785000000 + i) * 1000,
              'rec_ts': 1785000000 + i,
            });
          }
          await db.insert('derived_day', {
            'date': '2026-05-05',
            'payload_json': '{"legacy": true}',
            'version': 1,
            'last_raw_ts': 1780000000,
            'computed_at': 1,
            'rhr': 55.0,
          });
        },
      );

      // Before the guard: DatabaseException(duplicate column name: steps).
      final version = await _openThroughLocalDb(name);
      expect(version, LocalDb.schemaVersion);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');

      // The ladder's real work still happened: derived_day carried across.
      final migrated = await LocalDb.dayResult('2026-05-05');
      expect(migrated, isNotNull);
      expect(migrated!['payload_json'], '{"legacy": true}');

      // …and `sessions` has exactly ONE `steps` column, not two.
      final db = await LocalDb.instance;
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      expect(cols.where((c) => c['name'] == 'steps').length, 1);
      expect(cols.where((c) => c['name'] == 'hrr_bpm').length, 1);

      // Step 19's backfill landed. Before the fix this threw `no such column:
      // step_count` — the rung's own re-key had just rebuilt decoded_onehz
      // without the band columns the backfill's insert names.
      final oh = await db.query('decoded_onehz', orderBy: 'rec_ts ASC');
      expect([for (final r in oh) r['rec_ts']], [1785000000, 1785000001]);
      expect([for (final r in oh) r['hr']], [61, 62]);
      // The band columns are present and NULL — a gen4 record reports none.
      expect(oh.first.containsKey('step_count'), isTrue);
      expect(oh.first['step_count'], isNull);
      // The RR beat rode along with it.
      final rr = await db.query('decoded_rr');
      expect(rr.length, 2);
      expect(rr.first['rr_ms'], 850);
    },
  );

  test(
    'an orphaned sync_cursor_legacy is RESUMED, not abandoned — a crash '
    'mid-copy must not silently lose the resumable-sync cursor',
    () async {
      const name = 'migrate_legacy_resume_test.db';
      created.add(name);
      // Exactly the state an interrupted legacy migration leaves behind: the
      // NEW-shaped sync_cursor already exists (so the old code's "already
      // current" early-return fired and never looked at the orphan), while
      // sync_cursor_legacy still holds the rows that were never copied.
      await _seedOldDb(
        name,
        LocalDb.schemaVersion,
        [
          '''CREATE TABLE sync_cursor (
               name TEXT PRIMARY KEY, value TEXT, updated_at INTEGER NOT NULL)''',
          '''CREATE TABLE sync_cursor_legacy (
               name TEXT PRIMARY KEY, value TEXT, note TEXT)''',
        ],
        seedRows: (db) async {
          // Say the copy died after one of three rows.
          await db.insert('sync_cursor', {
            'name': 'strap_trim',
            'value': 'aabbccdd',
            'updated_at': 1,
          });
          for (final r in const [
            ['strap_trim', 'aabbccdd'],
            ['counter_hw', '1200000'],
            ['rec_ts_hw', '1780000000'],
          ]) {
            await db.insert('sync_cursor_legacy', {
              'name': r[0],
              'value': r[1],
            });
          }
        },
      );

      await _openThroughLocalDb(name);

      // Every legacy row is now in the live table…
      expect(await LocalDb.getCursor('strap_trim'), 'aabbccdd');
      expect(await LocalDb.getCursorInt('counter_hw'), 1200000);
      expect(await LocalDb.getCursorInt('rec_ts_hw'), 1780000000);
      // …and the orphan is gone, so this can never run again.
      final db = await LocalDb.instance;
      final left = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='sync_cursor_legacy'",
      );
      expect(left, isEmpty);
    },
  );

  test(
    'a legacy migration interrupted BEFORE the CREATE (table missing, legacy '
    'present) also resumes cleanly',
    () async {
      const name = 'migrate_legacy_resume2_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        LocalDb.schemaVersion,
        [
          '''CREATE TABLE sync_cursor_legacy (
               name TEXT PRIMARY KEY, value TEXT, note TEXT)''',
        ],
        seedRows: (db) async {
          await db.insert('sync_cursor_legacy', {
            'name': 'strap_trim',
            'value': 'feedface',
          });
        },
      );

      await _openThroughLocalDb(name);
      expect(await LocalDb.getCursor('strap_trim'), 'feedface');
      final db = await LocalDb.instance;
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='sync_cursor_legacy'",
        ),
        isEmpty,
      );
    },
  );

  test(
    'upgrade from v27 adds the numeric journal tables without touching the '
    'tags and note already stored for a day',
    () async {
      const name = 'migrate_from_v27_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        27,
        [
          ..._v5DerivedDdl,
          "CREATE TABLE journal (date TEXT PRIMARY KEY, "
              "tags_json TEXT NOT NULL DEFAULT '[]', "
              "note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL)",
        ],
        seedRows: (db) async {
          await db.insert('journal', {
            'date': '2026-06-01',
            'tags_json': '["caffeine","late meal"]',
            'note': 'felt rough',
            'updated_at': 1,
          });
        },
      );

      final version = await _openThroughLocalDb(name);
      expect(version, LocalDb.schemaVersion);

      // The upgrade is purely additive: a day that only ever had tags keeps
      // them, and simply has no numeric rows.
      final rows = await LocalDb.journalRows();
      expect(rows.single['tags_json'], '["caffeine","late meal"]');
      expect(rows.single['note'], 'felt rough');
      expect(await LocalDb.journalMetricsForDay('2026-06-01'), isEmpty);

      // And the new tables are usable immediately, not on the next launch.
      await LocalDb.putJournalMetrics('2026-06-01', {
        'mood': const JournalMetricValue(4),
      });
      expect(
        (await LocalDb.journalMetricsForDay('2026-06-01'))['mood']!.value,
        4,
      );
      expect(await LocalDb.journalFieldDefs(), isEmpty);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );


  test(
    'upgrade from v27 creates the lab tables and they accept a write '
    'immediately, not on the next launch',
    () async {
      const name = 'migrate_from_v27_labs_test.db';
      created.add(name);
      await _seedOldDb(name, 27, _v5DerivedDdl);

      final version = await _openThroughLocalDb(name);
      expect(version, LocalDb.schemaVersion);

      await LocalDb.putLabResult(
        marker: 'ferritin',
        takenOn: '2026-03-04',
        value: 42,
        unit: 'ng/mL',
      );
      expect((await LocalDb.labResults()).single['value'], 42.0);
      expect(await LocalDb.labMarkerDefs(), isEmpty);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'upgrade from v27 runs the whole ladder to 31 and every new table works',
    () async {
      const name = 'migrate_from_v27_to_31_test.db';
      created.add(name);
      await _seedOldDb(name, 27, _v5DerivedDdl);

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);

      // Each rung's table, exercised rather than merely present — a CREATE
      // that ran with a typo still leaves a table that nothing can write to.
      await LocalDb.putJournalMetrics('2026-06-01', {
        'mood': const JournalMetricValue(4),
      });
      await LocalDb.putLabResult(
        marker: 'ferritin',
        takenOn: '2026-03-04',
        value: 42,
        unit: 'ng/mL',
      );
      await LocalDb.putBreathingSession(
        startedAt: 1000,
        endedAt: 2000,
        pattern: 'resonance',
        seconds: 120,
      );
      await LocalDb.putNapEdit(
        dayId: '2026-06-01',
        startTs: 1000,
        endTs: 4600,
        source: 'manual',
      );

      expect(
        (await LocalDb.journalMetricsForDay('2026-06-01'))['mood']!.value,
        4,
      );
      expect((await LocalDb.labResults()).single['value'], 42.0);
      expect((await LocalDb.breathingSessions()).single['seconds'], 120);
      // MIND-06's window columns reach an OLD database through the onOpen
      // repair rather than a ladder rung, so this is the only thing that
      // proves they arrive at all on an upgrade.
      await LocalDb.updateBreathingWindows(
        startedAt: 1000,
        preRmssd: 38.5,
        postRmssd: 44.25,
      );
      expect((await LocalDb.breathingSessions()).single['pre_rmssd'], 38.5);
      expect((await LocalDb.breathingSessions()).single['post_rmssd'], 44.25);
      // An UPDATE, never an upsert: a session too short to bank has no row,
      // and its windows must not create one behind it.
      await LocalDb.updateBreathingWindows(startedAt: 999, preRmssd: 40);
      expect((await LocalDb.breathingSessions()).length, 1);
      expect((await LocalDb.napEdits('2026-06-01')).single['source'], 'manual');
      expect(await LocalDb.napEditDays(), {'2026-06-01'});

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'v33 re-key converts a v31 COUNTER-keyed decoded store to rec_ts LOSSLESSLY '
    '— raw_records is already dropped, so the rekey is the only copy',
    () async {
      const name = 'migrate_from_v31_counterkeyed_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        31,
        [..._counterKeyedDecodedDdl, ..._v5DerivedDdl],
        seedRows: (db) async {
          // Three distinct seconds, distinct counters (valid old-schema data).
          for (final r in const [
            [100, 1785000000, 60],
            [101, 1785000001, 61],
            [102, 1785000002, 62],
          ]) {
            await db.insert('decoded_onehz', {
              'counter': r[0], 'rec_ts': r[1], 'hr': r[2],
              'ax': 0.0, 'ay': 0.0, 'az': 0.0,
              'spo2_red_raw': 0, 'spo2_ir_raw': 0, 'skin_temp_raw': 0,
            });
          }
          // Beats under counter 100 (two) and 102 (one).
          await db.insert('decoded_rr', {
            'counter': 100, 'beat_index': 0,
            'rr_ts_ms': 1785000000 * 1000, 'rr_ms': 800,
          });
          await db.insert('decoded_rr', {
            'counter': 100, 'beat_index': 1,
            'rr_ts_ms': 1785000000 * 1000, 'rr_ms': 810,
          });
          await db.insert('decoded_rr', {
            'counter': 102, 'beat_index': 0,
            'rr_ts_ms': 1785000002 * 1000, 'rr_ms': 900,
          });
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      // Every second survives; counter is preserved as the forensic column.
      final oh = await db.query('decoded_onehz', orderBy: 'rec_ts ASC');
      expect([for (final r in oh) r['rec_ts']],
          [1785000000, 1785000001, 1785000002]);
      expect([for (final r in oh) r['counter']], [100, 101, 102]);
      // The key is no longer `counter` (v33) and, since v47, no longer rec_ts
      // alone either: (device_id, ts_ms), with rec_ts demoted to the indexed
      // range column and ts_ms carrying the same value it always had.
      final ohInfo = await db.rawQuery('PRAGMA table_info(decoded_onehz)');
      expect(ohInfo.firstWhere((c) => c['name'] == 'device_id')['pk'], 1);
      expect(ohInfo.firstWhere((c) => c['name'] == 'ts_ms')['pk'], 2);
      expect(ohInfo.firstWhere((c) => c['name'] == 'rec_ts')['pk'], 0);
      expect(ohInfo.firstWhere((c) => c['name'] == 'counter')['pk'], 0);
      expect([for (final r in oh) r['device_id']], ['', '', '']);
      expect([for (final r in oh) r['ts_ms']],
          [1785000000000, 1785000001000, 1785000002000]);

      // Beats re-home onto their real second; decoded_rr loses its counter col.
      final rr =
          await db.query('decoded_rr', orderBy: 'rec_ts ASC, beat_index ASC');
      expect([for (final r in rr) r['rec_ts']],
          [1785000000, 1785000000, 1785000002]);
      expect([for (final r in rr) r['rr_ms']], [800, 810, 900]);
      final rrInfo = await db.rawQuery('PRAGMA table_info(decoded_rr)');
      expect(rrInfo.any((c) => c['name'] == 'counter'), isFalse);

      // No stranded beats, no cross-stamped timestamps, no leaked temp tables.
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) c FROM decoded_rr WHERE rr_ts_ms != rec_ts * 1000',
        )).first['c'],
        0,
      );
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name LIKE '%\\_v33' ESCAPE '\\' "
          "OR name LIKE '%\\_new' ESCAPE '\\'",
        ),
        isEmpty,
      );

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'v31→v32 re-keys raw_archive off the volatile counter onto frame hex '
    'without losing a distinct frame, collapsing only exact-duplicate hex',
    () async {
      const name = 'migrate_from_v31_rawarchive_test.db';
      created.add(name);
      // The pre-v32 raw_archive shape: keyed by the strap counter, which resets
      // to ~0 on reboot — so a post-reboot frame reusing a live counter was
      // silently IGNORE-dropped in the one table meant to never lose a frame.
      await _seedOldDb(
        name,
        31,
        const [
          '''
          CREATE TABLE raw_archive (
            counter INTEGER PRIMARY KEY,
            hex TEXT NOT NULL,
            packet_type INTEGER NOT NULL,
            rec_ts INTEGER,
            captured_at INTEGER NOT NULL,
            reason TEXT NOT NULL
          )
          ''',
          'CREATE INDEX idx_raw_archive_captured ON raw_archive(captured_at DESC)',
        ],
        seedRows: (db) async {
          Future<void> row(int counter, String hex) => db.insert('raw_archive', {
                'counter': counter,
                'hex': hex,
                'packet_type': 0x2F,
                'captured_at': 1750000000000 + counter,
                'reason': 'undecodable_rec_v99',
              });
          // Three distinct frames (distinct counter AND hex) — none may be lost.
          await row(1, 'aa01');
          await row(2, 'bb02');
          await row(3, 'cc03');
          // Two rows the OLD counter-PK allowed but that carry IDENTICAL bytes;
          // the content re-key must collapse them to one (the dedup we want).
          await row(10, 'ff06');
          await row(11, 'ff06');
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);

      // 5 old rows → 4: the three distinct frames survive, the duplicate-hex
      // pair collapses to one. Nothing distinct was lost.
      final stats = await LocalDb.rawArchiveStats();
      expect(stats['count'], 4);

      // The migrated table is now hex-PK, proven end-to-end through the REAL
      // ladder (not just a fresh onCreate): two DISTINCT frames that reuse ONE
      // counter both survive — the exact loss the old counter-PK caused.
      await LocalDb.archiveRawRecord(ArchiveRecord(
        counter: 1, // reuses a counter already present from the seed
        hex: 'dd04',
        packetType: 0x2F,
        capturedAt: 1750000500000,
        reason: 'undecodable_post_reboot',
      ));
      await LocalDb.archiveRawRecord(ArchiveRecord(
        counter: 1, // SAME counter, DIFFERENT bytes
        hex: 'ee05',
        packetType: 0x2F,
        capturedAt: 1750000600000,
        reason: 'undecodable_post_reboot',
      ));
      expect((await LocalDb.rawArchiveStats())['count'], 6);

      // …and an identical re-flood still dedups on content.
      await LocalDb.archiveRawRecord(ArchiveRecord(
        counter: 999, // different counter, but bytes already archived
        hex: 'dd04',
        packetType: 0x2F,
        capturedAt: 1750000700000,
        reason: 'undecodable_post_reboot',
      ));
      expect((await LocalDb.rawArchiveStats())['count'], 6);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'v39 relaxes NOT NULL on the sensor columns of a POPULATED decoded_onehz '
    'without losing or rewriting a row',
    () async {
      const name = 'migrate_v38_to_v39_test.db';
      created.add(name);
      // A v38 install: the sensor columns are NOT NULL, so absence has already
      // been written as real zeros. The migration must keep those rows exactly
      // as they are (they are indistinguishable from real readings after the
      // fact) while making the column able to hold NULL going forward.
      await _seedOldDb(
        name,
        38,
        [
          '''
          CREATE TABLE decoded_onehz (
            rec_ts INTEGER PRIMARY KEY, counter INTEGER NOT NULL,
            hr INTEGER NOT NULL, ax REAL NOT NULL, ay REAL NOT NULL,
            az REAL NOT NULL, spo2_red_raw INTEGER NOT NULL,
            spo2_ir_raw INTEGER NOT NULL, skin_temp_raw INTEGER NOT NULL,
            step_count INTEGER, step_cadence INTEGER, activity_class INTEGER,
            skin_temp_c REAL, on_wrist INTEGER, hr_valid INTEGER,
            hr_alt INTEGER)
        ''',
          '''
          CREATE TABLE decoded_rr (
            rec_ts INTEGER NOT NULL, beat_index INTEGER NOT NULL,
            rr_ts_ms INTEGER NOT NULL, rr_ms INTEGER NOT NULL,
            PRIMARY KEY (rec_ts, beat_index))
        ''',
        ],
        seedRows: (db) async {
          for (var i = 0; i < 3; i++) {
            await db.insert('decoded_onehz', {
              'rec_ts': 1780000000 + i,
              'counter': 100 + i,
              'hr': 60 + i,
              'ax': 0.0, // the historical fabricated-absent shape
              'ay': 0.0,
              'az': 0.0,
              'spo2_red_raw': 1000 + i,
              'spo2_ir_raw': 2000 + i,
              'skin_temp_raw': 3000 + i,
              'skin_temp_c': 30.5,
            });
          }
          await db.insert('decoded_rr', {
            'rec_ts': 1780000000,
            'beat_index': 0,
            'rr_ts_ms': 1780000000000,
            'rr_ms': 900,
          });
        },
      );

      final version = await _openThroughLocalDb(name);
      expect(version, LocalDb.schemaVersion);

      final db = await LocalDb.instance;
      final rows = await db.query('decoded_onehz', orderBy: 'rec_ts');
      expect(rows.length, 3, reason: 'every row survives the rebuild');
      expect(rows.first['hr'], 60);
      expect(rows.first['spo2_red_raw'], 1000);
      expect(rows.first['skin_temp_c'], 30.5);
      expect(rows.last['counter'], 102);
      // The child table is NOT rebuilt, so its rows are untouched.
      expect((await db.query('decoded_rr')).length, 1);

      // The whole point: a NULL sensor reading is now storable.
      await db.insert('decoded_onehz', {
        'rec_ts': 1780000009,
        'counter': 109,
        'hr': 72,
        'ax': null,
        'ay': null,
        'az': null,
        'spo2_red_raw': null,
        'spo2_ir_raw': null,
        'skin_temp_raw': null,
      });
      final absent = await db.query('decoded_onehz',
          where: 'rec_ts = ?', whereArgs: [1780000009]);
      expect(absent.first['ax'], isNull);
      expect(absent.first['skin_temp_raw'], isNull);

      // The counter index is GONE — nothing ever read by `counter`, and it cost
      // a non-sequential b-tree insert per 1 Hz record on the ingest path. An
      // upgrade from a version that HAD it must drop it, not carry it forward.
      final idx = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='decoded_onehz'",
      );
      expect(
        idx.map((r) => r['name']),
        isNot(contains('idx_decoded_onehz_counter')),
      );

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'upgrade from v6 with an OFF-SKIN record completes — step 19 backfills '
    'through a writer that emits NULL hr, so the relax must precede it',
    () async {
      // v43 made `decoded_onehz.hr` nullable and `_queueDecodedOneHz` writes
      // NULL for a record with no heart rate. `hr = 0` is the off-skin
      // sentinel and is ORDINARY, not rare. Step 19 re-keys the decoded store
      // with `hr INTEGER NOT NULL` and then runs the backfill through that
      // same writer — so without the relax at the top of _backfillDecodedStore
      // the first off-skin record fails the constraint, throws inside the one
      // exclusive onUpgrade transaction, and quarantines the user's database.
      const name = 'migrate_v6_offskin_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        6,
        [
          _v6RawDdl,
          'CREATE TABLE samples (counter INTEGER PRIMARY KEY, ts INTEGER NOT NULL, hr INTEGER)',
          '''CREATE TABLE events (
               hex TEXT PRIMARY KEY, event_id INTEGER, ts INTEGER,
               captured_at INTEGER NOT NULL)''',
          ..._v5DerivedDdl,
        ],
        seedRows: (db) async {
          for (final e in const [(4300, 70), (4301, 0), (4302, 71)]) {
            await db.insert('raw_records', {
              'hex': _v24RecordHex(
                counter: e.$1,
                tsEpoch: 1786000000 + e.$1,
                hr: e.$2,
              ),
              'counter': e.$1,
              'packet_type': 47,
              'captured_at': (1786000000 + e.$1) * 1000,
              'rec_ts': 1786000000 + e.$1,
            });
          }
        },
      );

      // `_openThroughLocalDb` already fails loudly if the ladder bricked and
      // fell back to quarantine-and-rebuild.
      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);

      final db = await LocalDb.instance;
      final rows = await db.rawQuery(
        'SELECT rec_ts, hr FROM decoded_onehz ORDER BY rec_ts ASC',
      );
      expect(rows.length, 3);
      expect(rows[0]['hr'], 70);
      // The off-skin second SURVIVES as a row and its HR reads as absent.
      expect(rows[1]['hr'], isNull);
      expect(rows[2]['hr'], 71);

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'v47 re-keys decoded_onehz / decoded_rr / samples onto (device_id, ts_ms) '
    'without losing or rewriting a row',
    () async {
      const name = 'migrate_v46_device_key_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        46,
        [
          ..._preDeviceKeyDecodedDdl,
          ..._v5DerivedDdl,
        ],
        seedRows: (db) async {
          for (var i = 0; i < 3; i++) {
            await db.insert('decoded_onehz', {
              'rec_ts': 1786000000 + i,
              'counter': 500 + i,
              'hr': 60 + i,
              'ax': 0.1,
              'ay': 0.2,
              'az': 0.9,
              'device_family': 'gen4',
              'ts_subsec': 16384,
            });
            await db.insert('samples', {
              'counter': 500 + i,
              'ts': 1786000000 + i,
              'hr': 60 + i,
            });
          }
          for (var b = 0; b < 2; b++) {
            await db.insert('decoded_rr', {
              'rec_ts': 1786000000,
              'beat_index': b,
              'rr_ts_ms': 1786000000 * 1000,
              'rr_ms': 800 + b,
            });
          }
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      // NOTHING IS LOST AND NOTHING IS REWRITTEN. Same rows, same values, plus
      // a key that can tell two devices apart.
      final oh = await db.query('decoded_onehz', orderBy: 'rec_ts ASC');
      expect([for (final r in oh) r['rec_ts']],
          [1786000000, 1786000001, 1786000002]);
      expect([for (final r in oh) r['hr']], [60, 61, 62]);
      expect([for (final r in oh) r['counter']], [500, 501, 502]);
      // Columns added off-ladder survive the PRAGMA-derived rebuild — the whole
      // reason the DDL is reconstructed instead of hardcoded.
      expect([for (final r in oh) r['ts_subsec']], [16384, 16384, 16384]);
      expect([for (final r in oh) r['device_family']], ['gen4', 'gen4', 'gen4']);
      // '' is the primary band, reserved permanently; ts_ms is rec_ts*1000
      // EXACTLY, so the key is as unique as rec_ts was.
      expect([for (final r in oh) r['device_id']], ['', '', '']);
      expect([for (final r in oh) r['ts_ms']],
          [1786000000000, 1786000001000, 1786000002000]);

      for (final t in const ['decoded_onehz', 'decoded_rr', 'samples']) {
        final info = await db.rawQuery('PRAGMA table_info($t)');
        expect(info.firstWhere((c) => c['name'] == 'device_id')['pk'], 1,
            reason: t);
        expect(info.firstWhere((c) => c['name'] == 'ts_ms')['pk'], 2,
            reason: t);
      }
      // decoded_rr's key is its parent's, one level deeper.
      final rrInfo = await db.rawQuery('PRAGMA table_info(decoded_rr)');
      expect(rrInfo.firstWhere((c) => c['name'] == 'beat_index')['pk'], 3);
      final rr =
          await db.query('decoded_rr', orderBy: 'ts_ms ASC, beat_index ASC');
      expect([for (final r in rr) r['rr_ms']], [800, 801]);
      expect([for (final r in rr) r['ts_ms']],
          [1786000000000, 1786000000000]);

      // `samples` was keyed by the WHOOP flash counter; it is keyed by time now
      // and `counter` is demoted to a plain column.
      final sm = await db.query('samples', orderBy: 'ts ASC');
      expect([for (final r in sm) r['ts_ms']],
          [1786000000000, 1786000001000, 1786000002000]);
      expect([for (final r in sm) r['counter']], [500, 501, 502]);

      // rec_ts stops being the key, so it MUST become an index — every read in
      // db.dart ranges over it and would otherwise scan the whole table.
      final ix = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name IN ('decoded_onehz', 'decoded_rr')",
      );
      final ixNames = {for (final r in ix) r['name']};
      expect(ixNames, contains('idx_decoded_onehz_rects'));
      expect(ixNames, contains('idx_decoded_rr_rects'));

      // No leaked temp tables.
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name LIKE '%\\_v47' ESCAPE '\\'",
        ),
        isEmpty,
      );

      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'THE DEDUPE REGRESSION: re-ingesting an already-migrated second leaves '
    'EXACTLY ONE row — it fires on the next sync, not at migration time',
    () async {
      // The v47 re-key is only correct if `ts_ms = rec_ts * 1000` keeps the key
      // exactly as unique as `rec_ts` was. Widen it by one sub-second and the
      // band's post-reboot counter reset, a re-drained flash region and a
      // re-delivered batch each start writing a SECOND row for a second that
      // already has one — silently doubling the substrate. A ladder test cannot
      // see that: it only shows up the next time the writer runs.
      const name = 'v47_dedupe_test.db';
      created.add(name);
      await _seedOldDb(name, 46, [..._preDeviceKeyDecodedDdl, ..._v5DerivedDdl],
          seedRows: (db) async {
        await db.insert('decoded_onehz', {
          'rec_ts': 1786000000,
          'counter': 900,
          'hr': 55,
          'ts_subsec': 100,
        });
        await db.insert('decoded_rr', {
          'rec_ts': 1786000000,
          'beat_index': 0,
          'rr_ts_ms': 1786000000 * 1000,
          'rr_ms': 1000,
        });
      });
      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);

      // The SAME second re-offloaded under a DIFFERENT counter (what a band
      // reboot produces) and with a different sub-second and a shrinking beat
      // set — the three things that used to fight over the key.
      await LocalDb.insertRecordsBatch(
        [
          RawRecord(
            counter: 7,
            packetType: 47,
            hex: _v24RecordHex(
              counter: 7,
              tsEpoch: 1786000000,
              hr: 58,
              rrMs: 950,
            ),
            capturedAt: 1786000000 * 1000,
            recTs: 1786000000,
          ),
        ],
        [null],
      );

      final db = await LocalDb.instance;
      final oh = await db.query('decoded_onehz');
      expect(oh.length, 1, reason: 'newest-wins dedupe must survive the re-key');
      expect(oh.first['hr'], 58, reason: 'the fresher offload wins');
      expect(oh.first['ts_ms'], 1786000000000);
      // The beat set is REPLACED, not merged — and the delete that does it is
      // now scoped to the writing device.
      final rr = await db.query('decoded_rr');
      expect(rr.length, 1);
      expect(rr.first['rr_ms'], 950);
    },
  );

  test(
    'THE POINT OF THE WHOLE PHASE: a primary row and a secondary row at the '
    'SAME instant both survive',
    () async {
      // Before v47 this was impossible by construction: `decoded_onehz` was
      // `rec_ts INTEGER PRIMARY KEY` written with REPLACE and `decoded_rr` was
      // cleared by an unscoped `DELETE ... WHERE rec_ts = ?`, so the second
      // device did not merge with the first — it DELETED it, row and beats, and
      // raw_archive prunes at 3 days.
      const name = 'v47_two_devices_test.db';
      created.add(name);
      await _seedOldDb(name, 46, [..._preDeviceKeyDecodedDdl, ..._v5DerivedDdl],
          seedRows: (db) async {
        await db.insert('decoded_onehz',
            {'rec_ts': 1786000000, 'counter': 1, 'hr': 61});
        await db.insert('decoded_rr', {
          'rec_ts': 1786000000,
          'beat_index': 0,
          'rr_ts_ms': 1786000000 * 1000,
          'rr_ms': 980,
        });
      });
      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      await db.insert(
        'decoded_onehz',
        {
          'device_id': 'polar-h10:AABBCC',
          'ts_ms': 1786000000 * 1000,
          'rec_ts': 1786000000,
          'counter': 1,
          'hr': 59,
          'source': 'polar_h10',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.insert(
        'decoded_rr',
        {
          'device_id': 'polar-h10:AABBCC',
          'ts_ms': 1786000000 * 1000,
          'rec_ts': 1786000000,
          'beat_index': 0,
          'rr_ts_ms': 1786000000 * 1000,
          'rr_ms': 1010,
          'source': 'polar_h10',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final oh = await db.query('decoded_onehz', orderBy: 'device_id ASC');
      expect(oh.length, 2);
      expect([for (final r in oh) r['device_id']], ['', 'polar-h10:AABBCC']);
      expect([for (final r in oh) r['hr']], [61, 59]);

      final rr = await db.query('decoded_rr', orderBy: 'device_id ASC');
      expect(rr.length, 2);
      expect([for (final r in rr) r['rr_ms']], [980, 1010]);

      // And the primary band writing that same second again clears only ITS OWN
      // beats — the unscoped delete is what made a second device destructive.
      await LocalDb.insertRecordsBatch(
        [
          RawRecord(
            counter: 2,
            packetType: 47,
            hex: _v24RecordHex(
              counter: 2,
              tsEpoch: 1786000000,
              hr: 62,
              rrMs: 970,
            ),
            capturedAt: 1786000000 * 1000,
            recTs: 1786000000,
          ),
        ],
        [null],
      );
      final after = await db.query('decoded_rr', orderBy: 'device_id ASC');
      expect(after.length, 2);
      expect([for (final r in after) r['rr_ms']], [970, 1010]);
      expect(
        (await db.query('decoded_onehz')).length,
        2,
        reason: 'the strap must never evict the other device',
      );
    },
  );

  test(
    'v49 adds the device store and live_coverage.device_id without moving a '
    'single day\'s step total',
    () async {
      const name = 'migrate_v48_device_table_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        48,
        [_preDeviceLiveCoverageDdl, ..._v5DerivedDdl],
        seedRows: (db) async {
          // Two band rows over the SAME walk, which is what a re-import
          // produces. One device ⇒ they sum, and that is what the table has
          // always meant.
          for (var i = 0; i < 2; i++) {
            await db.insert('live_coverage', {
              'start_ts': 1786000000,
              'end_ts': 1786001800,
              'steps': 3000,
              'day': '2026-08-06',
              'source': 'band',
            });
          }
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      // The rows are untouched and every one belongs to the primary band —
      // which is exactly what a pre-v49 row has always meant, so no total moves.
      final rows = await db.query('live_coverage', orderBy: 'id ASC');
      expect([for (final r in rows) r['steps']], [3000, 3000]);
      expect([for (final r in rows) r['device_id']], ['', '']);
      expect((await LocalDb.resolvedStepsForDay('2026-08-06')).total, 6000);

      // And THE POINT: a second strap over the same walk now competes instead
      // of being credited in full. This could not fire before the column
      // existed — the resolver had handled it since the ladder gained
      // `CoverageSpan.deviceId` and never saw a second id.
      await LocalDb.addLiveCoverage(
        1786000000,
        1786001800,
        3000,
        '2026-08-06',
        deviceId: 'second-strap',
      );
      expect((await LocalDb.resolvedStepsForDay('2026-08-06')).total, 6000,
          reason: 'the walk is counted once more, not twice more');

      // The device store exists, is empty, and is not silently absent from the
      // health check — the observation table's rung is the worked example.
      expect(await LocalDb.deviceRow(), isNull);
      expect(await LocalDb.deviceRows(), isEmpty);
      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test(
    'the paired band survives the upgrade: the prefs pair migrates into the '
    'device table on first load',
    () async {
      const name = 'migrate_v48_paired_device_test.db';
      created.add(name);
      await _seedOldDb(name, 48, [_preDeviceLiveCoverageDdl, ..._v5DerivedDdl]);
      SharedPreferences.setMockInitialValues({
        'paired_remote_id': 'AA:BB:CC:DD:EE:FF',
        'paired_serial': '4C2248092',
      });
      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);

      // A user mid-upgrade must not have to re-pair.
      final paired = await PairedDevice.load();
      expect(paired?.remoteId, 'AA:BB:CC:DD:EE:FF');
      expect(paired?.serial, '4C2248092');
      // …and the migration is a WRITE, not a read-through: the row is there for
      // everything that joins on `device_id` from here on.
      final row = await LocalDb.deviceRow();
      expect(row?['remote_id'], 'AA:BB:CC:DD:EE:FF');
      expect(row?['label'], '4C2248092');
      expect(row?['id'], LocalDb.kPrimaryDeviceId);
      // The link has not said which band it is, and NULL is that refusal —
      // never a defaulted 'gen4'.
      expect(row?['adapter_id'], isNull);

      // Forgetting clears BOTH copies, or the mirror puts it straight back.
      await PairedDevice.clear();
      expect(await PairedDevice.load(), isNull);
      expect(await LocalDb.deviceRow(), isNull);
    },
  );

  test(
    'v50 adds device_coverage + signal_priority, both empty, idempotent reopen',
    () async {
      const name = 'migrate_v50_device_coverage_test.db';
      created.add(name);
      await _seedOldDb(name, 50, _v5DerivedDdl);

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      expect(await db.query('device_coverage'), isEmpty);
      expect(await db.query('signal_priority'), isEmpty);
      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');

      // Reopening (same-version repair pass) must not throw or duplicate.
      await LocalDb.close();
      LocalDb.lastRebuild = null;
      LocalDb.dbName = name;
      final db2 = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);
      expect(await db2.query('device_coverage'), isEmpty);
      expect(await db2.query('signal_priority'), isEmpty);
    },
  );

  test(
    'v50 gives device.role/.wearing: the primary row becomes role=primary, '
    'wearing=1 everywhere',
    () async {
      const name = 'migrate_v50_device_role_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        50,
        [
          '''
          CREATE TABLE device (
            id TEXT PRIMARY KEY, adapter_id TEXT, remote_id TEXT,
            label TEXT, tier TEXT,
            first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL
          )
          ''',
          ..._v5DerivedDdl,
        ],
        seedRows: (db) async {
          await db.insert('device', {
            'id': '',
            'first_seen': 1786000000,
            'last_seen': 1786000000,
          });
          await db.insert('device', {
            'id': 'second-strap',
            'first_seen': 1786000000,
            'last_seen': 1786000000,
          });
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;
      final rows = await db.query('device', orderBy: 'id ASC');
      expect(rows.length, 2);
      final byId = {for (final r in rows) r['id']: r};
      expect(byId['']!['role'], 'primary');
      expect(byId['second-strap']!['role'], 'paired');
      expect([for (final r in rows) r['wearing']], [1, 1]);
    },
  );

  test(
    'v50 re-keys raw_archive / band_events / events / band_battery onto '
    'device_id without losing a row, restores their indexes, and a second '
    'open is idempotent',
    () async {
      const name = 'migrate_v50_rekey_test.db';
      created.add(name);
      await _seedOldDb(
        name,
        50,
        [
          '''
          CREATE TABLE raw_archive (
            hex TEXT PRIMARY KEY, counter INTEGER, packet_type INTEGER NOT NULL,
            rec_ts INTEGER, captured_at INTEGER NOT NULL, reason TEXT NOT NULL
          )
          ''',
          '''
          CREATE TABLE band_events (
            hex TEXT PRIMARY KEY, event_id INTEGER NOT NULL, name TEXT NOT NULL,
            ts INTEGER NOT NULL, payload_json TEXT NOT NULL DEFAULT '{}',
            captured_at INTEGER NOT NULL
          )
          ''',
          '''
          CREATE TABLE events (
            hex TEXT PRIMARY KEY, event_id INTEGER, ts INTEGER,
            captured_at INTEGER NOT NULL
          )
          ''',
          '''
          CREATE TABLE band_battery (
            ts INTEGER NOT NULL, battery_pct REAL, charging INTEGER,
            wrist_on INTEGER, millivolts INTEGER, charge_units INTEGER,
            source TEXT NOT NULL, PRIMARY KEY (ts, source)
          )
          ''',
          ..._v5DerivedDdl,
        ],
        seedRows: (db) async {
          await db.insert('raw_archive', {
            'hex': 'aa01', 'counter': 1, 'packet_type': 0x2F,
            'rec_ts': 1786000001, 'captured_at': 1786000001000,
            'reason': 'undecodable_rec_v99',
          });
          await db.insert('band_events', {
            'hex': 'bb01', 'event_id': 56, 'name': 'alarmSet',
            'ts': 1786000002, 'captured_at': 1786000002000,
          });
          await db.insert('events', {
            'hex': 'cc01', 'event_id': 56, 'ts': 1786000003,
            'captured_at': 1786000003000,
          });
          await db.insert('band_battery', {
            'ts': 1786000004, 'battery_pct': 88.0, 'charging': 0,
            'wrist_on': 1, 'source': 'band_event',
          });
        },
      );

      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      for (final t in const [
        'raw_archive', 'band_events', 'events', 'band_battery',
      ]) {
        final rows = await db.query(t);
        expect(rows.length, 1, reason: '$t row count must be unchanged');
        expect(rows.single['device_id'], LocalDb.kPrimaryDeviceId,
            reason: '$t migrated row must belong to the primary device');
      }

      final indexNames = [
        for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index'",
        ))
          r['name'] as String,
      ];
      for (final ix in const [
        'idx_raw_archive_captured',
        'idx_band_events_ts',
        'idx_band_battery_ts',
        'idx_events_ts',
      ]) {
        expect(indexNames, contains(ix));
      }
      expect(indexNames.where((n) => n.contains('_v51')), isEmpty,
          reason: 'no leftover temp-named indexes');

      // Idempotent second open: nothing re-rekeys or re-drops.
      await LocalDb.close();
      LocalDb.lastRebuild = null;
      LocalDb.dbName = name;
      final db2 = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);
      for (final t in const [
        'raw_archive', 'band_events', 'events', 'band_battery',
      ]) {
        expect((await db2.query(t)).length, 1);
      }
    },
  );

  test(
    'THE M3 GATE: re-ingesting an already-migrated event under a second '
    'device leaves two rows, and re-inserting the first device\'s leaves it '
    'still two',
    () async {
      const name = 'migrate_v50_dedupe_regression_test.db';
      created.add(name);
      await _seedOldDb(name, 50, _v5DerivedDdl);
      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      Future<void> insertAs(String deviceId) => db.insert('band_events', {
            'device_id': deviceId,
            'hex': 'shared-hex',
            'event_id': 56,
            'name': 'alarmSet',
            'ts': 1786000010,
            'captured_at': 1786000010000,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
      Future<void> insertEventsAs(String deviceId) =>
          db.insert('events', {
            'device_id': deviceId,
            'hex': 'shared-hex',
            'event_id': 56,
            'ts': 1786000010,
            'captured_at': 1786000010000,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);

      await insertAs('');
      await insertEventsAs('');
      await insertAs('device-b');
      await insertEventsAs('device-b');
      expect(await db.query('band_events'), hasLength(2));
      expect(await db.query('events'), hasLength(2));

      // Re-ingest the first device's — must not create a third row.
      await insertAs('');
      await insertEventsAs('');
      expect(await db.query('band_events'), hasLength(2));
      expect(await db.query('events'), hasLength(2));
    },
  );

  test(
    'raw_archive: two devices sharing a byte-identical undecodable frame '
    'both survive, and a re-flood from one device still dedups',
    () async {
      const name = 'migrate_v50_archive_cross_device_test.db';
      created.add(name);
      await _seedOldDb(name, 50, _v5DerivedDdl);
      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      Future<void> archiveAs(String deviceId) => db.insert('raw_archive', {
            'device_id': deviceId,
            'hex': 'deadbeef',
            'counter': 1,
            'packet_type': 0x2F,
            'rec_ts': 1786000020,
            'captured_at': 1786000020000,
            'reason': 'undecodable_rec_v99',
          }, conflictAlgorithm: ConflictAlgorithm.ignore);

      await archiveAs('');
      await archiveAs('device-b');
      expect(await db.query('raw_archive'), hasLength(2));

      await archiveAs(''); // re-flood
      expect(await db.query('raw_archive'), hasLength(2));
    },
  );

  test(
    'redriveArchivedRecords after the v50 rekey recovers BOTH devices\' '
    'copy of an identical re-drivable frame',
    () async {
      const name = 'migrate_v50_archive_redrive_test.db';
      created.add(name);
      await _seedOldDb(name, 50, _v5DerivedDdl);
      expect(await _openThroughLocalDb(name), LocalDb.schemaVersion);
      final db = await LocalDb.instance;

      const hex =
          '2f128000394801a6e5776a0040008300000000000000000000616d0d85830000'
          'fff678893fcd5b1ac07b9466bd8fb2b23e0d8eb20000000000000000001e0131'
          '01570c500b010c020c0100000000000000000000000000000000000000000000'
          '010053748080000000fcaf98c0000000';
      for (final deviceId in const ['', 'device-b']) {
        await db.insert('raw_archive', {
          'device_id': deviceId,
          'hex': hex,
          'counter': 21510400,
          'packet_type': 0x2F,
          'captured_at': 1786242475895,
          'reason': 'undecodable_rec_v18',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      expect(await LocalDb.redriveArchivedRecords(db), 2,
          reason: 'both devices\' identical frame must decode, not just one');
    },
  );
}
