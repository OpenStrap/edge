// call_buzzer.dart — buzz the strap while the phone is RINGING. ANDROID ONLY: it
// rides a tiny native telephony bridge (CallStateBridge.kt), because ringing is
// not observable through the notification relay — dialers post the incoming-call
// notification as ONGOING (which the relay rightly skips as "not a ping"), and
// the dialer is a system app the app picker hides. iOS has no API to observe the
// native ringer at all, so on iOS this whole feature is inert and never shown.
//
// Flow: user flips the toggle → we ask for READ_PHONE_STATE (call STATE only —
// numbers are never read) → subscribe to the native ringing/offhook/idle stream
// → while ringing, buzz the band on a fixed cadence so the ring is hard to miss,
// and stop the instant the call is answered, declined, or rings out. Same
// persisted ChangeNotifier idiom as NotificationRelay so the settings UI is live.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show EventChannel, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CallBuzzer extends ChangeNotifier with WidgetsBindingObserver {
  CallBuzzer({required this.buzz, required this.isConnected});

  // Native telephony bridge (CallStateBridge.kt), registered on the long-lived
  // engine so the stream keeps flowing while the app is backgrounded.
  static const MethodChannel _channel = MethodChannel('openstrap/call_state');
  static const EventChannel _events =
      EventChannel('openstrap/call_state_events');

  /// Fire the strap haptic. Wired by AppState to `engine.buzz()`. Best-effort.
  final Future<void> Function() buzz;

  /// Whether the band is currently connected (no point buzzing nothing).
  final bool Function() isConnected;

  static const _kEnabled = 'call_buzz_enabled';

  /// Ring cadence: one buzz the moment ringing starts, then one every
  /// [repeatEvery] while it keeps ringing — a single pulse is easy to miss on
  /// the wrist, a steady cadence reads unmistakably as "your phone". [maxBuzzes]
  /// caps a stuck RINGING state (some OEMs never emit IDLE after a missed call)
  /// at roughly one standard ~30 s ring.
  static const Duration repeatEvery = Duration(seconds: 4);
  static const int maxBuzzes = 8;

  /// Only Android exposes call state. Everything below is a no-op when this is
  /// false, and the UI hides the feature entirely.
  bool get supported => Platform.isAndroid;

  bool _enabled = false;
  bool get enabled => _enabled;

  bool _granted = false;
  bool get permissionGranted => _granted;

  /// True only when everything needed to actually buzz is in place.
  bool get active => supported && _enabled && _granted;

  StreamSubscription<dynamic>? _sub;
  Timer? _ringTimer;
  bool _ringing = false; // true from first 'ringing' until idle/offhook
  int _buzzCount = 0;

  /// Load saved state, refresh permission, and start listening if active. Call
  /// once at startup. No-op on iOS.
  Future<void> bootstrap() async {
    if (!supported) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    WidgetsBinding.instance.addObserver(this);
    await refreshPermission();
    _resync();
    notifyListeners();
  }

  // The grant can change while we're backgrounded (user revokes it in Settings).
  // On every foreground return, re-check it and re-arm/tear down the stream.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && supported) {
      refreshPermission().then((_) => _resync());
    }
  }

  /// Re-query the READ_PHONE_STATE grant. Returns the current value.
  Future<bool> refreshPermission() async {
    if (!supported) return false;
    try {
      _granted =
          await _channel.invokeMethod<bool>('isPermissionGranted') ?? false;
    } catch (_) {
      _granted = false;
    }
    notifyListeners();
    return _granted;
  }

  /// Show the system permission dialog and return once it's answered. We re-read
  /// the real grant rather than trusting the dialog's return value.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      await _channel.invokeMethod<bool>('requestPermission');
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

  // Subscribe only when the feature can actually do something; otherwise tear
  // the stream down so the native side isn't holding a telephony listener for
  // nothing (onCancel unregisters it).
  void _resync() {
    final shouldListen = supported && _enabled && _granted;
    if (shouldListen) {
      _startListening();
    } else {
      _sub?.cancel();
      _sub = null;
      _stopRinging();
    }
  }

  void _startListening() {
    if (_sub != null) return;
    try {
      _sub = _events.receiveBroadcastStream().listen(
        (e) => handleStateEvent(e.toString()),
        // If the stream errors, drop it and let the next _resync re-arm — a
        // dead subscription must never silently stay dead.
        onError: (_) {
          _sub?.cancel();
          _sub = null;
        },
        cancelOnError: true,
      );
    } catch (_) {/* stream unavailable — stay inert */}
  }

  /// One native call-state transition: "ringing" | "offhook" | "idle".
  /// Exposed so the ring cadence is testable without a platform channel.
  @visibleForTesting
  void handleStateEvent(String state) {
    if (state == 'ringing') {
      _startRinging();
    } else {
      // offhook (answered / outgoing call) or idle (missed / declined / ended).
      _stopRinging();
    }
  }

  void _startRinging() {
    if (_ringing) return; // already this ring — don't restart the cadence
    _ringing = true;
    _buzzCount = 0;
    _fireBuzz();
    _ringTimer = Timer.periodic(repeatEvery, (_) {
      if (_buzzCount >= maxBuzzes) {
        // Stuck RINGING — stop buzzing after ~one full ring, but stay marked
        // as ringing so a duplicate 'ringing' event for the SAME call can't
        // start a fresh cadence. Only a terminal state (idle/offhook) clears it.
        _ringTimer?.cancel();
        _ringTimer = null;
        return;
      }
      _fireBuzz();
    });
  }

  void _stopRinging() {
    _ringTimer?.cancel();
    _ringTimer = null;
    _ringing = false;
    _buzzCount = 0;
  }

  void _fireBuzz() {
    _buzzCount++; // count the tick even unconnected, so the cap stays temporal
    if (!isConnected()) return;
    // Fire-and-forget; never let a BLE hiccup throw into the stream handler.
    unawaited(buzz().catchError((_) {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _stopRinging();
    super.dispose();
  }
}
