// Mi Smart Band 4 (`kMiBand4`, codename Cinco) on the Mi Band 2/3 engine:
// the crypt-flagged handshake (0x82 / 0x83, never a key install), then the
// same minute history through the real link, then the same column through
// the real derivation engine.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart' show ReplayBandLink;
import 'package:openstrap_edge/ble/adapters/miband234.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
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

/// The band's side of the crypt-flagged handshake. [accept] false answers the
/// proof with status 0x04, as a band holding a different key would.
List<List<int>> _band(List<int> w, {bool accept = true}) => switch (w[0]) {
      0x82 => [
          [0x10, 0x82, 0x01, ..._challenge],
        ],
      0x83 => accept &&
              w.sublist(2).toString() ==
                  miBand234AuthResponse(_key, _challenge).toString()
          ? [
              [0x10, 0x83, 0x01],
            ]
          : [
              [0x10, 0x83, 0x04],
            ],
      _ => const <List<int>>[],
    };

/// Runs [authenticateOnly] against [_band], returning the result and every
/// write the adapter made.
Future<(({int? status})?, List<List<int>>)> _auth(MiBand234Adapter a,
    {bool accept = true}) async {
  final link = ReplayBandLink();
  final writes = <List<int>>[];
  final pending = a.authenticateOnly(link);
  var served = 0;
  var result = pending.then((r) => r);
  var done = false;
  result = result.whenComplete(() => done = true);
  while (!done) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    while (served < link.writes.length) {
      final (_, v) = link.writes[served++];
      writes.add(v);
      for (final f in _band(v, accept: accept)) {
        link.feed(kHuami234AuthChar, f, atSec: 0);
      }
    }
  }
  await link.close();
  return (await result, writes);
}

void main() {
  group('registry', () {
    test('its own codename-keyed entry, Android only for now', () {
      expect(kMiBand4.id, 'huami_cinco');
      expect(kMiBand4.service, kMiBand234.service);
      expect(kBandRegistry, contains(kMiBand4));
      expect(kAskPickerSensors, contains(kMiBand4));
      expect(
          kAskPickerSensors.indexOf(kMiBand4),
          lessThan(kAskPickerSensors.indexOf(kHelioStrap)),
          reason: 'the FEE1 label the picker shows stays the strap\'s');
    });

    test('names: its own, and no other entry claims them', () {
      for (final n in ['mi smart band 4', 'cinco']) {
        final claims = [
          for (final e in kBandRegistry)
            if (e.nameMatcher?.call(n) ?? false) e.id,
        ];
        expect(claims, ['huami_cinco'], reason: n);
      }
      for (final n in ['mi band 3', 'mi smart band 5', 'mi smart band 4 nfc']) {
        expect(kMiBand4.nameMatcher!(n), isFalse, reason: n);
      }
    });

    test('same signals as Mi Band 2/3, in sync with kAdapterSignals', () {
      final s = MiBand234Adapter(key: _key, entry: kMiBand4).signals;
      expect(s, kMiBand234Signals);
      expect(kAdapterSignals['huami_cinco'], s);
      expect(s.containsKey(InputSignal.deviceHrv), isFalse);
    });

    test('the link and its lookup', () {
      expect(MiBand234Link.miBand4.entry, kMiBand4);
      expect(MiBand234Link.forId('huami_cinco'), MiBand234Link.miBand4);
      expect(MiBand234Link.forId('miband234'), MiBand234Link.instance);
      expect(MiBand234Link.forId('oura'), isNull);
    });
  });

  group('handshake', () {
    test('Mi Band 4: 82 00 02 01 00, then 83 00 <AES>, never a key install',
        () async {
      final (result, writes) = await _auth(
          MiBand234Adapter(key: _key, entry: kMiBand4, needsKeyWrite: true));
      expect(result, isNull, reason: 'the band accepted the key');
      expect(writes.first, [0x82, 0x00, 0x02, 0x01, 0x00]);
      expect(writes.last,
          [0x83, 0x00, ...miBand234AuthResponse(_key, _challenge)]);
      expect(writes.any((w) => w[0] == 0x01), isFalse,
          reason: 'a crypt-flagged band never takes a key from this app');
    });

    test('Mi Band 4: a wrong key is a refusal with its status', () async {
      final (result, _) = await _auth(
          MiBand234Adapter(key: _key, entry: kMiBand4), accept: false);
      expect(result?.status, 0x04);
    });

    test('Mi Band 2/3 still asks the old way', () async {
      final link = ReplayBandLink();
      final pending = MiBand234Adapter(
              key: _key, replyTimeout: const Duration(milliseconds: 20))
          .authenticateOnly(link);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(link.writes.first.$2, [0x02, 0x00, 0x02]);
      await link.close();
      await pending;
    });
  });

  group('through the link and the engine', () {
    final days = [
      for (var d = 1; d <= 4; d++)
        SyntheticDay(DateTime(2026, 10, d), nightHrOffset: d < 4 ? -6 : 0),
    ];
    const id = 'huami_cinco-synthetic';
    const dayId = '2026-10-04';
    const dayIds = {'2026-10-01', '2026-10-02', '2026-10-03', dayId};
    const profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'miband4_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.upsertDevice(
          id: id,
          adapterId: kMiBand4.id,
          remoteId: 'AA:BB:CC:00:00:44',
          label: kMiBand4.label);
      final now = DateTime(2026, 10, 4, 22, 30);
      await MiBand234Link.miBand4.ingestForTest(
        id,
        _key,
        (_, w) => _band(w),
        history: SyntheticDay.miBandHistory(days, now),
        nowSeconds: () => SyntheticDay.sec(now),
        window: const Duration(seconds: 5),
      );
    });

    tearDownAll(() async => LocalDb.close());

    test('its minute HR lands under its own device id', () async {
      final db = await LocalDb.instance;
      final rows = await db.query('decoded_onehz',
          where: 'device_id = ?', whereArgs: [id], limit: 5);
      expect(rows, isNotEmpty);
    });

    test('flag off: no number; flag on: the Mi Band column', () async {
      await LocalDb.setCursor(kActiveWearableCursor, id);
      expect(await DerivationEngine().runDays(profile, {dayId}, force: true), 0);
      expect(await LocalDb.dayResult(dayId), isNull);

      await LocalDb.setCursor(wearableEnabledCursor(kMiBand4.id), '1');
      for (var i = 0; i < 2; i++) {
        expect(await DerivationEngine().runDays(profile, dayIds, force: true), 4);
      }
      final cells = (await dayCells(dayId))!;
      String cls(String row) => cells[row]!['class'] as String;
      expect(cls('resting_hr'), 'ours');
      expect(cls('strain'), 'ours');
      expect(cls('readiness'), 'estimated');
      expect(cls('sleep_stages'), 'device');
      for (final r in ['hrv', 'respiratory_rate', 'spo2', 'stress', 'skin_temp']) {
        expect(cls(r), 'unavailable', reason: r);
      }
      final payload = (jsonDecode(
              (await LocalDb.dayResult(dayId))!['payload_json'] as String)
          as Map);
      expect(payload['device_family'], 'huami_cinco');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
