// Mi Smart Band 5 (`kMiBand5`, Kongming) and 6 (`kMiBand6`, Pangu): Mi Band
// 4's crypt-flagged handshake and typed vendor key, with 8-byte minute
// records. The 8-byte history runs through the real link into the real
// engine; its filler bytes (0x7e) must never surface as a reading.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart' show ReplayBandLink;
import 'package:openstrap_edge/ble/adapters/miband234.dart';
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

final List<int> _key = List<int>.generate(16, (i) => i + 1);
final List<int> _challenge = List<int>.generate(16, (i) => 0xa0 + i);

List<List<int>> _band(List<int> w) => switch (w[0]) {
      0x82 => [
          [0x10, 0x82, 0x01, ..._challenge],
        ],
      0x83 => w.sublist(2).toString() ==
              miBand234AuthResponse(_key, _challenge).toString()
          ? [
              [0x10, 0x83, 0x01],
            ]
          : [
              [0x10, 0x83, 0x04],
            ],
      _ => const <List<int>>[],
    };

void main() {
  group('registry', () {
    test('two codename-keyed entries; names claimed by exactly one entry', () {
      const names = {
        'mi smart band 5': 'huami_kongming',
        'kongming': 'huami_kongming',
        'mi smart band 6': 'huami_pangu',
        'pangu': 'huami_pangu',
      };
      for (final MapEntry(key: n, value: id) in names.entries) {
        final claims = [
          for (final e in kBandRegistry)
            if (e.nameMatcher?.call(n) ?? false) e.id,
        ];
        expect(claims, [id], reason: n);
      }
      expect(kAskPickerSensors, isNot(contains(kMiBand5)));
      expect(kAskPickerSensors, isNot(contains(kMiBand6)));
    });

    test('links, typed-key pairing, signals', () {
      for (final e in [kMiBand5, kMiBand6]) {
        expect(MiBand234Link.forId(e.id)?.entry, e);
        expect(miBandTypedKeyPairFor(e.id), isNotNull);
        expect(kAdapterSignals[e.id],
            MiBand234Adapter(key: _key, entry: e).signals);
      }
      expect(miBandTypedKeyPairFor(kMiBand234.id), isNull,
          reason: 'Mi Band 2/3 pairs on its own screen with a minted key');
      expect(MiBand234Link.all, hasLength(4));
    });
  });

  test('Mi Band 5: the crypt-flagged challenge, no key install', () async {
    final link = ReplayBandLink();
    final pending = MiBand234Adapter(
            key: _key, entry: kMiBand5, needsKeyWrite: true)
        .authenticateOnly(link);
    var done = false;
    final result = pending.whenComplete(() => done = true);
    var served = 0;
    while (!done) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      while (served < link.writes.length) {
        for (final f in _band(link.writes[served++].$2)) {
          link.feed(kHuami234AuthChar, f, atSec: 0);
        }
      }
    }
    expect(await result, isNull);
    expect(link.writes.first.$2, [0x82, 0x00, 0x02, 0x01, 0x00]);
    expect(link.writes.any((w) => w.$2.first == 0x01), isFalse);
    await link.close();
  });

  group('Mi Band 6: 8-byte history through the link and the engine', () {
    final days = [
      for (var d = 1; d <= 4; d++)
        SyntheticDay(DateTime(2026, 10, d), nightHrOffset: d < 4 ? -6 : 0),
    ];
    const id = 'huami_pangu-synthetic';
    const dayId = '2026-10-04';
    const dayIds = {'2026-10-01', '2026-10-02', '2026-10-03', dayId};
    const profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'miband56_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.upsertDevice(
          id: id,
          adapterId: kMiBand6.id,
          remoteId: 'AA:BB:CC:00:00:66',
          label: kMiBand6.label);
      final now = DateTime(2026, 10, 4, 22, 30);
      await MiBand234Link.miBand6.ingestForTest(
        id,
        _key,
        (_, w) => _band(w),
        history: SyntheticDay.miBandHistory(days, now, recordSize: 8),
        nowSeconds: () => SyntheticDay.sec(now),
        window: const Duration(seconds: 5),
      );
    });

    tearDownAll(() async => LocalDb.close());

    test('minutes land one per minute with real HR, never the filler', () async {
      final db = await LocalDb.instance;
      final rows = await db.query('decoded_onehz',
          where: 'device_id = ?', whereArgs: [id], orderBy: 'rec_ts');
      expect(rows.length, greaterThan(60 * 24 * 3),
          reason: 'about a minute each across the four days');
      final ts = [for (final r in rows) (r['rec_ts'] as num).toInt()];
      for (var i = 1; i < ts.length; i++) {
        expect(ts[i] - ts[i - 1], greaterThanOrEqualTo(60));
      }
      expect(rows.where((r) => r['hr'] == 0x7e), isEmpty,
          reason: 'a filler byte read as HR means 4-byte decoding');
    });

    test('flag off: nothing; flag on: the Mi Band column', () async {
      await LocalDb.setCursor(kActiveWearableCursor, id);
      expect(await DerivationEngine().runDays(profile, {dayId}, force: true), 0);
      await LocalDb.setCursor(wearableEnabledCursor(kMiBand6.id), '1');
      for (var i = 0; i < 2; i++) {
        expect(await DerivationEngine().runDays(profile, dayIds, force: true), 4);
      }
      final cells = (await dayCells(dayId))!;
      String cls(String row) => cells[row]!['class'] as String;
      expect(cls('resting_hr'), 'ours');
      expect(cls('strain'), 'ours');
      expect(cls('sleep_stages'), 'device');
      expect(cls('readiness'), 'estimated');
      for (final r in ['hrv', 'respiratory_rate', 'stress', 'skin_temp']) {
        expect(cls(r), 'unavailable', reason: r);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
