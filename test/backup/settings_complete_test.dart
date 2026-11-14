// After a wipe and an import the owner has every setting back. These pin the
// gaps the audit found: backup.cadence swept up by a prefix, consent state half
// restored, and a coach key lost without a word.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// The secure-storage plugin exposes its platform test seam in this dependency.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/live.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

import 'backup_support.dart';

class _ReadKeychain extends TestFlutterSecureStoragePlatform {
  _ReadKeychain(this.readKey) : super({});
  final Future<String?> Function() readKey;
  @override
  Future<String?> read({required String key,
      required Map<String, String> options}) => readKey();
}

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_complete_test.db'));
  tearDownAll(() async => env.dispose());

  Future<void> wipeAll() async {
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
  }

  for (final withPrefs in [false, true]) {
    test('AppState reloads and arms an imported weekday with prefs=$withPrefs',
        () async {
      await wipeAll();
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1, 7, 15);
      final weekday = tomorrow.weekday - 1;
      await LocalDb.setAlarmScheduleDay(weekday: weekday, hour: 7, minute: 15,
          enabled: true, smartWindowMinutes: 20);
      if (withPrefs) await setPrefs({'theme_choice': 'dark'});
      final path = await LocalDb.exportCopy();
      if (!withPrefs) {
        final copy = await databaseFactoryFfi.openDatabase(path,
            options: OpenDatabaseOptions(singleInstance: false));
        await copy.execute('DROP TABLE backup_prefs');
        await copy.execute('DROP TABLE backup_secrets');
        await copy.close();
      }
      await wipeAll();
      final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      final writes = <int>[];
      engine.debugInstallFakeLink(band: proto.BandProfile.gen4,
          onWrite: (bytes) async {
        final inner = proto.parseFrame(bytes, profile: proto.BandProfile.gen4)!.inner;
        if (inner[2] == proto.Cmd.setAlarmTime) {
          writes.add(inner[2]);
          final reply = proto.buildFrame([
            0x24, 0x94, proto.Cmd.setAlarmTime, inner[1], 0x01,
            proto.AlarmStatus.validInputPattern,
          ], profile: proto.BandProfile.gen4);
          engine.debugProcessImmediateFrame(
              proto.parseFrame(reply, profile: proto.BandProfile.gen4)!);
        }
        return true;
      });
      final app = AppState.forTesting(engine: engine);
      addTearDown(app.dispose);
      app.device.connection = 'connected';
      expect(app.alarmSchedule[weekday].enabled, isFalse);
      await app.importEdgeBackup(path);
      expect(app.alarmSchedule[weekday], AlarmScheduleEntry(weekday: weekday,
          hour: 7, minute: 15, smartWindowMinutes: 20));
      expect(writes, [proto.Cmd.setAlarmTime]);
      expect(app.alarmEpoch, tomorrow.millisecondsSinceEpoch ~/ 1000);
      expect((await allPrefs())['alarm_epoch'], tomorrow.millisecondsSinceEpoch ~/ 1000);
      // A repeated import goes through normal arm deduplication.
      await app.importEdgeBackup(path);
      expect(writes, [proto.Cmd.setAlarmTime]);
    });
  }

  group('Cancel-all survives an import', () {
    late BleEngine engine;
    late List<int> writes;
    late AppState app;

    Future<void> connect() async {
      engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      writes = [];
      engine.debugInstallFakeLink(band: proto.BandProfile.gen4,
          onWrite: (bytes) async {
        final inner = proto.parseFrame(bytes, profile: proto.BandProfile.gen4)!.inner;
        if (inner[2] == proto.Cmd.setAlarmTime) {
          writes.add(inner[2]);
          final reply = proto.buildFrame([
            0x24, 0x94, proto.Cmd.setAlarmTime, inner[1], 0x01,
            proto.AlarmStatus.validInputPattern,
          ], profile: proto.BandProfile.gen4);
          engine.debugProcessImmediateFrame(
              proto.parseFrame(reply, profile: proto.BandProfile.gen4)!);
        } else if (inner[2] == proto.Cmd.disableAlarm) {
          final reply = proto.buildFrame(
              [0x24, 0x94, proto.Cmd.disableAlarm, inner[1], 0x01, 0x00],
              profile: proto.BandProfile.gen4);
          engine.debugProcessImmediateFrame(
              proto.parseFrame(reply, profile: proto.BandProfile.gen4)!);
        }
        return true;
      });
      app = AppState.forTesting(engine: engine);
      addTearDown(app.dispose);
      app.device.connection = 'connected';
    }

    // A schedule exported, then cancelled on a install that has data.
    Future<String> exportThenCancel() async {
      await wipeAll();
      await env.seedData();
      await LocalDb.setAlarmScheduleDay(
          weekday: 2, hour: 7, minute: 15, enabled: true);
      final path = await LocalDb.exportCopy();
      await connect();
      await app.disableAlarm();
      expect(await LocalDb.alarmScheduleRows(), isEmpty);
      writes.clear();
      return path;
    }

    test('an import does not bring a cancelled schedule back', () async {
      final path = await exportThenCancel();
      await app.importEdgeBackup(path);
      expect(await LocalDb.alarmScheduleRows(), isEmpty);
      expect(app.alarmSchedule.where((e) => e.enabled), isEmpty);
      expect(writes, isEmpty, reason: 'nothing re-arms the band');
    });

    test('configuring a weekday after Cancel-all lets a later import fill '
        'absent slots again', () async {
      final path = await exportThenCancel();
      await app.setScheduleDay(weekday: 4, hour: 6, minute: 0, enabled: true);
      await app.importEdgeBackup(path);
      final byDay = {
        for (final r in await LocalDb.alarmScheduleRows()) r['weekday']: r,
      };
      expect(byDay.keys.toSet(), {2, 4});
      expect(byDay[2]!['enabled'], 1);
      expect(byDay[4]!['hour'], 6, reason: 'the local row still wins');
    });

    test('a fresh install still restores the schedule', () async {
      await wipeAll();
      await LocalDb.setAlarmScheduleDay(
          weekday: 2, hour: 7, minute: 15, enabled: true);
      final path = await LocalDb.exportCopy();
      await wipeAll();
      await LocalDb.importFromDbFile(path);
      expect(await LocalDb.alarmScheduleRows(), hasLength(1));
    });

    test('the cancel marker is device state: it is not exported', () async {
      final path = await exportThenCancel();
      expect((await exportedPrefs(path))!.keys, isNot(contains('alarm_schedule_cleared')));
      await wipeAll();
      await setPrefs({'alarm_schedule_cleared': true});
      final out = await LocalDb.exportCopy();
      expect((await exportedPrefs(out))?.keys ?? <String>[],
          isNot(contains('alarm_schedule_cleared')));
    });
  });

  test('a DB-only alarm restore establishes settings before a later import',
      () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark', 'backup.cadence': 'weekly'});
    final settings = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.setAlarmScheduleDay(weekday: 2, hour: 7, minute: 15, enabled: true);
    final old = await LocalDb.exportCopy();
    final copy = await databaseFactoryFfi.openDatabase(old,
        options: OpenDatabaseOptions(singleInstance: false));
    await copy.execute('DROP TABLE backup_prefs');
    await copy.execute('DROP TABLE backup_secrets');
    await copy.close();
    await wipeAll();
    await LocalDb.importFromDbFile(old);
    expect(await LocalDb.alarmScheduleRows(), hasLength(1));
    await setPrefs({'theme_choice': 'light'});
    final result = await LocalDb.importFromDbFile(settings);
    expect((await allPrefs())['theme_choice'], 'light');
    expect((await allPrefs())['backup.cadence'], 'weekly');
    expect(result.keysWritten, {'backup.cadence'});
  });

  for (final entry in <String, Map<String, Object>>{
    'journal_metric': {'date': '2026-09-21', 'field': 'water', 'value': 250, 'updated_at': 1},
    'cycle_symptom': {'date': '2026-09-21', 'symptoms_json': '["cramps"]', 'updated_at': 1},
    'sleep_override': {'day_id': '2026-09-21', 'onset_ts': 1790000000,
      'offset_ts': 1790028800, 'source': 'manual', 'created_at': 1},
    'step_calibration': {'device_family': 'whoop', 'wearing': 0, 'factor': 1.1,
      'n_days': 3, 'version': 1, 'updated_ts': 1},
    'med_def': {'key': 'vitamin', 'label': 'Vitamin', 'schedule_json': '[480]',
      'created_at': 1},
  }.entries) {
    test('${entry.key} alone protects existing settings from import', () async {
      await wipeAll();
      await setPrefs({'theme_choice': 'dark', 'backup.cadence': 'weekly'});
      final path = await LocalDb.exportCopy();
      await wipeAll();
      await (await LocalDb.instance).insert(entry.key, entry.value);
      await setPrefs({'theme_choice': 'light'});
      final result = await LocalDb.importFromDbFile(path);
      expect((await allPrefs())['theme_choice'], 'light');
      expect(result.keysWritten, {'backup.cadence'});
    });
  }

  for (final blank in ['', '   ']) {
    test('a blank coach server needs re-entry: "$blank"', () async {
      await wipeAll();
      await setPrefs({'coach_base_url': 'https://old.example.net/v1'});
      final path = await LocalDb.exportCopy();
      await wipeAll();
      await setPrefs({'coach_base_url': blank});
      final result = await LocalDb.importFromDbFile(path);
      expect(result.needsReentry, ['coach_base_url']);
      expect((await allPrefs())['coach_base_url'], blank);
    });
  }

  test('ChatGPT exports only presence and requests sign-in on a new phone',
      () async {
    await wipeAll();
    FlutterSecureStorage.setMockInitialValues({'coach_chatgpt_session': 'SECRET-SESSION'});
    await setPrefs({'coach_chatgpt_present': true, 'coach_use_chatgpt': true});
    final path = await LocalDb.exportCopy();
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    final markers = await copy.query('backup_secrets');
    await copy.close();
    expect(markers, [{'key': 'coach_chatgpt'}]);
    expect((await exportedPrefs(path))!.keys, ['coach_use_chatgpt']);
    expectNoSecretIn(path, ['SECRET-SESSION']);
    await wipeAll();
    expect((await LocalDb.importFromDbFile(path)).needsReentry, ['coach_chatgpt']);
    expect(await allPrefs(), {'coach_use_chatgpt': true});
    await setPrefs({'coach_chatgpt_present': true});
    expect((await LocalDb.importFromDbFile(path)).needsReentry, isEmpty);
    await wipeAll();
    final never = await LocalDb.exportCopy();
    expect((await LocalDb.importFromDbFile(never)).needsReentry, isEmpty);
  });

  test('the auto-backup cadence the owner chose comes back; device state stays',
      () async {
    await wipeAll();
    await setPrefs({
      'backup.cadence': 'weekly',
      'backup.folder': 'content://x',
      'backup.last_run_ms': 5,
      'backup.last_error': 'boom',
    });
    await env.seedData();
    final path = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now['backup.cadence'], 'weekly');
    expect(now.containsKey('backup.folder'), isFalse);
    expect(now.containsKey('backup.last_run_ms'), isFalse);
    expect(now.containsKey('backup.last_error'), isFalse);
  });

  test('hand-entered history also preserves the device settings', () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark', 'backup.cadence': 'weekly'});
    final path = await LocalDb.exportCopy();
    await wipeAll();
    final db = await LocalDb.instance;
    await db.insert('journal', {'date': '2026-09-21', 'updated_at': 1});
    await setPrefs({'theme_choice': 'light'});
    await LocalDb.importFromDbFile(path);
    expect(await allPrefs(), {'theme_choice': 'light', 'backup.cadence': 'weekly'});
  });

  test('set up without history: device values win and absent keys restore',
      () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark', 'backup.cadence': 'weekly'});
    final path = await LocalDb.exportCopy();
    for (final setup in <Map<String, Object>>[
      {'onboard.completed': true},
      {'onboarding_choice': 'new'},
      {'local_profile_json': '{"name":"Owner"}'},
    ]) {
      await wipeAll();
      await setPrefs({...setup, 'theme_choice': 'light'});
      final result = await LocalDb.importFromDbFile(path);
      expect((await allPrefs())['theme_choice'], 'light', reason: '$setup');
      expect((await allPrefs())['backup.cadence'], 'weekly');
      expect(result.keysWritten, {'backup.cadence'});
    }
  });

  test('a successful settings-only import protects subsequent device edits',
      () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark', 'backup.cadence': 'weekly'});
    final path = await LocalDb.exportCopy();
    await wipeAll();
    // True first run, including startup defaults: the backup wins all keys.
    await setPrefs({'theme_choice': 'system', 'backup.cadence': 'daily'});
    final first = await LocalDb.importFromDbFile(path);
    expect(first.keysWritten, {'theme_choice', 'backup.cadence'});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_choice', 'light');
    await prefs.remove('backup.cadence');
    await LocalDb.close(); // the import marker must outlive a process/DB reopen
    final second = await LocalDb.importFromDbFile(path);
    expect((await allPrefs())['theme_choice'], 'light');
    expect((await allPrefs())['backup.cadence'], 'weekly');
    expect(second.keysWritten, {'backup.cadence'});
  });

  test('a backup without settings cannot hand this phone its import marker',
      () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark'});
    final original = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.importFromDbFile(original);
    final path = await LocalDb.exportCopy(); // contains the source's import marker
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    await copy.execute('DROP TABLE backup_prefs');
    await copy.close();
    await wipeAll();
    await LocalDb.importFromDbFile(path);
    expect(await LocalDb.getCursor('backup_settings_imported'), isNull,
        reason: 'this phone has not restored settings');
  });

  test('a malformed setting is skipped and counted; the rest still come back',
      () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark', 'backup.cadence': 'weekly'});
    final path = await LocalDb.exportCopy();
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    await copy.update('backup_prefs', {'type': 'bool', 'value': 'invalid'},
        where: 'key = ?', whereArgs: ['theme_choice']);
    await copy.close();
    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now.containsKey('theme_choice'), isFalse);
    expect(now['backup.cadence'], 'weekly');
    expect(result.refusedPrefs, ['theme_choice']);
    expect(result.keysWritten, contains('backup.cadence'));
  });

  test('a live setting of the wrong type is refused and reported, not counted',
      () async {
    await wipeAll();
    await setPrefs({'clock_format': true, 'backup.cadence': 'weekly'});
    final path = await LocalDb.exportCopy();
    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now.containsKey('clock_format'), isFalse);
    expect(result.refusedPrefs, ['clock_format']);
    expect(result.keysWritten, isNot(contains('clock_format')));
    expect(now['backup.cadence'], 'weekly');
  });

  test('a restored schedule writes its next alarm to the new band', () async {
    await wipeAll();
    final now = DateTime(2026, 10, 20, 22);
    final next = DateTime(2026, 10, 21, 7);
    final epoch = next.millisecondsSinceEpoch ~/ 1000;
    await LocalDb.setAlarmScheduleDay(weekday: 2, hour: 7, minute: 0,
        enabled: true, smartWindowMinutes: 20);
    await setPrefs({
      'alarm_epoch': epoch,
      // CLAIM(alarm-band-ownership): a BLE receipt cannot travel to another phone.
      // catches: exporting the owner while correctly excluding the armed epoch.
      'alarm_remote_id': 'old-phone-band',
      'alarm_epoch_confirmed': true,
      'alarm_set_at_ms': now.millisecondsSinceEpoch,
      'alarm_pending_until': ['$epoch', '${next.millisecondsSinceEpoch}'],
      'alarm_latch_alert': ['$epoch', '1'],
      'alarm_probe_pending': true,
      'alarm_fired_at': epoch - 86400,
    });
    final path = await LocalDb.exportCopy();
    // Keep the restore-merge assertion separate from the arm dedupe regression.
    final backedUp = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    final schedule = [for (final r in await backedUp.query('alarm_schedule'))
      AlarmScheduleEntry.fromRow(r)];
    await backedUp.close();
    await wipeAll();
    await LocalDb.importFromDbFile(path);
    final restoredSchedule = [for (final r in await LocalDb.alarmScheduleRows())
      AlarmScheduleEntry.fromRow(r)];
    expect(schedule, [const AlarmScheduleEntry(weekday: 2, hour: 7, minute: 0,
        smartWindowMinutes: 20)]);
    final prefs = await SharedPreferences.getInstance();
    final writes = <int>[];
    final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugInstallFakeLink(band: proto.BandProfile.gen4,
        onWrite: (bytes) async {
      final inner = proto.parseFrame(bytes, profile: proto.BandProfile.gen4)!.inner;
      if (inner[2] == proto.Cmd.setAlarmTime) {
        writes.add(inner[2]);
        final reply = proto.buildFrame([
          0x24, 0x94, proto.Cmd.setAlarmTime, inner[1], 0x01,
          proto.AlarmStatus.validInputPattern,
        ], profile: proto.BandProfile.gen4);
        engine.debugProcessImmediateFrame(
            proto.parseFrame(reply, profile: proto.BandProfile.gen4)!);
      }
      return true;
    });
    final armed = await armNextScheduledOccurrence(engine: engine,
        schedule: restoredSchedule, currentArmedEpoch: prefs.getInt('alarm_epoch'), now: now);
    expect(writes, [proto.Cmd.setAlarmTime], reason: 'the new band needs an arm');
    expect(armed.epoch, epoch);
    expect(armed.failed, isFalse);
    expect(restoredSchedule, schedule, reason: 'the schedule must be restored too');
    expect((await allPrefs()).keys.where((k) => k.startsWith('alarm_')), isEmpty);
  });

  test('restored alarm weekdays fill gaps and keep this phone configuration',
      () async {
    await wipeAll();
    await LocalDb.setAlarmScheduleDay(weekday: 0, hour: 7, minute: 0, enabled: true);
    await LocalDb.setAlarmScheduleDay(weekday: 1, hour: 8, minute: 15, enabled: true);
    final path = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.setAlarmScheduleDay(weekday: 0, hour: 9, minute: 30, enabled: false);
    await LocalDb.importFromDbFile(path);
    final restored = [for (final r in await LocalDb.alarmScheduleRows())
      AlarmScheduleEntry.fromRow(r)];
    expect(restored, [
      const AlarmScheduleEntry(weekday: 0, hour: 9, minute: 30, enabled: false),
      const AlarmScheduleEntry(weekday: 1, hour: 8, minute: 15),
    ]);
    await LocalDb.importFromDbFile(path);
    expect([for (final r in await LocalDb.alarmScheduleRows())
      AlarmScheduleEntry.fromRow(r)], restored);
  });

  test('export during a private workout leaves drafts and recovery state local',
      () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark',
      'live_session_checkpoint': '{"runs":[[1790000000,1790000060,123]]}',
      'telemetry_outbox': '[{"message":"pending private diagnostics"}]',
    });
    await Prefs.reload();
    final draft = LiveDraft.begin(activityByName('running')!, private: true);
    addTearDown(LiveDraft.debugForget);
    draft.put('private_note', 'PRIVATE-WORKOUT-ENTRY');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('live.session_draft'), contains('PRIVATE-WORKOUT-ENTRY'));
    final path = await LocalDb.exportCopy();
    expect((await exportedPrefs(path))!.keys, ['theme_choice']);
    expectNoSecretIn(path, ['PRIVATE-WORKOUT-ENTRY', 'pending private diagnostics']);
    // Taking a backup must leave the running session intact on this phone.
    expect(LiveDraft.current!.private, isTrue);
    expect(LiveDraft.current!.data['private_note'], 'PRIVATE-WORKOUT-ENTRY');
    LiveDraft.debugForget();
    await wipeAll();
    await Prefs.reload();
    await LocalDb.importFromDbFile(path);
    await Prefs.reload();
    expect(LiveDraft.current, isNull);
    expect(await allPrefs(), {'theme_choice': 'dark'});
    LiveDraft.debugForget();
  });

  test('consent is asked again as a whole: no half-restored consent state',
      () async {
    await wipeAll();
    await setPrefs({
      'consent_telemetry': true,
      'consent_health_data': true,
      'consent_chosen': true,
    });
    await env.seedData();
    final path = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now.keys.where((k) => k.startsWith('consent_')), isEmpty);
  });

  test('a coach key that cannot travel is reported for re-entry, never hidden',
      () async {
    await wipeAll();
    FlutterSecureStorage.setMockInitialValues({'coach_api_key': 'sk-SECRET'});
    await setPrefs({'coach_api_key_present': true, 'coach_model': 'm'});
    await env.seedData();
    final path = await LocalDb.exportCopy();
    expectNoSecretIn(path, ['sk-SECRET']);

    await wipeAll(); // the new phone has no keychain payload
    final result = await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now['coach_model'], 'm');
    expect(now.containsKey('coach_api_key_present'), isFalse,
        reason: 'the marker would claim a key this phone does not hold');
    expect(result, needsReentry(['coach_api_key']));
  });

  test('a custom coach server does not travel and is reported for re-entry',
      () async {
    await wipeAll();
    const server = 'https://llm.example.net/v1?key=sk-IN-THE-URL';
    await setPrefs({'coach_base_url': server, 'coach_model': 'm'});
    await env.seedData();
    final path = await LocalDb.exportCopy();
    expectNoSecretIn(path, ['sk-IN-THE-URL', 'llm.example.net']);

    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now['coach_model'], 'm');
    expect(now.containsKey('coach_base_url'), isFalse);
    expect(result.needsReentry, ['coach_base_url']);
  });

  test('the default coach server asks for nothing after import', () async {
    await wipeAll();
    await setPrefs({'coach_base_url': 'https://api.openai.com/v1'});
    final path = await LocalDb.exportCopy();
    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    expect(result.needsReentry, isEmpty);
  });

  test('a server already set on this phone is not asked for again', () async {
    await wipeAll();
    await setPrefs({'coach_base_url': 'https://old.example.net/v1'});
    final path = await LocalDb.exportCopy();
    await wipeAll();
    await setPrefs({'coach_base_url': 'https://new.example.net/v1'});
    final result = await LocalDb.importFromDbFile(path);
    expect((await allPrefs())['coach_base_url'], 'https://new.example.net/v1');
    expect(result.needsReentry, isEmpty);
  });

  test('an unreadable coach key is not reported as missing, and can be retried',
      () async {
    await wipeAll();
    await setPrefs({'coach_api_key_present': true});
    final path = await LocalDb.exportCopy();
    await wipeAll();
    FlutterSecureStoragePlatform.instance = _ReadKeychain(() async {
      throw PlatformException(code: 'keychain_locked');
    });
    addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
    final failed = await LocalDb.importFromDbFile(path);
    expect(failed.needsReentry, isEmpty, reason: 'a failed read proves no absence');
    expect(failed.unreadableSecrets, ['coach_api_key']);
    FlutterSecureStorage.setMockInitialValues({'coach_api_key': ''});
    final empty = await LocalDb.importFromDbFile(path);
    expect(empty.needsReentry, ['coach_api_key']);
    expect(empty.unreadableSecrets, isEmpty);
    FlutterSecureStorage.setMockInitialValues({'coach_api_key': 'sk-on-this-phone'});
    final retried = await LocalDb.importFromDbFile(path);
    expect(retried.needsReentry, isEmpty);
    expect(retried.unreadableSecrets, isEmpty);
  });

  test('a timed-out coach key read is not reported as missing', () async {
    await wipeAll();
    await setPrefs({'coach_api_key_present': true});
    final path = await LocalDb.exportCopy();
    await wipeAll();
    final read = Completer<String?>();
    FlutterSecureStoragePlatform.instance = _ReadKeychain(() => read.future);
    addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
    final time = FakeAsync();
    final timeoutReady = Completer<void>();
    final result = runZoned(() => LocalDb.importFromDbFile(path),
        zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone,
            duration, callback) {
      if (duration == const Duration(seconds: 6)) {
        final timer = time.run((_) => Timer(duration, callback));
        timeoutReady.complete();
        return timer;
      }
      return parent.createTimer(zone, duration, callback);
    }));
    await timeoutReady.future;
    time.elapse(const Duration(seconds: 6));
    final timedOut = await result;
    expect(timedOut.needsReentry, isEmpty, reason: 'timeout is not an empty key');
    expect(timedOut.unreadableSecrets, ['coach_api_key']);
    read.complete('sk-still-on-this-phone');
  });

  test('ChatGPT credentials and phone registration stay on the phone', () async {
    await wipeAll();
    FlutterSecureStorage.setMockInitialValues({'coach_chatgpt_session': 'SECRET-SESSION'});
    await setPrefs({
      'coach_use_chatgpt': true,
      'coach_chatgpt_present': true,
      'coach_chatgpt_client_id': 'client-old',
      'coach_chatgpt_host_id': 'host-old',
      'coach_chatgpt_welcomed': true,
    });
    final path = await LocalDb.exportCopy();
    expect((await exportedPrefs(path))!.keys, ['coach_use_chatgpt']);
    expectNoSecretIn(path, ['SECRET-SESSION', 'client-old', 'host-old']);
    await wipeAll();
    await LocalDb.importFromDbFile(path);
    expect(await allPrefs(), {'coach_use_chatgpt': true});
  });

  test('a foreign backup cannot restore consent or a keychain marker', () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark'});
    final path = await LocalDb.exportCopy();
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    for (final key in ['consent_chosen', 'consent_telemetry',
        'consent_health_data', 'coach_api_key_present']) {
      await copy.insert('backup_prefs', {'key': key, 'type': 'bool', 'value': 'true'});
    }
    await copy.close();
    await wipeAll();
    await LocalDb.importFromDbFile(path);
    expect(await allPrefs(), {'theme_choice': 'dark'});
  });

  test('no re-entry is reported when the key is already on this phone or never set',
      () async {
    await wipeAll();
    await setPrefs({'coach_model': 'm'});
    await env.seedData();
    final never = await LocalDb.exportCopy();
    await wipeAll();
    expect(await LocalDb.importFromDbFile(never), needsReentry([]));

    await wipeAll();
    FlutterSecureStorage.setMockInitialValues({'coach_api_key': 'sk-1'});
    await setPrefs({'coach_api_key_present': true});
    await env.seedData();
    final had = await LocalDb.exportCopy();
    await wipeAll();
    FlutterSecureStorage.setMockInitialValues({'coach_api_key': 'sk-1'});
    expect(await LocalDb.importFromDbFile(had), needsReentry([]));
  });
}
