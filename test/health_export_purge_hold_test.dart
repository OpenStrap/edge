import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';

/// A day held behind the legacy steps purge, or behind a delete still running,
/// stays pending: no attempt is charged and nothing is written beside the
/// delete.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_health');
  const appleSleep = MethodChannel('openstrap/healthkit_sleep');
  final now = DateTime.now();
  final y = DateTime(now.year, now.month, now.day - 1);
  String two(int x) => x.toString().padLeft(2, '0');
  final day = '${y.year}-${two(y.month)}-${two(y.day)}';
  final noon = DateTime(y.year, y.month, y.day, 12).millisecondsSinceEpoch ~/ 1000;
  final writes = <String>[];
  var purgeFails = false;
  Completer<bool>? hangRhr;

  Future<void> putDay(Map<String, dynamic> payload) => LocalDb.putDayResult(
        dayId: day,
        algoVersion: 120,
        payloadJson: jsonEncode(payload),
        windowJson: '{}',
        finalized: false,
      );

  Future<Map<String, dynamic>> retryState() async {
    final raw = await LocalDb.getCursor('health_export_retry_state') ?? '';
    return raw.isEmpty
        ? const {}
        : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_purge_hold_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      final type = args['dataTypeKey'];
      if (call.method == 'delete') {
        if (type == 'STEPS' && args['startTime'] == 0 && purgeFails) {
          throw PlatformException(code: 'busy');
        }
        final hang = hangRhr;
        if (type == 'RESTING_HEART_RATE' && hang != null) return hang.future;
        return true;
      }
      if (call.method == 'writeData') writes.add('$type');
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

  test('a day held behind a failing steps purge spends no attempt', () async {
    final exporter = HealthExporter();
    await putDay({
      'steps': {
        'source': 'strap_counter',
        'band_measured': 400,
        'spans': [
          {'start_ts': noon, 'end_ts': noon + 3600, 'steps': 400},
        ],
      },
    });
    purgeFails = true;
    await exporter.exportAll(forceRetry: true);
    expect(writes, isNot(contains('STEPS')));
    expect((await retryState())[day], isNull,
        reason: 'a purge hold is not a failed export');

    purgeFails = false;
    await exporter.exportAll(forceRetry: true);
    expect(writes, contains('STEPS'));
  });

  test('no scalar is written beside a delete still running', () async {
    final exporter =
        HealthExporter(deleteTimeout: const Duration(milliseconds: 50));
    await putDay({
      'scalars': {'rhr': 55},
    });
    writes.clear();
    hangRhr = Completer<bool>();
    await exporter.exportAll(forceRetry: true);
    await exporter.exportAll(forceRetry: true);
    expect(writes, isNot(contains('RESTING_HEART_RATE')));

    final hang = hangRhr!;
    hangRhr = null;
    hang.complete(true);
    await Future<void>.delayed(Duration.zero);
    await exporter.exportAll(forceRetry: true);
    expect(writes, contains('RESTING_HEART_RATE'));
  });
}
