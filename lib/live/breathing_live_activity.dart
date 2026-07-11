// Breathing-session Live Activity bridge (iOS) — start/update/end the
// lock-screen + Dynamic Island coherence readout. Separate MethodChannel and
// native attributes type from the workout Live Activity (live_activity.dart)
// on purpose — different content, and keeps the two independent so neither
// risks the other. No-ops on Android / older iOS (the MethodChannel simply
// isn't there → MissingPluginException, swallowed).

import 'package:flutter/services.dart';

class BreathingLiveActivity {
  static const MethodChannel _ch = MethodChannel(
    'openstrap/breathing_live_activity',
  );
  static bool _active = false;

  static bool get isActive => _active;

  /// Start the activity for a breathing session. [startedAt] drives the live
  /// timer. No coherence score yet — the widget shows "Calibrating…".
  static Future<void> start({required DateTime startedAt}) async {
    try {
      await _ch.invokeMethod('start', {
        'startedAtMs': startedAt.millisecondsSinceEpoch,
        'coherenceScore': -1.0,
      });
      _active = true;
    } catch (_) {/* not iOS / not supported */}
  }

  /// Push a new coherence score (0-100). Pass null/absent to keep showing
  /// "Calibrating…" — never push a fabricated number.
  static Future<void> update({double? coherenceScore}) async {
    if (!_active) return;
    try {
      await _ch.invokeMethod('update', {
        'coherenceScore': coherenceScore ?? -1.0,
      });
    } catch (_) {}
  }

  static Future<void> end() async {
    try {
      await _ch.invokeMethod('end');
    } catch (_) {}
    _active = false;
  }
}
