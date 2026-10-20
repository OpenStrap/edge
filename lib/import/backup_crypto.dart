// Passphrase-encrypted backup.
//
// WHAT THIS IS FOR. The Data screen hands a raw SQLite file to the OS share
// sheet, correctly described as "the complete copy" — every journal note, every
// medication dose, every cycle entry, every GPS route. Putting that in iCloud
// or Drive puts a complete health record in someone else's storage in plain
// text. This makes the file unreadable without a passphrase.
//
// AND THE COST, stated as plainly as the benefit: A FORGOTTEN PASSPHRASE MEANS
// THE BACKUP IS GONE. There is no recovery, because there is no account and no
// server holding a key — which is the same property that makes the product
// private. So: NO HINT FIELD, NO RECOVERY CODE. Both make it feel safer while
// making it weaker, and a hint is the single most effective attack on a
// human-chosen passphrase.
//
// The plaintext `.db` option STAYS. It is the lossless, tool-readable format,
// some people want exactly that, and it is the only thing that still opens if
// this file's format is ever wrong.
//
// CONSTRUCTION — all standard, nothing improvised:
//   AES-256-GCM  (vetted AEAD; the tag is the tamper check)
//   PBKDF2-HMAC-SHA256, 210 000 iterations (OWASP's 2023 floor for this PRF)
//   a fresh 16-byte salt AND a fresh 12-byte nonce PER FILE, from the platform
//   CSPRNG. Never derived from the passphrase, never a counter, never reused —
//   a repeated (key, nonce) pair in GCM is a catastrophic break, not a weakness.
//   The whole header is authenticated as AAD, so the iteration count and salt
//   cannot be edited to steer a later decrypt.
//
// NOT Argon2id: a pure-Dart Argon2id is slow enough on a phone that it gets
// tuned down until it is worth less than the PBKDF2 it replaced.
//
// STREAMING, deliberately. A VACUUM'd export of a real database runs to
// hundreds of megabytes; reading one into a list to encrypt it is an
// out-of-memory crash on the device where it matters most.
//
// MEASURED THROUGHPUT — read this before wiring a caller. Pure-Dart AES-GCM
// runs at about **1.5 MB/s**: a real 133 MB gen4 export took 88 s to encrypt
// and 81 s to decrypt on a desktop, and a phone is slower. Byte-exact both
// ways, so this is a cost, not a defect — but it is a cost with consequences:
//   * A deliberate, user-initiated backup with a progress indicator is fine.
//   * AUTO-BACKUP MUST NOT DEFAULT TO ENCRYPTED. A silent scheduled job that
//     pins a core for ten minutes on a 600 MB database is a battery bug, and
//     the restore path has to have run green against a file written by a
//     PREVIOUS app version before any default changes.
//
// ponytail: pure-Dart AES-GCM at ~1.5 MB/s; the upgrade path is a
// platform-backed AEAD (`cryptography_flutter` delegates to CommonCrypto /
// javax.crypto and is ~50x faster), at the cost of a platform channel that
// cannot be round-tripped in a headless test. Take it only if the measured
// wait is what people actually complain about.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// File magic. Four bytes so a corrupted or mis-picked file fails on the first
/// read rather than after a two-second key derivation.
const List<int> kBackupMagic = [0x4f, 0x53, 0x42, 0x4b]; // "OSBK"

/// Format version. Bumped only for a change that an older build could not read;
/// [BackupHeader.parse] refuses anything it does not know rather than guessing.
const int kBackupFormatVersion = 1;

/// KDF id. One value today; the byte exists so a future migration to a memory-
/// hard KDF can be read by a build that also still opens today's files.
const int kKdfPbkdf2HmacSha256 = 1;

const int kSaltBytes = 16;
const int kNonceBytes = 12; // GCM's standard nonce length
const int kTagBytes = 16;
const int kKeyBytes = 32; // AES-256

/// OWASP's 2023 floor for PBKDF2-HMAC-SHA256. Stored in the header, so raising
/// it later does not orphan files written today.
const int kDefaultIterations = 210000;

/// Chunk size for the streaming passes. Big enough that the per-call overhead
/// disappears, small enough that peak residency is bounded on a phone.
const int _chunkBytes = 1 << 20; // 1 MiB

