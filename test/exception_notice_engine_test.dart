// The health-exception push through the real `_runNotifications`: the
// overnight detectors' verdict is dated by the night it is about, a night
// buzzes once however many passes see it, and history does not interrupt.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
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
  // One fixed clock for the seed AND the pass: labels taken from the real
  // clock at load time go stale if the run crosses midnight.
  const today = '2026-03-10';
  final yesterday = dayLabelBefore(today, 1)!;
  Future<void> runPass() =>
      DerivationEngine().runNotificationsForTest(today: today);

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_exception_notice_engine_test.db';
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

  // Today is still settling; the newest settled night carries the verdict.
  Future<void> seed({required String illnessDate}) => LocalDb.putBaseline(
        'crossday',
        jsonEncode({
          'illness': {'date': illnessDate, 'state': 'red'},
          'recent': [
            {'date': today, 'unsettled': true},
          ],
        }),
      );

  test("yesterday's red night buzzes, dated and keyed by that night", () async {
    await seed(illnessDate: yesterday);
    await runPass();
    expect(shown, hasLength(1));
    expect(shown.single.date, yesterday);
    expect(shown.single.dedupeKey, '$yesterday:exception:medical');
  });

  test('the same night does not buzz twice', () async {
    await seed(illnessDate: yesterday);
    await runPass();
    await runPass();
    expect(shown, hasLength(1));
  });

  test('a red night two days back is history', () async {
    await seed(illnessDate: dayLabelBefore(today, 2)!);
    await runPass();
    expect(shown, isEmpty);
  });
}
