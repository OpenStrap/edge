//
//  StrapWidgetKit.swift
//  OpenStrapWidget
//
//  The palette, the snapshot reader and the ring, shared by every widget that
//  renders what the app publishes into the App Group (OpenStrapWidget, the
//  Sleep widget and the Overnight widget). One namespace rather than free
//  functions and `extension Color` statics, because the Live Activity files
//  already own a `Pal` and a `Color.ink` of their own and two of those in one
//  module is a fight nobody wins.
//
//  WHAT THIS SIDE IS ALLOWED TO DECIDE: layout, and nothing else. The numbers,
//  their labels, what they are out of, whether a ring is a reading or
//  calibration progress, and why one is missing all arrive already resolved —
//  see `WidgetService.push` (lib/widget/widget_service.dart), which mirrors
//  `RingTrio` on Home. Rules that used to live here in Swift AND in Kotlin AND
//  in Dart disagreed about the same day; there is one copy now.
//

import WidgetKit
import SwiftUI

enum SW {
  static let appGroup = AppGroup.identifier

  // MARK: - Theme (lib/ui2/theme.dart)

  /// ui2's tokens, resolved for both appearances.
  ///
  /// The accents are `P.on(accent)` — ui2 nudges an accent toward the page ink
  /// until it clears WCAG AA 4.5:1 on the worst surface it can land on, and a
  /// ring spends that solved value for BOTH its arc and its number (see
  /// `_RingState.arc` / `.ink` in home_screen.dart). Recomputing these means
  /// running `P.on`'s binary search, not eyeballing a hex.
  struct Pal {
    let card, ink, ink2, ink3, track: Color
    /// Readiness tiers, then the two domain accents the other rings carry.
    let good, warn, bad, sleep, move: Color

    static let light = Pal(
      card: c(0xFFFFFF), ink: c(0x0F172A), ink2: c(0x475569),
      ink3: c(0x627188), track: c(0xE2E8F0),
      good: c(0x1A7A48), warn: c(0xA5521D), bad: c(0xB9393E),
      sleep: c(0x2F66C0), move: c(0x734FCF))
    static let dark = Pal(
      card: c(0x151C26), ink: c(0xF1F5F9), ink2: c(0x94A3B8),
      ink3: c(0x7F8DA0), track: c(0x232D3B),
      good: c(0x22C55E), warn: c(0xF87E28), bad: c(0xF07374),
      sleep: c(0x689EF7), move: c(0xA988F7))
  }

