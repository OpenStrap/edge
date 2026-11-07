import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup_support.dart';

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_paths_test.db'));
  tearDownAll(() async => env.dispose());

  test('automatic backups carry settings and gzip import restores them', () async {
    await env.wipe();
    await setPrefs({'theme_choice': 'dark', 'backup.cadence': 'weekly'});
    final backup = await runBackup(now: DateTime(2026, 9, 21));
    expect(backup.succeeded, isTrue, reason: backup.error);
    await env.wipe();
    await LocalDb.importFromDbFile(backup.path!);
    expect((await allPrefs())['theme_choice'], 'dark');
    expect((await allPrefs())['backup.cadence'], 'weekly');
  });

  test('an export for telemetry or support carries no settings or key signals', () async {
    await env.wipe();
    await setPrefs({'theme_choice': 'dark', 'coach_api_key_present': true});
    final String path;
    try {
      path = await Function.apply(LocalDb.exportCopy, [], {#includePrefs: false});
    } on NoSuchMethodError {
      fail('exportCopy must allow telemetry/support to omit preferences');
    }
    final tables = await tablesOf(path);
    expect(tables.where((t) => t.startsWith('backup_')), isEmpty);
    for (final file in ['lib/telemetry/health_uploader.dart', 'lib/support/issue_report.dart']) {
      expect(File(file).readAsStringSync(), contains('includePrefs: false'),
          reason: '$file must use the private export mode');
    }
  });

  test('older backups with no extras still import', () async {
    await env.wipe();
    await env.seedData();
    final path = await LocalDb.exportCopy();
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    for (final name in (await tablesOf(path)).where((t) => t.startsWith('backup_'))) {
      await copy.execute('DROP TABLE $name');
    }
    await copy.close();
    await env.wipe();
    await setPrefs({'theme_choice': 'light'});
    final counts = await LocalDb.importFromDbFile(path);
    expect(counts['decoded_onehz'], 30);
    expect((await allPrefs())['theme_choice'], 'light');
  });

  test('import reloads the live profile and synchronous preferences', () async {
    await env.wipe();
    await setPrefs({'local_profile_json': '{"name":"Backup Name"}',
      'ui.recap_range': 2});
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await Prefs.ensureLoaded();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await app.importEdgeBackup(path);
    expect(app.user?['name'], 'Backup Name');
    expect(Prefs.getInt('ui.recap_range', 0), 2);
  });

  test('a live theme reload adopts the imported choice without rewriting it', () async {
    await env.wipe();
    await setPrefs({'theme_choice': 'dark'});
    final path = await LocalDb.exportCopy();
    await env.wipe();
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light);
    addTearDown(theme.dispose);
    await LocalDb.importFromDbFile(path);
    try {
      await (theme as dynamic).reloadFromPrefs();
    } on NoSuchMethodError {
      fail('the live theme must be reloadable after importing settings');
    }
    expect(theme.choice, AppThemeChoice.dark);
    expect(theme.effective, Brightness.dark);
    expect((await allPrefs())['theme_choice'], 'dark');
  });
}
