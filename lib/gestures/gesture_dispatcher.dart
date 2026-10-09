// gesture_dispatcher.dart — turns a live band event into an action, with the guards
// that keep it safe. Wired ONLY into the foreground/live event path (AppState), never
// the headless drain (background_sync persists events but must not replay them).
//
// Two guards do the real work:
//  • Recency — a double-tap drained from the band's flash carries an OLD timestamp;
//    we refuse to act on anything that didn't happen in the last few seconds, so a
//    sync catch-up can't fire play/pause for a tap from this morning. (Only applies
//    when the band ts is plausible; a bogus RTC falls through to the debounce alone.)
//  • Debounce — the band can emit the event more than once per physical tap.

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'device_action.dart';
import 'gesture_settings.dart';
import '../platform/device_actions.dart';

class GestureDispatcher {
  final GestureSettings settings;
  final void Function(String line)? log;

  /// In-app action handlers (supplied by AppState). Native actions go to the
  /// platform channel instead.
  final Future<void> Function()? onMarkMoment;
  final Future<void> Function()? onWorkoutToggle;
  final Future<void> Function()? onLogWater;

  GestureDispatcher({
    required this.settings,
    this.log,
    this.onMarkMoment,
    this.onWorkoutToggle,
    this.onLogWater,
  });

  static const int _doubleTapEventId = 14; // EventId.doubleTap
  static const int _recencyWindowSec = 6; // older than this = a drained/historical tap
  static const int _plausibleAgeCapSec = 86400; // ignore the recency check if ts looks bogus
  static const int _debounceMs = 2000;

  /// The wall clock the recency window and the debounce read. Tests only.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  int _lastFiredMs = 0;

  /// Feed every live event here (id, band timestamp seconds, raw hex). Cheap to call
  /// for non-gesture events — it returns immediately.
  void onEvent(int eventId, int tsEpoch, String hex) {
    if (eventId != _doubleTapEventId) return;
    final action = settings.doubleTap;
    if (action == DeviceAction.none) return;

    final nowSec = now().millisecondsSinceEpoch ~/ 1000;
    final age = nowSec - tsEpoch;
    // Stale only when the ts is plausibly a real (recent-ish but past) historical
    // record. A wildly-off ts from an unset RTC is treated as "can't tell" → allow,
    // and rely on debounce + the live-only wiring.
    if (tsEpoch > 0 && age > _recencyWindowSec && age < _plausibleAgeCapSec) {
      log?.call('[gesture] ignoring stale double-tap (${age}s old)');
      return;
    }

    final nowMs = now().millisecondsSinceEpoch;
    if (nowMs - _lastFiredMs < _debounceMs) return;
    _lastFiredMs = nowMs;

    log?.call('[gesture] double-tap → ${action.id}');
    if (action.isInApp) {
      switch (action) {
        case DeviceAction.markMoment:
          onMarkMoment?.call();
          break;
        case DeviceAction.workoutToggle:
          onWorkoutToggle?.call();
          break;
        case DeviceAction.logWater:
          onLogWater?.call();
          break;
        default:
          // isInApp said yes and there is no case for it — an action that is
          // offered in the picker and then does nothing, which is the exact
          // failure the picker exists to end. Say so rather than return quietly.
          log?.call('[gesture] ${action.id} is in-app with no handler');
          break;
      }
      return;
    }
    DeviceActions.perform(action.id);
  }
}
