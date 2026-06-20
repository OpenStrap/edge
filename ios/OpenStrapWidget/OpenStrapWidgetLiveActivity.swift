//
//  OpenStrapWidgetLiveActivity.swift
//  Live workout activity — lock screen + Dynamic Island, claymorphic.
//  Live HR (pulsing heart), the 5 HR zones with the current one lit, strain,
//  active calories, and a live-counting timer. Persists on the lock screen while
//  the session runs (started/updated/ended from the app via ActivityKit).
//
//  The attributes struct lives in Shared/OpenStrapActivityAttributes.swift
//  (add that file to BOTH the Runner and widget targets).
//

import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Attributes
// Defined here (in the extension) AND in AppDelegate.swift (in the Runner app).
// ActivityKit matches the activity to this configuration by the type NAME +
// Codable shape, so the two copies MUST stay identical.

struct OpenStrapWidgetAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var hr: Int
    var zone: Int
    var strain: Double
    var calories: Int
    var maxHr: Int
    var rhr: Int
  }
  var sessionName: String
  var startedAt: Date
  var targetKcal: Int
}

// MARK: - Palette (Ember on Paper / Char, clay)
// Mirrors the app's in-app appearance via the shared App Group flag "theme_dark"
// (which already accounts for an OS-overriding choice). The clay surface + ink
// flip; the ember coral + zone accents stay constant in both modes.

private let kAppGroup = AppGroup.identifier

private extension Color {
  init(_ r: Int, _ g: Int, _ b: Int) {
    self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
  }
}

private struct Pal {
  let clayPaper: Color, claySunk: Color, ink: Color, inkMuted: Color
  let isDark: Bool
  static let light = Pal(clayPaper: Color(246, 242, 236), claySunk: Color(232, 226, 217),
                         ink: Color(26, 23, 20), inkMuted: Color(150, 142, 131), isDark: false)
  static let dark  = Pal(clayPaper: Color(32, 28, 23), claySunk: Color(46, 40, 32),
                         ink: Color(241, 236, 227), inkMuted: Color(126, 116, 102), isDark: true)
  static var current: Pal {
    (UserDefaults(suiteName: kAppGroup)?.object(forKey: "theme_dark") as? Bool ?? false)
      ? .dark : .light
  }
}

private extension Color {
  static var clayPaper: Color { Pal.current.clayPaper }
  static var claySunk: Color { Pal.current.claySunk }
  static var ink: Color { Pal.current.ink }
  static var inkMuted: Color { Pal.current.inkMuted }
  static let coral      = Color(255, 90, 54)
  static let coralDeep  = Color(232, 67, 31)
}

private let zonePalette: [Color] = [
  Color(124, 168, 240), // Z1 blue
  Color(43, 182, 115),  // Z2 green
  Color(255, 90, 54),   // Z3 coral
  Color(232, 67, 31),   // Z4 deep
  Color(229, 72, 77),   // Z5 red
]
private func zoneColor(_ z: Int) -> Color { (z >= 1 && z <= 5) ? zonePalette[z - 1] : .inkMuted }

// MARK: - Claymorphic surface

private struct Clay: ViewModifier {
  var radius: CGFloat = 22
  var fill: Color = .clayPaper
  func body(content: Content) -> some View {
    let dark = Pal.current.isDark
    return content.background(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(LinearGradient(colors: [fill, fill.opacity(0.92)],
                             startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(.white.opacity(dark ? 0.08 : 0.5), lineWidth: 1))
        .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 8, x: 0, y: 5))
  }
}
private extension View {
  func clay(_ radius: CGFloat = 22, _ fill: Color = .clayPaper) -> some View {
    modifier(Clay(radius: radius, fill: fill))
  }
}

// MARK: - Pieces

private struct PulseHeart: View {
  let size: CGFloat
  var body: some View {
    if #available(iOSApplicationExtension 17.0, *) {
      Image(systemName: "heart.fill").font(.system(size: size))
        .foregroundStyle(Color.coral).symbolEffect(.pulse, options: .repeating)
    } else {
      Image(systemName: "heart.fill").font(.system(size: size)).foregroundStyle(Color.coral)
    }
  }
}

