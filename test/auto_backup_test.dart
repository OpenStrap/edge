// Automatic backup scheduling and retention.
//
// The scheduling half is pure and is where the interesting cases live: never
// backed up, clock moved backwards, and the boundary. The retention half has
// to keep the NEWEST files, which means the filename ordering has to be right
// — getting it backwards would delete exactly the backups worth having.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:path/path.dart' as p;

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
      expect(backupFileName(DateTime(2026, 1, 2, 3, 4)),
          'openstrap-20260102-0304.db');
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
      touch('openstrap-20260101-0000.db');
      touch('openstrap-20260301-0000.db');
      touch('openstrap-20260201-0000.db');
      final out = sortBackupsNewestFirst(tmp.listSync());
      expect(
        out.map((f) => p.basename(f.path)),
        [
          'openstrap-20260301-0000.db',
          'openstrap-20260201-0000.db',
          'openstrap-20260101-0000.db',
        ],
      );
    });

    test('ignores anything that is not one of ours', () {
      // The documents directory is shared with whatever the user drops in it.
      touch('openstrap-20260101-0000.db');
      touch('holiday-photos.zip');
      touch('openstrap-notes.txt');
      touch('random.db');
      final out = sortBackupsNewestFirst(tmp.listSync());
      expect(out.map((f) => p.basename(f.path)), [
        'openstrap-20260101-0000.db',
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
        File(p.join(tmp.path, 'openstrap-2026$d-0000.db'))
            .writeAsStringSync('x');
      }
      await pruneBackups(tmp, keep: 2);
      expect(
        sortBackupsNewestFirst(tmp.listSync()).map((f) => p.basename(f.path)),
        ['openstrap-20260501-0000.db', 'openstrap-20260401-0000.db'],
      );
    });

    test('never touches a file that is not a backup', () async {
      File(p.join(tmp.path, 'openstrap-20260101-0000.db'))
          .writeAsStringSync('x');
      final other = File(p.join(tmp.path, 'important.txt'))
        ..writeAsStringSync('x');
      await pruneBackups(tmp, keep: 0);
      expect(other.existsSync(), isTrue);
      expect(sortBackupsNewestFirst(tmp.listSync()), isEmpty);
    });

    test('fewer backups than the limit is a no-op', () async {
      File(p.join(tmp.path, 'openstrap-20260101-0000.db'))
          .writeAsStringSync('x');
      await pruneBackups(tmp, keep: 5);
      expect(sortBackupsNewestFirst(tmp.listSync()), hasLength(1));
    });
  });

  test('runBackupIfDue skips rather than failing when nothing is due',
      () async {
    final outcome = await runBackupIfDue(
      cadence: BackupCadence.daily,
      lastRun: DateTime(2026, 8, 9, 11),
      now: DateTime(2026, 8, 9, 12),
    );
    expect(outcome.skipped, isTrue);
    expect(outcome.succeeded, isFalse);
    expect(outcome.error, isNull, reason: 'not due is not a failure');
  });
}
