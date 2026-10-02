// edge#333: the day's zone BARS and the zone timeline/footnote beside them
// must come off ONE zone set. The second derivation half used to recompute
// `zones` off the age estimate alone and overwrite the pipeline's, so a user
// with a measured ceiling got Tanaka bars under an "observed" footnote. This
// drives the real engine (runDays -> day_result), not `deriveDayBundle`, since
// the overwrite only ever happened in the coordinator.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

const _dayId = '2025-09-12'; // fixed, not `now`

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'day_zones_one_set_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  var seeded = false;
  Future<Map<String, dynamic>> derive(Profile profile) async {
    final db = await LocalDb.instance;
    if (seeded) {
      final done =
          await DerivationEngine().runDays(profile, {_dayId}, force: true);
      expect(done, 1);
      final row = await LocalDb.dayResult(_dayId);
      return SeriesCodec.decodePayloadJson(row!['payload_json'])!;
    }
    seeded = true;
    final night = (_sec(2025, 9, 11, 23, 0), _sec(2025, 9, 12, 6, 0));
    final wake = (_sec(2025, 9, 12, 8, 0), _sec(2025, 9, 12, 11, 0));
    final batch = db.batch();
    var counter = 0;
    for (final (from, to, hr) in [(night.$1, night.$2, 55), (wake.$1, wake.$2, 115)]) {
      for (var ts = from; ts < to; ts += 10) {
        batch.insert('decoded_onehz', {
          'device_id': LocalDb.kPrimaryDeviceId,
          'ts_ms': ts * 1000,
          'rec_ts': ts,
          'counter': counter++,
          'hr': hr,
          'ax': 0.0,
          'ay': 0.0,
          'az': 1.0,
          'device_family': 'gen4',
        });
      }
    }
    await batch.commit(noResult: true);
    for (final sig in const ['hr1Hz', 'rrIntervals']) {
      await db.insert('device_coverage', {
        'device_id': LocalDb.kPrimaryDeviceId,
        'signal': sig,
        'start_ts': night.$1,
        'end_ts': wake.$2,
      });
    }
    await LocalDb.putSleepOverride(
      dayId: _dayId,
      onsetTs: night.$1,
      offsetTs: night.$2,
      source: 'manual',
    );
    // A measured ceiling ABOVE the age line (30 -> 187), so the day's set is
    // the observed one. 115 bpm is Z1 on 200 (57.5 %) but Z2 on 187 (61.5 %).
    await LocalDb.putMetricSeriesValue('2025-09-10', 'hr_ceiling_bpm', 200);
    return derive(profile);
  }

  Map<String, int> timelineCounts(Map<String, dynamic> bundle) {
    final timeline = ((bundle['series'] as Map)['zone_timeline'] as List)
        .cast<Map>();
    expect(timeline, isNotEmpty);
    return {
      for (var z = 1; z <= 5; z++)
        'z$z': timeline.where((e) => e['z'] == z).length,
    };
  }

  test('day zone bars are binned on the same set as zone_timeline', () async {
    final bundle = await derive(const Profile(ageYears: 30));
    expect(bundle['zone_source'], 'observed');

    final fromTimeline = timelineCounts(bundle);
    final zones = (bundle['zones'] as Map).cast<String, dynamic>();
    expect(zones, fromTimeline,
        reason: 'bars and timeline are two views of one day on one set');
    expect(zones['z1'], greaterThan(0));
    expect(zones['z2'], 0, reason: '115 bpm is Z2 only on the age estimate');
  });

  // No age: the observed set needs none, so the bars must not go absent
  // asking for one while the timeline beside them is binned on that set.
  test('day zone bars do not need an age when the set does not', () async {
    final bundle = await derive(const Profile());
    expect(bundle['zone_source'], 'observed');
    final zones = (bundle['zones'] as Map).cast<String, dynamic>();
    expect(zones, timelineCounts(bundle));
    expect((bundle['absent_notes'] as Map?)?['zones'], isNull);
  });
}
