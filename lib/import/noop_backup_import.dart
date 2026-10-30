// noop_backup_import.dart — read a `.noopbak` full backup.
//
// A `.noopbak` is a ZIP around `noop-backup.sqlite`, NOOP's own GRDB database.
// On iOS it is the ONLY export NOOP offers, so every iOS user migrating across
// arrives with one; the raw-sensor CSV this importer originally required is
// Android-only. That is issue #160 for real, rather than the UTF-8 symptom.
//
// WHAT IT HOLDS (measured on a 13-day backup, 260 MB, NOOP 9.x):
//   hrSample(deviceId, ts, bpm)                 1,032,010 rows   1 Hz
//   rrInterval(deviceId, ts, rrMs)                505,358
//   gravitySample(deviceId, ts, x, y, z)        1,031,199        1 Hz
//   skinTempSample(deviceId, ts, raw)           1,031,199        1 Hz
//   stepSample(deviceId, ts, counter)           1,031,199        cumulative
//   spo2Sample / respSample                             0        present, empty
//   sleepSession / dailyMetric / metricSeries          12 / 14 / 24
// Timestamps are epoch SECONDS on a shared 1 Hz grid, which is the same shape as
// our own decoded substrate — so this is a FULL-FIDELITY source, not a summary
// import. We take the raw channels and re-derive; `sleepSession` and
// `dailyMetric` (NOOP's own scores) are deliberately NOT read, because a second
// set of stages and daily numbers would contradict the ones we compute.
//
// TWO TRAPS THIS FILE EXISTS TO AVOID:
//   1. `spo2Sample` and `respSample` are EMPTY in a real backup and a future
//      schema may drop them outright, so every table is probed before it is read.
//   2. deviceId is NOT consistent within one backup — the sample tables carry
//      "my-whoop" while sleepSession carries "my-whoop-noop". Nothing here
//      filters or joins on it: a user who replaced a strap has both ids over
//      disjoint spans and wants BOTH imported, and a per-second map keyed on ts
//      already collapses the (unrealistic) case of two straps worn at once.
//
// MEMORY. 3.6 M rows cannot be materialised, and sqflite serialises a whole
// result set on the platform side before any of it crosses the channel. So we
// walk one LOCAL DAY at a time (the unit [NoopIngest] derives anyway) and read
// each table for that day in pages.

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import 'import_container.dart';
import 'noop_import.dart';
import 'noop_ingest.dart';

/// "SQLite format 3\0" — the fixed 16-byte magic every SQLite file starts
/// with (https://www.sqlite.org/fileformat.html#the_database_header).
const List<int> _kSqliteMagic = [
  0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, //
  0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
];

/// Rows per platform-channel round trip. Big enough that a 1 Hz day is a handful
/// of queries, small enough that no single response is a memory event. Not
/// const: the page-boundary contract below is only testable at a small size.
@visibleForTesting
int kNoopBackupPageRows = 20000;

/// Plausible unix seconds (shared with the CSV path through [NoopIngest]). A
/// timestamp outside this range is corrupt or millisecond-scaled, and letting
/// one into the day walk would march it across decades one day at a time.
const int _kMinPlausibleTs = kNoopMinPlausibleTs;

/// Every table read, and the columns wanted from it. ONE definition: the probe
/// and the reads both key off this, so a name can no longer be spelled one way
/// here and another at a call site. That typo was silent — a mistyped table
/// simply produced an empty column list, the read skipped it, and every gravity
/// or skin-temperature sample vanished from the import with no error and a
/// still-positive day count.
const Map<String, List<String>> _kTableCols = {
  'hrSample': ['ts', 'bpm'],
  'rrInterval': ['ts', 'rrMs'],
  'gravitySample': ['ts', 'x', 'y', 'z'],
  'skinTempSample': ['ts', 'raw'],
  'spo2Sample': ['ts', 'red', 'ir'],
  'stepSample': ['ts', 'counter'],
};

