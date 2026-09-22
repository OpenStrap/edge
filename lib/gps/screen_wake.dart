// ScreenWake — hold the display awake for the duration of a live session.
//
// Every serious run/ride app does this: the athlete has the phone on a bar
// mount or an armband and glances at it, they do not tap it every 30 s to stop
// the screen sleeping. Before this, the live session screen carried a "Keep the
// screen on to map your route" hint — asking the user to work around the app.
//
// Deliberately NOT a new dependency. Both platforms already have a registered
// method channel, and the native primitive is one line each:
//   • Android — FLAG_KEEP_SCREEN_ON on the activity window (window-scoped, so
//     it is released automatically when the activity goes away).
//   • iOS     — UIApplication.isIdleTimerDisabled.
// Neither is a true CPU wakelock: they keep the DISPLAY on while the app is
// frontmost and nothing more, so a leaked flag can never drain the battery in
// the background. Background *recording* is a separate mechanism entirely (the
// location background mode / FGS location type — see gps_source.dart).
//
// OWNERS. More than one feature can want the screen (a workout, an ECG
// reading). Each holds and releases under its own name; the display is held
// while ANY owner remains, so one feature's release can never drop another's
// hold. The owner set is reconciled to the platform through the same
// serialized chain as before, and the confirmed state still moves only after
// a successful platform call — a failed enable leaves the owner recorded, so
// the next hold or release retries it.
//
// Failure is always silent: a screen that sleeps is a papercut, never a reason
// to interrupt a workout.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ScreenWake {
  static const _android = MethodChannel('openstrap/edge_tracking');
  static const _ios = MethodChannel('openstrap/ios_config');

  /// What the PLATFORM last confirmed, not what we last asked for.
  ///
  /// Only updated after a successful call. Android returns false when no
  /// activity is attached; latching the requested value before the result came
  /// back meant a failed enable left Dart believing the screen was held and
  /// short-circuited every later retry.
  static bool _on = false;

  /// Who currently wants the display held.
  static final Set<String> _owners = <String>{};

  /// Test seam for the platform switch below.
  ///
  /// `Platform.isAndroid` and `Platform.isIOS` are BOTH false on the host VM
  /// that widget tests run on, so without this the dispatch short-circuits and
  /// no test can reach either MethodChannel — the mocks looked wired up and
  /// asserted nothing. Set to 'android' or 'ios' in a test; null = real
  /// platform.
  @visibleForTesting
  static String? platformOverride;

  static bool get _isAndroid =>
      platformOverride == null ? Platform.isAndroid : platformOverride == 'android';
  static bool get _isIOS =>
      platformOverride == null ? Platform.isIOS : platformOverride == 'ios';

  @visibleForTesting
  static bool get isHeld => _on;

  @visibleForTesting
  static Set<String> get owners => Set.unmodifiable(_owners);

  /// Serializes transitions so each one sees the state the previous one left.
  ///
  /// Without this, `_on` is only updated AFTER the platform await, so a
  /// `release()` arriving while an `enable()` is still in flight reads the
  /// stale `false`, decides it has nothing to do, and returns — then the
  /// in-flight enable latches `_on = true` and the display stays held for the
  /// rest of the app's life. Both call sites are fire-and-forget from
  /// AppState, so a short workout (start then immediately stop) is enough to
  /// hit it.
  static Future<void> _chain = Future<void>.value();

  /// Keep the display awake on behalf of [owner]. Safe to call repeatedly.
  static Future<void> hold(String owner) {
    _owners.add(owner);
    return _reconcile();
  }

  /// [owner] no longer needs the display. The display is released only when
  /// no owner remains. MUST be called when the owner's session ends —
  /// including on the error/abort paths.
  static Future<void> releaseOwner(String owner) {
    _owners.remove(owner);
    return _reconcile();
  }

  /// The workout's hold under the original single-owner names — kept so the
  /// reliability tests written against them still describe real behaviour.
  /// New call sites use [hold]/[releaseOwner] with their own name.
  static const String workoutOwner = 'workout';
  static Future<void> enable() => hold(workoutOwner);
  static Future<void> release() => releaseOwner(workoutOwner);

  static Future<void> _reconcile() {
    // The owner set as of THIS call — so a hold followed by a release still
    // reaches the platform as enable-then-release, in order, exactly as the
    // reliability tests pin, and the last word is the release.
    final want = _owners.isNotEmpty;
    final next = _chain.then((_) => _apply(want));
    // Keep the chain alive even if a link fails; _apply already swallows, this
    // is belt-and-braces so one bad transition can't wedge every later one.
    _chain = next.catchError((_) {});
    return next;
  }

  static Future<void> _apply(bool on) async {
    if (on == _on) return;
    try {
      if (_isAndroid) {
        final ok = await _android.invokeMethod<bool>('keepAwake', {'on': on});
        // Android answers false when there is no attached activity. Leave the
        // flag alone so the next call retries rather than assuming success.
        if (ok != true) return;
      } else if (_isIOS) {
        await _ios.invokeMethod<bool>('keepAwake', {'on': on});
      }
      _on = on;
    } catch (e) {
      // Never surface: losing the wake flag degrades to "screen sleeps". The
      // flag stays unchanged, so a later attempt can still succeed.
      debugPrint('[screen-wake] ${on ? 'enable' : 'release'} failed: $e');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _on = false;
    _owners.clear();
    platformOverride = null;
    _chain = Future<void>.value();
  }
}
