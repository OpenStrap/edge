// The one-shot legacy-STEPS purge must not mark a day purged when the store
// did not confirm the delete.
//
// `_purgeLegacyStepsIfNeeded` discarded the bool from `_nativeDelete`. On
// Health Connect a false delete is a genuine failure (a denied STEPS write
// permission, an unmapped type, a store error) — `healthDeleteClearedRange`
// documents exactly that, and the sibling prefix purge already retries on it.
// The cursor advanced anyway, so the fabricated step samples earlier versions
// wrote for that day were never asked for again: the store keeps adding them
// to the user's real step total.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_health');
  const appleSleep = MethodChannel('openstrap/healthkit_sleep');

  final now = DateTime.now();
  DateTime dayAt(int back) => DateTime(now.year, now.month, now.day - back);
  String labelOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  final older = dayAt(2);
  final newer = dayAt(1);
  final olderDay = labelOf(older);
  final newerDay = labelOf(newer);

  // Every STEPS delete that is not the epoch-to-cursor prefix purge.
  final stepDeletes = <(int, int)>[];
  var perDayDeletesFail = 0;

  Future<void> putDay(String day) => LocalDb.putDayResult(
    dayId: day,
    algoVersion: 120,
    payloadJson: jsonEncode({
      'scalars': {'rhr': 55},
    }),
    windowJson: '{}',
    finalized: true,
  );

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_legacy_steps_purge_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments is Map ? call.arguments as Map : const {};
          if (call.method == 'delete') {
            final start = (args['startTime'] as num?)?.toInt() ?? 0;
            final end = (args['endTime'] as num?)?.toInt() ?? 0;
            if (args['dataTypeKey'] == 'STEPS' && start != 0) {
              stepDeletes.add((start, end));
              if (perDayDeletesFail > 0) {
                perDayDeletesFail--;
                return false;
              }
            }
            return true;
          }
          return true;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appleSleep, (_) async => true);
  });

  setUp(() async {
    stepDeletes.clear();
    perDayDeletesFail = 0;
    await LocalDb.setCursor('health_export_through', '');
    await LocalDb.setCursor('health_steps_purged_through', '');
    await LocalDb.setCursor('health_steps_purge_pending_from', '');
    await LocalDb.setCursor('health_export_retry_state', '');
    final days = await LocalDb.dayResultVersions();
    if (days.isNotEmpty) {
      await (await LocalDb.instance).delete('day_result');
    }
    await putDay(olderDay);
    await putDay(newerDay);
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appleSleep, null);
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  test('an unconfirmed delete does not advance the purge cursor', () async {
    perDayDeletesFail = 2;
    await HealthExporter(isApple: false).exportAll(forceRetry: true);
    expect(
      await LocalDb.getCursor('health_steps_purged_through'),
      isEmpty,
      reason: 'neither day was confirmed purged, so neither may be recorded',
    );
    expect(
      await LocalDb.getCursor('health_steps_purge_pending_from'),
      olderDay,
      reason: 'the earliest refused day is the one to retry from',
    );
  });

  test(
    'the next day retries the refused range, then clears the marker',
    () async {
      perDayDeletesFail = 1;
      await HealthExporter(isApple: false).exportAll(forceRetry: true);
      expect(stepDeletes, hasLength(2));
      expect(
        stepDeletes.first.$1,
        older.millisecondsSinceEpoch,
        reason: 'the first day purges its own range',
      );
      expect(
        stepDeletes.last.$1,
        older.millisecondsSinceEpoch,
        reason: 'the newer day widens its range over the day the store refused',
      );
      expect(await LocalDb.getCursor('health_steps_purged_through'), newerDay);
      expect(
        await LocalDb.getCursor('health_steps_purge_pending_from'),
        isEmpty,
      );
    },
  );
}
