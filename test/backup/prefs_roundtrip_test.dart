// A full export carries the owner's settings (SharedPreferences), and an import
// restores them: into a fresh install the backup wins; into an install that
// already has data the device keeps what it has and only fills what is absent.
//
// RED: the export writes no backup_prefs table and the import restores none.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

/// Upstream settings plus future keys and every supported preference type.
const _settings = <String, Object>{
  'gesture_double_tap': 'mark_moment',
  'notif_quiet_enabled': true,
  'notif_water_interval': 90,
  'local_profile_json': '{"name":"Owner","weight_kg":72.5}',
  'notif_battery_pct': 15,
  'notif_fired:2026-09-21:low_read': true,
  'theme_choice': 'dark',
  'profile_weight': 72.5,
  'selected_sensors': <String>['one', 'two'],
  'future.setting': 'also travels',
};

const _denied = <String, Object>{
  'install_device_id': 'install-AAA',
  'paired_remote_id': 'AA:BB:CC:DD:EE:FF',
  'consent_telemetry': true,
  'backup.folder': 'content://tree/primary%3ABackups',
  'ble.ask_add_pending': true,
};

const _secrets = {
  'coach_api_key': 'sk-SECRET-COACH-12345',
  'oura_token': 'OURA-SECRET-67890',
};

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_prefs_test.db'));
  tearDownAll(() async => env.dispose());

  test('the denylist names a reason for every entry', () {
    final denied = policyMap('kPrefsNotBackedUp');
    for (final e in denied.entries) {
      expect(e.value, isNotEmpty, reason: e.key);
    }
    for (final k in _denied.keys) {
      expect(!denied.containsKey(k), isFalse, reason: k);
    }
    for (final k in _settings.keys) {
      expect(!denied.containsKey(k), isTrue, reason: k);
    }
  });

  test('export carries every settings key, no denylisted key, no secret',
      () async {
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues(Map.of(_secrets));
    await setPrefs({..._settings, ..._denied});
    await env.seedData();
    final path = await LocalDb.exportCopy();

    final got = await exportedPrefs(path);
    expect(got, isNotNull, reason: 'export has a backup_prefs table');
    expect(got!.keys.toSet(), _settings.keys.toSet());
    for (final k in _denied.keys) {
      expect(got.containsKey(k), isFalse, reason: '$k stays on the device');
    }
    expectNoSecretIn(path, _secrets.values);
    expect(got['notif_water_interval']!.$1, 'int');
    expect(got['notif_quiet_enabled']!.$1, 'bool');
    expect(got['gesture_double_tap']!.$1, 'string');
  });

  test('native string lists survive export and restore', () async {
    await env.wipe();
    // Method-channel decoding returns List<Object?>, even though every item
    // is a string. SharedPreferences.getStringList accepts this native shape.
    await setPrefs({'selected_sensors': <Object?>['one', 'two']});
    final sp = await SharedPreferences.getInstance();
    expect(sp.getStringList('selected_sensors'), ['one', 'two']);
    final path = await LocalDb.exportCopy();
    expect((await exportedPrefs(path))!['selected_sensors'],
        ('stringList', '["one","two"]'));
    await env.wipe();
    await LocalDb.importFromDbFile(path);
    expect((await allPrefs())['selected_sensors'], ['one', 'two']);
  });

  test('the live database never gains backup_* tables', () async {
    await env.wipe();
    await setPrefs(Map.of(_settings));
    await LocalDb.exportCopy();
    final db = await LocalDb.instance;
    final names = {
      for (final r in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'"))
        r['name'] as String,
    };
    expect(names.where((n) => n.startsWith('backup_')), isEmpty);
  });

  test('fresh install: every backed-up key comes back equal', () async {
    await env.wipe();
    await setPrefs({..._settings, ..._denied});
    await env.seedData();
    final path = await LocalDb.exportCopy();

    await env.wipe(); // a new phone
    await LocalDb.instance;
    await setPrefs({'install_device_id': 'install-BBB', 'theme_choice': 'light'});
    expect(await isFreshInstall(), isTrue);
    await LocalDb.importFromDbFile(path);

    final now = await allPrefs();
    for (final e in _settings.entries) {
      expect(now[e.key], e.value, reason: e.key);
    }
    expect(now['install_device_id'], 'install-BBB',
        reason: 'per-install ids are never restored');
    expect(now.containsKey('paired_remote_id'), isFalse);
    expect(now.containsKey('backup.folder'), isFalse);
  });

  test('install with data: device values win, absent keys are restored',
      () async {
    await env.wipe();
    await setPrefs(Map.of(_settings));
    await env.seedData();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    await env.seedData(t0: 1790100000); // not fresh
    await setPrefs({
      'notif_water_interval': 60, // differs from the backup's 90
      'notif_battery_pct': 30, // differs
    });
    expect(await isFreshInstall(), isFalse);
    await LocalDb.importFromDbFile(path);

    final now = await allPrefs();
    expect(now['notif_water_interval'], 60, reason: 'device value kept');
    expect(now['notif_battery_pct'], 30, reason: 'device value kept');
    expect(now['local_profile_json'], _settings['local_profile_json'],
        reason: 'absent here, so restored');
    expect(now['gesture_double_tap'], 'mark_moment');
    expect(now['notif_fired:2026-09-21:low_read'], true);
  });

  test('importing the same backup twice changes nothing', () async {
    await env.wipe();
    await setPrefs(Map.of(_settings));
    await env.seedData();
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.importFromDbFile(path);
    final once = await allPrefs();
    await LocalDb.importFromDbFile(path);
    expect(await allPrefs(), once);
    expect(once.keys.toSet(), _settings.keys.toSet());
    final sp = await SharedPreferences.getInstance();
    expect(sp.getInt('notif_water_interval'), 90);
  });
}
