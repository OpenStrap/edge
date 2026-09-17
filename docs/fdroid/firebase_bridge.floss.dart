// firebase_bridge.dart (F-Droid / FLOSS variant) — no-op stand-in with the
// exact API of lib/telemetry/firebase_bridge.dart, zero firebase_* imports.
//
// Not compiled by default. The F-Droid build recipe (see
// docs/fdroid/wtf.openstrap.openstrap_edge.yml) copies this over
// lib/telemetry/firebase_bridge.dart and drops the four firebase_* lines
// from pubspec.yaml before building, so the FLOSS build contains zero
// Google Play Services / Firebase code. Every caller (telemetry_service.dart,
// main.dart) is unaffected — they only ever see this API.

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
