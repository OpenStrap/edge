// getSessions: merge of detected workouts (from the day bundle's
// `detected_workouts`) with manual sessions (the sessions table), with manual
// winning on overlap. Runs the REAL LocalDb against in-memory sqlite.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_sessions_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('getSessions merges detected + manual; manual wins on overlap', () async {
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});

    // Anchor near "now" so the default month window includes it.
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final base = nowSec - 3600; // 1 h ago
    final date = _ymd(DateTime.fromMillisecondsSinceEpoch(base * 1000));

    // One manual session [base, base+1200].
    await LocalDb.putSession({
      'id': 'manual1',
      'start_ts': base,
      'end_ts': base + 1200,
      'type': 'run',
      'status': 'done',
      'source': 'manual',
      'created_at': base * 1000,
    });

    // A derived day with TWO detected bouts: one OVERLAPS the manual session
    // (must be dropped), one is separate (must survive).
    final bundle = {
      'date': date,
      'detected_workouts': [
        {
          'start': base + 300, // overlaps manual [base, base+1200]
          'end': base + 900,
          'avg_hr': 150,
          'peak_hr': 165,
          'strain': 12.3,
          'duration_s': 600,
          'calories_kcal': 95,
          'sport': 'detected',
        },
        {
          'start': base + 2000, // separate, later
          'end': base + 2600,
          'avg_hr': 140,
          'peak_hr': 158,
          'strain': 9.1,
          'duration_s': 600,
          'calories_kcal': 80,
          'sport': 'detected',
        },
      ],
    };
    await LocalDb.putDayResult(
      dayId: date,
      algoVersion: 1,
      payloadJson: jsonEncode(bundle),
      windowJson: '{}',
    );

    final sessions = await repo.getSessions();
    // Manual + the one non-overlapping detected bout = 2.
    expect(sessions, hasLength(2));

    final byId = {for (final s in sessions) s['id']: s};
    expect(byId.containsKey('manual1'), isTrue);
    // The overlapping detected bout (auto_..._${base+300}) is dropped.
    expect(
      sessions.any((s) => (s['id'] as String).contains('${base + 300}')),
      isFalse,
    );
    // The separate detected bout survives, sourced 'auto', sport→type.
    final auto = sessions.firstWhere((s) => s['source'] == 'auto');
    expect(auto['start_ts'], base + 2000);
    expect(auto['type'], 'detected');
    expect(auto['calories'], 80);
    expect(auto['duration_min'], 10);

    // Sorted newest-first by start_ts: the later detected bout comes first.
    expect(sessions.first['start_ts'], base + 2000);
  });
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
