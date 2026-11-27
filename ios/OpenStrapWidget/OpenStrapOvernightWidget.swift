//
//  OpenStrapOvernightWidget.swift
//  OpenStrapWidget
//
//  The two things the band actually MEASURED while you slept: nocturnal HRV
//  (RMSSD, from beat-to-beat intervals) and resting heart rate. Everything else
//  on a widget is a composite of them.
//
//  It exists because the rebuilt home screen has three rings and HRV is not one
//  of them — Recovery, Strain and Sleep are — so the redesigned OpenStrapWidget
//  dropped the HRV ring it used to carry. This is where that number went, and
//  it is a better home for it: HRV means nothing against a population and
//  everything against your own baseline, which needs the room to say so.
//
//  HRV IS DRAWN AGAINST YOUR OWN BASELINE AND NOTHING ELSE. Full ring at or
//  above it. With no baseline there is no denominator, so there is no arc —
//  this used to divide by a hardcoded 100, a number that exists nowhere in the
//  pipeline.
//

import WidgetKit
import SwiftUI

struct OvernightEntry: TimelineEntry {
  var date: Date
  let snap: SW.Snapshot

  var fresh: Bool { SW.fresh(snap, at: date) }
  static let placeholder = OvernightEntry(date: Date(), snap: .placeholder)

  var hrvFrac: Double {
    guard snap.hrv >= 0, snap.hrvBaseline > 0 else { return -1 }
    return min(Double(snap.hrv) / Double(snap.hrvBaseline), 1)
  }

  /// Why there are no overnight numbers, as the app said it — the held-over
  /// night's reason first, then the night's own. Empty when nothing said why,
  /// in which case the widget says the value is missing and stops there rather
  /// than inventing a cause.
  var why: String {
    if !snap.overnightWhy.isEmpty { return snap.overnightWhy }
    return snap.sleep.why
  }

  var hasAny: Bool { snap.hrv >= 0 || snap.rhr >= 0 }
}

struct OvernightProvider: TimelineProvider {
  func placeholder(in context: Context) -> OvernightEntry { .placeholder }

  func getSnapshot(in context: Context, completion: @escaping (OvernightEntry) -> Void) {
    completion(context.isPreview ? .placeholder : OvernightEntry(date: Date(), snap: SW.read()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<OvernightEntry>) -> Void) {
    let snap = SW.read()
    completion(SW.timeline(snap, Date()) { OvernightEntry(date: $0, snap: snap) })
  }
}

/// One measured overnight figure: label, number, unit, and what it is being
/// read against. Absent prints the word, in the sentence weight.
private struct Figure: View {
  let label: String
  let value: Int
  let unit: String
  let against: String
  let accent: Color

  var body: some View {
    let p = SW.pal
    VStack(alignment: .leading, spacing: 1) {
      Text(label.uppercased()).font(SW.over).tracking(0.5).foregroundStyle(p.ink3)
      if value >= 0 {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text("\(value)").font(SW.num(24)).foregroundStyle(accent)
          Text(unit).font(SW.cap).foregroundStyle(p.ink3)
        }
        if !against.isEmpty {
          Text(against).font(SW.cap).foregroundStyle(p.ink3).lineLimit(1)
        }
      } else {
        Text("Not measured").font(SW.body).foregroundStyle(p.ink2)
      }
    }
  }
}

private struct OvernightSmallView: View {
  let e: OvernightEntry

  var body: some View {
    let p = SW.pal
    let s = e.snap
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        // The HRV dial carries no colour judgement — green is the Health
        // domain's accent, not a verdict. A "0.8 × baseline is amber" cut-off
        // was invented on this surface once and appears in no analytics output.
        SW.Dial(
          r: SW.RingData(state: s.hrv >= 0 ? 0 : 2, value: "", sub: "", why: "",
                         frac: e.hrvFrac),
          symbol: "waveform.path.ecg", accent: p.good, size: 40, line: 6)
        Figure(label: "HRV", value: s.hrv, unit: "ms",
               against: s.hrvBaseline > 0 ? String(localized: "base \(s.hrvBaseline)") : "",
               accent: p.good)
        Spacer(minLength: 0)
      }
      Divider()
      Figure(label: String(localized: "Resting HR"), value: s.rhr, unit: "bpm", against: "", accent: p.ink)
      if !e.hasAny, !e.why.isEmpty {
        Text(e.why).font(.system(size: 11)).foregroundStyle(p.ink3).lineLimit(3)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
  }
}

struct OpenStrapOvernightWidgetEntryView: View {
  @Environment(\.widgetFamily) var family
  var entry: OvernightEntry

  var body: some View {
    content.strapBackground(family)
  }

  private var line: String {
    let s = entry.snap
    let parts = [s.hrv >= 0 ? "HRV \(s.hrv) ms" : nil,
                 s.rhr >= 0 ? String(localized: "RHR \(s.rhr)") : nil].compactMap { $0 }
    return parts.isEmpty ? "" : parts.joined(separator: "   ")
  }

  @ViewBuilder private var content: some View {
    if !entry.fresh {
      SW.NoData()
    } else {
      switch family {
      case .accessoryCircular:
        if entry.snap.hrv >= 0, entry.hrvFrac >= 0 {
          Gauge(value: entry.hrvFrac) {
            Text("HRV")
          } currentValueLabel: {
            Text("\(entry.snap.hrv)")
          }
          .gaugeStyle(.accessoryCircular)
          .widgetAccentable()
        } else {
          VStack(spacing: 0) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 14)).widgetAccentable()
            Text(entry.snap.hrv >= 0 ? "\(entry.snap.hrv)" : "HRV")
              .font(.system(size: 10, weight: .semibold))
          }
        }
      case .accessoryRectangular:
        VStack(alignment: .leading, spacing: 2) {
          Text("Overnight").font(.system(size: 11, weight: .semibold)).widgetAccentable()
          Text(entry.hasAny ? line : String(localized: "Not measured"))
            .font(.system(size: 15, weight: .bold))
          Text(entry.hasAny
               ? (entry.snap.hrvBaseline > 0 ? String(localized: "Your baseline \(entry.snap.hrvBaseline) ms") : "")
               : entry.why)
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
      case .accessoryInline:
        Text(entry.snap.hrv >= 0 ? "HRV \(entry.snap.hrv) ms" : String(localized: "OpenStrap · HRV not measured"))
      default: OvernightSmallView(e: entry)
      }
    }
  }
}

struct OpenStrapOvernightWidget: Widget {
  let kind: String = "OpenStrapOvernightWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: OvernightProvider()) { entry in
      OpenStrapOvernightWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Overnight")
    .description("Last night's HRV against your own baseline, and resting heart rate.")
    .supportedFamilies([.systemSmall, .accessoryCircular,
                        .accessoryRectangular, .accessoryInline])
  }
}
