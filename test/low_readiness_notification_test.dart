// "Low readiness" thresholds the readiness the user sees (metric_series
// 'readiness', the composite, or the morning pin for its day), not the
// deprecated glass-box score in the cross-day bundle. The two are different
// models and can sit on opposite sides of kLowReadiness (the ring's "Rest
// today" band) on the same morning.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String dir;
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_low_readiness_notif_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    NotificationIds.instance.resetForTest();
    shown.clear();
    NotificationCenter.instance.presentSink = (e,
        {bool allowPermissionPrompt = true}) async {
      shown.add(e);
      return true;
    };
  });

  tearDown(() async {
    NotificationCenter.instance.presentSink = original;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<void> seed({required double glassBox, required double readiness}) async {
    final today = todayLabel();
    await LocalDb.putBaseline(
      'crossday',
      jsonEncode({
        'recent': [
          {'date': today},
        ],
        'readiness_glassbox': {
          'value': {'score': glassBox},
        },
      }),
    );
    await LocalDb.putMetricSeriesValue(today, 'readiness', readiness);
    // The day itself exists: a pin is only read for a day that has a result.
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: '{}',
      windowJson: '{}',
    );
  }

  test('a low glass-box score under a normal ring does not buzz', () async {
    await seed(glassBox: 20, readiness: 70);
    await DerivationEngine().runNotificationsForTest();
    expect(shown, isEmpty);
  });

  test('a low ring buzzes even when the glass-box score is fine', () async {
    await seed(glassBox: 70, readiness: 20);
    await DerivationEngine().runNotificationsForTest();
    expect(shown, hasLength(1));
    expect(shown.single.title, contains('recovery'));
  });

  test('the morning pin wins over a drifted series value', () async {
    // Pin 30 (ring shows 30, "Take it easy"); a later re-derive drifted the
    // series to 24. Must not buzz.
    await seed(glassBox: 70, readiness: 24);
    await LocalDb.setFrozenHeadline(todayLabel(), 30);
    await DerivationEngine().runNotificationsForTest();
    expect(shown, isEmpty);
  });

  test('a low pin buzzes even after the series drifted above the line',
      () async {
    await seed(glassBox: 70, readiness: 40);
    await LocalDb.setFrozenHeadline(todayLabel(), 22);
    await DerivationEngine().runNotificationsForTest();
    expect(shown, hasLength(1));
  });
}
