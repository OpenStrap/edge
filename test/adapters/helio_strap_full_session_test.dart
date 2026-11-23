// Full end-to-end scripted session for [HelioStrapAdapter]: a FAKE STRAP
// that runs its own real B-163 ECDH + AES side of the Huami2021 handshake
// (not a stub — the same math the adapter runs, mirrored), then answers one
// fetch round (activity) with protocol-correct bytes, every other type with
// "no data". Asserts the adapter actually completes authentication and
// emits a SampleBatch with the expected HR/steps samples decoded from it.
//
// Unlike `colmi_test.dart` (single notify channel per write channel), this
// protocol pushes replies across three different channels — the chunk
// transport's notify (auth), and the fetch channel's control/data chars —
// so the driver loop below routes by the WRITTEN BYTES, not just the write
// channel.

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

Uint8List _aesEcb(Uint8List key, Uint8List data, bool encrypt) {
  final c = ECBBlockCipher(AESEngine())..init(encrypt, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    c.processBlock(data, i, out, i);
  }
  return out;
}

Uint8List _aesDecrypt(Uint8List k, Uint8List d) => _aesEcb(k, d, false);

final DateTime _now = DateTime(2026, 10, 4, 12, 0);
final int _nowSec = _now.millisecondsSinceEpoch ~/ 1000;

/// One completed run's events and the link it ran over, for assertions.
Future<({List<BandEvent> events, ReplayBandLink link})> _run({
  Uint8List? authKey,
}) async {
  final key = authKey ?? Uint8List.fromList(List.generate(16, (i) => i + 1));
  final link = ReplayBandLink();
  final adapter = HelioStrapAdapter(
    nowSeconds: () => _nowSec,
    authKeyReader: () async => key,
    firstReplyTimeout: const Duration(milliseconds: 200),
    quietTimeout: const Duration(milliseconds: 30),
  );

  // ── the fake strap's own handshake state, computed for real ──
  final deviceKeypair = keypairFrom(
      Uint8List.fromList(List.generate(24, (i) => (i * 7 + 3) % 256)));
  final remoteRandom =
      Uint8List.fromList(List.generate(16, (i) => (i * 11 + 5) % 256));
  final strapDecoder = Huami2021Decoder();
  final strapEncoder = Huami2021Encoder();
  Uint8List? deviceSessionKey;

  // Activity round fixture: two 1-minute records starting at a fixed local
  // time, steps + hr both present on the first, steps-only on the second
  // (hr sentinel) — so the test proves both metrics decode independently.
  final activityRoundStart = DateTime(_now.year, _now.month, _now.day, 6, 0);
  const activitySteps1 = 20, activityHr1 = 65, activitySteps2 = 10;
  List<int> activityRecord(int steps, int hr) =>
      [0, 0, steps & 0xff, hr & 0xff, 0, 0, 0, 0];
  final activityBytes = <int>[
    ...activityRecord(activitySteps1, activityHr1),
    ...activityRecord(activitySteps2, 0xff), // hr sentinel: dropped
  ];

  /// Builds the strap's reply to one `[0x01, type, ...time8]` start request.
  /// Every type other than activity answers "no data".
  List<int> fetchStartReply(int type) {
    final hasData = type == kHuami2021TypeActivity;
    final expected = hasData ? activityBytes.length ~/ 8 : 0;
    final rs = hasData ? activityRoundStart : DateTime(1970);
    return [
      0x10, 0x01, 0x01, // status ok
      expected & 0xff, (expected >> 8) & 0xff, (expected >> 16) & 0xff,
      (expected >> 24) & 0xff,
      rs.year & 0xff, (rs.year >> 8) & 0xff, rs.month, rs.day, rs.hour,
      rs.minute, rs.second,
    ];
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
          final frame = strapDecoder.feed(value, sessionKey: null);
          if (frame == null || frame.endpoint != kHuami2021AuthEndpoint) {
            continue;
          }
          final p = frame.payload;
          if (p.isNotEmpty && p[0] == 0x04) {
            // Step 1: phone's public key. Reply step 2.
            final phonePublicKey = p.sublist(4, 4 + 48);
            final shared = sharedSecret(deviceKeypair.privateKey, phonePublicKey);
            deviceSessionKey = Uint8List(16);
            for (var i = 0; i < 16; i++) {
              deviceSessionKey![i] = shared[i + 8] ^ key[i];
            }
            final step2 = Uint8List.fromList(
                [0x10, 0x04, 0x01, ...remoteRandom, ...deviceKeypair.publicKey]);
            for (final chunk
                in strapEncoder.encode(kHuami2021AuthEndpoint, step2)) {
              link.feed(kHuami2021ChunkNotifyChar, chunk, atSec: _nowSec);
            }
          } else if (p.isNotEmpty && p[0] == 0x05) {
            // Step 4: the phone's proof. Verify both blocks decrypt to the
            // SAME remote-random this strap sent — real crypto, not a stub.
            final authProof = _aesDecrypt(key, p.sublist(1, 17));
            final sessionProof =
                _aesDecrypt(deviceSessionKey!, p.sublist(17, 33));
            expect(authProof, remoteRandom,
                reason: 'proof block 1 must decrypt under the shared auth key');
            expect(sessionProof, remoteRandom,
                reason: 'proof block 2 must decrypt under the derived '
                    'session key — proves the ECDH math matches on both '
                    'sides');
            final step5 = Uint8List.fromList([0x10, 0x05, 0x01]);
            for (final chunk
                in strapEncoder.encode(kHuami2021AuthEndpoint, step5)) {
              link.feed(kHuami2021ChunkNotifyChar, chunk, atSec: _nowSec);
            }
          }
          continue;
        }
        if (char == kHuami2021FetchControlChar) {
          if (value.isNotEmpty && value[0] == 0x01) {
            // Start request: [0x01, type, ...time8].
            final type = value[1];
            link.feed(kHuami2021FetchControlChar, fetchStartReply(type),
                atSec: _nowSec);
          } else if (value.length == 1 && value[0] == 0x02) {
            // Send-data trigger for the round just started. Only the
            // activity round (the last start reply with real data) ever
            // reaches this — reply with its two packets, then the round end.
            var counter = 0;
            for (final r in [
              activityRecord(activitySteps1, activityHr1),
              activityRecord(activitySteps2, 0xff),
            ]) {
              link.feed(kHuami2021FetchDataChar, [counter++, ...r],
                  atSec: _nowSec);
            }
            link.feed(kHuami2021FetchControlChar, const [0x10, 0x02, 0x01],
                atSec: _nowSec);
          }
          // `[0x03, 0x09]` (ack-keep) needs no reply.
        }
      }
    }
  }());

  await done.future.timeout(const Duration(seconds: 20));
  await sub.cancel();
  await link.close();
  return (events: events, link: link);
}

