// telemetry_service.dart — OPT-IN crash/error + device telemetry, captured locally
// and flushed in coalesced batches (NEVER a fixed timer). See the cadence design:
//   • capture: FlutterError.onError + PlatformDispatcher.onError + runZonedGuarded
//     enqueue into a small persisted outbox (survives a crash → sent next launch);
//   • flush:   on app foreground/background, after a successful BLE drain, when the
//     outbox passes a threshold, and once at launch;
//   • snapshot: OEM/model/OS/app-version + a band snapshot (serial/battery/BLE
//     state) provided by AppState rides along with each batch.
//
// Capture is always on (cheap, local); TRANSMISSION is gated on `enabled` (the
// user's telemetry consent). Nothing leaves the device until they opt in.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:firebase_analytics/firebase_analytics.dart';

import '../cloud/companion_client.dart';
import 'error_classification.dart';
import 'jank_policy.dart';

/// A band-side snapshot AppState supplies (it owns the live DeviceState).
typedef BandSnapshot = Map<String, dynamic> Function();

class TelemetryService {
  TelemetryService._();
  static final TelemetryService instance = TelemetryService._();

  static const String _kOutbox = 'telemetry_outbox';
  static const int _maxOutbox = 200;     // hard cap (drop oldest beyond this)
  static const int _flushThreshold = 20; // auto-flush when the outbox reaches this

