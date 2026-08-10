// Automatic backup scheduling and retention.
//
// The scheduling half is pure and is where the interesting cases live: never
// backed up, clock moved backwards, and the boundary. The retention half has
// to keep the NEWEST files, which means the filename ordering has to be right
// — getting it backwards would delete exactly the backups worth having.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A real backup writes a real file, so the serialization tests need somewhere
/// to write and a database to snapshot.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getLibraryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
  @override
  Future<String?> getExternalStoragePath() async => root;
}

void main() {
  group('backupIsDue', () {
    final now = DateTime(2026, 8, 9, 12);

    test('off is never due', () {
      expect(
        backupIsDue(cadence: BackupCadence.off, lastRun: null, now: now),
        isFalse,
      );
      expect(
        backupIsDue(
          cadence: BackupCadence.off,
          lastRun: DateTime(2020),
          now: now,
        ),
        isFalse,
      );
    });

    test('never backed up is always due', () {
      // Otherwise switching the setting on does nothing visible until
      // tomorrow, and the user reasonably concludes it is broken.
      for (final c in [BackupCadence.daily, BackupCadence.weekly]) {
        expect(backupIsDue(cadence: c, lastRun: null, now: now), isTrue);
      }
    });

    test('daily waits a day, and the boundary counts', () {
      expect(
        backupIsDue(
          cadence: BackupCadence.daily,
          lastRun: now.subtract(const Duration(hours: 23, minutes: 59)),
          now: now,
        ),
        isFalse,
      );
      expect(
        backupIsDue(
          cadence: BackupCadence.daily,
          lastRun: now.subtract(const Duration(days: 1)),
          now: now,
        ),
        isTrue,
      );
    });

    test('weekly waits a week', () {
      expect(
        backupIsDue(
          cadence: BackupCadence.weekly,
          lastRun: now.subtract(const Duration(days: 6)),
          now: now,
        ),
        isFalse,
      );
      expect(
        backupIsDue(
          cadence: BackupCadence.weekly,
          lastRun: now.subtract(const Duration(days: 7)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a last run in the future is due, not parked forever', () {
      // Reachable from a timezone change, an NTP correction, or a user setting
      // the date forward and back. Without this the schedule silently stops.
      expect(
        backupIsDue(
          cadence: BackupCadence.daily,
          lastRun: now.add(const Duration(days: 30)),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('BackupCadence', () {
    test('an unknown stored name falls back to off, not to backing up', () {
      // A pref written by a newer build must not silently start writing
      // unencrypted copies of everything on an older one.
      expect(BackupCadence.fromName('fortnightly'), BackupCadence.off);
      expect(BackupCadence.fromName(null), BackupCadence.off);
      expect(BackupCadence.fromName(''), BackupCadence.off);
      expect(BackupCadence.fromName('weekly'), BackupCadence.weekly);
    });

    test('off has no interval', () {
      expect(BackupCadence.off.interval, isNull);
      expect(BackupCadence.daily.interval, const Duration(days: 1));
    });
  });

  group('backupFileName', () {
    test('sorts chronologically as plain text', () {
      // Retention orders by name, so this has to hold without parsing.
      final names = [
        backupFileName(DateTime(2026, 8, 9, 9, 5)),
        backupFileName(DateTime(2026, 12, 1, 23, 59)),
        backupFileName(DateTime(2026, 8, 9, 10, 0)),
        backupFileName(DateTime(2025, 1, 1, 0, 0)),
      ]..sort();
      expect(names.first, contains('20250101'));
      expect(names.last, contains('20261201'));
      expect(names[1], contains('20260809-0905'));
      expect(names[2], contains('20260809-1000'));
    });

    test('is zero-padded so widths match', () {
      expect(backupFileName(DateTime(2026, 1, 2, 3, 4, 5)),
          'openstrap-20260102-030405.db.gz');
    });

    test('two runs in the same minute get different names', () {
      // Same-minute collisions would silently overwrite the earlier backup.
      expect(
        backupFileName(DateTime(2026, 1, 2, 3, 4, 5)),
        isNot(backupFileName(DateTime(2026, 1, 2, 3, 4, 6))),
      );
    });
  });

  group('sortBackupsNewestFirst', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('openstrap_backup_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    File touch(String name) =>
        File(p.join(tmp.path, name))..writeAsStringSync('x');

    test('orders newest first', () {
      touch('openstrap-20260101-000000.db');
      touch('openstrap-20260301-000000.db');
      touch('openstrap-20260201-000000.db');
      final out = sortBackupsNewestFirst(tmp.listSync());
      expect(
        out.map((f) => p.basename(f.path)),
        [
          'openstrap-20260301-000000.db',
          'openstrap-20260201-000000.db',
          'openstrap-20260101-000000.db',
        ],
      );
    });

    test('matches only the exact shape it emits', () {
      // This list is what retention DELETES, in a folder the user can drop
      // files into. A loose openstrap-*.db glob would eat their notes.
      touch(backupFileName(DateTime(2026, 1, 1, 0, 0, 0)));
      touch('holiday-photos.zip');
      touch('openstrap-notes.txt');
      touch('openstrap-notes.db');
      touch('openstrap-2026.db');
      touch('openstrap-20260101.db');
      touch('random.db');
      touch('openstrap-20260101-000000.db.gz.bak');
      final out = sortBackupsNewestFirst(tmp.listSync());
      expect(out.map((f) => p.basename(f.path)), [
        'openstrap-20260101-000000.db.gz',
      ]);
    });

    test('still matches the UNCOMPRESSED names earlier versions wrote', () {
      // An install that upgrades still holds up to kBackupsKept plain `.db`
      // backups. If the pattern stopped matching them they would never be
      // counted toward retention and never pruned — five full-size copies
      // leaked permanently, which is the opposite of the point.
      touch('openstrap-20260101-000000.db');
      touch('openstrap-20260102-000000.db.gz');
      final out = sortBackupsNewestFirst(tmp.listSync());
      expect(out.map((f) => p.basename(f.path)), [
        'openstrap-20260102-000000.db.gz',
        'openstrap-20260101-000000.db',
      ]);
    });

    test('matches the -N collision names _uniqueDestination emits', () {
      // These leaked for the same reason: two runs inside one second produce a
      // `-2` suffix that the pattern never covered, so the file was invisible
      // to retention forever.
      touch('openstrap-20260101-000000.db.gz');
      touch('openstrap-20260101-000000-2.db.gz');
      touch('openstrap-20260101-000000-3.db');
      expect(sortBackupsNewestFirst(tmp.listSync()).length, 3);
    });

    test('a collision suffix ranks NEWER, not older', () {
      // Sorting the raw basename got this backwards: `-` (0x2D) sorts before
      // `.` (0x2E), so `-2` compared LESS than the unsuffixed name and the
      // second backup of that second was ranked the older of the pair — the
      // one retention evicts first. A higher index is always the later write.
      touch('openstrap-20260101-000000.db.gz');
      touch('openstrap-20260101-000000-2.db.gz');
      touch('openstrap-20260101-000000-10.db.gz');
      expect(
        sortBackupsNewestFirst(tmp.listSync()).map((f) => p.basename(f.path)),
        [
          'openstrap-20260101-000000-10.db.gz',
          'openstrap-20260101-000000-2.db.gz',
          'openstrap-20260101-000000.db.gz',
        ],
      );
    });

    test('an empty directory is empty, not an error', () {
      expect(sortBackupsNewestFirst(tmp.listSync()), isEmpty);
    });
  });

  group('pruneBackups', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('openstrap_prune_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('keeps the newest and deletes the rest', () async {
      for (final d in ['0101', '0201', '0301', '0401', '0501']) {
        File(p.join(tmp.path, 'openstrap-2026$d-000000.db'))
            .writeAsStringSync('x');
      }
      await pruneBackups(tmp, keep: 2);
      expect(
        sortBackupsNewestFirst(tmp.listSync()).map((f) => p.basename(f.path)),
        ['openstrap-20260501-000000.db', 'openstrap-20260401-000000.db'],
      );
    });

    test('never touches a file that is not a backup', () async {
      File(p.join(tmp.path, 'openstrap-20260101-000000.db'))
          .writeAsStringSync('x');
      final other = File(p.join(tmp.path, 'important.txt'))
        ..writeAsStringSync('x');
      // Deliberately close to ours: this is the one retention would have
      // deleted under a prefix match.
      final lookalike = File(p.join(tmp.path, 'openstrap-notes.db'))
        ..writeAsStringSync('x');
      await pruneBackups(tmp, keep: 0);
      expect(other.existsSync(), isTrue);
      expect(lookalike.existsSync(), isTrue);
      expect(sortBackupsNewestFirst(tmp.listSync()), isEmpty);
    });

    test('fewer backups than the limit is a no-op', () async {
      File(p.join(tmp.path, 'openstrap-20260101-000000.db'))
          .writeAsStringSync('x');
      await pruneBackups(tmp, keep: 5);
      expect(sortBackupsNewestFirst(tmp.listSync()), hasLength(1));
    });
  });

  group('runBackupIfDue', () {
    late Directory tmp;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      tmp = await Directory.systemTemp.createTemp('openstrap_backup_run_');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      LocalDb.dbName = 'openstrap_backup_run_test.db';
      await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
      );
      await LocalDb.instance;
    });

    tearDownAll(() async {
      await LocalDb.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('skips rather than failing when nothing is due', () async {
      var marked = 0;
      final outcome = await runBackupIfDue(
        cadence: () => BackupCadence.daily,
        lastRun: () => DateTime(2026, 8, 9, 11),
        markRun: (_) async => marked++,
        now: DateTime(2026, 8, 9, 12),
      );
      expect(outcome.skipped, isTrue);
      expect(outcome.succeeded, isFalse);
      expect(outcome.error, isNull, reason: 'not due is not a failure');
      expect(marked, 0, reason: 'a skip is not a run');
    });

    test('reads the timestamp inside the lock, not before queueing', () async {
      // THE RACE this serialization exists to close. Two triggers arrive
      // together; the first backs up and records it. The second must see that
      // record when its turn comes, rather than the value it would have read
      // at call time — which is what a plain `lastRun` VALUE parameter gave it,
      // and what produced a duplicate export.
      DateTime? last;
      final reads = <DateTime?>[];
      final now = DateTime(2026, 8, 9, 12);

      Future<BackupOutcome> trigger() => runBackupIfDue(
        cadence: () => BackupCadence.daily,
        lastRun: () {
          reads.add(last);
          return last;
        },
        markRun: (when) async => last = when,
        now: now,
      );

      // Fired without awaiting the first, exactly as two resume events would.
      final results = await Future.wait([trigger(), trigger()]);

      expect(reads, hasLength(2));
      expect(
        reads.last,
        isNotNull,
        reason: 'the second read must see the first run, not a stale null',
      );
      expect(
        results.where((r) => r.skipped),
        hasLength(1),
        reason: 'exactly one of the two should have decided it was due',
      );
    });

    test('two runs in the same second get two files, not one overwritten',
        () async {
      // Seconds make a collision rare, not impossible. Two manual taps inside
      // one second would otherwise share a destination and the first snapshot
      // would be silently replaced by the second.
      final when = DateTime(2026, 8, 9, 12, 30, 15);
      final first = await runBackup(now: when);
      final second = await runBackup(now: when);

      expect(first.succeeded, isTrue, reason: '${first.error}');
      expect(second.succeeded, isTrue, reason: '${second.error}');
      expect(first.path, isNot(second.path));
      expect(File(first.path!).existsSync(), isTrue);
      expect(File(second.path!).existsSync(), isTrue);
    });

    test('a cadence switched off while queued does not still write', () async {
      // The privacy-shaped half of the same race. Someone turns backup off
      // while one is running; the queued call must see OFF, not the setting as
      // it was when it queued, or it writes an unencrypted copy of everything
      // after they disabled it.
      var cadence = BackupCadence.daily;
      var wrote = 0;

      final running = runBackup(
        exportSnapshot: () async {
          // Flip the setting while the first export is in flight.
          cadence = BackupCadence.off;
          return LocalDb.exportCopy();
        },
      );
      final queued = runBackupIfDue(
        cadence: () => cadence,
        lastRun: () => null,
        markRun: (_) async => wrote++,
      );

      await running;
      final outcome = await queued;
      expect(outcome.skipped, isTrue, reason: 'it must see the new setting');
      expect(wrote, 0);
    });

    test('a failed backup does not wedge every later one', () async {
      // The queue is chained; without an error guard on the tail, a single
      // throw would leave every subsequent call waiting on a failed future.
      final failed = await runBackup(
        exportSnapshot: () async => throw const FileSystemException('nope'),
      );
      expect(failed.succeeded, isFalse);
      expect(failed.error, isNotNull);

      final after = await runBackup(now: DateTime(2026, 8, 9, 13, 0, 0));
      expect(
        after.succeeded,
        isTrue,
        reason: 'the queue must survive the failure before it: ${after.error}',
      );
    });

    test('a backup is gzip on disk and inflates back to the database', () async {
      // The whole point of the extension change. A backup that is smaller but
      // cannot be read back is not a backup, so this asserts BOTH: the file is
      // really gzip, and what comes out of it is really the snapshot.
      final outcome = await runBackup(now: DateTime(2026, 8, 9, 15, 0, 0));
      expect(outcome.succeeded, isTrue, reason: outcome.error);

      final file = File(outcome.path!);
      expect(p.basename(file.path), endsWith('.db.gz'));

      final bytes = await file.readAsBytes();
      expect(bytes.length, greaterThan(2));
      expect(bytes[0], 0x1F, reason: 'gzip magic byte 0');
      expect(bytes[1], 0x8B, reason: 'gzip magic byte 1');

      final inflated = gzip.decode(bytes);
      expect(
        String.fromCharCodes(inflated.take(15)),
        'SQLite format 3',
        reason: 'the inflated backup must be an openable database',
      );
      expect(
        inflated.length,
        greaterThan(bytes.length),
        reason: 'a compressed backup must be smaller than the database',
      );
    });

    test('the final backup name never exists as a partial file', () async {
      // Compressing straight into `dest` published the final name while the
      // file was still being written. Kill the process mid-stream and a
      // truncated file carries a name retention matches, so it counts as one of
      // the five and evicts a good backup. `catch` cannot save that — the
      // process is gone. So: stage under a name retention does NOT match, and
      // publish by rename.
      //
      // Asserted through a failing export, which is the only mid-write failure
      // reachable from a test: no final-named file may be left behind, and
      // nothing invisible may accumulate either.
      final dir = await backupDirectory();
      final before = dir.listSync().length;

      final outcome = await runBackup(
        now: DateTime(2026, 8, 9, 17, 0, 0),
        exportSnapshot: () async => throw const FileSystemException('boom'),
      );
      expect(outcome.succeeded, isFalse);

      final names = dir.listSync().map((f) => p.basename(f.path)).toList();
      expect(
        names.where((n) => n.contains('20260809-170000')),
        isEmpty,
        reason: 'a failed backup must leave neither a final nor a staging file',
      );
      expect(dir.listSync().length, before);
    });

    test('a failure AFTER the staging file exists still removes it', () async {
      // The test above throws before the sink is ever opened, so it proves
      // nothing about the cleanup that matters: the case worth covering is a
      // staging file that has already been created and then has to be reclaimed
      // when the write fails. Reached here by handing back a snapshot path that
      // cannot be read as a file, so the failure lands inside the write rather
      // than in front of it.
      final dir = await backupDirectory();
      final when = DateTime(2026, 8, 9, 19, 0, 0);
      final dest = File(p.join(dir.path, backupFileName(when)));
      final staging = File('${dest.path}$kBackupStagingSuffix');
      staging.writeAsStringSync('a previous attempt got this far');

      final unreadable = Directory(p.join(tmp.path, 'not-a-snapshot'))
        ..createSync();
      final outcome = await runBackup(
        now: when,
        exportSnapshot: () async => unreadable.path,
      );

      expect(outcome.succeeded, isFalse);
      expect(dest.existsSync(), isFalse, reason: 'no final name may be published');
      expect(
        staging.existsSync(),
        isFalse,
        reason: 'a staging file that was created must be deleted on failure',
      );
      unreadable.deleteSync();
    });

    test('staging files are invisible to retention', () async {
      // The suffix only protects a good backup if retention genuinely cannot
      // see it — otherwise a partial would still be counted and still evict.
      final dir = await backupDirectory();
      File(
        p.join(dir.path, 'openstrap-20260809-180000.db.gz$kBackupStagingSuffix'),
      ).writeAsStringSync('half a backup');
      try {
        final seen = sortBackupsNewestFirst(dir.listSync())
            .map((f) => p.basename(f.path));
        expect(seen.where((n) => n.contains('180000')), isEmpty);
      } finally {
        await pruneStagingFiles(dir);
      }
      expect(
        dir.listSync().where((f) => f.path.endsWith(kBackupStagingSuffix)),
        isEmpty,
        reason: 'pruneStagingFiles must reclaim what retention cannot see',
      );
    });

    test('a .partial that is not ours is left alone', () async {
      // This folder is app-specific external storage on Android and the
      // file-sharing Documents directory on iOS — chosen precisely so sync
      // clients can point at it, and `.partial` is what a half-finished
      // Nextcloud or iCloud download is called. Deleting on the suffix alone
      // reached outside this feature's own files.
      final dir = await backupDirectory();
      final foreign = File(p.join(dir.path, 'holiday-video.mp4.partial'))
        ..writeAsStringSync('someone else is downloading this');
      final lookalike = File(p.join(dir.path, 'openstrap-notes.db.partial'))
        ..writeAsStringSync('not ours either');
      final ours = File(
        p.join(dir.path, 'openstrap-20260809-181500.db.gz$kBackupStagingSuffix'),
      )..writeAsStringSync('half a backup');

      await pruneStagingFiles(dir);

      expect(ours.existsSync(), isFalse);
      expect(foreign.existsSync(), isTrue);
      expect(lookalike.existsSync(), isTrue);
      foreign.deleteSync();
      lookalike.deleteSync();
    });

    test('a backup this code writes can actually be restored', () async {
      // THE boundary this feature turns on, and nothing crossed it. The write
      // side gzips; the restore side handed the picked path straight to
      // openDatabase, so every backup written here came back as "file is not a
      // database" — a user who lost their phone, reinstalled, and picked their
      // own backup got nothing.
      final db = await LocalDb.instance;
      const dayId = '2026-08-09';
      const payload = '{"scalars":{"rhr":52.0}}';
      await db.insert('day_result', {
        'day_id': dayId,
        'algo_version': 61,
        'payload_json': payload,
        'window_json': '{}',
        'computed_at': 1,
        'finalized': 0,
        'skipped': 0,
        'partial': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final outcome = await runBackup(now: DateTime(2026, 8, 9, 20, 0, 0));
      expect(outcome.succeeded, isTrue, reason: outcome.error);
      expect(outcome.path, endsWith('.db.gz'));
      // Out of the retention folder, so a later backup in this group cannot
      // evict the file under the assertion.
      final picked = File(p.join(tmp.path, 'picked-backup.db.gz'));
      await File(outcome.path!).copy(picked.path);

      await db.delete('day_result', where: 'day_id = ?', whereArgs: [dayId]);
      expect(
        await db.query('day_result', where: 'day_id = ?', whereArgs: [dayId]),
        isEmpty,
      );

      final counts = await LocalDb.importFromDbFile(picked.path);
      expect(counts['day_result'], greaterThanOrEqualTo(1));
      final restored = await db.query(
        'day_result',
        where: 'day_id = ?',
        whereArgs: [dayId],
      );
      expect(restored, hasLength(1));
      expect(restored.first['payload_json'], payload);
      await picked.delete();
      await db.delete('day_result', where: 'day_id = ?', whereArgs: [dayId]);
    });

    test('a plain uncompressed .db still restores', () async {
      // Older backups and exportCopy output are not compressed. Sniffing by
      // magic bytes rather than by extension has to leave that path alone.
      final db = await LocalDb.instance;
      const dayId = '2026-08-10';
      await db.insert('day_result', {
        'day_id': dayId,
        'algo_version': 61,
        'payload_json': '{"scalars":{"rhr":48.0}}',
        'window_json': '{}',
        'computed_at': 1,
        'finalized': 0,
        'skipped': 0,
        'partial': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final snapshot = await LocalDb.exportCopy();
      await db.delete('day_result', where: 'day_id = ?', whereArgs: [dayId]);

      await LocalDb.importFromDbFile(snapshot);
      expect(
        await db.query('day_result', where: 'day_id = ?', whereArgs: [dayId]),
        hasLength(1),
      );
      await File(snapshot).delete();
      await db.delete('day_result', where: 'day_id = ?', whereArgs: [dayId]);
    });

    test('a snapshot is never left behind in temp', () async {
      // The export is a full second copy of the database. The old code renamed
      // it into place; the new one streams and must still delete the source.
      final outcome = await runBackup(now: DateTime(2026, 8, 9, 16, 0, 0));
      expect(outcome.succeeded, isTrue, reason: outcome.error);
      final leftovers = tmp
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.startsWith('openstrap_export_'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('an occupied destination is never handed back', () async {
      // Returning the last candidate would give the next backup a real
      // snapshot to overwrite — the exact loss the unique naming prevents.
      final when = DateTime(2026, 8, 9, 14, 0, 0);
      final dir = await backupDirectory();
      final base = backupFileName(when);
      final stem = base.substring(0, base.length - kBackupExtension.length);
      for (var i = 1; i < 100; i++) {
        File(p.join(dir.path, i == 1 ? base : '$stem-$i$kBackupExtension'))
            .writeAsStringSync('occupied');
      }

      var exported = 0;
      final outcome = await runBackup(
        now: when,
        exportSnapshot: () async {
          exported++;
          return LocalDb.exportCopy();
        },
      );
      expect(outcome.succeeded, isFalse);
      expect(outcome.error, isNotNull);
      // The destination is chosen BEFORE the export. Exporting first left a
      // full copy of the database in temp on every failed attempt.
      expect(exported, 0, reason: 'nothing should have been exported');
      // Every pre-existing file is untouched.
      for (var i = 1; i < 100; i++) {
        final f = File(p.join(dir.path, i == 1 ? base : '$stem-$i$kBackupExtension'));
        expect(f.readAsStringSync(), 'occupied');
      }
      for (var i = 1; i < 100; i++) {
        File(p.join(dir.path, i == 1 ? base : '$stem-$i$kBackupExtension')).deleteSync();
      }
    });
  });
}
