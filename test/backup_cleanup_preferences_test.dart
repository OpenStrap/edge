import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _UnavailablePreferences extends SharedPreferencesStorePlatform {
  @override
  Future<Map<String, Object>> getAll() async =>
      throw PlatformException(code: 'preferences_unavailable');
  @override
  Future<bool> clear() async => throw StateError('Unexpected write');
  @override
  Future<bool> remove(String key) async => throw StateError('Unexpected write');
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      throw StateError('Unexpected write');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cleanup reports unavailable settings, cleans local copies, and retries loading',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'backup_cleanup_prefs_',
      );
      final previousPaths = PathProviderPlatform.instance;
      SharedPreferences.setMockInitialValues({});
      final previousStore = SharedPreferencesStorePlatform.instance;
      PathProviderPlatform.instance = _Paths(temp.path);
      try {
        expect(Prefs.loaded, isFalse);
        final directory = await backupDirectory();
        final copy = File(
          p.join(directory.path, backupFileName(DateTime(2026, 10, 7))),
        );
        await copy.writeAsBytes([1]);
        SharedPreferencesStorePlatform.instance = _UnavailablePreferences();

        await expectLater(
          deleteAutomaticBackups(),
          throwsA(isA<FileSystemException>()),
        );
        expect(await copy.exists(), isFalse);
        expect(Prefs.loaded, isFalse);

        const folder = BackupFolder(
          uri: 'content://backups/tree/test',
          name: 'Backups',
        );
        SharedPreferences.setMockInitialValues({
          Prefs.backupFolder: jsonEncode(folder.toJson()),
        });
        await deleteAutomaticBackups();
        expect(Prefs.loaded, isTrue);
        expect(selectedBackupFolder?.uri, folder.uri);
      } finally {
        SharedPreferencesStorePlatform.instance = previousStore;
        PathProviderPlatform.instance = previousPaths;
        await temp.delete(recursive: true);
      }
    },
  );
}
