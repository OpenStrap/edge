import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _DeleteFailureFile implements File {
  _DeleteFailureFile(this.path);
  @override
  final String path;
  @override
  Future<File> delete({bool recursive = false}) async =>
      throw FileSystemException('Delete failed', path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturedFolderApp extends AppState {
  _CapturedFolderApp() : super.forTesting();
  BackupFolder? capturedFolder;
  @override
  BackupFolder? get backupFolder => capturedFolder = super.backupFolder;
}

class _Documents {
  final files = <String, List<int>>{};
  final calls = <String>[];
  bool unavailable = false;
  bool failWrite = false;
  bool failRename = false;
  bool failDelete = false;
  BackupFolder? picked;
  List<int>? transferred;

  String uri(String name) => 'content://backups/tree/test/document/$name';
  Map<String, String> entry(String name) => {'uri': uri(name), 'name': name};

  Future<dynamic> handle(MethodCall call) async {
    calls.add(call.method);
    if (call.method == 'pick') return picked?.toJson();
    if (unavailable) {
      throw PlatformException(
        code: 'folder_access_lost',
        message: 'Choose the folder again.',
      );
    }
    final args = call.arguments as Map;
    expect(args['tree'], 'content://backups/tree/test');
    switch (call.method) {
      case 'list':
        return [for (final name in files.keys) entry(name)];
      case 'write':
        transferred = await File(args['source'] as String).readAsBytes();
        if (failWrite) {
          throw PlatformException(code: 'folder_io', message: 'Write failed.');
        }
        final name = args['name'] as String;
        if (files.containsKey(name)) {
          throw PlatformException(code: 'folder_io', message: 'Name in use.');
        }
        files[name] = transferred!;
        return entry(name);
      case 'rename':
        if (failRename) {
          throw PlatformException(code: 'folder_io', message: 'Rename failed.');
        }
        final name = args['name'] as String;
        final old = files.keys.singleWhere((n) => uri(n) == args['uri']);
        files[name] = files.remove(old)!;
        return entry(name);
      case 'delete':
        if (failDelete) {
          throw PlatformException(code: 'folder_io', message: 'Delete failed.');
        }
        files.removeWhere((name, _) => uri(name) == args['uri']);
        return null;
      case 'release':
        return null;
    }
    throw StateError('Unexpected method ${call.method}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _Documents documents;
  late SharedPreferences prefs;
  late PathProviderPlatform previousPaths;
  const folder = BackupFolder(
    uri: 'content://backups/tree/test',
    name: 'My backups',
  );
  const storage = AndroidBackupStorage(folder);
  final when = DateTime(2026, 10, 7, 12);
  final bytes = utf8.encode('SQLite format 3\u0000 test snapshot');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    prefs = await SharedPreferences.getInstance();
  });
  setUp(() async {
    await prefs.clear();
    temp = await Directory.systemTemp.createTemp('backup_folder_test_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(temp.path);
    documents = _Documents();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AndroidBackupStorage.channel,
          documents.handle,
        );
  });
  tearDown(() async {
    ResetGate.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidBackupStorage.channel, null);
    PathProviderPlatform.instance = previousPaths;
    await temp.delete(recursive: true);
  });

  Future<String> snapshot() async {
    final file = File(p.join(temp.path, 'snapshot.db'));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Future<BackupOutcome> run() =>
      runBackup(now: when, storage: storage, exportSnapshot: snapshot);

  test('picker cancellation leaves the saved folder unchanged', () async {
    await saveBackupFolder(folder);
    expect(await AndroidBackupStorage.pick(), isNull);
    expect(selectedBackupFolder?.uri, folder.uri);
  });

  test('picked folder retains a document URI and display name', () async {
    documents.picked = folder;
    final picked = await AndroidBackupStorage.pick();
    await saveBackupFolder(picked);
    expect(selectedBackupFolder?.toJson(), folder.toJson());
    expect(jsonDecode(prefs.getString(Prefs.backupFolder)!), folder.toJson());
  });

  test('returning to default does not delete or move old backups', () async {
    await saveBackupFolder(folder);
    documents.files[backupFileName(when)] = [1, 2, 3];
    await saveBackupFolder(null);
    expect(selectedBackupFolder, isNull);
    expect(documents.files, hasLength(1));
    expect(documents.calls, isNot(contains('delete')));
  });

  test(
    'a damaged saved setting stays selected rather than silently falling back',
    () async {
      await prefs.setString(Prefs.backupFolder, 'not-json');
      expect(selectedBackupFolder, isNotNull);
      expect(selectedBackupFolder!.uri, isEmpty);
    },
  );

  test(
    'writes gzip, reports the folder name, and removes both private temp copies',
    () async {
      final result = await run();
      expect(result.succeeded, isTrue, reason: result.error);
      expect(result.path, 'My backups/${backupFileName(when)}');
      expect(gzip.decode(documents.files.values.single), bytes);
      expect(documents.calls.take(3), ['list', 'write', 'rename']);
      expect(documents.files.keys.any((n) => n.endsWith('.partial')), isFalse);
      expect(temp.listSync(), isEmpty);
    },
  );

  test(
    'lost access is reported before exporting and never marks a run',
    () async {
      documents.unavailable = true;
      var exported = 0;
      var marked = 0;
      final result = await runBackupIfDue(
        cadence: () => BackupCadence.daily,
        lastRun: () => null,
        markRun: (_) async => marked++,
        storage: storage,
        exportSnapshot: () async {
          exported++;
          return snapshot();
        },
      );
      expect(result.error, 'Choose the folder again.');
      expect(result.succeeded, isFalse);
      expect(exported, 0);
      expect(marked, 0);
      expect(temp.listSync(), isEmpty);
    },
  );

  test(
    'failed transfer preserves good backups and cleans private files',
    () async {
      for (var day = 1; day <= 5; day++) {
        documents.files[backupFileName(DateTime(2026, 10, day))] = [day];
      }
      final before = Map<String, List<int>>.from(documents.files);
      documents.failWrite = true;
      expect((await run()).succeeded, isFalse);
      expect(documents.files, before);
      expect(documents.calls, isNot(contains('rename')));
      expect(temp.listSync(), isEmpty);
    },
  );

  test(
    'failed publication removes staging without pruning a good backup',
    () async {
      for (var day = 1; day <= 5; day++) {
        documents.files[backupFileName(DateTime(2026, 10, day))] = [day];
      }
      final before = Map<String, List<int>>.from(documents.files);
      documents.failRename = true;
      expect((await run()).succeeded, isFalse);
      expect(documents.files, before);
      expect(temp.listSync(), isEmpty);
      documents.failRename = false;
      expect(
        (await run()).succeeded,
        isTrue,
        reason: 'a failure must not wedge the queue',
      );
    },
  );

  test(
    'retention keeps five newest and only removes exact backup names',
    () async {
      for (var day = 1; day <= 5; day++) {
        documents.files[backupFileName(DateTime(2026, 10, day))] = [day];
      }
      documents.files['important.txt'] = [42];
      documents.files['openstrap-notes.db'] = [42];
      documents.files['download.partial'] = [42];
      documents.files['openstrap-20260101-000000.db.gz.partial'] = [0];
      expect((await run()).succeeded, isTrue);
      expect(
        documents.files.keys.where((n) => n.endsWith('.db.gz')),
        hasLength(5),
      );
      expect(
        documents.files,
        isNot(contains(backupFileName(DateTime(2026, 10, 1)))),
      );
      expect(documents.files['important.txt'], [42]);
      expect(documents.files['openstrap-notes.db'], [42]);
      expect(documents.files['download.partial'], [42]);
      expect(
        documents.files,
        isNot(contains('openstrap-20260101-000000.db.gz.partial')),
      );
    },
  );

  test(
    'cleanup failure does not turn a completed backup into a failed one',
    () async {
      documents.files['openstrap-20260101-000000.db.gz.partial'] = [0];
      documents.failDelete = true;
      final result = await run();
      expect(result.succeeded, isTrue);
      expect(result.error, isNull);
    },
  );

  test('same-second backups never overwrite an existing document', () async {
    final first = await run();
    final firstBytes = List<int>.from(documents.files[backupFileName(when)]!);
    final second = await run();
    expect(first.path, isNot(second.path));
    expect(documents.files[backupFileName(when)], firstBytes);
  });

  test('leftover staging does not block a same-second retry', () async {
    final stagingName = '${backupFileName(when)}.partial';
    documents.files[stagingName] = [0];
    final result = await run();
    expect(result.succeeded, isTrue, reason: result.error);
    expect(result.path, endsWith('-2.db.gz'));
    expect(gzip.decode(documents.files.values.single), bytes);
    expect(documents.files, isNot(contains(stagingName)));
  });

  test(
    'reset cleanup deletes backups and staging but leaves other files',
    () async {
      final directory = await backupDirectory();
      final backup = File(p.join(directory.path, backupFileName(when)));
      final staging = File('${backup.path}.partial');
      final unrelated = File(p.join(directory.path, 'openstrap-notes.db'));
      final download = File(p.join(directory.path, 'download.partial'));
      for (final file in [backup, staging, unrelated, download]) {
        await file.writeAsBytes([1]);
      }
      await deleteAutomaticBackups();
      expect(await backup.exists(), isFalse);
      expect(await staging.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      expect(await download.exists(), isTrue);
    },
  );

  test(
    'reset cleanup attempts remaining files after one delete fails',
    () async {
      final directory = await backupDirectory();
      final blocked = File(p.join(directory.path, backupFileName(when)));
      final other = File(
        p.join(
          directory.path,
          backupFileName(when.subtract(const Duration(days: 1))),
        ),
      );
      final unrelated = File(p.join(directory.path, 'notes.txt'));
      final files = [blocked, other, unrelated];
      for (final file in files) {
        await file.writeAsBytes([1]);
      }
      await IOOverrides.runZoned(
        () => expectLater(
          deleteAutomaticBackups(),
          throwsA(isA<FileSystemException>()),
        ),
        createFile: (path) => path == blocked.path
            ? _DeleteFailureFile(path)
            : files.singleWhere((file) => file.path == path),
      );
      expect(await blocked.exists(), isTrue);
      expect(await other.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
    },
  );

  test(
    'reset cleanup waits for a running backup before deleting its copy',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      final running = runBackup(
        now: when,
        exportSnapshot: () async {
          entered.complete();
          await finish.future;
          return snapshot();
        },
      );
      await entered.future;
      ResetGate.enter();
      var cleaned = false;
      final cleaning = deleteAutomaticBackups().then((_) => cleaned = true);
      await Future<void>.delayed(Duration.zero);
      expect(cleaned, isFalse);
      finish.complete();
      expect((await running).succeeded, isTrue);
      await cleaning;
      expect((await backupDirectory()).listSync(), isEmpty);
      ResetGate.leave();
    },
  );

  for (final unavailable in [false, true]) {
    test(
      'reset captures in-flight folder and wipes data, unavailable=$unavailable',
      () async {
        sqfliteFfiInit();
        final previousFactory = databaseFactoryOrNull;
        final previousName = LocalDb.dbName;
        await LocalDb.close();
        databaseFactory = databaseFactoryFfi;
        LocalDb.dbName = p.join(temp.path, 'reset.db');
        final app = _CapturedFolderApp();
        try {
          final db = await LocalDb.instance;
          await db.execute('CREATE TABLE reset_probe (value TEXT)');
          await db.insert('reset_probe', {'value': 'private data'});
          await prefs.setString('reset_probe', 'private preference');
          final directory = await backupDirectory();
          final copy = File(p.join(directory.path, backupFileName(when)));
          await copy.writeAsBytes([1]);
          if (unavailable) {
            final blocked = File(p.join(temp.path, 'unavailable'));
            await blocked.writeAsString('not a directory');
            PathProviderPlatform.instance = _Paths(blocked.path);
          }

          await saveBackupFolder(
            const BackupFolder(
              uri: 'content://backups/tree/old',
              name: 'Old folder',
            ),
          );
          final saving = saveBackupFolder(folder);
          // Let the save enter the queue before reset closes it to new work.
          await Future<void>.value();
          final resetting = app.resetAllData();
          await saving;
          final cleanupError = await resetting;

          expect(cleanupError, unavailable ? isNotNull : isNull);
          expect(app.capturedFolder?.uri, folder.uri);
          expect(await db.query('reset_probe'), isEmpty);
          expect(prefs.getString('reset_probe'), isNull);
          expect(await copy.exists(), unavailable);
          expect(ResetGate.active, isFalse);
        } finally {
          app.dispose();
          await LocalDb.close();
          databaseFactoryOrNull = previousFactory;
          LocalDb.dbName = previousName;
        }
      },
    );
  }

  test(
    'changing a folder preserves an enabled schedule without backing up',
    () async {
      await prefs.setString(Prefs.backupCadence, BackupCadence.daily.name);
      await prefs.setInt(Prefs.backupLastRunMs, when.millisecondsSinceEpoch);
      final app = AppState.forTesting();
      try {
        await app.setBackupFolder(folder);
        expect(app.backupFolder?.uri, folder.uri);
        expect(app.backupCadence, BackupCadence.daily);
        expect(app.lastBackupAt, when);
        expect(app.lastBackupError, isNull);
        expect(documents.calls, isEmpty);
        expect(temp.listSync(), isEmpty);
        await app.setBackupFolder(null);
        expect(app.backupFolder, isNull);
        expect(app.backupCadence, BackupCadence.daily);
        expect(app.lastBackupAt, when);
        expect(temp.listSync(), isEmpty);
      } finally {
        app.dispose();
      }
    },
  );

  test('changing folder waits for the current backup to finish', () async {
    await saveBackupFolder(folder);
    final entered = Completer<void>();
    final finish = Completer<void>();
    final running = runBackup(
      storage: storage,
      exportSnapshot: () async {
        entered.complete();
        await finish.future;
        return snapshot();
      },
    );
    await entered.future;
    var changed = false;
    final changing = saveBackupFolder(null).then((_) => changed = true);
    await Future<void>.delayed(Duration.zero);
    expect(changed, isFalse);
    expect(selectedBackupFolder?.uri, folder.uri);
    finish.complete();
    expect((await running).succeeded, isTrue);
    await changing;
    expect(selectedBackupFolder, isNull);
  });

  test(
    'a backup queued before reset cannot write while reset is active',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      final running = runBackup(
        storage: storage,
        exportSnapshot: () async {
          entered.complete();
          await finish.future;
          return snapshot();
        },
      );
      await entered.future;
      final queued = run();
      ResetGate.enter();
      finish.complete();
      await running;
      expect((await queued).skipped, isTrue);
      expect(documents.calls.where((m) => m == 'write'), hasLength(1));
      ResetGate.leave();
    },
  );
}
