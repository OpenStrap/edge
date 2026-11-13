// A settled no-sleep morning (strap on the charger overnight) is today's
// overnight per compute freshness. getToday used to read the overnight side
// from the newest day WITH sleep instead, so an older night's readiness
// showed as this morning's with no prior-night label. When today's no-window
// row counts as settled is overnightSettled's call (overnight_settled_test).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_today_no_sleep_test.db';
  });

  setUp(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  test('a held-over no-sleep night does not show an older night under its date',
      () async {
    final today = todayLabel();
    final now = DateTime.now();
    final yesterday =
        todayLabel(DateTime(now.year, now.month, now.day - 1, 12));
    final twoAgo = todayLabel(DateTime(now.year, now.month, now.day - 2, 12));
    await LocalDb.putDayResult(
      dayId: twoAgo,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'readiness': 77, 'rmssd': 55},
        'sleep': {
          'accounting': {
            'value': {'tst_sec': 25200},
          },
        },
      }),
      windowJson: '{}',
    );
    await LocalDb.putDayResult(
      dayId: yesterday,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'steps': 900},
        'flags': ['NO_SLEEP_DETECTED'],
      }),
      windowJson: '{}',
    );
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'steps': 300},
      }),
      windowJson: '{}',
    );
    await LocalDb.refreshComputeFreshness();

    final t = await LocalRepositoryImpl(getProfileMap: () => {}).getToday();
    final status = t['status'] as Map;
    expect(status['showing_prior_overnight'], true);
    expect(status['overnight_day'], yesterday);
    final readiness = (t['daily'] as Map)['readiness'];
    expect(
        readiness is Map ? readiness['value'] : readiness, isNot(isA<num>()),
        reason: "$twoAgo's 77 is not $yesterday's readiness");
  });

  test("a night marked 'Not sleep' is today's overnight, not a held-over one",
      () async {
    final today = todayLabel();
    final now = DateTime.now();
    final yesterday =
        todayLabel(DateTime(now.year, now.month, now.day - 1, 12));
    await LocalDb.putDayResult(
      dayId: yesterday,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'readiness': 77},
        'sleep': {
          'accounting': {
            'value': {'tst_sec': 25200},
          },
        },
      }),
      windowJson: '{}',
    );
    // No window and no data edge: before the fix this was held as unsettled
    // until noon, then skipped for lacking NO_SLEEP_DETECTED.
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'steps': 300},
        'flags': ['SLEEP_REJECTED'],
      }),
      windowJson: '{}',
    );
    await LocalDb.refreshComputeFreshness();

    final t = await LocalRepositoryImpl(getProfileMap: () => {}).getToday();
    final status = t['status'] as Map;
    expect(status['overnight_day'], today);
    expect(status['overnight_state'], 'ready');
    expect(status['showing_prior_overnight'], false);
  });

  test('an import restamps the night getToday reads', () async {
    final today = todayLabel();
    final now = DateTime.now();
    final yesterday =
        todayLabel(DateTime(now.year, now.month, now.day - 1, 12));
    Map<String, dynamic> night(int readiness) => {
          'scalars': {'readiness': readiness},
          'sleep': {
            'accounting': {
              'value': {'tst_sec': 25200},
            },
          },
        };
    await LocalDb.putDayResult(
      dayId: yesterday,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(night(77)),
      windowJson: '{}',
    );
    await LocalDb.refreshComputeFreshness();
    // Today's night lands outside the foreground derive (import, background).
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(night(64)),
      windowJson: '{}',
    );
    await DerivationEngine().finalizeImport(const Profile());

    final t = await LocalRepositoryImpl(getProfileMap: () => {}).getToday();
    expect((t['status'] as Map)['overnight_day'], today);
  });
}
