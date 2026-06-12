// Simple append-only file logger for field debugging.
//
// Writes to the app's external files dir on Android so it can be pulled with a
// plain `adb pull` (no run-as needed):
//   /storage/emulated/0/Android/data/wtf.openstrap.openstrap_edge/files/openstrap_sync.log

import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FileLog {
  static File? _file;
  static bool _init = false;

  static Future<void> _ensure() async {
    if (_init) return;
    _init = true;
    try {
      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/openstrap_sync.log');
    } catch (_) {
      _file = null;
    }
  }

  static Future<void> write(String line) async {
    await _ensure();
    try {
      await _file?.writeAsString('$line\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<String?> path() async {
    await _ensure();
    return _file?.path;
  }

  static Future<void> clear() async {
    await _ensure();
    try {
      await _file?.writeAsString('');
    } catch (_) {}
  }
}
