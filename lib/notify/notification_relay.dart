// notification_relay.dart — relay selected phone-app notifications to the strap as
// a haptic buzz. ANDROID ONLY: it rides Android's NotificationListenerService (the
// `notification_listener_service` plugin). iOS has no API to observe other apps'
// notifications, so on iOS this whole feature is inert and the UI never shows it.
//
// Flow: user grants "Notification access" + picks apps → we subscribe to the system
// notification stream → for each NEW notification whose package is on the allow-list,
// we buzz the band (Cmd.runHapticsPattern, via the injected callback). Same persisted
// ChangeNotifier idiom as GestureSettings/ThemeController so the settings UI is live.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:notification_listener_service/notification_event.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationRelay extends ChangeNotifier with WidgetsBindingObserver {
  NotificationRelay({required this.buzz, required this.isConnected});

  // The plugin's own MethodChannel. v1.0.0's Dart API doesn't expose the native
  // rebind/health handlers, so we invoke them directly to self-heal when Android
  // unbinds the NotificationListenerService (it does this routinely over time).
  static const MethodChannel _pluginChannel =
      MethodChannel('x-slayer/notifications_channel');
  static const Duration _healEvery = Duration(seconds: 120);
  Timer? _healTimer;

  /// Fire the strap haptic. Wired by AppState to `engine.buzz()`. Best-effort.
  final Future<void> Function() buzz;

  /// Whether the band is currently connected (no point buzzing nothing).
  final bool Function() isConnected;

  static const _kEnabled = 'notif_relay_enabled';
  static const _kPackages = 'notif_relay_packages';

  /// Only Android can observe other apps' notifications. Everything below is a
  /// no-op when this is false, and the UI hides the feature entirely.
  bool get supported => Platform.isAndroid;

  bool _enabled = false;
  bool get enabled => _enabled;

  bool _granted = false;
  bool get permissionGranted => _granted;

  final Set<String> _packages = {};
  Set<String> get packages => _packages;
  bool isAppEnabled(String pkg) => _packages.contains(pkg);
  int get appCount => _packages.length;

  /// True only when everything needed to actually buzz is in place.
  bool get active => supported && _enabled && _granted && _packages.isNotEmpty;

  StreamSubscription<ServiceNotificationEvent>? _sub;
  // Per-package de-dupe: ignore repeat posts of the same app within this window
  // (apps re-post the same notification as it updates), plus a global floor so a
  // burst never machine-guns the strap.
  final Map<String, int> _lastBuzzMs = {};
  int _lastAnyBuzzMs = 0;
  static const _perAppCooldownMs = 4000;
  static const _globalFloorMs = 800;

  /// Load saved state, refresh permission, and start listening if active. Call
  /// once at startup. No-op on iOS.
  Future<void> bootstrap() async {
    if (!supported) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _packages
      ..clear()
      ..addAll(prefs.getStringList(_kPackages) ?? const []);
    WidgetsBinding.instance.addObserver(this);
    await refreshPermission();
    _resync();
    notifyListeners();
  }

  // The OS can unbind the listener and kill our stream while we're backgrounded.
  // On every foreground return, re-check the grant and force the listener back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && supported) {
      refreshPermission().then((_) {
        _resync();
        _heal();
      });
    }
  }

  /// Re-query the OS "Notification access" grant (it can change while we're
  /// backgrounded — user revokes it in Settings). Returns the current value.
  Future<bool> refreshPermission() async {
    if (!supported) return false;
    try {
      _granted = await NotificationListenerService.isPermissionGranted();
    } catch (_) {
      _granted = false;
    }
    notifyListeners();
    return _granted;
  }

  /// Open the system Notification-access settings page and return once the user
  /// comes back. We re-read the real grant rather than trusting the return value.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      await NotificationListenerService.requestPermission();
    } catch (_) {/* user may just back out */}
    final ok = await refreshPermission();
    _resync();
    return ok;
  }

  Future<void> setEnabled(bool on) async {
    if (!supported || on == _enabled) return;
    _enabled = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, on);
    _resync();
    notifyListeners();
  }

  Future<void> setAppEnabled(String pkg, bool on) async {
    if (!supported) return;
    if (on) {
      if (!_packages.add(pkg)) return;
    } else {
      if (!_packages.remove(pkg)) return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPackages, _packages.toList());
    _resync();
    notifyListeners();
  }

  // Subscribe only when the feature can actually do something; otherwise tear the
  // stream down so we're not holding a system callback for nothing. Also runs a
  // periodic heal so a system-unbound listener gets re-armed while we're alive.
  void _resync() {
    final shouldListen = supported && _enabled && _granted;
    if (shouldListen) {
      _startListening();
      _healTimer ??= Timer.periodic(_healEvery, (_) => _heal());
    } else {
      _sub?.cancel();
      _sub = null;
      _healTimer?.cancel();
      _healTimer = null;
    }
  }

  void _startListening() {
    if (_sub != null) return;
    try {
      _sub = NotificationListenerService.notificationsStream.listen(
        _onNotification,
        // If the stream errors or closes, drop it and let the next _resync/heal
        // re-arm — a dead subscription must never silently stay dead.
        onError: (_) {
          _sub?.cancel();
          _sub = null;
        },
        onDone: () {
          _sub = null;
        },
        cancelOnError: true,
      );
    } catch (_) {/* stream unavailable — stay inert */}
  }

  // Ask the native side whether the listener is still bound; if not, force a
  // rebind + reconnect via the plugin's (Dart-unexposed) handlers. All best-effort
  // — older plugin builds or pre-API-24 devices simply no-op.
  Future<void> _heal() async {
    if (!active) return;
    _startListening(); // re-arm the Dart stream if it died
    try {
      final connected =
          await _pluginChannel.invokeMethod<bool>('isServiceConnected') ?? true;
      if (!connected) {
        try { await _pluginChannel.invokeMethod('forceRequestRebind'); } catch (_) {}
        try { await _pluginChannel.invokeMethod('reconnectService'); } catch (_) {}
      }
    } catch (_) {/* handler absent on this plugin build — ignore */}
  }

  void _onNotification(ServiceNotificationEvent e) {
    // Only fresh, user-facing posts: skip removals and persistent/ongoing ones
    // (media players, foreground-service notifications) — those aren't "a ping".
    if (e.hasRemoved || e.onGoing) return;
    final pkg = e.packageName;
    if (pkg.isEmpty || !_packages.contains(pkg)) return;
    if (!isConnected()) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final lastForPkg = _lastBuzzMs[pkg] ?? 0;
    if (now - lastForPkg < _perAppCooldownMs) return;
    if (now - _lastAnyBuzzMs < _globalFloorMs) return;
    _lastBuzzMs[pkg] = now;
    _lastAnyBuzzMs = now;
    // Fire-and-forget; never let a BLE hiccup throw into the system callback.
    unawaited(buzz().catchError((_) {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
