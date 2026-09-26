// OpenStrap App Intents — Siri / Shortcuts / Spotlight / Ultra Action Button.
//
// Add to the Runner (iOS app) target. These read the phone's App Group snapshot
// (the same keys WidgetService writes) and answer spoken/dialog queries. Because
// they're AppShortcuts, they work with zero user setup: "Hey Siri, OpenStrap
// recovery". The Apple Watch Ultra's Action Button can be bound to any of these
// via Settings ▸ Action Button ▸ Shortcut.

import AppIntents
import Foundation

// MARK: - Shared reader

enum OpenStrapShared {
  static var appGroup: String {
    Bundle.main.object(forInfoDictionaryKey: "OpenStrapAppGroupIdentifier") as? String
      // Same fallback as AppGroup.swift and WidgetService.fallbackAppGroupId:
      // the build-configured default (ios/Config/Signing.defaults.xcconfig).
      // Three different fallbacks for one group meant that if Info.plist ever
      // went missing, Siri and the widget would read different suites.
      ?? "group.com.example.openstrap"
  }

  static func defaults() -> UserDefaults? { UserDefaults(suiteName: appGroup) }

  /// `has_data` is the phone saying the snapshot is non-empty and describes a
  /// recent day — but it is a bool frozen when the phone last pushed, so on a
  /// phone that stopped syncing it stays true forever. Siri answers in the
  /// present tense, so it ages `updated_at` here, at answer time.
  ///
  /// Same 26 h and same reasoning as `kStaleAfter` in
  /// ios/OpenStrapWidget/OpenStrapWidget.swift and WatchMetrics.swift —
  /// separate build targets, so it cannot be one declaration.
  static let staleAfter: TimeInterval = 26 * 3600

  static var hasData: Bool {
    guard defaults()?.bool(forKey: "has_data") ?? false else { return false }
    let at = defaults()?.object(forKey: "updated_at") as? Int ?? 0
    // An unknown timestamp is not a claim of staleness.
    return at <= 0 || Date().timeIntervalSince1970 - Double(at) <= staleAfter
  }
  static var readiness: Int { defaults()?.object(forKey: "readiness") as? Int ?? -1 }
  /// The phone's own band label, published as `readiness_band` (thresholds:
  /// `readinessBand` in lib/ui2/screens/home_screen.dart). Siri used to carry a
  /// fourth private copy of the cut-offs, so it called 65 "moderate" while the
  /// phone said "Steady" and the widget drew orange.
  static var readinessBand: String { defaults()?.string(forKey: "readiness_band") ?? "" }
  static var strain: Double { defaults()?.object(forKey: "strain") as? Double ?? -1 }
  static var hrv: Int { defaults()?.object(forKey: "hrv") as? Int ?? -1 }
  static var rhr: Int { defaults()?.object(forKey: "rhr") as? Int ?? -1 }
  static var sleepMin: Int { defaults()?.object(forKey: "sleep_min") as? Int ?? -1 }

  /// Spoken, so it is words rather than the phone's "7h 05m" — but a 45-minute
  /// nap is not "0 hours 45 minutes".
  static var sleepText: String {
    guard sleepMin >= 0 else { return "no sleep data yet" }
    let h = sleepMin / 60, m = sleepMin % 60
    if h == 0 { return "\(m) minutes" }
    if m == 0 { return h == 1 ? "1 hour" : "\(h) hours" }
    return "\(h) \(h == 1 ? "hour" : "hours") \(m) minutes"
  }
  static var noData: String { "I don't have today's numbers yet. Open OpenStrap and sync your band." }
}

// MARK: - Intents

@available(iOS 16.0, *)
struct RecoveryIntent: AppIntent {
  static var title: LocalizedStringResource = "Check Readiness"
  static var description = IntentDescription("Ask OpenStrap for today's readiness.")
  static var openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard OpenStrapShared.hasData, OpenStrapShared.readiness >= 0 else {
      return .result(dialog: IntentDialog(stringLiteral: OpenStrapShared.noData))
    }
    // "Readiness, out of 100" — the app's own name and unit. It is not a
    // percentage and it is not called Recovery anywhere else in the product.
    let band = OpenStrapShared.readinessBand
    let line = "Your readiness is \(OpenStrapShared.readiness) out of 100."
    return .result(dialog: IntentDialog(
      stringLiteral: band.isEmpty ? line : "\(line) \(band)."))
  }
}

@available(iOS 16.0, *)
struct StrainIntent: AppIntent {
  static var title: LocalizedStringResource = "Check Strain"
  static var description = IntentDescription("Ask OpenStrap for today's strain.")
  static var openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard OpenStrapShared.hasData, OpenStrapShared.strain >= 0 else {
      return .result(dialog: IntentDialog(stringLiteral: OpenStrapShared.noData))
    }
    let s = String(format: "%.1f", OpenStrapShared.strain)
    return .result(dialog: "Today's strain so far is \(s) out of twenty-one.")
  }
}

