// Tests for BleEngine's gen5 -> band-agnostic Sample mapping
// (sampleFromGen5Historical) — the seam that turns protocol's typed gen5
// historical-record decode into the same `Sample` shape gen4 records
// produce, so the derivation pipeline / analytics stay band-agnostic.
//
// The v18 fixture is the same real, independently byte-verified capture used
// by protocol's own gen5_historical_test.dart (CRC16-modbus header + CRC32
// payload both check out; see that file's header comment for provenance) —
// reused here rather than re-typed, so a transcription slip can't silently
// diverge the two test suites' expectations.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('sampleFromGen5Historical — v18 (real fixture)', () {
    // "worn" capture, unix=1780916150 — CRC16+CRC32 both verified. Same
    // bytes as protocol/test/gen5_historical_test.dart's v18 real fixture.
    final frame = hex(
      'aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000'
      '000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000'
      '000000000000f7000901f10b0007010c020c000000000000000000000000000'
      '00000000000000000000100656f1e1e0000009d61a7c00000003e862817',
    );

    late Sample? sample;

    setUp(() {
      final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
      expect(parsed.valid, isTrue, reason: 'both gen5 CRCs must check out');
      sample = sampleFromGen5Historical(parseGen5Historical(parsed.inner));
    });

    test('maps ts/counter/hr straight through', () {
      expect(sample, isNotNull);
      expect(sample!.tsEpoch, 1780916150);
      expect(sample!.counter, 25443699);
      expect(sample!.hr, 102);
    });

    test('maps RR intervals straight through (band-agnostic HRV kernel)', () {
      expect(sample!.rrIntervalsMs, [602, 613]);
    });

    test('maps the gravity vector onto ax/ay/az (shared g-units)', () {
      expect(sample!.ax, closeTo(-0.7252, 1e-3));
      expect(sample!.ay, closeTo(0.4944, 1e-3));
      expect(sample!.az, closeTo(0.4969, 1e-3));
    });

    test(
      'does NOT populate skinTempRaw/spo2 — gen5-specific scale/absence',
      () {
        // See gen5_v18_decode's (now removed, folded into protocol) original
        // caution and Gen5HistorySample's field docs: gen5's skin_temp is
        // already °C-scaled (raw/100), a DIFFERENT transfer function from
        // gen4's per-device affine ADC calibration that `skinTempRaw` feeds —
        // reusing that field here would silently corrupt the skin-temp-z
        // metric. gen5 v18 has no real dual-wavelength SpO2 at all.
        expect(sample!.skinTempRaw, isNull);
        expect(sample!.spo2RedRaw, isNull);
        expect(sample!.spo2IrRaw, isNull);
      },
    );
  });

  group('sampleFromGen5Historical — non-Sample record kinds', () {
    test('a null decode (unrecognised version/garbage) maps to null', () {
      expect(sampleFromGen5Historical(null), isNull);
    });

    test('a v21 IMU deep buffer (no Sample equivalent) maps to null', () {
      // Synthetic-but-shape-correct v21 buffer: countA/countB both 100 (the
      // buffer's actual identity gate, per Gen5V21Decoder — hist_version is
      // not trusted for this kind at all).
      final inner = Uint8List(kGen5V21InnerLen);
      inner[0] = 0x2F;
      inner[1] = 21;
      final view = inner.buffer.asByteData();
      view.setUint16(16, 100, Endian.little); // countA offset
      view.setUint16(622, 100, Endian.little); // countB offset
      final decoded = parseGen5Historical(inner);
      expect(decoded, isA<Gen5ImuBuffer>());
      expect(sampleFromGen5Historical(decoded), isNull);
    });
  });
}
