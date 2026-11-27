// #912: on a phone whose SQLite has no JSON1, every json_* query threw, and a
// derive pass skipped each day with reason "error". The readers on that path
// now fall back to decoding the stored bundle in Dart. This holds the fallback
// to what the SQL answers, for the awkward payloads too.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/json_fallback.dart';

Future<void> _put(String day, Object payload, {bool skipped = false}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: payload is String ? payload : jsonEncode(payload),
      windowJson: '{}',
      skipped: skipped,
    );

Future<Map<String, Object?>> _answers(bool json1) async {
  LocalDb.debugJson1 = json1;
  final days = ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04',
      '2026-10-05', '2026-10-06', '2026-10-07'];
  return {
    'clock': [for (final d in days) await LocalDb.storedNightClock(d)],
    'facts': [
      for (final d in days)
        await LocalDb.pastDayFreshnessFactsForTest(d, kAlgoVersion),
    ],
    'scalars': await LocalDb.recentDayScalars(10, ['rhr', 'readiness', 'nope']),
    'tst': await LocalDb.daysWithSleepTst(),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'json1_fallback_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
    await _put('2026-10-01', {
      'sleep': {
        'window': {'value': {'onset_ms': 1790000000000}},
        'accounting': {'value': {'tst_sec': 25000}},
      },
      'scalars': {'rhr': 52, 'readiness': 70, 'sleep_onset_sec': -3600.5},
      'flags': ['NO_SLEEP_DETECTED'],
    });
    await _put('2026-10-02', {'skipped': true, 'reason': 'error'},
        skipped: true);
    await _put('2026-10-03', 'this is not json');
    await _put('2026-10-04', '[1,2]');
    await _put('2026-10-05', {
      'skipped': false,
      'sleep': {'accounting': {'value': {'tst_sec': null}}},
      'scalars': {'rhr': 'high', 'readiness': 'x'},
      'flags': 'SLEEP_REJECTED',
    });
    await _put('2026-10-06', {
      'scalars': {'rhr': 48.25, 'readiness': 55.5},
      'flags': ['OTHER'],
    });
    // 2026-10-07 has no row at all.
  });

  tearDownAll(() async {
    LocalDb.debugJson1 = null;
    await LocalDb.close();
  });

  test('the fallback answers what the JSON queries answer', () async {
    final sql = await _answers(true);
    final dart = await _answers(false);
    expect(dart['clock'], equals(sql['clock']));
    expect(dart['facts'], equals(sql['facts']));
    expect(dart['scalars'], equals(sql['scalars']));
    expect(dart['tst'], equals(sql['tst']));
    // Not vacuous: the good day really was read.
    expect((dart['tst'] as Set), contains('2026-10-01'));
    expect((dart['clock'] as List).first.onsetMs, 1790000000000);
  });

  test('the probe sees JSON1 here and remembers the answer', () async {
    LocalDb.debugJson1 = null;
    expect(await LocalDb.hasJson1(), isTrue);
    LocalDb.debugJson1 = false;
    expect(await LocalDb.hasJson1(), isFalse);
  });

  test('crossday_input first date', () {
    expect(
      crossdayInputFirstDateOf(jsonEncode({
        'days': [{'date': '2026-01-02'}, {'date': '2026-01-03'}],
      })),
      '2026-01-02',
    );
    expect(crossdayInputFirstDateOf('{"days":[]}'), isNull);
    expect(crossdayInputFirstDateOf('nope'), isNull);
  });
}
