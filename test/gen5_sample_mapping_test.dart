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

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' show kGen5PpgHrMinSamples;
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

List<int> sinePpg({required double bpm, required int n}) {
  final f = bpm / 60.0;
  return List<int>.generate(n, (i) {
    final t = i / 24.0;
    return (500 + 1000 * math.sin(2 * math.pi * f * t)).round();
  });
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

    test('a v20 optical deep buffer (no Sample equivalent) maps to null', () {
      final inner = Uint8List(kGen5V20InnerLen);
      inner[0] = 0x2F;
      inner[1] = 20;
      inner[2] = 0x81;
      final view = inner.buffer.asByteData();
      view.setUint32(3, 1, Endian.little);
      view.setUint32(7, 1780000000, Endian.little);
      inner[18] = 25; // block 0 active count
      final decoded = parseGen5Historical(inner);
      expect(decoded, isA<Gen5OpticalBuffer>());
      expect(sampleFromGen5Historical(decoded), isNull);
    });

    test('a v21 IMU deep buffer (no Sample equivalent) maps to null', () {
      final inner = Uint8List(kGen5V21InnerLen);
      inner[0] = 0x2F;
      inner[1] = 21;
      final view = inner.buffer.asByteData();
      view.setUint16(16, 100, Endian.little);
      view.setUint16(622, 100, Endian.little);
      final decoded = parseGen5Historical(inner);
      expect(decoded, isA<Gen5ImuBuffer>());
      expect(sampleFromGen5Historical(decoded), isNull);
    });
  });

  group('sampleFromGen5PpgWaveform — derived HR only', () {
    test('maps derived HR with empty RR when ACF recovers (10 s window)', () {
      final wave = sinePpg(bpm: 120, n: kGen5PpgHrMinSamples);
      final g = Gen5PpgWaveform(
        histVersion: 26,
        recordIndex: 42,
        unix: 1785801600,
        layoutMarker: 0,
        rawByte19: 0,
        burstIndex: 0,
        ppgWaveform: wave.sublist(0, 24),
      );
      final sample = sampleFromGen5PpgWaveform(g, wave);
      expect(sample, isNotNull);
      expect(sample!.hr, closeTo(120, 5));
      expect(sample.tsEpoch, 1785801600);
      expect(sample.counter, 42);
      expect(sample.rrIntervalsMs, isEmpty);
    });

    test('flatline PPG abstains (null Sample)', () {
      final g = Gen5PpgWaveform(
        histVersion: 26,
        recordIndex: 1,
        unix: 1785801600,
        layoutMarker: 0,
        rawByte19: 0,
        burstIndex: 0,
        ppgWaveform: List.filled(24, 100),
      );
      expect(
        sampleFromGen5PpgWaveform(
          g,
          List.filled(kGen5PpgHrMinSamples, 100),
        ),
        isNull,
      );
    });
  });

  group('Gen5PpgBurstBuffer', () {
    test('keeps only the last N bursts concatenated', () {
      final buf = Gen5PpgBurstBuffer(capacity: 2);
      buf.add(unix: 100, burstIndex: 0, wave: [1, 2]);
      buf.add(unix: 100, burstIndex: 1, wave: [3, 4]);
      buf.add(unix: 101, burstIndex: 0, wave: [5, 6]);
      expect(buf.concatenated(), [3, 4, 5, 6]);
    });

    test('clears on non-adjacent unix gap', () {
      final buf = Gen5PpgBurstBuffer();
      buf.add(unix: 100, burstIndex: 0, wave: [1, 2]);
      buf.add(unix: 102, burstIndex: 0, wave: [9, 9]);
      expect(buf.concatenated(), [9, 9]);
    });

    test('clears on non-monotonic burstIndex within same second', () {
      final buf = Gen5PpgBurstBuffer();
      buf.add(unix: 100, burstIndex: 1, wave: [1, 2]);
      buf.add(unix: 100, burstIndex: 0, wave: [9, 9]);
      expect(buf.concatenated(), [9, 9]);
    });
  });

  group('decodeGen5HistoricalSample — measured v18 clobber guard', () {
    const ppgUnix = 1780917232;

    Uint8List ppgInner() {
      final frame = hex(
        'aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46f'
        'c8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe8'
        '4fe15ff5cff405fb33c50080101006cb67c17',
      );
      return parseFrame(frame, profile: BandProfile.gen5)!.inner;
    }

    /// A buffer already holding a clean, ACF-resolvable waveform for the second
    /// BEFORE the fixture, so the concatenated series clears
    /// `kGen5PpgHrMinSamples` and the derived path is genuinely reachable.
    ///
    /// Without this the derived path abstains for want of samples no matter
    /// what the guard does — which is what made the original version of this
    /// test VACUOUS. Verified: it passed with the guard line deleted.
    Gen5PpgBurstBuffer primedBuf() {
      final buf = Gen5PpgBurstBuffer();
      // 24 Hz with a 24-sample period => 60 bpm, mid-range of the 25–230 search.
      const perBurst = 24;
      final bursts = (kGen5PpgHrMinSamples / perBurst).ceil() + 2;
      for (var b = 0; b < bursts; b++) {
        buf.add(
          unix: ppgUnix - 1,
          burstIndex: b,
          wave: [
            for (var i = 0; i < perBurst; i++)
              (2000 * math.sin(2 * math.pi * (b * perBurst + i) / 24)).round(),
          ],
        );
      }
      return buf;
    }

    test(
      'the derived PPG path is LIVE for this fixture when the second is '
      'unclaimed — otherwise the guard assertion below proves nothing',
      () {
        final sample = decodeGen5HistoricalSample(
          ppgInner(),
          ppgUnix,
          ppgBuf: primedBuf(),
          measuredRecTs: <int>{},
        );
        expect(
          sample,
          isNotNull,
          reason: 'fixture must actually reach sampleFromGen5PpgWaveform',
        );
        expect(sample!.derived, isTrue, reason: 'inferred HR, not measured');
        expect(sample.rrIntervalsMs, isEmpty, reason: 'no HRV claim from PPG');
      },
    );

    test('PPG abstains when measured v18 already claimed that second', () {
      expect(
        decodeGen5HistoricalSample(
          ppgInner(),
          ppgUnix,
          ppgBuf: primedBuf(),
          measuredRecTs: <int>{ppgUnix},
        ),
        isNull,
        reason: 'a derived bpm must never displace a measured record',
      );
    });
  });
}
