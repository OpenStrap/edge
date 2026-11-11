// The Sleep screen used to tell a fresh install, and any night the band was
// never worn, that "this night's detailed recordings are no longer on the
// phone". Both are uncorrectable because there is no substrate, but only a
// day the raw prune has actually cut may say its recordings were removed.
// `LocalDb.decodedPrunedFor` is that distinction.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_sleep_recordings_pruned_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  setUp(() async {
    await (await LocalDb.instance)
        .delete('sync_cursor', where: 'name = ?', whereArgs: [
      LocalDb.kDecodedPrunedBeforeCursor,
    ]);
  });

  test('nothing pruned yet (a fresh install): no day counts as pruned',
      () async {
    expect(await LocalDb.decodedPrunedFor(todayLabel()), isFalse);
    expect(await LocalDb.decodedPrunedFor('2020-01-01'), isFalse);
  });

  test('days before the cut are pruned; the cut day and later are not',
      () async {
    // The prune only ever cuts at a local midnight.
    await LocalDb.setCursor(LocalDb.kDecodedPrunedBeforeCursor,
        '${localDayStartSec('2026-06-10')}');

    expect(await LocalDb.decodedPrunedFor('2026-06-09'), isTrue);
    expect(await LocalDb.decodedPrunedFor('2026-06-10'), isFalse);
    expect(await LocalDb.decodedPrunedFor('2026-06-11'), isFalse);
  });

  test('an imported day before the cut never had recordings to prune',
      () async {
    await LocalDb.setCursor(LocalDb.kDecodedPrunedBeforeCursor,
        '${localDayStartSec('2026-06-10')}');
    final db = await LocalDb.instance;
    await db.insert('metric_series_version',
        {'date': '2026-06-08', 'algo_version': 1, 'source': 'whoop_csv'});
    addTearDown(() => db.delete('metric_series_version'));

    expect(await LocalDb.decodedPrunedFor('2026-06-08'), isFalse);
    expect(await LocalDb.decodedPrunedFor('2026-06-09'), isTrue);
  });

  test('a malformed day label is never reported as pruned', () async {
    await LocalDb.setCursor(LocalDb.kDecodedPrunedBeforeCursor,
        '${localDayStartSec('2026-06-10')}');

    expect(await LocalDb.decodedPrunedFor('not-a-day'), isFalse);
  });
}
