// Firmware-resilience: undecodable historical records must be ARCHIVED durably
// (kept, except the thinning in `LocalDb.thinRawArchiveBefore`) in the SAME
// transaction as the decoded rows + trim cursor, so they are set aside BEFORE
// the caller writes the batch-ACK that lets the band trim its flash (safe-trim
// invariant). Runs the REAL LocalDb over an in-memory
// sqlite via sqflite_common_ffi.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_archive_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('commitSyncBatch co-commits archive + raw + trim cursor atomically', () async {
    final raw = RawRecord(
      counter: 1001,
      packetType: 0x2F,
      hex: '2f18aabbccdd',
      capturedAt: 1750000000000,
      recTs: 1750000000,
    );
    // Fully-decoded sample rides the batch (the durable substrate is the
    // decoded store; commitSyncBatch persists decoded rows, not raw hex).
    final sample = Sample(
      tsEpoch: 1750000000,
      counter: 1001,
      hr: 62,
      ax: 0.1,
      ay: 0.2,
      az: 0.9,
      spo2RedRaw: 100,
      spo2IrRaw: 200,
      skinTempRaw: 300,
    );
    final archive = ArchiveRecord(
      counter: 2002,
      hex: '2f63deadbeef', // an unknown record version
      packetType: 0x2F,
      capturedAt: 1750000000500,
      reason: 'undecodable_rec_v99',
    );

    await LocalDb.commitSyncBatch(
      [raw],
      <Sample?>[sample],
      trimToken: 'aabbccddeeff0011',
      archives: [archive],
    );

    // Archive landed (durable, keyed by counter with reason breakdown).
    final stats = await LocalDb.rawArchiveStats();
    expect(stats['count'], 1);
    expect((stats['by_reason'] as Map)['undecodable_rec_v99'], 1);

    // Decoded record landed in the SAME commit.
    final counts = await LocalDb.counts();
    expect((counts['decoded_onehz'] ?? 0) >= 1, isTrue);

    // Trim cursor advanced in the SAME commit (what the ACK echoes verbatim).
    expect(await LocalDb.getCursor('strap_trim'), 'aabbccddeeff0011');
    expect(await LocalDb.getCursorInt('counter_hw'), 1001);
  });

  test('identical re-flood dedups on frame hex (missed-ACK redelivery)', () async {
    final archive = ArchiveRecord(
      counter: 2002, // same counter AND same bytes as above
      hex: '2f63deadbeef',
      packetType: 0x2F,
      capturedAt: 1750000099999,
      reason: 'undecodable_rec_v99',
    );
    await LocalDb.commitSyncBatch(
      const <RawRecord>[],
      const <Sample?>[],
      trimToken: 'aabbccddeeff0022',
      archives: [archive],
    );
    // Still one archived row — same bytes, so the redelivery deduped.
    final stats = await LocalDb.rawArchiveStats();
    expect(stats['count'], 1);
    // …but the trim cursor still advanced (this chunk was ACK-safe).
    expect(await LocalDb.getCursor('strap_trim'), 'aabbccddeeff0022');
  });

  test('archiveRawRecord fallback path also persists', () async {
    await LocalDb.archiveRawRecord(ArchiveRecord(
      counter: 3003,
      hex: '2f70cafebabe',
      packetType: 0x2F,
      capturedAt: 1750000100000,
      reason: 'undecodable_rec_v112',
    ));
    final stats = await LocalDb.rawArchiveStats();
    expect(stats['count'], 2);
    expect((stats['by_reason'] as Map)['undecodable_rec_v112'], 1);
  });

  test('two DISTINCT frames sharing a reused counter BOTH survive', () async {
    // The strap resets its record counter to ~0 on reboot, so a post-reboot
    // frame can reuse a pre-reboot counter while carrying different bytes.
    // Under the old `counter INTEGER PRIMARY KEY` + IGNORE, the second frame
    // was silently DROPPED — permanent loss in the table that exists precisely
    // to never lose a frame. Content-keyed, both must survive.
    final before = (await LocalDb.rawArchiveStats())['count'] as int;
    const reusedCounter = 4004;
    await LocalDb.archiveRawRecord(ArchiveRecord(
      counter: reusedCounter,
      hex: '2f63aaaaaaaa', // pre-reboot frame
      packetType: 0x2F,
      capturedAt: 1750000200000,
      reason: 'undecodable_pre_reboot',
    ));
    await LocalDb.archiveRawRecord(ArchiveRecord(
      counter: reusedCounter, // SAME counter, DIFFERENT bytes
      hex: '2f63bbbbbbbb', // post-reboot frame
      packetType: 0x2F,
      capturedAt: 1750000300000,
      reason: 'undecodable_post_reboot',
    ));
    final after = (await LocalDb.rawArchiveStats())['count'] as int;
    // Pre-fix: +1 (second dropped by counter-PK IGNORE). Post-fix: +2.
    expect(after - before, 2);
  });

  // ── GATES 4b — the re-drive ────────────────────────────────────────────────
  //
  // Four REAL gen5 v18 inner frames lifted from the MG export's own
  // `raw_archive` — two under each of the two stale reasons. They were archived
  // by a build whose gravity gate was gen4's (a 0.5-1.8 g window on a NORMALISED
  // vector, applied to gen5's raw per-axis means); all four decode today. Real
  // bytes on purpose: a synthetic frame would prove the plumbing and nothing
  // about the claim, which is that the ARCHIVE is stale, not the data.
  const v18Undecodable = [
    '2f128000394801a6e5776a0040008300000000000000000000616d0d85830000'
        'fff678893fcd5b1ac07b9466bd8fb2b23e0d8eb20000000000000000001e0131'
        '01570c500b010c020c0100000000000000000000000000000000000000000000'
        '010053748080000000fcaf98c0000000',
    '2f128001394801a7e5776a004000830000000000000000000061540985830000'
        'd5220951401416dbbf52e08a3ef620ae3e0d8eb20000000000000000001e0131'
        '01570c500b010c020c0100000000000000000000000000000000000000000000'
        '0100537480800000000c6890c0000000',
  ];
  const v18Partial = [
    '2f128000f54c0112b47c6a8f2200620000000000000000000061e70d84620000'
        'c51869b23feca5c0bf7b74123ea4c0053ee71061000000000000000000490154'
        '01900d6009010c020c0100000000000000000000000000000000000000000000'
        '01005b80808000000009c0b7bf000000',
    '2f128000f94c0112b87c6a1e25005f0000000000000000000061f905825f0000'
        'f2f430d43e713d96bdcd24ac3e7b74a83edf1174000000000000000000460151'
        '016b0d6009010c020c0100000000000000000000000000000000000000000000'
        '01004792808000000058c386c0000000',
  ];

  test('re-drive replays stale-reason archive rows into decoded_onehz',
      () async {
    // Both stale labels, plus a row this build still cannot read. The
    // unreadable one must survive untouched — that is what the archive is for.
    var counter = 21510400;
    for (final hex in [...v18Undecodable, ...v18Partial]) {
      await LocalDb.archiveRawRecord(ArchiveRecord(
        counter: counter++,
        hex: hex,
        packetType: 0x2F,
        capturedAt: 1786242475895,
        reason: v18Undecodable.contains(hex)
            ? 'undecodable_rec_v18'
            : 'partial_decode_v18_no_gravity',
      ));
    }
    await LocalDb.archiveRawRecord(ArchiveRecord(
      counter: counter++,
      hex: '2f14deadbeefdeadbeef', // a version nothing decodes
      packetType: 0x2F,
      capturedAt: 1786242475995,
      reason: 'undecodable_rec_v20',
    ));

    final db = await LocalDb.instance;
    expect(await LocalDb.redriveArchivedRecords(db), 4);

    // The seconds they carry, decoded — and the field GATES measured, which is
    // the reason recovering them is worth anything at all.
    final rows = await db.rawQuery(
      'SELECT rec_ts, hr, skin_temp_c, device_family FROM decoded_onehz '
      'WHERE rec_ts IN (?, ?, ?, ?) ORDER BY rec_ts',
      const [1786242470, 1786242471, 1786557458, 1786558482],
    );
    expect(rows.length, 4);
    for (final r in rows) {
      expect(r['skin_temp_c'], isNotNull, reason: 'gen5 °C must survive');
      // A replay has no live link to ask which strap measured it, and v18
      // exists on both generations — NULL, never gen4 by default.
      expect(r['device_family'], isNull);
    }

    // The bytes are never consumed: raw_archive keeps every row, unrelabelled.
    final stats = await LocalDb.rawArchiveStats();
    expect((stats['by_reason'] as Map)['undecodable_rec_v18'], 2);
    expect((stats['by_reason'] as Map)['partial_decode_v18_no_gravity'], 2);
    expect((stats['by_reason'] as Map)['undecodable_rec_v20'], 1);
  });

  test('re-drive is idempotent and never evicts a second that decoded',
      () async {
    final db = await LocalDb.instance;
    // Every second is already present from the run above, so a second pass
    // recovers nothing — this is what makes the migration rung safe to be the
    // only guard.
    expect(await LocalDb.redriveArchivedRecords(db), 0);

    // And the standing row wins on collision: mark one, replay, check it is
    // still ours. `_queueDecodedOneHz` writes REPLACE, so without the skip a
    // frame that FAILED to decode would evict one that succeeded.
    await db.rawUpdate(
      'UPDATE decoded_onehz SET hr = 199 WHERE rec_ts = ?',
      const [1786242470],
    );
    expect(await LocalDb.redriveArchivedRecords(db), 0);
    final row = (await db.rawQuery(
      'SELECT hr FROM decoded_onehz WHERE rec_ts = ?',
      const [1786242470],
    )).first;
    expect(row['hr'], 199);
  });

  // The REAL exports, through the REAL ladder — the same harness shape as
  // `device_family_migration_test.dart`. Skipped when the env var is unset;
  // those files are not in the repo.
  //
  // MEASURED, 2026-08-17:
  //   whoop-mg.db  1,035 archived v18 → 867 recovered (168 of those seconds
  //                already had a decoded row and were correctly left alone),
  //                115,672 v20 + 25,804 v26 untouched, second pass 0.
  //   whoop-5.db   3 archived v18 → 3 recovered.
  //   whoop-4.db   0 — its 28,395 archived frames are v25 PPG bursts, which
  //                are identified, not undecodable, and are not seconds.
  final real = (Platform.environment['OPENSTRAP_TEST_DBS'] ?? '')
      .split(',')
      .where((s) => s.trim().isNotEmpty);
  for (final src in real) {
    test('re-drive over the real ${p.basename(src)}', () async {
      final keep = LocalDb.dbName;
      final name = 'redrive_${p.basenameWithoutExtension(src)}.db';
      final dir = await databaseFactory.getDatabasesPath();
      await LocalDb.close();
      LocalDb.dbName = name;
      await databaseFactory.deleteDatabase(p.join(dir, name));
      await File(src).copy(p.join(dir, name));
      try {
        // Opening runs the whole ladder, v44 included.
        final db = await LocalDb.instance;
        final archived = (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM raw_archive WHERE reason IN '
          '(${List.filled(LocalDb.redrivableArchiveReasons.length, '?').join(',')})',
          LocalDb.redrivableArchiveReasons,
        )).first['n'];
        // ignore: avoid_print
        print('[redrive] ${p.basename(src)} redrivable=$archived');
        // The bytes are never consumed by a re-drive.
        expect(archived, isNotNull);
        // Idempotent: the rung already ran on open.
        expect(await LocalDb.redriveArchivedRecords(db), 0);
      } finally {
        await LocalDb.close();
        await databaseFactory.deleteDatabase(p.join(dir, name));
        LocalDb.dbName = keep;
      }
    }, timeout: const Timeout(Duration(minutes: 20)));
  }
}
