// A vendor night's stage minutes used to be floored PER EPOCH:
//
//   minutes[e.stage] = (minutes[e.stage] ?? 0) + (e.endSec - e.startSec) ~/ 60;
//
// A vendor epoch is often 30 s — Oura banks 960 of them for an 8 h night — so
// EVERY epoch contributed 0 and the Sleep screen's device staging read
// "Deep 0m / Light 0m" (and `duration_min: 0`) for a full night. The fix sums
// seconds per stage first and converts once, which also keeps the parts from
// claiming more than was staged when a night has a leftover under a minute.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 30 s epochs of [stage], starting at [fromSec].
List<VendorEpoch> _epochs(int fromSec, int count, String stage) => [
      for (var i = 0; i < count; i++)
        VendorEpoch(fromSec + i * 30, fromSec + (i + 1) * 30, stage),
    ];

void main() {
  group('vendorStageMinutes', () {
    test('30 s epochs add up instead of flooring each one to zero', () {
      final epochs = [
        ..._epochs(0, 40, 'deep'), // 1200 s = 20 min
        ..._epochs(1200, 80, 'light'), // 2400 s = 40 min
        ..._epochs(3600, 10, 'wake'), // 300 s = 5 min
      ];
      final m = vendorStageMinutes(epochs);
      expect(m['deep'], 20);
      expect(m['light'], 40);
      expect(m['wake'], 5);
      final nonWake = m.entries
          .where((e) => e.key != 'wake')
          .fold<int>(0, (s, e) => s + e.value);
      expect(nonWake, 60, reason: 'the night is an hour of sleep, not zero');
    });

    test('whole-minute epochs read the same as before the fix', () {
      final m = vendorStageMinutes([
        const VendorEpoch(0, 600, 'light'),
        const VendorEpoch(600, 900, 'deep'),
      ]);
      expect(m, {'light': 10, 'deep': 5});
    });

    test('a leftover under a minute is dropped once, not once per epoch', () {
      // 90 s of deep: one floor at the end gives 1 min; a per-epoch floor
      // gave 0.
      final m = vendorStageMinutes(_epochs(0, 3, 'deep'));
      expect(m['deep'], 1);
    });

    test('a non-positive epoch span is skipped, never subtracted', () {
      final m = vendorStageMinutes([
        const VendorEpoch(0, 600, 'light'),
        const VendorEpoch(300, 200, 'light'), // malformed, -100 s
      ]);
      expect(m['light'], 10);
    });

    test('mixed sub-minute stages still make one sleep minute', () {
      final epochs = [
        const VendorEpoch(0, 30, 'light'),
        const VendorEpoch(30, 60, 'deep'),
      ];
      // Per stage neither reaches a minute...
      expect(vendorStageMinutes(epochs), {'light': 0, 'deep': 0});
      // ...but together they did sleep for one, so the night must not say 0.
      expect(vendorSleepMinutes(epochs), 1);
      expect(vendorSleepMinutes([
        ...epochs,
        const VendorEpoch(60, 120, 'wake'), // awake is not sleep
      ]), 1);
    });
  });

  group('getDeviceNights', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'vendor_stage_minutes_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test('a 30 s-epoch night reports its real stage minutes', () async {
      const day = '2026-10-03';
      const family = 'oura';
      final wake = DateTime(2026, 10, 3, 7);
      final minute = DateTime(2026, 10, 3, 5); // 2 h earlier = 240 x 30 s
      final wakeSec = wake.millisecondsSinceEpoch ~/ 1000;
      final startSec = minute.millisecondsSinceEpoch ~/ 1000;
      expect(wakeSec - startSec, 7200);

      await LocalDb.upsertDevice(
          id: 'oura-test', adapterId: family, label: family);
      await LocalDb.putVendorSleepEpochs([
        ..._epochs(startSec, 40, 'deep'), // 20 min
        ..._epochs(startSec + 1200, 80, 'light'), // 40 min
        ..._epochs(startSec + 3600, 60, 'wake'), // 30 min
        ..._epochs(startSec + 5400, 60, 'rem'), // 30 min
      ], deviceId: 'oura-test', source: family);
      await LocalDb.setCursor(wearableEnabledCursor(family), '1');

      final nights = await LocalRepositoryImpl(getProfileMap: () => const {})
          .getDeviceNights(day);
      expect(nights, hasLength(1));
      final m = nights.single['stage_min'] as Map;
      expect(m['deep'], 20);
      expect(m['light'], 40);
      expect(m['wake'], 30);
      expect(m['rem'], 30);
      expect(nights.single['duration_min'], 90,
          reason: 'deep + light + rem, awake excluded');
    });

    test('a mixed 30 s night reports one minute asleep, zero per stage',
        () async {
      const day = '2026-10-04';
      const family = 'oura';
      final start = DateTime(2026, 10, 4, 7);
      final startSec = start.millisecondsSinceEpoch ~/ 1000;

      await LocalDb.upsertDevice(
          id: 'oura-mixed', adapterId: family, label: family);
      await LocalDb.putVendorSleepEpochs([
        VendorEpoch(startSec, startSec + 30, 'light'),
        VendorEpoch(startSec + 30, startSec + 60, 'deep'),
      ], deviceId: 'oura-mixed', source: family);

      final nights = await LocalRepositoryImpl(getProfileMap: () => const {})
          .getDeviceNights(day);
      expect(nights, hasLength(1));
      final m = nights.single['stage_min'] as Map;
      expect(m['light'], 0);
      expect(m['deep'], 0);
      expect(nights.single['duration_min'], 1,
          reason: 'the two 30 s stages together are a minute of sleep');
    });
  });
}
