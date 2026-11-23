// The first Amazfit watches (Bip S, Bip U, GTS, GTS 2, GTR) on the Mi Band
// 2/3 engine: Mi Band 4's crypt-flagged handshake and typed vendor key, with
// 4- or 8-byte minute records. Histories run through the real link into the
// real engine.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart' show ReplayBandLink;
import 'package:openstrap_edge/ble/adapters/miband234.dart';
import 'package:openstrap_edge/ble/helio_strap_link.dart' show zeppOsTypedKeyPairFor;
import 'package:openstrap_edge/ble/miband_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show kPairableSensors;
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

const _watches = [
  kAmazfitBipS,
  kAmazfitBipU,
  kAmazfitGts,
  kAmazfitGts2,
  kAmazfitGtr,
];

void main() {
  test('exact names: each claimed by one entry, newer models by none', () {
    const names = {
      'amazfit bip s': 'huami_tonlesap',
      'amazfit bip u': 'huami_como',
      'amazfit gts': 'huami_kestrel',
      'amazfit kestrel': 'huami_kestrel',
      'amazfit gts 2': 'huami_newton',
      'newton': 'huami_newton',
      'amazfit gtr': 'huami_falcon',
    };
    List<String> claims(String n) => [
          for (final e in kBandRegistry)
            if (e.nameMatcher?.call(n) ?? false) e.id,
        ];
    for (final MapEntry(key: n, value: id) in names.entries) {
      expect(claims(n), [id], reason: n);
    }
    for (final n in ['amazfit gtr 2', 'amazfit gts 2 mini', 'amazfit bip u pro']) {
      expect(claims(n).where((id) => id.startsWith('huami_')), isEmpty,
          reason: n);
    }
  });

  test('every key-only device offers no plain pair, so its screen asks for '
      'the one key', () {
    final keyOnly = [
      for (final s in kPairableSensors)
        if (zeppOsTypedKeyPairFor(s.entry.id) != null ||
            miBandTypedKeyPairFor(s.entry.id) != null)
          s,
    ];
    // helio, 4 zepp os, mi band 4-6, 5 watches
    expect(keyOnly, hasLength(13));
    for (final s in keyOnly) {
      expect(s.pick, isNull, reason: s.entry.id);
    }
  });

  test('links, typed-key pairing, signals, watch kind', () {
    for (final e in _watches) {
      expect(e.kind, DeviceKind.watch);
      expect(kAskPickerSensors, contains(e));
      expect(MiBand234Link.forId(e.id)?.entry, e);
      expect(miBandTypedKeyPairFor(e.id), isNotNull);
      expect(kAdapterSignals[e.id],
          MiBand234Adapter(key: _key, entry: e).signals);
    }
  });

  test('GTR: the crypt-flagged challenge, no key install', () async {
    final link = ReplayBandLink();
    final pending =
        MiBand234Adapter(key: _key, entry: kAmazfitGtr, needsKeyWrite: true)
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

  group('history through the link and the engine', () {
    final days = [
      for (var d = 1; d <= 4; d++)
        SyntheticDay(DateTime(2026, 10, d), nightHrOffset: d < 4 ? -6 : 0),
    ];
    const dayId = '2026-10-04';
    const dayIds = {'2026-10-01', '2026-10-02', '2026-10-03', dayId};
    const profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
    // GTS 2 sends 8-byte minutes, GTR 4-byte ones.
    const gts2 = 'huami_newton-synthetic';
    const gtr = 'huami_falcon-synthetic';

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'amazfit_g1_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      final now = DateTime(2026, 10, 4, 22, 30);
      for (final (id, entry, size) in [
        (gts2, kAmazfitGts2, 8),
        (gtr, kAmazfitGtr, 4),
      ]) {
        await LocalDb.upsertDevice(
            id: id,
            adapterId: entry.id,
            remoteId: 'AA:BB:CC:00:00:${size}0',
            label: entry.label);
        await MiBand234Link.forId(entry.id)!.ingestForTest(
          id,
          _key,
          (_, w) => _band(w),
          history: SyntheticDay.miBandHistory(days, now, recordSize: size),
          nowSeconds: () => SyntheticDay.sec(now),
          window: const Duration(seconds: 5),
        );
      }
    });

    tearDownAll(() async => LocalDb.close());

    test('both land a minute each, the 8-byte filler never as HR', () async {
      final db = await LocalDb.instance;
      for (final id in [gts2, gtr]) {
        final rows = await db.query('decoded_onehz',
            where: 'device_id = ?', whereArgs: [id], orderBy: 'rec_ts');
        expect(rows.length, greaterThan(60 * 24 * 3), reason: id);
        expect(rows.where((r) => r['hr'] == 0x7e), isEmpty, reason: id);
      }
    });

    test('flag off: nothing; flag on: the Mi Band column', () async {
      await LocalDb.setCursor(kActiveWearableCursor, gts2);
      expect(await DerivationEngine().runDays(profile, {dayId}, force: true), 0);
      await LocalDb.setCursor(wearableEnabledCursor(kAmazfitGts2.id), '1');
      for (var i = 0; i < 2; i++) {
        // The first pass also re-scores the day owed a quiet level (+1).
        expect(await DerivationEngine().runDays(profile, dayIds, force: true),
            i == 0 ? 5 : 4);
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
