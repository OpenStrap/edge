// Manual database exports used to pile up in temp: every "Export database"
// left another full copy of the health record (and every encrypted export a
// full-size .osbk) that nothing ever deleted.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/export_retention.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

Future<File> _touch(Directory dir, String name, {DateTime? at}) async {
  final f = File(p.join(dir.path, name));
  await f.writeAsString('x');
  if (at != null) await f.setLastModified(at);
  return f;
}

List<String> _names(Directory dir) =>
    dir.listSync().map((e) => p.basename(e.path)).toList()..sort();

void main() {
  group('pruneSharedExports', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('osx_'));
    tearDown(() async => dir.delete(recursive: true));

    test('keeps the two newest exports, .db and .osbk alike', () async {
      await _touch(dir, 'openstrap_export_1000.db');
      await _touch(dir, 'openstrap_export_2000.db.osbk');
      await _touch(dir, 'openstrap_export_3000.db');
      await _touch(dir, 'openstrap_export_4000.db');
      await _touch(dir, 'openstrap_export_4000.db.osbk');

      await pruneSharedExports(dir);

      expect(_names(dir), [
        'openstrap_export_3000.db',
        'openstrap_export_4000.db',
        'openstrap_export_4000.db.osbk',
      ]);
    });

    test('leaves files that are not exports alone', () async {
      await _touch(dir, 'openstrap_export_1.db');
      await _touch(dir, 'openstrap_export_2.db');
      await _touch(dir, 'openstrap_export_3.db');
      await _touch(dir, 'notes.txt');
      await _touch(dir, 'openstrap_export_x.db');

      await pruneSharedExports(dir);

      expect(_names(dir), [
        'notes.txt',
        'openstrap_export_2.db',
        'openstrap_export_3.db',
        'openstrap_export_x.db',
      ]);
    });
  });

  group('pruneLegacyRootExports', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('osx_'));
    tearDown(() async => dir.delete(recursive: true));

    test('removes stale root copies but not in-flight snapshots', () async {
      final now = DateTime(2026, 10, 17, 12);
      await _touch(dir, 'openstrap_export_1.db',
          at: now.subtract(const Duration(days: 3)));
      await _touch(dir, 'openstrap_export_2.db.osbk',
          at: now.subtract(const Duration(days: 2)));
      await _touch(dir, 'openstrap_export_3.db',
          at: now.subtract(const Duration(minutes: 1)));
      await _touch(dir, 'something_else.db',
          at: now.subtract(const Duration(days: 9)));

      await pruneLegacyRootExports(dir, now: now);

      expect(_names(dir), ['openstrap_export_3.db', 'something_else.db']);
    });
  });

  group('exportCopy(into:)', () {
    late Directory root;
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      root = await Directory.systemTemp.createTemp('osx_root_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      LocalDb.dbName = 'openstrap_export_retention_test.db';
      final dbDir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    });
    tearDownAll(() async {
      await LocalDb.close();
      await root.delete(recursive: true);
    });

    test('repeated manual exports stay bounded in their own folder', () async {
      final dir = await sharedExportDir();
      expect(p.dirname(dir.path), root.path);
      final paths = <String>[];
      for (var i = 0; i < 4; i++) {
        final path = await LocalDb.exportCopy(into: dir);
        expect(p.dirname(path), dir.path);
        paths.add(path);
        await pruneSharedExports(dir);
        // Distinct millisecond stamps per export.
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }

      final left = dir.listSync().whereType<File>().map((f) => f.path).toSet();
      expect(left, {paths[2], paths[3]});
      // Nothing landed in the temp root.
      expect(
        root
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith('openstrap_export_')),
        isEmpty,
      );
    });
  });

  group('pruneSharedReports', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('osr_'));
    tearDown(() async => dir.delete(recursive: true));

    test('keeps the two newest locally shared report archives', () async {
      for (final us in [100, 300, 200, 400]) {
        await _touch(dir, 'openstrap_report_$us.zip');
      }
      await _touch(dir, 'openstrap_report_50.db.gz');
      await _touch(dir, 'notes.txt');
      await pruneSharedReports(dir);
      expect(_names(dir), [
        'notes.txt',
        'openstrap_report_300.zip',
        'openstrap_report_400.zip',
        'openstrap_report_50.db.gz',
      ]);
    });

    test('the archive being shared survives a clock set back', () async {
      for (final n in ['openstrap_report_8.zip', 'openstrap_report_9.zip']) {
        await _touch(dir, n);
      }
      // Built after the clock went back, so its stamp ranks oldest.
      final current = await _touch(dir, 'openstrap_report_5.zip');
      await pruneSharedReports(dir, current: current);
      expect(_names(dir), ['openstrap_report_5.zip', 'openstrap_report_9.zip']);
    });
  });

  group('purgeSharedHealthCopies', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('osp_'));
    tearDown(() async => dir.delete(recursive: true));

    test('removes every shared or staged copy, nothing else', () async {
      final share = Directory(p.join(dir.path, 'db_share'))..createSync();
      await _touch(share, 'openstrap_export_2.db');
      final csv = Directory(p.join(dir.path, 'openstrap_csv', '9'))
        ..createSync(recursive: true);
      await _touch(csv, 'heart_rate.csv');
      Directory(p.join(dir.path, 'osm_tiles')).createSync();
      for (final n in [
        'openstrap_export_1.db',
        'openstrap_export_1.db.osbk',
        'openstrap_report_7.zip',
        'openstrap_report_8.db.gz',
        'openstrap_slice_9.db',
        'openstrap_days_10.db',
        'unrelated.db',
      ]) {
        await _touch(dir, n);
      }
      await purgeSharedHealthCopies(dir);
      expect(_names(dir), ['osm_tiles', 'unrelated.db']);
    });
  });
}
