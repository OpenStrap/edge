// Day delete / day export / restore leftovers, plus the vendor-epoch overlap
// probe and the session_sensor rebuild resume.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart' show VendorEpoch;
import 'package:openstrap_edge/data/db.dart';

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
}

int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  // A fixed past day, never "today": nothing here depends on the clock.
  const day = '2026-03-10';
  final dayStart = _sec(DateTime(2026, 3, 10));
  final noon = _sec(DateTime(2026, 3, 10, 12));
  final nextNoon = _sec(DateTime(2026, 3, 11, 12));

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PathProviderPlatform.instance = _FakePathProvider(
      Directory.systemTemp.createTempSync('day_fix_paths').path,
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  Future<Database> freshDb(String name) async {
    await LocalDb.close();
    LocalDb.dbName = name;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, name));
    return LocalDb.instance;
  }

  // Contiguous 30-minute epochs, so they chain into one night.
  List<VendorEpoch> night(int from, int to) => [
        for (var t = from; t < to; t += 1800)
          VendorEpoch(t, t + 1800, 'light'),
      ];

  Future<void> insertSession(Database db, String id, int start) =>
      db.insert('sessions', {
        'id': id,
        'start_ts': start,
        'end_ts': start + 1800,
        'type': 'run',
        'status': 'done',
        'created_at': start * 1000,
      });

  Future<void> insertRace(
    Database db, {
    required String id,
    required String status,
    required int start,
    required int updatedAtMs,
    int? finalizedAt,
    bool openSegment = false,
  }) async {
    await db.insert('triathlon_session', {
      'id': id,
      'kind': 'race',
      'preset': 'sprint',
      'status': status,
      'plan_json': '{"segments":[{}]}',
      'start_ts': start,
      'end_ts': openSegment ? null : start + 600,
      'finalized_at': finalizedAt,
      'created_at': updatedAtMs,
      'updated_at': updatedAtMs,
    });
    await db.insert('triathlon_segment', {
      'session_id': id,
      'idx': 0,
      'kind': 'swim',
      'start_ts': start,
      'end_ts': openSegment ? null : start + 600,
    });
  }

  test('deleting a day takes its external hr and the night that ended in it',
      () async {
    final db = await freshDb('day_fix_delete.db');
    await db.insert('external_hr',
        {'ts': noon, 'source': 'strap', 'hr': 120, 'session_id': null});
    await db.insert('external_hr',
        {'ts': nextNoon, 'source': 'strap', 'hr': 121, 'session_id': null});
    // The night that ended this morning belongs to this day; tonight's
    // night ends tomorrow and is not touched.
    await LocalDb.putVendorSleepEpochs(
      night(dayStart - 3600, dayStart + 6 * 3600),
      deviceId: 'ring',
      source: 'test',
    );
    await LocalDb.putVendorSleepEpochs(
      night(dayStart + 23 * 3600, dayStart + 30 * 3600),
      deviceId: 'ring',
      source: 'test',
    );

    await LocalDb.deleteDays({day});

    final hr = await db.query('external_hr');
    expect([for (final r in hr) r['ts']], [nextNoon]);
    final epochs = await db.query('vendor_sleep_epoch');
    expect(epochs, isNotEmpty);
    expect(
      epochs.every((r) => (r['start_ts'] as int) >= dayStart + 23 * 3600),
      isTrue,
    );
  });

  test('a day export carries the sessions children and the vendor night',
      () async {
    final db = await freshDb('day_fix_export.db');
    await insertSession(db, 'w1', noon);
    await db.insert('workout_route', {
      'session_id': 'w1',
      'seq': 0,
      'ts_ms': noon * 1000,
      'lat': 1.0,
      'lng': 2.0,
    });
    await db.insert('strength_set', {
      'session_id': 'w1',
      'seq': 0,
      'exercise_key': 'squat',
      'set_index': 0,
    });
    await db.insert('session_sensor', {'session_id': 'w1', 'source': 's'});
    await db.insert('external_hr',
        {'ts': noon + 5, 'source': 'strap', 'hr': 130, 'session_id': 'w1'});
    await LocalDb.putVendorSleepEpochs(
      night(dayStart - 3600, dayStart + 6 * 3600),
      deviceId: 'ring',
      source: 'test',
    );

    final path = await LocalDb.exportDaysDb({day});
    final out = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(readOnly: true));
    for (final t in [
      'workout_route',
      'strength_set',
      'session_sensor',
      'external_hr',
    ]) {
      expect(await out.query(t), hasLength(1), reason: t);
    }
    expect(await out.query('vendor_sleep_epoch'), hasLength(14));
    await out.close();
    await File(path).delete();
  });

  test('an abandoned race with an open segment does not belong to later days',
      () async {
    final db = await freshDb('day_fix_tri_window.db');
    final march = _sec(DateTime(2026, 3, 1, 9));
    await insertRace(
      db,
      id: 'old_race',
      status: 'abandoned',
      start: march,
      updatedAtMs: (march + 3600) * 1000,
      openSegment: true,
    );

    final path = await LocalDb.exportDaysDb({day});
    final out = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(readOnly: true));
    expect(await out.query('triathlon_session'), isEmpty);
    await out.close();
    await File(path).delete();

    await LocalDb.deleteDays({day});
    expect(await db.query('triathlon_session'), hasLength(1));
    expect(await db.query('triathlon_segment'), hasLength(1));
  });

  test('a restore never replaces a locally finalized race', () async {
    final src = await freshDb('day_fix_tri_restore_src.db');
    await insertRace(
      src,
      id: 'race',
      status: 'finished',
      start: noon,
      updatedAtMs: (noon + 9000) * 1000,
    );
    final path = await LocalDb.exportDaysDb({day});

    final dest = await freshDb('day_fix_tri_restore_dest.db');
    await insertRace(
      dest,
      id: 'race',
      status: 'finalized',
      start: noon,
      updatedAtMs: (noon + 700) * 1000,
      finalizedAt: (noon + 700) * 1000,
    );
    await LocalDb.importFromDbFile(path);

    final row = (await dest.query('triathlon_session')).single;
    expect(row['status'], 'finalized');
    expect(row['finalized_at'], (noon + 700) * 1000);
    await File(path).delete();
  });

  test('a stored epoch that overlaps a new one is still replaced', () async {
    final db = await freshDb('day_fix_vendor_overlap.db');
    final t = noon;
    await LocalDb.putVendorSleepEpochs(
      [VendorEpoch(t, t + 4 * 3600, 'deep')],
      deviceId: 'ring',
      source: 'test',
    );
    await LocalDb.putVendorSleepEpochs(
      [VendorEpoch(t + 3 * 3600, t + 3 * 3600 + 30, 'rem')],
      deviceId: 'ring',
      source: 'test',
    );
    final rows = await db.query('vendor_sleep_epoch');
    expect([for (final r in rows) r['stage']], ['rem']);
  });

  test('a session_sensor rebuild cut off mid-way is resumed on open',
      () async {
    await freshDb('day_fix_session_sensor.db');
    await LocalDb.close();
    final path =
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
    final raw = await databaseFactory.openDatabase(path);
    // What a kill after RENAME + CREATE leaves behind.
    await raw.execute('CREATE TABLE session_sensor_v1 '
        '(session_id TEXT PRIMARY KEY, source TEXT NOT NULL)');
    await raw.insert('session_sensor_v1', {'session_id': 'w9', 'source': 's'});
    await raw.close();

    final db = await LocalDb.instance;
    expect(await db.query('session_sensor'), [
      {'session_id': 'w9', 'source': 's'},
    ]);
    final orphan = await db.rawQuery("SELECT 1 FROM sqlite_master "
        "WHERE name = 'session_sensor_v1'");
    expect(orphan, isEmpty);
  });
}
