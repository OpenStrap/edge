import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stand-in for the platform health store, driven over the `health` plugin's
/// own method channel — the only seam `HealthExporter` reaches the store
/// through. Records every call so a test can assert what the exporter did
/// AFTER a delete came back false, which is the whole point: the bug was that
/// it wrote anyway.
class _FakeHealthStore {
  _FakeHealthStore({required this.deleteResult, this.deleteThrows = false});

  /// What `delete` answers. On Health Connect a `false` here means the delete
  /// genuinely failed and whatever we wrote before is STILL in the store.
  final bool deleteResult;
  final bool deleteThrows;

  final calls = <String>[];

  static const _channel = MethodChannel('flutter_health');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'delete':
              if (deleteThrows) {
                throw PlatformException(code: 'delete-failed');
              }
              return deleteResult;
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

Map<String, Object?> _session() {
  final start = DateTime(2026, 8, 26, 18, 30);
  final end = DateTime(2026, 8, 26, 19, 15);
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

  group('healthDeleteClearedRange', () {
    // The fact the whole gate hinges on, pinned so a future reader does not
    // "simplify" it back to a bare `deleted`. Verified against the plugin
    // sources in health 12.2.1 and Apple's own docs:
    //
    //   * HealthPlugin.kt `deleteData` -> deleteRecords over a time range,
    //     `result.success(true)` unless it threw. Zero matches is a success.
    //   * SwiftHealthPlugin.swift `delete` -> HKSampleQuery scoped to
    //     HKSource.default(), then HKHealthStore.delete(samples) with whatever
    //     came back — including an EMPTY array, which Apple documents as
    //     "Deleting an empty array fails with an errorInvalidArgument error".
    //
    // So on Apple a false delete is what every first export sees, and gating
    // the write on it would mean no workout ever reaches HealthKit at all.
    test('Health Connect false is a genuine failure', () {
      expect(healthDeleteClearedRange(deleted: false, ios: false), isFalse);
      expect(healthDeleteClearedRange(deleted: true, ios: false), isTrue);
    });

    test('HealthKit false is the documented empty-range answer', () {
      expect(healthDeleteClearedRange(deleted: false, ios: true), isTrue);
      expect(healthDeleteClearedRange(deleted: true, ios: true), isTrue);
    });
  });

  group('exportWorkout delete-then-write', () {
    // The host VM is neither iOS nor macOS, so `HealthExporter.isApple` is
    // false and these exercise the Health-Connect reading of `delete`.
    late _FakeHealthStore store;

    tearDown(() => store.remove());

    test('a failed delete does not write a duplicate on top of it', () async {
      store = _FakeHealthStore(deleteResult: false)..install();

      final ok = await HealthExporter().exportWorkout(_session());

      expect(ok, isFalse, reason: 'the caller must retry this workout');
      expect(store.calls, contains('delete'));
      expect(
        store.calls,
        isNot(contains('writeWorkoutData')),
        reason:
            'the previously exported copy survived the delete, so writing '
            'would leave two of this workout in the store — and the false '
            'return drives a retry that would write a third',
      );
    });

    test('a thrown delete does not write either', () async {
      store = _FakeHealthStore(deleteResult: true, deleteThrows: true)
        ..install();

      final ok = await HealthExporter().exportWorkout(_session());

      expect(ok, isFalse);
      expect(store.calls, isNot(contains('writeWorkoutData')));
    });

    test('a successful delete still writes', () async {
      store = _FakeHealthStore(deleteResult: true)..install();

      final ok = await HealthExporter().exportWorkout(_session());

      expect(ok, isTrue);
      expect(store.calls, containsAllInOrder(['delete', 'writeWorkoutData']));
    });

    test(
        'a reconciled orphan (end_ts_fabricated) is never written, even '
        'though it looks like any other finished row', () async {
      store = _FakeHealthStore(deleteResult: true)..install();

      final ok = await HealthExporter().exportWorkout({
        ..._session(),
        'end_ts_fabricated': 1,
      });

      expect(ok, isFalse);
      expect(store.calls, isNot(contains('writeWorkoutData')),
          reason: 'end_ts here is reconcile-time, not a measurement — this '
              'must never reach Health, on the periodic export path either');
    });
  });

  group('deleteWorkoutWindow (retime cleanup)', () {
    // setWorkoutWindow only has the OLD [start,end] before it overwrites the
    // row — this is what it calls to clear that range so a narrowed/moved
    // retime doesn't leave the previous Health sample stranded outside the
    // new window (which is all `exportWorkoutId`'s own delete ever reaches).
    late _FakeHealthStore store;

    tearDown(() => store.remove());

    test('clears the old window when health sync is on', () async {
      SharedPreferences.setMockInitialValues({'health_sync': true});
      store = _FakeHealthStore(deleteResult: true)..install();

      final oldStart = DateTime(2026, 8, 26, 18, 30);
      final oldEnd = DateTime(2026, 8, 26, 19, 15);
      await HealthExporter.deleteWorkoutWindow(
        oldStart.millisecondsSinceEpoch ~/ 1000,
        oldEnd.millisecondsSinceEpoch ~/ 1000,
      );

      expect(store.calls, contains('delete'));
      expect(store.calls, isNot(contains('writeWorkoutData')));
    });

    test('no-ops when health sync is off', () async {
      SharedPreferences.setMockInitialValues({'health_sync': false});
      store = _FakeHealthStore(deleteResult: true)..install();

      await HealthExporter.deleteWorkoutWindow(0, 100);

      expect(store.calls, isEmpty);
    });
  });
}
