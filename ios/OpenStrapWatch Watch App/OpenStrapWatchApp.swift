// OpenStrap Watch App — the on-wrist glance for today's readiness, strain and sleep.
//
// Read-only mirror of the phone's derived metrics (received over WCSession by
// WatchStore). Styled to match the phone app: it spends lib/ui2/theme.dart's
// tokens, tracking the app's own theme via the `theme_dark` flag it syncs. No
// compute, no BLE — the band is the sensor and the phone does the analytics.

import SwiftUI

@main
struct OpenStrapWatchApp: App {
  @StateObject private var store = WatchStore.shared

  init() { WatchStore.shared.activate() }

  var body: some Scene {
    WindowGroup {
      WatchGlanceView()
        .environmentObject(store)
    }
  }
}

// MARK: - Palette (mirrors lib/ui2/theme.dart)

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1)
  }
}

/// ui2's raw pigment (`C` in lib/ui2/theme.dart). Arcs and fills only — an
/// accent used as TEXT goes through the solved `on*` members of `Palette`,
/// which are `P.on()`'s output for this brightness.
enum C {
  static let green = Color(hex: 0x22C55E)
  static let orange = Color(hex: 0xF97316)
  static let red = Color(hex: 0xEF4444)
  static let blue = Color(hex: 0x3B82F6)     // sleep
  static let purple = Color(hex: 0x8B5CF6)   // strain / movement
  static let n400 = Color(hex: 0x94A3B8)
}

struct Palette {
  let bg, surface, surfaceAlt, divider: Color
  let ink, inkSoft, inkMuted: Color
  /// `P.on(C.green)` + `P.wash(C.green)` — the Home accent as text, and the
  /// tinted card it sits on.
  let onHome, homeWash: Color
  /// Tier accents as TEXT (`P.on`).
  let onGood, onWarn, onBad, onNone: Color

  static let light = Palette(
    bg: Color(hex: 0xF8FAFC), surface: Color(hex: 0xFFFFFF),
    surfaceAlt: Color(hex: 0xF1F5F9), divider: Color(hex: 0xE2E8F0),
    ink: Color(hex: 0x0F172A), inkSoft: Color(hex: 0x475569), inkMuted: Color(hex: 0x627188),
    onHome: Color(hex: 0x1A7948), homeWash: Color(hex: 0xE7F9ED),
    onGood: Color(hex: 0x1A7948), onWarn: Color(hex: 0xA5521D),
    onBad: Color(hex: 0xB9393E), onNone: Color(hex: 0x606B80))

  static let dark = Palette(
    bg: Color(hex: 0x0B1017), surface: Color(hex: 0x151C26),
    surfaceAlt: Color(hex: 0x1D2632), divider: Color(hex: 0x232D3B),
    ink: Color(hex: 0xF1F5F9), inkSoft: Color(hex: 0x94A3B8), inkMuted: Color(hex: 0x7F8DA0),
    onHome: Color(hex: 0x22C55E), homeWash: Color(hex: 0x173A30),
    onGood: Color(hex: 0x22C55E), onWarn: Color(hex: 0xF87F2A),
    onBad: Color(hex: 0xEF7373), onNone: Color(hex: 0x97A6BA))

  /// Readiness tier → arc pigment. The tier is computed once, in Dart, and
  /// shipped as `readiness_tier`; this only paints it.
  func readinessArc(_ tier: Int) -> Color {
    switch tier {
    case 3, 2: return C.green
    case 1: return C.orange
    case 0: return C.red
    default: return C.n400
    }
  }

  /// The same tier, solved for TEXT.
  func readiness(_ tier: Int) -> Color {
    switch tier {
    case 3, 2: return onGood
    case 1: return onWarn
    case 0: return onBad
    default: return onNone
    }
  }
}

// MARK: - Glance

struct WatchGlanceView: View {
  @EnvironmentObject var store: WatchStore
  private var m: WatchMetrics { store.metrics }
  private var p: Palette { m.themeDark ? .dark : .light }

