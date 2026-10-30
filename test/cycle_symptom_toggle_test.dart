// Cycle symptom chips toggle against the STORED row.
//
// The screen used to toggle against its last loaded snapshot and REPLACE the
// whole day's list. Two chips tapped before the reload landed were both
// computed from the same snapshot, so the second write wiped the first. It
// also passed no note, so every tap erased the day's note.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

Future<Map<String, dynamic>?> _row(String date) async {
  final rows = (await LocalDb.cycleSymptoms())
      .where((r) => r['date'] == date)
      .toList();
  return rows.isEmpty ? null : rows.first;
}

List<String> _symptoms(Map<String, dynamic>? r) => r == null
    ? const []
    : (jsonDecode(r['symptoms_json'] as String) as List).cast<String>();

void main() {
  const day = '2026-10-17';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_cycle_symptom_toggle_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async => LocalDb.close());

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('cycle_symptom');
  });

  test('two taps in flight at once both land', () async {
    await Future.wait([
      LocalDb.toggleCycleSymptom(day, 'cramps'),
      LocalDb.toggleCycleSymptom(day, 'headache'),
    ]);
    expect(_symptoms(await _row(day)).toSet(), {'cramps', 'headache'});
  });

  test('a stale off-then-on does not resurrect a removed symptom', () async {
    await LocalDb.putCycleSymptoms(day, ['cramps', 'headache']);
    await Future.wait([
      LocalDb.toggleCycleSymptom(day, 'cramps'),
      LocalDb.toggleCycleSymptom(day, 'bloating'),
    ]);
    expect(_symptoms(await _row(day)).toSet(), {'headache', 'bloating'});
  });

  test('a toggle keeps the day\'s note', () async {
    await LocalDb.putCycleSymptoms(day, ['cramps'], note: 'imported');
    await LocalDb.toggleCycleSymptom(day, 'headache');
    final r = await _row(day);
    expect(r?['note'], 'imported');
    expect(_symptoms(r), ['cramps', 'headache']);

    // Clearing the last symptom keeps the row while it still holds a note.
    await LocalDb.toggleCycleSymptom(day, 'cramps');
    await LocalDb.toggleCycleSymptom(day, 'headache');
    final cleared = await _row(day);
    expect(cleared?['note'], 'imported');
    expect(_symptoms(cleared), isEmpty);
  });

  test('clearing the last symptom with no note removes the row', () async {
    await LocalDb.toggleCycleSymptom(day, 'cramps');
    final now = await LocalDb.toggleCycleSymptom(day, 'cramps');
    expect(now, isEmpty);
    expect(await _row(day), isNull);
  });
}
