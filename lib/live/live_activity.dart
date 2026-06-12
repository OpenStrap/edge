// Live Activity bridge (iOS) — start/update/end the claymorphic workout Live
// Activity on the lock screen + Dynamic Island. No-ops on Android / older iOS
// (the MethodChannel simply isn't there → MissingPluginException, swallowed).

import 'package:flutter/services.dart';

class LiveActivity {
  static const MethodChannel _ch = MethodChannel('openstrap/live_activity');
  static bool _active = false;

  static bool get isActive => _active;

  /// Start the activity for a session. [startedAt] drives the live timer.
  static Future<void> start({
    required DateTime startedAt,
    required int targetKcal,
    required int maxHr,
    required int rhr,
    String name = 'Live session',
  }) async {
    try {
      await _ch.invokeMethod('start', {
        'name': name,
        'startedAtMs': startedAt.millisecondsSinceEpoch,
        'targetKcal': targetKcal,
        'hr': 0, 'zone': 0, 'strain': 0.0, 'calories': 0,
        'maxHr': maxHr, 'rhr': rhr,
      });
      _active = true;
    } catch (_) {/* not iOS / not supported */}
  }

  /// Push a new content state. Caller should throttle (~every 3–5s).
  static Future<void> update({
    required int hr,
    required int zone,
    required double strain,
    required int calories,
    required int maxHr,
    required int rhr,
  }) async {
    if (!_active) return;
    try {
      await _ch.invokeMethod('update', {
        'hr': hr, 'zone': zone, 'strain': strain, 'calories': calories,
        'maxHr': maxHr, 'rhr': rhr,
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
