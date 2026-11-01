// The stress Nerd Stats table is read from the VIEWED day's own payload. Not
// from `getDayStress`, which serves the latest complete day for a today with
// no bundle and substitutes the nightly RMSSD for a missing one. And a payload
// that will not decode costs the table, never the screen.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _put(String day, Map<String, dynamic> payload) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(payload),
      windowJson: '{}',
      finalized: true,
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_investigate_stress_load_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  final repo = LocalRepositoryImpl(getProfileMap: () => const {'age': 30});

  test('the block is the viewed day\'s own, with nothing substituted',
      () async {
    await _put('2020-03-01', {
      'stress': {'si': 12.5, 'level': 'low', 'score': 0.0},
      'scalars': {'rmssd': 99.0},
    });
    await _put('2020-03-02', {
      'stress': {'si': 80.0, 'level': 'normal', 'score': 40.0},
    });

    final a = await InvestigateData.load(repo, 'stress', want: '2020-03-01');
    expect(a.day, '2020-03-01');
    expect(a.stress, {'si': 12.5, 'level': 'low', 'score': 0.0},
        reason: 'no rmssd key: the nightly scalar is not borrowed');

    final b = await InvestigateData.load(repo, 'stress', want: '2020-03-02');
    expect(b.stress['si'], 80.0);
  });

  test('an imported day is still reported as imported from the same decode',
      () async {
    await _put('2020-03-04', {
      'imported': true,
      'source': 'NOOP',
      'stress': {'si': 12.5, 'level': 'low', 'score': 0.0},
    });
    final d = await InvestigateData.load(repo, 'stress', want: '2020-03-04');
    expect(d.importedFrom, 'NOOP');
    expect(d.stress['si'], 12.5);
  });

  test('only the stress key pays for the block', () async {
    final d = await InvestigateData.load(repo, 'rhr', want: '2020-03-01');
    expect(d.stress, isEmpty);
  });

  test('a payload that will not decode leaves the screen loadable', () async {
    final db = await LocalDb.instance;
    await db.insert('day_result', {
      'day_id': '2020-03-03',
      'algo_version': kAlgoVersion,
      'payload_json': '{"stress": {not json',
      'window_json': '{}',
      'computed_at': 0,
      'finalized': 1,
      'skipped': 0,
      'partial': 0,
    });
    final d = await InvestigateData.load(repo, 'stress', want: '2020-03-03');
    expect(d.day, '2020-03-03');
    expect(d.stress, isEmpty);
  });
}
