// Independent confirmation of the Withings Steel HR / Activité challenge
// proof — plain `SHA1(nonce ++ macAddress ++ secret)`, no cipher, so there is
// nothing platform-specific for this file to stand in for the way
// `oura_auth_crypto_test.dart` stands in for AES.
//
// EVERY EXPECTED VALUE BELOW WAS COMPUTED, NOT COPIED: SHA1 of a fixed
// concatenation of fixed bytes is reproducible by any conformant SHA1
// implementation — there is nothing device-specific or capture-specific
// about it.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/withings_steel_hr.dart';

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('withingsChallengeResponse — algorithmic cross-check', () {
    test('the fixed secret is 32 ASCII bytes', () {
      expect(kWithingsSteelHrSecret.codeUnits.length, 32);
      expect(kWithingsSteelHrSecret.codeUnits.every((c) => c < 128), isTrue);
    });

    test('one fixed nonce + mac + the real secret hashes to one fixed value',
        () {
      final nonce = _hex('000102030405060708090a0b0c0d0e0f');
      final out = withingsChallengeResponse(nonce, 'AA:BB:CC:DD:EE:FF');
      expect(out.length, 20, reason: 'SHA1 digests are always 20 bytes');
      expect(_toHex(out), 'ae5b3acfc402e7491afcde7d5e9ffef00d222245');
    });

    test('a different nonce answers differently', () {
      final a = withingsChallengeResponse(
          _hex('000102030405060708090a0b0c0d0e0f'), 'AA:BB:CC:DD:EE:FF');
      final b = withingsChallengeResponse(
          _hex('0102030405060708090a0b0c0d0e0f10'), 'AA:BB:CC:DD:EE:FF');
      expect(_toHex(b), 'b8d3f87d13652dd3d94f0bf96766387f4fe1e6f0');
      expect(_toHex(a), isNot(_toHex(b)));
    });

    test('a different macAddress answers differently — it is part of the '
        'proof, not merely routing', () {
      final withA = withingsChallengeResponse(
          _hex('000102030405060708090a0b0c0d0e0f'), 'AA:BB:CC:DD:EE:FF');
      final withB = withingsChallengeResponse(
          _hex('000102030405060708090a0b0c0d0e0f'), '11:22:33:44:55:66');
      expect(_toHex(withB), 'd652574985c6d94c158f5477535137f8564b6eb3');
      expect(_toHex(withA), isNot(_toHex(withB)));
    });

    test('deterministic: the same inputs always answer the same way', () {
      final nonce = _hex('000102030405060708090a0b0c0d0e0f');
      final a = withingsChallengeResponse(nonce, 'AA:BB:CC:DD:EE:FF');
      final b = withingsChallengeResponse(nonce, 'AA:BB:CC:DD:EE:FF');
      expect(_toHex(a), _toHex(b));
    });

    test('a wrong secret answers differently — a session with any other '
        'device family must not authenticate', () {
      final nonce = _hex('000102030405060708090a0b0c0d0e0f');
      final real = withingsChallengeResponse(nonce, 'AA:BB:CC:DD:EE:FF');
      final wrong = withingsChallengeResponse(nonce, 'AA:BB:CC:DD:EE:FF',
          secret: 'x' * 32);
      expect(_toHex(real), isNot(_toHex(wrong)));
    });
  });
}
