// A day_result derived BEFORE `rmssd` became one estimator keeps what it was.
//
// Old bundles can hold a fallback `scalars.rmssd` (the NREM median or the
// whole-night value) beside an absent session envelope (`value: '—'`,
// confidence 0). Rows are immutable per version and only the last ~3 days
// re-derive after a bump, so most of a user's HRV history is such bundles for a
// long time. Serving the absent envelope's confidence 0 next to that value made
// Health's HRV row blank (`Metric.isEmpty` honours confidence) while the
// widget, the trends and the baselines still showed and used the number. Every
// consumer must agree: the retained value with the confidence it always had.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart' show HealthData;
import 'package:openstrap_edge/widget/widget_service.dart';

/// A pre-change bundle: rmssd fell back to the NREM median because the
/// session estimator abstained.
String _legacyBundle(String day, double rmssd) => jsonEncode({
      'date': day,
      'scalars': {'rmssd': rmssd, 'sdnn': 70.0},
      'sleep': {
        'accounting': {
          'value': {'tst_sec': 7 * 3600, 'efficiency_pct': 90.0},
        },
      },
      'clinical': {
        'rmssd_sleep_session': {
          'value': '—',
          'confidence': 0,
          'tier': 'HIGH',
          'inputs_used': ['rr_sleep_window'],
          'note': 'no valid 5-min windows for sleep-session RMSSD',
        },
        'rmssd_nocturnal': {'value': rmssd, 'confidence': 0.7, 'tier': 'HIGH'},
        'hrv_time': {
          'value': {'sdnn_ms': 70.0, 'n_beats': 25000},
          'confidence': 0.62,
          'tier': 'HIGH',
        },
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Object?> written;
  late LocalRepositoryImpl repo;
  // Calendar days, not 24 h steps: across a DST change "now ± n × 24 h" can
  // land on the wrong local date. One captured date, offsets by day number.
  final now = DateTime.now();
  String dayAt(int offset) =>
      dayLabelOf(DateTime(now.year, now.month, now.day + offset));
  final today = dayAt(0);
  final tomorrow = dayAt(1);

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_rmssd_legacy_bundle_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
    // Three older nights and today, all written by the previous algorithm.
    final values = [52.0, 50.0, 54.0, 48.3];
    for (var i = 0; i < values.length; i++) {
      final day = dayAt(i - (values.length - 1));
      await LocalDb.putDayResult(
        dayId: day,
        algoVersion: kAlgoVersion - 1,
        payloadJson: _legacyBundle(day, values[i]),
        windowJson: '{}',
        rmssd: values[i],
        source: 'band',
        series: {'rmssd': values[i]},
      );
    }
    await LocalDb.refreshComputeFreshness();
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  setUp(() {
    written = {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      if (call.method == 'saveWidgetData') {
        final args = (call.arguments as Map).cast<String, Object?>();
        written[args['id'] as String] = args['data'];
      }
      return true;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('openstrap/ios_config'), (call) async {
      return call.method == 'appGroupIdentifier' ? 'group.test' : null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('home_widget'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('openstrap/ios_config'), null);
  });

  test('every consumer serves the retained value, with its old confidence',
      () async {
    // Today: the value, and the confidence it was always served with.
    final t = TodayData.fromJson(await repo.getToday());
    expect(t.hrv, isNotNull);
    expect(t.hrv!.rmssd, 48.3);
    expect(t.hrv!.confidence, 0.62,
        reason: 'not the absent session envelope\'s 0');

    // Health: the HRV row honours confidence, so 0 blanked it.
    final health = await HealthData.load(repo);
    expect(health.hrv.isEmpty, isFalse);
    expect(health.hrv.value, 48.3);

    // Widget / Watch: the same number.
    await WidgetService.push(t);
    expect(written['hrv'], 48);

    // HRV detail and the trend chart read the stored scalar and series.
    final dayHrv = await repo.getDayHrv(today);
    expect(dayHrv['rmssd'], 48.3);
    // The envelope that says WHICH estimator that is travels with it, so
    // Investigate does not label it the 5-min-window mean.
    expect((dayHrv['rmssd_sleep_session'] as Map)['value'], '—');
    final points = (await repo.getChart('hrv'))['points'] as List;
    expect(points.whereType<Map>().any((pt) => pt.values.contains(48.3)),
        isTrue,
        reason: 'the stored series point is still drawn');

    // The baseline the next derive scores against keeps the old values.
    final window = (await debugSweepBaselineWindows('rmssd', [tomorrow])).single;
    expect(window, containsAll(<double>[52.0, 50.0, 54.0, 48.3]));
  });
}
