// The Home day switcher reads three per-day getters (overview, strain, sleep)
// for the day it stepped onto. Each used to fetch and fully decode that day's
// stored bundle on its own, so every arrow tap decoded the same row three
// times on the UI isolate.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show HomeData;

void main() {
  late LocalRepositoryImpl repo;
  const day = '2026-03-10';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_home_day_decode_once_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'date': day,
        'scalars': {'rhr': 51.0, 'strain': 9.4, 'steps': 7200},
        'sleep': {
          'accounting': {
            'value': {'tst_sec': 420 * 60},
          },
        },
        'series': {
          'strain_curve': [
            for (var i = 0; i < 50; i++) {'t': 1000 + i * 60, 'v': i / 10},
          ],
        },
      }),
      windowJson: '{}',
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  test('stepping onto a past day decodes its bundle once', () async {
    final before = LocalRepositoryImpl.bundleDecodes;
    final h = await HomeData.loadForDay(repo, day);
    expect(LocalRepositoryImpl.bundleDecodes - before, 1);

    // Same figures the unshared getters serve.
    final strain = await repo.getDayStrain(day);
    final overview = await repo.getDayOverview(day);
    final sleep = await repo.getDaySleepV2(day);
    expect(h.strain.value, strain['strain']);
    expect(h.steps.value, strain['steps']);
    expect(h.rhr.value, overview['resting_hr']);
    expect(h.sleepMin.value, sleep['duration_min']);
    expect(h.sleepMin.value, isNotNull);
  });

  test('the shared decode does not outlive its scope', () async {
    await repo.sharingDayReads(() => repo.getDayStrain(day));
    final before = LocalRepositoryImpl.bundleDecodes;
    await repo.getDayStrain(day);
    await repo.getDayStrain(day);
    expect(LocalRepositoryImpl.bundleDecodes - before, 2);
  });
}
