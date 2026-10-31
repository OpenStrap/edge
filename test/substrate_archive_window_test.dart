// The archive window the data settings step through.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/substrate_archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('defaults to 90 days', () {
    expect(SubstrateArchivePolicy.defaults.keepDays, 90);
    expect(SubstrateArchivePolicy.fromJson(null).keepDays, 90);
  });

  test('steps 30 → 90 → 365 → forever → 30', () {
    var p = const SubstrateArchivePolicy(30);
    final seen = <int>[];
    for (var i = 0; i < 4; i++) {
      p = p.next;
      seen.add(p.keepDays);
    }
    expect(seen, [90, 365, -1, 30]);
  });

  test('an off or hand-set window moves to the next longer choice', () {
    expect(const SubstrateArchivePolicy(0).next.keepDays, 30);
    expect(const SubstrateArchivePolicy(45).next.keepDays, 90);
    expect(const SubstrateArchivePolicy(400).next.keepDays, -1);
  });

  test('only a shorter window counts as deleting history', () {
    const forever = SubstrateArchivePolicy(-1);
    const year = SubstrateArchivePolicy(365);
    const month = SubstrateArchivePolicy(30);
    expect(forever.keepsLongerThan(month), isTrue);
    expect(year.keepsLongerThan(month), isTrue);
    expect(month.keepsLongerThan(year), isFalse);
    expect(month.keepsLongerThan(forever), isFalse);
    expect(year.keepsLongerThan(year), isFalse);
  });

  group('an archive from before the 90-day default', () {
    late Database db;
    setUpAll(sqfliteFfiInit);
    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      await db.execute('CREATE TABLE compute_freshness (key TEXT PRIMARY KEY, '
          'payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)');
      await db.execute('CREATE TABLE ${SubstrateArchive.table} (utc_day INTEGER, day TEXT)');
      await db.execute('CREATE TABLE decoded_onehz (rec_ts INTEGER)');
      await db.execute('CREATE TABLE decoded_rr (rec_ts INTEGER)');
    });
    tearDown(() => db.close());

    test('keeps its year when nothing was ever chosen', () async {
      await db.insert(SubstrateArchive.table, {'day': '2025-11-01'});
      await SubstrateArchive.keepLegacyWindowOnce(db);
      expect((await SubstrateArchive.readPolicy(db)).keepDays, 365);
    });

    test('a new install gets the default, and the check runs once', () async {
      await SubstrateArchive.keepLegacyWindowOnce(db);
      expect((await SubstrateArchive.readPolicy(db)).keepDays, 90);
      // Archiving starts later on this build: still the default.
      await db.insert(SubstrateArchive.table, {'day': '2026-10-01'});
      await SubstrateArchive.keepLegacyWindowOnce(db);
      expect((await SubstrateArchive.readPolicy(db)).keepDays, 90);
    });

    test('an empty archive with band readings already stored keeps a year',
        () async {
      await db.insert('decoded_onehz', {'rec_ts': 1750000000});
      await SubstrateArchive.keepLegacyWindowOnce(db);
      expect((await SubstrateArchive.readPolicy(db)).keepDays, 365);
    });

    test('a backup from before the setting restores with its year', () async {
      final backup = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      addTearDown(backup.close);
      await backup.execute('CREATE TABLE compute_freshness (key TEXT PRIMARY '
          'KEY, payload_json TEXT NOT NULL, updated_at INTEGER NOT NULL)');
      await backup.execute('CREATE TABLE ${SubstrateArchive.table} (utc_day INTEGER, day TEXT)');
      // Fresh install: the check already ran and found nothing.
      await SubstrateArchive.keepLegacyWindowOnce(db);
      await SubstrateArchive.adoptPolicy(backup, db);
      expect((await SubstrateArchive.readPolicy(db)).keepDays, 90,
          reason: 'a backup with no history brings no window');
      await backup.insert(SubstrateArchive.table, {'day': '2025-11-01'});
      // A backup of a phone already on this build, with no setting chosen,
      // was getting the default: nothing to adopt.
      await backup.insert('compute_freshness', {
        'key': 'substrate_archive_policy_default_checked',
        'payload_json': '{}',
        'updated_at': 0,
      });
      await SubstrateArchive.adoptPolicy(backup, db);
      expect((await SubstrateArchive.readPolicy(db)).keepDays, 90);
      // One from before this build keeps its year.
      await backup.delete('compute_freshness');
      await SubstrateArchive.adoptPolicy(backup, db);
      expect((await SubstrateArchive.readPolicy(db)).keepDays, 365);
    });

    test('a window the user picked is left alone', () async {
      await db.insert(SubstrateArchive.table, {'day': '2025-11-01'});
      await db.insert('compute_freshness', {
        'key': SubstrateArchive.policyKey,
        'payload_json': const SubstrateArchivePolicy(30).toJson(),
        'updated_at': 0,
      });
      await SubstrateArchive.keepLegacyWindowOnce(db);
      expect((await SubstrateArchive.readPolicy(db)).keepDays, 30);
    });
  });
}
