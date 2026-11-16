// The one-shot legacy-STEPS purge must not mark a day purged when the store
// did not confirm the delete, and it must never widen a retry over an earlier
// day's valid strap-counter samples.
//
// `_purgeLegacyStepsIfNeeded` used to discard the bool from `_nativeDelete` and
// advance `health_steps_purged_through`. On Health Connect a false delete is a
// genuine failure (a denied STEPS write permission, an unmapped type, a store
// error) — `healthDeleteClearedRange` documents exactly that. The cursor
// advanced anyway, so the fabricated step samples earlier versions wrote were
// never asked for again.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';

const String kPendingCursor = 'health_steps_purge_pending';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_health');
  const appleSleep = MethodChannel('openstrap/healthkit_sleep');

  final now = DateTime.now();
  DateTime dayAt(int back) => DateTime(now.year, now.month, now.day - back);
  final older = dayAt(2);
  final newer = dayAt(1);
  final olderDay = dayLabelOf(older);
  final newerDay = dayLabelOf(newer);

  // Every STEPS delete that is not the epoch-to-cursor prefix purge.
  final stepDeletes = <({int start, int end, String pendingBefore})>[];
  final failStarts = <int>{};

  Future<void> putDay(String day) => LocalDb.putDayResult(
    dayId: day,
    algoVersion: 120,
    payloadJson: jsonEncode({
      'scalars': {'rhr': 55},
    }),
    windowJson: '{}',
    finalized: true,
  );

  Future<Map<String, ({int startMs, int endMs})>> pending() async {
    final raw = await LocalDb.getCursor(kPendingCursor) ?? '';
    if (raw.isEmpty) return {};
    return {
      for (final entry in (jsonDecode(raw) as List).whereType<Map>())
        entry['day'] as String: (
          startMs: (entry['start_ms'] as num).toInt(),
          endMs: (entry['end_ms'] as num).toInt(),
        ),
    };
  }

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
              // The retry intent must already be persisted when the delete is
              // issued, not written after it returns.
              final pendingBefore =
                  await LocalDb.getCursor(kPendingCursor) ?? '';
              stepDeletes.add((
                start: start,
                end: end,
                pendingBefore: pendingBefore,
              ));
              if (failStarts.contains(start)) return false;
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
    failStarts.clear();
    await LocalDb.setCursor('health_export_through', '');
    await LocalDb.setCursor('health_steps_purged_through', '');
    await LocalDb.setCursor(kPendingCursor, '');
    await LocalDb.setCursor('health_export_retry_state', '');
    await (await LocalDb.instance).delete('day_result');
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
    failStarts.addAll({
      older.millisecondsSinceEpoch,
      newer.millisecondsSinceEpoch,
    });
    await HealthExporter(isApple: false).exportAll(forceRetry: true);
    expect(
      await LocalDb.getCursor('health_steps_purged_through'),
      isEmpty,
      reason: 'neither day was confirmed purged, so neither may be recorded',
    );
    final left = await pending();
    expect(left.keys, containsAll([olderDay, newerDay]));
    expect(left[olderDay]!.startMs, older.millisecondsSinceEpoch);
  });

  test('a later day never widens over an earlier refused day', () async {
    failStarts.add(older.millisecondsSinceEpoch);
    await HealthExporter(isApple: false).exportAll(forceRetry: true);
    expect(stepDeletes, hasLength(2));
    expect(
      stepDeletes.last.start,
      newer.millisecondsSinceEpoch,
      reason:
          'the newer day clears only its own range; widening would delete '
          'the older day\'s valid steps that nothing rewrites',
    );
    final left = await pending();
    expect(left.keys, [olderDay], reason: 'only the confirmed day clears');
    expect(await LocalDb.getCursor('health_steps_purged_through'), newerDay);
  });

  test('retry intent is persisted before the delete is issued', () async {
    failStarts.add(older.millisecondsSinceEpoch);
    await HealthExporter(isApple: false).exportAll(forceRetry: true);
    final first = stepDeletes.first;
    expect(first.start, older.millisecondsSinceEpoch);
    expect(first.pendingBefore, isNotEmpty);
    expect(first.pendingBefore, contains(olderDay));
    expect(first.pendingBefore, contains('${older.millisecondsSinceEpoch}'));
  });

  test(
    'a retry is clipped to the part of its stored range that is still that day',
    () async {
      failStarts.add(older.millisecondsSinceEpoch);
      await HealthExporter(isApple: false).exportAll(forceRetry: true);
      final left = await pending();
      expect(left.keys, [olderDay]);

      // Move the stored start an hour earlier, as if the timezone had moved east
      // between the refusal and the retry. The stored range now reaches an hour
      // into the PREVIOUS day, whose valid strap steps nothing rewrites, so the
      // retry is clipped to this day instead of using the stored epoch verbatim.
      final stored = left[olderDay]!;
      final earlier = stored.startMs - const Duration(hours: 1).inMilliseconds;
      await LocalDb.setCursor(
        kPendingCursor,
        jsonEncode([
          {'day': olderDay, 'start_ms': earlier, 'end_ms': stored.endMs},
        ]),
      );
      failStarts.clear();
      await LocalDb.setCursor('health_export_through', '');

      final before = stepDeletes.length;
      await HealthExporter(isApple: false).exportAll(forceRetry: true);
      final retries = stepDeletes.skip(before).toList();
      expect(
        retries.any((d) => d.start == stored.startMs && d.end == stored.endMs),
        isTrue,
        reason: 'the retry covers this day',
      );
      expect(
        retries.any((d) => d.start == earlier),
        isFalse,
        reason: 'and never reaches into the previous day',
      );
      expect((await pending()).containsKey(olderDay), isFalse);
      expect(await LocalDb.getCursor('health_steps_purged_through'), newerDay);
    },
  );

  test('a refused later day survives an earlier day\'s success', () async {
    failStarts.addAll({
      older.millisecondsSinceEpoch,
      newer.millisecondsSinceEpoch,
    });
    await HealthExporter(isApple: false).exportAll(forceRetry: true);
    expect((await pending()).keys, containsAll([olderDay, newerDay]));

    await LocalDb.setCursor('health_export_through', '');
    failStarts
      ..clear()
      ..add(newer.millisecondsSinceEpoch);
    await HealthExporter(isApple: false).exportAll(forceRetry: true);

    expect((await pending()).keys, [
      newerDay,
    ], reason: 'clearing the older day must not clear the newer day\'s marker');
    expect(await LocalDb.getCursor('health_steps_purged_through'), olderDay);
  });

  test('an ordinary later pass retries a refused finalized day', () async {
    failStarts.add(older.millisecondsSinceEpoch);
    await HealthExporter(isApple: false).exportAll(forceRetry: true);
    expect((await pending()).keys, [olderDay]);
    expect(
      await LocalDb.getCursor('health_export_through'),
      isEmpty,
      reason: 'the refused purge holds the export cursor behind the day',
    );

    failStarts.clear();
    final before = stepDeletes.length;
    await HealthExporter(isApple: false).exportAll();
    expect(
      stepDeletes
          .skip(before)
          .any((d) => d.start == older.millisecondsSinceEpoch),
      isTrue,
      reason: 'an ordinary pass retries the held finalized day',
    );
    expect(await pending(), isEmpty);
    expect(await LocalDb.getCursor('health_steps_purged_through'), newerDay);
    expect(await LocalDb.getCursor('health_export_through'), newerDay);
  });

  test(
    'an intent-save failure never lets a later day skip the failed day',
    () async {
      final db = await LocalDb.instance;
      await db.execute(
        "CREATE TRIGGER fail_pending_save BEFORE INSERT ON sync_cursor "
        "WHEN NEW.name = '$kPendingCursor' AND NEW.value LIKE '%$olderDay%' "
        "BEGIN SELECT RAISE(ABORT, 'simulated save failure'); END;",
      );
      try {
        await HealthExporter(isApple: false).exportAll(forceRetry: true);
      } finally {
        await db.execute('DROP TRIGGER IF EXISTS fail_pending_save');
      }

      // Even if the newer day purged cleanly, the purge cursor must not jump
      // past the older day whose intent save failed.
      expect(await LocalDb.getCursor('health_steps_purged_through'), isEmpty);

      final before = stepDeletes.length;
      await HealthExporter(isApple: false).exportAll();
      expect(
        stepDeletes
            .skip(before)
            .any((d) => d.start == older.millisecondsSinceEpoch),
        isTrue,
        reason: 'the older day still purges once cursor saves work again',
      );
      expect(await LocalDb.getCursor('health_steps_purged_through'), newerDay);
    },
  );
}
