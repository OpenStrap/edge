//
//  OpenStrapWidget.swift
//  OpenStrapWidget
//
//  Home/lock-screen widget — "Ember on Paper". Renders the snapshot the app
//  writes into the shared App Group; ALSO self-refreshes ~hourly by fetching
//  /today directly (using the JWT + backend URL the app stores in the group), so
//  it stays current even when the app is fully closed. No @main here — the bundle
//  (OpenStrapWidgetBundle.swift) owns it.

import WidgetKit
import SwiftUI

private let kAppGroup = "group.wtf.openstrap"

// MARK: - Theme (Ember on Paper)

private extension Color {
  static let paper      = Color(red: 244/255, green: 241/255, blue: 236/255)
  static let ink        = Color(red: 26/255,  green: 23/255,  blue: 20/255)
  static let inkMuted   = Color(red: 165/255, green: 156/255, blue: 144/255)
  static let surfaceAlt = Color(red: 236/255, green: 231/255, blue: 223/255)
  static let coral      = Color(red: 255/255, green: 90/255,  blue: 54/255)
  static let coralDeep  = Color(red: 232/255, green: 67/255,  blue: 31/255)
  static let good       = Color(red: 43/255,  green: 182/255, blue: 115/255)
  static let sleepBlue  = Color(red: 124/255, green: 168/255, blue: 240/255)
}

private func scoreColor(_ t: Double) -> Color {
  if t >= 0.75 { return .good }
  if t >= 0.5  { return .coral }
  return .coralDeep
}

// MARK: - Model

struct OpenStrapEntry: TimelineEntry {
  let date: Date
  let hasData: Bool
  let readiness: Int      // -1 = none
  let strain: Double      // -1 = none
  let sleepMin: Int       // -1 = none
  let needMin: Int
  let rhr: Int            // -1 = none
  let coachLine: String

  static let placeholder = OpenStrapEntry(
    date: Date(), hasData: true, readiness: 78, strain: 12.4,
    sleepMin: 437, needMin: 480, rhr: 54, coachLine: "Room to push today")
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

    let readiness = val(daily, "readiness").map { Int($0.rounded()) } ?? -1
    let strain = val(daily, "strain") ?? -1
    let rhr = val(daily, "resting_hr").map { Int($0.rounded()) } ?? -1
    let sleepMin = val(sleep, "duration_min").map { Int($0.rounded()) } ?? -1
    let needMin = val(sleep, "need_min").map { Int($0.rounded()) } ?? 480

    var coachLine = ""
    if let plan = coach?["plan"] as? [[String: Any]], let first = plan.first,
       let title = first["title"] as? String { coachLine = title }
    else if let tgt = obj(coach?["strain_target"]), let v = tgt["value"] as? NSNumber {
      coachLine = "Aim for strain \(Int(v.doubleValue.rounded()))"
    }
    let hasData = daily != nil || sleep != nil
    return OpenStrapEntry(date: Date(), hasData: hasData, readiness: readiness,
                          strain: strain, sleepMin: sleepMin, needMin: needMin,
                          rhr: rhr, coachLine: coachLine)
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

private struct SmallView: View {
  let e: OpenStrapEntry
  var body: some View {
    let t = e.readiness >= 0 ? Double(e.readiness) / 100.0 : 0
    let c = e.readiness >= 0 ? scoreColor(t) : Color.inkMuted
    VStack(spacing: 8) {
      ZStack {
        Ring(t: t, color: c, lineWidth: 11)
        Text(e.readiness >= 0 ? "\(e.readiness)" : "—").font(numFont(34)).foregroundColor(c)
      }
      .frame(width: 92, height: 92)
      Text("RECOVERY").font(.system(size: 10, weight: .semibold)).tracking(1.2)
        .foregroundColor(.inkMuted)
    }
    .padding(14)
  }
}

private struct MetricRing: View {
  let label: String; let value: String; let t: Double; let color: Color
  var body: some View {
    VStack(spacing: 4) {
      ZStack {
        Ring(t: t, color: color, lineWidth: 6)
        Text(value).font(numFont(15)).foregroundColor(.ink)
      }
      .frame(width: 50, height: 50)
      Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundColor(.inkMuted)
    }
  }
}

private struct MediumView: View {
  let e: OpenStrapEntry
  var body: some View {
    let rt = e.readiness >= 0 ? Double(e.readiness) / 100.0 : 0
    let rc = e.readiness >= 0 ? scoreColor(rt) : Color.inkMuted
    let strainT = e.strain >= 0 ? min(e.strain / 21.0, 1) : 0
    let sleepT = (e.sleepMin >= 0 && e.needMin > 0) ? min(Double(e.sleepMin) / Double(e.needMin), 1) : 0
    HStack(spacing: 16) {
      ZStack {
        Ring(t: rt, color: rc, lineWidth: 12)
        VStack(spacing: 0) {
          Text(e.readiness >= 0 ? "\(e.readiness)" : "—").font(numFont(36)).foregroundColor(rc)
          Text("RECOVERY").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundColor(.inkMuted)
        }
      }
      .frame(width: 108, height: 108)
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 14) {
          MetricRing(label: "STRAIN",
                     value: e.strain >= 0 ? String(format: "%.1f", e.strain) : "—",
                     t: strainT, color: .coral)
          MetricRing(label: "SLEEP", value: hm(e.sleepMin), t: sleepT, color: .sleepBlue)
        }
        if !e.coachLine.isEmpty {
          Text(e.coachLine).font(.system(size: 12, weight: .medium)).foregroundColor(.ink).lineLimit(2)
        } else if !e.hasData {
          Text("Wear + sync to see today").font(.system(size: 12)).foregroundColor(.inkMuted).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(16)
  }
}

@available(iOSApplicationExtension 16.0, *)
private struct AccessoryCircularView: View {
  let e: OpenStrapEntry
  var body: some View {
    Gauge(value: e.readiness >= 0 ? Double(e.readiness) / 100.0 : 0) {
      Text("REC")
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
      Text("OpenStrap").font(.system(size: 11, weight: .bold)).widgetAccentable()
      Text("Recovery \(e.readiness >= 0 ? "\(e.readiness)" : "—")   Strain \(e.strain >= 0 ? String(format: "%.1f", e.strain) : "—")")
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
          Text("Rec \(entry.readiness >= 0 ? "\(entry.readiness)" : "—") · Strain \(entry.strain >= 0 ? String(format: "%.1f", entry.strain) : "—")")
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
    .description("Your recovery, strain and sleep at a glance.")
    .supportedFamilies(supportedFamilies)
  }

  private var supportedFamilies: [WidgetFamily] {
    if #available(iOSApplicationExtension 16.0, *) {
      return [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    }
    return [.systemSmall, .systemMedium]
  }
}
