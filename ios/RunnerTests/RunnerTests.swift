import Flutter
import UIKit
import XCTest
import AppIntents
@testable import Runner

@MainActor
class RunnerTests: XCTestCase {

  private func ready(_ bridge: ShortcutSyncBridge) {
    bridge.receive(FlutterMethodCall(methodName: "ready", arguments: nil)) { _ in }
  }

  func testReplyNeverTreatsMissingOrMalformedResponseAsSuccess() {
    let values: [Any?] = [nil, true, [:], ["status": "complete"],
                       ["status": "complete", "records": -1],
                       FlutterError(code: "storage", message: "Failed", details: nil)]
    for value in values {
      XCTAssertThrowsError(try ShortcutSyncReply(value))
    }
    XCTAssertEqual(try ShortcutSyncReply(["status": "complete", "records": 17]).records, 17)
    XCTAssertEqual(try ShortcutSyncReply(["status": "partial", "records": 3]).status, "partial")
  }

  func testWaitsForDartReadinessAndDispatchesOnlyOnce() async throws {
    var runs = 0
    let bridge = ShortcutSyncBridge { method, args, reply in
      XCTAssertEqual(method, "run")
      XCTAssertGreaterThan((args as! [String: Any])["budgetMs"] as! Int, 0)
      runs += 1
      reply(["status": "complete", "records": 8])
    }
    let request = Task { try await bridge.sync(timeout: 1) }
    await Task.yield()
    XCTAssertEqual(runs, 0)
    ready(bridge)
    let response = try await request.value
    XCTAssertEqual(response.records, 8)
    ready(bridge)
    XCTAssertEqual(runs, 1)
  }

  func testOverlappingRequestsDoNotStartAnotherSync() async throws {
    var reply: FlutterResult?
    let bridge = ShortcutSyncBridge { _, _, result in reply = result }
    ready(bridge)
    let first = Task { try await bridge.sync(timeout: 1) }
    while reply == nil { await Task.yield() }
    let second = try await bridge.sync(timeout: 1)
    XCTAssertEqual(second.status, "alreadyRunning")
    reply?(["status": "complete", "records": 2])
    let response = try await first.value
    XCTAssertEqual(response.status, "complete")
  }

  func testDeadlineCancelsAndIgnoresLateReply() async throws {
    var runReply: FlutterResult?
    var cancelledId: String?
    let bridge = ShortcutSyncBridge { method, args, reply in
      if method == "run" { runReply = reply }
      if method == "cancel" { cancelledId = (args as? [String: Any])?["id"] as? String }
    }
    ready(bridge)
    do {
      _ = try await bridge.sync(id: "expired", timeout: 0.02)
      XCTFail("A deadline must not report completion")
    } catch let error as ShortcutSyncFailure {
      XCTAssertEqual(error.code, "timedOut")
      XCTAssertFalse(error.canIgnore)
    }
    XCTAssertEqual(cancelledId, "expired")
    runReply?(["status": "complete", "records": 99])
  }

  func testTaskCancellationIsForwardedToMatchingRequest() async throws {
    var started = false
    var cancelled = false
    let bridge = ShortcutSyncBridge { method, args, _ in
      if method == "run" { started = true }
      if method == "cancel" {
        cancelled = (args as? [String: Any])?["id"] as? String == "cancel-me"
      }
    }
    ready(bridge)
    let request = Task { try await bridge.sync(id: "cancel-me", timeout: 1) }
    while !started { await Task.yield() }
    bridge.cancel(id: "some-other-request")
    XCTAssertFalse(cancelled)
    request.cancel()
    do {
      _ = try await request.value
      XCTFail("Cancelled request completed")
    } catch let error as ShortcutSyncFailure {
      XCTAssertEqual(error.code, "cancelled")
    }
    XCTAssertTrue(cancelled)
  }

  func testMissingReadinessDoesNotDispatchALateSync() async throws {
    var dispatched = false
    let bridge = ShortcutSyncBridge { _, _, _ in dispatched = true }
    do {
      _ = try await bridge.sync(timeout: 0.02)
      XCTFail("Missing readiness must time out")
    } catch let error as ShortcutSyncFailure {
      XCTAssertEqual(error.code, "timedOut")
    }
    ready(bridge)
    XCTAssertFalse(dispatched)
  }

  func testProgressBelongsOnlyToTheActiveRequest() async throws {
    var reply: FlutterResult?
    var updates = 0
    let bridge = ShortcutSyncBridge { _, _, result in reply = result }
    ready(bridge)
    let request = Task {
      try await bridge.sync(id: "active", timeout: 5, progress: { _ in updates += 1 })
    }
    while reply == nil { await Task.yield() }
    for id in ["old", "active"] {
      bridge.receive(FlutterMethodCall(methodName: "progress",
        arguments: ["id": id, "phase": "syncing", "batches": 2])) { _ in }
    }
    XCTAssertEqual(updates, 1)
    reply?(["status": "complete", "records": 2])
    _ = try await request.value
    bridge.receive(FlutterMethodCall(methodName: "progress",
      arguments: ["id": "active"])) { _ in }
    XCTAssertEqual(updates, 1)
  }

  func testSyncIntentIgnoresOnlyOptedInConnectivityErrors() async throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("App Intents require iOS 16") }
    for code in ["bluetoothUnavailable", "bandUnreachable", "permissionDenied",
                 "notPaired", "setupRequired", "failed", "timedOut", "cancelled"] {
      for ignore in [false, true] {
        let bridge = ShortcutSyncBridge { _, _, reply in
          reply(["status": code, "records": 0])
        }
        ready(bridge)
        var intent = SyncDataIntent()
        intent.ignoreConnectivityErrors = ignore
        let shouldIgnore = ignore && ["bluetoothUnavailable", "bandUnreachable"].contains(code)
        do {
          let message = try await intent.syncMessage(using: bridge)
          XCTAssertTrue(shouldIgnore, "Unexpected suppression of \(code)")
          XCTAssertTrue(message.hasPrefix("Skipped:"))
        } catch let error as ShortcutSyncFailure {
          XCTAssertFalse(shouldIgnore, "Expected suppression of \(code)")
          XCTAssertEqual(error.code, code)
        }
      }
    }
  }

  func testRealFlutterBridgeReportsUnpairedInsteadOfFalseSuccess() async throws {
    XCTAssertNotNil((UIApplication.shared.delegate as? AppDelegate)?.sharedEngine)
    do {
      _ = try await ShortcutSyncBridge.shared.sync(timeout: 25)
      XCTFail("The clean simulator has no paired band")
    } catch let error as ShortcutSyncFailure {
      XCTAssertEqual(error.code, "notPaired")
    }
  }

}
