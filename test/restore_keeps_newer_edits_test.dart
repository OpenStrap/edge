// Restoring an older backup must not hand the user's newer edits back to the
// backup's copies. Every hand-entered table used to merge with a plain
// INSERT OR REPLACE, so a journal note rewritten after the backup, a corrected
// sleep window or a finished workout all reverted on restore — and a day's
// journal fields were patched row by row, bringing back one the user removed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

const _day = '2026-10-12';
const _other = '2026-10-13';

Future<String> _snapshot(String name) async {
  final dir = await databaseFactory.getDatabasesPath();
  final path = p.join(dir, name);
  if (File(path).existsSync()) File(path).deleteSync();
  await (await LocalDb.instance).execute("VACUUM INTO '$path'");
  return path;
}

Future<void> _clear() async {
  final db = await LocalDb.instance;
  for (final t in [
    'journal',
    'journal_metric',
    'lab_result',
    'sleep_override',
    'cycle_symptom',
    'cycle_log',
    'sessions',
    'strength_set',
    'med_dose',
    'med_def',
    'food_entry',
    'step_calibration',
  ]) {
    await db.delete(t);
  }
}

Map<String, Object?> _session(String status, int? endTs) => {
      'id': 's1',
      'start_ts': 100,
      'end_ts': endTs,
      'type': 'run',
      'status': status,
      'created_at': 1,
    };

