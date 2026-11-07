// The gen5 v18 SpO2 candidate byte (protocol `spo2CandidateRaw`, inner[74])
// must be carried through `decodeGen5HistoricalSample` as a RAW byte — never
// gated, never converted to a percentage. The byte is unvalidated community
// knowledge (nonzero only in band-declared sleep bursts), so the contract
// under test is passthrough + null on gen4-shaped input, not a value claim.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// A minimal decodable v18 inner: length 112, version byte 18 at inner[1].
Uint8List v18Inner({int spo2Candidate = 0}) {
  final b = Uint8List(kGen5V18InnerLen);
  b[1] = 18;
  final v = ByteData.sublistView(b);
  v.setUint32(7, 1780916150, Endian.little); // unix
  b[73] = 2; // sleepStateByte: sleep
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

  test('zero candidate stays zero — absent measurement, not a gated null', () {
    final s = decodeGen5HistoricalSample(v18Inner(spo2Candidate: 0));
    expect(s!.spo2CandidateRaw, 0);
  });

  test('flag-style values above 128 are passed through unmasked', () {
    final s = decodeGen5HistoricalSample(v18Inner(spo2Candidate: 128 + 97));
    expect(s!.spo2CandidateRaw, 128 + 97);
  });
}
