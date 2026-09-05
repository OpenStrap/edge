// Independent confirmation of the Mi Band 2/3/4 auth-response cryptography —
// the one piece of this wire format that stays in this repo rather than the
// protocol package, because it needs a cipher implementation
// (`package:pointycastle`) that package deliberately has none of.
//
// THE VECTOR BELOW IS THE PUBLISHED FIPS-197 APPENDIX C.1 AES-128 EXAMPLE —
// not computed by this file's own encoder and not specific to this band: any
// conformant AES-128/ECB implementation reproduces it, which is what
// "independent" means for a block cipher.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/miband234.dart';

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('AES-128/ECB auth response — algorithmic cross-check', () {
    test('the FIPS-197 published key + plaintext block encrypts to the '
        'published ciphertext', () {
      final key = _hex('000102030405060708090a0b0c0d0e0f');
      final challenge = _hex('00112233445566778899aabbccddeeff');
      final out = miBand234AuthResponse(key, challenge);
      expect(_toHex(out), '69c4e0d86a7b0430d8cdb78070b4c55a');
    });

    test('one 16-byte block, no padding — unlike the ring, which pads a '
        '15-byte nonce', () {
      final out = miBand234AuthResponse(
        _hex('000102030405060708090a0b0c0d0e0f'),
        _hex('00112233445566778899aabbccddeeff'),
      );
      expect(out.length, 16);
    });

    test('deterministic: the same key and challenge always answer the same '
        'way, or a working pairing would break at random', () {
      final key = _hex('000102030405060708090a0b0c0d0e0f');
      final challenge = _hex('00112233445566778899aabbccddeeff');
      expect(miBand234AuthResponse(key, challenge),
          miBand234AuthResponse(key, challenge));
      // A different key must not answer the same way.
      expect(
        miBand234AuthResponse(_hex('00000000000000000000000000000000'),
            challenge),
        isNot(miBand234AuthResponse(key, challenge)),
      );
    });

    test('a wrong-sized key or challenge is refused rather than padded', () {
      expect(() => miBand234AuthResponse(List.filled(8, 0), List.filled(16, 0)),
          throwsArgumentError);
      expect(() => miBand234AuthResponse(List.filled(16, 0), List.filled(15, 0)),
          throwsArgumentError);
    });
  });
}
