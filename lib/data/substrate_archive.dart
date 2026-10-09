// The compressed, durable copy of the decoded substrate that the retention
// prune deletes from `decoded_onehz` / `decoded_rr`.
//
// WHY IT EXISTS. Derived results are immutable per `kAlgoVersion`, and a bump
// re-derives only the days whose 1 Hz substrate is still on disk — about
// `rawRetentionDays` of them. Every older day keeps the score of whichever
// version derived it, forever, because nothing is left to re-derive from.
// This table is that something: every row the prune removes, lossless, at
// roughly a tenth of its live size (see substrate_archive_codec.dart).
//
// WRITE SIDE ONLY, FOR NOW. Nothing re-derives from the archive yet — the
// derive reads, `decodedRecTsMaxByDay` and `rescanDayIds` still see only the
// live tables, so a bump still heals only live days. Re-deriving archived
// history is the follow-up this table exists for; it can only ever cover the
// days archived before it lands, which is why the archive starts first.
//
// ONE BUCKET PER (device_id, utc_day), `utc_day = rec_ts ~/ 86400`. That is a
// storage partition of ABSOLUTE time, not a day label: a bucket is a pure
// function of the row, so a re-delivered second always lands in the same
// bucket whatever the phone's timezone was. Local day labels are still only
// ever computed through day_label.dart, at read time, over a [from, to] range.
//
// LocalDb owns the table's DDL and delegates the logic here. Nothing in this
// file opens the database itself; every function takes the executor it runs
// on, so the archive step of a prune shares the prune's transaction.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';

import 'substrate_archive_codec.dart';

/// How long archived substrate is kept. Stored in `compute_freshness` so a
/// headless engine reads the same policy as the foreground one.
class SubstrateArchivePolicy {
  const SubstrateArchivePolicy(this.keepDays);

  /// One year. Chosen before a measurement on real exports; revisit with the
  /// bytes/day the size probe reports (see substrate_archive_size_probe_test).
  static const SubstrateArchivePolicy defaults = SubstrateArchivePolicy(365);

  /// 0 = off (and purged), -1 = forever, otherwise days behind the data edge.
  final int keepDays;

  bool get enabled => keepDays != 0;

  String toJson() => jsonEncode({'keep_days': keepDays});

  /// [defaults] for anything missing or malformed — an unreadable setting
  /// must not silently switch archiving off.
  static SubstrateArchivePolicy fromJson(String? json) {
    if (json == null) return defaults;
    try {
      final v = (jsonDecode(json) as Map)['keep_days'];
      if (v is int && v >= -1) return SubstrateArchivePolicy(v);
    } catch (_) {
      // fall through
    }
    return defaults;
  }

  @override
  bool operator ==(Object other) =>
      other is SubstrateArchivePolicy && other.keepDays == keepDays;

  @override
  int get hashCode => keepDays.hashCode;
}

abstract final class SubstrateArchive {
  static const String table = 'substrate_archive';

  /// `compute_freshness` key holding the [SubstrateArchivePolicy].
  static const String policyKey = 'substrate_archive_policy';

  /// `compute_freshness` key counting, per `device|utc_day`, the passes on
  /// which a bucket past the hold failed for a non-deterministic reason.
  static const String failuresKey = 'substrate_archive_failures';

  /// Failed passes past the hold after which ANY failure counts as
  /// permanent — see [archiveAndDeleteBefore].
  static const int maxFailedPasses = 3;

  static const int _pageSize = 5000;

  /// Test seam: corrupts the next encodes INSIDE the verify step, so the
  /// verify-before-delete path is exercised for real.
  @visibleForTesting
  static bool debugCorruptEncode = false;

  /// Test seam: awaited before each bucket's transaction during a prune, so a
  /// test can interleave another writer between two buckets.
  @visibleForTesting
  static Future<void> Function()? debugBeforeBucket;

  /// Test seam: thrown inside each bucket's transaction, to stand in for a
  /// transient failure (SQLITE_BUSY, an isolate that could not start).
  @visibleForTesting
  static Object? debugThrowInBucket;

  /// Test seam: awaited inside the past-the-hold unarchived delete's
  /// transaction, so a test can make that delete fail.
  @visibleForTesting
  static Future<void> Function()? debugBeforeFallbackDelete;

  @visibleForTesting
  static int get pageSizeForTest => _pageSize;

  static const int _blobChunk = 512 * 1024;

  /// Every column but `blob`, for reads that must not return a whole bucket
  /// in one row — see [readBlob].
  static const List<String> metaColumns = [
    'device_id',
    'utc_day',
    'codec',
    'from_ts',
    'to_ts',
    'onehz_rows',
    'rr_rows',
    'raw_bytes',
    'fingerprint',
    'tz_offset_min',
    'created_at',
    'updated_at',
  ];

