// A bout caught mid-workout is persisted with the data edge as its end. The
// next pass re-detects it with the same start (same id) and the real end; the
// row has to follow, or confirming it logs the truncated window.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_workout_suggestion_refresh_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Map<String, dynamic> row(int end, int min, int createdAt) => {
        'id': '2026-10-01:1000',
        'date': '2026-10-01',
        'start_ts': 1000,
        'end_ts': end,
        'avg_bpm': 130,
        'peak_bpm': 150,
        'duration_min': min,
        'sport': 'run',
        'dismissed': 0,
        'created_at': createdAt,
      };

  test('a re-detected bout with the same start updates its end', () async {
    await LocalDb.putWorkoutSuggestion(row(2200, 20, 1));
    await LocalDb.putWorkoutSuggestion(row(4600, 60, 2));
    final rows = await LocalDb.activeWorkoutSuggestions();
    expect(rows, hasLength(1));
    expect(rows.single['end_ts'], 4600);
    expect(rows.single['duration_min'], 60);
    expect(rows.single['created_at'], 1);
  });

  test('a dismissed suggestion stays dismissed', () async {
    await LocalDb.dismissWorkoutSuggestion('2026-10-01:1000');
    await LocalDb.putWorkoutSuggestion(row(5000, 66, 3));
    expect(await LocalDb.activeWorkoutSuggestions(), isEmpty);
  });
}
