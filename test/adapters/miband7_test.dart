// Xiaomi / Mi Smart Band 7 (`kMiBand7`, codename L66) through the SAME
// adapter as the Helio Strap. A fake band runs its own real B-163 ECDH + AES
// side of the handshake, then answers two fetch rounds with data (activity,
// HRV) and every other type with "no data". The same script runs against
// both entries, so each assertion that differs between them is a difference
// the entry makes, not the fixture.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/helio_strap.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:pointycastle/export.dart' show AESEngine, ECBBlockCipher, KeyParameter;

Uint8List _aesDecrypt(Uint8List key, Uint8List data) {
  final c = ECBBlockCipher(AESEngine())..init(false, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    c.processBlock(data, i, out, i);
  }
  return out;
}

final DateTime _now = DateTime(2026, 10, 4, 12, 0);
final int _nowSec = _now.millisecondsSinceEpoch ~/ 1000;
final DateTime _roundStart = DateTime(_now.year, _now.month, _now.day, 6, 0);

/// One 1-minute activity record: steps @ +2, hr @ +3.
List<int> _activity(int steps, int hr) => [0, 0, steps & 0xff, hr & 0xff, 0, 0, 0, 0];

final List<int> _activityBytes = [..._activity(20, 65), ..._activity(10, 0xff)];

/// One HRV record (type 0x49): absolute `sec` u32 LE @ +0, value u8 @ +5.
final int _hrvSec = _nowSec - 3600;
final List<int> _hrvBytes = [
  _hrvSec & 0xff, (_hrvSec >> 8) & 0xff, (_hrvSec >> 16) & 0xff,
  (_hrvSec >> 24) & 0xff, 0, 42,
];

