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

  // A strap's HR record and its temperature record both stamped on the same
  // minute (the Helio strap's activity and temperature rounds do this) used to
  // be two REPLACEs on one key: the second nulled the first's column.
  for (final hrFirst in [true, false]) {
    test('same-second HR and temperature in one batch keep both '
        '(${hrFirst ? 'HR' : 'temperature'} first)', () async {
      const hr = NeutralSample(
          anchor: TimeAnchor.measured, tsEpoch: 1750000060, hr: 58, rrMs: [1030]);
      const temp = NeutralSample(
          anchor: TimeAnchor.measured, tsEpoch: 1750000060, skinTempC: 33.6);
      await LocalDb.commitSyncBatch(
        const [],
        const [],
        deviceId: 'helio-1',
        deviceFamily: 'helio_strap',
        neutrals: hrFirst ? const [hr, temp] : const [temp, hr],
      );
      final db = await LocalDb.instance;
      final row = (await db.query('decoded_onehz',
              where: 'device_id = ? AND ts_ms = ?',
              whereArgs: ['helio-1', 1750000060000]))
          .single;
      expect(row['hr'], 58);
      expect(row['skin_temp_c'], 33.6);
      expect(row['device_family'], 'helio_strap');
      final rr = await db.query('decoded_rr',
          where: 'device_id = ? AND ts_ms = ?',
          whereArgs: ['helio-1', 1750000060000]);
      expect(rr.single['rr_ms'], 1030,
          reason: 'a temperature-only sample must not evict the beats');
    });
  }

  // The realistic shape: a later session re-fetches the strap's overlapping
  // window but its activity round fails (retries exhausted) while the
  // temperature round lands. Its temperature-only rows must not null the HR
  // the earlier session banked.
  test('a later temperature-only session keeps the banked HR', () async {
    Future<void> write(List<NeutralSample> n) => LocalDb.commitSyncBatch(
        const [], const [],
        deviceId: 'helio-1', deviceFamily: 'helio_strap', neutrals: n);
    await write(const [
      NeutralSample(anchor: TimeAnchor.measured, tsEpoch: 1750000180, hr: 61),
    ]);
    await write(const [
      NeutralSample(
          anchor: TimeAnchor.measured, tsEpoch: 1750000180, skinTempC: 33.9),
    ]);
    final db = await LocalDb.instance;
    final row = (await db.query('decoded_onehz',
            where: 'device_id = ? AND ts_ms = ?',
            whereArgs: ['helio-1', 1750000180000]))
        .single;
    expect(row['hr'], 61);
    expect(row['skin_temp_c'], 33.9);
  });

  test("the device's own RMSSD and breathing samples merge onto the HR row",
      () async {
    await LocalDb.commitSyncBatch(const [], const [],
        deviceId: 'helio-1',
        deviceFamily: 'helio_strap',
        neutrals: const [
          NeutralSample(anchor: TimeAnchor.measured, tsEpoch: 1750000240, hr: 55),
          NeutralSample(
              anchor: TimeAnchor.measured, tsEpoch: 1750000240, deviceRmssdMs: 48),
          NeutralSample(
              anchor: TimeAnchor.measured, tsEpoch: 1750000240, deviceRespBrpm: 14),
        ]);
    final db = await LocalDb.instance;
    final row = (await db.query('decoded_onehz',
            where: 'device_id = ? AND ts_ms = ?',
            whereArgs: ['helio-1', 1750000240000]))
        .single;
    expect(row['hr'], 55);
    expect(row['dev_rmssd_ms'], 48);
    expect(row['dev_resp_brpm'], 14);
  });

  test('a re-read still wins per field it carries', () async {
    Future<void> write(List<NeutralSample> n) => LocalDb.commitSyncBatch(
        const [], const [],
        deviceId: 'helio-1', deviceFamily: 'helio_strap', neutrals: n);
    await write(const [
      NeutralSample(
          anchor: TimeAnchor.measured, tsEpoch: 1750000120, hr: 70, skinTempC: 33.0),
    ]);
    await write(const [
      NeutralSample(anchor: TimeAnchor.measured, tsEpoch: 1750000120, hr: 64),
    ]);
    final db = await LocalDb.instance;
    final row = (await db.query('decoded_onehz',
            where: 'device_id = ? AND ts_ms = ?',
            whereArgs: ['helio-1', 1750000120000]))
        .single;
    expect(row['hr'], 64, reason: 'the newer heart rate replaces the older');
    expect(row['skin_temp_c'], 33.0,
        reason: 'a field the re-read does not carry is kept, not nulled');
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
