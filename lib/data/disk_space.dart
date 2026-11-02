// Free space on the volume that holds the database, from the platform.
//
// Only "Compact database" asks: a VACUUM writes a full second copy of the file
// before it drops the first, so it must not start on a nearly full phone.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

const MethodChannel _channel = MethodChannel('openstrap/storage');

/// Test seam: when set, answers instead of the platform.
@visibleForTesting
Future<int?> Function()? debugFreeDiskBytes;

/// Bytes free for the app on the database's volume, or null when the platform
/// cannot say (no channel, a desktop test, an error). Null is "unknown", and
/// every caller treats unknown as not enough.
Future<int?> freeDiskBytes() async {
  final override = debugFreeDiskBytes;
  if (override != null) return override();
  try {
    final v = await _channel.invokeMethod<Object?>(
      'freeBytes',
      {'path': await getDatabasesPath()},
    );
    return v is num ? v.toInt() : null;
  } catch (_) {
    return null;
  }
}
