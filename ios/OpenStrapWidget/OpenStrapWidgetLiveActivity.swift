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
    // Optional because unmeasured is not zero. A profile without the anchors
    // Keytel and Banister read cannot be scored at all, and the in-app gauge
    // shows "—" for exactly that case; these used to arrive coerced to 0, so
    // the lock screen claimed a real 0.0 strain / 0 kcal instead.
    var strain: Double?
    var calories: Int?
    var maxHr: Int
    var rhr: Int
  }
  var sessionName: String
  var startedAt: Date
  var targetKcal: Int
}

// MARK: - Palette (lib/ui2/theme.dart, clay)
// Mirrors the app's in-app appearance via the shared App Group flag "theme_dark"
// (which already accounts for an OS-overriding choice). The clay surface + ink
// flip; the accents stay constant in both modes.
//
// ui2 tokens, not the retired lib/theme/tokens.dart ones. The clay surface is
// `P.card` over a `P.card2` sunk well; live HR carries the Heart domain accent
// (`C.red`, as on the phone's Heart-rate card) and strain the Movement one
// (`C.purple`). Accent TEXT uses the `P.on()`-solved variant, accent FILL the
// `P.fill()` one — see the note at the top of OpenStrapWidget.swift.

private let kAppGroup = AppGroup.identifier

private extension Color {
  init(_ r: Int, _ g: Int, _ b: Int) {
    self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
  }
}

private struct Pal {
  let clayPaper: Color, claySunk: Color, ink: Color, inkMuted: Color
  /// `P.on(C.red)` / `P.on(C.purple)` — the accents as TEXT on this surface.
  let onHeart: Color, onMove: Color
  /// The five HR-zone bands as ui2 draws them: `ZoneBar.pigment` run through
  /// `P.on` (lib/ui2/charts.dart:729-733), because raw zone 1 measured 1.80:1
  /// on a light card and read as a pale smear.
  let zones: [Color]
  let isDark: Bool
  static let light = Pal(clayPaper: Color(0xFF, 0xFF, 0xFF), claySunk: Color(0xF1, 0xF5, 0xF9),
                         ink: Color(0x0F, 0x17, 0x2A), inkMuted: Color(0x62, 0x71, 0x88),
                         onHeart: Color(0xB9, 0x39, 0x3E), onMove: Color(0x74, 0x4E, 0xCF),
                         zones: [Color(0x51, 0x6E, 0x95), Color(0x30, 0x65, 0xC1),
                                 Color(0x1A, 0x79, 0x48), Color(0xA5, 0x52, 0x1D),
                                 Color(0xB9, 0x39, 0x3E)],
                         isDark: false)
  static let dark  = Pal(clayPaper: Color(0x15, 0x1C, 0x26), claySunk: Color(0x1D, 0x26, 0x32),
                         ink: Color(0xF1, 0xF5, 0xF9), inkMuted: Color(0x7F, 0x8D, 0xA0),
                         onHeart: Color(0xEF, 0x73, 0x73), onMove: Color(0xA9, 0x89, 0xF6),
                         zones: [Color(0x93, 0xC5, 0xFD), Color(0x68, 0x9F, 0xF7),
                                 Color(0x22, 0xC5, 0x5E), Color(0xF8, 0x7F, 0x2A),
                                 Color(0xEF, 0x73, 0x73)],
                         isDark: true)
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
  /// The raw Heart pigment, for glyphs and arcs (non-text UI).
  static let heart = Color(0xEF, 0x44, 0x44)
  /// `P.fill(C.red)` — darkened until white on it clears AA. Buttons, tints.
  static let heartFill = Color(0xD8, 0x3D, 0x3D)
  static var onHeart: Color { Pal.current.onHeart }
  static var onMove: Color { Pal.current.onMove }
}

