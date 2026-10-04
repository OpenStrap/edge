// The only file that imports firebase_*. The F-Droid build swaps it for
// docs/fdroid/firebase_bridge.floss.dart (same API, no-op), so keep it that way.

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart' as perf;
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

/// Handle for an in-flight Performance trace; opaque to callers.
class FirebaseTraceHandle {
  FirebaseTraceHandle._(this._trace);
  final perf.Trace _trace;
  Future<void> stop() => _trace.stop();
  void putAttribute(String name, String value) => _trace.putAttribute(name, value);
}

class FirebaseBridge {
  /// Throws when no real google-services.json / GoogleService-Info.plist is
  /// bundled; main() catches it.
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
