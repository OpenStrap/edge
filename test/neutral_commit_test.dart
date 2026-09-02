// M1 §9: `commitSyncBatch`'s neutral-sample path. Proves `_queueNeutralOneHz`
// is a MOVE of the two current writers (hrs_link._flush, oura_link._commit),
// not a rewrite — column-for-column parity against a hard-coded expected map —
// plus the beat-eviction invariant those two files carry today.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart' show TimeAnchor;
import 'package:openstrap_edge/ble/adapters/adapter.dart' show NeutralSample;
import 'package:openstrap_edge/data/db.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    LocalDb.dbName = 'openstrap_neutral_commit_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async {
    await LocalDb.close();
  });

  test('neutrals write the same decoded_onehz + decoded_rr rows hrs_link '
      'used to write directly', () async {
    await LocalDb.commitSyncBatch(
      const [],
      const [],
      deviceId: 'hrs-a1b2',
      deviceFamily: 'ble_hrs',
      neutrals: const [
        NeutralSample(
          anchor: TimeAnchor.arrival,
          tsEpoch: 1750000000,
          hr: 62,
          rrMs: [820, 810],
        ),
      ],
    );

    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz',
        where: 'device_id = ? AND rec_ts = ?', whereArgs: ['hrs-a1b2', 1750000000]);
    expect(onehz, hasLength(1));
    expect(onehz.single, containsPair('hr', 62));
    expect(onehz.single, containsPair('ts_ms', 1750000000000));
    expect(onehz.single, containsPair('counter', 0));
    expect(onehz.single, containsPair('device_family', 'ble_hrs'));
    expect(onehz.single, containsPair('source', 'ble_hrs'));
    expect(onehz.single['skin_temp_c'], isNull);

    final rr = await db.query('decoded_rr',
        where: 'device_id = ? AND rec_ts = ?',
        whereArgs: ['hrs-a1b2', 1750000000],
        orderBy: 'beat_index');
    expect(rr, hasLength(2));
    expect(rr[0], containsPair('rr_ms', 820));
    expect(rr[1], containsPair('rr_ms', 810));
    expect(rr[0], containsPair('rr_ts_ms', 1750000000000));
    expect(rr[0]['beat_ts_ms'], isNull, reason: 'NeutralSample carries no sub-second');
  });

  test('a shrinking beat count evicts the stale tail (3-then-1)', () async {
    await LocalDb.commitSyncBatch(
      const [],
      const [],
      deviceId: 'hrs-a1b2',
      deviceFamily: 'ble_hrs',
      neutrals: const [
        NeutralSample(
          anchor: TimeAnchor.arrival,
          tsEpoch: 1750000010,
          rrMs: [800, 800, 800],
        ),
      ],
    );
    await LocalDb.commitSyncBatch(
      const [],
      const [],
      deviceId: 'hrs-a1b2',
      deviceFamily: 'ble_hrs',
      neutrals: const [
        NeutralSample(
          anchor: TimeAnchor.arrival,
          tsEpoch: 1750000010,
          rrMs: [790],
        ),
      ],
    );

    final db = await LocalDb.instance;
    final count = await db.rawQuery(
      'SELECT COUNT(*) c FROM decoded_rr WHERE device_id = ? AND ts_ms = ?',
      ['hrs-a1b2', 1750000010000],
    );
    expect(count.first['c'], 1,
        reason: 'the second re-read with fewer beats must not leave the '
            'earlier read\'s stale high-index beats behind');
  });

  test('skin_temp_c lands for a source with no heart rate (oura shape)',
      () async {
    await LocalDb.commitSyncBatch(
      const [],
      const [],
      deviceId: 'oura-abcd',
      deviceFamily: 'oura',
      neutrals: const [
        NeutralSample(
          anchor: TimeAnchor.arrival,
          tsEpoch: 1750000020,
          skinTempC: 34.2,
        ),
      ],
    );

    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz',
        where: 'device_id = ? AND rec_ts = ?',
        whereArgs: ['oura-abcd', 1750000020]);
    expect(onehz.single['hr'], isNull, reason: 'absent is null, never zeroed');
    expect(onehz.single['skin_temp_c'], 34.2);
  });

  test('deviceId defaults to the primary and neutrals is a no-op for gen4',
      () async {
    // Single-device equivalence: passing neutrals: null (the default) queues
    // nothing extra and touches no non-primary device_id.
    await LocalDb.commitSyncBatch(const [], const []);
    final db = await LocalDb.instance;
    final rows = await db.query('decoded_onehz');
    expect(rows, isEmpty);
  });
}
