// reset_gate.dart — ONE process-wide "delete everything is running" flag.
//
// `AppState.resetAllData()` wipes the database but leaves the strap CONNECTED:
// its own documented order puts `signOut` — and the `unpair` inside it — LAST,
// because that flips the route and unwinds the UI. So records keep arriving
// across the wipe, and one that lands after it is written into the fresh
// database: the deleted installation, back again.
//
// AppState guards its own two ingest callbacks. It cannot guard the OTHER
// engine — `runHeadlessSync` (background_sync.dart) builds a second BleEngine
// whose callbacks go straight to LocalDb, with no AppState anywhere in scope.
// A drain already in flight when the user confirms the reset therefore keeps
// writing. Narrow, because a foreground engine PREEMPTS a background drainer
// when it connects (`BleEngine._claimBand`) and AppState connects on launch —
// but nothing in the reset itself closes it, and "deleted data comes back" is
// not a failure to leave resting on an incidental ordering.
//
// A STATIC is the right mechanism here, and only because there is no second
// isolate to hide from it. Every headless entry point runs in the MAIN isolate:
//   - Android post-boot — EdgeApplication.onCreate pre-warms the FlutterEngine
//     and runs `main()` with no Activity (headless_boot.dart)
//   - iOS CoreBluetooth restore wake (ios_ble_restore.dart)
//   - iOS BGProcessingTask / BGAppRefreshTask (ios_bg_task.dart)
// and the WorkManager tasks that DID run on their own isolate were pulled for
// exactly that reason — `main()` still cancels them by unique name on every
// Android start (main.dart), and nothing registers a `callbackDispatcher`.
// `HeadlessSyncGate` is already built on the same assumption.
//
// IF A BACKGROUND ISOLATE IS EVER REINTRODUCED, this flag stops working and
// stops working SILENTLY — statics are per-isolate. It would then have to move
// to something both isolates can see (a `sync_cursor` row, a pref read per
// batch). Said here rather than discovered later.
library;

/// Process-wide: is "delete everything" running right now?
///
/// Every path that writes band data consults this before it writes. Refusing
/// costs nothing — none of these records have been ACKed, so they are still on
/// the band and arrive on the next sync.
class ResetGate {
  ResetGate._();

  /// How many resets are in flight, not whether one is.
  ///
  /// `resetAllData()` is awaited but does not block the UI: the confirm dialog
  /// is already dismissed when it starts, `backToRoot` only runs when it ends,
  /// and a wipe of a real database takes seconds. So a user can walk back into
  /// Settings and confirm a second one on top of the first. With a bare bool
  /// the first to finish lowers the flag while the second is still wiping —
  /// reopening the exact window this class exists to close, at the worst
  /// possible moment. Counted, the gate stays shut until the LAST one leaves.
  static int _depth = 0;

  /// True from the moment a reset starts until the last one finishes (or
  /// throws).
  static bool get active => _depth > 0;

  /// Raise before the wipe. Pair with [leave] in a `finally`: a half-reset
  /// install that silently drops every record is worse than the race this
  /// closes.
  static void enter() => _depth++;

  /// Clamped at zero rather than allowed to go negative: an unbalanced [leave]
  /// is a bug, but one that drove the count below zero would make the NEXT
  /// reset's `enter()` fail to open the gate, which is the failure that loses
  /// data. Absorb it here instead.
  static void leave() {
    if (_depth > 0) _depth--;
  }

  /// Test seam — the count is static, so a test that raises it must be able to
  /// put it back even if it fails.
  static void resetForTest() => _depth = 0;
}
