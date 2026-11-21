//
//  OpenStrapBatteryWidget.swift
//  OpenStrapWidget
//
//  Lock-screen (and home-screen) widget showing the BAND's battery level.
//
//  Battery is a live BLE value (GET_BATTERY / HELLO) that only the app knows —
//  it is NOT part of /today — so unlike OpenStrapWidget this one does NOT
//  self-refresh over the network. It renders the last snapshot the app wrote
//  into the shared App Group (keys batt_pct / batt_charging / batt_at) the last
//  time the band was connected. Until we have ever seen the band it says so in
//  words — it never draws a bar at empty, which reads as "0%".
//
//  Primary surface is the lock screen (accessory* families); a systemSmall
//  variant is included so it can also live on the home screen.
//

import WidgetKit
import SwiftUI

private let kAppGroup = AppGroup.identifier

// MARK: - Theme (lib/ui2/theme.dart; mirrors OpenStrapWidget's)

private extension Color {
  init(_ r: Int, _ g: Int, _ b: Int) {
    self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
  }
}

private struct BattPal {
  let bg: Color, ink: Color, inkMuted: Color, track: Color
  static let light = BattPal(bg: Color(0xFF, 0xFF, 0xFF), ink: Color(0x0F, 0x17, 0x2A),
                             inkMuted: Color(0x62, 0x71, 0x88), track: Color(0xE2, 0xE8, 0xF0))
  static let dark  = BattPal(bg: Color(0x15, 0x1C, 0x26), ink: Color(0xF1, 0xF5, 0xF9),
                             inkMuted: Color(0x7F, 0x8D, 0xA0), track: Color(0x23, 0x2D, 0x3B))
  static var current: BattPal {
    let isDark = UserDefaults(suiteName: kAppGroup)?.object(forKey: "theme_dark") as? Bool ?? false
    return isDark ? .dark : .light
  }
}

private extension Color {
  static var battPaper: Color { BattPal.current.bg }
  static var battInk: Color { BattPal.current.ink }
  static var battInkMuted: Color { BattPal.current.inkMuted }
  static var battTrack: Color { BattPal.current.track }
  // Raw ui2 pigment: a battery bar is non-text UI, so it spends `C.*` directly.
  static let battLow      = Color(0xF9, 0x73, 0x16)   // C.orange
  static let battCritical = Color(0xEF, 0x44, 0x44)   // C.red
  static let battGood     = Color(0x22, 0xC5, 0x5E)   // C.green
  static let battCharge   = Color(0x3B, 0x82, 0xF6)   // C.blue
}

// MARK: - Model

/// A battery reading older than this is not the band's current level — we
/// simply have not talked to it. Shorter than the metrics widget's 26 h
/// (OpenStrapWidget.swift) on purpose: readiness describes a night that stays
/// true all day, a battery percentage describes right now.
private let kBattStaleAfter: TimeInterval = 86_400

struct BatteryEntry: TimelineEntry {
  var date: Date
  let name: String      // the band's advertising name (falls back to "Band")
  let pct: Int          // -1 = never seen the band
  let charging: Bool
  let updatedAt: Int    // epoch seconds, 0 = unknown

  static let placeholder = BatteryEntry(
    date: Date(), name: "Band", pct: 68, charging: false,
    updatedAt: Int(Date().timeIntervalSince1970))

  var hasData: Bool { pct >= 0 }

  /// Computed from THIS ENTRY'S date, not from `Date()` at read time — the same
  /// reason the metrics widget does it: a flag frozen when the timeline was
  /// built can never go stale on its own, so WidgetKit renders the flip from an
  /// entry it already holds (see getTimeline).
  var stale: Bool {
    guard hasData, updatedAt > 0 else { return false }
    return date.timeIntervalSince1970 - Double(updatedAt) >= kBattStaleAfter
  }

  /// The instant this reading stops being the band's current level.
  var stalenessDeadline: Date? {
    guard hasData, updatedAt > 0 else { return nil }
    let at = Date(timeIntervalSince1970: Double(updatedAt) + kBattStaleAfter)
    return at > date ? at : nil
  }

  func at(_ d: Date) -> BatteryEntry { var c = self; c.date = d; return c }
  var t: Double { pct >= 0 ? min(max(Double(pct) / 100.0, 0), 1) : 0 }

  /// `charging` is a fact about the moment the app last wrote, so it goes stale
  /// with the level it came with. Without this the widget said "Charging" in
  /// blue, with a bolt, about a band that came off the puck four days ago —
  /// the charge branch was tested before the staleness branch everywhere.
  /// Mirrored in OpenStrapBatteryWidgetProvider.kt — keep the two in step.
  var chargingNow: Bool { charging && !stale }

  /// Coral when low, deep-coral when critical, blue while charging, otherwise ink.
  var color: Color {
    if !hasData { return .battInkMuted }
    if chargingNow { return .battCharge }
    if pct <= 10 { return .battCritical }
    if pct <= 25 { return .battLow }
    return .battGood
  }

  var valueText: String { pct >= 0 ? "\(pct)%" : "" }

  /// Icon: a charging bolt while plugged in, otherwise the band glyph
  /// (mirrors the app's device icon, HugeIcons SmartWatch01).
  var symbol: String { chargingNow ? "bolt.fill" : "applewatch" }
}

// MARK: - Shared store (App Group, read-only here)

