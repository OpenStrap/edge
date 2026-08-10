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
        // Null, not 0 — nothing has been measured at the moment the activity
        // starts, and the widget renders an absent strain/kcal as "—".
        'hr': 0, 'zone': 0, 'strain': null, 'calories': null,
        'maxHr': maxHr, 'rhr': rhr,
      });
      _active = true;
    } catch (_) {/* not iOS / not supported */}
  }

  /// Push a new content state. Caller should throttle (~every 3–5s).
  ///
  /// [strain] and [calories] are NULLABLE and must be passed through as null
  /// when the session cannot be scored — a profile without the anchors Keytel
  /// and Banister read, or a band that has not delivered a heart rate yet. They
  /// were coerced to 0 here, so a new user's lock screen read a confident
  /// "0 kcal" for a whole workout while the in-app gauge correctly read "—".
  static Future<void> update({
    required int hr,
    required int zone,
    required double? strain,
    required int? calories,
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
