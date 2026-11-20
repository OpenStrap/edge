//
//  OpenStrapWidget.swift
//  OpenStrapWidget
//
//  The home/lock-screen face of the app's daily snapshot. Nothing else: this is
//  a local-first app with no backend and no account, so there is nothing for a
//  widget to fetch. `WidgetService.refresh()` publishes after every derive and
//  on every foreground; that is the only refresh there is.
//
//  IT IS THE SAME THREE RINGS AS HOME NOW — Recovery · Strain · Sleep, in that
//  order, with the icon inside the dial and the number under it. It used to be
//  a readiness headline over Strain · Sleep · HRV, which was the previous
//  design system's home screen; HRV stopped being one of Home's rings in the
//  rebuild and lives on its own widget (OpenStrapOvernightWidget) instead.
//
//  HONESTY: nothing here may look current when it isn't, and nothing here may
//  look measured when it isn't.
//
//   · Freshness is computed at RENDER time from `updated_at`, not from the
//     `has_data` bool frozen at push time — see `SW.fresh`.
//   · The four ring states (measured / calibrating / unscaled / absent) arrive
//     resolved from Dart. Before that this file drew one dimmed empty circle
//     for every absence, so "four more nights and this fills in" and "the band
//     recorded nothing all night" were the same picture, forever.
//   · An absence is a WORD and a reason, never a dash and never an arc at zero
//     — an arc at zero reads as a score of zero, which is a lie about the user.
//

import WidgetKit
import SwiftUI

// MARK: - Model

struct OpenStrapEntry: TimelineEntry {
  var date: Date
  let snap: SW.Snapshot

  var fresh: Bool { SW.fresh(snap, at: date) }

  static let placeholder = OpenStrapEntry(date: Date(), snap: .placeholder)
}

// MARK: - Provider

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> OpenStrapEntry { .placeholder }

  func getSnapshot(in context: Context, completion: @escaping (OpenStrapEntry) -> Void) {
    completion(context.isPreview
               ? .placeholder
               : OpenStrapEntry(date: Date(), snap: SW.read()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<OpenStrapEntry>) -> Void) {
    let snap = SW.read()
    completion(SW.timeline(snap, Date()) { OpenStrapEntry(date: $0, snap: snap) })
  }
}

// MARK: - The trio

/// Which ring. The three the app can stand behind on a home screen: what the
/// night gave back, what the day has cost, and what the night was made of —
/// the same three, in the same order, as `HomeRingKind` on Home.
private enum Trio: CaseIterable {
  case recovery, strain, sleep

  var label: String {
    switch self {
    case .recovery: return "Recovery"
    case .strain: return "Strain"
    case .sleep: return "Sleep"
    }
  }

  /// The nearest SF Symbol to Home's Lucide glyph: battery-charging, zap, moon.
  var symbol: String {
    switch self {
    case .recovery: return "battery.100percent.bolt"
    case .strain: return "bolt.fill"
    case .sleep: return "moon.fill"
    }
  }

  func data(_ s: SW.Snapshot) -> SW.RingData {
    switch self {
    case .recovery: return s.recovery
    case .strain: return s.strain
    case .sleep: return s.sleep
    }
  }

  /// Recovery wears its band's colour, the other two their domain accent.
  func accent(_ s: SW.Snapshot, _ p: SW.Pal) -> Color {
    switch self {
    case .recovery: return SW.tierColor(s.tier, p)
    case .strain: return p.move
    case .sleep: return p.sleep
    }
  }
}

/// Home's own accessibility layout — dial left, type in the width it needs.
/// A small widget has the same problem a 1.3× text size does: three columns of
/// "7h 17m" do not fit across 140 points.
private struct RingRow: View {
  let kind: Trio
  let snap: SW.Snapshot
  var dial: CGFloat = 34

  var body: some View {
    let p = SW.pal
    let r = kind.data(snap)
    HStack(spacing: 10) {
      SW.Dial(r: r, symbol: kind.symbol, accent: kind.accent(snap, p),
              size: dial, line: 5)
      SW.RingText(label: kind.label, r: r, accent: kind.accent(snap, p),
                  align: .leading, valueSize: 17, showSub: false)
      Spacer(minLength: 0)
    }
  }
}

/// The default: three across, the number under the dial.
private struct RingColumn: View {
  let kind: Trio
  let snap: SW.Snapshot
  var dial: CGFloat = 48