/// A backup file that cannot be read: wrong magic, unknown version, truncated,
/// wrong passphrase, or tampered-with contents. Deliberately ONE type with a
/// human-readable reason — telling an attacker which of those it was buys them
/// something and buys the user nothing.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'BackupFormatException: $message';
}

/// The plaintext preamble of an encrypted backup. Authenticated (as GCM
/// additional data) but not encrypted: a restore has to read the KDF parameters
/// before it can derive the key that would decrypt them.
class BackupHeader {
  const BackupHeader({
    required this.version,
    required this.kdf,
    required this.iterations,
    required this.salt,
    required this.nonce,
  });

  final int version;
  final int kdf;
  final int iterations;
  final Uint8List salt;
  final Uint8List nonce;

  /// magic(4) version(1) kdf(1) iterations(4, big-endian) salt(16) nonce(12).
  static const int byteLength =
      4 + 1 + 1 + 4 + kSaltBytes + kNonceBytes;

  Uint8List toBytes() {
    final out = Uint8List(byteLength);
    out.setRange(0, 4, kBackupMagic);
    out[4] = version;
    out[5] = kdf;
    ByteData.view(out.buffer).setUint32(6, iterations, Endian.big);
    out.setRange(10, 10 + kSaltBytes, salt);
    out.setRange(10 + kSaltBytes, byteLength, nonce);
    return out;
  }

  static BackupHeader parse(Uint8List bytes) {
    if (bytes.length < byteLength) {
      throw const BackupFormatException('not a Locus backup');
    }
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != kBackupMagic[i]) {
        throw const BackupFormatException('not a Locus backup');
      }
    }
    final version = bytes[4];
    if (version != kBackupFormatVersion) {
      throw BackupFormatException(
        'this backup was written by a newer version of the app (format '
        '$version)',
      );
    }
    final kdf = bytes[5];
    if (kdf != kKdfPbkdf2HmacSha256) {
      throw const BackupFormatException('unsupported key derivation');
    }
    final iterations = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
    ).getUint32(6, Endian.big);
    // A zero or absurd iteration count is a corrupted (or hostile) header. It
    // is authenticated, so this can only fire before the tag check — refuse
    // rather than spend a minute deriving a key for a file that will fail.
    if (iterations < 1000 || iterations > 10000000) {
      throw const BackupFormatException('corrupt backup header');
    }
    return BackupHeader(
      version: version,
      kdf: kdf,
      iterations: iterations,
      salt: Uint8List.sublistView(bytes, 10, 10 + kSaltBytes),
      nonce: Uint8List.sublistView(bytes, 10 + kSaltBytes, byteLength),
    );
  }
}

/// PBKDF2-HMAC-SHA256 → a 256-bit AES key.
///
/// The passphrase is encoded UTF-8. This is the slow step by design (it is the
/// only thing standing between a stolen file and a guessed passphrase), so it
/// belongs off the UI isolate at the call site.
Uint8List deriveKey(String passphrase, Uint8List salt, int iterations) {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, kKeyBytes));
  // UTF-8, not code units: an emoji or an accented character in a passphrase
  // must derive the same key on every platform and every future build.
  return kdf.process(Uint8List.fromList(utf8.encode(passphrase)));
}

