import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';

/// A not-yet-final day the strap counter won on one pass and lost on the next
/// must not keep the step samples written the first time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_health');
  const appleSleep = MethodChannel('openstrap/healthkit_sleep');
  final now = DateTime.now();
  final y = DateTime(now.year, now.month, now.day - 1);
  String two(int x) => x.toString().padLeft(2, '0');
  final day = '${y.year}-${two(y.month)}-${two(y.day)}';
  final noon = DateTime(y.year, y.month, y.day, 12).millisecondsSinceEpoch ~/ 1000;
  final stepWrites = <int>[];
  final stepDeletes = <int>[];
  Completer<bool>? hangSteps;

  Future<void> putDay(Map<String, dynamic> steps) => LocalDb.putDayResult(
        dayId: day,
        algoVersion: 120,
        payloadJson: jsonEncode({'steps': steps}),
        windowJson: '{}',
        finalized: false,
      );

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_steps_switch_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      final isSteps = args['dataTypeKey'] == 'STEPS';
      if (call.method == 'delete') {
        if (isSteps) stepDeletes.add(args['startTime'] as int);
        final hang = hangSteps;
        if (isSteps && hang != null) return hang.future;
        return true;
      }
      if (call.method == 'writeData' && isSteps) {
        stepWrites.add(args['startTime'] as int);
      }
      return call.method == 'writeData' ? true : null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appleSleep, (_) async => true);
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

  test('a counter day that switches to the phone clears its steps', () async {
    final exporter = HealthExporter();
    await putDay({
      'source': 'strap_counter',
      'band_measured': 400,
      'spans': [
        {'start_ts': noon, 'end_ts': noon + 3600, 'steps': 400},
      ],
    });
    await exporter.exportAll();
    expect(stepWrites, hasLength(1));

    stepDeletes.clear();
    await putDay({'source': 'phone', 'band_measured': 400, 'value': 900});
    await exporter.exportAll(forceRetry: true);
    expect(stepDeletes, hasLength(1));
    expect(stepWrites, hasLength(1));
  });

  test('a step delete still running after its timeout holds later passes',
      () async {
    final exporter =
        HealthExporter(deleteTimeout: const Duration(milliseconds: 50));
    await putDay({
      'source': 'strap_counter',
      'band_measured': 500,
      'spans': [
        {'start_ts': noon, 'end_ts': noon + 3600, 'steps': 500},
      ],
    });
    stepWrites.clear();
    stepDeletes.clear();
    hangSteps = Completer<bool>();
    await exporter.exportAll(forceRetry: true);
    expect(stepDeletes, hasLength(1));
    expect(stepWrites, isEmpty, reason: 'nothing written beside a survivor');

    // The native delete hasn't landed: the next pass must not write into
    // its range, or the late delete takes the new samples with it.
    await exporter.exportAll(forceRetry: true);
    expect(stepDeletes, hasLength(1));
    expect(stepWrites, isEmpty);

    final hang = hangSteps!;
    hangSteps = null;
    hang.complete(true);
    await Future<void>.delayed(Duration.zero);
    await exporter.exportAll(forceRetry: true);
    expect(stepWrites, hasLength(1));
  });
}
