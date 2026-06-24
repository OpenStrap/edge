// End-to-end LOCAL pipeline over the REAL storage layer: seed LocalDb.raw_records
// with the 550 whoop_hist frames, run LocalPipeline.computeAll() (decode + full
// analytics via the Rust FFI core), and assert the permanent derived store gets a
// daily/sleep/sessions bundle — and that retention prunes raw past the 14-day cutoff.
//
// Uses sqflite_common_ffi so LocalDb runs on the host Dart VM under `flutter test`.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/local/local_api_client.dart';
import 'package:openstrap_edge/local/local_pipeline.dart';
import 'package:openstrap_edge/native/native_core.dart';

void main() {
  final home = Platform.environment['HOME']!;
  final root = '$home/Documents/whoop-master';
  final dylib = '$root/openstrap-edge/rust/target/debug/libosc_edge.dylib';
  final hist = '$root/whoop_hist.jsonl';

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('computeAll: raw_records → decode → full analytics → derived store', () async {
    if (!File(dylib).existsSync()) {
      fail('build the glue first: cd openstrap-edge/rust && cargo build');
    }
    final core = NativeCore.open(libPath: dylib);

    // Seed raw_records with the 550 real R24 frames (captured "now" so they survive
    // the 14-day prune; their decoded ts_epoch sets the derived day).
    final now = DateTime.now().millisecondsSinceEpoch;
    final raws = <RawRecord>[];
    for (final line in File(hist).readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      if (rec['t'] != 24) continue;
      raws.add(RawRecord(counter: raws.length, packetType: 0x2F, hex: rec['hex'] as String, capturedAt: now));
    }
    expect(raws.length, greaterThan(500));
    await LocalDb.insertRecordsBatch(raws, List.filled(raws.length, null));
    expect((await LocalDb.counts())['raw'], raws.length);

    // Run the full on-device pipeline.
    final profile = {'age': 30, 'sex': 'm', 'height_cm': 178, 'weight_kg': 78};
    final written = await LocalPipeline(core, profile: profile).computeAll();
    expect(written, greaterThanOrEqualTo(1), reason: 'at least one physiological day derived');

    // The permanent derived store now holds the bundles.
    final dates = (await LocalDb.derivedDates()).toList()..sort();
    expect(dates, isNotEmpty);
    final day = dates.last;

    final daily = jsonDecode((await LocalDb.getDerived(day, 'daily'))!);
    final sleep = jsonDecode((await LocalDb.getDerived(day, 'sleep'))!);
    final sessions = jsonDecode((await LocalDb.getDerived(day, 'sessions'))!);
    final baseline = jsonDecode((await LocalDb.getDerived('_baseline', 'baselines'))!);

    expect(daily['strain'], isNotNull);
    expect(daily['hrv'], isNotNull);
    expect(daily['recovery'], isNotNull);
    expect(daily['readiness'], isNotNull); // cross-day pass ran
    expect(daily['cvhr'], isNotNull); // 1 Hz family ran (value may be null — honest)
    expect(sleep['sleep'], isNotNull);
    expect(sessions, isA<List>());
    expect(baseline['resting_hr'], isNotNull);

    // ignore: avoid_print
    print('E2E OK — day=$day strain=${daily['strain']['score']} '
        'rmssd=${daily['hrv']['rmssd']} recovery=${daily['recovery']['score']} '
        'baseline_rhr=${baseline['resting_hr']}');

    // Retention: raw captured "now" is inside the 14-day window → NOT pruned.
    expect((await LocalDb.counts())['raw'], raws.length,
        reason: 'recent raw stays; only raw older than 14 days is pruned');

    // ── (a) LocalApiClient serves the cloud envelopes from the derived store ──
    final lapi = LocalApiClient();
    final today = await lapi.getToday();
    expect(today['date'], day);
    expect(today['daily'], isNotNull);
    expect(today['daily']['strain'], isA<Map>()); // Metric<T> envelope
    expect(today['daily']['strain']['value'], isNotNull);
    expect(today['sleep'], isNotNull);

    final dayStrain = await lapi.getDayStrain(day);
    expect(dayStrain['strain'], isNotNull);
    expect(dayStrain['zones'], isA<Map>());
    expect(dayStrain['sessions'], isA<List>());

    final heart = await lapi.getDayHeart(day);
    expect(heart.containsKey('hrv'), isTrue);
    expect(heart['resting_hr'], isNotNull);

    final historyResp = await lapi.getHistory(range: '30d');
    expect(historyResp['series'], isA<Map>());
    expect((historyResp['series'] as Map)['strain'], isA<List>());

    final trend = await lapi.getTrend('strain', scale: 'month');
    expect(trend['buckets'], isA<List>());
    expect((trend['buckets'] as List), isNotEmpty);

    final workouts = await lapi.getWorkouts(range: 'month');
    expect(workouts['workouts'], isA<List>());
    expect(workouts['summary'], isA<Map>());

    // ignore: avoid_print
    print('LOCAL API OK — today.strain=${today['daily']['strain']['value']} '
        'history.strain_points=${(historyResp['series']['strain'] as List).length} '
        'trend.buckets=${(trend['buckets'] as List).length}');
  });
}