  var body: some View {
    let p = SW.pal
    let r = kind.data(snap)
    VStack(spacing: 5) {
      SW.Dial(r: r, symbol: kind.symbol, accent: kind.accent(snap, p),
              size: dial, line: 7)
      SW.RingText(label: kind.label, r: r, accent: kind.accent(snap, p),
                  valueSize: 20)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct SmallView: View {
  let snap: SW.Snapshot
  var body: some View {
    VStack(spacing: 8) {
      ForEach(Array(Trio.allCases.enumerated()), id: \.offset) { _, k in
        RingRow(kind: k, snap: snap)
      }
    }
    .padding(12)
  }
}

private struct MediumView: View {
  let snap: SW.Snapshot

  /// The first ring that is missing and said why. One line is what a medium
  /// widget can afford; the rest is one tap away in the app.
  private var gap: Trio? {
    Trio.allCases.first { !$0.data(snap).why.isEmpty }
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(alignment: .top, spacing: 4) {
        ForEach(Array(Trio.allCases.enumerated()), id: \.offset) { _, k in
          RingColumn(kind: k, snap: snap)
        }
      }
      if let g = gap {
        SW.GapRow(label: g.label, symbol: g.symbol, why: g.data(snap).why)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(14)
  }
}

// MARK: - Accessory families

private struct AccessoryCircularView: View {
  let snap: SW.Snapshot
  var body: some View {
    let r = snap.recovery
    // No Gauge when there is no score: a gauge at zero is indistinguishable
    // from a recovery OF zero.
    if r.measured, r.frac >= 0 {
      Gauge(value: min(r.frac, 1)) {
        Text("RCV")
      } currentValueLabel: {
        Text(r.value)
      }
      .gaugeStyle(.accessoryCircular)
      .widgetAccentable()
    } else {
      VStack(spacing: 0) {
        Image(systemName: "bolt.heart").font(.system(size: 15)).widgetAccentable()
        Text("RCV").font(.system(size: 9, weight: .semibold))
      }
    }
  }
}

private struct AccessoryRectangularView: View {
  let snap: SW.Snapshot
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(snap.recovery.measured
           ? "Recovery \(snap.recovery.value)"
           : "Recovery · \(snap.recovery.value)")
        .font(.system(size: 13, weight: .bold)).widgetAccentable()
      // Only the rings that are actually reporting. An absent metric is left
      // out of the line rather than printed as a dash.
      Text(pair("Strain", snap.strain, "Sleep", snap.sleep))
        .font(.system(size: 13, weight: .semibold))
      // A calibrating or still-finishing score keeps its sub ("Finishing up",
      // "2 of 4 nights") so a provisional number never reads as final.
      Text((snap.recovery.measured || snap.recovery.calibrating) && !snap.recovery.sub.isEmpty
           ? snap.recovery.sub
           : firstWhy)
        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
    }
  }

  private var firstWhy: String {
    for r in [snap.recovery, snap.sleep, snap.strain] where !r.why.isEmpty { return r.why }
    return ""
  }

  private func pair(_ aLabel: String, _ a: SW.RingData,
                    _ bLabel: String, _ b: SW.RingData) -> String {
    [a.measured ? "\(aLabel) \(a.value)" : nil,
     b.measured ? "\(bLabel) \(b.value)" : nil]
      .compactMap { $0 }.joined(separator: "   ")
  }
}

// MARK: - Widget

struct OpenStrapWidgetEntryView: View {
  @Environment(\.widgetFamily) var family
  var entry: OpenStrapEntry

  var body: some View {
    content.strapBackground(family)
  }

  @ViewBuilder private var content: some View {
    if !entry.fresh {
      SW.NoData()
    } else {
      switch family {
      case .systemSmall: SmallView(snap: entry.snap)
      case .systemMedium: MediumView(snap: entry.snap)
      case .accessoryCircular: AccessoryCircularView(snap: entry.snap)
      case .accessoryRectangular: AccessoryRectangularView(snap: entry.snap)
      case .accessoryInline:
        Text(entry.snap.recovery.measured
             ? "Recovery \(entry.snap.recovery.value)"
             : "OpenStrap · \(entry.snap.recovery.value.lowercased())"
               + (entry.snap.recovery.calibrating && !entry.snap.recovery.sub.isEmpty
                  ? " · \(entry.snap.recovery.sub.lowercased())" : ""))
      default: SmallView(snap: entry.snap)
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
    .description("Recovery, strain and sleep at a glance.")
    .supportedFamilies([.systemSmall, .systemMedium,
                        .accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}
