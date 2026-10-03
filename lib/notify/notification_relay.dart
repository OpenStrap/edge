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
import 'dart:typed_data';

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
  // 15 min, not 120 s: the heal is a belt-and-braces rebind for a listener
  // Android rarely unbinds, foreground resume already heals eagerly, and a
  // missed buzz during the window costs nothing — while the timer itself ran
  // a platform-channel round trip forever in an always-alive process.
  // 120 s. The active-gate above already confines this timer to installs that
  // actually use the relay, so the drain saved by a longer period is small
  // and the cost is silent non-buzzing for up to the whole interval.
  static const Duration _healEvery = Duration(seconds: 120);
  Timer? _healTimer;

  /// Fire the strap haptic. Wired by AppState to `engine.buzz()`. Best-effort.
  final Future<void> Function() buzz;

  /// Whether the band is currently connected (no point buzzing nothing).
  final bool Function() isConnected;

  static const _kEnabled = 'notif_relay_enabled';
  static const _kPackages = 'notif_relay_packages';
  static const _kSeen = 'notif_relay_seen';

  /// How many apps the "seen" list remembers. A phone posts from a long tail
  /// of packages over a week; past this the list stops being a list you can
  /// read.
  static const int maxSeen = 60;

  /// Only Android can observe other apps' notifications. Everything below is a
  /// no-op when this is false, and the UI hides the feature entirely.
  bool get supported => Platform.isAndroid;

  bool _enabled = false;
  bool get enabled => _enabled;

  bool _granted = false;
  bool get permissionGranted => _granted;

  /// Packages that have actually posted a notification while the listener was
  /// running, most recent first. This is what the picker offers.
  ///
  /// The alternative — enumerating installed apps — needs QUERY_ALL_PACKAGES,
  /// which was deliberately removed from the manifest with `tools:node=remove`
  /// as the most policy-expensive permission there is. It is also the worse
  /// list: two hundred packages to scroll, against the dozen that actually
  /// interrupt you.
  final List<String> _seen = [];

  /// Per-package icon, straight off the notification the OS handed us. RAM
  /// only, deliberately: the packages persist, the bitmaps do not, and a
  /// freshly-launched app simply shows names until each one posts again.
  final Map<String, Uint8List> _icons = {};

  List<String> get seenPackages => List.unmodifiable(_seen);
  Uint8List? iconFor(String pkg) => _icons[pkg];

  final Set<String> _packages = {};
  Set<String> get packages => _packages;
  bool isAppEnabled(String pkg) => _packages.contains(pkg);
  int get appCount => _packages.length;

  /// True only when everything needed to actually buzz is in place.
  bool get active => supported && _enabled && _granted && _packages.isNotEmpty;

  /// Whether the listener runs. NOT [active]: with zero apps picked the
  /// listener is the only thing that fills the picker, so gating it on a
  /// picked app meant a fresh install could never pick its first one.
  bool get _listening => supported && _enabled && _granted;

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
    _seen
      ..clear()
      ..addAll(prefs.getStringList(_kSeen) ?? const []);
    // An app already on the allow-list belongs in the picker whether or not it
    // has posted since launch — otherwise turning the feature on and reopening
    // the screen shows an empty list with your choices invisibly still active.
    for (final p in _packages) {
      if (!_seen.contains(p)) _seen.add(p);
    }
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
    // Off whenever the relay is off or ungranted, so an install that never
    // turned it on holds no stream and no heal timer. On with zero apps
    // picked: those posts are what the picker is built from (see
    // [_onNotification]); the buzz itself stays gated on the allow-list.
    final shouldListen = _listening;
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
    if (!_listening) return;
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

  /// Remember that [pkg] notifies, so the picker has something to offer.
  ///
  /// Persisted only when the package is NEW: the in-memory order changes on
  /// every ping and a SharedPreferences write per notification would be a
  /// disk write per notification.
  @visibleForTesting
  void noteSeen(String pkg, Uint8List? icon) {
    if (icon != null && icon.isNotEmpty) _icons[pkg] = icon;
    final known = _seen.remove(pkg);
    _seen.insert(0, pkg);
    if (_seen.length > maxSeen) {
      // Oldest first, but an ARMED app is never evicted. The picker is built
      // from this list, so dropping one you turned ON leaves it buzzing the
      // strap with no row to turn it off from — a thing that keeps acting on
      // you with no way to stop it. The bound survives: the overflow is at most
      // the apps you chose yourself.
      for (var i = _seen.length - 1; i >= 0 && _seen.length > maxSeen; i--) {
        if (!_packages.contains(_seen[i])) _seen.removeAt(i);
      }
      // The icons go with them. `_seen` is bounded, `_icons` was not — an
      // evicted package left its bitmap resident for the life of the process,
      // and on a phone with a lot of chatty apps that is the picker's whole
      // icon set held for a list it is no longer on.
      // ponytail: O(n) scan over 60 entries, only on eviction.
      _icons.removeWhere((k, _) => !_seen.contains(k));
    }
    if (!known) {
      SharedPreferences.getInstance()
          .then((p) => p.setStringList(_kSeen, _seen))
          .catchError((_) => false);
    }
    notifyListeners();
  }

  void _onNotification(ServiceNotificationEvent e) {
    // Only fresh, user-facing posts: skip removals and persistent/ongoing ones
    // (media players, foreground-service notifications) — those aren't "a ping".
    if (e.hasRemoved || e.onGoing) return;
    final pkg = e.packageName;
    if (pkg.isEmpty) return;
    // BEFORE the allow-list check: an app you have not chosen yet is exactly
    // the one the picker needs to be able to offer you.
    noteSeen(pkg, e.appIcon);
    if (!_packages.contains(pkg)) return;
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

/// A readable name for [pkg], from the package name alone.
///
/// An app's own label lives behind `getApplicationLabel`, which needs the
/// package-visibility permission this feature deliberately does not have — so
/// the ICON beside it (taken off the notification itself) is the identifier a
/// human actually reads, and this is the caption under it.
///
/// The last meaningful segment, capitalised: `com.whatsapp` → "Whatsapp",
/// `org.telegram.messenger` → "Messenger", `com.foo.android` → "Foo". Segments
/// that name a platform or a build rather than a product are stepped over,
/// because "Android" under every second icon is not a name.
String appLabel(String pkg) {
  const generic = {
    'android', 'app', 'apps', 'client', 'mobile', 'main', 'ui',
    'free', 'pro', 'lite', 'beta', 'release',
  };
  final parts = [for (final p in pkg.split('.')) if (p.isNotEmpty) p];
  if (parts.isEmpty) return pkg;
  var i = parts.length - 1;
  while (i > 0 && generic.contains(parts[i].toLowerCase())) {
    i--;
  }
  final w = parts[i];
  return w[0].toUpperCase() + w.substring(1);
}
