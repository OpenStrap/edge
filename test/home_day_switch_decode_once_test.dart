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
import 'package:openstrap_edge/data/local_repository.dart';
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

  test('loading TODAY with a scored night decodes the day bundle once',
      () async {
    final now = DateTime.now();
    final todayDay = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    await LocalDb.putDayResult(
      dayId: todayDay,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'date': todayDay,
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
    // Warm anything that is not the bundle (freshness rows, the profile).
    await repo.getToday();
    final before = LocalRepositoryImpl.bundleDecodes;
    final h = await HomeData.load(repo);
    expect(h.sleepMin.value, isNotNull,
        reason: 'the fixture must be a scored night of today, or the stage '
            'read this test is about never happens');
    expect(LocalRepositoryImpl.bundleDecodes - before, 1,
        reason: 'getToday and the stage read share ONE decode');
  });

  group('HomeData.load keeps its extra reads minimal', () {
    Map<String, dynamic> today({required bool slept}) => {
          'daily': {
            'readiness': {'value': 80, 'confidence': .8, 'tier': 'HIGH'},
          },
          'sleep': slept
              ? {
                  'duration_min': {
                    'value': 442,
                    'confidence': .8,
                    'tier': 'ESTIMATE',
                    'unit': 'min',
                  },
                }
              : const {},
          'status': {
            'today_day': '2026-10-09',
            'overnight_state': 'ready',
            'overnight_day': '2026-10-09',
            'showing_prior_overnight': false,
          },
        };

    test('one stage read, and only for a scored night',
        () async {
      final scored = _CountingRepo(today(slept: true));
      await HomeData.load(scored);
      expect(scored.nightReads, 1);
      expect(scored.insightReads, 1);

      // No scored night: no stage read at all, and nothing borrowed.
      final bare = _CountingRepo(today(slept: false));
      final d = await HomeData.load(bare);
      expect(bare.nightReads, 0);
      expect(d.sleepStages, isNull);
    });

    test('a failed stage read leaves the figure absent, not a failed Home', () async {
      final repo = _CountingRepo(today(slept: true), throwing: true);
      final d = await HomeData.load(repo);
      expect(d.sleepStages, isNull);
      expect(d.sleepMin.value, 442);
    });
  });
}

class _CountingRepo extends LocalRepository {
  _CountingRepo(this._today, {this.throwing = false});
  final Map<String, dynamic> _today;
  final bool throwing;
  int nightReads = 0, insightReads = 0;

  @override
  Future<Map<String, dynamic>> getToday() async => _today;
  @override
  Future<Map<String, dynamic>> getInsights() async {
    insightReads++;
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    nightReads++;
    if (throwing) throw StateError('read failed');
    return {'has_sleep': true, 'deep_min': 70, 'rem_min': 95, 'light_min': 277};
  }
}
