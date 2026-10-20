import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';

// THE ROUND TRIP COMES FIRST — before the share sheet, before a settings
// toggle, before auto-backup is allowed anywhere near this. A backup format
// whose restore path has never run is not a backup.
//
// Iterations are turned down to 1000 here (the parser's floor) so the suite
// does not spend a minute per case in PBKDF2. Production uses the default and
// nothing in this file can change that.
const int _fastIters = 1000;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('osbk_test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File at(String name) => File('${tmp.path}/$name');

  Future<File> plain(String name, List<int> bytes) async {
    final f = at(name);
    await f.writeAsBytes(bytes);
    return f;
  }

  test('round trip returns the exact bytes', () async {
    // Deliberately not a round number of AES blocks, and bigger than one
    // stream chunk would be if the chunking were wrong.
    final data = Uint8List.fromList(
      List<int>.generate(300003, (i) => (i * 31 + 7) & 0xff),
    );
    final src = await plain('in.db', data);
    final enc = at('in.osbk');
    final out = at('out.db');

    await encryptBackupFile(src, enc, 'correct horse battery', iterations: _fastIters);
    await decryptBackupFile(enc, out, 'correct horse battery');

    expect(await out.readAsBytes(), equals(data));
  });

  test('an empty file round-trips rather than throwing', () async {
    final src = await plain('empty.db', const []);
    final enc = at('empty.osbk');
    final out = at('empty.out');
    await encryptBackupFile(src, enc, 'pw', iterations: _fastIters);
    await decryptBackupFile(enc, out, 'pw');
    expect(await out.length(), 0);
  });

  test('the ciphertext is not the plaintext', () async {
    final data = Uint8List.fromList(List<int>.filled(4096, 0x41));
    final src = await plain('a.db', data);
    final enc = at('a.osbk');
    await encryptBackupFile(src, enc, 'pw', iterations: _fastIters);
    final bytes = await enc.readAsBytes();
    // Header + ciphertext + 16-byte tag.
    expect(bytes.length, data.length + BackupHeader.byteLength + kTagBytes);
    expect(bytes.sublist(BackupHeader.byteLength), isNot(equals(data)));
  });

  test('two encryptions of the same file share no salt and no nonce', () async {
    final src = await plain('b.db', List<int>.filled(64, 9));
    final a = at('b1.osbk');
    final b = at('b2.osbk');
    await encryptBackupFile(src, a, 'pw', iterations: _fastIters);
    await encryptBackupFile(src, b, 'pw', iterations: _fastIters);
    final ha = BackupHeader.parse(await a.readAsBytes());
    final hb = BackupHeader.parse(await b.readAsBytes());
    // A reused (key, nonce) pair in GCM is a catastrophic break, not a
    // weakness — this is the assertion that guards it.
    expect(ha.nonce, isNot(equals(hb.nonce)));
    expect(ha.salt, isNot(equals(hb.salt)));
    // …and so the whole file differs.
    expect(await a.readAsBytes(), isNot(equals(await b.readAsBytes())));
  });

  test('a wrong passphrase fails and leaves no plaintext behind', () async {
    final src = await plain('c.db', List<int>.generate(1000, (i) => i & 0xff));
    final enc = at('c.osbk');
    final out = at('c.out');
    await encryptBackupFile(src, enc, 'right', iterations: _fastIters);
    await expectLater(
      decryptBackupFile(enc, out, 'wrong'),
      throwsA(isA<BackupFormatException>()),
    );
    // A half-written plaintext must never be left looking like a restore
    // candidate.
    expect(await out.exists(), isFalse);
  });

  test('a modified ciphertext byte is refused, not restored', () async {
    final src = await plain('d.db', List<int>.generate(1000, (i) => i & 0xff));
    final enc = at('d.osbk');
    await encryptBackupFile(src, enc, 'pw', iterations: _fastIters);
    final bytes = await enc.readAsBytes();
    bytes[BackupHeader.byteLength + 10] ^= 0x01;
    await enc.writeAsBytes(bytes);
    await expectLater(
      decryptBackupFile(enc, at('d.out'), 'pw'),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('the header is authenticated: editing the salt breaks the tag', () async {
    final src = await plain('e.db', List<int>.generate(64, (i) => i));
    final enc = at('e.osbk');
    await encryptBackupFile(src, enc, 'pw', iterations: _fastIters);
    final bytes = await enc.readAsBytes();
    bytes[12] ^= 0xff; // inside the salt
    await enc.writeAsBytes(bytes);
    await expectLater(
      decryptBackupFile(enc, at('e.out'), 'pw'),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('a plaintext .db is rejected up front, not after a slow KDF', () async {
    final notABackup = await plain('f.db', List<int>.filled(200, 0x00));
    await expectLater(
      decryptBackupFile(notABackup, at('f.out'), 'pw'),
      throwsA(
        isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains('not a Locus backup'),
        ),
      ),
    );
  });

  test('an empty passphrase is refused', () async {
    final src = await plain('g.db', const [1, 2, 3]);
    await expectLater(
      encryptBackupFile(src, at('g.osbk'), '', iterations: _fastIters),
      throwsA(isA<BackupFormatException>()),
    );
  });

  group('BackupHeader', () {
    test('survives a byte round trip', () {
      final h = BackupHeader(
        version: kBackupFormatVersion,
        kdf: kKdfPbkdf2HmacSha256,
        iterations: kDefaultIterations,
        salt: randomBytes(kSaltBytes, rng: Random(1)),
        nonce: randomBytes(kNonceBytes, rng: Random(2)),
      );
      final back = BackupHeader.parse(h.toBytes());
      expect(back.iterations, kDefaultIterations);
      expect(back.salt, equals(h.salt));
      expect(back.nonce, equals(h.nonce));
    });

    test('refuses a future format rather than guessing at it', () {
      final bytes = BackupHeader(
        version: kBackupFormatVersion,
        kdf: kKdfPbkdf2HmacSha256,
        iterations: kDefaultIterations,
        salt: Uint8List(kSaltBytes),
        nonce: Uint8List(kNonceBytes),
      ).toBytes();
      bytes[4] = 99;
      expect(() => BackupHeader.parse(bytes), throwsA(isA<BackupFormatException>()));
    });

    test('refuses an absurd iteration count', () {
      final bytes = BackupHeader(
        version: kBackupFormatVersion,
        kdf: kKdfPbkdf2HmacSha256,
        iterations: kDefaultIterations,
        salt: Uint8List(kSaltBytes),
        nonce: Uint8List(kNonceBytes),
      ).toBytes();
      ByteData.view(bytes.buffer).setUint32(6, 0, Endian.big);
      expect(() => BackupHeader.parse(bytes), throwsA(isA<BackupFormatException>()));
    });
  });
}
