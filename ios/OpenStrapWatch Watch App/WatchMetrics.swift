// WatchMetrics — the today snapshot the watch renders.
//
// Watch App target only. WatchStore receives the payload over WCSession and
// caches it here; the glance reads it back. This used to be stored in an App
// Group ("group.wtf.openstrap.watch") that the watch entitlement never declared
// — a suite nobody else could open, kept alive for a complication extension
// that was never in the Xcode project. One process writes and reads it, so
// standard defaults are the whole requirement.
//
// HONESTY: the phone forbids a bare dash and a zero-filled ring for an absent
// metric. Text helpers return "" and ring fractions return a negative sentinel
// so the views can leave the slot empty instead of drawing "0". And `hasData`
// is not enough on its own — it is a bool frozen when the phone pushed, so the
// wrist gates on `fresh`, which ages `updatedAt` at render time.

import Foundation

/// How old a snapshot may be before the wrist stops presenting it as today's
/// answer: one whole missed wake cycle plus a little grace. Same value and same
/// reasoning as `kStaleAfter` in ios/OpenStrapWidget/OpenStrapWidget.swift —
/// separate build targets, so it cannot be one declaration.
let kStaleAfter: TimeInterval = 26 * 3600

struct WatchMetrics {
  var hasData: Bool
  var readiness: Int      // 0–100, -1 = none
  /// Readiness tier, straight from Dart. The thresholds live in exactly one
  /// place — `readinessBand` in lib/ui2/screens/home_screen.dart, published as
  /// `readiness_tier`. Never re-derive a band from `readiness` here: the watch
  /// used to call 38 "yellow" while the phone called the same score red.
  var tier: Int           // -1 not scored · 0 rest · 1 easy · 2 steady · 3 good
  var band: String        // the phone's own label for `tier`
  var strain: Double      // 0–21, -1 = none
  var sleepMin: Int       // minutes asleep, -1 = none
  var needMin: Int        // sleep need (min); -1 = none — never fabricate 8h
  var hrv: Int            // RMSSD ms, -1 = none
  var hrvBaseline: Int    // baseline RMSSD ms, -1 = none
  var rhr: Int            // bpm, -1 = none
  var coachLine: String
  var battPct: Int        // strap battery %, -1 = unknown
  var updatedAt: Int      // epoch sec
  var themeDark: Bool     // mirror the app's Ember-on-Paper (false) / Char (true)
  /// The recovery ring exactly as Dart resolved it for the widgets
  /// (`ring_recovery_*`). `readiness` is -1 for a calibrating baseline, a
  /// provisional score still finishing and a held-over night alike; this is
  /// what tells them apart. A payload from an app that predates these keys
  /// reads as absent with no reason, which is the old "Not scored".
  var recoveryState: Int  // 0 measured · 1 calibrating/provisional · 2 absent
  var recoveryValue: String
  var recoverySub: String
  var recoveryWhy: String
  var recoveryFrac: Double  // negative = nothing honest to sweep
  /// Why the overnight figures are not today's own; "" when they are.
  var overnightWhy: String

  static let empty = WatchMetrics(
    hasData: false, readiness: -1, tier: -1, band: "", strain: -1, sleepMin: -1,
    needMin: -1, hrv: -1, hrvBaseline: -1, rhr: -1, coachLine: "", battPct: -1,
    updatedAt: 0, themeDark: true, recoveryState: 2, recoveryValue: "",
    recoverySub: "", recoveryWhy: "", recoveryFrac: -1, overnightWhy: "")

  static func load() -> WatchMetrics {
    let d = UserDefaults.standard
    return WatchMetrics(
      hasData: d.bool(forKey: "has_data"),
      readiness: d.object(forKey: "readiness") as? Int ?? -1,
      tier: d.object(forKey: "readiness_tier") as? Int ?? -1,
      band: d.string(forKey: "readiness_band") ?? "",
      strain: d.object(forKey: "strain") as? Double ?? -1,
      sleepMin: d.object(forKey: "sleep_min") as? Int ?? -1,
      needMin: d.object(forKey: "sleep_need_min") as? Int ?? -1,
      hrv: d.object(forKey: "hrv") as? Int ?? -1,
      hrvBaseline: d.object(forKey: "hrv_baseline") as? Int ?? -1,
      rhr: d.object(forKey: "rhr") as? Int ?? -1,
      coachLine: d.string(forKey: "coach_line") ?? "",
      battPct: d.object(forKey: "batt_pct") as? Int ?? -1,
      updatedAt: d.object(forKey: "updated_at") as? Int ?? 0,
      themeDark: d.object(forKey: "theme_dark") as? Bool ?? true,
      recoveryState: d.object(forKey: "ring_recovery_state") as? Int ?? 2,
      recoveryValue: d.string(forKey: "ring_recovery_value") ?? "",
      recoverySub: d.string(forKey: "ring_recovery_sub") ?? "",
      recoveryWhy: d.string(forKey: "ring_recovery_why") ?? "",
      recoveryFrac: d.object(forKey: "ring_recovery_frac") as? Double ?? -1,
      overnightWhy: d.string(forKey: "overnight_why") ?? "")
  }

  /// No final score yet, but the phone has progress to show: baseline nights
  /// banked ("Calibrating" · "2 of 4 nights") or a provisional number that is
  /// "Finishing up". Drawn muted, never as a reading.
  var recoveryPending: Bool {
    readiness < 0 && recoveryState == 1 && !recoveryValue.isEmpty
  }

  /// The reason behind a bare "Not scored": the held-over sentence first (the
  /// same order the overnight widget uses), then the ring's own reason.
  var notScoredWhy: String {
    guard readiness < 0, !recoveryPending else { return "" }
    return overnightWhy.isEmpty ? recoveryWhy : overnightWhy
  }

  /// Is this still today's answer? An unknown timestamp is not a claim of
  /// staleness (a snapshot that never got a push has `hasData` false anyway).
  var fresh: Bool {
    guard hasData else { return false }
    guard updatedAt > 0 else { return true }
    return Date().timeIntervalSince1970 - Double(updatedAt) <= kStaleAfter
  }

  // MARK: Display helpers
  // "" = no measurement. The score the phone calls READINESS out of 100 is not
  // a percentage and is not called Recovery — one number, one name, one unit.

  var readinessText: String { readiness >= 0 ? "\(readiness)" : "" }
  var strainText: String { strain >= 0 ? String(format: "%.1f", strain) : "" }
  var hrvText: String { hrv >= 0 ? "\(hrv)" : "" }
  var rhrText: String { rhr >= 0 ? "\(rhr)" : "" }
  /// "45m" / "7h 05m" — the phone's `hm()` (lib/ui2/screens/home_screen.dart).
  var sleepText: String {
    guard sleepMin >= 0 else { return "" }
    if sleepMin < 60 { return "\(sleepMin)m" }
    return String(format: "%dh %02dm", sleepMin / 60, sleepMin % 60)
  }

  // Ring fractions; negative = nothing measured, so draw the track only.
  var readinessFraction: Double { readiness >= 0 ? Double(readiness) / 100.0 : -1 }
  /// Strain ring fraction 0–1. 0–21 is the headline scale `strainScore` maps
  /// TRIMP onto (analytics/lib/src/onehz/clinical/load_trimp.dart:104-122).
  var strainFraction: Double { strain >= 0 ? min(strain / 21.0, 1) : -1 }
  /// Sleep-vs-need fraction 0–1.
  var sleepFraction: Double {
    guard sleepMin >= 0, needMin > 0 else { return -1 }
    return min(Double(sleepMin) / Double(needMin), 1)
  }
}
