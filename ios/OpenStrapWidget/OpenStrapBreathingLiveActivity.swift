//
//  OpenStrapBreathingLiveActivity.swift
//  Live breathing-session activity — lock screen + Dynamic Island. Shows the
//  real McCraty & Zayas 2014 cardiac-coherence score (never a fabricated
//  number — an honest "Calibrating…" until enough live RR has accumulated,
//  matching CalmBreathingView's in-app state) and a live-counting timer.
//
//  Deliberately separate from OpenStrapWidgetLiveActivity.swift (the workout
//  one) — different content entirely (coherence, not HR/zone/strain) — kept
//  independent so the well-tuned workout activity is never at risk here.
//
//  The attributes struct MUST stay identical to the copy in
//  BreathingLiveActivityBridge.swift (Runner target) — ActivityKit matches by
//  type name + Codable shape.
//
//  No per-breath animation sync here on purpose: ActivityKit rate-limits
//  updates, and the phone screen (not the lock screen) is the pacer while the
//  session is active — this is a passive coherence readout, not a driver.
//

import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Attributes

struct OpenStrapBreathingAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var coherenceScore: Double // -1 = not yet available ("Calibrating…")
  }
  var startedAt: Date
}

// MARK: - Palette (lib/ui2/theme.dart; mirrors OpenStrapWidgetLiveActivity's, kept local —
// that file's helpers are `private` to it, so a small deliberate duplication
// here is safer than widening that file's access just to share four colors)

private let kAppGroup = AppGroup.identifier

private extension Color {
  init(_ r: Int, _ g: Int, _ b: Int) {
    self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
  }
}

private struct BreathingPal {
  let clayPaper: Color, ink: Color, inkMuted: Color
  /// `P.on(C.teal)` — the Mind accent as TEXT on this surface.
  let onMind: Color
  let isDark: Bool
  static let light = BreathingPal(clayPaper: Color(0xFF, 0xFF, 0xFF), ink: Color(0x0F, 0x17, 0x2A),
                                  inkMuted: Color(0x62, 0x71, 0x88),
                                  onMind: Color(0x12, 0x76, 0x74), isDark: false)
  static let dark  = BreathingPal(clayPaper: Color(0x15, 0x1C, 0x26), ink: Color(0xF1, 0xF5, 0xF9),
                                  inkMuted: Color(0x7F, 0x8D, 0xA0),
                                  onMind: Color(0x14, 0xB8, 0xA6), isDark: true)
  static var current: BreathingPal {
    (UserDefaults(suiteName: kAppGroup)?.object(forKey: "theme_dark") as? Bool ?? false)
      ? .dark : .light
  }
}

private extension Color {
  static var bClayPaper: Color { BreathingPal.current.clayPaper }
  static var bInk: Color { BreathingPal.current.ink }
  static var bInkMuted: Color { BreathingPal.current.inkMuted }
  /// Breathing is the Mind domain — `C.teal` in lib/ui2/theme.dart, the fifth
  /// tab's accent. Raw pigment for glyphs and keylines…
  static let bMind = Color(0x14, 0xB8, 0xA6)
  /// …`P.fill(C.teal)` for anything white sits on (buttons, tints)…
  static let bMindFill = Color(0x0F, 0x85, 0x78)
  /// …and `P.on(C.teal)` for accent TEXT.
  static var bOnMind: Color { BreathingPal.current.onMind }
}

private func coherenceText(_ v: Double) -> String { v >= 0 ? "\(Int(v.rounded()))%" : "Calibrating…" }

// A stale frame (no push for a minute: app killed, RR stopped) is an old
// reading, not a live one, so its score is blanked, same as the workout
// activity blanks HR. nil = stale.
private func shownScore(_ context: ActivityViewContext<OpenStrapBreathingAttributes>) -> Double? {
  if #available(iOSApplicationExtension 16.2, *), context.isStale { return nil }
  return context.state.coherenceScore
}
private func scoreText(_ v: Double?) -> String { v.map(coherenceText) ?? "" }

// MARK: - Interactive stop (iOS 17+) — separate flag from the workout's
// end_session so the two Live Activities never collide.

@available(iOSApplicationExtension 17.0, *)
struct EndBreathingIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "End session"
  func perform() async throws -> some IntentResult {
    UserDefaults(suiteName: kAppGroup)?.set(true, forKey: "end_breathing_session")
    for activity in Activity<OpenStrapBreathingAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
    return .result()
  }
}

// MARK: - Lock screen

private struct BreathingLockScreenView: View {
  let context: ActivityViewContext<OpenStrapBreathingAttributes>
  var body: some View {
    let score = shownScore(context)
    HStack(spacing: 14) {
      if #available(iOSApplicationExtension 17.0, *) {
        Image(systemName: "wind").font(.system(size: 26))
          .foregroundStyle(Color.bMind).symbolEffect(.pulse, options: .repeating)
      } else {
        Image(systemName: "wind").font(.system(size: 26)).foregroundStyle(Color.bMind)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(scoreText(score))
          .font(.system(size: (score ?? -1) >= 0 ? 30 : 18, weight: .bold, design: .rounded))
          .foregroundStyle(Color.bInk).contentTransition(.numericText())
        Text("COHERENCE").font(.system(size: 9, weight: .semibold)).tracking(1)
          .foregroundStyle(Color.bInkMuted)
      }
      Spacer()
      Text(context.attributes.startedAt, style: .timer)
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.bInkMuted)
      if #available(iOSApplicationExtension 17.0, *) {
        Button(intent: EndBreathingIntent()) {
          Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
        }
        .tint(Color.bMindFill).buttonBorderShape(.capsule)
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.bClayPaper)
    )
    .padding(8)
  }
}

// MARK: - Widget config

struct OpenStrapBreathingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: OpenStrapBreathingAttributes.self) { context in
      BreathingLockScreenView(context: context)
        .activitySystemActionForegroundColor(Color.bMindFill)
    } dynamicIsland: { context in
      let score = shownScore(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "wind").font(.system(size: 18)).foregroundStyle(Color.bMind)
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing, spacing: 0) {
            Text(scoreText(score))
              .font(.system(size: 18, weight: .bold, design: .rounded))
              .foregroundStyle(Color.bOnMind).contentTransition(.numericText())
            Text("COHERENCE").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
          }
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.attributes.startedAt, style: .timer)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if #available(iOSApplicationExtension 17.0, *) {
            Button(intent: EndBreathingIntent()) {
              Label("End session", systemImage: "stop.fill").font(.system(size: 12, weight: .bold))
            }
            .tint(Color.bMindFill).buttonBorderShape(.capsule)
          }
        }
      } compactLeading: {
        Image(systemName: "wind").font(.system(size: 14)).foregroundStyle(Color.bMind)
      } compactTrailing: {
        Text(score.map { $0 >= 0 ? "\(Int($0.rounded()))%" : "·" } ?? "")
          .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.bOnMind)
      } minimal: {
        Image(systemName: "wind").font(.system(size: 12)).foregroundStyle(Color.bMind)
      }
      .keylineTint(Color.bMind)
    }
  }
}