Future<List<BandEvent>> _run(BandEntry entry) async {
  final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
  final link = ReplayBandLink();
  final adapter = HelioStrapAdapter(
    entry: entry,
    nowSeconds: () => _nowSec,
    authKeyReader: () async => key,
    firstReplyTimeout: const Duration(milliseconds: 200),
    quietTimeout: const Duration(milliseconds: 30),
  );

  final deviceKeypair = keypairFrom(
      Uint8List.fromList(List.generate(24, (i) => (i * 7 + 3) % 256)));
  final remoteRandom =
      Uint8List.fromList(List.generate(16, (i) => (i * 11 + 5) % 256));
  final bandDecoder = Huami2021Decoder();
  final bandEncoder = Huami2021Encoder();
  Uint8List? sessionKey;

  // The data each round with data serves, by type, and the count its start
  // reply announces: records for activity, BYTES for every other type
  // (`huami2021FetchCountMatches`).
  final rounds = <int, (List<int>, int)>{
    kHuami2021TypeActivity: (_activityBytes, _activityBytes.length ~/ 8),
    kHuami2021TypeHrv: (_hrvBytes, _hrvBytes.length),
  };
  int? currentType;

  void feedAuth(List<int> body) {
    for (final chunk in bandEncoder.encode(kHuami2021AuthEndpoint, body)) {
      link.feed(kHuami2021ChunkNotifyChar, chunk, atSec: _nowSec);
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
          final frame = bandDecoder.feed(value, sessionKey: null);
          if (frame == null || frame.endpoint != kHuami2021AuthEndpoint) continue;
          final p = frame.payload;
          if (p.isNotEmpty && p[0] == 0x04) {
            final shared =
                sharedSecret(deviceKeypair.privateKey, p.sublist(4, 4 + 48));
            sessionKey = Uint8List(16);
            for (var i = 0; i < 16; i++) {
              sessionKey![i] = shared[i + 8] ^ key[i];
            }
            feedAuth([0x10, 0x04, 0x01, ...remoteRandom, ...deviceKeypair.publicKey]);
          } else if (p.isNotEmpty && p[0] == 0x05) {
            expect(_aesDecrypt(key, p.sublist(1, 17)), remoteRandom);
            expect(_aesDecrypt(sessionKey!, p.sublist(17, 33)), remoteRandom);
            feedAuth([0x10, 0x05, 0x01]);
          }
          continue;
        }
        if (char != kHuami2021FetchControlChar || value.isEmpty) continue;
        if (value[0] == 0x01) {
          currentType = value[1];
          final round = rounds[currentType];
          final n = round?.$2 ?? 0;
          final rs = round == null ? DateTime(1970) : _roundStart;
          link.feed(
              kHuami2021FetchControlChar,
              [
                0x10, 0x01, 0x01,
                n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff,
                rs.year & 0xff, (rs.year >> 8) & 0xff, rs.month, rs.day,
                rs.hour, rs.minute, rs.second,
              ],
              atSec: _nowSec);
        } else if (value.length == 1 && value[0] == 0x02) {
          final bytes = rounds[currentType]?.$1 ?? const <int>[];
          link.feed(kHuami2021FetchDataChar, [0, ...bytes], atSec: _nowSec);
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

List<NeutralSample> _samples(List<BandEvent> e) =>
    [for (final b in e.whereType<SampleBatch>()) ...b.samples];
List<Observation> _rows(List<BandEvent> e) =>
    [for (final v in e.whereType<VendorScalars>()) ...v.rows];
List<Uint8List> _raw(List<BandEvent> e) =>
    [for (final b in e.whereType<SampleBatch>()) ...?b.raw];

bool _containsSequence(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length && ok; j++) {
      ok = haystack[i + j] == needle[j];
    }
    if (ok) return true;
  }
  return false;
}

void main() {
  group('registry', () {
    test('Mi Band 7 is its own codename-keyed entry on the Zepp OS channels', () {
      expect(kMiBand7.id, 'zeppos_l66');
      expect(kMiBand7.service, kHelioStrap.service);
      expect(kMiBand7.requiredCharacteristics,
          kHelioStrap.requiredCharacteristics);
      expect(kBandRegistry, contains(kMiBand7));
      expect(kAskPickerSensors, contains(kMiBand7));
    });

    test('matches every name the band advertises, and nothing else', () {
      final m = kMiBand7.nameMatcher!;
      for (final name in [
        'xiaomi smart band 7',
        'mi smart band 7',
        'l66',
        'xiaomi smart band 7 a1b2',
        'xiaomi smart band 7 0f3c',
      ]) {
        expect(m(name), isTrue, reason: name);
      }
      for (final name in [
        'xiaomi smart band 7 pro',
        'xiaomi smart band 8',
        'mi band 3',
        'amazfit helio strap',
        'xiaomi smart band 7 abcde',
      ]) {
        expect(m(name), isFalse, reason: name);
      }
    });

    test('no earlier registry entry claims a Mi Band 7 name', () {
      for (final name in ['xiaomi smart band 7', 'mi smart band 7', 'l66']) {
        final first = kBandRegistry
            .firstWhere((e) => e.nameMatcher?.call(name) ?? false);
        expect(first, kMiBand7, reason: name);
      }
    });

    test('declares only HR, steps, stages and vendor scalars, in sync with '
        'kAdapterSignals', () {
      expect(kMiBand7Adapter.signals.keys.toSet(), {
        InputSignal.hrSparse,
        InputSignal.steps,
        InputSignal.deviceStages,
        InputSignal.vendorScalars,
      });
      expect(kAdapterSignals['zeppos_l66'], kMiBand7Adapter.signals);
      expect(kMiBand7Adapter.signals.containsKey(InputSignal.deviceHrv), isFalse);
      expect(kMiBand7Adapter.signals.containsKey(InputSignal.skinTempC), isFalse);
    });

    test('each family has its own key slot; Helio keeps its original one', () {
      expect(zeppOsKeySlot(kHelioStrap), kHelioStrapSecureStorageKey);
      expect(zeppOsKeySlot(kMiBand7), isNot(kHelioStrapSecureStorageKey));
    });
  });

  group('session', () {
    test('Mi Band 7: real handshake, HR and steps decoded, Xiaomi-attributed',
        () async {
      final events = await _run(kMiBand7);
      expect(events.whereType<BandNote>(), isEmpty);

      final hr = _samples(events).where((s) => s.hr != null).toList();
      expect(hr, hasLength(1));
      expect(hr.single.hr, 65);
      expect(hr.single.tsEpoch, _roundStart.millisecondsSinceEpoch ~/ 1000);

      final steps = _rows(events).singleWhere((o) => o.key == 'steps');
      expect(steps.value, 30);
      expect(steps.attribution, 'Xiaomi');
    });

    test('Mi Band 7: HRV bytes are banked raw and never decoded into a value',
        () async {
      final events = await _run(kMiBand7);
      expect(_samples(events).where((s) => s.deviceRmssdMs != null), isEmpty,
          reason: 'unit unconfirmed without hardware: no number labelled ms');
      expect(_rows(events).where((o) => (o.vendorKey ?? '').startsWith('hrv')),
          isEmpty);
      expect(_raw(events).any((f) => _containsSequence(f, _hrvBytes)), isTrue,
          reason: 'the HRV round is kept for a later re-decode');
    });

    test('Helio Strap: the same script still decodes HRV and stays '
        'Amazfit-attributed', () async {
      final events = await _run(kHelioStrap);
      final rmssd = _samples(events).where((s) => s.deviceRmssdMs != null);
      expect(rmssd, hasLength(1));
      expect(rmssd.single.deviceRmssdMs, 42);
      expect(_rows(events).singleWhere((o) => o.key == 'steps').attribution,
          kHelioStrapAttribution);
    });
  });
}
