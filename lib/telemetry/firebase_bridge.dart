// firebase_bridge.dart — the ONLY file in this app that imports a firebase_*
// package. Every Firebase type/call telemetry_service.dart and main.dart need
// is re-exposed here through plain Dart signatures.
//
// Why this exists: Firebase is fully optional already (see
// telemetry_service.dart's `enabled` gate and android/app/build.gradle.kts'
// conditional plugin application), but F-Droid rejects apps that bundle the
// Play Services / Firebase Android libraries at all, used or not. Because
// every firebase_* import in the app funnels through this one file, an
// F-Droid build recipe can ship a Firebase-free build by replacing just this
// file with docs/fdroid/firebase_bridge.floss.dart (a no-op stub with the
// same API) and dropping the four firebase_* deps from pubspec.yaml — no
// other source file changes needed.
//
// Keep every firebase_* import confined to this file when touching telemetry.

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart' as perf;
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

/// Handle for an in-flight Performance trace; opaque to callers.
class FirebaseTraceHandle {
  FirebaseTraceHandle._(this._trace);
  final perf.Trace? _trace;
  Future<void> stop() async => _trace?.stop();
  void putAttribute(String name, String value) => _trace?.putAttribute(name, value);
}

class FirebaseBridge {
  /// Initializes Firebase; no-op (throws internally, caught) if no real
  /// google-services.json / GoogleService-Info.plist is bundled.
  static Future<void> initialize({Duration? timeout}) async {
    final future = Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await (timeout == null ? future : future.timeout(timeout));
  }

  static bool get isInitialized => Firebase.apps.isNotEmpty;

  static void setCollectionEnabled(bool value) {
    FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(value);
    perf.FirebasePerformance.instance.setPerformanceCollectionEnabled(value);
    FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(value);
  }

  static void recordFlutterError(FlutterErrorDetails details, {required bool fatal}) {
    FirebaseCrashlytics.instance.recordFlutterError(details, fatal: fatal);
  }

  static void recordError(Object error, StackTrace stack, {required bool fatal, String? reason}) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: fatal, reason: reason);
  }

  static void log(String message) => FirebaseCrashlytics.instance.log(message);

  static void setCustomKey(String key, Object value) =>
      FirebaseCrashlytics.instance.setCustomKey(key, value);

  static Future<FirebaseTraceHandle> startTrace(String name) async {
    final trace = perf.FirebasePerformance.instance.newTrace(name);
    await trace.start();
    return FirebaseTraceHandle._(trace);
  }

  static void logEvent(String name, Map<String, Object> parameters) {
    FirebaseAnalytics.instance.logEvent(name: name, parameters: parameters);
  }
}
