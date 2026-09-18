import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/health_export.dart';

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
  });
}