private struct ZoneBar: View {
  let zone: Int
  var compact: Bool = false
  var body: some View {
    HStack(spacing: compact ? 3 : 5) {
      ForEach(1...5, id: \.self) { z in
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(z <= zone ? zoneColor(zone) : Color.claySunk)
          .frame(height: compact ? 6 : 10)
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
      }
    }
  }
}

private func hrText(_ v: Int) -> String { v > 0 ? "\(v)" : "—" }

// MARK: - Finish (interactive, iOS 17+)

@available(iOSApplicationExtension 17.0, *)
struct EndSessionIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Finish session"
  func perform() async throws -> some IntentResult {
    UserDefaults(suiteName: kAppGroup)?.set(true, forKey: "end_session")
    for activity in Activity<OpenStrapWidgetAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    return .result()
  }
}

// MARK: - Lock screen

private struct LockScreenView: View {
  let context: ActivityViewContext<OpenStrapWidgetAttributes>
  var body: some View {
    let s = context.state
    VStack(spacing: 12) {
      HStack(alignment: .center) {
        HStack(spacing: 8) {
          PulseHeart(size: 22)
          VStack(alignment: .leading, spacing: 0) {
            Text(hrText(s.hr)).font(.system(size: 34, weight: .bold, design: .rounded))
              .foregroundStyle(Color.ink).contentTransition(.numericText())
            Text("BPM").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Color.inkMuted)
          }
        }
        Spacer()
        HStack(spacing: 14) {
          stat("STRAIN", String(format: "%.1f", s.strain), .coralDeep)
          stat("KCAL", "\(s.calories)", .coral)
        }
      }
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(s.zone >= 1 ? "ZONE \(s.zone)" : "WARMING UP")
            .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(zoneColor(s.zone))
          Spacer()
          Text(context.attributes.startedAt, style: .timer)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.inkMuted).frame(maxWidth: 60, alignment: .trailing)
        }
        ZoneBar(zone: s.zone)
      }
    }
    .padding(16).clay(24).padding(8)
  }
  private func stat(_ label: String, _ value: String, _ c: Color) -> some View {
    VStack(spacing: 1) {
      Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(c)
        .contentTransition(.numericText())
      Text(label).font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(Color.inkMuted)
    }
  }
}

// MARK: - Widget config

struct OpenStrapWidgetLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: OpenStrapWidgetAttributes.self) { context in
      LockScreenView(context: context)
        .activitySystemActionForegroundColor(Color.coralDeep)
    } dynamicIsland: { context in
      let s = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            PulseHeart(size: 16)
            Text(hrText(s.hr)).font(.system(size: 22, weight: .bold, design: .rounded))
              .foregroundStyle(.white).contentTransition(.numericText())
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing, spacing: 0) {
            Text(String(format: "%.1f", s.strain))
              .font(.system(size: 20, weight: .bold, design: .rounded))
              .foregroundStyle(Color.coral).contentTransition(.numericText())
            Text("STRAIN").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
          }
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.attributes.startedAt, style: .timer)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary).frame(maxWidth: 56)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 10) {
            ZoneBar(zone: s.zone)
            Text("\(s.calories) kcal").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            if #available(iOSApplicationExtension 17.0, *) {
              Button(intent: EndSessionIntent()) {
                Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
              }
              .tint(Color.coralDeep).buttonBorderShape(.capsule)
            }
          }.padding(.top, 2)
        }
      } compactLeading: {
        HStack(spacing: 3) {
          PulseHeart(size: 12)
          Text(hrText(s.hr)).font(.system(size: 14, weight: .bold, design: .rounded))
        }
      } compactTrailing: {
        Text(s.zone >= 1 ? "Z\(s.zone)" : "·")
          .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(zoneColor(s.zone))
      } minimal: {
        Text(hrText(s.hr)).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.coral)
      }
      .keylineTint(Color.coral)
    }
  }
}