class NoopBackupImporter {
  /// Import an already-extracted `noop-backup.sqlite` at [path].
  ///
  /// Opened READ-ONLY — a backup is the user's only copy of their history and
  /// this must not be able to write to it, even by accident.
  static Future<NoopImportResult> importDatabase(
    String path,
    Profile profile,
    DerivationEngine engine, {
    void Function(int days)? onProgress,
  }) async {
    if (!await File(path).exists()) {
      throw const ImportFormatException('That backup could not be read.');
    }
    Directory? scratch;
    try {
      final opened = await _repairTruncatedHeader(path);
      scratch = opened.$2;
      final Database src;
      try {
        src = await openDatabase(opened.$1, readOnly: true);
      } catch (e) {
        throw ImportFormatException(
          'That backup\'s database could not be opened ($e). If it came off '
          'another phone, try exporting it again.',
        );
      }
      try {
        return await _import(src, profile, engine, onProgress: onProgress);
      } finally {
        await src.close();
      }
    } finally {
      if (scratch != null) {
        try {
          await scratch.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// A `.noopbak` exported by copying NOOP's live database file (rather than
  /// through a proper backup API, e.g. `sqlite3_backup` or a WAL checkpoint)
  /// can catch it mid-write: new pages are already flushed to disk, but the
  /// header's page-count field (bytes 28-31, big-endian — see the SQLite file
  /// format spec) was not updated before the copy ran. Every B-tree pointer
  /// into one of those pages then reads as SQLITE_CORRUPT ("invalid page
  /// number") from the very first page it touches, which on a real backup
  /// meant losing gravity/skin-temp/step samples ENTIRELY rather than just
  /// their newest rows.
  ///
  /// Fixed by comparing the header's page count against how many whole pages
  /// the file actually holds: if there are more than the header claims, the
  /// header is patched to match, on a COPY — never the original, which may be
  /// the user's picked file with no [ResolvedNoopDatabase] tempDir to own it.
  /// A file the header already agrees with is returned untouched, so a normal
  /// backup pays no copy at all.
  ///
  /// This does NOT repair genuine row-level corruption from the same partial
  /// write (a torn B-tree page, rather than a stale page count) — that surfaces
  /// downstream as [_isCorruptPageError], and [_read] drops just the affected
  /// table rather than the whole import.
  static Future<(String, Directory?)> _repairTruncatedHeader(
    String path,
  ) async {
    final f = await File(path).open();
    final int fileLen;
    final List<int> header;
    try {
      header = await f.read(100);
      fileLen = await f.length();
    } finally {
      await f.close();
    }
    if (header.length < 100 ||
        !const ListEquality<int>().equals(
          header.sublist(0, 16),
          _kSqliteMagic,
        )) {
      return (path, null); // not a plain SQLite file (or too short to check)
    }
    final rawPageSize = (header[16] << 8) | header[17];
    // 1 means 65536 (the u16 field cannot hold it) — see the format spec.
    final pageSize = rawPageSize == 1 ? 65536 : rawPageSize;
    // SQLite only ever writes a power of two from 512 to 32768 (or the 1
    // encoding above). Anything else means the magic bytes matched but the
    // header itself is garbage — e.g. pageSize==3 would pass a bare
    // `fileLen % pageSize` check on plenty of ordinary file lengths and send
    // a file that was never a real SQLite page layout through the repair
    // copy, patching offset 28 against a page count that means nothing.
    final validPageSize = pageSize == 65536 ||
        (pageSize >= 512 && pageSize <= 32768 && (pageSize & (pageSize - 1)) == 0);
    if (!validPageSize || fileLen % pageSize != 0) return (path, null);
    final declaredPages =
        (header[28] << 24) | (header[29] << 16) | (header[30] << 8) | header[31];
    final actualPages = fileLen ~/ pageSize;
    if (actualPages <= declaredPages) return (path, null); // header agrees

    final scratch = await Directory.systemTemp.createTemp('openstrap_noopfix_');
    try {
      final repaired = p.join(scratch.path, 'repaired.sqlite');
      await File(path).copy(repaired); // OS-level copy, not materialised here
      final raf = await File(repaired).open(mode: FileMode.append);
      try {
        await raf.setPosition(28);
        final be = ByteData(4)..setUint32(0, actualPages, Endian.big);
        await raf.writeFrom(be.buffer.asUint8List());
      } finally {
        await raf.close();
      }
      return (repaired, scratch);
    } catch (_) {
      // Nothing has been returned yet, so the caller has no handle to clean
      // this up with — delete it here rather than leak a scratch dir + a
      // partial copy of the user's database on every failure.
      try {
        await scratch.delete(recursive: true);
      } catch (_) {
        /* the OS reclaims the temp dir eventually */
      }
      rethrow;
    }
  }

  static Future<NoopImportResult> _import(
    Database src,
    Profile profile,
    DerivationEngine engine, {
    void Function(int days)? onProgress,
  }) async {
    final tables = await _tableNames(src);
    // hrSample is the spine: no heart rate means nothing downstream can be
    // derived, so its absence is a wrong-file error rather than an empty import.
    if (!tables.contains('hrSample')) {
      throw ImportFormatException(
        'That database is not a NOOP backup — it has no `hrSample` table '
        '(found: ${tables.take(6).join(', ')}${tables.length > 6 ? '…' : ''}).',
      );
    }

    // Probe every table's columns ONCE, and do it BEFORE anything queries them.
    // The schema cannot change during a read-only import, and probing inside
    // the day walk cost a `PRAGMA table_info` per table per day. Order matters:
    // `_span` selects MIN(ts)/MAX(ts), so a drifted table with no `ts` at all
    // would throw a raw SQL error out of the span before the probe that exists
    // to skip it had run.
    final columns = <String, List<String>>{};
    final ordered = <String, String>{};
    for (final e in _kTableCols.entries) {
      if (!tables.contains(e.key)) continue;
      final have = await _columnNames(src, e.key);
      columns[e.key] = [for (final c in e.value) if (have.contains(c)) c];
      // `ORDER BY ts` is not a total order — `rrInterval` holds several beats
      // per second — and the drain below pages an equal-timestamp group with
      // OFFSET, which is only meaningful if both queries see the SAME order.
      // `rowid` provides one for free on an ordinary table; a WITHOUT ROWID
      // table has none, so probe rather than assume.
      ordered[e.key] = await _hasRowid(src, e.key) ? 'ts, rowid' : 'ts';
    }

    // The spine has to be USABLE, not merely present. A `hrSample` with no
    // `bpm` clears the table-name check above and is then silently skipped by
    // every read — the other channels would carry the import to a plausible day
    // count with no heart rate in any of it.
    if ((columns['hrSample'] ?? const []).length <
        _kTableCols['hrSample']!.length) {
      throw const ImportFormatException(
        'That database has an `hrSample` table without the columns we read '
        '(`ts`, `bpm`), so there is no heart rate to import.',
      );
    }

    // Only tables we can actually read contribute to the span.
    final readable = {
      for (final e in columns.entries)
        if (e.value.length == (_kTableCols[e.key]?.length ?? -1)) e.key,
    };

    // A backup exported by copying NOOP's live database file (rather than
    // through a proper backup API) can leave a scattered corrupt page
    // anywhere in a table's own storage. None of these tables carry an index
    // usable for a `ts` range that ALSO covers the other columns a read here
    // selects (x/y/z, bpm, …), so every per-day read of an affected table
    // scans the WHOLE table before it can emit a single row — the `ts`
    // window narrows what's kept, not what's touched. That means one corrupt
    // page anywhere in a table fails EVERY day's read of it identically, not
    // just the day the bad page would chronologically belong to, so a table
    // goes in here once and stays — there is no point re-running the same
    // failing whole-table scan on every remaining day.
    //
    // Declared before the span probe (not just before the day walk below):
    // `_span`'s own whole-table MIN/MAX scan can hit the same SQLITE_CORRUPT a
    // per-day `_read` would, and if every table is torn this badly, `_span`
    // returns null — that must still surface as "corrupted", not as "empty",
    // which is the exact distinction this file exists to make.
    final corrupt = <String>{};
    final span = await _span(src, readable, corrupt);
    if (span == null) {
      throw ImportFormatException(corrupt.isNotEmpty
          ? 'That NOOP backup file is corrupted — SQLite cannot read '
              '${corrupt.join(', ')}, and those are every table this app '
              'imports. There is nothing left to recover from this file; '
              'export a new backup from NOOP.'
          : 'That NOOP backup holds no samples — there is nothing to import.');
    }
    final (minTs, maxTs) = span;

    final ingest = NoopIngest(profile, engine, onProgress: onProgress);

    // Walk LOCAL days. Built through the DateTime(y, m, d + 1) constructor
    // rather than `add(Duration(days: 1))` so a DST boundary lands on real local
    // midnight instead of 23:00 or 01:00.
    var dayStart = _localMidnight(minTs);
    while (dayStart.millisecondsSinceEpoch ~/ 1000 <= maxTs) {
      final next = DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
      final from = dayStart.millisecondsSinceEpoch ~/ 1000;
      final to = next.millisecondsSinceEpoch ~/ 1000;

      // [NoopIngest] re-sorts by timestamp but keeps rows that share a second in
      // arrival order, so beats within a second must come in detection order
      // (the `ts, rowid` order above). The DAYS must also arrive in ascending
      // order, since the high-water date is what closes out and derives the
      // previous one.
      await _read(src, tables, columns, ordered, corrupt, 'hrSample', from, to,
          (r) async {
        final ts = _int(r['ts']), v = _int(r['bpm']);
        if (ts == null || v == null) return;
        if (await ingest.offer(ts)) ingest.hr(ts, v);
      });
      await _read(src, tables, columns, ordered, corrupt, 'rrInterval', from,
          to, (r) async {
        final ts = _int(r['ts']), v = _num(r['rrMs']);
        if (ts == null || v == null) return;
        if (await ingest.offer(ts)) ingest.rr(ts, v);
      });
      await _read(src, tables, columns, ordered, corrupt, 'gravitySample',
          from, to, (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) {
          ingest.gravity(ts, _num(r['x']), _num(r['y']), _num(r['z']));
        }
      });
      await _read(src, tables, columns, ordered, corrupt, 'skinTempSample',
          from, to, (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) ingest.skinTemp(ts, _int(r['raw']));
      });
      await _read(src, tables, columns, ordered, corrupt, 'spo2Sample', from,
          to, (r) async {
        final ts = _int(r['ts']);
        if (ts == null) return;
        if (await ingest.offer(ts)) {
          ingest.spo2(ts, _int(r['red']), _int(r['ir']));
        }
      });
      await _read(src, tables, columns, ordered, corrupt, 'stepSample', from,
          to, (r) async {
        final ts = _int(r['ts']), v = _int(r['counter']);
        if (ts == null || v == null) return;
        if (await ingest.offer(ts)) ingest.stepCounter(ts, v);
      });

      dayStart = next;
    }

    if (ingest.rows == 0) {
      // Every channel we read came back corrupt (see [_isCorruptPageError]) —
      // this is not "the backup is empty", it is "SQLite itself cannot read
      // the file", and the two must never share a message.
      throw ImportFormatException(corrupt.isNotEmpty
          ? 'That NOOP backup file is corrupted — SQLite cannot read '
              '${corrupt.join(', ')}, and those are every table this app '
              'imports. There is nothing left to recover from this file; '
              'export a new backup from NOOP.'
          : 'That NOOP backup holds no samples we could read.');
    }
    await ingest.finish();
    return NoopImportResult(ingest.days, ingest.rows, ingest.lateRows,
        ingest.steps, ingest.strandedDates, corrupt);
  }

  /// Page one table's rows for the half-open window [from, to) into [onRow].
  /// A table the backup does not have — or one whose columns have drifted — is
  /// skipped rather than failing the import mid-way.
  ///
  /// Paged by KEYSET (`ts > last`), not OFFSET: LIMIT/OFFSET re-walks and
  /// re-discards every skipped row, so paging an 86,400-row day turns quadratic.
  ///
  /// The cursor is the RAW column value, never a truncated second. `ts` is not
  /// unique — `rrInterval`'s key is (deviceId, ts, rrMs), so one second holds
  /// several beats — so a page boundary can land inside a timestamp, and the
  /// trailing rows sharing it are held back and re-read whole on the next page.
  /// Keying that cursor on `ts` truncated to an int looks equivalent and is not:
  /// against a REAL column (a GRDB `Date` is stored as one) `ts > 3.0` does not
  /// exclude `3.2`, so the same rows come back forever — or, with a guard
  /// against that, the read stops early and silently drops the rest of the day.
  static Future<void> _read(
    Database src,
    Set<String> tables,
    Map<String, List<String>> columns,
    Map<String, String> ordered,
    Set<String> corrupt,
    String table,
    int from,
    int to,
    Future<void> Function(Map<String, Object?> row) onRow,
  ) async {
    // A table name with no entry is a programming error, not a schema
    // variation — fail loudly here rather than silently importing without that
    // channel.
    final cols = _kTableCols[table]!;
    if (!tables.contains(table)) return;
    if (corrupt.contains(table)) return; // already hit a torn page, see below
    final usable = columns[table] ?? const <String>[];
    if (usable.length < cols.length) return;
    final orderBy = ordered[table] ?? 'ts';

    // `ts >= from` on the FIRST page, `ts > cursor` after. Not `ts > from - 1`:
    // that is only equivalent for integral timestamps, and against a fractional
    // one it makes the open interval (to-1, to) belong to BOTH the day that
    // ends at `to` and the day that starts there. The straddling rows are then
    // read twice, and while the map-keyed channels absorb that, `rr()` APPENDS —
    // a duplicated beat corrupts the night's RMSSD rather than costing a row.
    num cursor = from;
    var firstPage = true;
    while (true) {
      final List<Map<String, Object?>> rows;
      try {
        rows = await src.query(
          table,
          columns: cols,
          where: firstPage ? 'ts >= ? AND ts < ?' : 'ts > ? AND ts < ?',
          whereArgs: [cursor, to],
          orderBy: orderBy,
          limit: kNoopBackupPageRows,
        );
      } catch (e) {
        if (!_isCorruptPageError(e)) rethrow;
        // A whole-table scan (see the comment above [corrupt]'s declaration)
        // means this can surface on page ONE of day one — there is usually
        // nothing from this table to salvage, only nothing further lost by
        // trying. Every OTHER channel keeps importing regardless.
        corrupt.add(table);
        return;
      }
      firstPage = false;
      if (rows.isEmpty) return;
      final full = rows.length == kNoopBackupPageRows;

      // Hold back the trailing rows that share the last timestamp EXACTLY; the
      // next page re-reads that timestamp whole.
      var end = rows.length;
      if (full) {
        final lastTs = _raw(rows.last['ts']);
        while (end > 0 && _raw(rows[end - 1]['ts']) == lastTs) {
          end--;
        }
      }
      // A whole page sharing one timestamp cannot hold anything back without
      // stalling. Take it, then drain whatever else carries that exact value
      // before stepping past it — stepping past directly would silently lose
      // the remainder, which is the partial-history failure this file refuses
      // everywhere else. Offset-paged, but bounded to one timestamp's rows.
      if (end == 0) {
        final lastTs = _raw(rows.last['ts']);
        for (final r in rows) {
          await onRow(r);
        }
        var drained = rows.length;
        while (lastTs != null) {
          final List<Map<String, Object?>> more;
          try {
            more = await src.query(
              table,
              columns: cols,
              where: 'ts = ?',
              whereArgs: [lastTs],
              orderBy: orderBy,
              limit: kNoopBackupPageRows,
              offset: drained,
            );
          } catch (e) {
            if (!_isCorruptPageError(e)) rethrow;
            corrupt.add(table);
            return;
          }
          if (more.isEmpty) break;
          for (final r in more) {
            await onRow(r);
          }
          drained += more.length;
          if (more.length < kNoopBackupPageRows) break;
        }
        if (lastTs == null) return; // a NULL ts cannot be paged past
        cursor = lastTs;
        continue;
      }

      for (var i = 0; i < end; i++) {
        await onRow(rows[i]);
      }
      if (!full) return;
      // The cursor is the last row actually EMITTED, so nothing is skipped and
      // the next page starts strictly after it.
      final next = _raw(rows[end - 1]['ts']);
      if (next == null || next <= cursor) return; // non-numeric ts: stop
      cursor = next;
    }
  }

  /// SQLite's own corruption signal (`SQLITE_CORRUPT`, result code 11 —
  /// "database disk image is malformed") reached mid-scan, distinguished from
  /// every other [DatabaseException] (a typo'd column, a closed database) that
  /// this must NOT swallow. Matched on message text because sqflite does not
  /// expose the result code uniformly across its Android/iOS/ffi backends —
  /// see [DatabaseException.getResultCode]'s own comment on the same problem.
  static bool _isCorruptPageError(Object e) =>
      e is DatabaseException &&
      (e.toString().contains('malformed') ||
          e.toString().contains('SQLITE_CORRUPT'));

  /// Earliest and latest sample timestamp across every table we read, so the day
  /// walk covers days that carry (say) only a step counter.
  static Future<(int, int)?> _span(
    Database src,
    Set<String> tables,
    Set<String> corrupt,
  ) async {
    int? lo, hi;
    for (final t in const [
      'hrSample',
      'rrInterval',
      'gravitySample',
      'skinTempSample',
      'spo2Sample',
      'stepSample',
    ]) {
      if (!tables.contains(t)) continue;
      // The plausibility bound is applied INSIDE the aggregate, not to its
      // result. MIN/MAX collapse the table to two rows, so a single corrupt
      // timestamp — one `ts = 0`, one millisecond-scaled row — would otherwise
      // disqualify the entire table and, if every table has one, fail the
      // import as "no samples" on a backup holding years of data.
      // A table torn by a live-copy export (see [_read]) can fail this
      // whole-table scan before it returns a row at all. One corrupt table
      // does not sink the span — every other table covers roughly the same
      // 1 Hz timeline, and [_read] below marks the same table corrupt on its
      // first day and drops only that channel from the import.
      final List<Map<String, Object?>> r;
      try {
        r = await src.rawQuery(
          'SELECT MIN(ts) AS lo, MAX(ts) AS hi FROM $t WHERE ts >= ? AND ts <= ?',
          [_kMinPlausibleTs, noopMaxPlausibleTs()],
        );
      } catch (e) {
        if (!_isCorruptPageError(e)) rethrow;
        corrupt.add(t);
        continue;
      }
      if (r.isEmpty) continue;
      final a = _int(r.first['lo']), b = _int(r.first['hi']);
      if (a == null || b == null) continue;
      lo = lo == null || a < lo ? a : lo;
      hi = hi == null || b > hi ? b : hi;
    }
    return (lo == null || hi == null) ? null : (lo, hi);
  }

  /// Does [table] have an implicit `rowid`? False for a WITHOUT ROWID table,
  /// where selecting it is an error rather than an empty result.
  static Future<bool> _hasRowid(Database src, String table) async {
    try {
      await src.rawQuery('SELECT rowid FROM $table LIMIT 1');
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Set<String>> _columnNames(Database src, String table) async {
    final rows = await src.rawQuery('PRAGMA table_info($table)');
    return {for (final r in rows) (r['name'] as String?) ?? ''};
  }

  static Future<Set<String>> _tableNames(Database src) async {
    final rows = await src
        .rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
    return {for (final r in rows) (r['name'] as String?) ?? ''};
  }

  static DateTime _localMidnight(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    return DateTime(d.year, d.month, d.day);
  }

  static int? _int(Object? v) => v is int
      ? v
      : v is num
          ? v.toInt()
          : null;

  static double? _num(Object? v) => v is num ? v.toDouble() : null;

  /// The timestamp column's value as stored — INTEGER in every NOOP schema seen
  /// so far, but REAL is representable and must page correctly either way.
  static num? _raw(Object? v) => v is num ? v : null;
}
