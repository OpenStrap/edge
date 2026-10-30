// water_buzzer.dart — fires a strap haptic alongside the hydration reminder.
//
// The reminder is TWO things and this is the weaker half. The OS-scheduled
// notification (armed in NotificationCenter._armWaterSlots) fires even when the
// app is dead; a strap buzz needs a live BLE link AND a live Dart isolate — you
// can't buzz a band that isn't connected. So this is BEST-EFFORT: an in-memory
// timer (re-armed every app launch, since timers don't persist) that fires at
// each hydration slot and buzzes ONLY if the band is connected. A missed buzz
// costs nothing, because the notification is what actually reminds.
//
// Slot times come verbatim from NotificationCenter.waterSlotMinutes(), the same
// list the notification is armed from, so the two land at the same wall-clock
// minute.

import 'dart:async';

import 'package:flutter/foundation.dart';

class WaterBuzzer {
  WaterBuzzer({
    required this.buzz,
    required this.isConnected,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Sends one short haptic to the strap (no-op if the link isn't ready).
  final Future<void> Function() buzz;

  /// Whether the strap is currently connected (checked lazily at fire time).
  final bool Function() isConnected;

  final DateTime Function() _now;

  /// How late (wall-clock) a fire may land and still buzz. Dart timers run on
  /// the monotonic clock, which stops while the device is suspended, so a timer
  /// armed hours ahead can expire hours after its slot (e.g. a 21:00 slot
  /// going off at 01:30). Past this, the slot is skipped and the next re-armed.
  static const lateTolerance = Duration(minutes: 10);

  Timer? _timer;
  DateTime? _due; // wall-clock instant the pending timer is meant to fire
  bool _enabled = false;
  List<int> _slots = const []; // minutes-from-midnight, ascending

  /// Wall-clock instant the pending timer is meant to fire, if armed.
  @visibleForTesting
  DateTime? get debugDue => _due;

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
    _due = null;
    if (!_enabled || _slots.isEmpty) return;

    final now = _now();
    final nowMin = now.hour * 60 + now.minute;

    // Next slot later today, else the first slot tomorrow. The target is built
    // from calendar fields rather than by adding minutes to now: across a DST
    // change midnight-to-slot is not 24 h of wall clock, and an elapsed-minutes
    // delay would buzz an hour early (inside quiet hours) on fall-back night
    // while the notification for the same slot still lands on time.
    final next = _slots.where((s) => s > nowMin);
    final slot = next.isNotEmpty ? next.first : _slots.first;
    final target = DateTime(now.year, now.month,
        now.day + (next.isNotEmpty ? 0 : 1), slot ~/ 60, slot % 60);
    var delay = target.difference(now);
    if (delay.isNegative) delay = Duration.zero;

    _due = target;
    _timer = Timer(delay, _fire);
  }

  Future<void> _fire() async {
    final due = _due;
    final onTime = due != null && _now().difference(due) <= lateTolerance;
    if (_enabled && onTime && isConnected()) {
      try {
        await buzz();
      } catch (_) {/* link dropped mid-write — best effort */}
    }
    _reschedule(); // arm the next slot
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _due = null;
  }
}
