import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android: the launcher opened the app again after it was closed (issue #650).
///
/// The Activity goes away when the app is swiped from recents, but the Flutter
/// engine is kept alive for background Bluetooth, so the Navigator still holds
/// whatever screen was on top: reopening landed back inside Settings. On iOS the
/// process ends and a relaunch starts on the saved tab with nothing above it.
/// `MainActivity.onCreate` sends `relaunched` only for that case, and this
/// closes the pushed screens to match. The tab itself is left alone: it is
/// restored on purpose (`restoredShellTab`).
class ActivityRelaunch {
  static const channel = MethodChannel('openstrap/activity');

  static NavigatorState? Function()? _navigator;

  /// Handle `relaunched` while [navigator] can answer; it returns null once its
  /// owner is gone. Pass the same function to [stop] when the owner is disposed.
  static void listen(NavigatorState? Function() navigator) {
    _navigator = navigator;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'relaunched') return;
      // Stops at a screen that refuses to close (`PopScope(canPop: false)`):
      // a breathing session or an ECG capture in progress. `popUntil` pops
      // without asking, and closing one of those mid-run would throw the
      // recording away; whatever sits above it is still closed.
      _navigator?.call()?.popUntil((route) =>
          route.isFirst ||
          route.popDisposition == RoutePopDisposition.doNotPop);
    });
  }

  /// Stops listening, unless a newer owner has called [listen] since: a
  /// replaced owner's dispose runs after its successor's initState.
  static void stop(NavigatorState? Function() navigator) {
    // `!=`, not `identical`: two tear-offs of one instance's method are equal
    // but not guaranteed identical.
    if (_navigator != navigator) return;
    _navigator = null;
    channel.setMethodCallHandler(null);
  }
}
