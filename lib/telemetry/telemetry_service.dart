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
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cloud/companion_client.dart';

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
  bool enabled = false;

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
      record(
        kind: 'crash',
        level: 'error',
        message: details.exceptionAsString(),
        stack: details.stack?.toString(),
        context: {'library': details.library ?? 'flutter'},
      );
    };
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record(kind: 'crash', level: 'error', message: '$error', stack: '$stack');
      return false; // let the platform also see it
    };
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
    _outbox.add({
      'kind': kind,
      if (level != null) 'level': level,
      if (message != null) 'message': _clip(message, 4000),
      if (stack != null) 'stacktrace': _clip(stack, 8000),
      if (context != null) 'context': context,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
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