Map<String, Object?> _set(int seq, int reps) => {
      'session_id': 's1',
      'seq': seq,
      'exercise_key': 'squat',
      'set_index': seq,
      'reps': reps,
    };

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_restore_keeps_newer_edits_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    for (final f in [
      'openstrap_restore_keeps_newer_edits_test.db',
      'monday.db',
      'newer.db',
      'dose.db',
      'schedule.db',
      'calib.db',
      'calib_new.db',
    ]) {
      try {
        File(p.join(dir, f)).deleteSync();
      } catch (_) {}
    }
  });

  test('an older backup leaves edits made after it alone', () async {
    await _clear();
    final db = await LocalDb.instance;
    await db.insert('journal',
        {'date': _day, 'tags_json': '[]', 'note': 'MONDAY', 'updated_at': 1000});
    await db.insert('journal_metric',
        {'date': _day, 'field': 'caffeine', 'value': 3.0, 'updated_at': 1000});
    await db.insert('lab_result', {
      'marker': 'ldl', 'taken_on': _day, 'value': 9.0, 'unit': 'mg/dL',
      'updated_at': 1000,
    });
    await db.insert('sleep_override', {
      'day_id': _day, 'onset_ts': 100, 'offset_ts': 200, 'source': 'manual',
      'created_at': 1000,
    });
    await db.insert('cycle_symptom',
        {'date': _day, 'symptoms_json': '["cramps"]', 'updated_at': 1000});
    await db.insert('cycle_log', {'date': _day, 'kind': 'start'});
    await db.insert('sessions', _session('live', null));
    for (var i = 0; i < 3; i++) {
      await db.insert('strength_set', _set(i, 5));
    }
    // Only in the backup: a restore still brings back what was lost.
    await db.insert('journal',
        {'date': _other, 'tags_json': '[]', 'note': 'LOST', 'updated_at': 900});
    final backup = await _snapshot('monday.db');

    await db.delete('journal', where: 'date = ?', whereArgs: [_other]);
    await db.update('journal', {'note': 'TUESDAY', 'updated_at': 2000});
    await db.delete('journal_metric');
    await db.insert('journal_metric',
        {'date': _day, 'field': 'alcohol', 'value': 1.0, 'updated_at': 2000});
    await db.update('lab_result', {'value': 90.0, 'updated_at': 2000});
    await db.update('sleep_override',
        {'onset_ts': 300, 'offset_ts': 400, 'created_at': 2000});
    await db.update('cycle_symptom',
        {'symptoms_json': '["headache"]', 'updated_at': 2000});
    await db.update('cycle_log', {'kind': 'end'});
    await db.update('sessions', {'status': 'done', 'end_ts': 900});
    await db.delete('strength_set', where: 'seq = 2');

    await LocalDb.importFromDbFile(backup);

    final journal = await db.query('journal', orderBy: 'date');
    expect([for (final r in journal) r['note']], ['TUESDAY', 'LOST']);
    final fields = await db.query('journal_metric');
    expect([for (final r in fields) r['field']], ['alcohol']);
    expect((await db.query('lab_result')).single['value'], 90.0);
    expect((await db.query('sleep_override')).single['onset_ts'], 300);
    expect((await db.query('cycle_symptom')).single['symptoms_json'],
        '["headache"]');
    expect((await db.query('cycle_log')).single['kind'], 'end');
    expect((await db.query('sessions')).single['status'], 'done');
    expect(await db.query('strength_set'), hasLength(2));
  });

  test('a backup newer than the local copy still wins, as a whole day',
      () async {
    await _clear();
    final db = await LocalDb.instance;
    await db.insert('journal_metric',
        {'date': _day, 'field': 'alcohol', 'value': 2.0, 'updated_at': 3000});
    await db.insert('sleep_override', {
      'day_id': _day, 'onset_ts': 500, 'offset_ts': 600, 'source': 'manual',
      'created_at': 3000,
    });
    final backup = await _snapshot('newer.db');

    // The local copy is rolled back to something older than the backup.
    await db.delete('journal_metric');
    await db.insert('journal_metric',
        {'date': _day, 'field': 'caffeine', 'value': 4.0, 'updated_at': 1000});
    await db.update('sleep_override',
        {'onset_ts': 100, 'offset_ts': 200, 'created_at': 1000});

    await LocalDb.importFromDbFile(backup);

    final fields = await db.query('journal_metric');
    expect([for (final r in fields) r['field']], ['alcohol']);
    expect((await db.query('sleep_override')).single['onset_ts'], 500);
  });

  test('an older backup does not undo a dose marked after it', () async {
    await _clear();
    final db = await LocalDb.instance;
    Map<String, Object?> dose(int slot, {int? takenTs, int skipped = 0,
            required int updatedAt}) =>
        {
          'med_key': 'iron', 'date': _day, 'slot_min': slot,
          'taken_ts': takenTs, 'skipped': skipped, 'note': '',
          'updated_at': updatedAt,
        };
    await db.insert('med_dose', dose(480, skipped: 1, updatedAt: 1000));
    await db.insert('med_dose', dose(1200, updatedAt: 1000));
    final backup = await _snapshot('dose.db');

    // Since the backup: the skipped morning dose was taken after all.
    await db.update(
        'med_dose', {'taken_ts': 50, 'skipped': 0, 'updated_at': 2000},
        where: 'slot_min = 480');

    await LocalDb.importFromDbFile(backup);

    final rows = await db.query('med_dose', orderBy: 'slot_min');
    expect(rows, hasLength(2));
    expect(rows.first['taken_ts'], 50);
    expect(rows.first['skipped'], 0);
  });

  test('an older backup does not undo a retimed schedule or an edited meal',
      () async {
    await _clear();
    final db = await LocalDb.instance;
    await db.insert('med_def', {
      'key': 'iron', 'label': 'Iron', 'schedule_json': '[480]',
      'created_at': 1000,
    });
    await db.insert('food_entry', {
      'id': 'f1', 'date': _day, 'meal': 'dinner', 'label': 'pasta',
      'kcal': 800.0, 'created_at': 1000, 'updated_at': 1000,
    });
    final backup = await _snapshot('schedule.db');

    // Since the backup: the dose moved to 09:00 and the meal was corrected.
    await db.update('med_def', {'schedule_json': '[540]'});
    await db.update('food_entry', {'kcal': 450.0, 'updated_at': 2000});

    await LocalDb.importFromDbFile(backup);

    expect((await db.query('med_def')).single['schedule_json'], '[540]');
    expect((await db.query('food_entry')).single['kcal'], 450.0);
  });

  test('an older backup does not roll back a refit step calibration',
      () async {
    await _clear();
    final db = await LocalDb.instance;
    Map<String, Object?> profile(double factor, int nDays, int ts) => {
          'device_family': 'whoop5', 'wearing': 1, 'factor': factor,
          'n_days': nDays, 'version': 1, 'updated_ts': ts,
        };
    await db.insert('step_calibration', profile(1.12, 10, 1000));
    final backup = await _snapshot('calib.db');

    // Since the backup: refit from more days.
    await db.insert('step_calibration', profile(0.97, 24, 2000),
        conflictAlgorithm: ConflictAlgorithm.replace);

    await LocalDb.importFromDbFile(backup);

    final row = (await db.query('step_calibration')).single;
    expect(row['factor'], 0.97);
    expect(row['n_days'], 24);
  });

  test('a newer backup step calibration still replaces an older local one',
      () async {
    await _clear();
    final db = await LocalDb.instance;
    Map<String, Object?> profile(double factor, int nDays, int ts) => {
          'device_family': 'whoop5', 'wearing': 1, 'factor': factor,
          'n_days': nDays, 'version': 1, 'updated_ts': ts,
        };
    await db.insert('step_calibration', profile(0.97, 24, 2000));
    final backup = await _snapshot('calib_new.db');
    await db.insert('step_calibration', profile(1.12, 10, 1000),
        conflictAlgorithm: ConflictAlgorithm.replace);

    await LocalDb.importFromDbFile(backup);

    final row = (await db.query('step_calibration')).single;
    expect(row['factor'], 0.97);
  });
}
