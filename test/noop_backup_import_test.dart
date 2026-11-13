// Importing a `.noopbak` full backup (OpenStrap/edge#160, #199).
//
// A `.noopbak` is a ZIP around NOOP's own GRDB SQLite database, and on iOS it is
// the only export NOOP offers — so the CSV-only importer left every iOS migrant
// with no way in. The schema below is the one measured on a real 13-day backup
// (260 MB, NOOP 9.x); the traps it pins are the ones that file actually carries:
// empty `spo2Sample`/`respSample` tables, and a deviceId that differs between
// the sample tables ("my-whoop") and `sleepSession` ("my-whoop-noop").

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/import_container.dart';
import 'package:openstrap_edge/import/noop_backup_import.dart';
import 'package:openstrap_edge/import/noop_import.dart';

/// 'YYYY-MM-DD' for an epoch second, in the LOCAL zone — the same day key the
/// importer writes, so an assertion can scope itself to its own fixture.
String _localDay(int epochSec) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}


/// `payload_json` nests some sections as encoded strings and some as maps,
/// depending on which writer produced them — decode either shape.
Map<String, dynamic>? _section(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is String) {
    try {
      final d = jsonDecode(v);
      if (d is Map<String, dynamic>) return d;
    } on FormatException {
      // A rendered value ("—"), not an encoded section.
    }
  }
  return null;
}

