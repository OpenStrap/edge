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
//  time the band was connected. "—" until we've ever seen the band.
//
//  Primary surface is the lock screen (accessory* families); a systemSmall
//  variant is included so it can also live on the home screen.
//

import WidgetKit
import SwiftUI

private let kAppGroup = "group.wtf.openstrap"

// MARK: - Theme (mirrors OpenStrapWidget's Ember-on-Paper / Char)

private extension Color {
  init(_ r: Int, _ g: Int, _ b: Int) {
    self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
  }
}

private struct BattPal {
  let bg: Color, ink: Color, inkMuted: Color, track: Color
  static let light = BattPal(bg: Color(244, 241, 236), ink: Color(26, 23, 20),
                             inkMuted: Color(165, 156, 144), track: Color(236, 231, 223))
  static let dark  = BattPal(bg: Color(30, 26, 21), ink: Color(241, 236, 227),
                             inkMuted: Color(126, 116, 102), track: Color(42, 37, 31))
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
  static let battCoral     = Color(255, 90, 54)
  static let battCoralDeep = Color(232, 67, 31)
  static let battGood      = Color(43, 182, 115)
  static let battCharge    = Color(124, 168, 240)
}

// MARK: - Model

struct BatteryEntry: TimelineEntry {
  let date: Date
  let name: String      // strap advertising name (falls back to "Strap")
  let pct: Int          // -1 = never seen the band
  let charging: Bool
  let updatedAt: Int    // epoch seconds, 0 = unknown
  let stale: Bool       // last reading is old enough that we mute it

  static let placeholder = BatteryEntry(
    date: Date(), name: "WHOOP 4.0", pct: 68, charging: false,
    updatedAt: Int(Date().timeIntervalSince1970), stale: false)

  var hasData: Bool { pct >= 0 }
  var t: Double { pct >= 0 ? min(max(Double(pct) / 100.0, 0), 1) : 0 }

  /// Coral when low, deep-coral when critical, blue while charging, otherwise ink.
  var color: Color {
    if !hasData { return .battInkMuted }
    if charging { return .battCharge }
    if pct <= 10 { return .battCoralDeep }
    if pct <= 25 { return .battCoral }
    return .battGood
  }

  var valueText: String { pct >= 0 ? "\(pct)%" : "—" }

  /// Icon: a charging bolt while plugged in, otherwise the strap glyph
  /// (mirrors the app's device icon, HugeIcons SmartWatch01).
  var symbol: String { charging ? "bolt.fill" : "applewatch" }
}

// MARK: - Shared store (App Group, read-only here)

private enum BatteryStore {
  static func read() -> BatteryEntry {
    let d = UserDefaults(suiteName: kAppGroup)
    let pct = d?.object(forKey: "batt_pct") as? Int ?? -1
    let charging = d?.object(forKey: "batt_charging") as? Bool ?? false
    let at = d?.object(forKey: "batt_at") as? Int ?? 0
    let raw = (d?.string(forKey: "batt_name") ?? "").trimmingCharacters(in: .whitespaces)
    let name = raw.isEmpty ? "Strap" : raw
    // Mute (still show the number, but greyed) once the reading is > 24h old —
    // we genuinely don't know the current level if we haven't talked to the band.
    let stale = at > 0 && (Int(Date().timeIntervalSince1970) - at) > 86_400
    return BatteryEntry(date: Date(), name: name, pct: pct, charging: charging,
                        updatedAt: at, stale: stale)
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
    let entry = BatteryStore.read()
    let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
      ?? Date().addingTimeInterval(1800)
    completion(Timeline(entries: [entry], policy: .after(next)))
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

/// Home-screen small: strap name + level + linear bar.
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
      BattBar(t: e.t, color: e.color, height: 9)
      Text(e.charging ? "Charging" : (e.hasData ? "Battery" : "Not connected"))
        .font(.system(size: 10, weight: .medium)).foregroundColor(.battInkMuted)
        .padding(.top, 5)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .opacity(e.stale ? 0.5 : 1)
    .padding(14)
  }
}

@available(iOSApplicationExtension 16.0, *)
private struct BatteryCircularView: View {
  let e: BatteryEntry
  var body: some View {
    Gauge(value: e.t) {
      Image(systemName: e.symbol)
    } currentValueLabel: {
      Text(e.valueText)
    }
    .gaugeStyle(.accessoryCircularCapacity)
    .widgetAccentable()
  }
}

@available(iOSApplicationExtension 16.0, *)
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

      // Linear lock-screen battery bar with the level inline.
      Gauge(value: e.t) {
        Text("")
      } currentValueLabel: {
        Text(e.hasData ? "\(e.pct)%" : "—")
      }
      .gaugeStyle(.accessoryLinearCapacity)
    }
  }
}

private extension View {
  @ViewBuilder func battWidgetBackground(_ color: Color) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(color, for: .widget)
    } else {
      background(color)
    }
  }
}

struct OpenStrapBatteryEntryView: View {
  @Environment(\.widgetFamily) var family
  var entry: BatteryEntry

  var body: some View {
    content.battWidgetBackground(family == .systemSmall ? Color.battPaper : Color.clear)
  }

  @ViewBuilder private var content: some View {
    switch family {
    case .systemSmall: BatterySmallView(e: entry)
    default:
      if #available(iOSApplicationExtension 16.0, *) {
        switch family {
        case .accessoryCircular:    BatteryCircularView(e: entry)
        case .accessoryRectangular: BatteryRectangularView(e: entry)
        case .accessoryInline:
          Label(
            entry.hasData ? "\(entry.name) \(entry.pct)%" : "\(entry.name) —",
            systemImage: entry.symbol)
        default: BatterySmallView(e: entry)
        }
      } else {
        BatterySmallView(e: entry)
      }
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
    .supportedFamilies(supportedFamilies)
  }

  private var supportedFamilies: [WidgetFamily] {
    if #available(iOSApplicationExtension 16.0, *) {
      return [.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    }
    return [.systemSmall]
  }
}
