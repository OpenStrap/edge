// The two ways this app used to brick itself, and the recovery for each.
//
//   F-1  `AppState._init()` had no try/catch and is fired unawaited from the
//        constructor, so ANY throw inside it skipped `initialized = true`. The
//        route stayed `AppRoute.loading` — a bare CircularProgressIndicator
//        with no timeout, no message and no retry — on every single launch.
//
//   F-2  The migration ladder runs in ONE exclusive transaction with no
//        top-level guard, so a step that throws rolls it all back, the on-disk
//        `user_version` never advances, and the SAME step throws next launch.
//        Reinstalling was the only fix, and a reinstall takes the hand-typed
//        entries — journal, labs, nutrition, medication, strength sets, cycle
//        markers, sleep corrections — with it.
//
// Neither path is exercised by anything a user does, which is exactly why they
// both shipped broken.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show dbRebuiltCard;

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final created = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalDb.lastRebuild = null;
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
    // Plus every quarantine a rebuild parked (timestamped, so glob by prefix).
    for (final f in Directory(dir).listSync()) {
      final base = p.basename(f.path);
      if (f is File && created.any((n) => base.startsWith('$n.unopenable'))) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  });

  // ── F-1 ────────────────────────────────────────────────────────────────────
  group('start-up failure is a state, not a spinner', () {
    test('a throw inside _init names the failure and offers a retry', () async {
      const name = 'startup_guard_test.db';
      created.add(name);
      await LocalDb.close();
      LocalDb.dbName = name;
      // A corrupt prefs blob: `PairedDevice.load()` is the FIRST line of
      // start-up and `getString` on a non-string throws. Any step throwing has
      // the same consequence, and this one needs no platform failure to stage.
      SharedPreferences.setMockInitialValues({'paired_remote_id': 7});
      final app = AppState.forTesting();
      addTearDown(app.dispose);

      expect(app.route, AppRoute.loading);
      await app.debugInit();

      // Before the guard: initialized stayed false, initError did not exist,
      // and the route sat on `loading` forever with the throw reaching nothing
      // but Crashlytics.
      expect(app.initialized, isFalse);
      expect(app.initError, isNotNull);
      expect(app.initError, isNotEmpty);
      expect(app.route, AppRoute.failed);
    });

    test('retryInit clears the error and runs start-up again', () async {
      const name = 'startup_retry_test.db';
      created.add(name);
      await LocalDb.close();
      LocalDb.dbName = name;
      SharedPreferences.setMockInitialValues({'paired_remote_id': 7});
      final app = AppState.forTesting();
      await app.debugInit();
      expect(app.route, AppRoute.failed);

      // Repair the condition, then retry: the same code path has to be able to
      // succeed, or "Try again" is decoration.
      SharedPreferences.setMockInitialValues({});
      await app.retryInit();

      expect(app.initError, isNull);
      expect(app.initialized, isTrue);
      expect(app.route, isNot(AppRoute.failed));
      // Let the fire-and-forget tails of a SUCCESSFUL start-up land before the
      // object goes away, or they notify a disposed ChangeNotifier.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      app.dispose();
    });
  });

  // ── F-2 ────────────────────────────────────────────────────────────────────
  group('a database that will not open is rebuilt, not lost', () {
    test(
      'the unopenable file is quarantined and the hand-typed rows come back',
      () async {
        const name = 'rebuild_recovery_test.db';
        created.add(name);
        final path = await _dbPath(name);
        await databaseFactory.deleteDatabase(path);

        // Seed a v2 database carrying real user data — and a `metric_series`
        // table with the wrong shape, so the ladder's
        // `CREATE INDEX idx_metric_series_key ON metric_series(key, date)`
        // throws "no such column: key" and rolls the whole upgrade back.
        // (`_createDerived` is `CREATE TABLE IF NOT EXISTS`, and nothing in the
        // ladder drops this table.) A faithful stand-in for every ladder brick
        // this codebase has actually shipped — the real ones were "duplicate
        // column name" out of a bare ALTER.
        final seed = await databaseFactory.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE metric_series (bogus INTEGER)');
              await db.execute('''
                CREATE TABLE journal (
                  date TEXT PRIMARY KEY,
                  tags_json TEXT NOT NULL DEFAULT '[]',
                  note TEXT NOT NULL DEFAULT '',
                  updated_at INTEGER NOT NULL
                )
              ''');
              await db.execute('''
                CREATE TABLE cycle_log (
                  date TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  note TEXT
                )
              ''');
            },
          ),
        );
        await seed.insert('journal', {
          'date': '2026-08-01',
          'tags_json': '["caffeine"]',
          'note': 'slept badly, three coffees',
          'updated_at': 1,
        });
        await seed.insert('cycle_log', {
          'date': '2026-08-03',
          'kind': 'start',
          'note': null,
        });
        await seed.close();

        await LocalDb.close();
        LocalDb.dbName = name;

        // Before the guard this threw straight out of `openDatabase`, forever.
        final db = await LocalDb.instance;
        expect(
          (await db.rawQuery('PRAGMA user_version')).first.values.first,
          LocalDb.schemaVersion,
        );

        final rebuild = LocalDb.lastRebuild;
        expect(rebuild, isNotNull, reason: 'the rebuild must be recorded');
        expect(rebuild!.cause, isNotEmpty);

        // The old file is PARKED, never deleted: whatever the tolerant salvage
        // could not read is still in there.
        expect(File(rebuild.quarantinePath).existsSync(), isTrue);

        // And the irreplaceable rows are back in the new database.
        final journal = await db.query('journal');
        expect(journal, hasLength(1));
        expect(journal.first['note'], 'slept badly, three coffees');
        final cycle = await db.query('cycle_log');
        expect(cycle, hasLength(1));
        expect(cycle.first['kind'], 'start');

        // A rebuild is only a recovery if the result is a WORKING database.
        final health = await LocalDb.schemaHealth();
        expect(health['ok'], isTrue, reason: '$health');
        await LocalDb.close();
      },
    );

    test('a normal open records no rebuild', () async {
      const name = 'rebuild_not_needed_test.db';
      created.add(name);
      await databaseFactory.deleteDatabase(await _dbPath(name));
      await LocalDb.close();
      LocalDb.dbName = name;
      await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);
      await LocalDb.close();
    });
  });

  // ── F-2, end to end ────────────────────────────────────────────────────────
  //
  // The group above proves ONE brick (a ladder throw) recovers TWO tables. The
  // quarantine path is the app's only safety net against a permanent brick and
  // the rest of what it promises was tested only implicitly:
  //
  //   * a file that is not a database at all — garbage bytes, and a truncated
  //     one — where the salvage gets nothing and must still leave a WORKING app
  //     and the original file on disk;
  //   * the whole `_salvageTables` promise, not a two-table sample;
  //   * the user actually being TOLD (the rebuild notice), because a silent
  //     rebuild is indistinguishable from data vanishing;
  //   * idempotence in both directions: a rebuilt database re-opens normally,
  //     and a SECOND rebuild must not overwrite the first quarantine.
  group('the quarantine path, end to end', () {
    /// One row per salvage-list group, at the shapes `_salvageTables` names.
    /// Values are distinctive so a merge that silently substituted a default
    /// would fail on the value, not just the count.
    Future<void> seedOneOfEverything(Database db) async {
      await db.insert('journal', {
        'date': '2026-08-01',
        'tags_json': '["caffeine"]',
        'note': 'slept badly, three coffees',
        'updated_at': 1,
      });
      await db.insert('lab_result', {
        'marker': 'ferritin',
        'taken_on': '2026-07-14',
        'value': 63.5,
        'unit': 'ng/mL',
        'note': 'fasted',
        'updated_at': 1,
      });
      await db.insert('food_entry', {
        'id': 'fe1',
        'date': '2026-08-01',
        'meal': 'breakfast',
        'label': 'porridge',
        'kcal': 340.0,
        'created_at': 1,
        'updated_at': 1,
      });
      await db.insert('med_dose', {
        'med_key': 'vitd',
        'date': '2026-08-01',
        'slot_min': 480,
        'taken_ts': 1234,
        'updated_at': 1,
      });
      await db.insert('cycle_log', {
        'date': '2026-08-03',
        'kind': 'start',
        'note': null,
      });
      await db.insert('sleep_override', {
        'day_id': '2026-08-01',
        'onset_ts': 1000,
        'offset_ts': 2000,
        'source': 'user',
        'created_at': 1,
      });
      await db.insert('sessions', {
        'id': 's1',
        'start_ts': 1000,
        'end_ts': 2000,
        'type': 'run',
        'status': 'done',
        'source': 'manual',
        'created_at': 1,
      });
      await db.insert('day_result', {
        'day_id': '2026-08-01',
        'algo_version': 70,
        'payload_json': '{"x":1}',
        'computed_at': 1,
        'rhr': 51.0,
      });
      await db.insert('metric_series', {
        'date': '2026-08-01',
        'key': 'rhr',
        'value': 51.0,
      });
      await db.insert('baselines', {
        'key': 'rhr',
        'payload_json': '{"mean":51}',
        'updated_at': 1,
      });
      await db.insert('raw_archive', {
        'hex': 'deadbeef',
        'counter': 7,
        'packet_type': 0x2f,
        'rec_ts': 1000,
        'captured_at': 1000,
        'reason': 'undecodable',
      });
      await db.insert('decoded_onehz', {
        'rec_ts': 1000,
        'counter': 7,
        'hr': 57,
      });
      await db.insert('decoded_rr', {
        'rec_ts': 1000,
        'beat_index': 0,
        'rr_ts_ms': 0,
        'rr_ms': 1042,
      });
    }

    /// Every table `seedOneOfEverything` writes, i.e. the salvage promise as a
    /// user reads it: hand-typed, derived-once, and the retention window.
    const salvaged = [
      'journal',
      'lab_result',
      'food_entry',
      'med_dose',
      'cycle_log',
      'sleep_override',
      'sessions',
      'day_result',
      'metric_series',
      'baselines',
      'raw_archive',
      'decoded_onehz',
      'decoded_rr',
    ];

    /// Drop a database at [name] that opens fine today, then force the ladder
    /// to throw on the NEXT open without damaging a single salvage table:
    /// rewind `user_version` and pre-plant the `_raw_old` name that the oldV<8
    /// step renames `raw_records` onto. `ALTER TABLE … RENAME TO` onto an
    /// existing name throws, inside the one exclusive transaction, exactly as
    /// every real brick this file documents did.
    Future<void> seedThenBrickTheLadder(String name) async {
      created.add(name);
      await databaseFactory.deleteDatabase(await _dbPath(name));
      await LocalDb.close();
      LocalDb.dbName = name;
      await seedOneOfEverything(await LocalDb.instance);
      await LocalDb.close();

      final raw = await databaseFactory.openDatabase(await _dbPath(name));
      await raw.execute('CREATE TABLE _raw_old (hex TEXT)');
      await raw.execute('PRAGMA user_version = 2');
      await raw.close();
      LocalDb.lastRebuild = null;
    }

    test('a ladder brick returns every table the salvage list promises',
        () async {
      await seedThenBrickTheLadder('rebuild_full_salvage_test.db');

      final db = await LocalDb.instance;
      final r = LocalDb.lastRebuild;
      expect(r, isNotNull, reason: 'the planted brick must trip the rebuild');
      expect(
        (await db.rawQuery('PRAGMA user_version')).first.values.first,
        LocalDb.schemaVersion,
      );
      expect(File(r!.quarantinePath).existsSync(), isTrue,
          reason: 'the old file is parked, never deleted');

      for (final t in salvaged) {
        expect(await db.query(t), hasLength(1), reason: '$t did not come back');
        expect(r.salvaged[t], 1, reason: '$t was not reported as recovered');
      }
      // Values, not just counts — a merge that dropped columns would pass a
      // row count and still hand the user a blank entry.
      expect((await db.query('journal')).first['note'],
          'slept badly, three coffees');
      expect((await db.query('lab_result')).first['value'], 63.5);
      expect((await db.query('decoded_rr')).first['rr_ms'], 1042);
      // `_days` is the importer's bookkeeping key, not a table: it must never
      // reach the rebuild card, which prints this map verbatim.
      expect(r.salvaged.containsKey('_days'), isFalse);
      expect((await LocalDb.schemaHealth())['ok'], isTrue);

      // THE USER IS TOLD. A rebuild nobody hears about is data vanishing.
      final card = dbRebuiltCard(r);
      expect(card, isNotNull);
      expect(card!.what, contains('rebuilt'));
      expect(card.why, contains('journal 1'));
      expect(card.why, contains(r.quarantinePath));
      expect(card.why, contains('nothing was '));

      // IDEMPOTENT: the rebuilt file is a normal database. Re-opening it runs
      // no second rebuild and loses nothing.
      LocalDb.lastRebuild = null;
      await LocalDb.close();
      final again = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);
      for (final t in salvaged) {
        expect(await again.query(t), hasLength(1), reason: '$t lost on reopen');
      }
      await LocalDb.close();
    });

    test('the salvage list covers everything a restore carries', () {
      // Notifications regenerate on the next derive; everything else a
      // restore treats as the only copy is the only copy on a rebuild too.
      expect(
        LocalDb.restoreTablesForTest
            .toSet()
            .difference(LocalDb.salvageTablesForTest.toSet()),
        {'notifications'},
      );
    });

    test('a garbage file is quarantined byte-for-byte and the app still opens',
        () async {
      const name = 'rebuild_garbage_test.db';
      created.add(name);
      final path = await _dbPath(name);
      await databaseFactory.deleteDatabase(path);
      await LocalDb.close();
      LocalDb.dbName = name;

      final garbage = Uint8List.fromList(
          List<int>.generate(8192, (i) => (i * 37 + 11) & 0xFF));
      File(path).writeAsBytesSync(garbage);
      LocalDb.lastRebuild = null;

      final db = await LocalDb.instance;
      final r = LocalDb.lastRebuild;
      expect(r, isNotNull);
      expect(
        (await db.rawQuery('PRAGMA user_version')).first.values.first,
        LocalDb.schemaVersion,
      );
      // Nothing was readable, so nothing is claimed — and the bytes are still
      // there, unmodified, for a human to take apart.
      expect(r!.salvaged.values.where((v) => v > 0), isEmpty);
      expect(File(r.quarantinePath).readAsBytesSync(), garbage);
      expect(dbRebuiltCard(r)!.why, contains('Nothing could be read back.'));
      expect((await LocalDb.schemaHealth())['ok'], isTrue);
      // A working database, not just an opening one.
      await db.insert('journal', {
        'date': '2026-08-05',
        'tags_json': '[]',
        'note': 'after the rebuild',
        'updated_at': 1,
      });

      // IDEMPOTENT the other way: a SECOND rebuild must park a SECOND file.
      // A fixed quarantine name would overwrite the first one — the only copy
      // of whatever the tolerant salvage could not read.
      final first = r.quarantinePath;
      await LocalDb.close();
      File(path).writeAsBytesSync(garbage);
      LocalDb.lastRebuild = null;
      await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNotNull);
      expect(LocalDb.lastRebuild!.quarantinePath, isNot(first));
      expect(File(first).existsSync(), isTrue,
          reason: 'the first quarantine must survive the second rebuild');
      await LocalDb.close();
    });

    test('a truncated database is quarantined, not wiped', () async {
      const name = 'rebuild_truncated_test.db';
      created.add(name);
      final path = await _dbPath(name);
      await databaseFactory.deleteDatabase(path);
      await LocalDb.close();
      LocalDb.dbName = name;
      await seedOneOfEverything(await LocalDb.instance);
      await LocalDb.close();

      // Keep the sqlite magic, lose the rest — the shape of an interrupted
      // copy or a filesystem that gave up mid-write. The -wal/-shm siblings go
      // too, or sqlite replays a journal over the stump.
      for (final s in const ['-wal', '-shm']) {
        final f = File('$path$s');
        if (f.existsSync()) f.deleteSync();
      }
      final before = File(path).lengthSync();
      expect(before, greaterThan(600));
      final raf = File(path).openSync(mode: FileMode.write)..truncateSync(600);
      raf.closeSync();
      LocalDb.lastRebuild = null;

      final db = await LocalDb.instance;
      final r = LocalDb.lastRebuild;
      expect(r, isNotNull, reason: 'a 600-byte stump must not open');
      expect(File(r!.quarantinePath).lengthSync(), 600,
          reason: 'the stump is parked exactly as found');
      expect(
        (await db.rawQuery('PRAGMA user_version')).first.values.first,
        LocalDb.schemaVersion,
      );
      expect((await LocalDb.schemaHealth())['ok'], isTrue);
      expect(dbRebuiltCard(r), isNotNull);
      await LocalDb.close();
    });
  });
}