private func zoneColor(_ z: Int) -> Color {
  (z >= 1 && z <= 5) ? Pal.current.zones[z - 1] : .inkMuted
}

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
  var live: Bool = true
  var body: some View {
    if !live {
      Image(systemName: "heart").font(.system(size: size)).foregroundStyle(Color.inkMuted)
    } else if #available(iOSApplicationExtension 17.0, *) {
      Image(systemName: "heart.fill").font(.system(size: size))
        .foregroundStyle(Color.heart).symbolEffect(.pulse, options: .repeating)
    } else {
      Image(systemName: "heart.fill").font(.system(size: size)).foregroundStyle(Color.heart)
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

// "" = nothing measured. A bare em-dash is the one rendering the phone's
// grammar forbids outright (lib/ui2/grammar.dart:566-568), and it forbids it
// here too: the lock screen dims the slot instead. Unscored sessions push null
// rather than 0, so absence arrives as absence and stays that way.
private func hrText(_ v: Int) -> String { v > 0 ? "\(v)" : "" }
private func strainText(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
private func kcalText(_ v: Int?) -> String { v.map { "\($0)" } ?? "" }

// The frame to draw. The bridge stamps every push with a stale date a minute
// out, and the app stops pushing when the band stops reporting HR or the app
// dies, so a stale frame's bpm and zone are an old reading, not a live one:
// blank them. Strain and kcal are session tallies, still true as of that frame.
private func shownState(
  _ context: ActivityViewContext<OpenStrapWidgetAttributes>
) -> OpenStrapWidgetAttributes.ContentState {
  var s = context.state
  if isStale(context) {
    s.hr = 0
    s.zone = 0
  }
  return s
}

private func isStale(_ context: ActivityViewContext<OpenStrapWidgetAttributes>) -> Bool {
  if #available(iOSApplicationExtension 16.2, *) { return context.isStale }
  return false
}

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
    let s = shownState(context)
    let live = !isStale(context)
    VStack(spacing: 12) {
      HStack(alignment: .center) {
        HStack(spacing: 8) {
          PulseHeart(size: 22, live: live)
          VStack(alignment: .leading, spacing: 0) {
            Text(hrText(s.hr)).font(.system(size: 34, weight: .bold, design: .rounded))
              .foregroundStyle(Color.ink).contentTransition(.numericText())
            Text("BPM").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Color.inkMuted)
          }
        }
        Spacer()
        HStack(spacing: 14) {
          stat("STRAIN", strainText(s.strain), .onMove)
          stat("KCAL", kcalText(s.calories), .onHeart)
        }
      }
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(!live ? "NO SIGNAL" : s.zone >= 1 ? "ZONE \(s.zone)" : "WARMING UP")
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
        .opacity(value.isEmpty ? 0.4 : 1)
      Text(label).font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(Color.inkMuted)
    }
  }
}

// MARK: - Widget config

struct OpenStrapWidgetLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: OpenStrapWidgetAttributes.self) { context in
      LockScreenView(context: context)
        .activitySystemActionForegroundColor(Color.heartFill)
    } dynamicIsland: { context in
      let s = shownState(context)
      let live = !isStale(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            PulseHeart(size: 16, live: live)
            Text(hrText(s.hr)).font(.system(size: 22, weight: .bold, design: .rounded))
              .foregroundStyle(.white).contentTransition(.numericText())
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing, spacing: 0) {
            Text(strainText(s.strain))
              .font(.system(size: 20, weight: .bold, design: .rounded))
              .foregroundStyle(Color.onMove).contentTransition(.numericText())
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
            // Absent stays absent: a bare " kcal" with nothing in front of it
            // is the unit claiming a measurement we don't have. The lock
            // screen dims the empty slot; here the whole label goes.
            Text(s.calories.map { "\($0) kcal" } ?? "").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            if #available(iOSApplicationExtension 17.0, *) {
              Button(intent: EndSessionIntent()) {
                Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
              }
              .tint(Color.heartFill).buttonBorderShape(.capsule)
            }
          }.padding(.top, 2)
        }
      } compactLeading: {
        HStack(spacing: 3) {
          PulseHeart(size: 12, live: live)
          Text(hrText(s.hr)).font(.system(size: 14, weight: .bold, design: .rounded))
        }
      } compactTrailing: {
        Text(s.zone >= 1 ? "Z\(s.zone)" : "·")
          .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(zoneColor(s.zone))
      } minimal: {
        Text(hrText(s.hr)).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.heart)
      }
      .keylineTint(Color.heart)
    }
  }
}
