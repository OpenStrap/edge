// WHOOP exports write wall-clock times with no offset and carry the offset in
// a separate "Cycle timezone" column. Reading those times in the phone's
// current zone put every night or workout recorded somewhere else at the wrong
// instant (and wrote it to Apple Health / Health Connect that way). These
// assertions are absolute epochs, so they hold whatever zone the test runs in.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/whoop_import.dart';

int _utc(int y, int mo, int d, int h, [int mi = 0]) =>
    DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

void main() {
  group('zoneOffset', () {
    test('reads the export formats', () {
      expect(WhoopImporter.zoneOffset('UTC+01:00'), const Duration(hours: 1));
      expect(WhoopImporter.zoneOffset('UTC-08:00'), const Duration(hours: -8));
      expect(WhoopImporter.zoneOffset('UTC+0530'),
          const Duration(hours: 5, minutes: 30));
      expect(WhoopImporter.zoneOffset('GMT+5:30'),
          const Duration(hours: 5, minutes: 30));
      expect(WhoopImporter.zoneOffset('-03:00'), const Duration(hours: -3));
      expect(WhoopImporter.zoneOffset('UTC'), Duration.zero);
    });

    test('anything unreadable falls back to the phone zone', () {
      expect(WhoopImporter.zoneOffset(''), isNull);
      expect(WhoopImporter.zoneOffset('Europe/Paris'), isNull);
      expect(WhoopImporter.zoneOffset('UTC+25:00'), isNull);
    });
  });

  group('parseExportTs', () {
    test('an offset-less time is read in the row zone', () {
      expect(
          WhoopImporter.parseExportTs('2024-03-09 23:10:00', zone: 'UTC+01:00'),
          _utc(2024, 3, 9, 22, 10));
      expect(
          WhoopImporter.parseExportTs('2024-03-09 23:10:00', zone: 'UTC-08:00'),
          _utc(2024, 3, 10, 7, 10));
    });

    test('a time carrying its own offset ignores the zone column', () {
      expect(
          WhoopImporter.parseExportTs('2024-03-09T23:10:00Z',
              zone: 'UTC+01:00'),
          _utc(2024, 3, 9, 23, 10));
      expect(
          WhoopImporter.parseExportTs('2024-03-09 23:10:00+0200',
              zone: 'UTC+01:00'),
          _utc(2024, 3, 9, 21, 10));
    });

    test('no zone column keeps the phone-local reading', () {
      expect(WhoopImporter.parseExportTs('2024-03-09 23:10:00'),
          DateTime(2024, 3, 9, 23, 10).millisecondsSinceEpoch ~/ 1000);
      expect(WhoopImporter.parseExportTs(''), isNull);
    });
  });

  group('import', () {
    late Directory tmp;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_whoop_tz_test.db';
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      tmp = Directory.systemTemp.createTempSync('openstrap_whoop_tz');
    });

    tearDownAll(() async {
      await LocalDb.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('a Paris night lands at its real instant and Paris wake date',
        () async {
      final f = File(p.join(tmp.path, 'sleeps.csv'))
        ..writeAsStringSync(
          'Cycle start time,Cycle end time,Cycle timezone,Sleep onset,'
          'Wake onset,Asleep duration (min),In bed duration (min),Nap\n'
          '2024-03-09 23:00:00,2024-03-10 23:00:00,UTC+01:00,'
          '2024-03-09 23:10:00,2024-03-10 07:00:00,440,470,false\n',
        );
      final res = await WhoopImporter.importFiles([f.path]);
      expect(res.days, 1);
      final row = await LocalDb.dayResult('2024-03-10');
      expect(row, isNotNull, reason: 'filed under the Paris wake date');
      final win = jsonDecode(row!['window_json'] as String) as Map;
      expect(win['onset_ms'], _utc(2024, 3, 9, 22, 10) * 1000);
      expect(win['offset_ms'], _utc(2024, 3, 10, 6) * 1000);
    });

    test('a Paris workout is stored at its real instant', () async {
      final f = File(p.join(tmp.path, 'workouts.csv'))
        ..writeAsStringSync(
          'Cycle start time,Cycle end time,Cycle timezone,Workout start time,'
          'Workout end time,Activity name,Activity Strain\n'
          '2024-03-10 07:00:00,2024-03-11 07:00:00,UTC+01:00,'
          '2024-03-10 18:00:00,2024-03-10 18:45:00,Running,11.2\n',
        );
      final res = await WhoopImporter.importFiles([f.path]);
      expect(res.workouts, 1);
      final start = _utc(2024, 3, 10, 17);
      final db = await LocalDb.instance;
      final rows = await db.query('sessions',
          where: 'id = ?', whereArgs: ['whoop_$start']);
      expect(rows, hasLength(1));
      expect((rows.first['start_ts'] as num).toInt(), start);
      expect((rows.first['end_ts'] as num).toInt(), _utc(2024, 3, 10, 17, 45));
    });

    // An import made before the zone column was honoured stored this workout
    // at its wall time read in the phone's zone, under that instant's id.
    // +05:45 so the test host's own zone can't make the two readings agree.
    const wallStart = '2024-04-02 06:00:00';
    const wallEnd = '2024-04-02 07:10:00';
    String workoutCsv(String name) => (File(p.join(tmp.path, name))
      ..writeAsStringSync(
        'Cycle start time,Cycle end time,Cycle timezone,Workout start time,'
        'Workout end time,Activity name,Activity Strain\n'
        '2024-04-02 04:00:00,2024-04-03 04:00:00,UTC+05:45,'
        '$wallStart,$wallEnd,Running,9.4\n',
      )).path;

    Future<List<Map<String, dynamic>>> sessionsAround(int ts) async {
      final db = await LocalDb.instance;
      return db.query('sessions',
          where: "id LIKE 'whoop%' AND start_ts BETWEEN ? AND ?",
          whereArgs: [ts - 86400, ts + 86400]);
    }

    test('a re-import moves a phone-zone workout instead of duplicating it',
        () async {
      SharedPreferences.setMockInitialValues({});
      final legacyStart = WhoopImporter.parseExportTs(wallStart)!;
      final legacyEnd = WhoopImporter.parseExportTs(wallEnd)!;
      final start = _utc(2024, 4, 2, 0, 15);
      final end = _utc(2024, 4, 2, 1, 25);
      if (legacyStart == start) return; // host is on +05:45 itself
      final legacyId = 'whoop_$legacyStart';
      await LocalDb.putSession({
        'id': legacyId,
        'start_ts': legacyStart,
        'end_ts': legacyEnd,
        'type': 'cycling', // the user's correction
        'status': 'done',
        'source': 'whoop',
        'strain': 9.4,
        'duration_min': 70,
        'created_at': 0,
      });
      await LocalDb.setSessionPrivate(legacyId, true);
      // Measured over the wrong seconds before the move.
      final db0 = await LocalDb.instance;
      await db0.update(
          'sessions',
          {'trace_json': '{"hr":[]}', 'trace_samples': 10, 'avg_hr': 140},
          where: 'id = ?',
          whereArgs: [legacyId]);

      for (var i = 0; i < 2; i++) {
        final res = await WhoopImporter.importFiles([workoutCsv('w$i.csv')]);
        expect(res.workouts, 0);
        final rows = await sessionsAround(start);
        expect(rows, hasLength(1), reason: 'import ${i + 1}');
        final r = rows.single;
        expect(r['id'], legacyId);
        expect((r['start_ts'] as num).toInt(), start);
        expect((r['end_ts'] as num).toInt(), end);
        expect(r['type'], 'cycling');
        expect(r['private'], 1);
        expect(r['trace_json'], isNull);
        expect(r['avg_hr'], isNull);
        expect(r['strain'], 9.4);
      }
      final db = await LocalDb.instance;
      await db.delete('sessions', where: 'id = ?', whereArgs: [legacyId]);
    });

    test('a workout already moved under its old id is not inserted again',
        () async {
      SharedPreferences.setMockInitialValues({});
      final start = _utc(2024, 4, 2, 0, 15);
      // Any id other than the one this import would compute: the row an
      // earlier re-import moved onto the right instant.
      const movedId = 'whoop_1';
      await LocalDb.putSession({
        'id': movedId,
        'start_ts': start,
        'end_ts': _utc(2024, 4, 2, 1, 25),
        'type': 'running',
        'status': 'done',
        'source': 'whoop',
        'duration_min': 70,
        'created_at': 0,
      });
      final res = await WhoopImporter.importFiles([workoutCsv('wm.csv')]);
      expect(res.workouts, 0);
      final rows = await sessionsAround(start);
      expect(rows.map((r) => r['id']), [movedId]);
      final db = await LocalDb.instance;
      await db.delete('sessions', where: 'id = ?', whereArgs: [movedId]);
    });

    test('a moved workout deleted under its old id stays deleted', () async {
      SharedPreferences.setMockInitialValues({});
      final start = _utc(2024, 4, 2, 0, 15);
      await WhoopImporter.rememberDeletedWorkout('whoop_1', startTs: start);
      final res = await WhoopImporter.importFiles([workoutCsv('wdm.csv')]);
      expect(res.workouts, 0);
      expect(await sessionsAround(start), isEmpty);
    });

    test('a deleted phone-zone workout stays deleted on re-import', () async {
      final legacyStart = WhoopImporter.parseExportTs(wallStart)!;
      final start = _utc(2024, 4, 2, 0, 15);
      if (legacyStart == start) return;
      SharedPreferences.setMockInitialValues({
        'whoop_import_deleted_workouts': ['whoop_$legacyStart'],
      });
      final res = await WhoopImporter.importFiles([workoutCsv('wd.csv')]);
      expect(res.workouts, 0);
      expect(await sessionsAround(start), isEmpty);
    });
  });
}