  /// Transmission gate — set from the user's telemetry consent. Capture happens
  /// regardless; we only POST when this is true.
  bool _enabled = false;
  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    _consentResolved = true;
    _applyFirebaseCollection(value);
  }

  // ── consent-gated Firebase collection ──────────────────────────────────────
  //
  // The Firebase SDKs auto-collect from process start unless told otherwise at
  // the PLATFORM level, which is why ios/Runner/Info.plist and
  // android/app/src/main/AndroidManifest.xml both ship
  // <analytics|crashlytics|performance>_collection_enabled = false. Those flags
  // are the real guarantee (they land before any Dart runs); everything here is
  // the seam that turns collection back ON, and only after the user's stored
  // consent has actually been read.

  /// False until the user's persisted telemetry consent has been LOADED — not
  /// merely defaulted. Nothing is transmitted and no Firebase SDK is enabled
  /// while this is false, no matter what else happens during startup.
  bool _consentResolved = false;
  bool get consentResolved => _consentResolved;

  /// Test seam: replaces the real `set*CollectionEnabled` fan-out (the Firebase
  /// SDKs can't be initialized in a unit test). Receives the value that would
  /// have been pushed to Crashlytics/Performance/Analytics.
  @visibleForTesting
  static void Function(bool enabled)? debugCollectionSink;

  void _applyFirebaseCollection(bool value) {
    final sink = debugCollectionSink;
    if (sink != null) {
      sink(value);
      return;
    }
    try {
      if (Firebase.apps.isNotEmpty) {
        FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(value);
        FirebasePerformance.instance.setPerformanceCollectionEnabled(value);
        FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(value);
      }
    } catch (_) {}
  }

  /// Apply the user's AFFIRMATIVELY LOADED telemetry consent. Preferred over
  /// assigning [enabled] directly because it reads as what it is: the single
  /// point where collection may be switched on.
  void applyConsent(bool consent) => enabled = consent;

  /// Belt-and-braces: force every Firebase SDK's collection OFF at startup,
  /// before consent is known. The platform flags already do this, but a build
  /// with a stale plist/manifest (or a future SDK that defaults differently)
  /// must still not collect. No-op once consent has been resolved, so a hot
  /// restart / re-entry can't silently revoke an opt-in.
  ///
  /// Called from main() right after Firebase.initializeApp. Safe when Firebase
  /// is absent entirely (no google-services.json / GoogleService-Info.plist) —
  /// Firebase is OPTIONAL and the app must run without it.
  void enforceCollectionOffUntilConsent() {
    if (_consentResolved) return;
    _enabled = false;
    _applyFirebaseCollection(false);
  }

  /// Test seam: return the singleton to its fresh-install state (no consent
  /// read yet, nothing transmitted).
  @visibleForTesting
  void debugResetConsent() {
    _consentResolved = false;
    _enabled = false;
  }

  /// Anchors + version stamped onto each batch (AppState sets these on load).
  String? deviceId;
  String? userId;
  int consentVersion = 1;

  /// AppState injects this to fold the live band state into the device snapshot.
  BandSnapshot? bandSnapshot;

  final List<Map<String, dynamic>> _outbox = [];
  bool _loaded = false;
  bool _flushing = false;
  Map<String, dynamic>? _staticDevice; // cached OEM/model/OS/app (collected once)

  // ── lifecycle ───────────────────────────────────────────────────────────────

  /// Install the global error hooks. Safe to call before consent loads — captured
  /// errors sit in the local outbox and are only transmitted once `enabled`.
  void installErrorHandlers() {
    final prior = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      prior?.call(details);
      try {
        if (Firebase.apps.isNotEmpty && _enabled) {
          // Flutter itself marks a FlutterErrorDetails `silent: true` for
          // errors it considers expected/non-actionable noise — e.g. an
          // image/tile network fetch that fails after the requesting widget
          // (a workout-route map tile) was already disposed: the framework's
          // own ImageStreamCompleter.reportError falls through to this global
          // handler only because no listener remained to catch it, NOT
          // because the app crashed (see image_stream.dart's `silent: true`
          // call sites — "resolving an image codec" / "loading an image").
          // Treating every FlutterError as FATAL misclassified these as
          // fatal crashes (inflating crash-free-users) even though the app
          // kept running fine. Still fully captured — just filed as
          // non-fatal so it doesn't count against crash-free-rate.
          FirebaseCrashlytics.instance.recordFlutterError(
            details,
            fatal: !details.silent,
          );
        }
      } catch (_) {}
      record(
        kind: 'crash',
        level: 'error',
        message: details.exceptionAsString(),
        stack: details.stack?.toString(),
        context: {'library': details.library ?? 'flutter', 'silent': details.silent},
      );
    };
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      try {
        if (Firebase.apps.isNotEmpty && _enabled) {
          // Same reasoning as the `silent` check above, for the errors the
          // framework never sees: a dropped tile fetch or a TLS handshake that
          // died with no network is not a crash, and filing it as one both
          // understates crash-free users and buries the real crashes.
          FirebaseCrashlytics.instance.recordError(
            error,
            stack,
            fatal: !isTransientError(error),
          );
        }
      } catch (_) {}
      record(kind: 'crash', level: 'error', message: '$error', stack: '$stack');
      return false; // let the platform also see it
    };
  }

  // ── observability surface: breadcrumbs, context, non-fatals, traces ────────
  //
  // Crashlytics only ever sees framework-reported errors on its own
  // (installErrorHandlers above) — PlatformDispatcher.onError is always fatal,
  // and FlutterError.onError is fatal unless the framework itself flagged the
  // FlutterErrorDetails `silent` (then non-fatal). Either way it has zero
  // visibility into freezes/jank or into errors that get caught-and-swallowed
  // today. These helpers are how we get real signal out of Firebase for
  // exactly those blind spots:
  //   - breadcrumb()/setContext(): attached automatically to whatever crash OR
  //     ANR report comes next from this session — the log() calls and the
  //     currently-set custom keys both ride along, no extra wiring needed.
  //   - recordNonFatal(): promotes a caught-and-swallowed error to a real
  //     Crashlytics issue instead of vanishing into debugPrint.
  //   - traced(): a Firebase Performance custom trace around a span of code —
  //     the only way to get real-world timing for BLE drains/derivation
  //     passes/health export, since Performance doesn't auto-instrument
  //     arbitrary Flutter rebuild cost.
  // All best-effort + silently no-op before Firebase is configured or before
  // the user has opted in, same gate as the rest of this file.

  /// Attach a breadcrumb log line to whatever Crashlytics report (crash OR
  /// ANR) comes next from this session. Cheap; call liberally at lifecycle
  /// transitions (screen changes, BLE state changes, derivation passes).
  void breadcrumb(String message) {
    try {
      if (Firebase.apps.isNotEmpty && _enabled) {
        FirebaseCrashlytics.instance.log(message);
      }
    } catch (_) {}
  }

  /// Set a persistent custom key visible on every subsequent Crashlytics
  /// report until overwritten — e.g. current_screen, ble_state, derive_mode.
  /// Unlike breadcrumb(), this is STATE (last-write-wins), not an event log.
  void setContext(String key, Object value) {
    try {
      if (Firebase.apps.isNotEmpty && _enabled) {
        FirebaseCrashlytics.instance.setCustomKey(key, value);
      }
    } catch (_) {}
  }

  /// Report a caught error as a Crashlytics NON-FATAL issue — for the many
  /// `catch (e) { debugPrint(...) }` sites where a real problem currently just
  /// vanishes into a debug console nobody in production ever reads.
  void recordNonFatal(Object error, StackTrace stack, {String? reason}) {
    try {
      if (Firebase.apps.isNotEmpty && _enabled) {
        FirebaseCrashlytics.instance.recordError(
          error,
          stack,
          fatal: false,
          reason: reason,
        );
      }
    } catch (_) {}
  }

  final Map<String, Trace> _activeTraces = {};

  /// Wrap [body] in a named Firebase Performance trace. Safe to nest under
  /// different names; a given [name] running concurrently with itself is not
  /// supported (the later start wins) — use distinct names per call site.
  Future<T> traced<T>(String name, Future<T> Function() body) async {
    Trace? trace;
    try {
      if (Firebase.apps.isNotEmpty && _enabled) {
        trace = FirebasePerformance.instance.newTrace(name);
        await trace.start();
        _activeTraces[name] = trace;
      }
    } catch (_) {
      trace = null;
    }
    try {
      return await body();
    } finally {
      try {
        await trace?.stop();
      } catch (_) {}
      _activeTraces.remove(name);
    }
  }

  Timer? _jankThrottle;

  /// Turn invisible UI jank into real Crashlytics non-fatal reports. Flutter
  /// itself already measures every frame's build+raster cost — we just have
  /// to listen. A frame whose ENGINE WORK (build + raster) is at/above
  /// [thresholdMs] reads as a visible stutter to the user; this is what
  /// actually answers "the app froze while scrolling" reports, which
  /// Crashlytics otherwise never sees at all (freezing isn't a crash).
  /// Throttled to at most one report per [minGapSeconds] so a rough patch
  /// (e.g. a long scroll over a busy screen) doesn't spam the outbox — still
  /// enough to catch the pattern without drowning it.
  ///
  /// The threshold deliberately does NOT apply to `FrameTiming.totalSpan`.
  /// totalSpan includes time the engine did nothing — above all the gap across
  /// an app resume — which produced reports like "Slow frame: 16358ms (build=0
  /// raster=8)" and made this the noisiest issue in the project. See
  /// [JankPolicy] for the full rationale; totalSpan is still attached as
  /// context so a scheduling-delay pattern remains visible.
  void installJankWatchdog({int thresholdMs = 700, int minGapSeconds = 30}) {
    final policy = JankPolicy(thresholdMs: thresholdMs);
    SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
      if (_jankThrottle != null) return;
      for (final t in timings) {
        final v = policy.evaluate(
          buildMs: t.buildDuration.inMilliseconds,
          rasterMs: t.rasterDuration.inMilliseconds,
          totalMs: t.totalSpan.inMilliseconds,
        );
        if (!v.report) continue;
        _jankThrottle = Timer(Duration(seconds: minGapSeconds), () {
          _jankThrottle = null;
        });
        breadcrumb(
          'slow_frame work=${v.workMs}ms build=${v.buildMs}ms '
          'raster=${v.rasterMs}ms total=${v.totalMs}ms',
        );
        recordNonFatal(
          Exception(v.message),
          StackTrace.current,
          reason: 'jank_watchdog',
        );
        record(kind: 'event', level: 'warn', message: 'slow_frame', context: {
          'work_ms': v.workMs,
          'build_ms': v.buildMs,
          'raster_ms': v.rasterMs,
          'total_ms': v.totalMs,
          'idle_ms': v.idleMs,
        });
        break; // one report per callback batch is enough signal
      }
    });
  }

  /// Record an uncaught zone error (called from runZonedGuarded in main).
  void recordZoneError(Object error, StackTrace stack) =>
      record(kind: 'crash', level: 'error', message: '$error', stack: '$stack');

  /// Enqueue one record. Cheap + local; persists so a crash survives to next run.
  void record({
    required String kind, // 'error' | 'crash' | 'event' | 'device'
    String? level,
    String? message,
    String? stack,
    Map<String, dynamic>? context,
  }) {
    // Local outbox persist
    _outbox.add({
      'kind': kind,
      ...?level == null ? null : {'level': level},
      ...?message == null ? null : {'message': _clip(message, 4000)},
      ...?stack == null ? null : {'stacktrace': _clip(stack, 8000)},
      ...?context == null ? null : {'context': context},
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    
    // Remote Firebase Analytics integration (only if event)
    try {
      if (Firebase.apps.isNotEmpty && _enabled && kind == 'event' && message != null) {
        final params = <String, Object>{};
        if (context != null) {
          context.forEach((k, v) {
            if (v is num || v is String) {
              params[k] = v;
            } else {
              params[k] = v.toString();
            }
          });
        }
        FirebaseAnalytics.instance.logEvent(
          name: message.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_'),
          parameters: params,
        );
      }
    } catch (_) {}

    while (_outbox.length > _maxOutbox) {
      _outbox.removeAt(0);
    }
    unawaited(_persist());
    if (enabled && _outbox.length >= _flushThreshold) unawaited(flush());
  }

  /// Load any persisted outbox (e.g. crash records from a previous session).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kOutbox);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final e in list) {
            if (e is Map) _outbox.add(e.cast<String, dynamic>());
          }
        }
      }
    } catch (_) {/* ignore corrupt blob */}
  }

  /// Send the whole outbox as one batch. No-op unless enabled + configured +
  /// non-empty. Clears the outbox only on a successful send.
  Future<void> flush() async {
    if (!enabled || !CompanionClient.configured || _flushing) return;
    if (deviceId == null || _outbox.isEmpty) return;
    _flushing = true;
    try {
      final events = List<Map<String, dynamic>>.from(_outbox);
      final ok = await CompanionClient.postTelemetry(
        deviceId: deviceId!,
        userId: userId,
        consentVersion: consentVersion,
        device: await _deviceSnapshot(),
        events: events,
      );
      if (ok) {
        // Drop exactly what we sent (records added meanwhile are kept).
        _outbox.removeRange(0, events.length.clamp(0, _outbox.length));
        await _persist();
      }
    } catch (_) {/* best-effort */} finally {
      _flushing = false;
    }
  }

  // ── device snapshot ───────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _deviceSnapshot() async {
    final s = _staticDevice ??= await _collectStatic();
    final snap = Map<String, dynamic>.from(s);
    // Live phone battery + the band snapshot AppState provides.
    try {
      snap['battery_pct'] = await Battery().batteryLevel;
    } catch (_) {/* unavailable */}
    final band = bandSnapshot?.call();
    if (band != null) snap.addAll(band);
    return snap;
  }

  Future<Map<String, dynamic>> _collectStatic() async {
    final out = <String, dynamic>{};
    try {
      final pkg = await PackageInfo.fromPlatform();
      out['app_version'] = pkg.version;
      out['app_build'] = int.tryParse(pkg.buildNumber);
    } catch (_) {}
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        out['platform'] = 'android';
        out['os_version'] = 'Android ${a.version.release} (SDK ${a.version.sdkInt})';
        out['oem'] = a.manufacturer;
        out['model'] = a.model;
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        out['platform'] = 'ios';
        out['os_version'] = '${i.systemName} ${i.systemVersion}';
        out['oem'] = 'Apple';
        out['model'] = i.utsname.machine;
      }
    } catch (_) {}
    return out;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kOutbox, jsonEncode(_outbox));
    } catch (_) {/* best-effort */}
  }

  String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);
}

/// Wire into MaterialApp's `navigatorObservers` so every real Navigator.push/
/// pop (drill-down screens, modals, settings) sets `current_screen` +
/// breadcrumbs it — free "what screen were they on" context on every future
/// crash/ANR report. Note this only sees Navigator-based transitions; the
/// app's top-level AppRoute switch (loading/pairing/profile/shell) and any
/// IndexedStack-based tab switching inside the shell are NOT Navigator pushes
/// and need their own hook (see _Gate in app.dart for the top-level one).
class TelemetryNavigatorObserver extends NavigatorObserver {
  String? _nameOf(Route<dynamic>? route) =>
      route?.settings.name ?? route?.runtimeType.toString();

  void _report(String event, Route<dynamic>? route) {
    final name = _nameOf(route);
    if (name == null) return;
    TelemetryService.instance.setContext('current_screen', name);
    TelemetryService.instance.breadcrumb('nav: $event $name');
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _report('push', route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _report('pop', previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _report('replace', newRoute);
}
