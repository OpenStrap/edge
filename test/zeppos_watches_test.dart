// The Zepp OS watches on the Helio engine: Amazfit GTR 3 (`zeppos_verona`),
// GTR 3 Pro (`zeppos_madrid`) and GTS 3 (`zeppos_zurich`). Registry and
// lookups, a real-handshake session through the adapter, and one watch's
// synthetic days through the real derivation engine. The engine path is the
// same for all three, which the registry tests pin.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/helio_strap.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/ble/helio_strap_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const List<BandEntry> _watches = [kAmazfitGtr3, kAmazfitGtr3Pro, kAmazfitGts3];

final DateTime _now = DateTime(2026, 10, 4, 12, 0);
final int _nowSec = _now.millisecondsSinceEpoch ~/ 1000;
final DateTime _roundStart = DateTime(_now.year, _now.month, _now.day, 6, 0);

/// Real handshake, one activity round (two minutes: hr 65 + 20 steps, then
/// 10 steps with the hr sentinel), every other type "no data".
Future<List<BandEvent>> _session(BandEntry entry) async {
  final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
  final link = ReplayBandLink();
  final adapter = HelioStrapAdapter(
    entry: entry,
    nowSeconds: () => _nowSec,
    authKeyReader: () async => key,
    firstReplyTimeout: const Duration(milliseconds: 200),
    quietTimeout: const Duration(milliseconds: 30),
  );
  final kp = keypairFrom(
      Uint8List.fromList(List.generate(24, (i) => (i * 7 + 3) % 256)));
  final remoteRandom =
      Uint8List.fromList(List.generate(16, (i) => (i * 11 + 5) % 256));
  final decoder = Huami2021Decoder();
  final encoder = Huami2021Encoder();
  void auth(List<int> body) {
    for (final c in encoder.encode(kHuami2021AuthEndpoint, body)) {
      link.feed(kHuami2021ChunkNotifyChar, c, atSec: _nowSec);
    }
  }

  final events = <BandEvent>[];
  final done = Completer<void>();
  final sub = adapter.run(link).listen(events.add, onDone: done.complete);
  unawaited(() async {
    var served = 0;
    while (!done.isCompleted) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      while (served < link.writes.length) {
        final (char, value) = link.writes[served++];
        if (char == kHuami2021ChunkWriteChar) {
          final frame = decoder.feed(value, sessionKey: null);
          if (frame == null || frame.endpoint != kHuami2021AuthEndpoint) continue;
          final p = frame.payload;
          if (p.isNotEmpty && p[0] == 0x04) {
            auth([0x10, 0x04, 0x01, ...remoteRandom, ...kp.publicKey]);
          } else if (p.isNotEmpty && p[0] == 0x05) {
            auth([0x10, 0x05, 0x01]);
          }
          continue;
        }
        if (char != kHuami2021FetchControlChar || value.isEmpty) continue;
        if (value[0] == 0x01) {
          final hasData = value[1] == kHuami2021TypeActivity;
          final n = hasData ? 2 : 0;
          final rs = hasData ? _roundStart : DateTime(1970);
          link.feed(
              kHuami2021FetchControlChar,
              [
                0x10, 0x01, 0x01, n, 0, 0, 0,
                rs.year & 0xff, (rs.year >> 8) & 0xff, rs.month, rs.day,
                rs.hour, rs.minute, rs.second,
              ],
              atSec: _nowSec);
        } else if (value.length == 1 && value[0] == 0x02) {
          link.feed(kHuami2021FetchDataChar,
              [0, 0, 0, 20, 65, 0, 0, 0, 0, 0, 0, 10, 0xff, 0, 0, 0, 0],
              atSec: _nowSec);
          link.feed(kHuami2021FetchControlChar, const [0x10, 0x02, 0x01],
              atSec: _nowSec);
        }
      }
    }
  }());
  await done.future.timeout(const Duration(seconds: 20));
  await sub.cancel();
  await link.close();
  return events;
}

Map<String, dynamic> _payload(Map<String, Object?> row) =>
    (jsonDecode(row['payload_json'] as String) as Map).cast<String, dynamic>();

