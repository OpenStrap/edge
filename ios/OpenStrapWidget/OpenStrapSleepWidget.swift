//
//  OpenStrapSleepWidget.swift
//  OpenStrapWidget
//
//  Last night, on its own. The one number people look for before they open
//  anything, and the moment they want it — first unlock of the morning — is the
//  moment a lock-screen widget is on screen anyway.
//
//  It is the trio's sleep ring at full size plus the one figure that does not
//  fit in a third of a card: efficiency. Everything it renders is resolved by
//  `WidgetService.push`, including whether there is a need to measure the night
//  against at all — a night with no LEARNED need draws an open track and says
//  "No target yet" rather than filling against a hardcoded 8 h that is not this
//  user's.
//

import WidgetKit
import SwiftUI

struct SleepEntry: TimelineEntry {
  var date: Date
  let snap: SW.Snapshot

  var fresh: Bool { SW.fresh(snap, at: date) }
  static let placeholder = SleepEntry(date: Date(), snap: .placeholder)
}

struct SleepProvider: TimelineProvider {
  func placeholder(in context: Context) -> SleepEntry { .placeholder }

  func getSnapshot(in context: Context, completion: @escaping (SleepEntry) -> Void) {
    completion(context.isPreview ? .placeholder : SleepEntry(date: Date(), snap: SW.read()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<SleepEntry>) -> Void) {
    let snap = SW.read()
    completion(SW.timeline(snap, Date()) { SleepEntry(date: $0, snap: snap) })
  }
}

private struct SleepSmallView: View {
  let snap: SW.Snapshot

  var body: some View {
    let p = SW.pal
    let r = snap.sleep
    VStack(spacing: 6) {
      SW.Dial(r: r, symbol: "moon.fill", accent: p.sleep, size: 60, line: 8)
      SW.RingText(label: String(localized: "Sleep"), r: r, accent: p.sleep, valueSize: 22)
      // Efficiency only when the night has one. It is the share of time in bed
      // actually asleep, and there is no honest placeholder for it.
      if r.measured, snap.efficiency >= 0 {
        Text("\(snap.efficiency)% efficient")
          .font(SW.cap).foregroundStyle(p.ink3).lineLimit(1)
      } else if !r.why.isEmpty {
        Text(r.why)
          .font(.system(size: 11)).foregroundStyle(p.ink3)
          .multilineTextAlignment(.center).lineLimit(3)
      }
    }
    .padding(12)
  }
}

private struct SleepRectangularView: View {
  let snap: SW.Snapshot
  var body: some View {
    let r = snap.sleep
    VStack(alignment: .leading, spacing: 2) {
      Text("Last night").font(.system(size: 11, weight: .semibold)).widgetAccentable()
      Text(r.value).font(.system(size: 16, weight: .bold))
      Text(r.measured
           ? [r.sub, snap.efficiency >= 0 ? String(localized: "\(snap.efficiency)% efficient") : nil]
              .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ")
           : r.why)
        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
    }
  }
}

struct OpenStrapSleepWidgetEntryView: View {
  @Environment(\.widgetFamily) var family
  var entry: SleepEntry

  var body: some View {
    content.strapBackground(family)
  }

  @ViewBuilder private var content: some View {
    if !entry.fresh {
      SW.NoData()
    } else {
      switch family {
      case .accessoryCircular:
        let r = entry.snap.sleep
        // An arc only when there is a need to measure the night against.
        if r.measured, r.frac >= 0 {
          Gauge(value: min(r.frac, 1)) {
            Image(systemName: "moon.fill")
          } currentValueLabel: {
            Text(r.value).minimumScaleFactor(0.5)
          }
          .gaugeStyle(.accessoryCircular)
          .widgetAccentable()
        } else {
          // Measured but unscaled (no learned need) prints the duration with no
          // ring; absent prints the glyph and the word alone. Neither draws an
          // arc, because an arc at zero reads as a night with no sleep in it.
          VStack(spacing: 0) {
            Image(systemName: "moon.fill").font(.system(size: 13)).widgetAccentable()
            Text(r.measured ? r.value : String(localized: "SLEEP"))
              .font(.system(size: 10, weight: .semibold)).minimumScaleFactor(0.6)
          }
        }
      case .accessoryRectangular: SleepRectangularView(snap: entry.snap)
      case .accessoryInline:
        Text(entry.snap.sleep.measured
             ? String(localized: "Slept \(entry.snap.sleep.value)")
             : "OpenStrap · \(entry.snap.sleep.value.lowercased())")
      default: SleepSmallView(snap: entry.snap)
      }
    }
  }
}

struct OpenStrapSleepWidget: Widget {
  let kind: String = "OpenStrapSleepWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: SleepProvider()) { entry in
      OpenStrapSleepWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Last night")
    .description("How long you slept, against the need the app has learned.")
    .supportedFamilies([.systemSmall, .accessoryCircular,
                        .accessoryRectangular, .accessoryInline])
  }
}