/// Beats the RR pipeline actually used for [day], or null if it did not run.
int? _beatsUsed(Map<String, Object?> row) {
  final payload = _section(row['payload_json']);
  final irregular = _section(_section(payload?['clinical'])?['irregular_24h']);
  return _section(irregular?['value'])?['n_beats'] as int?;
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_noopbak_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    tmp = await Directory.systemTemp.createTemp('noopbak');
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Write a NOOP-schema database holding [seconds] of 1 Hz data from [t0],
  /// with the step counter walking 1/s. Returns its path.
  Future<String> writeNoopDb(
    String name, {
    required int t0,
    required int seconds,
    String deviceId = 'my-whoop',
    bool withEmptyOptionalTables = true,
  }) async {
    final path = p.join(tmp.path, name);
    if (File(path).existsSync()) File(path).deleteSync();
    final db = await databaseFactory.openDatabase(path);
    await db.execute('CREATE TABLE hrSample (deviceId TEXT NOT NULL, '
        'ts INTEGER NOT NULL, bpm INTEGER NOT NULL, synced INTEGER NOT NULL '
        'DEFAULT 0, PRIMARY KEY (deviceId, ts))');
    await db.execute('CREATE TABLE rrInterval (deviceId TEXT NOT NULL, '
        'ts INTEGER NOT NULL, rrMs INTEGER NOT NULL, synced INTEGER NOT NULL '
        'DEFAULT 0, PRIMARY KEY (deviceId, ts, rrMs))');
    await db.execute('CREATE TABLE gravitySample (deviceId TEXT NOT NULL, '
        'ts INTEGER NOT NULL, x DOUBLE NOT NULL, y DOUBLE NOT NULL, '
        'z DOUBLE NOT NULL, PRIMARY KEY (deviceId, ts))');
    await db.execute('CREATE TABLE skinTempSample (deviceId TEXT NOT NULL, '
        'ts INTEGER NOT NULL, raw INTEGER NOT NULL, PRIMARY KEY (deviceId, ts))');
    await db.execute('CREATE TABLE stepSample (deviceId TEXT NOT NULL, '
        'ts INTEGER NOT NULL, counter INTEGER NOT NULL, '
        'PRIMARY KEY (deviceId, ts))');
    if (withEmptyOptionalTables) {
      // Present but EMPTY in the real backup — the importer must read them
      // without deciding the file is unusable.
      await db.execute('CREATE TABLE spo2Sample (deviceId TEXT NOT NULL, '
          'ts INTEGER NOT NULL, red INTEGER NOT NULL, ir INTEGER NOT NULL, '
          'PRIMARY KEY (deviceId, ts))');
      await db.execute('CREATE TABLE respSample (deviceId TEXT NOT NULL, '
          'ts INTEGER NOT NULL, raw INTEGER NOT NULL, '
          'PRIMARY KEY (deviceId, ts))');
    }
    // NOOP's own scores. Note the DIFFERENT deviceId, exactly as shipped — we
    // never read these, and nothing may filter samples on a device id because of
    // it.
    await db.execute('CREATE TABLE sleepSession (deviceId TEXT NOT NULL, '
        'startTs INTEGER NOT NULL, endTs INTEGER NOT NULL, efficiency DOUBLE, '
        'restingHr INTEGER, avgHrv DOUBLE, stagesJSON TEXT, '
        'PRIMARY KEY (deviceId, startTs))');
    await db.insert('sleepSession', {
      'deviceId': '$deviceId-noop',
      'startTs': t0,
      'endTs': t0 + seconds,
      'efficiency': 0.93,
      'restingHr': 52,
      'avgHrv': 95.3,
      'stagesJSON': '[]',
    });

    final batch = db.batch();
    for (var i = 0; i < seconds; i++) {
      final ts = t0 + i;
      batch.insert('hrSample', {
        'deviceId': deviceId,
        'ts': ts,
        'bpm': 60 + (i % 20),
      });
      batch.insert('gravitySample', {
        'deviceId': deviceId,
        'ts': ts,
        'x': 0.1,
        'y': 0.2,
        'z': 0.97,
      });
      batch.insert(
          'skinTempSample', {'deviceId': deviceId, 'ts': ts, 'raw': 3240});
      batch.insert('stepSample', {
        'deviceId': deviceId,
        'ts': ts,
        'counter': 24302 + i,
      });
      if (i % 2 == 0) {
        batch.insert(
            'rrInterval', {'deviceId': deviceId, 'ts': ts, 'rrMs': 900 + i % 40});
      }
    }
    await batch.commit(noResult: true);
    await db.close();
    return path;
  }

  /// Zip [dbPath] up the way NOOP does: one member, named `noop-backup.sqlite`.
  String writeBackup(String name, String dbPath, {String? extraMember}) {
    final archive = Archive();
    final bytes = File(dbPath).readAsBytesSync();
    archive.addFile(ArchiveFile('noop-backup.sqlite', bytes.length, bytes));
    if (extraMember != null) {
      final e = [1, 2, 3];
      archive.addFile(ArchiveFile(extraMember, e.length, e));
    }
    final out = p.join(tmp.path, name);
    File(out).writeAsBytesSync(ZipEncoder().encode(archive));
    return out;
  }

  test('imports a .noopbak end to end, banking the band step counter',
      () async {
    // 2026-07-31T09:00:00Z, 40 min of 1 Hz data.
    const t0 = 1785488400;
    const secs = 2400;
    final dbPath = await writeNoopDb('a.sqlite', t0: t0, seconds: secs);
    final bak = writeBackup('backup.noopbak', dbPath);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());

    expect(res.days, greaterThan(0));
    expect(res.lateRows, 0);
    // Every 1 Hz channel row counts, so the row total dwarfs the second count.
    expect(res.rows, greaterThan(secs));
    // The band's own counter, banked as REAL steps rather than an estimate.
    expect(res.steps, secs - 1);

    final db = await LocalDb.instance;
    final cov = await db.query('live_coverage');
    expect(cov.fold<int>(0, (a, r) => a + (r['steps'] as int)), secs - 1);

    // The day derived from the backup's own samples, not from NOOP's scores.
    final days = await db.query('day_result');
    expect(days, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a WAL-mode backup with no -wal beside it still opens', () async {
    // Read-only, a WAL-mode database without its -wal/-shm fails with
    // SQLITE_CANTOPEN ("unable to open database file", code 14).
    const t0 = 1785747600; // 2026-08-03
    final dbPath = await writeNoopDb('w.sqlite', t0: t0, seconds: 600);
    final raf = File(dbPath).openSync(mode: FileMode.append);
    raf.setPositionSync(18);
    raf.writeFromSync(const [2, 2]); // the header's WAL marker
    raf.closeSync();
    // The test sqlite builds the -wal itself, so assert the copy's header
    // (what the system sqlite on iOS needs), then the import as a whole.
    final (fixed, scratch) =
        await NoopBackupImporter.repairTruncatedHeader(dbPath);
    expect(fixed, isNot(dbPath));
    expect(File(fixed).readAsBytesSync().sublist(18, 20), [1, 1]);
    expect(File(dbPath).readAsBytesSync().sublist(18, 20), [2, 2],
        reason: 'the picked file itself is never written');
    await scratch!.delete(recursive: true);

    final bak = writeBackup('w.noopbak', dbPath);
    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.steps, 599);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('re-importing the same backup does not double-count steps', () async {
    const t0 = 1785660000; // 2026-08-02
    const secs = 900;
    final dbPath = await writeNoopDb('b.sqlite', t0: t0, seconds: secs);
    final bak = writeBackup('b.noopbak', dbPath);

    final first = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(first.steps, secs - 1);

    final again = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(again.steps, 0, reason: 'the span is already covered');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the unpacked database is deleted once the import finishes', () async {
    const t0 = 1785746400; // 2026-08-03
    final dbPath = await writeNoopDb('c.sqlite', t0: t0, seconds: 120);
    final bak = writeBackup('c.noopbak', dbPath);

    // The extraction directory lives under systemTemp, which is machine-global
    // — so compare against a snapshot rather than asserting it is empty, or an
    // unrelated crashed run fails this test.
    Set<String> extractions() => Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .where((n) => n.startsWith('openstrap_noopbak_'))
        .toSet();

    final before = extractions();
    await NoopImporter.importFile(bak, const Profile(), DerivationEngine());
    // Nothing extracted survives — a 260 MB backup would otherwise leave a full
    // second copy behind on the phone.
    expect(extractions().difference(before), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('no RR beat is lost to a page boundary inside a second', () async {
    // `rrInterval`'s key is (deviceId, ts, rrMs): one second holds several
    // beats. Keyset paging on ts alone would skip whatever sits past the page
    // edge within that second — silently, and only on real-sized backups.
    const t0 = 1785832800; // 2026-08-04
    const secs = 300;
    const beatsPerSec = 4;
    final path = p.join(tmp.path, 'rr.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    await src.execute('CREATE TABLE rrInterval (deviceId TEXT, ts INTEGER, '
        'rrMs INTEGER, PRIMARY KEY (deviceId, ts, rrMs))');
    final b = src.batch();
    for (var i = 0; i < secs; i++) {
      b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i, 'bpm': 65});
      for (var k = 0; k < beatsPerSec; k++) {
        b.insert(
            'rrInterval', {'deviceId': 'd', 'ts': t0 + i, 'rrMs': 800 + k * 7});
      }
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('rr.noopbak', path);

    // A page size that cannot align to the 4-beats-per-second grid, so
    // boundaries land mid-second.
    final saved = kNoopBackupPageRows;
    kNoopBackupPageRows = 7;
    addTearDown(() => kNoopBackupPageRows = saved);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.rows, secs + secs * beatsPerSec,
        reason: 'every HR sample and every RR beat was read');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a non-finite interval from the database is not a beat', () async {
    // sqflite returns NULL for a NaN REAL, so `_num` already drops it before
    // the guard — but INFINITY comes back as a real double and reaches `rr()`.
    // (The NaN path proper is exercised through the CSV importer, where
    // `double.tryParse('NaN')` genuinely produces one — see
    // noop_schema_drift_test.dart.)
    const t0 = 1786608000; // 2026-08-13, a day no other fixture here uses
    final path = p.join(tmp.path, 'nan.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    await src.execute('CREATE TABLE rrInterval (deviceId TEXT, ts INTEGER, '
        'rrMs REAL, PRIMARY KEY (deviceId, ts, rrMs))');
    final b = src.batch();
    // 600 beats: the irregular-rhythm screen (the one payload field that
    // reports how many beats it actually used) needs a real window before it
    // emits anything, and without it there is nothing to assert on.
    for (var i = 0; i < 600; i++) {
      b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i, 'bpm': 65});
      b.insert('rrInterval', {
        'deviceId': 'd',
        'ts': t0 + i,
        // Varied on purpose: a constant series has SD2 = 0 and the
        // irregular-rhythm screen abstains, leaving no beat count to assert on.
        'rrMs': i == 300 ? double.infinity : 880.0 + (i % 41),
      });
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('nan.noopbak', path);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.days, greaterThan(0), reason: 'the day still imports');

    // The beat COUNT is what discriminates — the row's typed columns hold no
    // derived metric at all, so sweeping them for a non-finite double passes
    // whatever the guard does. 120 beats written, one of them infinite.
    final day = _localDay(t0);
    final db = await LocalDb.instance;
    final rows =
        await db.query('day_result', where: 'day_id = ?', whereArgs: [day]);
    var checked = 0;
    for (final r in rows) {
      final n = _beatsUsed(r);
      if (n == null) continue;
      expect(n, 599, reason: 'the infinite beat is dropped, not counted');
      checked++;
    }
    expect(checked, greaterThan(0), reason: 'the assertion must have run');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a database that is not a NOOP backup is named, not silently empty',
      () async {
    final path = p.join(tmp.path, 'other.sqlite');
    final db = await databaseFactory.openDatabase(path);
    await db.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)');
    await db.close();
    final bak = writeBackup('other.noopbak', path);

    await expectLater(
      NoopImporter.importFile(bak, const Profile(), DerivationEngine()),
      throwsA(isA<ImportFormatException>()
          .having((e) => e.message, 'message', contains('hrSample'))),
    );
  });

  test('one corrupt timestamp does not disqualify the whole table', () async {
    // MIN/MAX collapse a table to two rows, so a single `ts = 0` used to drop
    // that table from the span entirely — and if every table has one, a backup
    // holding years of data imports as "no samples".
    const t0 = 1786003200; // 2026-08-06
    final path = p.join(tmp.path, 'corrupt.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    final b = src.batch();
    b.insert('hrSample', {'deviceId': 'd', 'ts': 0, 'bpm': 60}); // corrupt
    for (var i = 0; i < 300; i++) {
      b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i, 'bpm': 62});
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('corrupt.noopbak', path);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.days, greaterThan(0));
    expect(res.rows, 300, reason: 'the good rows import, the corrupt one does not');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a long gap between blocks still derives the later day', () async {
    // The prior-evening buffer used to be retained across ANY gap, handing the
    // next day a Substrate spanning the whole thing. `calendarDays` walks that
    // span a day at a time under a 400-iteration guard, so past ~400 days it
    // never reaches the target date: the day is missing and the import still
    // reports success.
    const first = 1690000000; // 2023-07
    const later = first + 500 * 86400;
    final path = p.join(tmp.path, 'gap.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    final b = src.batch();
    for (final t0 in const [first, later]) {
      for (var i = 0; i < 3600; i++) {
        b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i, 'bpm': 62});
      }
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('gap.noopbak', path);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.days, 2, reason: 'both blocks derive, 500 days apart');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a REAL timestamp column cannot hang the paging', () async {
    // A GRDB `Date` is stored as a REAL. Sub-second values truncate onto the
    // same second, which left the page cursor exactly where it was — an
    // infinite loop, and every RR beat in the page re-appended on each pass.
    const t0 = 1786089600; // 2026-08-07
    final path = p.join(tmp.path, 'real.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts REAL, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    final b = src.batch();
    var n = 0;
    for (var i = 0; i < 40; i++) {
      // Several fractional samples inside each second.
      for (final frac in const [0.2, 0.4, 0.6, 0.8]) {
        b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i + frac, 'bpm': 60});
        n++;
      }
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('real.noopbak', path);

    final saved = kNoopBackupPageRows;
    kNoopBackupPageRows = 4;
    addTearDown(() => kNoopBackupPageRows = saved);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    // EXACT: `lessThanOrEqualTo` would pass on an importer that read one row.
    // Duplication and loss are both real failure modes here — the fallback path
    // drains a whole second rather than stepping past it precisely so that the
    // count can be exact.
    expect(res.rows, n);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a fractional timestamp at midnight is not read by both days', () async {
    // The day windows are half-open, but `ts > from - 1` only expresses that
    // for integral timestamps: against a fractional one the interval
    // (midnight-1, midnight) belongs to the day before AND the day after. The
    // map-keyed channels absorb the double read; `rr()` appends, so the night
    // gets a duplicate beat and its RMSSD is wrong.
    final midnight = DateTime(2026, 8, 5).millisecondsSinceEpoch ~/ 1000;
    final path = p.join(tmp.path, 'straddle.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts REAL, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    await src.execute('CREATE TABLE rrInterval (deviceId TEXT, ts REAL, '
        'rrMs REAL, PRIMARY KEY (deviceId, ts, rrMs))');
    final b = src.batch();
    var expected = 0;
    // 20 min either side of midnight, every sample on a .5 offset.
    for (var i = -1200; i < 1200; i++) {
      final ts = midnight + i + 0.5;
      b.insert('hrSample', {'deviceId': 'd', 'ts': ts, 'bpm': 60});
      b.insert('rrInterval', {'deviceId': 'd', 'ts': ts, 'rrMs': 900.0});
      expected += 2;
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('straddle.noopbak', path);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.rows, expected,
        reason: 'every sample is read exactly once, on exactly one day');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a renamed column is a message, not a raw SQL error mid-import',
      () async {
    const t0 = 1786176000; // 2026-08-08
    final path = p.join(tmp.path, 'renamed.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    // spo2Sample exists but has drifted — the table this code documents as
    // never observed non-empty, i.e. the one least confirmed.
    await src.execute('CREATE TABLE spo2Sample (deviceId TEXT, ts INTEGER, '
        'redRaw INTEGER, irRaw INTEGER, PRIMARY KEY (deviceId, ts))');
    final b = src.batch();
    for (var i = 0; i < 300; i++) {
      b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i, 'bpm': 61});
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('renamed.noopbak', path);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.days, greaterThan(0),
        reason: 'the drifted table is skipped, the rest still imports');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('an optional table with no ts column does not break the span', () async {
    // `_span` selects MIN(ts)/MAX(ts). Running it before the column probe threw
    // a raw SQL error out of a table the probe exists to skip.
    const t0 = 1786694400; // 2026-08-14
    final path = p.join(tmp.path, 'nots.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    // Drifted beyond recognition: no `ts` at all.
    await src.execute('CREATE TABLE spo2Sample (deviceId TEXT, '
        'recordedAt INTEGER, red INTEGER, ir INTEGER)');
    await src.insert('spo2Sample',
        {'deviceId': 'd', 'recordedAt': t0, 'red': 1, 'ir': 2});
    final b = src.batch();
    for (var i = 0; i < 300; i++) {
      b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i, 'bpm': 63});
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('nots.noopbak', path);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.days, greaterThan(0));
    expect(res.rows, 300);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('an hrSample without bpm is refused, not quietly imported', () async {
    // The table-name check passes, then every read skips it — the remaining
    // channels would carry the import to a plausible day count with no heart
    // rate anywhere in it.
    const t0 = 1786780800; // 2026-08-15
    final path = p.join(tmp.path, 'nobpm.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'heartRate INTEGER, PRIMARY KEY (deviceId, ts))');
    await src.execute('CREATE TABLE gravitySample (deviceId TEXT, ts INTEGER, '
        'x DOUBLE, y DOUBLE, z DOUBLE, PRIMARY KEY (deviceId, ts))');
    final b = src.batch();
    for (var i = 0; i < 300; i++) {
      b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i, 'heartRate': 63});
      b.insert('gravitySample',
          {'deviceId': 'd', 'ts': t0 + i, 'x': 0.1, 'y': 0.2, 'z': 0.97});
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('nobpm.noopbak', path);

    await expectLater(
      NoopImporter.importFile(bak, const Profile(), DerivationEngine()),
      throwsA(isA<ImportFormatException>()
          .having((e) => e.message, 'message', contains('heart rate'))),
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a timestamp with more rows than a page loses none to the drain',
      () async {
    // The drain pages an equal-timestamp group with OFFSET. Two queries whose
    // ORDER BY is not a total order can hand back that group in different
    // orders, and the offset then skips and repeats — silent duplicate beats
    // in the append-only RR channel.
    const t0 = 1786867200; // 2026-08-16
    const beats = 25; // > the page size set below
    final path = p.join(tmp.path, 'drain.sqlite');
    if (File(path).existsSync()) File(path).deleteSync();
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    await src.execute('CREATE TABLE rrInterval (deviceId TEXT, ts INTEGER, '
        'rrMs REAL, PRIMARY KEY (deviceId, ts, rrMs))');
    final b = src.batch();
    var expected = 0;
    for (var i = 0; i < 60; i++) {
      b.insert('hrSample', {'deviceId': 'd', 'ts': t0 + i, 'bpm': 64});
      expected++;
    }
    // One second carrying far more beats than a page holds, inserted in a
    // scrambled rrMs order so a naive tie order differs from insertion order.
    for (var k = 0; k < beats; k++) {
      final rr = 700.0 + ((k * 37) % beats);
      b.insert('rrInterval', {'deviceId': 'd', 'ts': t0 + 30, 'rrMs': rr});
      expected++;
    }
    await b.commit(noResult: true);
    await src.close();
    final bak = writeBackup('drain.noopbak', path);

    final saved = kNoopBackupPageRows;
    kNoopBackupPageRows = 8;
    addTearDown(() => kNoopBackupPageRows = saved);

    final res = await NoopImporter.importFile(
        bak, const Profile(), DerivationEngine());
    expect(res.rows, expected,
        reason: 'every row read exactly once, drain included');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a backup with no samples says so rather than importing 0 days',
      () async {
    final path = p.join(tmp.path, 'empty.sqlite');
    final db = await databaseFactory.openDatabase(path);
    await db.execute('CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, '
        'bpm INTEGER, PRIMARY KEY (deviceId, ts))');
    await db.close();
    final bak = writeBackup('empty.noopbak', path);

    await expectLater(
      NoopImporter.importFile(bak, const Profile(), DerivationEngine()),
      throwsA(isA<ImportFormatException>()
          .having((e) => e.message, 'message', contains('no samples'))),
    );
  });

  // OpenStrap/edge — a real `.noopbak` off a phone (NOOP 10.5.0, WHOOP 5.0/MG)
  // failed to open at all: `PRAGMA quick_check` reported "invalid page
  // number" across most tables, on a zip whose own declared uncompressed size
  // also undercounted its content (see import_container_test.dart for that
  // half). The backup was taken by copying NOOP's live database file rather
  // than through a proper backup API, which left two DIFFERENT kinds of
  // damage: a stale page-count header (bytes 28-31) that undercounted how
  // many pages the file actually holds, on top of genuinely torn B-tree pages
  // scattered through several tables' own storage. The two tests below pin
  // both, on a synthetic fixture (never the real file — see the memory note
  // on personal health data in fixtures). On the real file, EVERY populated
  // 1 Hz table had at least one torn page, so nothing below `dailyMetric` /
  // `sleepSession` (deliberately not read — see this file's header) survived;
  // the second test below still confirms the degradation is per-table, not
  // total, on a fixture with exactly one bad page.

  test('a stale page-count header self-heals and imports in full', () async {
    // Big enough to spread hrSample across several real pages, the same
    // shape the header lie has to actually matter for. A date no other
    // fixture in this file uses (they share one LocalDb across tests).
    const t0 = 1786953600; // 2026-08-17
    const secs = 6000;
    final dbPath = await writeNoopDb('stale_header.sqlite', t0: t0, seconds: secs);

    // Patch the header exactly the way the real bug left it: the file holds
    // more whole pages than byte 28-31 claims.
    final bytes = File(dbPath).readAsBytesSync();
    final pageSize = (bytes[16] << 8) | bytes[17];
    final actualPages = bytes.length ~/ pageSize;
    expect(actualPages, greaterThan(4),
        reason: 'fixture must span multiple pages for this to test anything');
    final understated = actualPages - 2;
    final patched = Uint8List.fromList(bytes);
    patched[28] = (understated >> 24) & 0xff;
    patched[29] = (understated >> 16) & 0xff;
    patched[30] = (understated >> 8) & 0xff;
    patched[31] = understated & 0xff;
    File(dbPath).writeAsBytesSync(patched);

    final bak = writeBackup('stale_header.noopbak', dbPath);
    final res = await NoopImporter.importFile(bak, const Profile(), DerivationEngine());

    // A header lie, not row damage — every row is recovered, on every table.
    expect(res.rows, secs * 4 + (secs / 2).ceil()); // hr+gravity+skinTemp+step, rr every other second
    expect(res.corruptTables, isEmpty);
  });

  test('a torn page loses only its own table, not the whole import',
      () async {
    const t0 = 1787040000; // 2026-08-18, distinct from every other fixture here
    const secs = 6000; // enough rows that hrSample spans several leaf pages
    final dbPath = await writeNoopDb('torn_page.sqlite', t0: t0, seconds: secs);

    // Find a real hrSample leaf page and scramble it — the same shape as a
    // torn write, not merely an absent one: an all-zero page is a VALID empty
    // leaf, so this has to write bytes that are not a legal btree page type.
    final probe = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final rows = await probe.rawQuery(
      "SELECT pageno FROM dbstat('main') WHERE name = 'hrSample' AND pagetype = 'leaf' ORDER BY pageno",
    );
    await probe.close();
    expect(rows.length, greaterThan(2),
        reason: 'fixture must span multiple leaf pages for this to test anything');
    // WHICH leaf doesn't matter, and that is the point: none of these tables
    // carry an index that covers the extra columns `_read` selects (bpm, x/y/z,
    // …) alongside `ts`, so a day-windowed read has to scan hrSample's WHOLE
    // table before it can emit a single (ordered) row. One bad page anywhere
    // fails that scan for EVERY day identically — this is not "the newest
    // rows are lost", it is "this whole channel is lost, every other one
    // survives".
    final targetPage = (rows[rows.length ~/ 2]['pageno'] as int);

    final raw = File(dbPath).readAsBytesSync();
    final pageSize = (raw[16] << 8) | raw[17];
    final patched = Uint8List.fromList(raw);
    final offset = (targetPage - 1) * pageSize;
    patched.fillRange(offset, offset + pageSize, 0xFF); // not a valid page type
    File(dbPath).writeAsBytesSync(patched);

    final bak = writeBackup('torn_page.noopbak', dbPath);
    final res = await NoopImporter.importFile(bak, const Profile(), DerivationEngine());

    expect(res.corruptTables, {'hrSample'});
    // hrSample itself contributes NOTHING — gravity+skinTemp+step (3 * secs)
    // and rr (every other second) still land in full.
    expect(res.rows, secs * 3 + (secs / 2).ceil());
    expect(res.days, greaterThan(0));
  });
}