private enum BatteryStore {
  static func read() -> BatteryEntry {
    let d = UserDefaults(suiteName: kAppGroup)
    let pct = d?.object(forKey: "batt_pct") as? Int ?? -1
    let charging = d?.object(forKey: "batt_charging") as? Bool ?? false
    let at = d?.object(forKey: "batt_at") as? Int ?? 0
    let raw = (d?.string(forKey: "batt_name") ?? "").trimmingCharacters(in: .whitespaces)
    let name = raw.isEmpty ? "Band" : raw
    return BatteryEntry(date: Date(), name: name, pct: pct, charging: charging,
                        updatedAt: at)
  }
}

// MARK: - Provider
// No network refresh — the app pushes new readings + calls reloadAllTimelines.
// We still re-render every ~30 min so the staleness flag can flip on its own.

struct BatteryProvider: TimelineProvider {
  func placeholder(in context: Context) -> BatteryEntry { .placeholder }

  func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
    completion(context.isPreview ? .placeholder : BatteryStore.read())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
    // Second entry at the staleness deadline: the reading labels itself "last
    // known" at exactly that moment with no process wake. The 30-min `.after`
    // only picks up a newer snapshot.
    let now = Date()
    let entry = BatteryStore.read().at(now)
    var entries = [entry]
    if let deadline = entry.stalenessDeadline { entries.append(entry.at(deadline)) }
    let next = Calendar.current.date(byAdding: .minute, value: 30, to: now)
      ?? now.addingTimeInterval(1800)
    completion(Timeline(entries: entries, policy: .after(next)))
  }
}

// MARK: - Views

private func battNumFont(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }

/// Linear capsule progress bar (ember fill on a track).
private struct BattBar: View {
  let t: Double
  let color: Color
  var height: CGFloat = 8
  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.battTrack)
        if t > 0 {
          Capsule().fill(color)
            .frame(width: max(height, geo.size.width * min(max(t, 0), 1)))
        }
      }
    }
    .frame(height: height)
  }
}

/// Home-screen small: band name + level + linear bar.
private struct BatterySmallView: View {
  let e: BatteryEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: e.symbol).font(.system(size: 14, weight: .semibold)).foregroundColor(e.color)
        Text(e.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.battInkMuted)
          .lineLimit(1).minimumScaleFactor(0.7)
      }
      Spacer(minLength: 8)
      Text(e.valueText).font(battNumFont(30)).foregroundColor(.battInk)
        .minimumScaleFactor(0.6).lineLimit(1)
      Spacer(minLength: 8)
      if e.hasData { BattBar(t: e.t, color: e.color, height: 9) }
      // Dimming alone does not SAY anything. A reading we can no longer vouch
      // for names itself, on every family.
      Text(!e.hasData ? "Not connected yet"
           : (e.stale ? "Last known level" : (e.charging ? "Charging" : "Battery")))
        .font(.system(size: 10, weight: .medium)).foregroundColor(.battInkMuted)
        .padding(.top, 5)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .padding(14)
  }
}

// A Gauge with no reading is a bar drawn at empty, which reads as "0% battery"
// rather than "we haven't heard from the band" — so an unknown level gets the
// glyph and a word, never a gauge.
private struct BatteryCircularView: View {
  let e: BatteryEntry
  var body: some View {
    if e.hasData {
      Gauge(value: e.t) {
        Image(systemName: e.symbol)
      } currentValueLabel: {
        Text(e.valueText)
      }
      .gaugeStyle(.accessoryCircularCapacity)
      .widgetAccentable()
    } else {
      Image(systemName: "applewatch.slash").font(.system(size: 18)).widgetAccentable()
    }
  }
}

private struct BatteryRectangularView: View {
  let e: BatteryEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label {
        Text(e.name).lineLimit(1)
      } icon: {
        Image(systemName: e.symbol)
      }
      .font(.system(size: 13, weight: .semibold))
      .widgetAccentable()

      if e.hasData {
        // Linear lock-screen battery bar with the level inline.
        Gauge(value: e.t) {
          Text("")
        } currentValueLabel: {
          Text("\(e.pct)%")
        }
        .gaugeStyle(.accessoryLinearCapacity)
      } else {
        Text("Not connected yet").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if e.stale {
        Text("Last known").font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }
}

private extension View {
  @ViewBuilder func battWidgetBackground(_ color: Color) -> some View {
    containerBackground(color, for: .widget)
  }
}

struct OpenStrapBatteryEntryView: View {
  @Environment(\.widgetFamily) var family
  var entry: BatteryEntry

  var body: some View {
    // The staleness mute used to be applied only inside BatterySmallView, so a
    // lock-screen complication showed a week-old percentage at full strength.
    // It belongs here, above every family.
    content
      .opacity(entry.stale ? 0.5 : 1)
      .battWidgetBackground(family == .systemSmall ? Color.battPaper : Color.clear)
  }

  @ViewBuilder private var content: some View {
    switch family {
    case .systemSmall:          BatterySmallView(e: entry)
    case .accessoryCircular:    BatteryCircularView(e: entry)
    case .accessoryRectangular: BatteryRectangularView(e: entry)
    case .accessoryInline:
      Label(
        entry.hasData
          ? "\(entry.name) \(entry.pct)%\(entry.stale ? " · last known" : "")"
          : "\(entry.name) not connected",
        systemImage: entry.symbol)
    default: BatterySmallView(e: entry)
    }
  }
}

struct OpenStrapBatteryWidget: Widget {
  let kind: String = "OpenStrapBatteryWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: BatteryProvider()) { entry in
      OpenStrapBatteryEntryView(entry: entry)
    }
    .configurationDisplayName("Band Battery")
    .description("Your band's battery level at a glance.")
    .supportedFamilies([.systemSmall, .accessoryCircular,
                        .accessoryRectangular, .accessoryInline])
  }
}
