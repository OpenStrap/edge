// #325 — an imported workout can be scored from the band's own 1 Hz heart
// rate, and the scored session replaces the import rather than sitting beside
// it. Both tap paths, and the replacement itself.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _start = DateTime(2026, 8, 1, 9);
final _end = DateTime(2026, 8, 1, 10, 36);

Future<void> _tap(WidgetTester t, {required bool stored}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (c) => TextButton(
          onPressed: () => scoreImportedWorkout(c,
              uuid: 'hevy-1',
              start: _start,
              end: _end,
              activity: quickStart.first,
              hasHr: (_, _) async => stored),
          child: const Text('row'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('row'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('with band heart rate stored, opens the log form on its window',
      (t) async {
    await _tap(t, stored: true);
    final form = t.widget<LogWorkout>(find.byType(LogWorkout));
    expect(form.start, _start);
    expect(form.end, _end);
    expect(form.importedUuid, 'hevy-1');
    expect(form.sessionId, isNull);
    expect(find.text('Score with band heart rate'), findsOneWidget);
  });

  testWidgets('with the heart rate pruned, says so and opens nothing',
      (t) async {
    await _tap(t, stored: false);
    expect(find.byType(LogWorkout), findsNothing);
    expect(find.textContaining('no longer stored'), findsOneWidget);
  });

  group('supersedeImportedWorkout', () {
    late Directory dir;
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_score_imported_test.db';
      dir = Directory(await databaseFactory.getDatabasesPath());
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dir.path, LocalDb.dbName));
    });
    tearDown(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dir.path, LocalDb.dbName));
    });

    test('drops the import and hands its route to the scored session',
        () async {
      await LocalDb.putImportedWorkouts([
        {
          'uuid': 'hevy-1',
          'start_ts': 100,
          'end_ts': 200,
          'kind': 'RUNNING',
          'source': 'Hevy',
        },
      ]);
      final db = await LocalDb.instance;
      await db.insert('workout_route', {
        'session_id': 'hevy-1',
        'seq': 0,
        'ts_ms': 100000,
        'lat': 51.5,
        'lng': -0.1,
      });

      await LocalDb.supersedeImportedWorkout('hevy-1', 'manual-100');

      expect(await LocalDb.importedWorkouts(), isEmpty);
      final route = await db.query('workout_route');
      expect(route.single['session_id'], 'manual-100');
    });
  });
}
