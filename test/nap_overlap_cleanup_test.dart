// The raw-free next-night nap cleanup reaches old bundles whatever version
// stamp they carry now: the readiness backfill restamps a pre-v106 day at the
// current version without touching its naps.

import 'dart:convert';
import 'dart:io';

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

  test('a phantom already copied aside as a legacy edit is dropped too',
      () async {
    await LocalDb.deleteComputeFreshness(kNapNextNightCleanupKey);
    // 2026-09-02 22:30Z -> 2026-09-03 06:30Z.
    const onset = 1788388200;
    const offset = onset + 8 * 3600;
    final legacy = {
      'start': onset,
      'end': onset + 2400,
      'duration_min': 40,
      'source': 'legacy',
    };
    final manual = {
      'start': onset - 3 * 3600,
      'end': onset - 3 * 3600 + 1200,
      'duration_min': 20,
      'source': 'manual',
    };
    await LocalDb.putDayResult(
      dayId: '2026-09-02',
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'naps': {
          'value': [manual, legacy],
          'count': 2,
        },
        'scalars': {'nap_min': 60.0},
      }),
      windowJson: '{}',
      finalized: true,
    );
    await LocalDb.putDayResult(
      dayId: '2026-09-03',
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
    final db = await LocalDb.instance;
    for (final n in [legacy, manual]) {
      await db.insert('sleep_nap', {
        'day_id': '2026-09-02',
        'start_ts': n['start'],
        'end_ts': n['end'],
        'source': n['source'],
        'created_at': 0,
        'payload_json': jsonEncode(n),
      });
    }

    expect(await cleanNextNightNapsOnce(), 1);
    final out = jsonDecode(
        (await LocalDb.dayResult('2026-09-02'))!['payload_json'] as String) as Map;
    expect(((out['naps'] as Map)['value'] as List).map((n) => (n as Map)['source']),
        ['manual']);
    final edits = await LocalDb.napEdits('2026-09-02');
    expect(edits.map((e) => e['source']), ['manual']);
  });

  test('importing nap edits alone re-arms the cleanup', () async {
    final db = await LocalDb.instance;
    await db.insert('sleep_nap', {
      'day_id': '2026-09-02',
      'start_ts': 1788388200,
      'end_ts': 1788388200 + 2400,
      'source': 'legacy',
      'created_at': 0,
      'payload_json': jsonEncode({'duration_min': 40, 'source': 'legacy'}),
    });
    final dir = Directory.systemTemp.createTempSync('nap-cleanup-import-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'backup.db');
    await db.execute('VACUUM INTO ?', [path]);
    await db.delete('sleep_nap',
        where: 'day_id = ? AND source = ?', whereArgs: ['2026-09-02', 'legacy']);
    await LocalDb.putComputeFreshness(kNapNextNightCleanupKey, '{}');

    final counts = await LocalDb.importFromDbFile(path);
    expect(counts['day_result'] ?? 0, 0);
    expect(counts['sleep_nap'], greaterThan(0));
    expect(await LocalDb.computeFreshness(kNapNextNightCleanupKey), isNull);
  });
}
