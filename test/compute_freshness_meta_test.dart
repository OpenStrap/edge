// refreshComputeFreshness runs after every derive pass, so it reads day rows
// payload-free and fetches a bundle only for the rows it visits. These pin
// what it reports when today has no row yet, the case that used to walk and
// decode all 30 bundles, and that it reads the SERVED version of each day.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late String dir;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_compute_freshness_meta_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    db = await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  String daysAgo(int n) {
    final d = DateTime.now().subtract(Duration(days: n));
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> put(
    String day, {
    int version = kAlgoVersion,
    bool sleep = false,
    num? readiness,
    int computedAt = 1,
  }) async {
    await db.insert('day_result', {
      'day_id': day,
      'algo_version': version,
      'payload_json': jsonEncode({
        'scalars': {'readiness': ?readiness},
        if (sleep)
          'sleep': {
            'accounting': {
              'value': {'tst_sec': 6 * 3600},
            },
          },
      }),
      'computed_at': computedAt,
      'finalized': 1,
    });
  }

  Future<Map<String, dynamic>> today() async {
    await LocalDb.refreshComputeFreshness();
    final row = await LocalDb.computeFreshness('today');
    return jsonDecode(row!['payload_json'] as String) as Map<String, dynamic>;
  }

  test('no row for today: overnight and recovery come from older days',
      () async {
    expect(daysAgo(0), todayLabel());
    await put(daysAgo(1), sleep: true, computedAt: 11);
    await put(daysAgo(2));
    await put(daysAgo(3), sleep: true, readiness: 64, computedAt: 33);
    for (var i = 4; i < 30; i++) {
      await put(daysAgo(i), sleep: true, readiness: 50);
    }
    final t = await today();
    expect(t['activity_state'], 'missing');
    expect(t['activity_day'], isNull);
    expect(t['overnight_day'], daysAgo(1));
    expect(t['overnight_computed_at'], 11);
    expect(t['recovery_day'], daysAgo(3));
    expect(t['recovery_computed_at'], 33);
    expect(t['recovery_state'], isNull);
    expect(t['showing_prior_overnight'], isTrue);
  });

  test('reads the served version of a day, not a newer unserved one',
      () async {
    await put(daysAgo(1), sleep: true, readiness: 70, computedAt: 5);
    // A row above the served ceiling must not be the one whose bundle is read.
    await db.insert('day_result', {
      'day_id': daysAgo(1),
      'algo_version': 1 << 30,
      'payload_json': jsonEncode({'skipped': true}),
      'computed_at': 99,
      'finalized': 1,
    });
    final t = await today();
    expect(t['overnight_day'], daysAgo(1));
    expect(t['recovery_day'], daysAgo(1));
    expect(t['recovery_computed_at'], 5);
  });

  test('capture still reports the band edge and the decoded counts', () async {
    await db.insert('decoded_onehz', {
      'ts_ms': 1700000000 * 1000,
      'rec_ts': 1700000000,
      'counter': 1,
      'hr': 60,
    });
    await LocalDb.refreshComputeFreshness();
    final row = await LocalDb.computeFreshness('capture');
    final c = jsonDecode(row!['payload_json'] as String);
    expect(c['latest_raw_rec_ts'], 1700000000);
    expect(c['decoded_onehz'], 1);
    expect(c['decoded_rr'], 0);
  });
}
