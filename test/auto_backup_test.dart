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
          'openstrap-20260102-030405.db');
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
      final out = sortBackupsNewestFirst(tmp.listSync());
      expect(out.map((f) => p.basename(f.path)), [
        'openstrap-20260101-000000.db',
      ]);
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

    test('an occupied destination is never handed back', () async {
      // Returning the last candidate would give the next backup a real
      // snapshot to overwrite — the exact loss the unique naming prevents.
      final when = DateTime(2026, 8, 9, 14, 0, 0);
      final dir = await backupDirectory();
      final base = backupFileName(when);
      final stem = base.substring(0, base.length - 3);
      for (var i = 1; i < 100; i++) {
        File(p.join(dir.path, i == 1 ? base : '$stem-$i.db'))
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
        final f = File(p.join(dir.path, i == 1 ? base : '$stem-$i.db'));
        expect(f.readAsStringSync(), 'occupied');
      }
      for (var i = 1; i < 100; i++) {
        File(p.join(dir.path, i == 1 ? base : '$stem-$i.db')).deleteSync();
      }
    });
  });
}
