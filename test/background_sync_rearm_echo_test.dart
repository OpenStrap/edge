// rearmHeadlessAlarm end to end on a fake WHOOP 4 link: the strap's instant
// SET_ALARM_TIME reply echoes the wake time, and the headless re-arm must
// persist the arm as confirmed without waiting for event 56. Pins the wiring
// from the engine's reply through armNextScheduledOccurrence to the prefs
// (the unit test of headlessArmAndConfirm alone passes a hand-made result).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart'
    show AlarmScheduleEntry, fillDefaultAlarmSchedule, nextAlarmOccurrence;
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_rearm_echo_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('an echoed wake time confirms the headless re-arm without event 56',
      () async {
    SharedPreferences.setMockInitialValues({});
    final db = await LocalDb.instance;
    await db.delete('alarm_schedule');
    for (var d = 0; d < 7; d++) {
      await db.insert('alarm_schedule', {
        'weekday': d,
        'hour': 7,
        'minute': 0,
        'enabled': 1,
        'smart_window_minutes': 0,
      });
    }
    final schedule = fillDefaultAlarmSchedule([
      for (final r in await LocalDb.alarmScheduleRows())
        AlarmScheduleEntry.fromRow(r),
    ]);
    final epoch =
        nextAlarmOccurrence(schedule, DateTime.now())!.millisecondsSinceEpoch ~/
            1000;

    final engine =
        BleEngine(onRecord: (_, _) async {}, onState: (_) {}, log: (_) {});
    engine.debugInstallFakeLink(
      band: proto.BandProfile.gen4,
      onWrite: (frame) async {
        final inner =
            proto.parseFrame(frame, profile: proto.BandProfile.gen4)!.inner;
        if (inner[2] == proto.Cmd.setAlarmTime) {
          final reply = proto.buildFrame(
            [
              0x24, 0x94, proto.Cmd.setAlarmTime, inner[1], 0x01, 0x01,
              epoch & 0xff, (epoch >> 8) & 0xff, (epoch >> 16) & 0xff,
              (epoch >> 24) & 0xff, 0x00, 0x00,
            ],
            profile: proto.BandProfile.gen4,
          );
          engine.debugProcessImmediateFrame(
              proto.parseFrame(reply, profile: proto.BandProfile.gen4)!);
        }
        return true;
      },
    );

    await rearmHeadlessAlarm(engine);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('alarm_epoch'), epoch);
    expect(prefs.getBool('alarm_epoch_confirmed'), isTrue,
        reason: 'the reply echoed the wake time; no 56 was ever delivered');
  });
}
