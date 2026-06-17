//
//  OpenStrapWidget.swift
//  OpenStrapWidget
//
//  Home/lock-screen widget — "Ember on Paper". Renders the snapshot the app
//  writes into the shared App Group; ALSO self-refreshes ~hourly by fetching
//  /today directly (using the JWT + backend URL the app stores in the group), so
//  it stays current even when the app is fully closed. No @main here — the bundle
//  (OpenStrapWidgetBundle.swift) owns it.
//
//  Shows three rings: Strain · Sleep · HRV. (Recovery was retired — the app no
//  longer surfaces a recovery score; HRV is the real measured autonomic signal.)

import WidgetKit
import SwiftUI

private let kAppGroup = AppGroup.identifier

// MARK: - Theme (Ember on Paper / Char)
// The app writes "theme_dark" into the App Group to mirror its in-app appearance
// (which already resolves "System" to the actual OS brightness). Surfaces + ink
// flip between paper and char; the ember coral + ring accents stay constant.

private extension Color {
  init(_ r: Int, _ g: Int, _ b: Int) {
    self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
  }
}

private struct Pal {
  let bg: Color, ink: Color, inkMuted: Color, track: Color
  static let light = Pal(bg: Color(244, 241, 236), ink: Color(26, 23, 20),
                         inkMuted: Color(165, 156, 144), track: Color(236, 231, 223))
  static let dark  = Pal(bg: Color(30, 26, 21), ink: Color(241, 236, 227),
                         inkMuted: Color(126, 116, 102), track: Color(42, 37, 31))
  static var isDark: Bool {
    UserDefaults(suiteName: kAppGroup)?.object(forKey: "theme_dark") as? Bool ?? false
  }
  static var current: Pal { isDark ? .dark : .light }
}

private extension Color {
  static var paper: Color { Pal.current.bg }
  static var ink: Color { Pal.current.ink }
  static var inkMuted: Color { Pal.current.inkMuted }
  static var surfaceAlt: Color { Pal.current.track }
  static let coral      = Color(255, 90, 54)
  static let coralDeep  = Color(232, 67, 31)
  static let good       = Color(43, 182, 115)
  static let sleepBlue  = Color(124, 168, 240)
}

// MARK: - Model

struct OpenStrapEntry: TimelineEntry {
  let date: Date
  let hasData: Bool
  let readiness: Int      // -1 = none (composite 0..100) — the headline
  let strain: Double      // -1 = none
  let sleepMin: Int       // -1 = none
  let needMin: Int
  let hrv: Int            // -1 = none (RMSSD, ms)
  let hrvBaseline: Int    // -1 = none (personal RMSSD baseline, ms)
  let rhr: Int            // -1 = none
  let coachLine: String

  static let placeholder = OpenStrapEntry(
    date: Date(), hasData: true, readiness: 72, strain: 12.4,
    sleepMin: 437, needMin: 480, hrv: 62, hrvBaseline: 58, rhr: 54,
    coachLine: "Room to push today")

  // Ring fractions (0…1).
  var readinessT: Double { readiness >= 0 ? Double(readiness) / 100.0 : 0 }
  var readinessColor: Color {
    if readiness < 0 { return .inkMuted }
    if readiness >= 66 { return .good }
    if readiness >= 40 { return .coral }
    return .coralDeep
  }
  var strainT: Double { strain >= 0 ? min(strain / 21.0, 1) : 0 }
  var sleepT: Double { (sleepMin >= 0 && needMin > 0) ? min(Double(sleepMin) / Double(needMin), 1) : 0 }
  var hrvT: Double {
    guard hrv >= 0 else { return 0 }
    if hrvBaseline > 0 { return min(Double(hrv) / (1.5 * Double(hrvBaseline)), 1) }
    return min(Double(hrv) / 100.0, 1)
  }
  // HRV reads green at/above your baseline, warmer as it drops below it.
  var hrvColor: Color {
    guard hrv >= 0, hrvBaseline > 0 else { return .good }
    if hrv >= hrvBaseline { return .good }
    if hrv >= Int(0.8 * Double(hrvBaseline)) { return .coral }
    return .coralDeep
  }
}

// MARK: - Shared store (App Group)

