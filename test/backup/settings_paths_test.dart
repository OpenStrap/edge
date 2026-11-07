import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/support/issue_report.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup_support.dart';

// Only the platform availability/permission is faked; settings and the pending
// notification run through the real relay.
class _AndroidRelay extends NotificationRelay {
  _AndroidRelay({required super.buzz, required super.quietNow})
      : super(isConnected: () => true);
  @override
  bool get supported => true;
  @override
  Future<bool> refreshPermission() async => false;
}

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
    final path = await LocalDb.exportCopy(includePrefs: false);
    final tables = await tablesOf(path);
    expect(tables.where((t) => t.startsWith('backup_')), isEmpty);
    // The uploader is compile-time gated and requires battery/Wi-Fi plugins.
    expect(File('lib/telemetry/health_uploader.dart').readAsStringSync(),
        contains('includePrefs: false'));
  });

  test('a full support report contains no backup settings or key signals', () async {
    await env.wipe();
    await setPrefs({'theme_choice': 'dark', 'coach_api_key_present': true});
    final personal = await LocalDb.exportCopy();
    expect((await exportedPrefs(personal))!['theme_choice'], ('string', 'dark'));
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final report = await collectReport(app, const ReportDraft(
      category: ReportCategory.sync, title: 'Sync', description: 'Details',
      fullDatabase: true,
    ));
    final zip = ZipDecoder().decodeBytes(await report.zip.readAsBytes());
    final payload = zip.files.singleWhere((f) => f.name == 'database.db.gz');
    final db = File('${env.root.path}/support.db');
    await db.writeAsBytes(gzip.decode(payload.content as List<int>));
    expect((await tablesOf(db.path)).where((t) => t.startsWith('backup_')), isEmpty);
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

  test('the import report receives settings counts and coach re-entry', () async {
    await env.wipe();
    await setPrefs({'coach_model': 'm', 'coach_api_key_present': true,
      'onboarding_choice': 'existing'});
    final path = await LocalDb.exportCopy();
    await env.wipe();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.initialized = true;
    final result = await runImport(app, [path]);
    expect(app.route, AppRoute.welcome,
        reason: 'restored onboarding prefs must not hide the import report');
    expect(await settleOnboardImport(app, result), isTrue);
    expect(result.needsReentry, ['coach_api_key']);
    expect(result.prefsRestored, 2);
    expect(result.nothingLanded, isFalse);
    expect(result.needsReading, isTrue);
    await app.completeImportOnboard();
    expect(app.route, AppRoute.pairing);
  });

  test('relay reload adopts imported apps and cancels a pending buzz', () async {
    await env.wipe();
    var buzzes = 0;
    final quiet = Completer<bool>();
    final relay = _AndroidRelay(buzz: () async { buzzes++; },
        quietNow: () => quiet.future);
    addTearDown(relay.dispose);
    relay.packages.add('com.chat');
    relay.debugOnNotification(ServiceNotificationEvent(
      id: 1, title: '', content: '', packageName: 'com.chat',
      canReply: false, haveExtraPicture: false, hasRemoved: false,
      onGoing: false, timestamp: 0,
      appIcon: null, extrasPicture: null, largeIcon: null,
    ));
    await setPrefs({'notif_relay_enabled': false,
      'notif_relay_packages': <String>['com.chat', 'com.mail']});
    await relay.reloadFromPrefs();
    expect(relay.enabled, isFalse);
    expect(relay.packages, {'com.chat', 'com.mail'});
    expect(relay.seenPackages, ['com.chat', 'com.mail']);
    quiet.complete(false);
    await Future<void>.value();
    expect(buzzes, 0);
  });

  test('a live theme reload adopts the imported choice without rewriting it', () async {
    await env.wipe();
    await setPrefs({'theme_choice': 'dark'});
    final path = await LocalDb.exportCopy();
    await env.wipe();
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light);
    addTearDown(theme.dispose);
    await LocalDb.importFromDbFile(path);
    await theme.reloadFromPrefs();
    expect(theme.choice, AppThemeChoice.dark);
    expect(theme.effective, Brightness.dark);
    expect((await allPrefs())['theme_choice'], 'dark');
  });
}
