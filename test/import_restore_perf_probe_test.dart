// Optional timing probe: restores a supplied export into an empty FFI DB, prints
// per-table wall ms, sqflite calls and rows. Desktop ffi has no platform
// channel, so it understates Android.
//
//   IMPORT_PERF_PROBE=1 IMPORT_PERF_SRC=/path/export.db \
//     flutter test test/import_restore_perf_probe_test.dart
// The supplied file is only read; restore runs against a temporary copy.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

Iterable<String> _sqlOf(Object? args) sync* {
  if (args is Map) {
    final sql = args['sql'];
    if (sql is String) yield sql;
    for (final v in args.values) {
      if (v is List || v is Map) yield* _sqlOf(v);
    }
  } else if (args is List) {
    for (final v in args) {
      yield* _sqlOf(v);
    }
  }
}

void main() {
  final srcPath = Platform.environment['IMPORT_PERF_SRC'] ?? '';

  test('restore timing per table', () async {
    final tables = LocalDb.restoreTablesForTest;
    final patterns = {for (final t in tables) t: RegExp('\\b$t\\b')};
    final wallUs = <String, int>{};
    final calls = <String, int>{};
    final clock = Stopwatch();
    var lastUs = 0;
    var on = false;
    var current = '(other)';

    sqfliteFfiInit();
    // The logger is the only public hook that sees every sqflite call.
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.invoke,
        log: (e) {
          if (!on || e is! SqfliteLoggerInvokeEvent) return;
          final now = clock.elapsedMicroseconds;
          final sql = _sqlOf(e.arguments).join('\n');
          String? owner;
          for (final t in tables) {
            if (patterns[t]!.hasMatch(sql)) {
              owner = t;
              break;
            }
          }
          // BEGIN/COMMIT and other unnamed calls belong to the table being
          // copied: the Dart time before them is that table's row work.
          owner ??= current;
          current = owner;
          wallUs[owner] = (wallUs[owner] ?? 0) + (now - lastUs);
          calls[owner] = (calls[owner] ?? 0) + 1;
          lastUs = now;
        },
      ),
    );
    SharedPreferences.setMockInitialValues({});
    final tmp = await Directory.systemTemp.createTemp('openstrap_perf_');
    LocalDb.dbName = 'openstrap_perf_probe.db';
    final dbDir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    try {
      final copy = p.join(tmp.path, 'export.db');
      await File(srcPath).copy(copy);
      await LocalDb.instance;

      on = true;
      clock.start();
      final counts = await LocalDb.importFromDbFile(copy);
      clock.stop();
      on = false;

      final rows = <String>[];
      var totalRows = 0;
      for (final t in [...tables, '(other)']) {
        final n = counts[t] ?? 0;
        if (n > 0) totalRows += n;
        final ms = (wallUs[t] ?? 0) / 1000;
        if (n == 0 && ms < 5) continue;
        rows.add('${t.padRight(26)} ${ms.toStringAsFixed(0).padLeft(8)} ms '
            '${'${calls[t] ?? 0}'.padLeft(7)} calls ${'$n'.padLeft(9)} rows');
      }
      // ignore: avoid_print
      print('[import-perf] total ${clock.elapsedMilliseconds} ms, '
          '$totalRows rows, _days=${counts['_days']}\n${rows.join('\n')}');
    } finally {
      on = false;
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
      await tmp.delete(recursive: true);
    }
  },
      skip: Platform.environment['IMPORT_PERF_PROBE'] != '1' || srcPath.isEmpty
          ? 'set IMPORT_PERF_PROBE=1 and IMPORT_PERF_SRC to measure a restore'
          : false,
      timeout: const Timeout(Duration(minutes: 30)));
}
