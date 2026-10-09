// A Mi Band 2/3 synced the way background sync does it: more than once a
// day, resuming each time from the `miband_since` cursor. Every night must
// land once, whole, whatever instant the syncs ran at.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/miband234.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const String _band = 'miband-resync';

Future<void> _fresh(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory
      .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
  await LocalDb.upsertDevice(
      id: _band,
      adapterId: 'miband234',
      remoteId: 'AA:BB:CC:00:00:44',
      label: 'miband234');
}

Future<void> _sync(List<SyntheticDay> days, DateTime now) async {
  final key = List<int>.generate(16, (i) => i + 1);
  final challenge = List<int>.generate(16, (i) => 0xa0 + i);
  await MiBand234Link.instance.ingestForTest(
    _band,
    key,
    (_, w) => switch (w[0]) {
      0x02 => [
          [0x10, 0x02, 0x01, ...challenge],
        ],
      0x03 => [
          [
            0x10,
            0x03,
            w.sublist(2).toString() ==
                    miBand234AuthResponse(key, challenge).toString()
                ? 0x01
                : 0x04,
          ],
        ],
      _ => const <List<int>>[],
    },
    history: SyntheticDay.miBandHistory(days, now),
    nowSeconds: () => SyntheticDay.sec(now),
    window: const Duration(seconds: 2),
  );
}

/// The band's banked stage minutes for [date], summed over every row.
Future<num> _stageMin(String date, String stage) async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery(
      'SELECT SUM(value) AS v FROM observation '
      'WHERE device_id = ? AND date = ? AND vendor_key = ?',
      [_band, date, 'sleep_${stage}_min']);
  return (r.first['v'] as num?) ?? 0;
}

/// Every banked night of the band, with why it could not stage a day.
Future<List<String?>> _rejections() async => [
      for (final n in await LocalDb.vendorSleepNights(0, 1 << 40))
        vendorNightRejection(n,
            dataStartSec: 0, dataEndSec: 1 << 40, ours: null, unclaimed: true),
    ];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(LocalDb.close);

  test('a sync in the middle of the night, then one after waking: the night '
      'counts once, whole', () async {
    await _fresh('miband_resync_midnight_test.db');
    final days = [
      SyntheticDay(DateTime(2026, 10, 3)),
      SyntheticDay(DateTime(2026, 10, 4)),
    ];
    await _sync(days, DateTime(2026, 10, 4, 3));
    await _sync(days, DateTime(2026, 10, 4, 9));
    expect(await _stageMin('2026-10-04', 'deep'), days.last.deepMin);
    expect(await _stageMin('2026-10-03', 'deep'), days.first.deepMin);
    expect(await _rejections(), everyElement(isNull));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a sync each morning: the night before last keeps its start', () async {
    await _fresh('miband_resync_mornings_test.db');
    final days = [
      for (var d = 2; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
    ];
    // Asleep at midnight before the 2nd, and before the 3rd, so the second
    // sync's cursor (the start of the 3rd) falls inside a night.
    expect(days.first.sleepOnset.day, 1);
    expect(days[1].sleepOnset.day, 2);
    await _sync(days, DateTime(2026, 10, 3, 8));
    // The cursor the LAST banked day moved it to, though its rows rode an
    // earlier commit: the start of the first day not read whole, the night
    // into it having closed.
    expect(await LocalDb.getCursorInt('miband_since:$_band'),
        SyntheticDay.sec(DateTime(2026, 10, 3)));
    await _sync(days, DateTime(2026, 10, 4, 8));
    for (final d in days) {
      final date = '2026-10-0${d.day.day}';
      expect(await _stageMin(date, 'deep'), d.deepMin, reason: date);
      // Its light holds REM.
      final lightMin = d.stage.values
              .where((s) => s == Stage.light || s == Stage.rem)
              .length ~/
          60;
      expect(await _stageMin(date, 'light'), lightMin, reason: date);
    }
    final nights = await LocalDb.vendorSleepNights(0, 1 << 40);
    expect(nights, hasLength(3));
    expect(nights.first.onsetSec,
        lessThan(SyntheticDay.sec(DateTime(2026, 10, 2))));
    expect(await _rejections(), everyElement(isNull));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
