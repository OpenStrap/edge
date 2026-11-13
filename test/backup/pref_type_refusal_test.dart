// A backup row whose stored type differs from how the app reads that key must
// be refused and reported, never written: the typed getter would throw on every
// later launch. Also: a custom coach server is reported when this phone saved
// the default address explicitly.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_pref_types_test.db'));
  tearDownAll(() async => env.dispose());

  Future<void> wipeAll() async {
    await env.wipe();
    FlutterSecureStorage.setMockInitialValues({});
  }

  /// Exports [prefs], then rewrites [retype] rows to another stored type.
  Future<String> exportRetyped(Map<String, Object> prefs,
      Map<String, (String, String)> retype) async {
    await wipeAll();
    await setPrefs(prefs);
    final path = await LocalDb.exportCopy();
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    for (final e in retype.entries) {
      await copy.update('backup_prefs', {'type': e.value.$1, 'value': e.value.$2},
          where: 'key = ?', whereArgs: [e.key]);
    }
    await copy.close();
    return path;
  }

  test('a profile stored as a bool is refused, not written, and does not throw',
      () async {
    final path = await exportRetyped(
        {'local_profile_json': '{"name":"Owner"}', 'backup.cadence': 'weekly'},
        {'local_profile_json': ('bool', 'true')});
    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    final now = await allPrefs();
    expect(now.containsKey('local_profile_json'), isFalse);
    expect(result.refusedPrefs, ['local_profile_json']);
    expect(result.keysWritten, isNot(contains('local_profile_json')));
    expect(now['backup.cadence'], 'weekly', reason: 'the rest still comes back');
  });

  test('an int setting stored as a double is refused', () async {
    final path = await exportRetyped({'notif_water_interval': 90},
        {'notif_water_interval': ('double', '90.0')});
    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    expect((await allPrefs()).containsKey('notif_water_interval'), isFalse);
    expect(result.refusedPrefs, ['notif_water_interval']);
  });

  test('a string list stored as a string is refused', () async {
    final path = await exportRetyped({'notif_relay_packages': ['a.b']},
        {'notif_relay_packages': ('string', 'a.b')});
    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    expect((await allPrefs()).containsKey('notif_relay_packages'), isFalse);
    expect(result.refusedPrefs, ['notif_relay_packages']);
  });

  test('a dated flag family member of the wrong type is refused', () async {
    final path = await exportRetyped({'notif_fired:2026-09-21:low_read': true},
        {'notif_fired:2026-09-21:low_read': ('string', 'yes')});
    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    expect(result.refusedPrefs, ['notif_fired:2026-09-21:low_read']);
  });

  test('rows of the right type, and keys the app never reads, restore as-is',
      () async {
    await wipeAll();
    await setPrefs({
      'local_profile_json': '{"name":"Owner"}', 'notif_water_interval': 90,
      'notif_relay_packages': ['a.b'], 'future.setting': 'also travels',
    });
    final path = await LocalDb.exportCopy();
    await wipeAll();
    final result = await LocalDb.importFromDbFile(path);
    expect(result.refusedPrefs, isEmpty);
    expect((await allPrefs())['notif_water_interval'], 90);
    expect((await allPrefs())['future.setting'], 'also travels');
  });

  Future<String> exportCustomServer() async {
    await wipeAll();
    await setPrefs({'coach_base_url': 'https://llm.example.net/v1'});
    return LocalDb.exportCopy();
  }

  test('a destination that saved the default server still needs re-entry',
      () async {
    final path = await exportCustomServer();
    await wipeAll();
    await setPrefs({'coach_base_url': ' https://api.openai.com/v1 '});
    final result = await LocalDb.importFromDbFile(path);
    expect(result, needsReentry(['coach_base_url']));
  });

  test('a destination with its own custom server is not asked again', () async {
    final path = await exportCustomServer();
    await wipeAll();
    await setPrefs({'coach_base_url': 'https://mine.example.net/v1'});
    final result = await LocalDb.importFromDbFile(path);
    expect(result.needsReentry, isEmpty);
  });
}
