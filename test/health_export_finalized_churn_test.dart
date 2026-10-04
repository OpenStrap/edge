import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';

/// Three finalized days, the oldest of which keeps failing to write. The two
/// newer days export fine but stay above the cursor while it retries; they
/// must not be deleted and rewritten again on every pass in the meantime.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_health');
  // Only reached on an Apple host; the native sleep writer has nothing to do.
  const appleSleep = MethodChannel('openstrap/healthkit_sleep');
  const days = ['2026-08-01', '2026-08-02', '2026-08-03'];
  var failFirstDay = true;
  final writes = <String, int>{};

  String dayOf(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_churn_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    for (final d in days) {
      await LocalDb.putDayResult(
        dayId: d,
        algoVersion: 41,
        payloadJson: '{"scalars":{"rhr":52.0}}',
        windowJson: '{}',
        finalized: true,
      );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'delete') return true;
          if (call.method != 'writeData') return null;
          final day = dayOf((call.arguments as Map)['startTime'] as int);
          writes[day] = (writes[day] ?? 0) + 1;
          return !(failFirstDay && day == days.first);
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

  test('finalized days behind a retrying day are written once', () async {
    final exporter = HealthExporter();
    expect(await exporter.exportAll(), 2);
    // unset (null) on non-apple hosts, '' after the apple sleep-epoch reset;
    // the exporter reads both as "nothing exported yet".
    expect(await LocalDb.getCursor('health_export_through') ?? '', '');
    final afterFirst = Map.of(writes);

    // The failing day is in backoff; nothing is due.
    expect(await exporter.exportAll(), 0);
    expect(writes, afterFirst);

    // Once the blocker lands, the cursor moves past all three without
    // rewriting the two that were already done.
    failFirstDay = false;
    expect(await exporter.exportAll(forceRetry: true), 1);
    expect(await LocalDb.getCursor('health_export_through'), days.last);
    expect(writes[days[1]], afterFirst[days[1]]);
    expect(writes[days[2]], afterFirst[days[2]]);
  });
}