  /// One bucket's blob, read in chunks, or null when there is no such row.
  ///
  /// NEVER select `blob` as a column: Android returns query results through a
  /// CursorWindow that cannot hold a row much over 2 MB, and a full day is
  /// about 1 MB measured, more for a fast second sensor — one oversized row
  /// would make that day unreadable to every path. `substr` slices are small
  /// rows. Works on any database holding the table (a restore's source too).
  static Future<Uint8List?> readBlob(
    DatabaseExecutor ex,
    String deviceId,
    int day,
  ) async {
    const where = 'device_id = ? AND utc_day = ?';
    final n = (await ex.rawQuery(
      'SELECT length(blob) AS n FROM $table WHERE $where',
      [deviceId, day],
    ));
    if (n.isEmpty || n.first['n'] is! num) return null;
    final len = (n.first['n'] as num).toInt();
    final out = Uint8List(len);
    for (var off = 0; off < len; off += _blobChunk) {
      final part =
          (await ex.rawQuery(
                'SELECT substr(blob, ?, ?) AS part FROM $table WHERE $where',
                [off + 1, _blobChunk, deviceId, day],
              )).first['part']
              as Uint8List;
      out.setRange(off, off + part.length, part);
    }
    return out;
  }

  /// The policy as stored, on [ex] — inside a transaction when the caller
  /// needs it to agree with what that transaction writes.
  static Future<SubstrateArchivePolicy> readPolicy(DatabaseExecutor ex) async {
    final rows = await ex.query(
      'compute_freshness',
      columns: ['payload_json'],
      where: 'key = ?',
      whereArgs: [policyKey],
      limit: 1,
    );
    return SubstrateArchivePolicy.fromJson(
      rows.isEmpty ? null : rows.first['payload_json'] as String?,
    );
  }

