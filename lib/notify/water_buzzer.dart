// water_buzzer.dart — fires a strap haptic alongside the hydration reminder.
//
// The OS-scheduled water notification (see NotificationCenter) fires even when
// the app is dead, but a strap buzz needs a live BLE link AND a live Dart
// isolate — you can't buzz a band that isn't connected. So this is BEST-EFFORT:
// an in-memory timer (re-armed every app launch, since timers don't persist)
// that fires at each hydration slot and buzzes ONLY if the band is connected.
//
// Slot times come verbatim from NotificationCenter.waterSlotMinutes() so the
// buzz and the OS notification land at the same wall-clock moment.

import 'dart:async';

class WaterBuzzer {
  WaterBuzzer({required this.buzz, required this.isConnected});

  /// Sends one short haptic to the strap (no-op if the link isn't ready).
  final Future<void> Function() buzz;

  /// Whether the strap is currently connected (checked lazily at fire time).
  final bool Function() isConnected;

  Timer? _timer;
  bool _enabled = false;
  List<int> _slots = const []; // minutes-from-midnight, ascending

  /// (Re)configure from the current prefs. Idempotent — cancels and re-arms.
  /// Pass `NotificationCenter.waterSlotMinutes(prefs)` as [slotMinutes].
  void configure({required bool enabled, required List<int> slotMinutes}) {
    _enabled = enabled;
    _slots = List<int>.from(slotMinutes)..sort();
    _reschedule();
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (!_enabled || _slots.isEmpty) return;

    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;

    // Next slot later today, else the first slot tomorrow.
    int deltaMin;
    final next = _slots.where((s) => s > nowMin);
    if (next.isNotEmpty) {
      deltaMin = next.first - nowMin;
    } else {
      deltaMin = (1440 - nowMin) + _slots.first;
    }
    // Subtract the seconds already elapsed this minute so we land on the minute.
    var delay = Duration(minutes: deltaMin) - Duration(seconds: now.second);
    if (delay.isNegative) delay = Duration.zero;

    _timer = Timer(delay, _fire);
  }

  Future<void> _fire() async {
    if (_enabled && isConnected()) {
      try {
        await buzz();
      } catch (_) {/* link dropped mid-write — best effort */}
    }
    _reschedule(); // arm the next slot
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