private enum Store {
  static var defaults: UserDefaults? { UserDefaults(suiteName: kAppGroup) }

  static func read() -> OpenStrapEntry {
    let d = defaults
    return OpenStrapEntry(
      date: Date(),
      hasData: d?.bool(forKey: "has_data") ?? false,
      readiness: d?.object(forKey: "readiness") as? Int ?? -1,
      strain: d?.object(forKey: "strain") as? Double ?? -1,
      sleepMin: d?.object(forKey: "sleep_min") as? Int ?? -1,
      needMin: (d?.object(forKey: "sleep_need_min") as? Int) ?? 480,
      hrv: d?.object(forKey: "hrv") as? Int ?? -1,
      hrvBaseline: d?.object(forKey: "hrv_baseline") as? Int ?? -1,
      rhr: d?.object(forKey: "rhr") as? Int ?? -1,
      coachLine: d?.string(forKey: "coach_line") ?? "")
  }

  static func write(_ e: OpenStrapEntry) {
    let d = defaults
    d?.set(true, forKey: "has_data")
    d?.set(e.readiness, forKey: "readiness")
    d?.set(e.strain, forKey: "strain")
    d?.set(e.sleepMin, forKey: "sleep_min")
    d?.set(e.needMin, forKey: "sleep_need_min")
    d?.set(e.hrv, forKey: "hrv")
    d?.set(e.hrvBaseline, forKey: "hrv_baseline")
    d?.set(e.rhr, forKey: "rhr")
    d?.set(e.coachLine, forKey: "coach_line")
    d?.set(Int(Date().timeIntervalSince1970), forKey: "updated_at")
  }

  static var backendURL: String { defaults?.string(forKey: "backend_url") ?? "" }
  static var jwt: String { defaults?.string(forKey: "access_jwt") ?? "" }
}

// MARK: - Self-refresh: fetch /today directly

private enum TodayAPI {
  /// GET {url}/today with the stored JWT, parse into an entry. Falls back to the
  /// cached entry on any failure (offline / expired token / parse error).
  static func fetch(fallback: OpenStrapEntry, completion: @escaping (OpenStrapEntry) -> Void) {
    let base = Store.backendURL
    let token = Store.jwt
    guard !base.isEmpty, !token.isEmpty, let url = URL(string: base + "/today") else {
      completion(fallback); return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 12
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: req) { data, resp, _ in
      guard
        let http = resp as? HTTPURLResponse, http.statusCode == 200,
        let data = data,
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { completion(fallback); return }
      let entry = parse(json) ?? fallback
      Store.write(entry)         // keep the cache fresh for the next instant render
      completion(entry)
    }.resume()
  }

  private static func parse(_ j: [String: Any]) -> OpenStrapEntry? {
    func obj(_ m: Any?) -> [String: Any]? { m as? [String: Any] }
    func val(_ parent: [String: Any]?, _ key: String) -> Double? {
      guard let leaf = obj(parent?[key]), let v = leaf["value"] as? NSNumber else { return nil }
      return v.doubleValue
    }
    let daily = obj(j["daily"]); let sleep = obj(j["sleep"]); let coach = obj(j["coach"])
    let hrvObj = obj(j["hrv"])  // top-level { rmssd, baseline, ... }

    let readiness = val(daily, "readiness").map { Int($0.rounded()) } ?? -1
    let strain = val(daily, "strain") ?? -1
    let rhr = val(daily, "resting_hr").map { Int($0.rounded()) } ?? -1
    let sleepMin = val(sleep, "duration_min").map { Int($0.rounded()) } ?? -1
    let needMin = val(sleep, "need_min").map { Int($0.rounded()) } ?? 480
    let hrv = (hrvObj?["rmssd"] as? NSNumber).map { Int($0.doubleValue.rounded()) } ?? -1
    let hrvBase = (hrvObj?["baseline"] as? NSNumber).map { Int($0.doubleValue.rounded()) } ?? -1

    var coachLine = ""
    if let plan = coach?["plan"] as? [[String: Any]], let first = plan.first,
       let title = first["title"] as? String { coachLine = title }
    else if let tgt = obj(coach?["strain_target"]), let v = tgt["value"] as? NSNumber {
      coachLine = "Aim for strain \(Int(v.doubleValue.rounded()))"
    }
    let hasData = daily != nil || sleep != nil
    return OpenStrapEntry(date: Date(), hasData: hasData, readiness: readiness, strain: strain,
                          sleepMin: sleepMin, needMin: needMin, hrv: hrv,
                          hrvBaseline: hrvBase, rhr: rhr, coachLine: coachLine)
  }
}

