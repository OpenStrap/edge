// import_container.dart — what did the user actually hand us?
//
// WHY THIS EXISTS (issues #199, #160)
//
// Every importer took the path from a `FileType.any` picker and piped it
// straight into `utf8.decoder`. Users picked the file their OTHER app told them
// to export — a WHOOP "My Data" export (a ZIP of CSVs) or a NOOP full backup
// (`.noopbak`, a ZIP holding `noop-backup.sqlite`) — and got:
//
//     FormatException: Unexpected extension byte (at offset 10)
//     FormatException: Invalid UTF-8 byte (at offset 10)
//
// Offset 10 is not a coincidence and it is not an encoding problem. A ZIP's
// first ten bytes (`PK\x03\x04`, version, flags, method) are all < 0x80, so the
// UTF-8 decoder always survives exactly that far and then hits byte 10 — the low
// byte of the DOS modification time, the first byte in the file that can have
// its high bit set. Byte 18 (the compressed size) is the next such field, which
// is where the other reported offset comes from. Both reports are ZIPs.
//
// (A genuinely mis-encoded CSV — latin1/cp1252, a Spanish or French export —
// fails differently: "Missing extension byte". None of the reports show that,
// so the "it's a localized CSV" theory does not explain them. Lenient decoding
// is still applied below, but as a separate, smaller fix.)
//
// So: sniff the container before decoding. A ZIP of CSVs is unwrapped and
// imported for real; anything we cannot use gets a message naming the file we
// DO want, instead of a byte offset.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// What the first bytes of the picked file say it is.
enum ImportContainer {
  /// Plain text — decode and parse it.
  text,

  /// PKZIP. A WHOOP export, or a `.noopbak`.
  zip,

  /// A raw SQLite database (a `noop-backup.sqlite` extracted by hand, say).
  sqlite,

  /// gzip — not a container we unwrap, but worth naming precisely.
  gzip,

  /// Text, but UTF-16 rather than UTF-8 — re-savable by the user.
  utf16,

  /// Binary of some other kind.
  binary,
}

/// An import that failed for a reason the user can act on. Distinct from a
/// `FormatException` so the UI can show guidance rather than a byte offset.
class ImportFormatException implements Exception {
  const ImportFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Classify a file from its leading bytes. Pure — [head] is the first ~16 bytes.
///
/// Magic numbers: `PK\x03\x04` (and the empty/spanned variants `PK\x05\x06`,
/// `PK\x07\x08`) for ZIP; `SQLite format 3\x00` for SQLite; `\x1f\x8b` for gzip.
/// Everything else is called text unless it holds a NUL or a run of control
/// bytes, which no CSV export contains.
ImportContainer sniffImportContainer(List<int> head) {
  // UTF-16 (what Excel writes for "Unicode text") is full of NUL bytes and
  // would otherwise be called binary — technically true, useless to the user.
  if (head.length >= 2 &&
      ((head[0] == 0xFF && head[1] == 0xFE) ||
          (head[0] == 0xFE && head[1] == 0xFF))) {
    return ImportContainer.utf16;
  }
  if (head.length >= 4 &&
      head[0] == 0x50 &&
      head[1] == 0x4B &&
      (head[2] == 0x03 || head[2] == 0x05 || head[2] == 0x07)) {
    return ImportContainer.zip;
  }
  const sqliteMagic = 'SQLite format 3';
  if (head.length >= sqliteMagic.length &&
      String.fromCharCodes(head.take(sqliteMagic.length)) == sqliteMagic) {
    return ImportContainer.sqlite;
  }
  if (head.length >= 2 && head[0] == 0x1F && head[1] == 0x8B) {
    return ImportContainer.gzip;
  }
  for (final b in head) {
    // NUL, or a control byte that is not tab/LF/CR — not a CSV.
    if (b == 0x00 || (b < 0x09) || (b > 0x0D && b < 0x20)) {
      return ImportContainer.binary;
    }
  }
  return ImportContainer.text;
}

/// Read enough of [path] to classify it.
Future<ImportContainer> sniffFile(String path) async {
  final f = File(path);
  final raf = await f.open();
  try {
    return sniffImportContainer(await raf.read(16));
  } finally {
    await raf.close();
  }
}

/// True for a ZIP member we can actually parse as an export.
bool _isCsvMember(String name) {
  final base = p.basename(name).toLowerCase();
  // `__MACOSX/._foo.csv` resource forks are AppleDouble binaries, not CSVs.
  return base.endsWith('.csv') &&
      !base.startsWith('._') &&
      !name.startsWith('__MACOSX/');
}

/// Ceilings for archive extraction. A picked file is local and user-chosen, so
/// this is not a hostile-input boundary — but a malformed or pathological zip
/// should fail with a message rather than take the process out trying to
/// materialise it. The uncompressed ceiling is generous: a 90-day NOOP raw
/// export really is hundreds of megabytes.
const int _kMaxArchiveMembers = 5000;
const int _kMaxUncompressedBytes = 4 * 1024 * 1024 * 1024; // 4 GiB

/// Ceiling for a STREAMED gzip inflate, which is a different problem from the
/// ZIP one above: there the size is declared in the member header and can be
/// refused before a byte is written, whereas gzip declares nothing, so the only
/// way to refuse one is to count bytes that are already landing on disk. A
/// ceiling in the multi-gigabyte range is therefore no protection at all on a
/// phone — the storage is gone long before the guard trips. 2 GiB is more than
/// an order of magnitude above the largest real database this app produces and
/// still leaves a device with room to notice. Dart has no portable free-space
/// API, so this is the bound available; the partial file is deleted on the way
/// out either way.
const int _kMaxInflatedBytes = 2 * 1024 * 1024 * 1024; // 2 GiB

/// CSV files on disk for an import, plus the temp directory (if any) that has
/// to be cleaned up once they have been read.
class ResolvedImportFiles {
  ResolvedImportFiles(this.paths, this._tempDir);

