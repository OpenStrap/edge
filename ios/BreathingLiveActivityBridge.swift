//
//  BreathingLiveActivityBridge.swift
//  Runner — drives the breathing-session Live Activity from Flutter over a
//  MethodChannel. Channel "openstrap/breathing_live_activity": start / update /
//  end. Separate from LiveActivityBridge.swift (the workout one) deliberately —
//  a breathing session shows fundamentally different content (coherence, not
//  HR/zone/strain) and this keeps the well-tuned workout activity untouched.
//  Add to the Runner target. Requires NSSupportsLiveActivities=YES (already
//  set, shared with the workout activity) + iOS 16.2+.
//

import Foundation
import Flutter
import ActivityKit

// Live Activity attributes (Runner copy). MUST stay identical to the copy in
// the widget extension (OpenStrapBreathingLiveActivity.swift) — ActivityKit
// matches the activity to the widget by the type name + Codable shape.
//
// coherenceScore uses -1 as the "not yet available" sentinel (same convention
// as OpenStrapShared.readiness/strain/etc in OpenStrapIntents.swift) rather
// than Optional, to keep ContentState's shape simple — the widget renders
// "Calibrating…" for < 0, matching the in-app screen's honest pre-result state
// (never a fabricated number).
@available(iOS 16.1, *)
struct OpenStrapBreathingAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var coherenceScore: Double // -1 = not yet available ("Calibrating…")
  }
  var startedAt: Date
}

enum BreathingLiveActivityBridge {
  private static let channelName = "openstrap/breathing_live_activity"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard #available(iOS 16.2, *) else { result(nil); return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "start":  start(args);  result(nil)
      case "update": update(args); result(nil)
      case "end":    end();        result(nil)
      default:       result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func dbl(_ a: [String: Any], _ k: String, _ d: Double = -1) -> Double {
    (a[k] as? NSNumber)?.doubleValue ?? d
  }

  @available(iOS 16.2, *)
  private static func state(_ a: [String: Any]) -> OpenStrapBreathingAttributes.ContentState {
    .init(coherenceScore: dbl(a, "coherenceScore"))
  }

  @available(iOS 16.2, *)
  private static func start(_ a: [String: Any]) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    // One at a time — end any stragglers first.
    for act in Activity<OpenStrapBreathingAttributes>.activities {
      Task { await act.end(nil, dismissalPolicy: .immediate) }
    }
    let attrs = OpenStrapBreathingAttributes(
      startedAt: Date(timeIntervalSince1970: dbl(a, "startedAtMs", 0) / 1000.0))
    do {
      _ = try Activity.request(
        attributes: attrs,
        content: .init(state: state(a), staleDate: nil))
    } catch {
      NSLog("BreathingLiveActivity start failed: \(error)")
    }
  }

  @available(iOS 16.2, *)
  private static func update(_ a: [String: Any]) {
    let content = ActivityContent(state: state(a), staleDate: nil)
    for act in Activity<OpenStrapBreathingAttributes>.activities {
      Task { await act.update(content) }
    }
  }

  @available(iOS 16.2, *)
  private static func end() {
    for act in Activity<OpenStrapBreathingAttributes>.activities {
      Task { await act.end(nil, dismissalPolicy: .immediate) }
    }
  }
}