  static func c(_ hex: Int) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255)
  }

  /// The app mirrors its own resolved appearance into `theme_dark` (including
  /// an in-app override of the OS), so the widget follows the app rather than
  /// the system.
  static var pal: Pal {
    (UserDefaults(suiteName: appGroup)?.object(forKey: "theme_dark") as? Bool ?? false)
      ? .dark : .light
  }

  /// Readiness tier → its accent. The CUT-OFFS are not here: Dart publishes
  /// `readiness_tier` (`readinessBand`, home_screen.dart) so the phone, the
  /// widget, the Watch and Siri cannot disagree about what a 65 means.
  static func tierColor(_ tier: Int, _ p: Pal) -> Color {
    switch tier {
    case 3, 2: return p.good
    case 1: return p.warn
    case 0: return p.bad
    default: return p.ink3
    }
  }

  // MARK: - Type (F, lib/ui2/theme.dart)

  /// The numeral ramp. Tabular so a value never jitters its own layout, and SF
  /// Pro Text rather than the rounded face — the app's numbers are not round.
  static func num(_ size: CGFloat) -> Font {
    .system(size: size, weight: .bold).monospacedDigit()
  }
  /// `F.over` — the uppercase label over every ring.
  static let over = Font.system(size: 11, weight: .semibold)
  /// `F.cap` / `F.body`.
  static let cap = Font.system(size: 13)
  static let body = Font.system(size: 15)

  // MARK: - Freshness

  /// How old the snapshot may be before the widget stops presenting it as
  /// today's answer. The app pushes after every derive and on every foreground,
  /// so under normal use this is refreshed each morning; 26 h is one whole
  /// missed wake cycle plus grace for a wandering wake time.
  ///
  /// Kept in step with the same constant on the Watch (WatchMetrics.swift), in
  /// Siri (OpenStrapIntents.swift) and on Android (StrapWidgets.kt) — four
  /// separate build targets, so it cannot be one declaration.
  static let staleAfter: TimeInterval = 26 * 3600

  // MARK: - Snapshot

  /// One home ring as Dart resolved it. `state` is the same four-way split the
  /// phone draws: a reading, calibration progress, or an absence with the
  /// pipeline's own reason attached.
  struct RingData {
    let state: Int      // 0 measured · 1 calibrating · 2 absent
    let value: String   // the number, or the absence IN WORDS — never a dash
    let sub: String     // what it is out of, the band, or the nights banked
    let why: String     // absent rings only
    let frac: Double    // negative = nothing honest to sweep

    var measured: Bool { state == 0 }
    var calibrating: Bool { state == 1 }

    /// Arc and numeral share one colour on the phone, and the colour IS the
    /// signal that this is not a reading.
    func color(_ accent: Color, _ p: Pal) -> Color { measured ? accent : p.ink3 }
  }

  struct Snapshot {
    let hasData: Bool
    let updatedAt: Int          // epoch sec of the last push, 0 = unknown
    let tier: Int               // -1 not scored · 0 rest · 1 easy · 2 steady · 3 good
    let recovery, strain, sleep: RingData
    let hrv, hrvBaseline, rhr, efficiency: Int  // -1 = none
    /// Why the overnight figures are missing, when they are held over from a
    /// night that is not today's. "" when they are today's own.
    let overnightWhy: String

    /// Has any ring at all been published? False for a snapshot written by an
    /// app version older than the rings — every value would be the empty
    /// string, which draws three circles with nothing in them. It heals on the
    /// first push (the app publishes on every foreground), and until then the
    /// no-data state is the honest picture.
    var usable: Bool {
      !recovery.value.isEmpty || !strain.value.isEmpty || !sleep.value.isEmpty
    }

    static let placeholder = Snapshot(
      hasData: true, updatedAt: Int(Date().timeIntervalSince1970), tier: 3,
      recovery: RingData(state: 0, value: "72", sub: "Good to go", why: "", frac: 0.72),
      strain: RingData(state: 0, value: "12.4", sub: "of 21", why: "", frac: 12.4 / 21),
      sleep: RingData(state: 0, value: "7h 17m", sub: "of 7h 45m", why: "", frac: 437.0 / 465),
      hrv: 62, hrvBaseline: 58, rhr: 54, efficiency: 91,
      overnightWhy: "")
  }

  private static func ring(_ d: UserDefaults?, _ key: String) -> RingData {
    RingData(
      state: d?.object(forKey: "ring_\(key)_state") as? Int ?? 2,
      value: d?.string(forKey: "ring_\(key)_value") ?? "",
      sub: d?.string(forKey: "ring_\(key)_sub") ?? "",
      why: d?.string(forKey: "ring_\(key)_why") ?? "",
      frac: d?.object(forKey: "ring_\(key)_frac") as? Double ?? -1)
  }

  static func read() -> Snapshot {
    let d = UserDefaults(suiteName: appGroup)
    func i(_ k: String) -> Int { d?.object(forKey: k) as? Int ?? -1 }
    return Snapshot(
      hasData: d?.bool(forKey: "has_data") ?? false,
      updatedAt: d?.object(forKey: "updated_at") as? Int ?? 0,
      tier: i("readiness_tier"),
      recovery: ring(d, "recovery"), strain: ring(d, "strain"), sleep: ring(d, "sleep"),
      hrv: i("hrv"), hrvBaseline: i("hrv_baseline"), rhr: i("rhr"),
      efficiency: i("sleep_efficiency"),
      overnightWhy: d?.string(forKey: "overnight_why") ?? "")
  }

  /// Is [s] still today's answer AS OF [date]?
  ///
  /// `has_data` alone is not enough and never was: it is frozen the moment Dart
  /// writes it, so a phone that has not synced for a week keeps a week-old
  /// readiness on the home screen looking exactly like this morning's. Measured
  /// against the ENTRY's date rather than `Date()` so WidgetKit can render the
  /// flip from a timeline entry it already holds. An unknown timestamp is not a
  /// claim of staleness (matching `WidgetService.isStale`).
  static func fresh(_ s: Snapshot, at date: Date) -> Bool {
    guard s.hasData, s.usable else { return false }
    guard s.updatedAt > 0 else { return true }
    return date.timeIntervalSince1970 - Double(s.updatedAt) < staleAfter
  }

  /// The instant [s] stops being today's answer, or nil if it already is not.
  static func stalenessDeadline(_ s: Snapshot, after date: Date) -> Date? {
    guard s.hasData, s.updatedAt > 0 else { return nil }
    let at = Date(timeIntervalSince1970: Double(s.updatedAt) + staleAfter)
    return at > date ? at : nil
  }

  /// The one timeline policy all three snapshot widgets share: now, the moment
  /// the snapshot goes stale (so the honest empty state appears with no process
  /// wake and no budget spent), and an hourly re-read as belt and braces.
  static func timeline<E: TimelineEntry>(
    _ s: Snapshot, _ now: Date, _ make: (Date) -> E
  ) -> Timeline<E> {
    var entries = [make(now)]
    if let deadline = stalenessDeadline(s, after: now) { entries.append(make(deadline)) }
    let next = Calendar.current.date(byAdding: .hour, value: 1, to: now)
      ?? now.addingTimeInterval(3600)
    return Timeline(entries: entries, policy: .after(next))
  }

  // MARK: - Views

  /// Track circle + progress arc from 12 o'clock, round caps.
  struct Ring: View {
    let frac: Double
    let color: Color
    var lineWidth: CGFloat = 8

    var body: some View {
      let p = SW.pal
      ZStack {
        Circle().stroke(p.track, lineWidth: lineWidth)
        if frac > 0 {
          Circle()
            .trim(from: 0, to: min(frac, 1))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
      }
    }
  }

  /// The dial: the arc with the ring's ICON at its centre, exactly as on Home.
  ///
  /// The number lives UNDER the dial, not inside it — inside is where "7h 45m"
  /// overflows its own circle at the first accessibility step, and nothing
  /// about that string gets shorter.
  struct Dial: View {
    let r: RingData
    let symbol: String
    let accent: Color
    var size: CGFloat = 56
    var line: CGFloat = 7

    var body: some View {
      let p = SW.pal
      let tint = r.color(accent, p)
      ZStack {
        Ring(frac: r.frac, color: tint, lineWidth: line)
        Image(systemName: symbol)
          .font(.system(size: size * 0.32, weight: .medium))
          .foregroundStyle(tint)
      }
      .frame(width: size, height: size)
    }
  }

  /// Label over, value under, what-it-is-out-of under that. An absence takes
  /// the SENTENCE weight rather than the numeral one, because it is a sentence:
  /// "No sleep" set in 24pt bold would read as a score.
  struct RingText: View {
    let label: String
    let r: RingData
    let accent: Color
    var align: HorizontalAlignment = .center
    var valueSize: CGFloat = 22
    var showSub: Bool = true

    var body: some View {
      let p = SW.pal
      VStack(alignment: align, spacing: 1) {
        Text(label.uppercased()).font(SW.over).tracking(0.5).foregroundStyle(p.ink3)
        Text(r.value)
          .font(r.measured ? SW.num(valueSize) : SW.body)
          .foregroundStyle(r.measured ? p.ink : p.ink2)
          .lineLimit(1).minimumScaleFactor(0.65)
        if showSub && !r.sub.isEmpty {
          Text(r.sub).font(SW.cap).foregroundStyle(p.ink3)
            .lineLimit(1).minimumScaleFactor(0.7)
        }
      }
      .multilineTextAlignment(align == .leading ? .leading : .center)
    }
  }

  /// WHY a ring is empty. The row Home puts under the trio, at the size a
  /// widget can afford: what is missing, and the reason the pipeline gave.
  /// Never a reason invented here.
  struct GapRow: View {
    let label: String
    let symbol: String
    let why: String

    var body: some View {
      let p = SW.pal
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(p.ink3)
        // Interpolated rather than concatenated: `Text + Text` is deprecated,
        // and a nested Text keeps the label's weight without a second view.
        Text("\(Text(label).fontWeight(.semibold).foregroundColor(p.ink2)) · \(why)")
          .font(.system(size: 11))
          .foregroundStyle(p.ink3)
      }
      .lineLimit(2)
    }
  }

  /// `has_data` is false, or the snapshot has aged past [staleAfter]. Say that;
  /// do not render last week's readiness at full confidence.
  struct NoData: View {
    @Environment(\.widgetFamily) var family

    var body: some View {
      let p = SW.pal
      switch family {
      case .accessoryCircular:
        Image(systemName: "bolt.heart").font(.system(size: 18)).widgetAccentable()
      case .accessoryRectangular:
        VStack(alignment: .leading, spacing: 2) {
          Text("No recent data").font(.system(size: 13, weight: .bold)).widgetAccentable()
          Text("Open OpenStrap and sync your band.")
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
      case .accessoryInline:
        Text("OpenStrap · no recent data")
      default:
        VStack(spacing: 6) {
          Image(systemName: "bolt.heart").font(.system(size: 22)).foregroundStyle(p.ink3)
          Text("No recent data").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink)
          Text("Open OpenStrap and sync your band.")
            .font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(p.ink3)
        }
        .padding(12)
      }
    }
  }
}

extension View {
  /// Systems families get the app's card surface; accessory families must stay
  /// clear so the lock screen's own material shows through.
  @ViewBuilder func strapBackground(_ family: WidgetFamily) -> some View {
    let system = family == .systemSmall || family == .systemMedium || family == .systemLarge
    containerBackground(system ? SW.pal.card : Color.clear, for: .widget)
  }
}
