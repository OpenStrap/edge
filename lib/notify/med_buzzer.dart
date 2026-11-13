// med_buzzer.dart — fires a strap haptic at each scheduled medication dose.
//
// The mirror of WaterBuzzer for the medication reminder, and the weaker half
// by the same argument: the OS-scheduled dose notifications (armed in
// NotificationCenter._armMedSlots) fire even when the app is dead; a strap
// buzz needs a live BLE link AND a live Dart isolate. BEST-EFFORT — an
// in-memory timer (re-armed on every foreground pass, since timers don't
// persist) that buzzes ONLY if the band is connected at the dose instant. A
// missed buzz costs nothing: the notification is what actually reminds, and
// the checklist behind it is where the dose gets recorded.
//
// Where water slots are daily wall-clock MINUTES (recurring), doses are
// ONE-SHOT ABSOLUTE instants — `med_def` schedules land on specific days
// (slotsForDay already resolved taken/skipped/past for today), and
// medPromptSlots hands back exactly the still-upcoming slots over its 3-day
// horizon. So this class consumes DateTimes, not minutes-from-midnight.

import 'dart:async';

class MedBuzzer {
  MedBuzzer({
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
  /// armed hours ahead can expire hours after its slot — at night, for a dose
  /// the notification already covered. Past this, the slot is dropped silently.
  static const lateTolerance = Duration(minutes: 10);

  Timer? _timer;
  List<DateTime> _slots = const []; // absolute instants, ascending

  /// (Re)configure from the current prefs + schedule. Idempotent — cancels and
  /// re-arms. Pass `NotificationCenter.medPromptSlots(...)` mapped through
  /// `NotificationCenter.medSlotInstant(...)` (nulls dropped) as [slotInstants].
  /// Past instants are skipped, not fired late: a buzz for a dose window that
  /// already passed is noise about a decision the user already made.
  void configure({required List<DateTime> slotInstants}) {
    final now = _now();
    _slots = slotInstants.where((t) => t.isAfter(now)).toList()..sort();
    _reschedule();
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (_slots.isEmpty) return; // also guards the const [] left by dispose()

    final now = _now();
    // Drop slots already too late to buzz. Without this, one late fire after a
    // suspend would re-arm the next missed slot at zero delay and every missed
    // dose would buzz back to back.
    _slots.removeWhere((t) => now.difference(t) > lateTolerance);
    if (_slots.isEmpty) return;

    final next = _slots.first;
    var delay = next.difference(now);
    if (delay.isNegative) delay = Duration.zero;

    _timer = Timer(delay, _fire);
  }

  Future<void> _fire() async {
    // Consume the slot whether or not the buzz landed — the link being down at
    // the dose instant is not a reason to re-buzz minutes later.
    if (_slots.isEmpty) return;
    final slot = _slots.removeAt(0);
    final onTime = _now().difference(slot) <= lateTolerance;
    if (onTime && isConnected()) {
      try {
        await buzz();
      } catch (_) {/* link dropped mid-write — best effort */}
    }
    _reschedule(); // arm the next dose, if any remain in this batch
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _slots = const [];
  }
}
