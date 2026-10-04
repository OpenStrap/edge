import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Records the ORDER platform-channel calls land in. The bug this guards is
/// exportAll's day-wide WORKOUT delete-then-write racing exportWorkout's
/// session-scoped delete-then-write on the same `HealthExporter` singleton:
/// two interleaved passes can both see "nothing to delete" and both write,
/// double-booking the workout. If the two ops are serialized, every delete
/// is immediately followed by its own write; if they are not, both deletes
/// land before either write.
class _OrderingHealthStore {
  final calls = <String>[];
  static const _channel = MethodChannel('flutter_health');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'delete':
              return true;
            case 'writeWorkoutData':
              return true;
            default:
              return null;
          }
        });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

Map<String, Object?> _session(int hourOffset) {
  final start = DateTime(2026, 8, 26, 18, 30).add(Duration(hours: hourOffset));
  final end = start.add(const Duration(minutes: 45));
  return {
    'status': 'done',
    'type': 'run',
    'start_ts': start.millisecondsSinceEpoch ~/ 1000,
    'end_ts': end.millisecondsSinceEpoch ~/ 1000,
    'calories': 412,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('exportWorkout concurrency', () {
    late _OrderingHealthStore store;

    tearDown(() => store.remove());

    test(
      'two overlapping exportWorkout calls on the same exporter never '
      'interleave their delete-then-write pairs',
      () async {
        store = _OrderingHealthStore()..install();
        final exporter = HealthExporter();

        // Fire both without awaiting either first — this is the shape of the
        // real bug: a BLE-derive exportAll pass and endWorkout's
        // unawaited exportWorkoutId landing at the same time.
        final a = exporter.exportWorkout(_session(0));
        final b = exporter.exportWorkout(_session(1));
        await Future.wait([a, b]);

        expect(
          store.calls,
          ['delete', 'writeWorkoutData', 'delete', 'writeWorkoutData'],
          reason:
              'each delete must be immediately followed by its own write; '
              'delete,delete,write,write would mean the second call cleared '
              'a still-empty window before the first call had written, '
              'which is exactly the race that produces a duplicate',
        );
      },
    );

    test('a delete that never calls back does not freeze later exports',
        () async {
      // HealthKit's delete never answers when its sample query errors (store
      // locked). Under the shared lock that used to block every later export.
      final calls = <String>[];
      var deletes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_health'),
              (call) async {
        calls.add(call.method);
        if (call.method == 'delete' && deletes++ == 0) {
          return Completer<bool>().future; // never completes
        }
        return true;
      });
      store = _OrderingHealthStore();
      final exporter =
          HealthExporter(deleteTimeout: const Duration(milliseconds: 50));

      final first = exporter.exportWorkout(_session(0));
      final second = exporter.exportWorkout(_session(1));

      expect(await first, isFalse, reason: 'uncleared window, no write');
      expect(await second, isTrue);
      expect(calls, ['delete', 'delete', 'writeWorkoutData']);
    });

    test('one hung delete ends the exportAll pass instead of every type of '
        'every day timing out in turn', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_health_hung_store_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      addTearDown(() async {
        await LocalDb.close();
        await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      });
      for (final day in ['2026-08-25', '2026-08-26']) {
        await LocalDb.putDayResult(
          dayId: day,
          algoVersion: kAlgoVersion,
          payloadJson: '{"scalars":{}}',
          windowJson: '{}',
        );
      }

      var deletes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_health'),
              (call) async {
        if (call.method == 'delete') {
          deletes++;
          return Completer<bool>().future; // locked store: never answers
        }
        return true;
      });
      store = _OrderingHealthStore();
      final exporter =
          HealthExporter(deleteTimeout: const Duration(milliseconds: 20));

      await exporter.exportAll();
      expect(deletes, 1,
          reason: 'the first timeout marks the store hung for the rest of '
              'the lock hold; each further delete would hold the lock '
              'another full timeout');
      final retry =
          await LocalDb.getCursor('health_export_retry_state') ?? '';
      expect(retry, isNot(contains('attempts')),
          reason: 'a locked store is transient, not a failed export; '
              'counting it lets locked background passes burn the attempt '
              'cap and give the day up for good');

      // The next hold starts clean, so a workout export still tries.
      expect(await exporter.exportWorkout(_session(0)), isFalse);
      expect(deletes, 2);
    });
  });
}