// MARK: - Provider

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> OpenStrapEntry { .placeholder }

  func getSnapshot(in context: Context, completion: @escaping (OpenStrapEntry) -> Void) {
    completion(context.isPreview ? .placeholder : Store.read())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<OpenStrapEntry>) -> Void) {
    let cached = Store.read()
    // Refresh from the network (best-effort); fall back to cache. Re-render hourly.
    TodayAPI.fetch(fallback: cached) { entry in
      let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date())
        ?? Date().addingTimeInterval(3600)
      completion(Timeline(entries: [entry], policy: .after(next)))
    }
  }
}

// MARK: - Reusable views

private struct Ring: View {
  let t: Double
  let color: Color
  let lineWidth: CGFloat
  var body: some View {
    ZStack {
      Circle().stroke(Color.surfaceAlt, lineWidth: lineWidth)
      if t > 0 {
        Circle()
          .trim(from: 0, to: min(max(t, 0), 1))
          .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
    }
  }
}

private func hm(_ min: Int) -> String {
  if min < 0 { return "—" }
  let h = min / 60, m = min % 60
  if h == 0 { return "\(m)m" }
  if m == 0 { return "\(h)h" }
  return "\(h)h \(m)m"
}

private func numFont(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }

/// One labelled metric ring (used for all three: Strain / Sleep / HRV).
private struct MetricRing: View {
  let label: String
  let value: String
  let t: Double
  let color: Color
  var size: CGFloat = 58
  var line: CGFloat = 7
  var valueSize: CGFloat = 16
  var body: some View {
    VStack(spacing: 5) {
      ZStack {
        Ring(t: t, color: color, lineWidth: line)
        Text(value).font(numFont(valueSize)).foregroundColor(.ink).minimumScaleFactor(0.6).lineLimit(1)
      }
      .frame(width: size, height: size)
      Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundColor(.inkMuted)
    }
  }
}

/// The three rings in a row, each taking an equal share of the width so they're
/// evenly distributed regardless of value width.
private struct TripleRings: View {
  let e: OpenStrapEntry
  var size: CGFloat = 58
  var line: CGFloat = 7
  var valueSize: CGFloat = 16
  var body: some View {
    HStack(spacing: 0) {
      MetricRing(label: "STRAIN",
                 value: e.strain >= 0 ? String(format: "%.1f", e.strain) : "—",
                 t: e.strainT, color: .coral, size: size, line: line, valueSize: valueSize)
        .frame(maxWidth: .infinity)
      MetricRing(label: "SLEEP", value: hm(e.sleepMin),
                 t: e.sleepT, color: .sleepBlue, size: size, line: line, valueSize: valueSize - 1)
        .frame(maxWidth: .infinity)
      MetricRing(label: "HRV", value: e.hrv >= 0 ? "\(e.hrv)" : "—",
                 t: e.hrvT, color: e.hrvColor, size: size, line: line, valueSize: valueSize)
        .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
  }
}

/// Readiness headline row — big ring + score + what it blends.
private struct ReadinessRow: View {
  let e: OpenStrapEntry
  var ring: CGFloat = 64
  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        Ring(t: e.readinessT, color: e.readinessColor, lineWidth: 9)
        Text(e.readiness >= 0 ? "\(e.readiness)" : "—").font(numFont(22)).foregroundColor(e.readinessColor)
      }
      .frame(width: ring, height: ring)
      VStack(alignment: .leading, spacing: 2) {
        Text("READINESS").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundColor(.inkMuted)
        Text(e.readiness >= 0 ? "HRV recovery + sleep" : "Building baseline")
          .font(.system(size: 12)).foregroundColor(.ink)
      }
      Spacer(minLength: 0)
    }
  }
}

