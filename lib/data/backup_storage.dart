import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A document-tree grant, not a filesystem path. Kept on this device only.
class BackupFolder {
  const BackupFolder({required this.uri, required this.name});

  final String uri;
  final String name;

  Map<String, String> toJson() => {'uri': uri, 'name': name};

  factory BackupFolder.fromJson(Map<String, dynamic> json) =>
      BackupFolder(uri: json['uri'] as String, name: json['name'] as String);
}

class BackupFile {
  const BackupFile({required this.path, required this.name});

  final String path;
  final String name;
}

/// Retention and publication use the same policy for paths and document URIs.
abstract class BackupStorage {
  Future<List<BackupFile>> list();
  Future<BackupFile> write(File snapshot, String name);
  Future<BackupFile> rename(BackupFile file, String name);
  Future<void> delete(BackupFile file);
}

class LocalBackupStorage implements BackupStorage {
  const LocalBackupStorage(this.directory);

  final Directory directory;

  @override
  Future<List<BackupFile>> list() async => [
    await for (final entry in directory.list())
      if (entry is File)
        BackupFile(path: entry.path, name: p.basename(entry.path)),
  ];

  @override
  Future<BackupFile> write(File snapshot, String name) async {
    final file = File(p.join(directory.path, name));
    try {
      await snapshot.openRead().transform(gzip.encoder).pipe(file.openWrite());
      return BackupFile(path: file.path, name: name);
    } catch (_) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<BackupFile> rename(BackupFile file, String name) async {
    final destination = File(p.join(directory.path, name));
    if (await destination.exists()) {
      throw const FileSystemException('Backup filename is already in use');
    }
    final renamed = await File(file.path).rename(destination.path);
    return BackupFile(path: renamed.path, name: name);
  }

  @override
  Future<void> delete(BackupFile file) async {
    await File(file.path).delete();
  }
}

/// The native bridge handles document-provider I/O on a worker thread. Dart
/// still owns compression, naming, retention, and backup scheduling.
class AndroidBackupStorage implements BackupStorage {
  const AndroidBackupStorage(this.folder);

  static const channel = MethodChannel('openstrap/backup_folder');
  final BackupFolder folder;

  static Future<BackupFolder?> pick() async {
    final result = await channel.invokeMapMethod<String, dynamic>('pick');
    return result == null ? null : BackupFolder.fromJson(result);
  }

  static Future<void> release(BackupFolder folder) =>
      channel.invokeMethod<void>('release', {'tree': folder.uri});

  Map<String, String> _arguments() => {'tree': folder.uri};

  BackupFile _file(Map<dynamic, dynamic> value) =>
      BackupFile(path: value['uri'] as String, name: value['name'] as String);

  @override
  Future<List<BackupFile>> list() async {
    final result = await channel.invokeListMethod<dynamic>(
      'list',
      _arguments(),
    );
    if (result == null) {
      throw const FileSystemException('Cannot read backup folder');
    }
    return [for (final file in result) _file(file as Map)];
  }

  @override
  Future<BackupFile> write(File snapshot, String name) async {
    // A private compressed staging copy avoids moving a whole database through
    // the method channel. Neither this file nor the snapshot is buffered in RAM.
    final temp = await (await getTemporaryDirectory()).createTemp('backup_');
    try {
      final compressed = File(p.join(temp.path, 'snapshot.db.gz'));
      await snapshot
          .openRead()
          .transform(gzip.encoder)
          .pipe(compressed.openWrite());
      final result = await channel.invokeMapMethod<String, dynamic>('write', {
        ..._arguments(),
        'source': compressed.path,
        'name': name,
      });
      if (result == null) {
        throw const FileSystemException('Backup was not written');
      }
      return _file(result);
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<BackupFile> rename(BackupFile file, String name) async {
    final result = await channel.invokeMapMethod<String, dynamic>('rename', {
      ..._arguments(),
      'uri': file.path,
      'name': name,
    });
    if (result == null) {
      throw const FileSystemException('Backup was not published');
    }
    return _file(result);
  }

  @override
  Future<void> delete(BackupFile file) =>
      channel.invokeMethod<void>('delete', {..._arguments(), 'uri': file.path});
}
