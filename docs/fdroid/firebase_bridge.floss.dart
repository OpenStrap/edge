// F-Droid stand-in for lib/telemetry/firebase_bridge.dart: same API, no firebase.
// Copied over the real one by wtf.openstrap.openstrap_edge.yml.

import 'package:flutter/foundation.dart';

class FirebaseTraceHandle {
  const FirebaseTraceHandle._();
  Future<void> stop() async {}
  void putAttribute(String name, String value) {}
}

class FirebaseBridge {
  static Future<void> initialize({Duration? timeout}) async {}

  static bool get isInitialized => false;

  static void setCollectionEnabled(bool value) {}

  static void recordFlutterError(FlutterErrorDetails details, {required bool fatal}) {}

  static void recordError(Object error, StackTrace stack, {required bool fatal, String? reason}) {}

  static void log(String message) {}

  static void setCustomKey(String key, Object value) {}

  static Future<FirebaseTraceHandle> startTrace(String name) async =>
      const FirebaseTraceHandle._();

  static void logEvent(String name, Map<String, Object> parameters) {}
}
