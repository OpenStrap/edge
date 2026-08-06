// P0 REGRESSION — a DERIVED (PPG) HR must never evict a MEASURED row, and
// must never take its RR beats down with it.
//
// `decoded_onehz` is INSERT-OR-REPLACE keyed on UNIQUE(rec_ts), and
// `_queueOrphanGuard` additionally DELETEs the evicted counter's `decoded_rr`
// beats. That "newest wins" rule is correct for two MEASURED records of the
// same second (the strap counter resets after a reboot), but a v26 PPG sample
// carries an INFERRED bpm and no beats at all — so letting it win trades a
// measured HR *and* a full second of beat-to-beat intervals for a guess.
// `decoded_rr` is the durable RR store; those beats are not recoverable.
//
// The engine guards this with an in-memory `_gen5MeasuredRecTs` set, but that
// set is per-connection: `_teardownSession` clears it and nothing ever seeds it
// from `decoded_onehz`. So the guard evaporates at exactly the moment it is
// needed — a reconnect, where the band re-delivers a burst for a second whose
// measured row is already on disk. These tests drive persistence directly with
// an EMPTY measured set, which is precisely the post-reconnect state.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Minimal gen5 v18 inner carrying a plausible unix + HR (gravity absent).
Uint8List _v18Inner({required int unix, required int counter}) {
  final inner = Uint8List(112);
  inner[0] = PacketType.historicalData;
  inner[1] = 18;
  inner.buffer.asByteData().setUint32(3, counter, Endian.little);
  inner.buffer.asByteData().setUint32(7, unix, Endian.little);
  return inner;
}

void main() {
  const recTs = 1785801600;
  const measuredCounter = 1000;
  const derivedCounter = 7; // a v26 burst index — small, and NOT the same row

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_derived_evict_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('decoded_onehz');
    await db.delete('decoded_rr');
  });

  /// Commit a measured v18 sample carrying RR beats for [recTs].
  Future<void> commitMeasured() async {
    final inner = _v18Inner(unix: recTs, counter: measuredCounter);
    await LocalDb.commitSyncBatch(
      [
        RawRecord(
          counter: measuredCounter,
          packetType: PacketType.historicalData,
          hex: _hex(inner),
          capturedAt: recTs * 1000,
          recTs: recTs,
        )
      ],
      [
        Sample(
          tsEpoch: recTs,
          counter: measuredCounter,
          hr: 61,
          rrIntervalsMs: const [980, 1005, 991],
        )
      ],
    );
  }

  /// Commit a PPG-DERIVED sample for the SAME second, as it arrives after a
  /// reconnect: no RR of its own, `derived: true`.
  Future<void> commitDerivedSameSecond() async {
    final inner = _v18Inner(unix: recTs, counter: derivedCounter);
    await LocalDb.commitSyncBatch(
      [
        RawRecord(
          counter: derivedCounter,
          packetType: PacketType.historicalData,
          hex: _hex(inner),
          capturedAt: recTs * 1000,
          recTs: recTs,
        )
      ],
      [
        Sample(
          tsEpoch: recTs,
          counter: derivedCounter,
          hr: 74, // a different, inferred value
          rrIntervalsMs: const [],
          derived: true,
        )
      ],
    );
  }

  test(
    'a derived PPG sample does NOT replace the measured row for that second',
    () async {
      await commitMeasured();
      await commitDerivedSameSecond();

      final db = await LocalDb.instance;
      final rows = await db.query('decoded_onehz',
          where: 'rec_ts = ?', whereArgs: [recTs]);

      expect(rows, hasLength(1));
      expect(
        rows.first['hr'],
        61,
        reason: 'the measured HR must stand, not the inferred 74',
      );
      expect(rows.first['counter'], measuredCounter);
    },
  );

  test(
    'and it does NOT take the measured row\'s decoded_rr beats with it',
    () async {
      await commitMeasured();
      final db = await LocalDb.instance;
      final before = await db.query('decoded_rr',
          where: 'counter = ?', whereArgs: [measuredCounter]);
      expect(before, hasLength(3), reason: 'sanity: beats were persisted');

      await commitDerivedSameSecond();

      final after = await db.query('decoded_rr',
          where: 'counter = ?', whereArgs: [measuredCounter]);
      expect(
        after,
        hasLength(3),
        reason: 'decoded_rr is the durable RR store — this loss is permanent',
      );
      expect(
        [for (final r in after) r['rr_ms']],
        containsAll([980, 1005, 991]),
      );
    },
  );

  test(
    'a derived sample still lands when the second is genuinely unclaimed',
    () async {
      await commitDerivedSameSecond();

      final db = await LocalDb.instance;
      final rows = await db.query('decoded_onehz',
          where: 'rec_ts = ?', whereArgs: [recTs]);
      expect(
        rows,
        hasLength(1),
        reason: 'the guard is about precedence, not about dropping PPG HR',
      );
      expect(rows.first['hr'], 74);
    },
  );

  test(
    'two MEASURED records for one second keep newest-wins (counter reset '
    'after a band reboot must still be recoverable)',
    () async {
      await commitMeasured();

      const rebootCounter = 3;
      final inner = _v18Inner(unix: recTs, counter: rebootCounter);
      await LocalDb.commitSyncBatch(
        [
          RawRecord(
            counter: rebootCounter,
            packetType: PacketType.historicalData,
            hex: _hex(inner),
            capturedAt: recTs * 1000,
            recTs: recTs,
          )
        ],
        [
          Sample(
            tsEpoch: recTs,
            counter: rebootCounter,
            hr: 88,
            rrIntervalsMs: const [700],
          )
        ],
      );

      final db = await LocalDb.instance;
      final rows = await db.query('decoded_onehz',
          where: 'rec_ts = ?', whereArgs: [recTs]);
      expect(rows, hasLength(1));
      expect(
        rows.first['hr'],
        88,
        reason: 'measured-vs-measured is unchanged by the derived guard',
      );
    },
  );
}
