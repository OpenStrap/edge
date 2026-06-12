//
//  LiveActivityBridge.swift
//  Runner — drives the workout Live Activity from Flutter over a MethodChannel.
//  Channel "openstrap/live_activity": start / update / end. Add to the Runner
//  target. Requires NSSupportsLiveActivities=YES in Info.plist + iOS 16.2+.
//

import Foundation
import Flutter
import ActivityKit

// Live Activity attributes (Runner copy). MUST stay identical to the copy in the
// widget extension (OpenStrapWidgetLiveActivity.swift) — ActivityKit matches the
// activity to the widget by the type name + Codable shape.
@available(iOS 16.1, *)
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

enum LiveActivityBridge {
  private static let channelName = "openstrap/live_activity"

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

  private static func i(_ a: [String: Any], _ k: String, _ d: Int = 0) -> Int {
    (a[k] as? NSNumber)?.intValue ?? d
  }
  private static func dbl(_ a: [String: Any], _ k: String, _ d: Double = 0) -> Double {
    (a[k] as? NSNumber)?.doubleValue ?? d
  }

  @available(iOS 16.2, *)
  private static func state(_ a: [String: Any]) -> OpenStrapWidgetAttributes.ContentState {
    .init(hr: i(a, "hr"), zone: i(a, "zone"), strain: dbl(a, "strain"),
          calories: i(a, "calories"), maxHr: i(a, "maxHr", 190), rhr: i(a, "rhr", 60))
  }

  @available(iOS 16.2, *)
  private static func start(_ a: [String: Any]) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    // One at a time — end any stragglers first.
    for act in Activity<OpenStrapWidgetAttributes>.activities {
      Task { await act.end(nil, dismissalPolicy: .immediate) }
    }
    let attrs = OpenStrapWidgetAttributes(
      sessionName: a["name"] as? String ?? "Live session",
      startedAt: Date(timeIntervalSince1970: dbl(a, "startedAtMs") / 1000.0),
      targetKcal: i(a, "targetKcal", 300))
    do {
      _ = try Activity.request(
        attributes: attrs,
        content: .init(state: state(a), staleDate: nil))
    } catch {
      NSLog("LiveActivity start failed: \(error)")
    }
  }

  @available(iOS 16.2, *)
  private static func update(_ a: [String: Any]) {
    let content = ActivityContent(state: state(a), staleDate: nil)
    for act in Activity<OpenStrapWidgetAttributes>.activities {
      Task { await act.update(content) }
    }
  }

  @available(iOS 16.2, *)
  private static func end() {
    for act in Activity<OpenStrapWidgetAttributes>.activities {
      Task { await act.end(nil, dismissalPolicy: .immediate) }
    }
  }
}
