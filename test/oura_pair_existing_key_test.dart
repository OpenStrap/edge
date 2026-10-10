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

  /// When set, every key install is answered with this status instead.
  int? installStatus;
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
      final forced = installStatus;
      if (forced != null) {
        feed(kOuraNotifyChar, [0x25, 0x01, forced], atSec: 0);
        return;
      }
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
      final attempt = await ouraPairHandshake(ring, _appKey,
          install: false, replyWindow: _window);
      expect(attempt.ok, isTrue);
      expect(attempt.refusal, isNull);
      expect(ring.sentKeyInstall, isFalse,
          reason: 'the existing-key path must be read-only on the ring');
      expect(ring.held, _appKey);
    });

    test('a wrong key is refused without ever suggesting a reset', () async {
      final ring = _Ring(List.of(_appKey));
      final wrong = List<int>.generate(16, (i) => i);
      final attempt = await ouraPairHandshake(ring, wrong,
          install: false, replyWindow: _window);
      expect(attempt.refusal, contains('refused that key'));
      expect(attempt.refusal!.toLowerCase(), isNot(contains('reset')));
      expect(attempt.keyRejected, isTrue,
          reason: 'the ring answered, so this is a verdict on the key and a '
              'multi-key trial may move to the next candidate');
      expect(ring.sentKeyInstall, isFalse);
      expect(ring.held, _appKey, reason: 'the ring keeps its own key');
    });

    test('a factory-reset ring says there is no key to match', () async {
      final ring = _Ring(null);
      final attempt = await ouraPairHandshake(ring, _appKey,
          install: false, replyWindow: _window);
      expect(attempt.refusal, contains('holds no key yet'));
      expect(attempt.keyRejected, isFalse,
          reason: 'every other candidate gets the same answer, so a multi-key '
              'trial stops here instead of reporting all keys as wrong');
      expect(ring.sentKeyInstall, isFalse);
    });
  });

  group('the install handshake is unchanged', () {
    test('a factory-reset ring takes our key, then proves it', () async {
      final ring = _Ring(null);
      final ours = List<int>.generate(16, (i) => 0x10 + i);
      final attempt = await ouraPairHandshake(ring, ours,
          install: true, replyWindow: _window);
      expect(attempt.ok, isTrue);
      expect(ring.writes.first.$2.first, 0x24,
          reason: 'the install goes out first, before any nonce request');
      expect(ring.held, ours);
    });

    test('a ring in use refuses the install, and is told to reset', () async {
      final ring = _Ring(List.of(_appKey));
      final attempt = await ouraPairHandshake(ring, List.filled(16, 7),
          install: true, replyWindow: _window);
      expect(attempt.refusal, contains('factory reset'));
      expect(ring.held, _appKey);
    });

    test('a ring missing its production tests is not told to reset', () async {
      final ring = _Ring(null)..installStatus = 0x05;
      final attempt = await ouraPairHandshake(ring, List.filled(16, 7),
          install: true, replyWindow: _window);
      expect(attempt.ok, isFalse);
      expect(attempt.refusal, contains('production tests'));
      expect(attempt.refusal, contains('does not'));
      expect(attempt.keyRejected, isFalse,
          reason: 'every key gets the same answer, so a trial stops here');
      expect(ring.writes.where((w) => w.$2.first == 0x2f), isEmpty,
          reason: 'nothing past the refused install');
    });

    test('reports the install only once the ring acked it', () async {
      var taken = 0;
      await ouraPairHandshake(_Ring(null), List.filled(16, 7),
          install: true, replyWindow: _window, onKeyInstalled: () => taken++);
      await ouraPairHandshake(_Ring(List.of(_appKey)), List.filled(16, 7),
          install: true, replyWindow: _window, onKeyInstalled: () => taken++);
      await ouraPairHandshake(_Ring(List.of(_appKey)), _appKey,
          install: false, replyWindow: _window, onKeyInstalled: () => taken++);
      expect(taken, 1,
          reason: 'a re-pair keeps the new key only if the ring took it');
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

  group('parseOuraKeys', () {
    const a = 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf';
    const b = 'b0b1b2b3b4b5b6b7b8b9babbbcbdbebf';
    const c = 'c0c1c2c3c4c5c6c7c8c9cacbcccdcecf';

    test('one key stays one key, separators and all', () {
      // THE COMPATIBILITY CASE. `parseOuraKey` strips spaces, colons, hyphens
      // and newlines, so this has always been ONE key — splitting the field
      // before trying it whole would turn it into malformed fragments.
      final d = parseOuraKeys(' a0:a1:a2:a3 a4-a5-a6-a7\na8a9aaabacadaeaf ');
      expect(d.keys, [_appKey]);
      expect(d.malformed, 0);
      expect(d.overflow, 0);
    });

    test('reads one key per line, in order', () {
      final d = parseOuraKeys('$a\n$b\n$c');
      expect(d.keys.length, 3);
      expect(d.keys.first, _appKey);
      expect(d.malformed, 0);
    });

    test('also splits on commas and semicolons, and ignores blank lines', () {
      expect(parseOuraKeys('$a,$b').keys.length, 2);
      expect(parseOuraKeys('$a;$b').keys.length, 2);
      expect(parseOuraKeys('\n$a\n\n$b\n\n').keys.length, 2);
    });

    test('mixes hex and base64, and de-duplicates on the bytes', () {
      // The same key written both ways is ONE candidate — otherwise it burns
      // two connections to answer the same question.
      final d = parseOuraKeys('$a\noKGio6SlpqeoqaqrrK2urw==\n$b');
      expect(d.keys.length, 2);
      expect(d.keys.first, _appKey);
    });

    test('keeps the valid lines and counts the rest, rather than refusing all',
        () {
      final d = parseOuraKeys('$a\nnot a key\n$b\nzz');
      expect(d.keys.length, 2);
      expect(d.malformed, 2,
          reason: 'a silently dropped line is how a typo gets retried twice');
    });

    test('caps at kOuraMaxCandidateKeys and reports the overflow', () {
      final many = [
        for (var i = 0; i < kOuraMaxCandidateKeys + 2; i++)
          List<int>.generate(16, (j) => i * 16 + j)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
      ].join('\n');
      final d = parseOuraKeys(many);
      expect(d.keys.length, kOuraMaxCandidateKeys);
      expect(d.overflow, 2);
    });

    test('an empty or hopeless field yields no candidates', () {
      expect(parseOuraKeys('').isEmpty, isTrue);
      expect(parseOuraKeys('   \n  ').isEmpty, isTrue);
      final d = parseOuraKeys('nope\nalso nope');
      expect(d.isEmpty, isTrue);
      expect(d.malformed, 2);
    });
  });
}
