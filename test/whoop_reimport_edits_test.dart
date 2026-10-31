// Importing a newer WHOOP export carries every old workout again under the
// same deterministic id. Writing those rows back over the existing ones
// reverted the user's type correction, wiped their RPE, cleared the private
// flag (and re-exported the workout to the health store), and brought back
// workouts they had deleted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/import/whoop_import.dart';

int _utc(int y, int mo, int d, int h, [int mi = 0]) =>
    DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_whoop_reimport_test.db';
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    tmp = Directory.systemTemp.createTempSync('openstrap_whoop_reimport');
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a re-import keeps edits, the private flag and deletions', () async {
    final f = File(p.join(tmp.path, 'workouts.csv'))
      ..writeAsStringSync(
        'Cycle start time,Cycle end time,Cycle timezone,Workout start time,'
        'Workout end time,Activity name,Activity Strain\n'
        '2024-03-10 07:00:00,2024-03-11 07:00:00,UTC,'
        '2024-03-10 09:00:00,2024-03-10 10:00:00,Functional Fitness,9.1\n'
        '2024-03-11 07:00:00,2024-03-12 07:00:00,UTC,'
        '2024-03-11 09:00:00,2024-03-11 10:00:00,Yoga,4.0\n'
        '2024-03-12 07:00:00,2024-03-13 07:00:00,UTC,'
        '2024-03-12 09:00:00,2024-03-12 10:00:00,Running,11.2\n',
      );
    final first = await WhoopImporter.importFiles([f.path]);
    expect(first.workouts, 3);

    final edited = 'whoop_${_utc(2024, 3, 10, 9)}';
    final private = 'whoop_${_utc(2024, 3, 11, 9)}';
    final deleted = 'whoop_${_utc(2024, 3, 12, 9)}';
    expect(await LocalDb.session(deleted), isNotNull);

    await LocalDb.setSessionType(edited, 'strength_trainer');
    await LocalDb.setSessionRpe(edited, 7);
    await LocalDb.setSessionPrivate(private, true);
    await LocalRepositoryImpl(getProfileMap: () => const {})
        .deleteWorkout(deleted);
    expect(await LocalDb.session(deleted), isNull);

    final second = await WhoopImporter.importFiles([f.path]);
    expect(second.workouts, 0);

    final e = (await LocalDb.session(edited))!;
    expect(e['type'], 'strength_trainer');
    expect((e['rpe'] as num?)?.toDouble(), 7.0);
    expect((await LocalDb.session(private))!['private'], 1);
    expect(await LocalDb.session(deleted), isNull,
        reason: 'a deleted import stays deleted');
  });
}
