// Restoring an older backup must not move this install's sync_cursor
// bookkeeping backwards. The prune edge (`decoded_pruned_before`) is only ever
// raised; a restore that lowered it made the derive engine treat a restored
// day whose rows stop at the backup moment as complete, and re-derive it over
// its finalized full-day result.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';

int _midnight(DateTime d) =>
    DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;

String _label(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Future<String> _backup(String name, Map<String, String> cursors) async {
  final dir = await databaseFactory.getDatabasesPath();
  final path = p.join(dir, name);
  await databaseFactory.deleteDatabase(path);
  final src = await databaseFactory.openDatabase(path);
  await src.execute('CREATE TABLE sync_cursor (name TEXT PRIMARY KEY, '
      'value TEXT, updated_at INTEGER NOT NULL)');
  for (final e in cursors.entries) {
    await src.insert(
        'sync_cursor', {'name': e.key, 'value': e.value, 'updated_at': 1});
  }
  await src.close();
  return path;
}

void main() {
  final today = DateTime.now();
  final local = _midnight(today.subtract(const Duration(days: 5)));
  final older = _midnight(today.subtract(const Duration(days: 15)));
  final newer = _midnight(today.subtract(const Duration(days: 2)));

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_restore_sync_cursor_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    for (final f in ['openstrap_restore_sync_cursor_test.db', 'old.db', 'new.db']) {
      try {
        File(p.join(dir, f)).deleteSync();
      } catch (_) {}
    }
  });

  test('an older backup leaves the prune edge and derive bookkeeping alone',
      () async {
    await LocalDb.setCursor(LocalDb.kDecodedPrunedBeforeCursor, '$local');
    await LocalDb.setCursor('baseline_sig', 'local-sig');
    final path = await _backup('old.db', {
      LocalDb.kDecodedPrunedBeforeCursor: '$older',
      'baseline_sig': 'backup-sig',
      'health_export_through': '2026-01-01',
    });

    await LocalDb.importFromDbFile(path);

    final after =
        await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor);
    expect(after, local);
    expect(await LocalDb.getCursor('baseline_sig'), 'local-sig');
    // A key this install never had still comes across.
    expect(await LocalDb.getCursor('health_export_through'), '2026-01-01');
    // The restored day ten days back still reads as truncated, so the
    // engine will not re-derive it from the backup's partial substrate.
    final day10 = _label(today.subtract(const Duration(days: 10)));
    expect(DerivationEngine.windowTruncatedByPrune(day10, after), isTrue);
  });

  test('a backup with a higher prune edge raises it', () async {
    await LocalDb.setCursor(LocalDb.kDecodedPrunedBeforeCursor, '$local');
    final path =
        await _backup('new.db', {LocalDb.kDecodedPrunedBeforeCursor: '$newer'});

    await LocalDb.importFromDbFile(path);

    expect(await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor),
        newer);
  });
}