  final List<String> paths;
  final Directory? _tempDir;

  /// Delete anything extracted for this import. Safe to call more than once,
  /// and never throws — a leftover temp file is not worth failing an import
  /// that otherwise succeeded.
  Future<void> dispose() async {
    final dir = _tempDir;
    if (dir == null) return;
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      /* the OS reclaims the temp dir eventually */
    }
  }
}

/// True for a ZIP member that is a database rather than a CSV.
bool _isDbMember(String name) {
  final base = p.basename(name).toLowerCase();
  return (base.endsWith('.sqlite') ||
          base.endsWith('.db') ||
          base.endsWith('.sqlite3')) &&
      !base.startsWith('._') &&
      !name.startsWith('__MACOSX/');
}

/// A NOOP database ready to read, plus the temp directory holding it (if it had
/// to be unpacked). The caller MUST [dispose] once it has finished reading.
class ResolvedNoopDatabase {
  ResolvedNoopDatabase(this.path, this._tempDir);

  final String path;
  final Directory? _tempDir;

  Future<void> dispose() async {
    final dir = _tempDir;
    if (dir == null) return;
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      /* the OS reclaims the temp dir eventually */
    }
  }
}

/// Inflate a gzip file into [dir] and return the path, or null if [path] is not
/// gzip.
///
/// STREAMED with a running ceiling rather than decoded in memory. A gzip
/// declares nothing about its output size, so the only way to refuse a
/// pathological one is to count bytes as they land and stop — and the file this
/// most often is (a full database backup) is exactly the size that must never
/// be buffered twice.
///
/// VERIFIED against the gzip trailer, which the decoder alone does not get to.
/// A gzip ends with a CRC32 and an ISIZE over the uncompressed bytes, and zlib
/// does check them — but only on reaching the end of the stream. A stream that
/// simply STOPS never gets there, and Dart's decoder returns whatever it
/// managed to inflate without raising. So a backup truncated to 99.9% inflated
/// cleanly, sniffed as SQLite, merged, and reported success one row short of
/// what the user was restoring; a half-synced iCloud or Nextcloud copy is
/// exactly the case restore exists for. Cuts between 50% and 99% were caught
/// only incidentally, by sqlite, and surfaced as a raw ffi exception rather
/// than something a user could act on. Reading the trailer off the file instead
/// of waiting for the decoder to reach it catches every cut at the container,
/// where the message can name what is wrong.
///
/// Single-member gzip only, which is what every writer in this app produces.
/// Concatenated members would carry a trailer per member and be rejected here.
///
/// The caller owns [dir] and the file inside it.
Future<String?> inflateGzip(String path, Directory dir) async {
  if (await sniffFile(path) != ImportContainer.gzip) return null;

  var base = p.basename(path);
  if (base.toLowerCase().endsWith('.gz')) {
    base = base.substring(0, base.length - 3);
  }
  if (base.isEmpty) base = 'inflated';
  final destPath = p.join(dir.path, base);
  final sink = File(destPath).openWrite();
  var written = 0;
  var crc = 0;
  // COUNT INSIDE A TRANSFORMER, then `pipe`. The obvious `await for (…)
  // sink.add(chunk)` reads as streaming but is not: `IOSink.add` queues without
  // back-pressure, so an inflate that outruns the disk buffers the ENTIRE
  // inflated database in memory — the 256 MB-heap OOM this file's header is
  // about, reintroduced by the code meant to avoid it. `pipe` goes through
  // `addStream`, which pauses the source while a write is in flight, and the
  // transformer propagates that pause upstream to the decoder.
  final counted = StreamTransformer<List<int>, List<int>>.fromHandlers(
    handleData: (chunk, out) {
      written += chunk.length;
      if (written > _kMaxInflatedBytes) {
        out.addError(
          ImportFormatException(
            '“${p.basename(path)}” unpacks to more than '
            '${_kMaxInflatedBytes ~/ (1024 * 1024 * 1024)} GB, which is not '
            'something we can import.',
          ),
        );
        out.close();
        return;
      }
      // Folded into the same pass as the ceiling: the inflated bytes are only
      // in memory here, and re-reading the restored file to checksum it would
      // double the I/O on a multi-hundred-MB backup.
      crc = getCrc32(chunk, crc);
      out.add(chunk);
    },
  );
  try {
    await File(path).openRead().transform(gzip.decoder).transform(counted).pipe(sink);
    await _checkGzipTrailer(path, written: written, crc: crc);
  } catch (e) {
    try {
      await sink.close();
    } catch (_) {}
    try {
      final partial = File(destPath);
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
    if (e is ImportFormatException) rethrow;
    throw ImportFormatException(
      'Could not read “${p.basename(path)}” as a gzip archive: $e',
    );
  }
  return destPath;
}

/// Compare the gzip trailer of [path] against what actually came out of the
/// decoder, and throw [ImportFormatException] when they disagree.
///
/// The last eight bytes of a gzip member are CRC32 then ISIZE, both
/// little-endian over the UNCOMPRESSED data, ISIZE modulo 2^32. Either one
/// mismatching means the file we read is not the file that was written — the
/// usual cause being a copy that was still syncing.
Future<void> _checkGzipTrailer(
  String path, {
  required int written,
  required int crc,
}) async {
  final file = File(path);
  final length = await file.length();
  // 10-byte header + 2-byte empty deflate block + 8-byte trailer is the
  // smallest possible gzip; anything shorter lost its trailer outright.
  if (length < 18) throw _gzipTruncated(path);

  final raf = await file.open();
  final Uint8List trailer;
  try {
    await raf.setPosition(length - 8);
    trailer = await raf.read(8);
  } finally {
    await raf.close();
  }
  if (trailer.length != 8) throw _gzipTruncated(path);

  final expectedCrc =
      trailer[0] | trailer[1] << 8 | trailer[2] << 16 | trailer[3] << 24;
  final expectedSize =
      trailer[4] | trailer[5] << 8 | trailer[6] << 16 | trailer[7] << 24;
  if (written % 0x100000000 != expectedSize || crc != expectedCrc) {
    throw _gzipTruncated(path);
  }
}

ImportFormatException _gzipTruncated(String path) => ImportFormatException(
  '“${p.basename(path)}” is incomplete or damaged — the compressed data does '
  'not match the checksum stored in the file. If it came from a cloud folder, '
  'wait for it to finish downloading, or export it again.',
);

/// If [path] is a NOOP full backup, return its database ready to open.
///
/// Handles both shapes users arrive with: the `.noopbak` itself (a ZIP whose
/// only member is `noop-backup.sqlite`) and a database someone already unpacked
/// by hand. Returns null for anything else, so the caller falls through to the
/// CSV path.
///
/// The database is EXTRACTED to a temp directory rather than read in place: a
/// ZIP member is deflated, and sqlite needs a real file it can seek in.
Future<ResolvedNoopDatabase?> resolveNoopDatabase(String path) async {
  switch (await sniffFile(path)) {
    case ImportContainer.sqlite:
      return ResolvedNoopDatabase(path, null);
    case ImportContainer.zip:
      break;
    case ImportContainer.gzip:
      // A gzipped database — the shape this app's own auto-backups take, and
      // what `gzip -k` leaves behind for anyone compressing an export by hand.
      // Inflate, then re-sniff: only a real SQLite file is claimed here, so a
      // gzipped CSV still falls through to the CSV path.
      final tempDir = await Directory.systemTemp.createTemp('openstrap_gz_');
      try {
        final inflated = await inflateGzip(path, tempDir);
        if (inflated != null &&
            await sniffFile(inflated) == ImportContainer.sqlite) {
          return ResolvedNoopDatabase(inflated, tempDir);
        }
      } catch (_) {
        // Not readable as gzip — let the CSV path produce the user-facing
        // message rather than throwing a database-flavoured one here.
      }
      try {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      } catch (_) {}
      return null;
    default:
      return null;
  }

  final input = InputFileStream(path);
  Archive archive;
  try {
    archive = ZipDecoder().decodeStream(input);
  } catch (e) {
    await input.close();
    throw ImportFormatException(
      'Could not read “${p.basename(path)}” as an archive: $e',
    );
  }
  try {
    ArchiveFile? db;
    for (final f in archive.files) {
      if (f.isFile && _isDbMember(f.name)) {
        // Largest member wins: a backup can ship the database alongside a small
        // sidecar (`-wal`, a manifest), and picking the first match could take
        // the wrong one.
        if (db == null || f.size > db.size) db = f;
      }
    }
    if (db == null) return null; // not a backup — let the CSV path try.

    if (db.size > _kMaxUncompressedBytes) {
      throw ImportFormatException(
        '“${p.basename(path)}” unpacks to '
        '${(db.size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB, which is '
        'not something we can import.',
      );
    }
    final tempDir = await Directory.systemTemp.createTemp('openstrap_noopbak_');
    // Everything past this point owns `tempDir`. An IO failure here is a
    // hundreds-of-megabytes partial copy, so nothing may escape without
    // deleting it — the caller has no handle to clean up with, because the
    // handle is what this function failed to return.
    try {
      final destPath = p.join(tempDir.path, p.basename(db.name));
      final sink = OutputFileStream(destPath);
      try {
        db.writeContent(sink);
      } finally {
        await sink.close();
      }
    // A 260 MB backup unpacks to a full second copy, and a phone that runs out
    // of space mid-write leaves a TRUNCATED file — which still opens as a valid
    // database and would import a fraction of the history as if that were all
    // of it. Silent partial history is the worst outcome here, so verify the
    // whole member landed. (Dart has no portable free-space API, hence checking
    // after rather than before.)
      // The size is checked in BOTH directions, AFTER the write. Short means it
      // ran out of space, and a truncated database still opens — importing a
      // fraction of someone's history as if it were all of it. Long means the
      // archive's declared size is not what it actually holds, so the ceiling
      // above was checked against a number that turned out to be fiction. Note
      // this REPORTS an over-run rather than preventing it: the bytes are on
      // disk by the time we can compare, and bounding that would need a
      // size-limited sink around the decoder. Rejecting after the fact is still
      // worth it — the file is deleted below and never imported.
      final written = await File(destPath).length();
      if (db.size > 0 && written < db.size) {
        throw ImportFormatException(
          'Unpacking that backup stopped at '
          '${(written / (1024 * 1024)).round()} MB of '
          '${(db.size / (1024 * 1024)).round()} MB — the phone is probably out '
          'of space. Free some up and try again.',
        );
      }
      if (db.size > 0 && written > db.size) {
        throw ImportFormatException(
          '“${p.basename(path)}” does not hold what it says it does — its '
          'database unpacked to more than the archive declared. It is likely '
          'damaged; export it again.',
        );
      }
      return ResolvedNoopDatabase(destPath, tempDir);
    } catch (_) {
      // Delete the partial copy directly, and never let a cleanup failure
      // replace the real exception — the out-of-space message above is the one
      // the user can act on.
      try {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      } catch (_) {
        /* the OS reclaims the temp dir eventually */
      }
      rethrow;
    }
  } finally {
    await input.close();
  }
}

/// Resolve the picked paths into CSV files on disk, unwrapping ZIP archives.
///
/// [flavor] names the importer in error messages ('NOOP', 'WHOOP'). Extracted
/// members are written to a temp directory; the caller MUST `dispose()` the
/// result once it has finished reading them, or a large export leaves a full
/// second copy behind. Nothing is ever copied into app storage.
///
/// Throws [ImportFormatException] with actionable guidance for anything we
/// cannot parse: a database, an archive of databases, a gzip, binary junk.
Future<ResolvedImportFiles> resolveImportCsvPaths(
  List<String> paths, {
  required String flavor,
}) async {
  final out = <String>[];
  Directory? tempDir;
  var archiveIndex = 0;
  try {
    for (final path in paths) {
      final kind = await sniffFile(path);
      switch (kind) {
        case ImportContainer.text:
          out.add(path);
        case ImportContainer.zip:
          tempDir ??=
              await Directory.systemTemp.createTemp('openstrap_import_');
          // One subdirectory per archive: the multi-select WHOOP path can hand
          // us two exports that each contain `data.csv`, and a shared
          // destination made the second overwrite the first (and returned the
          // survivor's path twice).
          final into = Directory(p.join(tempDir.path, 'a${archiveIndex++}'));
          await into.create(recursive: true);
          out.addAll(
            await _extractCsvMembers(path, flavor: flavor, dir: into),
          );
        case ImportContainer.sqlite:
          // Only reachable for WHOOP now — a NOOP database (loose or inside a
          // `.noopbak`) is claimed by [resolveNoopDatabase] before this runs.
          throw ImportFormatException(
            '“${p.basename(path)}” is a database file, not a $flavor CSV '
            'export.',
          );
        case ImportContainer.gzip:
          // Used to be a flat refusal ("unzip it first"). It is inflated now:
          // gzip is what every command-line tool and most file managers produce
          // when someone compresses a CSV, and it is the shape this app's own
          // auto-backups take.
          tempDir ??=
              await Directory.systemTemp.createTemp('openstrap_import_');
          final gzInto = Directory(p.join(tempDir.path, 'a${archiveIndex++}'));
          await gzInto.create(recursive: true);
          final inflated = await inflateGzip(path, gzInto);
          // Re-sniff rather than assume: a gzipped ZIP or database is still not
          // a CSV, and the message for those should say so.
          final inner = inflated == null
              ? ImportContainer.binary
              : await sniffFile(inflated);
          if (inner != ImportContainer.text) {
            throw ImportFormatException(
              '“${p.basename(path)}” unpacks to something that is not a '
              '$flavor CSV export.',
            );
          }
          out.add(inflated!);
        case ImportContainer.utf16:
          throw ImportFormatException(
            '“${p.basename(path)}” is saved as UTF-16 text. Re-save it as '
            'UTF-8 CSV and import it again.',
          );
        case ImportContainer.binary:
          throw ImportFormatException(
            '“${p.basename(path)}” is not a text file, so there is nothing to '
            'read as a $flavor CSV export.',
          );
      }
    }
  } catch (_) {
    // A later file failing must not strand what an earlier ZIP already wrote.
    await ResolvedImportFiles(const [], tempDir).dispose();
    rethrow;
  }
  return ResolvedImportFiles(out, tempDir);
}

Future<List<String>> _extractCsvMembers(
  String path, {
  required String flavor,
  required Directory dir,
}) async {
  final name = p.basename(path);
  final Archive archive;
  // STREAMED, not `decodeBytes(readAsBytes())`. A 90-day NOOP raw export is
  // hundreds of megabytes; buffering the whole archive AND then each member in
  // memory would OOM the phone on exactly the export this path exists to
  // import — and the rest of the import pipeline is carefully streamed for the
  // same reason. `InputFileStream` reads the archive off disk as it decodes.
  final input = InputFileStream(path);
  try {
    archive = ZipDecoder().decodeStream(input);
  } catch (e) {
    await input.close();
    throw ImportFormatException(
      'Could not read “$name” as an archive: $e',
    );
  }

  if (archive.files.length > _kMaxArchiveMembers) {
    throw ImportFormatException(
      '“$name” holds ${archive.files.length} entries, which is far more than '
      'any $flavor export — refusing to unpack it.',
    );
  }

  final csvFiles = [
    for (final f in archive.files)
      if (f.isFile && _isCsvMember(f.name)) f,
  ];

  final declaredBytes =
      csvFiles.fold<int>(0, (sum, f) => sum + (f.size > 0 ? f.size : 0));
  if (declaredBytes > _kMaxUncompressedBytes) {
    throw ImportFormatException(
      '“$name” unpacks to more than '
      '${(declaredBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB of '
      'CSV, which is not something we can import.',
    );
  }

  if (csvFiles.isEmpty) {
    throw ImportFormatException(
      '“$name” is an archive with no CSV files inside '
      '(${archive.files.length} entr${archive.files.length == 1 ? 'y' : 'ies'}). '
      'Pick the $flavor CSV export instead.',
    );
  }

  final out = <String>[];
  final used = <String>{};
  try {
    for (final f in csvFiles) {
    // Members can share a basename (`daily/data.csv`, `workouts/data.csv`).
    // Flattening them onto one destination silently dropped one file and
    // parsed the survivor twice.
      var base = p.basename(f.name);
      if (!used.add(base)) {
        final stem = p.basenameWithoutExtension(base);
        final ext = p.extension(base);
        var n = 2;
        while (!used.add(base = '$stem-$n$ext')) {
          n++;
        }
      }
      final destPath = p.join(dir.path, base);
      // `writeContent` decompresses straight to disk — never materialising the
      // member, which for a raw sensor export is the big one.
      final sink = OutputFileStream(destPath);
      try {
        f.writeContent(sink);
      } finally {
        await sink.close();
      }
      out.add(destPath);
    }
  } finally {
    await input.close();
  }
  return out;
}
