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

  test('a failed restore cannot inherit another install successful-import marker',
      () async {
    await wipeAll();
    await setPrefs({'theme_choice': 'dark'});
    final original = await LocalDb.exportCopy();
    await wipeAll();
    await LocalDb.importFromDbFile(original);
    final path = await LocalDb.exportCopy(); // contains the source's import marker
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    await copy.delete('backup_prefs');
    await copy.insert('backup_prefs',
        {'key': 'theme_choice', 'type': 'bool', 'value': 'invalid'});
    await copy.close();
    await wipeAll();
    await setPrefs({'theme_choice': 'system'});
    await expectLater(LocalDb.importFromDbFile(path), throwsFormatException);
    expect(await LocalDb.getCursor('backup_settings_imported'), isNull,
        reason: 'this phone has not successfully restored settings');
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