/// A fresh CSPRNG-backed random block. `Random.secure()` is the platform CSPRNG
/// (SecRandomCopyBytes / /dev/urandom); `Random()` here would be a real break,
/// not a style choice.
Uint8List randomBytes(int n, {Random? rng}) {
  final r = rng ?? Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

GCMBlockCipher _gcm({
  required bool forEncryption,
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List aad,
}) =>
    GCMBlockCipher(AESEngine())
      ..init(
        forEncryption,
        AEADParameters(KeyParameter(key), kTagBytes * 8, nonce, aad),
      );

/// Encrypt [src] to [dest]. [dest] is overwritten.
///
/// [iterations] and [rng] are injectable for tests ONLY — production must take
/// the defaults, and a test's fixed rng must never reach a real backup.
Future<void> encryptBackupFile(
  File src,
  File dest,
  String passphrase, {
  int iterations = kDefaultIterations,
  Random? rng,
}) async {
  if (passphrase.isEmpty) {
    throw const BackupFormatException('a backup needs a passphrase');
  }
  final header = BackupHeader(
    version: kBackupFormatVersion,
    kdf: kKdfPbkdf2HmacSha256,
    iterations: iterations,
    salt: randomBytes(kSaltBytes, rng: rng),
    nonce: randomBytes(kNonceBytes, rng: rng),
  );
  final headerBytes = header.toBytes();
  final key = deriveKey(passphrase, header.salt, iterations);
  final cipher = _gcm(
    forEncryption: true,
    key: key,
    nonce: header.nonce,
    aad: headerBytes,
  );

  final out = dest.openWrite();
  try {
    out.add(headerBytes);
    await _pump(src, cipher, out);
    out.add(_finish(cipher));
    await out.flush();
  } finally {
    await out.close();
  }
}

/// Decrypt [src] to [dest]. Throws [BackupFormatException] on a wrong
/// passphrase or a modified file — GCM's tag makes those the same failure, and
/// that is the point: a backup that decrypts to *nearly* your database is worse
/// than one that refuses.
///
/// [dest] is DELETED on failure. A half-written plaintext file that fails
/// authentication must never be left behind looking like a restore candidate.
Future<void> decryptBackupFile(File src, File dest, String passphrase) async {
  final raf = await src.open();
  Uint8List headerBytes;
  try {
    headerBytes = await raf.read(BackupHeader.byteLength);
  } finally {
    await raf.close();
  }
  final header = BackupHeader.parse(headerBytes);
  final key = deriveKey(passphrase, header.salt, header.iterations);
  final cipher = _gcm(
    forEncryption: false,
    key: key,
    nonce: header.nonce,
    aad: headerBytes,
  );

  final out = dest.openWrite();
  var ok = false;
  try {
    await _pump(src, cipher, out, skip: BackupHeader.byteLength);
    try {
      out.add(_finish(cipher));
    } on InvalidCipherTextException {
      throw const BackupFormatException(
        'wrong passphrase, or this backup has been modified',
      );
    }
    await out.flush();
    ok = true;
  } finally {
    await out.close();
    if (!ok && await dest.exists()) {
      await dest.delete();
    }
  }
}

/// Stream [src] through [cipher] into [out], dropping the first [skip] bytes.
///
/// ALIGNMENT IS LOAD-BEARING, not tidiness. `BaseAEADBlockCipher
/// ._processCipherBytes` (pointycastle 3.9) tops up its partial-block buffer
/// from the caller's input and then does NOT advance `inpOff` — so any call
/// that arrives while 0 < bufOff < 16 re-processes the bytes it just buffered,
/// and the file decrypts to garbage that fails its own tag. Feeding every call
/// a length that is a MULTIPLE OF THE BLOCK SIZE keeps bufOff at 0 or 16, where
/// the same branch consumes nothing and the missing advance is correct. Only
/// the final call — after which nothing else is fed — may carry a remainder.
///
/// ponytail: 16-byte alignment as a workaround for an upstream bug; drop the
/// carry buffer if pointycastle ever fixes `_processCipherBytes`.
Future<void> _pump(
  File src,
  GCMBlockCipher cipher,
  IOSink out, {
  int skip = 0,
}) async {
  final bs = cipher.blockSize;
  final carry = BytesBuilder(copy: false);

  void feed(Uint8List part) {
    if (part.isEmpty) return;
    final buf = Uint8List(part.length + bs);
    final n = cipher.processBytes(part, 0, part.length, buf, 0);
    if (n > 0) out.add(Uint8List.sublistView(buf, 0, n));
  }

  var dropped = 0;
  await for (final raw in src.openRead()) {
    var chunk = raw is Uint8List ? raw : Uint8List.fromList(raw);
    if (dropped < skip) {
      final take = skip - dropped;
      if (chunk.length <= take) {
        dropped += chunk.length;
        continue;
      }
      chunk = Uint8List.sublistView(chunk, take);
      dropped = skip;
    }
    carry.add(chunk);
    if (carry.length < _chunkBytes) continue;
    final pending = carry.takeBytes();
    final aligned = (pending.length ~/ bs) * bs;
    feed(Uint8List.sublistView(pending, 0, aligned));
    if (aligned < pending.length) {
      carry.add(Uint8List.sublistView(pending, aligned));
    }
  }
  // The tail, whatever length it is: nothing is fed after this.
  feed(carry.takeBytes());
}

Uint8List _finish(GCMBlockCipher cipher) {
  final tail = Uint8List(cipher.getOutputSize(0) + kTagBytes);
  final n = cipher.doFinal(tail, 0);
  return Uint8List.sublistView(tail, 0, n);
}
