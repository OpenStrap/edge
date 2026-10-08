// Rows stranded under a dead device_id are moved onto the row that lived.
//
// Pairing minted a fresh `<family>-xxxxxxxx` every run, so re-pairing one
// physical ring forked it into N identities and every earlier pairing's rows
// were left under an id no `device` row points at — unreachable, because every
// reader starts from a `device` row. Seen on a real phone: a `device` row
// `oura-a4487268` beside 96,521 `raw_archive` frames and 1,765 `decoded_onehz`
// rows under `oura-7e117c66`.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

Future<Database> _open() async {
  final dir = await databaseFactory.getDatabasesPath();
  final path = p.join(dir, 'reunite_test_${DateTime.now().microsecondsSinceEpoch}.db');
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(path);
  // The shapes this heal touches, reduced to the columns it keys on.
  await db.execute('CREATE TABLE device (id TEXT PRIMARY KEY, adapter_id TEXT)');
  await db.execute('CREATE TABLE decoded_onehz ('
      "device_id TEXT NOT NULL DEFAULT '', ts_ms INTEGER NOT NULL DEFAULT 0, "
      'hr INTEGER, PRIMARY KEY (device_id, ts_ms))');
  await db.execute('CREATE TABLE raw_archive ('
      "device_id TEXT NOT NULL DEFAULT '', hex TEXT NOT NULL, "
      'PRIMARY KEY (device_id, hex))');
  await db.execute('CREATE TABLE sync_cursor ('
      'name TEXT PRIMARY KEY, value TEXT, updated_at INTEGER)');
  return db;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('a stranded id is reunited with the surviving row of its family',
      () async {
    final db = await _open();
    await db.insert('device', {'id': 'oura-a4487268', 'adapter_id': 'oura'});
    await db.insert('decoded_onehz',
        {'device_id': 'oura-7e117c66', 'ts_ms': 1000, 'hr': 55});
    await db.insert('raw_archive', {'device_id': 'oura-7e117c66', 'hex': 'ab'});
    await db.insert('sync_cursor',
        {'name': 'oura_cursor_ds:oura-7e117c66', 'value': '42'});

    expect(await LocalDb.reuniteStrandedDeviceRows(db), 1);

    expect(
      (await db.query('decoded_onehz')).single['device_id'],
      'oura-a4487268',
    );
    expect(
      (await db.query('raw_archive')).single['device_id'],
      'oura-a4487268',
    );
    // The bookmark is DROPPED, never carried: a stranded id cannot be shown to
    // be the same physical ring, and a foreign origin mis-stamps every second.
    expect(await db.query('sync_cursor'), isEmpty);
    await db.close();
  });

  test('re-running is a no-op — nothing is left to match', () async {
    final db = await _open();
    await db.insert('device', {'id': 'oura-a4487268', 'adapter_id': 'oura'});
    await db.insert('decoded_onehz',
        {'device_id': 'oura-7e117c66', 'ts_ms': 1000, 'hr': 55});

    expect(await LocalDb.reuniteStrandedDeviceRows(db), 1);
    expect(await LocalDb.reuniteStrandedDeviceRows(db), 0);
    await db.close();
  });

  test('the primary band is never re-keyed', () async {
    final db = await _open();
    await db.insert('device', {'id': 'oura-a4487268', 'adapter_id': 'oura'});
    // kPrimaryDeviceId: no family separator, so it can never be a candidate.
    await db.insert(
        'decoded_onehz', {'device_id': '', 'ts_ms': 1000, 'hr': 55});

    expect(await LocalDb.reuniteStrandedDeviceRows(db), 0);
    expect((await db.query('decoded_onehz')).single['device_id'], '');
    await db.close();
  });

  test('a stranded id is never moved across families', () async {
    final db = await _open();
    await db.insert('device', {'id': 'oura-a4487268', 'adapter_id': 'oura'});
    await db.insert('decoded_onehz',
        {'device_id': 'o2ring-deadbeef', 'ts_ms': 1000, 'hr': 55});

    expect(await LocalDb.reuniteStrandedDeviceRows(db), 0);
    expect(
      (await db.query('decoded_onehz')).single['device_id'],
      'o2ring-deadbeef',
    );
    await db.close();
  });

  // Two rows in one family means there is no single answer to "which device is
  // this", and picking one would merge two devices' measurements into one
  // history — a fabricated number by a slower route.
  test('an ambiguous family is left completely alone', () async {
    final db = await _open();
    await db.insert('device', {'id': 'oura-aaaaaaaa', 'adapter_id': 'oura'});
    await db.insert('device', {'id': 'oura-bbbbbbbb', 'adapter_id': 'oura'});
    await db.insert('decoded_onehz',
        {'device_id': 'oura-7e117c66', 'ts_ms': 1000, 'hr': 55});

    expect(await LocalDb.reuniteStrandedDeviceRows(db), 0);
    expect(
      (await db.query('decoded_onehz')).single['device_id'],
      'oura-7e117c66',
    );
    await db.close();
  });

  // The collision the UPDATE OR IGNORE + delete exists for: a constraint
  // failure here would roll back onUpgrade's one exclusive transaction and
  // quarantine the database (invariant 11). The surviving id's row wins, so a
  // value already on screen never changes.
  test('a colliding key keeps the surviving row instead of aborting',
      () async {
    final db = await _open();
    await db.insert('device', {'id': 'oura-a4487268', 'adapter_id': 'oura'});
    await db.insert('decoded_onehz',
        {'device_id': 'oura-a4487268', 'ts_ms': 1000, 'hr': 55});
    await db.insert('decoded_onehz',
        {'device_id': 'oura-7e117c66', 'ts_ms': 1000, 'hr': 61});

    expect(await LocalDb.reuniteStrandedDeviceRows(db), 1);
    final rows = await db.query('decoded_onehz');
    expect(rows.length, 1);
    expect(rows.single['device_id'], 'oura-a4487268');
    expect(rows.single['hr'], 55);
    await db.close();
  });

  test('only the stranded id\'s own bookmarks are dropped', () async {
    final db = await _open();
    await db.insert('device', {'id': 'oura-a4487268', 'adapter_id': 'oura'});
    await db.insert('decoded_onehz',
        {'device_id': 'oura-7e117c66', 'ts_ms': 1000, 'hr': 55});
    for (final name in [
      'oura_cursor_ds:oura-7e117c66',
      'oura_cursor_ds:oura-a4487268',
      'oura_cursor_ds:xoura-7e117c66',
      'oura_cursor_ds:OURA-7E117C66',
    ]) {
      await db.insert('sync_cursor', {'name': name, 'value': '1'});
    }

    expect(await LocalDb.reuniteStrandedDeviceRows(db), 1);
    expect(
      (await db.query('sync_cursor', orderBy: 'name'))
          .map((r) => r['name'])
          .toList(),
      [
        'oura_cursor_ds:OURA-7E117C66',
        'oura_cursor_ds:oura-a4487268',
        'oura_cursor_ds:xoura-7e117c66',
      ],
    );
    await db.close();
  });
}
