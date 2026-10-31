// The cross-day artifacts hold each night on its lived clock relative to the
// zone they were built in. Read in another zone, every night moves by the
// difference, so a past day's rollup is served only in the zone it was built
// in; elsewhere it abstains until the next pass rebuilds it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart'
    show crossDayAsOf;
import 'package:openstrap_edge/data/db.dart';

Map<String, dynamic> _day(String date, int onset) => {
      'date': date,
      'rhr': 52,
      'rmssd': 60,
      'readiness': 70,
      'onset_sec': onset,
      'wake_sec': onset + 8 * 3600,
      'tst_min': 450,
      'efficiency': 95,
    };

Future<void> _putInput(String zone) async {
  final base = DateTime.utc(2026, 9, 1, 22).millisecondsSinceEpoch ~/ 1000;
  final days = [
    for (var i = 0; i < 5; i++)
      _day('2026-09-0${i + 2}', base + i * 86400),
  ];
  await LocalDb.putBaseline(
    'crossday_input',
    jsonEncode({
      'algo_version': kAlgoVersion,
      'built_for_day': '2026-09-06',
      'review_revision': await LocalDb.activityReviewRevision(),
      'zone': zone,
      'days': days,
    }),
  );
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_crossday_as_of_zone_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('inputs built in this zone rebuild a past day', () async {
    await _putInput(DerivationEngine.crossDayZoneStamp());
    expect(await crossDayAsOf('2026-09-05'), isNotEmpty);
  });

  test('inputs built in another zone abstain', () async {
    await _putInput('Elsewhere|-420');
    expect(await crossDayAsOf('2026-09-05'), isEmpty);
  });

  test('a stored rollup from another zone is not served as current',
      () async {
    await _putInput('Elsewhere|-420');
    await LocalDb.putBaseline(
      'crossday',
      jsonEncode({
        'algo_version': kAlgoVersion,
        'zone': 'Elsewhere|-420',
        'recent': [
          {'date': '2026-09-06'},
        ],
      }),
    );
    expect(await crossDayAsOf('2026-09-06'), isEmpty);
  });
}
