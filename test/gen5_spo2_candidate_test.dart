// The gen5 v18 SpO2 candidate byte (protocol `spo2CandidateRaw`, inner[74])
// must be carried through `decodeGen5HistoricalSample` as a RAW byte — never
// gated, never converted to a percentage. The byte is unvalidated, so the
// contract under test is passthrough + null on gen4-shaped input, not a value
// claim.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// A minimal decodable v18 inner: length 112, version byte 18 at inner[1].
Uint8List v18Inner({int spo2Candidate = 0, int stateByte = 2}) {
  final b = Uint8List(kGen5V18InnerLen);
  b[1] = 18;
  final v = ByteData.sublistView(b);
  v.setUint32(7, 1780916150, Endian.little); // unix
  b[73] = stateByte; // sleep-state byte; the sleep code sits in bits 4-5
  b[74] = spo2Candidate;
  return b;
}

void main() {
  test('gen5 v18 spo2CandidateRaw is carried through as the raw byte', () {
    final s = decodeGen5HistoricalSample(v18Inner(spo2Candidate: 97));
    expect(s, isNotNull);
    expect(s!.spo2CandidateRaw, 97);
    expect(s.bandSleepState, isNotNull);
  });

  // The candidate is carried whatever the band says about sleep: the decoder
  // must not gate it on the sleep code, so a nonzero byte with a wake state
  // still comes through unchanged.
  test('a nonzero candidate is carried with a wake sleep state too', () {
    final s = decodeGen5HistoricalSample(
        v18Inner(spo2Candidate: 97, stateByte: 0x00));
    expect(s!.spo2CandidateRaw, 97);
  });

  test('zero candidate stays zero — absent measurement, not a gated null', () {
    final s = decodeGen5HistoricalSample(v18Inner(spo2Candidate: 0));
    expect(s!.spo2CandidateRaw, 0);
  });

  test('flag-style values above 128 are passed through unmasked', () {
    final s = decodeGen5HistoricalSample(v18Inner(spo2Candidate: 128 + 97));
    expect(s!.spo2CandidateRaw, 128 + 97);
  });

  // copyWith must carry the candidate along — a regression that drops
  // spo2CandidateRaw from copyWith would silently lose it on every copy.
  // (copyWith only overrides tsEpoch; the field must pass through unchanged.)
  test('copyWith preserves a nonzero spo2CandidateRaw', () {
    final s = decodeGen5HistoricalSample(v18Inner(spo2Candidate: 97))!;
    expect(s.copyWith(tsEpoch: s.tsEpoch + 1).spo2CandidateRaw, 97);
  });

  test('copyWith preserves an absent (null) spo2CandidateRaw', () {
    // A gen4-shaped sample carries no candidate byte at all.
    final s = Sample(tsEpoch: 1000, counter: 0, hr: 60);
    expect(s.spo2CandidateRaw, isNull);
    expect(s.copyWith(tsEpoch: 1001).spo2CandidateRaw, isNull);
  });

  // The seam to PR #472: a captured candidate byte must NOT unlock the
  // publication path. `Spo2Data` (payloads.dart) stays unread until the
  // validation gate passes — capturing is not displaying.
  test('captured candidate stays unread: Spo2Data refusal is intact', () {
    final s = decodeGen5HistoricalSample(v18Inner(spo2Candidate: 97))!;
    expect(s.spo2CandidateRaw, 97);
    final payload = TodayData.fromJson({'spo2': const <String, dynamic>{}});
    expect(payload.spo2, isNull, reason: 'no odi_per_hour -> Spo2Data unread');
  });
}