List<NeutralSample> _samples(List<BandEvent> e) =>
    [for (final b in e.whereType<SampleBatch>()) ...b.samples];
List<Observation> _rows(List<BandEvent> e) =>
    [for (final v in e.whereType<VendorScalars>()) ...v.rows];

void main() {
  test('declares the signals Helio actually supplies', () {
    expect(kHelioStrapAdapter.signals.keys, [
      InputSignal.hrSparse,
      InputSignal.steps,
      InputSignal.skinTempC,
      InputSignal.deviceStress,
      InputSignal.deviceHrv,
      InputSignal.deviceResp,
      InputSignal.deviceSpo2,
      InputSignal.deviceStages,
      InputSignal.vendorScalars,
    ]);
  });

  test('no auth key in secure storage ends the session with kHelioNoKeyNote',
      () async {
    final link = ReplayBandLink();
    final adapter = HelioStrapAdapter(
        nowSeconds: () => _nowSec, authKeyReader: () async => null);
    final events = await adapter.run(link).toList();
    expect(events, [const BandNote(kHelioNoKeyNote)]);
    expect(link.writes, isEmpty, reason: 'no key ⇒ nothing sent at all');
  });

  test('real B-163/AES handshake completes, then one fetch round decodes '
      'into the expected HR/steps samples', () async {
    final r = await _run();

    expect(r.events.whereType<BandNote>(), isEmpty,
        reason: 'a real handshake success emits no failure note');

    final samples = _samples(r.events);
    expect(samples, hasLength(1), reason: 'the hr-sentinel record yields no hr sample');
    expect(samples.single.anchor, TimeAnchor.measured);
    expect(samples.single.tsEpoch,
        activityRoundStartSec, reason: 'first minute of the round');
    expect(samples.single.hr, 65);

    final rows = _rows(r.events);
    final steps = rows.singleWhere((o) => o.key == 'steps');
    expect(steps.value, 30, reason: '20 + 10 across the two one-minute slots');
    expect(steps.unit, 'steps');
    expect(steps.sourceKind, ObservationSource.vendor);
    expect(steps.attribution, kHelioStrapAttribution);

    // Every reply (handshake chunks and fetch frames) is archived verbatim —
    // asserted directly, not just "some raw bytes exist somewhere": at
    // least one archived frame must contain the chunk-transport marker
    // byte (0x03) that only a handshake chunk carries, since the fetch
    // channel's own frames never do.
    // The fetch starts at a local midnight (two days back), never mid-day:
    // a day the window cut into would replace the whole day's stored total.
    final start = r.link.writes.firstWhere((w) =>
        w.$1 == kHuami2021FetchControlChar &&
        w.$2.length > 1 &&
        w.$2[0] == 0x01 &&
        w.$2[1] == kHuami2021TypeActivity);
    final since = DateTime(2026, 10, 2);
    expect(start.$2, huami2021FetchStartRequest(kHuami2021TypeActivity, since,
        since.timeZoneOffset.inMinutes));

    final raw = [for (final b in r.events.whereType<SampleBatch>()) ...?b.raw];
    expect(raw, isNotEmpty);
    expect(raw.any((f) => f.isNotEmpty && f[0] == 0x03), isTrue,
        reason: 'at least one archived frame must be a handshake chunk, '
            'not only fetch-channel frames');
  });
}

final int activityRoundStartSec =
    DateTime(_now.year, _now.month, _now.day, 6, 0).millisecondsSinceEpoch ~/
        1000;