  /// Store [policy]; switching to Off purges the archive IN THE SAME
  /// TRANSACTION, so no reader ever sees "off" next to a table still full.
  static Future<void> writePolicy(Database db, SubstrateArchivePolicy policy) =>
      db.transaction((txn) async {
        await txn.insert('compute_freshness', {
          'key': policyKey,
          'payload_json': policy.toJson(),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        if (!policy.enabled) await txn.delete(table);
      });

  /// Restore/salvage onto a database with NO archive of its own: bring the
  /// source's policy along — otherwise a "forever" archive comes back under
  /// the default, and the next housekeeping pass evicts what it was told to
  /// keep.
  ///
  /// Never adopted over local history. A local policy row always wins, and so
  /// does a local archive under the implicit default: that history was kept
  /// on this phone, and importing some other backup's "Off" must not be what
  /// deletes it (a restore only ever ADDS history). Checked and written in one
  /// transaction, so an archive cannot appear between the two.
  static Future<void> adoptPolicy(DatabaseExecutor src, Database db) async {
    final List<Map<String, Object?>> theirs;
    try {
      theirs = await src.query(
        'compute_freshness',
        columns: ['payload_json'],
        where: 'key = ?',
        whereArgs: [policyKey],
        limit: 1,
      );
    } on DatabaseException catch (e) {
      if (e.isNoSuchTableError()) return;
      rethrow;
    }
    if (theirs.isEmpty) return;
    final adopted = SubstrateArchivePolicy.fromJson(
      theirs.first['payload_json'] as String?,
    );
    await db.transaction((txn) async {
      final ours = await txn.query(
        'compute_freshness',
        columns: ['key'],
        where: 'key = ?',
        whereArgs: [policyKey],
        limit: 1,
      );
      if (ours.isNotEmpty) return;
      final anyLocal = await txn.query(table, columns: ['utc_day'], limit: 1);
      if (anyLocal.isNotEmpty) return;
      await txn.insert('compute_freshness', {
        'key': policyKey,
        'payload_json': adopted.toJson(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  /// Archive, then delete, every decoded row with `0 < rec_ts < cutoffSec`.
  /// Returns the number of live rows deleted.
  ///
  /// EACH BUCKET IS ITS OWN TRANSACTION: read the bucket's live rows, merge
  /// them into the existing blob (live rows win, as in the live table), encode,
  /// decode the result again and compare (see
  /// [SubstrateArchiveCodec.encodeMergeVerify]), write it, and only then delete
  /// the live rows. Bounded lock time, and nothing is deleted unless the blob
  /// holding it has been read back.
  ///
  /// The policy is RE-READ inside each bucket's transaction: archiving
  /// switched off while a prune is running (the purge is one transaction with
  /// the setting, see [writePolicy]) must not be followed by this prune
  /// writing a fresh bucket after it.
  ///
  /// A bucket that fails STAYS LIVE and is retried on the next pass. The one
  /// exception is a DETERMINISTIC failure — the codec refusing the data or
  /// failing its own read-back, or an existing blob this build cannot read —
  /// on a bucket entirely behind [hardFloorSec] (the end of the bounded
  /// hold). That failure would repeat on every pass, so the bucket is deleted
  /// unarchived exactly as before this table existed, and one bad bucket
  /// cannot switch retention off. Anything else (SQLITE_BUSY, an isolate that
  /// could not start, I/O) is treated as transient and retried — but a bucket
  /// past the hold that has failed on [maxFailedPasses] passes (an encode that
  /// runs out of memory on a huge day fails "transiently" forever) is treated
  /// as permanent too. The count persists in `compute_freshness`
  /// ([failuresKey]) and is cleared when the bucket archives.
  ///
  /// [maxBuckets] caps how many buckets one pass archives; the rest stay live
  /// for the next pass (background engines run on a short, throttled budget).
  ///
  /// The `UNION` over both tables is required: gen4 history can carry
  /// beat-only seconds with no 1 Hz parent row.
  ///
  /// [onDeleted] runs inside every transaction that deletes live rows, with
  /// the bound below which that transaction deleted them — the caller's
  /// "pruned before" cursor rises with the delete, never after it.
  ///
  /// [shouldYield] is checked before EACH bucket; once it returns true the
  /// pass stops archiving and every bucket it did not reach stays live, to be
  /// archived next pass — never deleted unarchived. It is how a band offload
  /// that starts mid-prune gets the database back: a bucket holds the write
  /// lock for its whole transaction (a full 1 Hz day measured ~3 s on a
  /// loaded machine), so a drain commit waits behind at most ONE in-flight
  /// bucket rather than a backlog of them. Ordering is unchanged — the
  /// drain's commit still lands before its ACK; it only lands later.
  static Future<int> archiveAndDeleteBefore(
    Database db,
    int cutoffSec, {
    int? hardFloorSec,
    void Function(String message)? log,
    bool Function()? shouldYield,
    int? maxBuckets,
    Future<void> Function(Transaction txn, int beforeSec)? onDeleted,
  }) async {
    final buckets = await db.rawQuery(
      'SELECT device_id, rec_ts / 86400 AS d FROM decoded_onehz '
      'WHERE rec_ts > 0 AND rec_ts < ? '
      'UNION '
      'SELECT device_id, rec_ts / 86400 AS d FROM decoded_rr '
      'WHERE rec_ts > 0 AND rec_ts < ? '
      'ORDER BY d, device_id',
      [cutoffSec, cutoffSec],
    );
    var deleted = 0, attempted = 0;
    final failures = await _readFailures(db);
    var failuresChanged = false;
    // The counts are saved however the loop ends, so a pass that stops
    // early never loses the increments it already made.
    try {
      for (final b in buckets) {
        final deviceId = b['device_id'] as String;
        final day = (b['d'] as num).toInt();
        final lo = day * 86400;
        final hi = math.min((day + 1) * 86400, cutoffSec);
        await debugBeforeBucket?.call();
        if (maxBuckets != null && attempted >= maxBuckets) break;
        attempted++;
        if (shouldYield?.call() ?? false) {
          log?.call(
            'substrate archive: offload active, leaving the rest live for the '
            'next pass',
          );
          break;
        }
        final failureKey = '$deviceId|$day';
        try {
          deleted += await db.transaction((txn) async {
            final n = await _archiveBucket(txn, deviceId, day, lo, hi);
            await onDeleted?.call(txn, hi);
            return n;
          });
          if (failures.remove(failureKey) != null) failuresChanged = true;
        } catch (e) {
          final pastHold = hardFloorSec != null && hi <= hardFloorSec;
          var permanent =
              e is StateError || e is ArgumentError || e is FormatException;
          if (pastHold && !permanent) {
            final n = (failures[failureKey] ?? 0) + 1;
            failures[failureKey] = n;
            failuresChanged = true;
            permanent = n >= maxFailedPasses;
          }
          if (permanent && pastHold) {
            // Guarded: one bucket whose delete fails (a concurrent writer
            // holding the lock) must not end the pass for every other
            // bucket. It stays live and keeps its count, so the next pass
            // tries again.
            try {
              deleted += await db.transaction((txn) async {
                await debugBeforeFallbackDelete?.call();
                final n = await _deleteLive(txn, deviceId, lo, hi);
                await onDeleted?.call(txn, hi);
                return n;
              });
              if (failures.remove(failureKey) != null) failuresChanged = true;
              log?.call(
                'substrate archive failed for $deviceId/$day ($e); past the '
                'hold, deleted unarchived',
              );
            } catch (e2) {
              log?.call(
                'substrate archive failed for $deviceId/$day ($e) and the '
                'unarchived delete failed too ($e2); kept live for the next '
                'pass',
              );
            }
          } else {
            log?.call(
              'substrate archive failed for $deviceId/$day ($e); kept live for '
              'the next pass',
            );
          }
        }
      }
    } finally {
      if (failuresChanged) {
        await db.insert('compute_freshness', {
          'key': failuresKey,
          'payload_json': jsonEncode(failures),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    return deleted;
  }

  static Future<Map<String, int>> _readFailures(DatabaseExecutor ex) async {
    final rows = await ex.query(
      'compute_freshness',
      columns: ['payload_json'],
      where: 'key = ?',
      whereArgs: [failuresKey],
      limit: 1,
    );
    if (rows.isEmpty) return {};
    try {
      final m = jsonDecode(rows.first['payload_json'] as String) as Map;
      return {
        for (final e in m.entries)
          if (e.value is int) '${e.key}': e.value as int,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<int> _archiveBucket(
    Transaction txn,
    String deviceId,
    int day,
    int lo,
    int hi,
  ) async {
    final fault = debugThrowInBucket;
    if (fault != null) throw fault;
    // Switched off since this prune started: the old behaviour, no archive.
    if (!(await readPolicy(txn)).enabled) {
      return _deleteLive(txn, deviceId, lo, hi);
    }
    final (onehz, rr) = await _readLivePages(txn, deviceId, lo, hi);
    final existing = await txn.query(
      table,
      columns: ['codec', 'created_at', 'tz_offset_min'],
      where: 'device_id = ? AND utc_day = ?',
      whereArgs: [deviceId, day],
    );
    final prior = existing.isEmpty ? null : existing.first;
    final w = await _encodeOffIsolate(
      onehz,
      rr,
      prior == null ? null : await readBlob(txn, deviceId, day),
      (prior?['codec'] as num?)?.toInt() ?? SubstrateArchiveCodec.codecId,
      debugCorruptEncode,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await txn.insert(
      table,
      _row(
        deviceId,
        day,
        w,
        // PROVENANCE IS SET ONCE. The first archival is the one closest in
        // time to when the bucket was recorded, so its zone is the best
        // evidence there is; a later merge (late rows, a re-flood) never
        // rewrites it — not even an unknown (NULL) one, which stays unknown
        // rather than claiming today's zone for seconds recorded earlier. If
        // late rows were in fact recorded in another zone, the bucket keeps
        // its first zone: a re-derive's timezone guard then errs towards the
        // zone most of the bucket was recorded in.
        //
        // The offset is the zone's AT THE BUCKET'S OWN INSTANT, so DST alone
        // never makes an archived day look like it was recorded elsewhere.
        tzOffsetMin: prior != null
            ? (prior['tz_offset_min'] as num?)?.toInt()
            : DateTime.fromMillisecondsSinceEpoch(
                lo * 1000,
              ).timeZoneOffset.inMinutes,
        createdAt: (prior?['created_at'] as num?)?.toInt() ?? now,
        updatedAt: now,
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return _deleteLive(txn, deviceId, lo, hi);
  }

  static Future<int> _deleteLive(
    DatabaseExecutor ex,
    String deviceId,
    int lo,
    int hi,
  ) async {
    final rr = await ex.delete(
      'decoded_rr',
      where: 'device_id = ? AND rec_ts >= ? AND rec_ts < ?',
      whereArgs: [deviceId, lo, hi],
    );
    final onehz = await ex.delete(
      'decoded_onehz',
      where: 'device_id = ? AND rec_ts >= ? AND rec_ts < ?',
      whereArgs: [deviceId, lo, hi],
    );
    return rr + onehz;
  }

  /// Page queries for one device's live rows in a `rec_ts` range, keyset on
  /// the primary key so each page is an index seek, never an OFFSET re-scan.
  /// `+rec_ts` keeps the planner on the primary key (and its order) instead
  /// of the `rec_ts` index plus a sort, and the bucket's own `ts_ms` span
  /// (read first, [_spanSql]) bounds the walk at both ends — without it the
  /// last page scanned on through every later live row of the device. The
  /// R-R cursor is a ROW VALUE, which SQLite (3.15+; Android API 26 ships
  /// 3.18) can seek on — the equivalent `ts_ms > ? OR (ts_ms = ? AND …)`
  /// cannot be, and walks the day from the start on every page.
  @visibleForTesting
  static const String onehzPageSql =
      'SELECT * FROM decoded_onehz '
      'WHERE device_id = ? AND +rec_ts >= ? AND +rec_ts < ? '
      'AND ts_ms > ? AND ts_ms <= ? '
      'ORDER BY ts_ms LIMIT ?';
  @visibleForTesting
  static const String rrPageSql =
      'SELECT * FROM decoded_rr '
      'WHERE device_id = ? AND +rec_ts >= ? AND +rec_ts < ? '
      'AND (ts_ms, beat_index) > (?, ?) AND ts_ms <= ? '
      'ORDER BY ts_ms, beat_index LIMIT ?';

  /// One device's `ts_ms` span within a `rec_ts` range, off the rec_ts index.
  static String _spanSql(String t) =>
      'SELECT MIN(ts_ms) AS lo, MAX(ts_ms) AS hi FROM $t '
      'WHERE device_id = ? AND rec_ts >= ? AND rec_ts < ?';

  /// One device's live rows in `[lo, hi)`, every column (`SELECT *`), as
  /// typed pages: each page is converted as it arrives (see
  /// [ArchiveTableBuilder]), so this isolate never holds a day of row maps.
  /// Row order inside the bucket is fixed by the codec's merge, not here.
  static Future<(List<ArchiveTable>, List<ArchiveTable>)> _readLivePages(
    DatabaseExecutor ex,
    String deviceId,
    int lo,
    int hi,
  ) async {
    Future<(int, int)?> span(String t) async {
      final r = (await ex.rawQuery(_spanSql(t), [deviceId, lo, hi])).first;
      final a = r['lo'], b = r['hi'];
      return a is num && b is num ? (a.toInt(), b.toInt()) : null;
    }

    // Beat indices start at 0, so this is below every real one.
    const anyBeat = -(1 << 62);
    final onehz = ArchiveTableBuilder();
    final onehzSpan = await span('decoded_onehz');
    if (onehzSpan != null) {
      var afterTs = onehzSpan.$1 - 1;
      while (true) {
        final page = await ex.rawQuery(onehzPageSql, [
          deviceId,
          lo,
          hi,
          afterTs,
          onehzSpan.$2,
          _pageSize,
        ]);
        onehz.addRows(page);
        if (page.length < _pageSize) break;
        afterTs = (page.last['ts_ms'] as num).toInt();
      }
    }
    final rr = ArchiveTableBuilder();
    final rrSpan = await span('decoded_rr');
    if (rrSpan != null) {
      var afterSec = rrSpan.$1 - 1, afterBeat = anyBeat;
      while (true) {
        final page = await ex.rawQuery(rrPageSql, [
          deviceId,
          lo,
          hi,
          afterSec,
          afterBeat,
          rrSpan.$2,
          _pageSize,
        ]);
        rr.addRows(page);
        if (page.length < _pageSize) break;
        afterSec = (page.last['ts_ms'] as num).toInt();
        afterBeat = (page.last['beat_index'] as num).toInt();
      }
    }
    return (onehz.pages, rr.pages);
  }

  // Each `Isolate.run` closure is built in a function whose scope holds only
  // what it sends — typed pages and blobs, never a Transaction or a row map.
  static Future<ArchiveWrite> _encodeOffIsolate(
    List<ArchiveTable> onehz,
    List<ArchiveTable> rr,
    Uint8List? existing,
    int existingCodec,
    bool corrupt,
  ) => Isolate.run(
    () => SubstrateArchiveCodec.encodeMergeVerify(
      ArchiveBucket(ArchiveTable.concat(onehz), ArchiveTable.concat(rr)),
      existing: existing,
      existingCodec: existingCodec,
      corruptForTest: corrupt,
    ),
  );

  /// The blob decodes and matches its recorded fingerprint.
  static Future<bool> _blobIntactOffIsolate(
    Uint8List blob,
    int codec,
    int fingerprint,
  ) => Isolate.run(() {
    final b = SubstrateArchiveCodec.decode(blob, codec: codec);
    return b != null && SubstrateArchiveCodec.fingerprint(b) == fingerprint;
  });

  /// Null when the blob cannot be decoded; an EMPTY write when nothing of it
  /// lies in [ranges].
  static Future<ArchiveWrite?> _keepOffIsolate(
    Uint8List blob,
    int codec,
    List<(int, int)> ranges,
  ) => Isolate.run(() {
    final b = SubstrateArchiveCodec.decode(blob, codec: codec);
    if (b == null) return null;
    return SubstrateArchiveCodec.keepRanges(b, ranges) ?? ArchiveWrite.empty();
  });

  /// `unreadable` ⇒ the blob can never be decoded by this build (unknown
  /// codec, corruption). Any other failure THROWS.
  static Future<({bool unreadable, ArchiveWrite? write})> _dropOffIsolate(
    Uint8List blob,
    int codec,
    List<(int, int)> ranges,
    bool corrupt,
  ) => Isolate.run(() {
    final b = SubstrateArchiveCodec.decode(blob, codec: codec);
    if (b == null) return (unreadable: true, write: null);
    return (
      unreadable: false,
      write: SubstrateArchiveCodec.dropRanges(
        b,
        ranges,
        corruptForTest: corrupt,
      ),
    );
  });

  static Future<ArchiveWrite> _mergeBlobsOffIsolate(
    Uint8List winner,
    int winnerCodec,
    Uint8List loser,
    int loserCodec,
    bool corrupt,
  ) => Isolate.run(() {
    final w =
        SubstrateArchiveCodec.decode(winner, codec: winnerCodec) ??
        (throw StateError('local archive bucket is unreadable'));
    return SubstrateArchiveCodec.encodeMergeVerify(
      w,
      existing: loser,
      existingCodec: loserCodec,
      corruptForTest: corrupt,
    );
  });

  static Map<String, Object?> _row(
    String deviceId,
    int day,
    ArchiveWrite w, {
    required int? tzOffsetMin,
    required int createdAt,
    required int updatedAt,
  }) => {
    'device_id': deviceId,
    'utc_day': day,
    'codec': SubstrateArchiveCodec.codecId,
    'from_ts': w.fromTs ?? day * 86400,
    'to_ts': w.toTs ?? day * 86400,
    'onehz_rows': w.onehzRows,
    'rr_rows': w.rrRows,
    'raw_bytes': w.rawBytes,
    'fingerprint': w.fingerprint,
    'tz_offset_min': tzOffsetMin,
    'blob': w.blob,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  /// Remove every archived second whose `rec_ts` lies in any of [windows]
  /// (half-open), for every device — "delete this day" has to delete the
  /// archived copy too. Runs on the caller's transaction.
  ///
  /// A bucket wholly inside one window is dropped without decoding. A bucket
  /// that can NEVER be decoded by this build (unknown codec, corrupt blob) but
  /// overlaps a window is dropped WHOLE. The trade-off is deliberate and it
  /// costs data: that bucket's seconds OUTSIDE the window — the rest of its
  /// UTC day for that device — go too. The user asked for the window's seconds
  /// to be gone, and a copy we can neither edit nor ever read again is the one
  /// outcome that cannot be allowed to keep them.
  ///
  /// Anything else that fails (the rewrite's read-back verification, I/O)
  /// THROWS, which rolls the caller's transaction back: retryable, and never
  /// widened into a bigger delete than was asked for.
  static Future<int> deleteRanges(
    Transaction txn,
    List<(int, int)> windows,
  ) async {
    if (windows.isEmpty) return 0;
    // Coalesce touching windows first. Buckets are UTC days and windows are
    // local days, so outside UTC no single day contains a bucket — but a run
    // of consecutive days does, and is dropped without a decode.
    final sorted = [...windows]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final w in sorted) {
      if (merged.isNotEmpty && w.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, math.max(last.$2, w.$2)));
      } else {
        merged.add(w);
      }
    }
    windows = merged;
    final byBucket = <(String, int), List<(int, int)>>{};
    final meta = <(String, int), Map<String, Object?>>{};
    for (final (start, end) in windows) {
      final hits = await txn.query(
        table,
        columns: ['device_id', 'utc_day', 'from_ts', 'to_ts'],
        where: 'utc_day >= ? AND utc_day <= ? AND to_ts >= ? AND from_ts < ?',
        whereArgs: [start ~/ 86400, (end - 1) ~/ 86400, start, end],
      );
      for (final h in hits) {
        final key = (h['device_id'] as String, (h['utc_day'] as num).toInt());
        (byBucket[key] ??= []).add((start, end));
        meta[key] = h;
      }
    }
    var changed = 0;
    for (final e in byBucket.entries) {
      final (deviceId, day) = e.key;
      final m = meta[e.key]!;
      final from = (m['from_ts'] as num).toInt();
      final to = (m['to_ts'] as num).toInt();
      const where = 'device_id = ? AND utc_day = ?';
      final args = [deviceId, day];
      if (e.value.any((w) => w.$1 <= from && to < w.$2)) {
        changed += await txn.delete(table, where: where, whereArgs: args);
        continue;
      }
      final row = (await txn.query(
        table,
        columns: ['codec', 'tz_offset_min', 'created_at'],
        where: where,
        whereArgs: args,
      )).first;
      final r = await _dropOffIsolate(
        (await readBlob(txn, deviceId, day))!,
        (row['codec'] as num).toInt(),
        e.value,
        debugCorruptEncode,
      );
      final w = r.write;
      if (r.unreadable || (w != null && w.isEmpty)) {
        changed += await txn.delete(table, where: where, whereArgs: args);
        continue;
      }
      if (w == null) continue;
      await txn.insert(
        table,
        _row(
          deviceId,
          day,
          w,
          tzOffsetMin: (row['tz_offset_min'] as num?)?.toInt(),
          createdAt: (row['created_at'] as num).toInt(),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      changed++;
    }
    return changed;
  }

  /// Copy the archived seconds whose `rec_ts` lies in any of [windows]
  /// (half-open) into [out]'s own `substrate_archive`, still compressed: each
  /// overlapping bucket is cut down to exactly those seconds
  /// ([SubstrateArchiveCodec.keepRanges]), re-encoded and verified. A per-day
  /// export of an old day therefore carries its substrate at archive size — a
  /// year is hundreds of MB, not the GBs of expanding it back into rows — and
  /// nothing outside the selected days leaves the phone. Importing it is the
  /// ordinary restore merge ([restoreRows]); the export's live rows, in its
  /// decoded tables, win over these on the importing device's next prune,
  /// exactly as they would have here.
  ///
  /// Each bucket's codec and blob are read inside ONE transaction on [src], so
  /// a prune merge or an eviction committing mid-read cannot hand back a torn
  /// blob. A bucket this build cannot read fails the export rather than leave
  /// a silent hole.
  static Future<int> copyArchiveInto(
    Database src,
    Database out,
    List<(int, int)> windows,
  ) async {
    final keys = <(String, int)>{};
    for (final (startSec, endSec) in windows) {
      for (final r in await src.query(
        table,
        columns: ['device_id', 'utc_day'],
        where: 'utc_day >= ? AND utc_day <= ? AND to_ts >= ? AND from_ts < ?',
        whereArgs: [startSec ~/ 86400, (endSec - 1) ~/ 86400, startSec, endSec],
      )) {
        keys.add((r['device_id'] as String, (r['utc_day'] as num).toInt()));
      }
    }
    var written = 0;
    for (final (deviceId, day) in keys) {
      final (meta, blob) = await src.transaction((txn) async {
        final m = await txn.query(
          table,
          columns: ['codec', 'tz_offset_min', 'created_at'],
          where: 'device_id = ? AND utc_day = ?',
          whereArgs: [deviceId, day],
        );
        return m.isEmpty
            ? (null, null)
            : (m.first, await readBlob(txn, deviceId, day));
      });
      if (meta == null) continue; // evicted since the overlap query
      final codec = (meta['codec'] as num).toInt();
      final w = blob == null
          ? null
          : await _keepOffIsolate(blob, codec, windows);
      if (w == null) {
        throw StateError(
          'substrate archive bucket $deviceId/$day cannot be read by this build',
        );
      }
      if (w.isEmpty) continue;
      await out.insert(
        table,
        _row(
          deviceId,
          day,
          w,
          tzOffsetMin: (meta['tz_offset_min'] as num?)?.toInt(),
          createdAt: (meta['created_at'] as num).toInt(),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      written++;
    }
    return written;
  }

  /// Merge restored `substrate_archive` rows into the local table on [txn].
  ///
  /// LOCAL WINS — the same "a restore never overwrites this device's own
  /// history" stance as finalized `day_result`. A key that is new here is
  /// inserted as is; one that exists is merged second-by-second with the
  /// local row winning, so a restore can only ADD seconds.
  ///
  /// A bucket this build cannot read — the backup's, or the local one it
  /// would merge into — is SKIPPED (counted in `skipped`, which the import
  /// report shows): it can be neither merged nor read, and letting it in
  /// would make every later export or delete that touches its day fail on it.
  /// A newer build can import it again. A bucket older than this database
  /// keeps ([dataEdgeSec] − keepDays) is left out and not counted: the next
  /// housekeeping would evict it anyway. Blobs are read from [src] in chunks
  /// ([readBlob]); [rows] carry only [metaColumns]. A known
  /// codec is decoded and its fingerprint checked BEFORE it is inserted, so a
  /// damaged blob never enters the table either. Every other failure THROWS —
  /// a user's restore must not report success over history it dropped —
  /// unless [tolerant] (the damaged-file salvage, which has no better file to
  /// fall back to), where the bucket is skipped and counted instead. Nothing
  /// is restored into a database whose policy is Off.
  static Future<({int copied, int skipped})> restoreRows(
    Transaction txn,
    DatabaseExecutor src,
    List<Map<String, Object?>> rows, {
    bool tolerant = false,
    int? dataEdgeSec,
  }) async {
    var copied = 0, skipped = 0;
    final policy = await readPolicy(txn);
    // Archiving is off here: an archive is exactly what this database was
    // told not to keep, restore or no restore.
    if (!policy.enabled) return (copied: 0, skipped: 0);
    // Older than this database keeps: housekeeping would evict it on the next
    // derive, so restoring (and reporting) it would be a promise not kept.
    final floorDay = dataEdgeSec != null && policy.keepDays > 0
        ? dataEdgeSec ~/ 86400 - policy.keepDays
        : null;
    for (final r in rows) {
      final deviceId = r['device_id'];
      final day = r['utc_day'];
      final codec = r['codec'];
      if (deviceId is! String || day is! int || codec is! int) {
        if (!tolerant) {
          throw FormatException(
            'malformed substrate_archive row $deviceId/$day',
          );
        }
        skipped++;
        continue;
      }
      if (floorDay != null && day < floorDay) continue;
      if (codec != SubstrateArchiveCodec.codecId) {
        skipped++;
        continue;
      }
      final blob = await readBlob(src, deviceId, day);
      final local = await txn.query(
        table,
        columns: ['codec', 'fingerprint'],
        where: 'device_id = ? AND utc_day = ?',
        whereArgs: [deviceId, day],
      );
      if (local.isEmpty) {
        final fp = r['fingerprint'];
        if (blob == null ||
            fp is! int ||
            !await _blobIntactOffIsolate(blob, codec, fp)) {
          if (!tolerant) {
            throw StateError(
              'substrate_archive bucket $deviceId/$day in the backup is damaged',
            );
          }
          skipped++;
          continue;
        }
        await txn.insert(table, {
          ...r,
          'blob': blob,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        copied++;
        continue;
      }
      final l = local.first;
      final localCodec = (l['codec'] as num).toInt();
      if (localCodec != SubstrateArchiveCodec.codecId) {
        skipped++;
        continue;
      }
      final ArchiveWrite w;
      try {
        w = await _mergeBlobsOffIsolate(
          (await readBlob(txn, deviceId, day))!,
          localCodec,
          blob ??
              (throw StateError('backup bucket $deviceId/$day has no blob')),
          codec,
          debugCorruptEncode,
        );
      } catch (_) {
        if (!tolerant) rethrow;
        skipped++;
        continue;
      }
      if (w.fingerprint == (l['fingerprint'] as num?)?.toInt()) continue;
      await txn.update(
        table,
        {
          'codec': SubstrateArchiveCodec.codecId,
          'from_ts': w.fromTs,
          'to_ts': w.toTs,
          'onehz_rows': w.onehzRows,
          'rr_rows': w.rrRows,
          'raw_bytes': w.rawBytes,
          'fingerprint': w.fingerprint,
          'blob': w.blob,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'device_id = ? AND utc_day = ?',
        whereArgs: [deviceId, day],
      );
      copied++;
    }
    return (copied: copied, skipped: skipped);
  }

  /// Drop every bucket older than [policy] allows, measured in whole UTC days
  /// behind [dataNowSec]. Off purges everything; forever keeps everything.
  static Future<int> evict(
    DatabaseExecutor ex,
    SubstrateArchivePolicy policy,
    int dataNowSec,
  ) {
    if (!policy.enabled) return ex.delete(table);
    if (policy.keepDays < 0) return Future.value(0);
    return ex.delete(
      table,
      where: 'utc_day < ?',
      whereArgs: [dataNowSec ~/ 86400 - policy.keepDays],
    );
  }

  /// `{buckets, bytes, raw_bytes, oldest_from_ts, newest_to_ts}`; the two
  /// timestamps are null on an empty archive.
  static Future<Map<String, Object?>> stats(DatabaseExecutor ex) async {
    final r = (await ex.rawQuery(
      'SELECT COUNT(*) AS buckets, '
      'COALESCE(SUM(LENGTH(blob)), 0) AS bytes, '
      'COALESCE(SUM(raw_bytes), 0) AS raw_bytes, '
      'MIN(from_ts) AS oldest_from_ts, MAX(to_ts) AS newest_to_ts '
      'FROM $table',
    )).first;
    return Map<String, Object?>.from(r);
  }
}
