// Pairing an Oura ring with the key it ALREADY holds.
//
// The guarantee worth pinning is the one that makes this path safe to offer:
// it is READ-ONLY on the ring. The key-install command (tag 0x24) only takes a
// key on a factory-reset ring, so on a ring in use it is at best refused — and
// this path must never send it. These tests drive the real handshake
// (`ouraPairHandshake`) over a link that answers like a ring holding one key.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/oura.dart' show ouraAuthResponse;
import 'package:openstrap_edge/ble/oura_link.dart';

/// A ring holding [held] (null = factory reset), answering the three requests
/// the handshake makes the way the protocol documents them.
class _Ring extends ReplayBandLink {
  _Ring(this.held);

  List<int>? held;
  static const List<int> nonce = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  ];

  @override
  Future<bool> write(String characteristicUuid, List<int> value) async {
    final ok = await super.write(characteristicUuid, value);
    // Answered on a later turn, the way a notification lands after the
    // write that caused it.
    scheduleMicrotask(() => _answer(value));
    return ok;
  }

  void _answer(List<int> v) {
    if (v.isEmpty) return;
    if (v[0] == 0x24) {
      // A key install: taken only while factory reset.
      final ok = held == null;
      if (ok) held = v.sublist(2);
      feed(kOuraNotifyChar, [0x25, 0x01, ok ? 0x00 : 0x01], atSec: 0);
    } else if (v.length == 3 && v[0] == 0x2f && v[2] == 0x2b) {
      feed(kOuraNotifyChar, [0x2f, 0x10, 0x2c, ...nonce], atSec: 0);
    } else if (v.length == 19 && v[0] == 0x2f && v[2] == 0x2d) {
      final key = held;
      final int result;
      if (key == null) {
        result = 0x02; // factory reset: no key to match
      } else {
        final expected = ouraAuthResponse(key, nonce);
        result = _same(expected, v.sublist(3)) ? 0x00 : 0x01;
      }
      feed(kOuraNotifyChar, [0x2f, 0x02, 0x2e, result], atSec: 0);
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool get sentKeyInstall => writes.any((w) => w.$2.first == 0x24);
}

const _window = Duration(seconds: 2);
final _appKey = List<int>.generate(16, (i) => 0xA0 + i);

void main() {
  group('the existing-key handshake', () {
    test('lets a ring in with the key it holds, and never installs one',
        () async {
      final ring = _Ring(List.of(_appKey));
      final refusal = await ouraPairHandshake(ring, _appKey,
          install: false, replyWindow: _window);
      expect(refusal, isNull);
      expect(ring.sentKeyInstall, isFalse,
          reason: 'the existing-key path must be read-only on the ring');
      expect(ring.held, _appKey);
    });

    test('a wrong key is refused without ever suggesting a reset', () async {
      final ring = _Ring(List.of(_appKey));
      final wrong = List<int>.generate(16, (i) => i);
      final refusal = await ouraPairHandshake(ring, wrong,
          install: false, replyWindow: _window);
      expect(refusal, contains('refused that key'));
      expect(refusal!.toLowerCase(), isNot(contains('reset')));
      expect(ring.sentKeyInstall, isFalse);
      expect(ring.held, _appKey, reason: 'the ring keeps its own key');
    });

    test('a factory-reset ring says there is no key to match', () async {
      final ring = _Ring(null);
      final refusal = await ouraPairHandshake(ring, _appKey,
          install: false, replyWindow: _window);
      expect(refusal, contains('holds no key yet'));
      expect(ring.sentKeyInstall, isFalse);
    });
  });

  group('the install handshake is unchanged', () {
    test('a factory-reset ring takes our key, then proves it', () async {
      final ring = _Ring(null);
      final ours = List<int>.generate(16, (i) => 0x10 + i);
      final refusal = await ouraPairHandshake(ring, ours,
          install: true, replyWindow: _window);
      expect(refusal, isNull);
      expect(ring.writes.first.$2.first, 0x24,
          reason: 'the install goes out first, before any nonce request');
      expect(ring.held, ours);
    });

    test('a ring in use refuses the install, and is told to reset', () async {
      final ring = _Ring(List.of(_appKey));
      final refusal = await ouraPairHandshake(ring, List.filled(16, 7),
          install: true, replyWindow: _window);
      expect(refusal, contains('factory reset'));
      expect(ring.held, _appKey);
    });
  });

  group('parseOuraKey', () {
    const hex = 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf';

    test('reads 32 hex digits, any case, with separators ignored', () {
      expect(parseOuraKey(hex), _appKey);
      expect(parseOuraKey(hex.toUpperCase()), _appKey);
      expect(parseOuraKey(' a0:a1:a2:a3 a4-a5-a6-a7\na8a9aaabacadaeaf '),
          _appKey);
    });

    test('reads the 24-character base64 form', () {
      expect(parseOuraKey('oKGio6SlpqeoqaqrrK2urw=='), _appKey);
    });

    test('refuses anything that is not exactly 16 bytes', () {
      expect(parseOuraKey(''), isNull);
      expect(parseOuraKey(hex.substring(2)), isNull); // 15 bytes of hex
      expect(parseOuraKey('${hex}00'), isNull); // 17 bytes of hex
      expect(parseOuraKey('AAAAAAAAAAAAAAAAAAAA'), isNull); // 15 bytes base64
      expect(parseOuraKey('not a key at all!'), isNull);
    });
  });
}