@available(iOS 16.0, *)
struct SleepIntent: AppIntent {
  static var title: LocalizedStringResource = "Check Sleep"
  static var description = IntentDescription("Ask OpenStrap how you slept.")
  static var openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard OpenStrapShared.hasData, OpenStrapShared.sleepMin >= 0 else {
      return .result(dialog: IntentDialog(stringLiteral: OpenStrapShared.noData))
    }
    return .result(dialog: "You slept \(OpenStrapShared.sleepText) last night.")
  }
}

// MARK: - Action intents (these actually DO something, not just answer)

/// "Start breathing" — unlike the query intents above, this needs the live
/// Flutter engine + BLE stack (a guided session reads live RR from the band),
/// so it must open the app rather than answer standalone. Writes the target
/// route into the App Group; the Dart side picks it up via
/// WidgetService.consumePendingRoute() on launch AND on every foreground
/// resume (see AppState.checkPendingSiriRoute — openAppWhenRun doesn't
/// guarantee a fresh launch, it may just foreground an already-running
/// process, so both call sites matter).
@available(iOS 16.0, *)
struct StartBreathingIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Breathing Session"
  static var description = IntentDescription(
    "Start a guided resonance-breathing session in OpenStrap.")
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult & ProvidesDialog {
    OpenStrapShared.defaults()?.set("/breathing", forKey: "pending_route")
    return .result(dialog: "Starting your breathing session.")
  }
}

/// "Enable tomorrow's alarm" — the other action intent. It does not carry a
/// time: it turns on whatever hour/minute tomorrow's weekday already has in
/// the app's weekly schedule (same toggle as the Alarm screen), so there is
/// nothing to ask Siri to parse and nothing that can silently pick the wrong
/// time. Setting the actual band alarm needs a live BLE connection the
/// widget process doesn't have, so — same as [StartBreathingIntent] — this
/// just latches a flag and opens the app; AppState.checkPendingSiriRoute
/// consumes it and does the real write (setScheduleDay → engine.setAlarm) on
/// launch/resume.
@available(iOS 16.0, *)
struct EnableTomorrowAlarmIntent: AppIntent {
  static var title: LocalizedStringResource = "Enable Tomorrow's Alarm"
  static var description = IntentDescription(
    "Turn on tomorrow's alarm at whatever time you already set for that weekday in OpenStrap.")
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult & ProvidesDialog {
    // "Tomorrow" is fixed HERE, at the moment Siri actually ran this, not
    // whenever AppState happens to consume the latch — a request made just
    // before local midnight must still mean the day the user asked for, even
    // if the app doesn't launch/resume until after midnight has rolled over.
    // Calendar's `.weekday` is 1=Sun..7=Sat; AlarmScheduleEntry's column
    // (lib/state/alarm_schedule.dart) is 0=Mon..6=Sun — `(weekday + 5) % 7`
    // converts one to the other (Mon 2→0 … Sat 7→5, Sun 1→6).
    let cal = Calendar.current
    let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    let column = (cal.component(.weekday, from: tomorrow) + 5) % 7
    OpenStrapShared.defaults()?.set(column, forKey: "enable_tomorrow_alarm_weekday")
    // Same App Group route latch StartBreathingIntent uses, so the user lands
    // on the Alarm screen and can see the toggle actually flipped rather than
    // wondering whether Siri did anything.
    OpenStrapShared.defaults()?.set("/alarm", forKey: "pending_route")
    return .result(dialog: "Turning on tomorrow's alarm.")
  }
}

// MARK: - Shortcuts provider (zero-setup Siri phrases)

@available(iOS 16.0, *)
struct OpenStrapShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RecoveryIntent(),
      phrases: [
        "\(.applicationName) readiness",
        "What's my readiness in \(.applicationName)",
        "\(.applicationName) recovery",
        "How recovered am I in \(.applicationName)",
      ],
      shortTitle: "Readiness",
      systemImageName: "bolt.heart")

    AppShortcut(
      intent: StrainIntent(),
      phrases: [
        "\(.applicationName) strain",
        "What's my strain in \(.applicationName)",
      ],
      shortTitle: "Strain",
      systemImageName: "flame")

    AppShortcut(
      intent: SleepIntent(),
      phrases: [
        "\(.applicationName) sleep",
        "How did I sleep in \(.applicationName)",
      ],
      shortTitle: "Sleep",
      systemImageName: "moon.zzz")

    AppShortcut(
      intent: StartBreathingIntent(),
      phrases: [
        "Start breathing in \(.applicationName)",
        "\(.applicationName) breathe",
        "Start a breathing session in \(.applicationName)",
        "Breathe with \(.applicationName)",
      ],
      shortTitle: "Breathe",
      systemImageName: "wind")

    AppShortcut(
      intent: EnableTomorrowAlarmIntent(),
      phrases: [
        "Enable tomorrow's alarm in \(.applicationName)",
        "Turn on tomorrow's alarm in \(.applicationName)",
        "\(.applicationName) enable tomorrow's alarm",
      ],
      shortTitle: "Tomorrow's Alarm",
      systemImageName: "alarm")
  }
}
