// The raw-free next-night nap cleanup reaches old bundles whatever version
// stamp they carry now: the readiness backfill restamps a pre-v106 day at the
// current version without touching its naps.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/compute/nap_overlap_cleanup.dart';
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_nap_overlap_cleanup_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a pre-v106 day restamped by the readiness backfill is still cleaned',
      () async {
    // 2026-08-02 22:30Z -> 2026-08-03 06:30Z: the next day's main sleep.
    const onset = 1785709800;
    const offset = onset + 8 * 3600;
    final afternoon = {
      'start': onset - 7 * 3600,
      'end': onset - 7 * 3600 + 1800,
      'duration_min': 30,
    };
    final phantom = {'start': onset, 'end': onset + 2400, 'duration_min': 40};
    final payload = {
      'naps': {
        'value': [afternoon, phantom],
        'count': 2,
      },
      'scalars': {'nap_min': 70.0, 'readiness': 64.0},
    };
    // Same bundle as a v100 derive, but stamped the way the backfill leaves it.
    await LocalDb.putDayResult(
      dayId: '2026-08-02',
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(payload),
      windowJson: '{}',
      finalized: true,
      readiness: 64.0,
    );
    await LocalDb.putDayResult(
      dayId: '2026-08-03',
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'sleep': {
          'window': {
            'value': {'onset_ms': onset * 1000, 'offset_ms': offset * 1000},
          },
        },
      }),
      windowJson: '{}',
      finalized: true,
    );

    // An earlier day whose next night has no sleep ('—') is skipped, not a
    // throw that ends the pass before the day above is reached.
    await LocalDb.putDayResult(
      dayId: '2026-07-30',
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'naps': {
          'value': [afternoon],
          'count': 1,
        },
      }),
      windowJson: '{}',
      finalized: true,
    );
    await LocalDb.putDayResult(
      dayId: '2026-07-31',
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'sleep': {
          'window': {'value': '—'},
        },
      }),
      windowJson: '{}',
      finalized: true,
    );

    expect(await cleanNextNightNapsOnce(), 1);
    final row = await LocalDb.dayResult('2026-08-02');
    expect((row!['algo_version'] as num).toInt(), kAlgoVersion);
    final out = jsonDecode(row['payload_json'] as String) as Map;
    final naps = (out['naps'] as Map)['value'] as List;
    expect(naps.map((n) => (n as Map)['start']), [afternoon['start']]);
    expect((out['naps'] as Map)['count'], 1);
    expect((out['scalars'] as Map)['nap_min'], 30.0);
    expect((out['scalars'] as Map)['readiness'], 64.0);
    final series = await LocalDb.metricSeries('nap_min');
    expect(series.where((r) => r['date'] == '2026-08-02').single['value'], 30.0);

    // One-shot: a second call does nothing.
    expect(await cleanNextNightNapsOnce(), 0);
  });
}
