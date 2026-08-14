// Gen5 history-record decode, checked against the golden values recorded
// alongside a real WHOOP 5.0 capture (geniemax-core decode_golden.json).
//
// The point of this suite is as much about what we REFUSE to decode as what we
// decode. A gen5 field we cannot justify must come back null, because null
// archives the record for a future fix while a wrong number silently poisons
// every metric derived from it.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/gen5_framing.dart';
import 'package:openstrap_edge/ble/gen5_records.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'gen5_framing_test.dart' show kK18Frame, kK2Frame;

/// Inner payload of the real k18 capture.
Uint8List _k18Inner() => parseGen5Frame(hexToBytes(kK18Frame))!.inner;

void main() {
  group('real k18 capture', () {
    test('decodes every field geniemax recorded, and no others', () {
      final r = decodeGen5History(_k18Inner())!;
      expect(r.kDomain, 18);
      expect(r.hr, 77, reason: 'golden hr14');
      expect(r.tsEpoch, 1577582585, reason: 'golden ts7');
      expect(r.respRate, 18, reason: 'golden resp35');
      expect(r.skinTempC, closeTo(33.02, 0.001), reason: 'golden temp_c');
      expect(r.counter, greaterThan(0));
    });

    test('agrees with the gen4 header decode on counter and timestamp', () {
      // The header is the part both generations genuinely share; if this ever
      // stops holding, the shared-header premise is wrong and the transport
      // needs rethinking, not patching.
      final inner = _k18Inner();
      final view = inner.buffer.asByteData(inner.offsetInBytes, inner.length);
      final r = decodeGen5History(inner)!;
      expect(r.counter, view.getUint32(3, Endian.little));
      expect(r.tsEpoch, view.getUint32(7, Endian.little));
      expect(r.tsSubsec, view.getUint16(11, Endian.little));
    });

    test('the gen4 full-record decoder correctly REFUSES this record', () {
      // Documents the measured divergence: gen4's v24 field map reads a 0.27 g
      // gravity vector here, so its plausibility gate rejects the decode. This
      // is why a gen5-specific decoder exists at all — if this test ever starts
      // failing, the two layouts converged and this file can shrink.
      expect(parseR24(_k18Inner()), isNull);
    });
  });

  group('k-domain handling', () {
    test('HR offsets match the gen4 table exactly', () {
      // Two independent reverse-engineering efforts, same numbers. This test is
      // the tripwire for that agreement quietly breaking.
      expect(kGen5HrOffsetByKDomain, {7: 27, 9: 17, 12: 17, 18: 14, 24: 17});
    });

    test('reads HR at the right offset for each known k-domain', () {
      for (final entry in kGen5HrOffsetByKDomain.entries) {
        final inner = Uint8List(80);
        inner[0] = PacketType.historicalData;
        inner[1] = entry.key;
        inner[entry.value] = 61;
        final r = decodeGen5History(inner);
        expect(r, isNotNull, reason: 'k${entry.key} should decode');
        expect(r!.hr, 61, reason: 'k${entry.key} HR at ${entry.value}');
      }
    });

    test('an unknown k-domain returns null so the record gets archived', () {
      final inner = Uint8List(80);
      inner[0] = PacketType.historicalData;
      inner[1] = 99;
      expect(decodeGen5History(inner), isNull);
    });

    test('resp and skin temp are k18-only', () {
      final inner = Uint8List(80);
      inner[0] = PacketType.historicalData;
      inner[1] = 24; // a non-k18 history domain
      inner[17] = 60;
      final r = decodeGen5History(inner)!;
      expect(r.respRate, isNull);
      expect(r.skinTempCentiC, isNull);
    });
  });

  group('refusals', () {
    test('rejects a non-historical packet type', () {
      expect(decodeGen5History(parseGen5Frame(hexToBytes(kK2Frame))!.inner),
          isNull);
    });

    test('rejects a truncated record', () {
      expect(decodeGen5History(Uint8List(4)), isNull);
    });

    test('rejects an implausible heart rate', () {
      final inner = Uint8List(80);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      inner[14] = 240; // above any live human HR ⇒ wrong byte, not a reading
      expect(decodeGen5History(inner), isNull);
    });

    test('accepts HR 0 — off-wrist is a real reading, not a failure', () {
      final inner = Uint8List(80);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      inner[14] = 0;
      expect(decodeGen5History(inner)!.hr, 0);
    });

    test('drops an out-of-range respiration rather than reporting it', () {
      final inner = Uint8List(80);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      inner[14] = 60;
      inner[35] = 200; // nobody breathes 200x a minute
      expect(decodeGen5History(inner)!.respRate, isNull);
    });

    test('drops an out-of-range skin temperature', () {
      final inner = Uint8List(80);
      inner[0] = PacketType.historicalData;
      inner[1] = 18;
      inner[14] = 60;
      inner[65] = 0x00;
      inner[66] = 0x00; // 0.00 °C — not a wrist
      expect(decodeGen5History(inner)!.skinTempCentiC, isNull);
    });

    test('leaves unknown fields null rather than defaulting them to zero', () {
      // The whole contract of this decoder: absent ≠ zero.
      final r = decodeGen5History(_k18Inner())!;
      expect(r.skinTempC, isNotNull);
      // No accelerometer/RR/SpO2 accessors exist at all — they are not modelled
      // as nullable fields, they are simply not claimed. Guard that nothing
      // quietly adds a zero-valued one later.
      expect(r.toString(), isNot(contains('ax')));
      expect(r.toString(), isNot(contains('rr')));
    });
  });
}