private struct SmallView: View {
  let e: OpenStrapEntry
  var body: some View {
    // 2×2: Readiness · Strain / Sleep · HRV.
    VStack(spacing: 10) {
      HStack(spacing: 0) {
        MetricRing(label: "READY", value: e.readiness >= 0 ? "\(e.readiness)" : "—",
                   t: e.readinessT, color: e.readinessColor, size: 44, line: 6, valueSize: 13).frame(maxWidth: .infinity)
        MetricRing(label: "STRAIN", value: e.strain >= 0 ? String(format: "%.1f", e.strain) : "—",
                   t: e.strainT, color: .coral, size: 44, line: 6, valueSize: 13).frame(maxWidth: .infinity)
      }
      HStack(spacing: 0) {
        MetricRing(label: "SLEEP", value: hm(e.sleepMin), t: e.sleepT, color: .sleepBlue, size: 44, line: 6, valueSize: 12).frame(maxWidth: .infinity)
        MetricRing(label: "HRV", value: e.hrv >= 0 ? "\(e.hrv)" : "—", t: e.hrvT, color: e.hrvColor, size: 44, line: 6, valueSize: 13).frame(maxWidth: .infinity)
      }
    }
    .padding(12)
  }
}

private struct MediumView: View {
  let e: OpenStrapEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ReadinessRow(e: e)
      TripleRings(e: e, size: 56, line: 7, valueSize: 15)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }
}

@available(iOSApplicationExtension 16.0, *)
private struct AccessoryCircularView: View {
  let e: OpenStrapEntry
  var body: some View {
    Gauge(value: e.readinessT) {
      Text("RDY")
    } currentValueLabel: {
      Text(e.readiness >= 0 ? "\(e.readiness)" : "—")
    }
    .gaugeStyle(.accessoryCircular)
    .widgetAccentable()
  }
}

@available(iOSApplicationExtension 16.0, *)
private struct AccessoryRectangularView: View {
  let e: OpenStrapEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Readiness \(e.readiness >= 0 ? "\(e.readiness)" : "—")").font(.system(size: 13, weight: .bold)).widgetAccentable()
      Text("Strain \(e.strain >= 0 ? String(format: "%.1f", e.strain) : "—")   HRV \(e.hrv >= 0 ? "\(e.hrv)" : "—")")
        .font(.system(size: 13, weight: .semibold))
      Text("Sleep \(hm(e.sleepMin))" + (e.rhr >= 0 ? "   RHR \(e.rhr)" : ""))
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }
  }
}

private extension View {
  @ViewBuilder func widgetBackground(_ color: Color) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(color, for: .widget)
    } else {
      background(color)
    }
  }
}

struct OpenStrapWidgetEntryView: View {
  @Environment(\.widgetFamily) var family
  var entry: OpenStrapEntry

  var body: some View {
    content.widgetBackground(isSystem ? Color.paper : Color.clear)
  }

  private var isSystem: Bool { family == .systemSmall || family == .systemMedium }

  @ViewBuilder private var content: some View {
    switch family {
    case .systemSmall:  SmallView(e: entry)
    case .systemMedium: MediumView(e: entry)
    default:
      if #available(iOSApplicationExtension 16.0, *) {
        switch family {
        case .accessoryCircular:    AccessoryCircularView(e: entry)
        case .accessoryRectangular: AccessoryRectangularView(e: entry)
        case .accessoryInline:
          Text("Ready \(entry.readiness >= 0 ? "\(entry.readiness)" : "—") · Strain \(entry.strain >= 0 ? String(format: "%.1f", entry.strain) : "—")")
        default: SmallView(e: entry)
        }
      } else {
        SmallView(e: entry)
      }
    }
  }
}

struct OpenStrapWidget: Widget {
  let kind: String = "OpenStrapWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: Provider()) { entry in
      OpenStrapWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("OpenStrap")
    .description("Readiness, strain, sleep and HRV at a glance.")
    .supportedFamilies(supportedFamilies)
  }

  private var supportedFamilies: [WidgetFamily] {
    if #available(iOSApplicationExtension 16.0, *) {
      return [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    }
    return [.systemSmall, .systemMedium]
  }
}
