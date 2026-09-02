// M1 §10: `BandHost` — the one place that drives an adapter and banks what
// comes back. Exercised directly here (not through hrs_link.dart, which does
// not yet call it — see M1's commit order) using the real `BleHrsAdapter`
// over a `ReplayBandLink`, the same fixture shape as `test/hrs_link_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/data/db.dart';

const List<int> kBpmOnly = <int>[0x00, 61];
const List<int> kHrWithTwoRr = <int>[
  0x16,
  120,
  0xF4, 0x01, // 500 ticks = 488 ms
  0x00, 0x02, // 512 ticks = 500 ms
];

void main() {
  const deviceId = 'hrs-a1b2c3d4';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'band_host_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('drives an adapter over a replay link and banks HR + beats', () async {
    final host = BandHost(adapter: kBleHrsAdapter, deviceId: deviceId);
    final link = ReplayBandLink();
    final future = host.run(link);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kHrWithTwoRr,
        atSec: 1_800_000_000);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kBpmOnly,
        atSec: 1_800_000_001);
    await link.close();
    await future;
    await host.stop();

    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz', orderBy: 'ts_ms');
    expect(onehz, hasLength(2));
    expect(onehz.first['device_id'], deviceId);
    expect(onehz.first['hr'], 120);
    expect(onehz.first['source'], 'ble_hrs');
    expect(onehz.first['device_family'], 'ble_hrs');

    final rr = await db.query('decoded_rr', orderBy: 'beat_index');
    expect(rr, hasLength(2));
    expect(rr[0]['rr_ms'], 488);
    expect(rr[1]['rr_ms'], 500);
  });

  test('the live reading publishes as samples arrive', () async {
    final host = BandHost(adapter: kBleHrsAdapter, deviceId: deviceId);
    final link = ReplayBandLink();
    final future = host.run(link);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kHrWithTwoRr,
        atSec: 1_800_000_010);
    // Give the stream a turn to process the notification.
    await Future<void>.delayed(Duration.zero);
    expect(host.reading.value?.bpm, 120);
    await link.close();
    await future;
    await host.stop();
    expect(host.reading.value, isNull, reason: 'stop() clears the reading');
  });

  test('an admitSample predicate the caller supplies can still refuse a '
      'second (the Oura-style bound, kept separate from any gate)', () async {
    final host = BandHost(
      adapter: kBleHrsAdapter,
      deviceId: deviceId,
      admitSample: (ts) => ts != 1_800_000_030,
    );
    final link = ReplayBandLink();
    final future = host.run(link);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kHrWithTwoRr,
        atSec: 1_800_000_030);
    await link.close();
    await future;
    await host.stop();

    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz');
    expect(onehz, isEmpty);
  });

  test('the sync_cursor advance is namespaced to THIS device, never the '
      'primary\'s bare key', () async {
    final host = BandHost(adapter: kBleHrsAdapter, deviceId: deviceId);
    final link = ReplayBandLink();
    final future = host.run(link);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kHrWithTwoRr,
        atSec: 1_800_000_020);
    await link.close();
    await future;
    await host.stop();

    expect(await LocalDb.getCursorInt(LocalDb.cursorKeyFor('rec_ts_hw', deviceId)),
        1_800_000_020);
    expect(await LocalDb.getCursorInt('rec_ts_hw'), isNull,
        reason: 'the primary\'s bare cursor key must be untouched');
  });
}
