// A bout caught mid-workout is persisted with the data edge as its end. The
// next pass re-detects it with the same start (same id) and the real end; the
// row has to follow, or confirming it logs the truncated window.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_workout_suggestion_refresh_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    // Open the review store's cutoff to the fixtures below.
    await (await LocalDb.instance)
        .update('activity_review_meta', {'activated_at': 1});
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // Recent, not 1970: an unanswered suggestion only stays listed for a week.
  final base = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400;

  Map<String, dynamic> row(int end, int min, int createdAt) => {
        'id': 'workout:$base',
        'date': '2026-10-01',
        'start_ts': base,
        'end_ts': base + end,
        'avg_bpm': 130,
        'peak_bpm': 150,
        'duration_min': min,
        'sport': 'run',
        'dismissed': 0,
        'created_at': createdAt,
      };

  test('a re-detected bout with the same start updates its end', () async {
    await LocalDb.putWorkoutSuggestion(row(1200, 20, 1));
    await LocalDb.putWorkoutSuggestion(row(3600, 60, 2));
    final rows = await LocalDb.activeWorkoutSuggestions();
    expect(rows, hasLength(1));
    expect(rows.single['end_ts'], base + 3600);
    expect(rows.single['duration_min'], 60);
  });

  test('a stale pass with an earlier end does not shrink the span', () async {
    await LocalDb.putWorkoutSuggestion(row(1200, 20, 3));
    final rows = await LocalDb.activeWorkoutSuggestions();
    expect(rows.single['end_ts'], base + 3600);
    expect(rows.single['duration_min'], 60);
  });

  test('a dismissed suggestion stays dismissed', () async {
    await LocalDb.dismissWorkoutSuggestion('workout:$base');
    await LocalDb.putWorkoutSuggestion(row(4000, 66, 3));
    expect(await LocalDb.activeWorkoutSuggestions(), isEmpty);
  });

  test('a nap re-detected with an earlier end does move back', () async {
    final store = ActivityStore(await LocalDb.instance);
    await store.reconcile(ActivityKind.nap, [
      {'start': 9000, 'end': 12000},
    ]);
    await store.reconcile(ActivityKind.nap, [
      {'start': 9000, 'end': 10800},
    ]);
    final rows = await (await LocalDb.instance).query('activity_suggestions',
        where: "kind = 'nap'");
    expect(rows.single['end_ts'], 10800);
  });
}
