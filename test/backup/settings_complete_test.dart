// After a wipe and an import the owner has every setting back. These pin the
// gaps the audit found: backup.cadence swept up by a prefix, consent state half
// restored, and a coach key lost without a word.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

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
