// A day the strap's on-chip step counter ANSWERED is presented from that
// counter, whether or not `live_coverage` also holds phone rows for it.
//
// The counter is a whole-day alternative: the derive only picks it when its
// calibrated total beat every coverage row put together. So the coverage rows
// on such a day are the count the day did NOT publish, and publishing their
// total as the day's figure put a smaller number on this screen than the one
// Home shows for the same day — labelled with the phone, on a day the wrist
// answered.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_day_steps_counter_over_coverage_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a counter day that also has phone hours publishes the counter', () async {
    const day = '2026-03-10';
    final midnight = localDayStartSec(day)!;
    const counterTotal = 12000;

    // The strap's chip answered the day: 12,000 steps in two hourly spans.
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'steps': {
          'value': counterTotal,
          'band_measured': counterTotal,
          'source': 'strap_counter',
          'spans': [
            {
              'start_ts': midnight + 9 * 3600,
              'end_ts': midnight + 10 * 3600 - 1,
              'steps': 4000,
            },
            {
              'start_ts': midnight + 10 * 3600,
              'end_ts': midnight + 11 * 3600 - 1,
              'steps': 8000,
            },
          ],
        },
      }),
      windowJson: '{}',
      finalized: true,
    );

    // …and the phone banked its own, smaller, hours. The ladder lost them to
    // the counter (8,000 < 12,000), which is exactly the state that used to
    // reach the screen as "8,000, counted by your phone".
    await LocalDb.replacePhoneCoverageForDay(day, [
      for (var h = 9; h < 17; h++)
        (
          startTs: midnight + h * 3600,
          endTs: midnight + (h + 1) * 3600 - 1,
          steps: 1000,
        ),
    ]);
    expect(await LocalDb.phoneStepsForDay(day), 8000,
        reason: 'the phone rows are really there, so the old reader saw them');

    final out =
        await LocalRepositoryImpl(getProfileMap: () => null).getDaySteps(day);

    // The day's number is the one it published, and the split sums to it.
    expect(out['day_total'], counterTotal);
    expect(out['day_source'], 'strap_counter');
    expect(out['total'], counterTotal,
        reason: 'the coverage total was the count this day did not publish');
    expect(out['strap'], counterTotal);
    expect(out['phone'], 0);

    // The clock comes from the counter's own spans, never the phone's.
    final spans = (out['spans'] as List).cast<Map>();
    expect(spans.map((s) => s['steps']), [4000, 8000]);
    expect(spans.map((s) => s['start_ts']),
        [midnight + 9 * 3600, midnight + 10 * 3600]);
    expect(spans.every((s) => s['source'] == LocalDb.kStepSourceBand), isTrue);
  });
}
