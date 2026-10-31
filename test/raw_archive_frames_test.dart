// raw_archive stores each undecodable frame once, as bytes, keyed by a hash of
// them. The old table kept it as hex TEXT under PRIMARY KEY (device_id, hex)
// on a rowid table, so the hex was stored twice. This pins: readers still see
// the exact hex they always did, dedup still holds, text that is not
// canonical hex survives verbatim, and an existing archive moves across in
// pages without losing or duplicating a frame.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

const _frameBytes = 2128; // a WHOOP MG v20 frame

String _frameHex(int seed) {
  final r = math.Random(seed);
  final b = StringBuffer();
  for (var i = 0; i < _frameBytes; i++) {
    b.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

ArchiveRecord _rec(int counter, String hex, {String reason = 'undecodable_rec_v20'}) =>
    ArchiveRecord(
      counter: counter,
      hex: hex,
      packetType: 0x2F,
      capturedAt: 1750000000000 + counter * 1000,
      reason: reason,
    );

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Future<void> _fresh(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(await _path(name));
}

Future<List<Map<String, Object?>>> _viewRows() async =>
    (await LocalDb.instance).rawQuery(
      'SELECT device_id, hex, counter, packet_type, rec_ts, captured_at, '
      'reason FROM ${LocalDb.rawArchiveView} ORDER BY device_id, hex',
    );

Future<int> _bytes(Database db, List<String> names) async {
  final marks = List.filled(names.length, '?').join(',');
  final r = await db.rawQuery(
    'SELECT SUM(pgsize) AS b FROM dbstat WHERE name IN ($marks)',
    names,
  );
  return (r.first['b'] as num?)?.toInt() ?? 0;
}

/// A database as the previous build left it: user_version 58 and the
/// hex-keyed table, with [rows] in it.
Future<void> _legacyDb(String name, List<Map<String, Object?>> rows) async {
  await _fresh(name);
  final db = await databaseFactory.openDatabase(await _path(name),
      options: OpenDatabaseOptions(
        version: LocalDb.schemaVersion,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE raw_archive (
              device_id TEXT NOT NULL DEFAULT '',
              hex TEXT NOT NULL,
              counter INTEGER,
              packet_type INTEGER NOT NULL,
              rec_ts INTEGER,
              captured_at INTEGER NOT NULL,
              reason TEXT NOT NULL,
              PRIMARY KEY (device_id, hex)
            )
          ''');
          await db.execute('CREATE INDEX idx_raw_archive_captured '
              'ON raw_archive(captured_at DESC)');
        },
      ));
  final batch = db.batch();
  for (final r in rows) {
    batch.insert('raw_archive', r);
  }
  await batch.commit(noResult: true);
  await db.close();
}

Map<String, Object?> _legacyRow(String device, String hex, int counter) => {
      'device_id': device,
      'hex': hex,
      'counter': counter,
      'packet_type': 0x2F,
      'rec_ts': null,
      'captured_at': 1750000000000 + counter,
      'reason': 'undecodable_rec_v20',
    };

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async => LocalDb.close());

  test('a frame is stored once, as bytes, and reads back as its hex', () async {
    await _fresh('raw_frames_store.db');
    final a = _frameHex(1), b = _frameHex(2);
    await LocalDb.commitSyncBatch(const [], const [],
        archives: [_rec(1, a), _rec(2, b), _rec(3, a)]);
    await LocalDb.archiveRawRecord(_rec(4, b)); // a re-flood, other path
    final rows = await _viewRows();
    expect([for (final r in rows) r['hex']], unorderedEquals([a, b]));
    final db = await LocalDb.instance;
    final stored = await db.query(LocalDb.rawArchiveTable);
    expect(stored, hasLength(2));
    for (final r in stored) {
      expect(r['hex'], isNull);
      expect((r['frame'] as List).length, _frameBytes);
      expect((r['hash'] as List).length, 20);
    }
  });

  test('text that is not canonical hex is kept verbatim', () async {
    await _fresh('raw_frames_text.db');
    const odd = ['ABCDEF', 'abc', 'not hex at all', 'Deadbeef'];
    await LocalDb.commitSyncBatch(const [], const [],
        archives: [for (var i = 0; i < odd.length; i++) _rec(i, odd[i])]);
    expect([for (final r in await _viewRows()) r['hex']],
        unorderedEquals(odd));
  });

  test('two devices keep their own copy of a byte-identical frame', () async {
    await _fresh('raw_frames_devices.db');
    final hex = _frameHex(9);
    await LocalDb.archiveRawRecord(_rec(1, hex));
    await LocalDb.archiveRawRecord(_rec(1, hex), deviceId: 'ring-1');
    expect(await _viewRows(), hasLength(2));
  });

  test('plain inserts and deletes on the old name still work', () async {
    await _fresh('raw_frames_compat.db');
    final db = await LocalDb.instance;
    await db.insert(LocalDb.rawArchiveView, _legacyRow('', 'beef', 7));
    await db.insert(LocalDb.rawArchiveView, _legacyRow('', 'beef', 7),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    expect(await _viewRows(), hasLength(1));
    await db.delete(LocalDb.rawArchiveView, where: 'hex = ?', whereArgs: ['beef']);
    expect(await _viewRows(), isEmpty);
  });

  test('an existing archive moves across in pages, losing nothing', () async {
    final rows = [
      for (var i = 0; i < 1203; i++)
        _legacyRow(i % 7 == 0 ? 'ring-1' : '', _frameHex(100 + i), i),
      _legacyRow('', 'Not-Hex', 5000),
    ];
    await _legacyDb('raw_frames_migrate.db', rows);
    final expected = [
      for (final r in rows)
        '${r['device_id']}|${r['hex']}|${r['counter']}|${r['captured_at']}',
    ]..sort();
    Future<List<String>> seen() async => [
          for (final r in await _viewRows())
            '${r['device_id']}|${r['hex']}|${r['counter']}|${r['captured_at']}',
        ]..sort();

    // Opening renames the table aside; the view already shows every row.
    expect(await seen(), expected);
    final db = await LocalDb.instance;
    // The table and its key's autoindex, whatever the rename called it.
    final legacyIndex = [
      for (final r in await db.rawQuery("SELECT name FROM sqlite_master "
          "WHERE type = 'index' AND tbl_name = 'raw_archive_legacy'"))
        r['name'] as String,
    ];
    expect(legacyIndex, isNotEmpty);
    final legacyBytes =
        await _bytes(db, ['raw_archive_legacy', ...legacyIndex]);

    // A frame arriving mid-move, already in the legacy table: one copy after.
    await LocalDb.archiveRawRecord(_rec(1, rows[1]['hex'] as String));

    // One page per call, a frame lands between calls, and the pass resumes.
    var calls = 0;
    while (await LocalDb.migrateLegacyRawArchive(budget: Duration.zero) > 0) {
      calls++;
      if (calls == 1) {
        await LocalDb.archiveRawRecord(_rec(9999, _frameHex(9999)));
        expected.add('|${_frameHex(9999)}|9999|${1750000000000 + 9999000}');
        expected.sort();
      }
    }
    expect(calls, greaterThanOrEqualTo(3));
    expect(
      await db.rawQuery("SELECT 1 FROM sqlite_master WHERE name = 'raw_archive_legacy'"),
      isEmpty,
    );
    final view = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE name = '${LocalDb.rawArchiveView}'");
    expect('${view.single['sql']}', isNot(contains('legacy')));
    final after = await seen();
    // The mid-move duplicate collapsed; counter differs, so compare keys.
    expect(after.map((s) => s.split('|').take(2).join('|')).toList(),
        expected.map((s) => s.split('|').take(2).join('|')).toList());
    expect(after.length, expected.length);

    final newBytes = await _bytes(db, [
      LocalDb.rawArchiveTable,
      for (final r in await db.rawQuery("SELECT name FROM sqlite_master "
          "WHERE type = 'index' AND tbl_name = ?", [LocalDb.rawArchiveTable]))
        r['name'] as String,
    ]);
    // ignore: avoid_print
    print('raw_archive: ${rows.length} frames, legacy ${legacyBytes >> 10} KiB'
        ' -> ${newBytes >> 10} KiB '
        '(${(legacyBytes / rows.length).round()} -> '
        '${(newBytes / after.length).round()} bytes/frame)');
    // A 2.2 KB row cannot share a 4 KB page with another, so a frame costs a
    // page; the hex row and its key copy cost two and change.
    expect(newBytes, lessThan(legacyBytes * 0.55));

    // Reopening a converted database changes nothing.
    await LocalDb.close();
    expect(await seen(), after);
  });

  test('the move stops after a page once an offload starts', () async {
    await _legacyDb('raw_frames_offload.db', [
      for (var i = 0; i < 1200; i++) _legacyRow('', _frameHex(100 + i), i),
    ]);
    // No time budget: only the offload signal can stop it early.
    expect(await LocalDb.migrateLegacyRawArchive(shouldStop: () => true), 500);
    expect(await LocalDb.migrateLegacyRawArchive(), 700);
  });

  test('an older build can still open the file, and its frames come back',
      () async {
    await _fresh('raw_frames_rollback.db');
    await LocalDb.close();
    LocalDb.dbName = 'raw_frames_rollback.db';
    await LocalDb.archiveRawRecord(_rec(1, _frameHex(1)));
    await LocalDb.close();
    // What the build before this layout runs on every open, verbatim. With
    // a view named raw_archive the index line failed ("views may not be
    // indexed") and the open with it.
    final old = await databaseFactory.openDatabase(
        await _path('raw_frames_rollback.db'));
    await old.execute('''
      CREATE TABLE IF NOT EXISTS raw_archive (
        device_id TEXT NOT NULL DEFAULT '',
        hex TEXT NOT NULL,
        counter INTEGER,
        packet_type INTEGER NOT NULL,
        rec_ts INTEGER,
        captured_at INTEGER NOT NULL,
        reason TEXT NOT NULL,
        PRIMARY KEY (device_id, hex)
      )
    ''');
    await old.execute('CREATE INDEX IF NOT EXISTS idx_raw_archive_captured '
        'ON raw_archive(captured_at DESC)');
    // The old build archives a frame of its own.
    await old.insert('raw_archive', _legacyRow('', _frameHex(2), 2));
    await old.close();

    // Back on this build: both frames are there.
    final keys = [
      for (final r in await (await LocalDb.instance).rawQuery(
          'SELECT hex FROM ${LocalDb.rawArchiveView} ORDER BY hex'))
        r['hex'],
    ];
    expect(keys, [_frameHex(1), _frameHex(2)]..sort());
  });

  test('a backup of the new layout restores every frame', () async {
    await _fresh('raw_frames_backup_src.db');
    final frames = [_frameHex(1), 'Not-Hex', _frameHex(2)];
    await LocalDb.commitSyncBatch(const [], const [],
        archives: [for (var i = 0; i < frames.length; i++) _rec(i, frames[i])]);
    final before = await _viewRows();
    final copy = await LocalDb.exportCopy(
        into: Directory.systemTemp.createTempSync('raw_frames'));
    await _fresh('raw_frames_backup_dst.db');
    await LocalDb.importFromDbFile(copy);
    expect(await _viewRows(), before);
  });

  test('thinning keeps the same 1-in-60 sample in both tables', () async {
    final rows = [
      for (var i = 0; i < 240; i++) _legacyRow('', _frameHex(i), i),
    ];
    await _legacyDb('raw_frames_thin.db', rows);
    await LocalDb.instance;
    // Half moved, half still aside, when the retention pass thins.
    await LocalDb.migrateLegacyRawArchive(budget: Duration.zero);
    final deleted = await LocalDb.thinRawArchiveBefore(1750000000000 + 1000);
    expect(deleted, 240 - 4); // counters 0, 60, 120, 180 stay
    expect([for (final r in await _viewRows()) r['counter']]..sort(),
        [0, 60, 120, 180]);
  });
}