  var body: some View {
    ZStack {
      // Flat surface. ui2 has no glow: the phone is cards on a plain ground,
      // and the wrist is one of its cards.
      p.bg.ignoresSafeArea()

      ScrollView {
        VStack(spacing: 12) {
          if !m.fresh { empty } else {
            readinessHero
            HStack(spacing: 10) {
              MetricCard(p: p, title: "STRAIN", value: m.strainText,
                         fraction: m.strainFraction, accent: C.purple)
              MetricCard(p: p, title: "SLEEP", value: m.sleepText,
                         fraction: m.sleepFraction, accent: C.blue)
            }
            HStack(spacing: 8) {
              StatCell(p: p, label: "HRV", value: m.hrvText, unit: "ms")
              StatCell(p: p, label: "RHR", value: m.rhrText, unit: "bpm")
            }
            if !m.coachLine.isEmpty { coach }
          }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
      }
    }
    .onAppear { store.requestRefresh() }
  }

  /// Nothing to show — either the phone has never pushed, or what it pushed is
  /// old enough that it is no longer today's answer. The two say different
  /// things: a snapshot going stale is not the same as never having one, and a
  /// stale number rendered as current is exactly what this state exists to
  /// prevent.
  private var empty: some View {
    VStack(spacing: 8) {
      Image(systemName: "heart.text.square")
        .font(.system(size: 32))
        .foregroundStyle(p.inkMuted)
      Text(m.hasData ? "No recent data" : "No data yet")
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .foregroundStyle(p.ink)
      Text("Open OpenStrap on your iPhone and sync your band.")
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .foregroundStyle(p.inkSoft)
    }
    .padding(.top, 20)
  }

  /// Readiness hero. Not "Recovery", and not a percentage — the phone scores
  /// READINESS out of 100 and the wrist must not rename it. With no score there
  /// is no arc: an arc trimmed to zero is a ring pinned at empty, which reads
  /// as "your readiness is 0".
  /// A pending score (calibrating, or provisional and "Finishing up") keeps the
  /// phone's muted treatment: arc and value in the muted ink, because the
  /// colour is the signal that this is not a reading yet.
  private var readinessHero: some View {
    let pending = m.recoveryPending
    let arc = pending ? p.inkMuted : p.readinessArc(m.tier)
    let frac = pending ? m.recoveryFrac : m.readinessFraction
    let numeric = pending && Int(m.recoveryValue) != nil
    let label: String = {
      if m.readiness >= 0 && !m.band.isEmpty { return m.band.uppercased() }
      if pending && !m.recoverySub.isEmpty { return m.recoverySub.uppercased() }
      return "READINESS"
    }()
    return VStack(spacing: 6) {
      ZStack {
        Circle().stroke(p.divider, lineWidth: 11)
        if frac > 0 {
          Circle()
            .trim(from: 0, to: min(frac, 1))
            .stroke(arc, style: StrokeStyle(lineWidth: 11, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        VStack(spacing: -2) {
          if m.readiness >= 0 {
            Text("\(m.readiness)")
              .font(.system(size: 40, weight: .bold, design: .rounded))
              .foregroundStyle(p.ink)
          } else if pending {
            Text(m.recoveryValue)
              .font(.system(size: numeric ? 40 : 13, weight: numeric ? .bold : .semibold,
                            design: .rounded))
              .minimumScaleFactor(0.7)
              .lineLimit(1)
              .foregroundStyle(p.inkMuted)
          } else {
            Text("Not scored")
              .font(.system(size: 13, weight: .semibold, design: .rounded))
              .foregroundStyle(p.inkSoft)
          }
          Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(1.2)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .foregroundStyle(p.inkMuted)
        }
        .padding(.horizontal, 14)
      }
      .frame(width: 118, height: 118)
      if !m.notScoredWhy.isEmpty {
        Text(m.notScoredWhy)
          .font(.system(size: 11))
          .multilineTextAlignment(.center)
          .foregroundStyle(p.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 2)
  }

  private var coach: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "sparkles")
        .font(.system(size: 11))
        .foregroundStyle(p.onHome)
      Text(m.coachLine)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(p.onHome)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(p.homeWash, in: RoundedRectangle(cornerRadius: 12))
  }
}

// MARK: - Components

/// An absent metric is an empty slot — no number, no arc, the card dimmed.
/// A 54pt circle cannot carry the phone's what/why/fix, but a dash over a ring
/// drawn at zero is a measurement we do not have, which is worse than silence.
private struct MetricCard: View {
  let p: Palette
  let title: String
  let value: String
  let fraction: Double
  let accent: Color
  private var absent: Bool { value.isEmpty }

  var body: some View {
    VStack(spacing: 6) {
      ZStack {
        Circle().stroke(accent.opacity(0.18), lineWidth: 6)
        if fraction > 0 {
          Circle()
            .trim(from: 0, to: fraction)
            .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        Text(value)
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundStyle(p.ink)
          .minimumScaleFactor(0.6)
          .lineLimit(1)
          .padding(3)
      }
      .frame(width: 54, height: 54)
      Text(title)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .tracking(0.8)
        .foregroundStyle(p.inkMuted)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
    .background(p.surface, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.divider, lineWidth: 1))
    .opacity(absent ? 0.4 : 1)
  }
}

private struct StatCell: View {
  let p: Palette
  let label: String
  let value: String
  let unit: String
  private var absent: Bool { value.isEmpty }

  var body: some View {
    VStack(spacing: 1) {
      Text(label)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .tracking(0.8)
        .foregroundStyle(p.inkMuted)
      if absent {
        Text("no reading")
          .font(.system(size: 11))
          .foregroundStyle(p.inkSoft)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
          Text(value)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(p.ink)
          Text(unit)
            .font(.system(size: 9))
            .foregroundStyle(p.inkSoft)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.divider, lineWidth: 1))
  }
}
