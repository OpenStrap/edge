// WatchBridge — phone → Apple Watch data ferry (WatchConnectivity).
//
// iPhone and Apple Watch do NOT share an App Group container (they're separate
// devices), so the watch cannot read the phone's App Group directly. This bridge
// takes the exact snapshot the app already writes for the home-screen widget
// (WidgetService → home_widget → App Group UserDefaults) and pushes it to the
// watch over WCSession. The watch caches it locally and its glance renders from
// that (there are no complications — see WatchStore.swift). One source of truth: we never recompute here, we mirror.
//
// Trigger: Dart calls the `syncWatch` method on the existing `openstrap/ios_config`
// channel right after it updates the widget (see WidgetService). We also push on
// session (re)activation so the watch is fresh the moment it connects.

import Foundation
import WatchConnectivity

final class WatchBridge: NSObject, WCSessionDelegate {
  static let shared = WatchBridge()

  // The keys mirrored from WidgetService.push()/pushBattery(). Kept in lockstep
  // with lib/widget/widget_service.dart and OpenStrapWidget.swift.
  private static let intKeys = [
    "readiness", "readiness_tier", "hrv", "hrv_baseline", "sleep_min",
    "sleep_need_min", "rhr", "updated_at", "batt_pct", "batt_at",
    "ring_recovery_state",
  ]
  // The resolved recovery ring and the held-over reason carry what the bare
  // `readiness` int cannot: -1 is written for a calibrating baseline, a
  // provisional score that is still finishing, and a night held over alike.
  // Without them the wrist could only say "Not scored" while the phone and
  // both widgets say why.
  private static let doubleKeys = ["strain", "ring_recovery_frac"]
  private static let stringKeys = [
    "readiness_band", "coach_line", "batt_name", "overnight_why",
    "ring_recovery_value", "ring_recovery_sub", "ring_recovery_why",
  ]
  private static let boolKeys = ["has_data", "batt_charging", "theme_dark"]

  private var appGroupId: String {
    Bundle.main.object(forInfoDictionaryKey: "OpenStrapAppGroupIdentifier") as? String
      // Same fallback as AppGroup.swift and WidgetService.fallbackAppGroupId —
      // see the note there.
      ?? "group.com.example.openstrap"
  }

  /// Activate the WCSession. Safe to call once at launch; no-op if unsupported
  /// (iPad / no paired watch handled gracefully by the framework).
  func activate() {
    guard WCSession.isSupported() else { return }
    let s = WCSession.default
    s.delegate = self
    s.activate()
  }

  /// Read the current App Group snapshot into a plist-safe dictionary.
  private func snapshot() -> [String: Any] {
    guard let d = UserDefaults(suiteName: appGroupId) else { return [:] }
    var out: [String: Any] = [:]
    for k in Self.intKeys { if let v = d.object(forKey: k) as? Int { out[k] = v } }
    for k in Self.doubleKeys { if let v = d.object(forKey: k) as? Double { out[k] = v } }
    for k in Self.stringKeys { if let v = d.string(forKey: k) { out[k] = v } }
    for k in Self.boolKeys { if let v = d.object(forKey: k) as? Bool { out[k] = v } }
    return out
  }

  /// Push the latest snapshot to the watch. `updateApplicationContext` delivers a
  /// single coalesced latest-state in the background — exactly right for "today's
  /// numbers". Best-effort.
  ///
  /// No complication transfer: the watch ships no complications (their sources
  /// were never in the Xcode project), so `transferCurrentComplicationUserInfo`
  /// was spending a scarce daily budget on a face that cannot show it.
  func pushCurrentState() {
    guard WCSession.isSupported() else { return }
    let s = WCSession.default
    guard s.activationState == .activated else { return }
    let payload = snapshot()
    guard !payload.isEmpty else { return }
    do { try s.updateApplicationContext(payload) } catch { /* transient — next push retries */ }
  }

  // MARK: - WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if activationState == .activated { pushCurrentState() }
  }

  // The watch can pull the latest on demand (e.g. right after it activates).
  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    replyHandler(snapshot())
  }

  // Required on iOS so the session can hand off between paired watches.
  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
