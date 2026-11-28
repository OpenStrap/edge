// Banking a vendor hypnogram replaces what the new epochs overlap, and the
// overlap lookups stay off the PK range so the newest night does not walk the
// device's whole history.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const int _t0 = 1782000000;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'vendor_sleep_epoch_bank_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  List<VendorEpoch> minutes(int from, int n, String stage) => [
        for (var i = 0; i < n; i++)
          VendorEpoch(from + i * 60, from + i * 60 + 60, stage),
      ];

  Future<List<VendorEpoch>> stored() async =>
      [for (final n in await LocalDb.vendorSleepNights(0, 1 << 31)) ...n.epochs];

  test('a night re-read shifted by 30 s replaces the old one', () async {
    await LocalDb.putVendorSleepEpochs(minutes(_t0, 10, 'light'),
        deviceId: 'band', source: 'miband');
    // A gap, then a second night that must survive untouched.
    await LocalDb.putVendorSleepEpochs(minutes(_t0 + 6 * 3600, 5, 'deep'),
        deviceId: 'band', source: 'miband');
    await LocalDb.putVendorSleepEpochs(minutes(_t0 + 30, 10, 'rem'),
        deviceId: 'band', source: 'miband');
    final eps = await stored();
    expect(eps.where((e) => e.stage == 'light'), isEmpty);
    expect(eps.where((e) => e.stage == 'rem'), hasLength(10));
    expect(eps.where((e) => e.stage == 'deep'), hasLength(5));
  });

  test('wholeNights drops the old night outside the new epochs too', () async {
    await LocalDb.putVendorSleepEpochs(minutes(_t0, 20, 'light'),
        deviceId: 'band', source: 'helio', wholeNights: true);
    // Re-reported starting 10 min later: the old leading 10 min go too.
    await LocalDb.putVendorSleepEpochs(minutes(_t0 + 600, 10, 'deep'),
        deviceId: 'band', source: 'helio', wholeNights: true);
    final nights = await LocalDb.vendorSleepNights(0, 1 << 31);
    expect(nights, hasLength(1));
    expect(nights.single.onsetSec, _t0 + 600);
    expect(nights.single.epochs.map((e) => e.stage).toSet(), {'deep'});
  });

  test('the overlap lookups range on end_ts, not the open PK range', () async {
    await LocalDb.putVendorSleepEpochs(minutes(_t0, 1, 'light'),
        deviceId: 'band', source: 'miband');
    final db = await LocalDb.instance;
    for (final sql in const [
      'DELETE FROM vendor_sleep_epoch '
          'WHERE device_id = ? AND +start_ts < ? AND end_ts > ?',
      'SELECT night_onset_ts FROM vendor_sleep_epoch '
          'WHERE device_id = ? AND end_ts >= ? AND +start_ts < ? '
          'ORDER BY end_ts DESC LIMIT 1',
    ]) {
      final plan = (await db.rawQuery(
              'EXPLAIN QUERY PLAN $sql', ['band', _t0, _t0]))
          .map((r) => r['detail'])
          .join(' | ');
      expect(plan, contains('idx_vendor_sleep_epoch_end'), reason: sql);
      expect(plan, contains('end_ts>'), reason: sql);
    }
  });
}