void main() {
  group('registry', () {
    test('each watch is its own codename-keyed entry on the Zepp OS channels',
        () {
      expect(_watches.map((e) => e.id),
          ['zeppos_verona', 'zeppos_madrid', 'zeppos_zurich']);
      for (final e in _watches) {
        expect(e.service, kHelioStrap.service, reason: e.id);
        expect(e.requiredCharacteristics, kHelioStrap.requiredCharacteristics,
            reason: e.id);
        expect(kBandRegistry, contains(e));
        expect(kAskPickerSensors, contains(e));
      }
    });

    test('names map to exactly one entry, the right one', () {
      const names = <String, String>{
        'amazfit gtr 3': 'zeppos_verona',
        'amazfit gtr 3e': 'zeppos_verona',
        'verona': 'zeppos_verona',
        'amazfit gtr 3 pro': 'zeppos_madrid',
        'madrid': 'zeppos_madrid',
        'madrid w': 'zeppos_madrid',
        'amazfit gts 3': 'zeppos_zurich',
        'amazfit gts 3e': 'zeppos_zurich',
        'zurich': 'zeppos_zurich',
      };
      for (final MapEntry(key: name, value: id) in names.entries) {
        final claims = [
          for (final e in kBandRegistry)
            if (e.nameMatcher?.call(name) ?? false) e.id,
        ];
        expect(claims, [id], reason: name);
      }
      for (final name in ['amazfit gtr 4', 'amazfit gts 3 pro', 'gtr 3']) {
        expect(_watches.where((e) => e.nameMatcher!(name)), isEmpty,
            reason: name);
      }
    });

    test('signals are the basic Zepp OS set, in sync with kAdapterSignals', () {
      for (final e in _watches) {
        final s = HelioStrapAdapter(entry: e).signals;
        expect(s, kZeppOsSignals, reason: e.id);
        expect(kAdapterSignals[e.id], s, reason: e.id);
        expect(s.containsKey(InputSignal.deviceHrv), isFalse);
      }
    });

    test('links, pairing and key slots are per watch', () {
      for (final e in _watches) {
        expect(HelioStrapLink.forId(e.id)?.entry, e, reason: e.id);
        expect(zeppOsTypedKeyPairFor(e.id), isNotNull, reason: e.id);
      }
      expect(HelioStrapLink.all.map((l) => l.entry.id).toSet(), hasLength(5));
      expect(HelioStrapLink.forId('oura'), isNull);
      expect(zeppOsTypedKeyPairFor('oura'), isNull);
      final slots = {
        for (final l in HelioStrapLink.all) zeppOsKeySlot(l.entry),
      };
      expect(slots, hasLength(5), reason: 'no two devices share a key slot');
    });

    test('attribution is Amazfit for the watches', () {
      for (final e in _watches) {
        expect(zeppOsAttribution(e), 'Amazfit', reason: e.id);
      }
    });
  });

  test('GTR 3 session: real handshake, HR and steps decoded', () async {
    final events = await _session(kAmazfitGtr3);
    expect(events.whereType<BandNote>(), isEmpty);
    final hr = [
      for (final b in events.whereType<SampleBatch>())
        for (final s in b.samples)
          if (s.hr != null) s,
    ];
    expect(hr.map((s) => s.hr), [65]);
    final steps = [
      for (final v in events.whereType<VendorScalars>()) ...v.rows,
    ].singleWhere((o) => o.key == 'steps');
    expect(steps.value, 30);
    expect(steps.attribution, 'Amazfit');
  });

  group('GTS 3 through the engine', () {
    final days = [
      for (var d = 1; d <= 4; d++)
        SyntheticDay(DateTime(2026, 10, d), nightHrOffset: d < 4 ? -6 : 0),
    ];
    const id = 'zeppos_zurich-synthetic';
    final family = kAmazfitGts3.id;
    const dayId = '2026-10-04';
    const dayIds = {'2026-10-01', '2026-10-02', '2026-10-03', dayId};
    const profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'zeppos_watches_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.upsertDevice(id: id, adapterId: family, label: kAmazfitGts3.label);
      final minuteHr = <int, int>{};
      for (final d in days) {
        for (final MapEntry(key: t, value: bpm) in d.hr.entries) {
          if (t % 60 == 0) minuteHr[t] = bpm;
        }
      }
      await LocalDb.commitSyncBatch(const [], const [],
          deviceId: id,
          deviceFamily: family,
          neutrals: [
            for (final t in minuteHr.keys.toList()..sort())
              NeutralSample(
                  anchor: TimeAnchor.measured, tsEpoch: t, hr: minuteHr[t]),
          ]);
      for (final d in days) {
        await LocalDb.putVendorSleepEpochs([
          for (final (a, b, st) in d.hypnogramBlocks()) VendorEpoch(a, b, st.name),
        ], deviceId: id, source: family);
      }
    });

    tearDownAll(() async => LocalDb.close());

    test('flag off: nothing; flag on: strain, resting HR, readiness estimate',
        () async {
      await LocalDb.setCursor(kActiveWearableCursor, id);
      expect(await DerivationEngine().runDays(profile, {dayId}, force: true), 0);
      expect(await LocalDb.dayResult(dayId), isNull);

      await LocalDb.setCursor(wearableEnabledCursor(family), '1');
      // Twice: strain abstains until three prior days have a level, which
      // the first pass is what writes.
      for (var i = 0; i < 2; i++) {
        expect(
            await DerivationEngine().runDays(profile, dayIds, force: true), 4);
      }
      final cells = (await dayCells(dayId))!;
      String cls(String row) => cells[row]!['class'] as String;
      expect(cls('strain'), 'ours');
      expect(cls('resting_hr'), 'ours');
      expect(cells['resting_hr']!['method'], 'hr_1min');
      expect(cls('readiness'), 'estimated');
      expect(cls('sleep_window'), 'ours');
      for (final r in ['hrv', 'respiratory_rate', 'stress', 'skin_temp']) {
        expect(cls(r), 'unavailable', reason: r);
        expect(cells[r]!['reason'], isNotEmpty);
      }
      expect(_payload((await LocalDb.dayResult(dayId))!)['device_family'],
          family);

      await LocalDb.putObservations([
        Observation(
          at: DateTime(2026, 10, 4),
          sourceKind: ObservationSource.vendor,
          key: 'steps',
          value: 7000,
          unit: 'steps',
          attribution: 'Amazfit',
        ),
      ], deviceId: id);
      await DerivationEngine().runDays(profile, {dayId}, force: true);
      expect((_payload((await LocalDb.dayResult(dayId))!)['scalars'] as Map)['steps'],
          7000);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
