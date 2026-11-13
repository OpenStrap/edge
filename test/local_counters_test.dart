// Local diagnostics that ride inside a contributed database: the band
// firmware seen per connection and the usage counters.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Map<String, dynamic>> _payload(String key) async => (jsonDecode(
        (await LocalDb.computeFreshness(key))!['payload_json'] as String) as Map)
    .cast<String, dynamic>();

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'local_counters_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async => LocalDb.close());

  test('firmware: latest plus one history entry per change', () async {
    await LocalDb.noteBandFirmware('41.16.6.0', nowSec: 100);
    await LocalDb.noteBandFirmware('41.16.6.0', nowSec: 200);
    await LocalDb.noteBandFirmware('41.17.1.0', nowSec: 300);
    final m = await _payload(LocalDb.kBandFirmwareKey);
    expect(m['fw'], '41.17.1.0');
    expect(m['last_seen'], 300);
    expect([for (final e in m['history'] as List) e['fw']],
        ['41.16.6.0', '41.17.1.0']);
  });

  test('usage counters count', () async {
    await LocalDb.bumpUsageCounter('coach_open');
    await LocalDb.bumpUsageCounter('coach_open');
    await LocalDb.bumpUsageCounter('health_upload_failed');
    final m = await _payload(LocalDb.kUsageCountersKey);
    expect(m, {'coach_open': 2, 'health_upload_failed': 1});
  });
}
